# frozen_string_literal: true

module RegistryHelpers
  # Build a Registry directly from a policies hash — bypasses Manifest::Builder.
  def build_registry(policies, skipped: {})
    lock = {
      "schema_digest" => "x",
      "source_digest" => "x",
      "policies" => policies.transform_keys(&:to_s).transform_values do |p|
        p.transform_keys(&:to_s)
      end,
      "skipped" => {
        "explicit" => Array(skipped[:explicit]).map(&:to_s),
        "automatic" => Array(skipped[:automatic]).map(&:to_s),
        "unreachable" => Array(skipped[:unreachable]).map(&:to_s)
      }
    }
    StrongMultiTenant::Registry.from_lock(lock)
  end

  def analyzer_for(policies, skipped: {})
    registry = build_registry(policies, skipped: skipped)
    StrongMultiTenant::Analyzer.new(registry: registry)
  end
end

RSpec.configure do |config|
  config.include RegistryHelpers
end
