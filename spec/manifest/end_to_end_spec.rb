# frozen_string_literal: true

require "spec_helper"
require "tempfile"

RSpec.describe "Manifest end-to-end (YAML → lock → Registry → Analyzer)" do
  let(:schema) do
    StrongMultiTenant::Manifest::StaticSchemaReader.new(
      tables: %w[organizations posts comments],
      foreign_keys: [
        { from_table: "posts", to_table: "organizations", column: "organization_id" },
        { from_table: "comments", to_table: "posts", column: "post_id" }
      ],
      columns: {
        "organizations" => %w[id],
        "posts" => %w[id organization_id],
        "comments" => %w[id post_id]
      },
      primary_keys: { "organizations" => "id", "posts" => "id", "comments" => "id" }
    )
  end

  it "drives an analyzer via Manifest::Builder output" do
    yml = <<~YAML
      roots: [organizations]
      direct: { posts: organization_id }
    YAML
    source = StrongMultiTenant::Manifest::Source.new(yml)
    lock = StrongMultiTenant::Manifest::Builder.build(source: source, schema_reader: schema)

    registry = StrongMultiTenant::Registry.from_lock(lock)
    analyzer = StrongMultiTenant::Analyzer.new(registry: registry)

    StrongMultiTenant::Current.tenant_id = 42

    expect(analyzer.analyze("SELECT * FROM posts WHERE organization_id = 42")).to be_ok
    expect(analyzer.analyze("SELECT * FROM comments WHERE post_id = 1")).to be_ok
    expect(analyzer.analyze("SELECT * FROM posts WHERE organization_id = 99").ok?).to be false
    expect(analyzer.analyze("SELECT * FROM comments").ok?).to be false # NoWhere
  end

  it "serializes and re-loads lock identically" do
    yml = "roots: [organizations]\ndirect: { posts: organization_id }\n"
    source = StrongMultiTenant::Manifest::Source.new(yml)
    lock = StrongMultiTenant::Manifest::Builder.build(source: source, schema_reader: schema)

    file = Tempfile.new(["lock", ".yml"])
    file.write(StrongMultiTenant::Manifest.dump_lock(lock))
    file.close

    reloaded = StrongMultiTenant::Manifest.load_lock(file.path)
    expect(reloaded["policies"].keys).to include("organizations", "posts", "comments")
  ensure
    file&.unlink
  end
end
