# frozen_string_literal: true

require "active_support/current_attributes"
require "set"

module StrongMultiTenant
  class Current < ActiveSupport::CurrentAttributes
    attribute :tenant_id
    attribute :bypass
    attribute :allow_no_where_tables

    def bypass?
      !!bypass
    end

    def allow_no_where?(table)
      tables = allow_no_where_tables
      return false unless tables
      tables.include?(table.to_sym)
    end

    def allow_no_where_tables
      super || Set.new
    end
  end
end
