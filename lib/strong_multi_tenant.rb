# frozen_string_literal: true

require "active_support"
require "active_support/notifications"

require_relative "strong_multi_tenant/version"
require_relative "strong_multi_tenant/current"
require_relative "strong_multi_tenant/policy"
require_relative "strong_multi_tenant/violation"
require_relative "strong_multi_tenant/manifest"
require_relative "strong_multi_tenant/registry"
require_relative "strong_multi_tenant/analyzer"
require_relative "strong_multi_tenant/adapter_guard"

module StrongMultiTenant
  class << self
    attr_accessor :registry, :analyzer

    # Block-scoped: disable ALL guard checks (tenant + NoWhere).
    def bypass
      prev = Current.bypass
      Current.bypass = true
      yield
    ensure
      Current.bypass = prev
    end

    # Block-scoped: replace tenant_id for the duration of the block.
    def with_tenant(tenant_id)
      prev = Current.tenant_id
      Current.tenant_id = tenant_id
      yield
    ensure
      Current.tenant_id = prev
    end

    # Block-scoped: allow NoWhere on one or more tables. Tenant checks still apply.
    def allow_no_where(*tables)
      prev = Current.allow_no_where_tables.dup
      Current.allow_no_where_tables = prev + tables.flatten.map(&:to_sym)
      yield
    ensure
      Current.allow_no_where_tables = prev
    end

    # Wire up the guard. Called from Railtie at boot, or directly in non-Rails usage.
    def boot!(manifest_path:, lock_path:, schema_path: nil, digest_mismatch_mode: :raise, env: nil)
      unless File.exist?(manifest_path)
        raise ConfigurationError, "manifest not found: #{manifest_path} (run `rails g strong_multi_tenant:install`)"
      end
      unless File.exist?(lock_path)
        raise ConfigurationError, "lock file not found: #{lock_path} (run `rake strong_multi_tenant:build`)"
      end

      source = Manifest::Source.load_file(manifest_path)
      lock = Manifest.load_lock(lock_path)

      verify_digests!(source: source, lock: lock, schema_path: schema_path,
                      mode: digest_mismatch_mode, env: env)

      self.registry = Registry.from_lock(lock)
      self.analyzer = Analyzer.new(registry: registry)
      AdapterGuard.install!(analyzer)
    end

    def reset!
      self.registry = nil
      self.analyzer = nil
      AdapterGuard.disable!
    end

    private

    def verify_digests!(source:, lock:, schema_path:, mode:, env:)
      problems = []
      if lock["source_digest"] && lock["source_digest"] != source.digest
        problems << "strong_multi_tenant.yml changed since last build (source_digest mismatch)"
      end

      if schema_path && File.exist?(schema_path) && lock["schema_digest"]
        current_schema_digest = Manifest.schema_digest_from_file(schema_path)
        if current_schema_digest != lock["schema_digest"]
          problems << "db/schema.rb changed since last build (schema_digest mismatch)"
        end
      end

      return if problems.empty?

      msg = "strong_multi_tenant: #{problems.join("; ")} — run `rake strong_multi_tenant:build`"
      case mode
      when :warn
        warn msg
      else
        raise StaleLockError, msg
      end
    end
  end
end

require_relative "strong_multi_tenant/railtie" if defined?(Rails::Railtie)
