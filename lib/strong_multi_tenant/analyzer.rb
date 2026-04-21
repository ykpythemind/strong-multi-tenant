# frozen_string_literal: true

require "pg_query"

require_relative "analyzer/result"
require_relative "analyzer/walker"
require_relative "analyzer/predicate"
require_relative "analyzer/no_where"

module StrongMultiTenant
  # Inspects a single SQL statement and returns :ok or a Violation Result.
  #
  # Usage:
  #   analyzer = Analyzer.new(registry: registry, current: StrongMultiTenant::Current.instance)
  #   result = analyzer.analyze(sql, binds: [1, 2])
  #   raise TenantViolation unless result.ok?
  class Analyzer
    # Maximum fingerprint-cache size.
    CACHE_LIMIT = 1024

    def initialize(registry:, current: StrongMultiTenant::Current.instance)
      @registry = registry
      @current = current
      @cache = {}
    end

    # sql: String
    # binds: optional Array of bind values (in $1, $2, ... order). Used to validate
    # that a ParamRef tenant predicate holds the Current.tenant_id.
    def analyze(sql, binds: [])
      return Result.ok if @current.bypass?
      return Result.ok if skip_sql?(sql)

      parse_result = parse(sql)
      return Result.ok if parse_result.nil?

      parse_result.tree.stmts.each do |raw_stmt|
        stmt = Walker.node_unwrap(raw_stmt.stmt)
        next unless stmt

        result = analyze_stmt(stmt, sql: sql, binds: binds)
        return result unless result.ok?
      end

      Result.ok
    end

    private

    def parse(sql)
      PgQuery.parse(sql)
    rescue PgQuery::ParseError
      # If pg_query refuses the SQL, we cannot analyze. Let the DB decide — the
      # adapter layer will surface the syntax error.
      nil
    end

    # Fast-path exclusions. Checked before parse to keep overhead low.
    SCHEMA_QUERY_PATTERNS = [
      /\A\s*SHOW\s/i,
      /\A\s*BEGIN\b/i,
      /\A\s*COMMIT\b/i,
      /\A\s*ROLLBACK\b/i,
      /\A\s*SAVEPOINT\b/i,
      /\A\s*RELEASE\s+SAVEPOINT\b/i,
      /\A\s*SET\s/i,
      /\A\s*EXPLAIN\s/i,
      /\A\s*VACUUM\b/i,
      /\A\s*ANALYZE\b/i,
      /\A\s*LOCK\b/i,
      /\A\s*DISCARD\b/i,
      /\A\s*LISTEN\b/i,
      /\A\s*NOTIFY\b/i
    ].freeze

    def skip_sql?(sql)
      return true if sql.nil? || sql.strip.empty?
      SCHEMA_QUERY_PATTERNS.any? { |re| re.match?(sql) }
    end

    def analyze_stmt(stmt, sql:, binds:)
      case stmt
      when PgQuery::SelectStmt
        analyze_select(stmt, sql: sql, binds: binds)
      when PgQuery::UpdateStmt
        analyze_update(stmt, sql: sql, binds: binds)
      when PgQuery::DeleteStmt
        analyze_delete(stmt, sql: sql, binds: binds)
      when PgQuery::InsertStmt
        analyze_insert(stmt, sql: sql, binds: binds)
      else
        # DDL / Transaction / other: trust.
        Result.ok
      end
    end

    # --------------------------------------------------------------------
    # SELECT
    # --------------------------------------------------------------------
    def analyze_select(stmt, sql:, binds:)
      # UNION / INTERSECT / EXCEPT combines two SelectStmts.
      if stmt.op && stmt.op != :SETOP_NONE
        [stmt.larg, stmt.rarg].compact.each do |branch|
          inner = branch.is_a?(PgQuery::Node) ? Walker.node_unwrap(branch) : branch
          next unless inner.is_a?(PgQuery::SelectStmt)
          r = analyze_select(inner, sql: sql, binds: binds)
          return r unless r.ok?
        end
        return Result.ok
      end

      # VALUES-only SELECT (has values_lists, no from_clause): nothing to enforce.
      if stmt.values_lists && !stmt.values_lists.empty?
        return Result.ok
      end

      # CTEs: each CTE query is its own scope.
      if stmt.with_clause && stmt.with_clause.ctes && !stmt.with_clause.ctes.empty?
        stmt.with_clause.ctes.each do |cte_node|
          cte = Walker.node_unwrap(cte_node)
          next unless cte.is_a?(PgQuery::CommonTableExpr)
          inner = Walker.node_unwrap(cte.ctequery)
          next unless inner
          r = analyze_stmt(inner, sql: sql, binds: binds)
          return r unless r.ok?
        end
      end

      from_nodes = stmt.from_clause.to_a
      where = stmt.where_clause

      return Result.ok if from_nodes.empty? # e.g. SELECT 1

      # Find primary target tables (top-level FROM + JOIN).
      primary_tables = Walker.top_level_range_vars(from_nodes)

      # NoWhere check: any primary target that has no WHERE (or trivially-true) → NoWhereViolation,
      # unless allowed.
      primary_tables.each do |range_var|
        tname = range_var.relname.to_sym
        next if @current.allow_no_where?(tname)
        if NoWhere.trivially_true?(where)
          return Result.violation(
            kind: :no_where,
            table: tname,
            reason: :missing_where,
            message: "SELECT without WHERE on #{tname}"
          )
        end
      end

      # Tenant-predicate check for each table in the statement scope (top-level + joined).
      r = check_scope_tables(from_nodes, where, binds: binds, sql: sql, stmt: stmt)
      return r unless r.ok?

      # Recurse into subqueries: each RangeSubselect / SubLink is its own scope.
      Walker.each_node(stmt) do |n|
        case n
        when PgQuery::RangeSubselect
          sub = Walker.node_unwrap(n.subquery)
          next unless sub.is_a?(PgQuery::SelectStmt)
          next if sub.equal?(stmt)
          r = analyze_select(sub, sql: sql, binds: binds)
          return r unless r.ok?
        when PgQuery::SubLink
          sub = Walker.node_unwrap(n.subselect)
          next unless sub.is_a?(PgQuery::SelectStmt)
          r = analyze_select(sub, sql: sql, binds: binds)
          return r unless r.ok?
        end
      end

      Result.ok
    end

    # --------------------------------------------------------------------
    # UPDATE / DELETE
    # --------------------------------------------------------------------
    def analyze_update(stmt, sql:, binds:)
      target = stmt.relation
      return Result.ok unless target
      tname = target.relname.to_sym
      where = stmt.where_clause

      unless @current.allow_no_where?(tname)
        if NoWhere.trivially_true?(where)
          return Result.violation(kind: :no_where, table: tname, reason: :missing_where,
                                  message: "UPDATE without WHERE on #{tname}")
        end
      end

      # Scope tables: target + FROM/USING.
      scope_nodes = []
      scope_nodes << target
      scope_nodes.concat(stmt.from_clause.to_a) if stmt.from_clause
      check_scope_tables(scope_nodes, where, binds: binds, sql: sql, stmt: stmt)
    end

    def analyze_delete(stmt, sql:, binds:)
      target = stmt.relation
      return Result.ok unless target
      tname = target.relname.to_sym
      where = stmt.where_clause

      unless @current.allow_no_where?(tname)
        if NoWhere.trivially_true?(where)
          return Result.violation(kind: :no_where, table: tname, reason: :missing_where,
                                  message: "DELETE without WHERE on #{tname}")
        end
      end

      scope_nodes = []
      scope_nodes << target
      scope_nodes.concat(stmt.using_clause.to_a) if stmt.using_clause
      check_scope_tables(scope_nodes, where, binds: binds, sql: sql, stmt: stmt)
    end

    # --------------------------------------------------------------------
    # INSERT
    # --------------------------------------------------------------------
    def analyze_insert(stmt, sql:, binds:)
      target = stmt.relation
      return Result.ok unless target
      tname = target.relname.to_sym
      policy = @registry.lookup(tname)
      return Result.ok unless policy
      return Result.ok unless policy.requires_tenant_column?

      col_names = (stmt.cols || []).map do |c|
        rt = Walker.node_unwrap(c)
        rt.respond_to?(:name) ? rt.name : nil
      end

      idx = col_names.index(policy.tenant_column.to_s)
      if idx.nil?
        # Column not listed: could be default. Be strict — require it.
        return Result.violation(
          kind: :tenant,
          table: tname,
          reason: :insert_missing_tenant_column,
          message: "INSERT into #{tname} did not set #{policy.tenant_column}"
        )
      end

      # Inspect values. For INSERT ... VALUES, select_stmt is SelectStmt with values_lists.
      select_inner = Walker.node_unwrap(stmt.select_stmt)
      return Result.ok unless select_inner.is_a?(PgQuery::SelectStmt)

      if select_inner.values_lists && !select_inner.values_lists.empty?
        select_inner.values_lists.each do |row_node|
          row = Walker.node_unwrap(row_node)
          items = case row
                  when PgQuery::List then row.items
                  else []
                  end
          value_node = items[idx]
          next unless value_node
          v = Predicate.value_side(Predicate.classify_side(value_node))
          next unless v
          unless value_matches_tenant?(v, binds: binds)
            return Result.violation(
              kind: :tenant,
              table: tname,
              reason: :insert_tenant_mismatch,
              message: "INSERT into #{tname}.#{policy.tenant_column} does not match Current.tenant_id"
            )
          end
        end
      end

      Result.ok
    end

    # --------------------------------------------------------------------
    # Shared: scope check
    # --------------------------------------------------------------------
    def check_scope_tables(from_or_target_nodes, where_node, binds:, sql:, stmt:)
      tables = []
      Array(from_or_target_nodes).each do |node|
        next unless node
        if node.is_a?(PgQuery::RangeVar)
          tables << node
        else
          tables.concat(Walker.top_level_range_vars([node]))
        end
      end

      preds = Predicate.extract_anded(where_node)

      tables.each do |rv|
        tname = rv.relname.to_sym
        policy = @registry.lookup(tname)
        next unless policy

        alias_name = rv.alias&.aliasname
        alias_name = nil if alias_name && alias_name.empty?

        case policy.mode
        when :root, :direct
          ok = tenant_column_bound?(
            preds, tname, alias_name, policy.tenant_column, binds: binds
          )
          unless ok
            return Result.violation(
              kind: :tenant,
              table: tname,
              reason: :missing_tenant_predicate,
              message: "No #{policy.tenant_column} predicate for #{tname}"
            )
          end
        when :fk
          ok = fk_bound?(preds, tname, alias_name, policy.fk_columns)
          unless ok
            return Result.violation(
              kind: :tenant,
              table: tname,
              reason: :missing_fk_predicate,
              message: "No fk predicate (#{policy.fk_columns.join(",")}) for #{tname}"
            )
          end
        when :hybrid
          ok = tenant_column_bound?(preds, tname, alias_name, policy.tenant_column, binds: binds) ||
               fk_bound?(preds, tname, alias_name, policy.fk_columns)
          unless ok
            return Result.violation(
              kind: :tenant,
              table: tname,
              reason: :missing_tenant_or_fk_predicate,
              message: "No tenant_column or fk predicate for #{tname}"
            )
          end
        end
      end

      Result.ok
    end

    # Is there a `<table>.<tenant_column> = <Const|Param>` predicate (or unqualified
    # where table is unambiguous), AND if a Const, does its value equal
    # Current.tenant_id? If a ParamRef, does the matching bind equal Current.tenant_id?
    def tenant_column_bound?(preds, table, alias_name, column, binds:)
      preds.any? do |p|
        next false unless p[:column] == column.to_s
        next false if p[:table] && p[:table] != table.to_s && p[:table] != alias_name
        p[:values].any? { |v| value_matches_tenant?(v, binds: binds) }
      end
    end

    def fk_bound?(preds, table, alias_name, fk_columns)
      fk_cols = fk_columns.map(&:to_s)
      preds.any? do |p|
        next false unless fk_cols.include?(p[:column])
        next false if p[:table] && p[:table] != table.to_s && p[:table] != alias_name
        !p[:values].empty?
      end
    end

    def value_matches_tenant?(value, binds:)
      tenant_id = @current.tenant_id
      return false if tenant_id.nil?

      case value[:type]
      when :const
        cast_equal?(value[:value], tenant_id)
      when :param
        idx = value[:index].to_i - 1
        return false if idx < 0
        return false if binds.length <= idx
        cast_equal?(binds[idx], tenant_id)
      else
        false
      end
    end

    def cast_equal?(a, b)
      return true if a == b
      return a.to_s == b.to_s if a.is_a?(Integer) || b.is_a?(Integer)
      false
    end
  end
end
