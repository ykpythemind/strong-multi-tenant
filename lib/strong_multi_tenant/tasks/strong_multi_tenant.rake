# frozen_string_literal: true

require "digest"

namespace :strong_multi_tenant do
  desc "Build config/strong_multi_tenant.lock.yml from config/strong_multi_tenant.yml + schema"
  task build: :environment do
    lock_hash = StrongMultiTenant::Rake.build_lock
    path = StrongMultiTenant::Rake.lock_path
    File.write(path, StrongMultiTenant::Manifest.dump_lock(lock_hash))
    puts "Wrote #{path}"
  end

  desc "Verify that config/strong_multi_tenant.lock.yml is up-to-date (CI drift check)"
  task check: :environment do
    fresh = StrongMultiTenant::Rake.build_lock
    path = StrongMultiTenant::Rake.lock_path
    unless File.exist?(path)
      warn "missing #{path} — run `rake strong_multi_tenant:build`"
      exit 1
    end
    existing = StrongMultiTenant::Manifest.load_lock(path)
    if existing == fresh
      puts "lock is up-to-date"
    else
      warn "lock drifts from manifest/schema — run `rake strong_multi_tenant:build`"
      exit 1
    end
  end
end

module StrongMultiTenant
  module Rake
    module_function

    def manifest_path
      path = Rails.application.config.strong_multi_tenant.manifest_path
      path || Rails.root.join("config/strong_multi_tenant.yml").to_s
    end

    def lock_path
      path = Rails.application.config.strong_multi_tenant.lock_path
      path || Rails.root.join("config/strong_multi_tenant.lock.yml").to_s
    end

    def schema_path
      path = Rails.application.config.strong_multi_tenant.schema_path
      path || Rails.root.join("db/schema.rb").to_s
    end

    def build_lock
      source = StrongMultiTenant::Manifest::Source.load_file(manifest_path)
      reader = StrongMultiTenant::Manifest::SchemaReader.from_connection
      digest = StrongMultiTenant::Manifest.schema_digest_from_file(schema_path)
      StrongMultiTenant::Manifest::Builder.build(
        source: source,
        schema_reader: reader,
        schema_digest: digest
      )
    end
  end
end
