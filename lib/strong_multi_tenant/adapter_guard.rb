# frozen_string_literal: true

require "active_support/notifications"

module StrongMultiTenant
  # Module prepended onto PostgreSQLAdapter. Intercepts SQL before it reaches
  # the DB and runs it through Analyzer.
  module AdapterGuard
    class << self
      attr_accessor :analyzer, :enabled

      def enabled?
        !!@enabled
      end

      def install!(analyzer)
        @analyzer = analyzer
        @enabled = true
      end

      def disable!
        @enabled = false
      end
    end

    def internal_exec_query(sql, name = nil, binds = [], **opts)
      StrongMultiTenant::AdapterGuard.guard!(sql, extract_bind_values(binds))
      super
    end

    def exec_query(sql, name = nil, binds = [], **opts)
      StrongMultiTenant::AdapterGuard.guard!(sql, extract_bind_values(binds))
      super
    end

    def exec_update(sql, name = nil, binds = [])
      StrongMultiTenant::AdapterGuard.guard!(sql, extract_bind_values(binds))
      super
    end

    def exec_delete(sql, name = nil, binds = [])
      StrongMultiTenant::AdapterGuard.guard!(sql, extract_bind_values(binds))
      super
    end

    def exec_insert(sql, name = nil, binds = [], *args, **kwargs)
      StrongMultiTenant::AdapterGuard.guard!(sql, extract_bind_values(binds))
      super
    end

    def execute(sql, name = nil, **opts)
      StrongMultiTenant::AdapterGuard.guard!(sql, [])
      super
    end

    class << self
      def guard!(sql, binds)
        return unless enabled?
        return if @analyzer.nil?
        return if StrongMultiTenant::Current.bypass?

        result = @analyzer.analyze(sql, binds: binds)
        return if result.ok?

        instrument_violation(sql, result)

        exc_class = case result.kind
                    when :no_where then NoWhereViolation
                    when :tenant then TenantViolation
                    else Violation
                    end
        raise exc_class.new(
          result.message || "strong_multi_tenant violation",
          sql: sql,
          table: result.table,
          reason: result.reason,
          tenant_context: {
            tenant_id: StrongMultiTenant::Current.tenant_id,
            bypass: StrongMultiTenant::Current.bypass?
          }
        )
      end

      def instrument_violation(sql, result)
        ActiveSupport::Notifications.instrument(
          "strong_multi_tenant.violation",
          sql: sql,
          kind: result.kind,
          table: result.table,
          reason: result.reason,
          message: result.message,
          tenant_id: StrongMultiTenant::Current.tenant_id
        )
      end
    end

    private

    def extract_bind_values(binds)
      return [] unless binds
      binds.map do |b|
        if b.respond_to?(:value_for_database)
          b.value_for_database
        elsif b.respond_to?(:value)
          b.value
        else
          b
        end
      end
    rescue StandardError
      []
    end
  end
end
