# frozen_string_literal: true

module StrongMultiTenant
  MODES = %i[root direct fk hybrid].freeze
  PARENT_CHECKS = %i[trust_app runtime_exists rewrite].freeze

  Policy = Data.define(
    :table_name,
    :mode,
    :tenant_column,
    :fk_columns,
    :parents,
    :parent_check
  ) do
    def self.build(
      table_name:,
      mode:,
      tenant_column: nil,
      fk_columns: nil,
      parents: nil,
      parent_check: :trust_app
    )
      mode = mode.to_sym
      raise ArgumentError, "invalid mode: #{mode}" unless MODES.include?(mode)

      parent_check = parent_check.to_sym
      unless PARENT_CHECKS.include?(parent_check)
        raise ArgumentError, "invalid parent_check: #{parent_check}"
      end

      new(
        table_name: table_name.to_sym,
        mode: mode,
        tenant_column: tenant_column&.to_sym,
        fk_columns: fk_columns&.map(&:to_sym)&.freeze,
        parents: parents&.map(&:to_sym)&.freeze,
        parent_check: parent_check
      )
    end

    def root?
      mode == :root
    end

    def direct?
      mode == :direct
    end

    def fk?
      mode == :fk
    end

    def hybrid?
      mode == :hybrid
    end

    def requires_tenant_column?
      mode == :root || mode == :direct || mode == :hybrid
    end

    def requires_fk?
      mode == :fk || mode == :hybrid
    end
  end
end
