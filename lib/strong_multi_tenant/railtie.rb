# frozen_string_literal: true

require "rails/railtie"

module StrongMultiTenant
  class Railtie < ::Rails::Railtie
    config.strong_multi_tenant = ActiveSupport::OrderedOptions.new
    config.strong_multi_tenant.digest_mismatch_mode = :raise # :raise | :warn
    config.strong_multi_tenant.manifest_path = nil            # defaults to config/strong_multi_tenant.yml
    config.strong_multi_tenant.lock_path = nil                # defaults to config/strong_multi_tenant.lock.yml
    config.strong_multi_tenant.schema_path = nil              # defaults to db/schema.rb
    config.strong_multi_tenant.enabled = true

    rake_tasks do
      load File.expand_path("tasks/strong_multi_tenant.rake", __dir__)
    end

    initializer "strong_multi_tenant.load", after: :load_config_initializers do |app|
      settings = app.config.strong_multi_tenant
      next unless settings.enabled

      manifest_path = settings.manifest_path || app.root.join("config/strong_multi_tenant.yml").to_s
      lock_path = settings.lock_path || app.root.join("config/strong_multi_tenant.lock.yml").to_s
      schema_path = settings.schema_path || app.root.join("db/schema.rb").to_s

      StrongMultiTenant.boot!(
        manifest_path: manifest_path,
        lock_path: lock_path,
        schema_path: schema_path,
        digest_mismatch_mode: settings.digest_mismatch_mode,
        env: Rails.env
      )
    end

    initializer "strong_multi_tenant.prepend_adapter" do
      ActiveSupport.on_load(:active_record_postgresqladapter) do
        prepend StrongMultiTenant::AdapterGuard
      end
    end
  end
end
