# frozen_string_literal: true

Rails.application.config.strong_multi_tenant.tap do |c|
  # :raise (default) — boot fails if lock drifts from manifest/schema.
  # :warn           — warn and boot anyway (production soft-rollout).
  c.digest_mismatch_mode = Rails.env.production? ? :warn : :raise

  # c.manifest_path = Rails.root.join("config/strong_multi_tenant.yml")
  # c.lock_path     = Rails.root.join("config/strong_multi_tenant.lock.yml")
  # c.schema_path   = Rails.root.join("db/schema.rb")
  # c.enabled       = true
end
