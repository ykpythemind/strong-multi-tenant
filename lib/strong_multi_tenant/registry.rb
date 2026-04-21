# frozen_string_literal: true

require_relative "policy"

module StrongMultiTenant
  class Registry
    attr_reader :policies, :skipped_explicit, :skipped_automatic, :skipped_unreachable,
                :source_digest, :schema_digest

    def self.from_lock(lock_hash)
      new(lock_hash)
    end

    def initialize(lock_hash)
      @source_digest = lock_hash["source_digest"]
      @schema_digest = lock_hash["schema_digest"]

      @policies = {}
      (lock_hash["policies"] || {}).each do |table, entry|
        @policies[table.to_sym] = Policy.build(
          table_name: table,
          mode: entry["mode"],
          tenant_column: entry["tenant_column"],
          fk_columns: entry["fk_columns"],
          parents: entry["parents"],
          parent_check: entry["parent_check"] || "trust_app"
        )
      end

      skipped = lock_hash["skipped"] || {}
      @skipped_explicit = (skipped["explicit"] || []).map(&:to_sym).to_set
      @skipped_automatic = (skipped["automatic"] || []).map(&:to_sym).to_set
      @skipped_unreachable = (skipped["unreachable"] || []).map(&:to_sym).to_set
    end

    def lookup(table_name)
      @policies[table_name.to_sym]
    end

    def tenant_column_known?(column)
      column = column.to_sym
      @policies.each_value do |p|
        return true if p.tenant_column == column
      end
      false
    end

    def skipped?(table_name)
      t = table_name.to_sym
      @skipped_explicit.include?(t) || @skipped_automatic.include?(t) || @skipped_unreachable.include?(t)
    end
  end
end
