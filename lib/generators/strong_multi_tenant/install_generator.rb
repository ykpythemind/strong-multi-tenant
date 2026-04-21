# frozen_string_literal: true

require "rails/generators"

module StrongMultiTenant
  module Generators
    class InstallGenerator < ::Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      desc "Install strong_multi_tenant config files"

      def create_manifest
        template "strong_multi_tenant.yml", "config/strong_multi_tenant.yml"
      end

      def create_initializer
        template "strong_multi_tenant.rb", "config/initializers/strong_multi_tenant.rb"
      end

      def create_controller_concern
        template "strong_multi_tenant_context.rb", "app/controllers/concerns/strong_multi_tenant_context.rb"
      end

      def say_next_steps
        say <<~MSG

          strong_multi_tenant installed.

          Next:
            1. Edit config/strong_multi_tenant.yml (roots / direct / skip)
            2. Run: rake strong_multi_tenant:build  (generates config/strong_multi_tenant.lock.yml)
            3. Commit both files.
            4. In ApplicationController, include StrongMultiTenantContext to set Current.tenant_id.

        MSG
      end
    end
  end
end
