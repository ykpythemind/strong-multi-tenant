# frozen_string_literal: true

require "spec_helper"

RSpec.describe StrongMultiTenant::Manifest::Source do
  let(:schema) do
    StrongMultiTenant::Manifest::StaticSchemaReader.new(
      tables: %w[organizations posts comments],
      foreign_keys: [
        { from_table: "posts", to_table: "organizations", column: "organization_id" },
        { from_table: "comments", to_table: "posts", column: "post_id" }
      ],
      columns: {
        "organizations" => %w[id name],
        "posts" => %w[id organization_id title],
        "comments" => %w[id post_id body]
      },
      primary_keys: { "organizations" => "id", "posts" => "id", "comments" => "id" }
    )
  end

  it "parses a valid manifest" do
    yml = <<~YAML
      roots:
        - organizations
      direct:
        posts: organization_id
      skip:
        - schema_migrations
    YAML

    src = described_class.new(yml)
    expect(src.roots).to eq ["organizations"]
    expect(src.direct).to eq("posts" => "organization_id")
    expect(src.skip).to eq ["schema_migrations"]
    expect(src.digest).to match(/\A[0-9a-f]+\z/)
  end

  it "rejects unknown top-level keys" do
    yml = "foo: 1\nroots: []\n"
    expect { described_class.new(yml) }.to raise_error(StrongMultiTenant::ConfigurationError, /unknown/)
  end

  it "rejects tables missing from schema" do
    yml = "roots: [missing]\n"
    src = described_class.new(yml)
    expect { src.validate_against_schema!(schema) }.to raise_error(StrongMultiTenant::ConfigurationError, /missing from schema/)
  end

  it "rejects direct table whose column is absent" do
    yml = "direct: { posts: tenant_id }\n"
    src = described_class.new(yml)
    expect { src.validate_against_schema!(schema) }.to raise_error(StrongMultiTenant::ConfigurationError, /column 'tenant_id'/)
  end

  it "rejects overlap between roots and direct" do
    yml = "roots: [posts]\ndirect: { posts: organization_id }\n"
    expect { described_class.new(yml) }.to raise_error(StrongMultiTenant::ConfigurationError, /both root and direct/)
  end

  it "raises NotImplementedError for non-trust_app parent_check" do
    yml = <<~YAML
      roots: [organizations]
      direct: { posts: organization_id }
      parent_check: { comments: runtime_exists }
    YAML
    src = described_class.new(yml)
    expect { src.validate_against_schema!(schema) }.to raise_error(NotImplementedError, /runtime_exists/)
  end
end
