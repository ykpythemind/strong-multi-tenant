# frozen_string_literal: true

require "set"
require "yaml"
require "digest"

module StrongMultiTenant
  module Manifest
    # Builds a lock hash from (source, schema_reader).
    #
    # Traversal rule:
    #   - Start with all root tables (mode: :root) and direct tables (mode: :direct).
    #   - BFS through foreign keys: every FK `child(col) -> parent` where parent is
    #     already policy-covered makes child covered as :fk.
    #   - If a child table has a column with the same name as any ancestor root's
    #     primary key OR any direct table's tenant_column, promote child to :hybrid.
    #
    # Tables in `skip` are never expanded. Tables never reached go into
    # `skipped.unreachable` (minus skip + automatic excludes).
    class Builder
      AUTOMATIC_SKIP = %w[schema_migrations ar_internal_metadata].freeze

      def self.build(source:, schema_reader:, schema_digest: nil)
        new(source: source, schema_reader: schema_reader, schema_digest: schema_digest).build
      end

      def initialize(source:, schema_reader:, schema_digest: nil)
        @source = source
        @schema = schema_reader
        @schema_digest = schema_digest
      end

      def build
        @source.validate_against_schema!(@schema)

        policies = {}
        skip_set = Set.new(@source.skip + AUTOMATIC_SKIP)

        # Tenant columns that indicate "hybrid" promotion.
        hybrid_column_candidates = @source.direct.values.uniq

        # Roots.
        @source.roots.each do |root|
          policies[root] = {
            "mode" => "root",
            "tenant_column" => @schema.primary_key(root)
          }
        end

        # Direct.
        @source.direct.each do |table, column|
          policies[table] = {
            "mode" => "direct",
            "tenant_column" => column
          }
        end

        # FK BFS. Build incoming fk index: for each to_table, list of [from_table, column, primary_key].
        incoming = Hash.new { |h, k| h[k] = [] }
        @schema.all_foreign_keys.each do |fk|
          incoming[fk[:to_table]] << fk
        end

        queue = policies.keys.dup
        visited = Set.new(queue)
        visited.merge(skip_set) # skip set never enters queue

        until queue.empty?
          parent = queue.shift
          incoming[parent].each do |fk|
            child = fk[:from_table]
            next if skip_set.include?(child)
            next if visited.include?(child) && !policies.key?(child) == false && policies[child]

            if policies.key?(child)
              existing = policies[child]
              # Already covered by root/direct/hybrid/fk — accumulate fk_columns if fk mode.
              if existing["mode"] == "fk" || existing["mode"] == "hybrid"
                existing["fk_columns"] = ((existing["fk_columns"] || []) + [fk[:column]]).uniq
                existing["parents"] = ((existing["parents"] || []) + [parent]).uniq
              end
              # roots / direct — do not overwrite.
              next
            end

            visited << child
            child_cols = @schema.columns(child).map(&:to_s)
            hybrid_col = hybrid_column_candidates.find { |c| child_cols.include?(c) }

            entry = {
              "mode" => hybrid_col ? "hybrid" : "fk",
              "fk_columns" => [fk[:column]],
              "parents" => [parent],
              "parent_check" => (@source.parent_check[child] || "trust_app")
            }
            entry["tenant_column"] = hybrid_col if hybrid_col

            policies[child] = entry
            queue << child
          end
        end

        # Accumulate fk_columns for already-inserted fk children whose parent is discovered later (BFS handles normally,
        # but multi-parent fks need collecting): do a pass.
        @schema.all_foreign_keys.each do |fk|
          child = fk[:from_table]
          parent = fk[:to_table]
          next unless policies[child] && (policies[child]["mode"] == "fk" || policies[child]["mode"] == "hybrid")
          next unless policies[parent]
          policies[child]["fk_columns"] = ((policies[child]["fk_columns"] || []) + [fk[:column]]).uniq
          policies[child]["parents"] = ((policies[child]["parents"] || []) + [parent]).uniq
        end

        covered = policies.keys.to_set
        all_tables = @schema.all_tables.map(&:to_s)
        automatic_skipped = AUTOMATIC_SKIP & all_tables
        explicit_skipped = @source.skip & all_tables
        unreachable = all_tables - covered.to_a - automatic_skipped - explicit_skipped

        {
          "schema_digest" => @schema_digest,
          "source_digest" => @source.digest,
          "policies" => policies.sort.to_h,
          "skipped" => {
            "explicit" => explicit_skipped.sort,
            "automatic" => automatic_skipped.sort,
            "unreachable" => unreachable.sort
          }
        }
      end
    end
  end
end
