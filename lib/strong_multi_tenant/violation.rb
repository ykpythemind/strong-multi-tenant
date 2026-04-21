# frozen_string_literal: true

module StrongMultiTenant
  class Violation < StandardError
    attr_reader :sql, :table, :reason, :tenant_context

    def initialize(message = nil, sql: nil, table: nil, reason: nil, tenant_context: nil)
      super(message)
      @sql = sql
      @table = table
      @reason = reason
      @tenant_context = tenant_context
    end
  end

  class TenantViolation < Violation; end
  class NoWhereViolation < Violation; end
  class ParentTenantMismatch < Violation; end
  class ConfigurationError < Violation; end
  class StaleLockError < Violation; end
end
