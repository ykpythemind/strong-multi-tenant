# frozen_string_literal: true

# Include into ApplicationController (or a base controller) so Current.tenant_id
# is set per request. Customize `current_tenant_id` to your auth scheme.
module StrongMultiTenantContext
  extend ActiveSupport::Concern

  included do
    before_action :set_strong_multi_tenant_current
  end

  private

  def set_strong_multi_tenant_current
    StrongMultiTenant::Current.tenant_id = current_tenant_id
  end

  def current_tenant_id
    # Example: current_user&.organization_id
    raise NotImplementedError, "override current_tenant_id"
  end
end
