# frozen_string_literal: true

require_relative "lib/strong_multi_tenant/version"

Gem::Specification.new do |spec|
  spec.name = "strong_multi_tenant"
  spec.version = StrongMultiTenant::VERSION
  spec.authors = ["ykpythemind"]
  spec.email = ["ykpythemind@st.inc"]

  spec.summary = "Application-layer RLS enforcement for Rails + PostgreSQL"
  spec.description = "Parses every SQL statement with pg_query and raises if a tenant predicate is missing. Declarative YAML manifest, FK-graph derived lock file, no model DSL."
  spec.homepage = "https://github.com/ykpythemind/strong_multi_tenant"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage

  spec.files = Dir[
    "lib/**/*.rb",
    "lib/**/*.rake",
    "lib/generators/**/*",
    "README.md",
    "LICENSE.txt"
  ].reject { |f| File.directory?(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "activerecord", ">= 7.1"
  spec.add_dependency "activesupport", ">= 7.1"
  spec.add_dependency "pg_query", "~> 6.2"

  spec.add_development_dependency "pg", ">= 1.5"
  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "rspec-rails", "~> 7.0"
  spec.add_development_dependency "rake", "~> 13.0"
end
