# frozen_string_literal: true

module StrongMultiTenant
  class Analyzer
    # Given a WHERE-clause AST (typically a node holding an A_Expr / BoolExpr tree),
    # extract simple equality/IN predicates of the form:
    #    <qualified?column> = <Const|ParamRef>
    #    <qualified?column> IN (<Const|ParamRef>, ...)
    #
    # Returns an Array<Hash> of predicates:
    #   { table: String|nil, column: String, kind: :eq|:in, values: [Value, ...] }
    # where Value is { type: :const, value: Integer|String|...} or { type: :param, index: Integer }
    module Predicate
      module_function

      # Enumerate atomic predicates inside a WHERE. Only AND conjunctions are
      # considered "required". An OR branch cannot strengthen tenant guarantees,
      # so predicates inside OR are ignored (they cannot be counted as matching).
      def extract_anded(where_node)
        preds = []
        walk(where_node, in_and: true, preds: preds)
        preds
      end

      def walk(node, in_and:, preds:)
        return unless node

        inner = node.is_a?(PgQuery::Node) ? Walker.node_unwrap(node) : node
        return unless inner

        case inner
        when PgQuery::BoolExpr
          case inner.boolop
          when :AND_EXPR
            inner.args.each { |a| walk(a, in_and: true, preds: preds) }
          when :OR_EXPR, :NOT_EXPR
            # Inside OR/NOT: predicates don't strengthen guarantees — skip.
          end
        when PgQuery::A_Expr
          pred = extract_simple(inner)
          preds << pred if pred && in_and
        when PgQuery::RowExpr, PgQuery::SubLink, PgQuery::NullTest, PgQuery::TypeCast
          # Skip exotic forms; we cannot safely interpret them.
        end
      end

      # Handles: col = value, col IN (list), col = ANY($1)
      def extract_simple(a_expr)
        case a_expr.kind
        when :AEXPR_OP
          opname = a_expr.name.map { |n| str_val(n) }.join
          return nil unless opname == "="
          lhs = classify_side(a_expr.lexpr)
          rhs = classify_side(a_expr.rexpr)
          if lhs && lhs[:type] == :column
            rhsv = value_side(rhs)
            return nil unless rhsv
            return { table: lhs[:table], column: lhs[:column], kind: :eq, values: [rhsv] }
          elsif rhs && rhs[:type] == :column
            lhsv = value_side(lhs)
            return nil unless lhsv
            return { table: rhs[:table], column: rhs[:column], kind: :eq, values: [lhsv] }
          end
          nil
        when :AEXPR_IN
          lhs = classify_side(a_expr.lexpr)
          return nil unless lhs && lhs[:type] == :column
          values = list_values(a_expr.rexpr)
          return nil if values.empty?
          { table: lhs[:table], column: lhs[:column], kind: :in, values: values }
        else
          nil
        end
      end

      def classify_side(node)
        return nil unless node
        inner = node.is_a?(PgQuery::Node) ? Walker.node_unwrap(node) : node
        return nil unless inner

        case inner
        when PgQuery::ColumnRef
          parts = inner.fields.map { |f| col_field(f) }.compact
          return nil if parts.empty?
          if parts.length == 1
            { type: :column, table: nil, column: parts[0] }
          else
            { type: :column, table: parts[-2], column: parts[-1] }
          end
        when PgQuery::A_Const
          { type: :const, value: a_const_value(inner) }
        when PgQuery::ParamRef
          { type: :param, index: inner.number }
        when PgQuery::TypeCast
          classify_side(inner.arg)
        else
          nil
        end
      end

      def value_side(classified)
        return nil unless classified
        case classified[:type]
        when :const
          { type: :const, value: classified[:value] }
        when :param
          { type: :param, index: classified[:index] }
        end
      end

      def list_values(node)
        inner = node.is_a?(PgQuery::Node) ? Walker.node_unwrap(node) : node
        values = []
        case inner
        when PgQuery::List
          inner.items.each do |item|
            v = value_side(classify_side(item))
            values << v if v
          end
        when PgQuery::ArrayExpr
          inner.elements.each do |item|
            v = value_side(classify_side(item))
            values << v if v
          end
        when Array
          inner.each do |item|
            v = value_side(classify_side(item))
            values << v if v
          end
        end
        values
      end

      def col_field(field)
        inner = field.is_a?(PgQuery::Node) ? Walker.node_unwrap(field) : field
        case inner
        when PgQuery::String
          inner.sval
        when PgQuery::A_Star
          nil
        end
      end

      def str_val(node)
        inner = node.is_a?(PgQuery::Node) ? Walker.node_unwrap(node) : node
        case inner
        when PgQuery::String
          inner.sval
        else
          inner.to_s
        end
      end

      def a_const_value(a_const)
        return nil if a_const.isnull
        return a_const.ival.ival if a_const.ival
        return a_const.sval.sval if a_const.sval
        return a_const.boolval.boolval if a_const.boolval
        return a_const.fval.fval.to_f if a_const.fval
        nil
      rescue StandardError
        nil
      end
    end
  end
end
