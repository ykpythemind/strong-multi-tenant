# frozen_string_literal: true

require "spec_helper"

RSpec.describe StrongMultiTenant::Manifest::Builder do
  def schema_for(tables:, fks:, columns:)
    StrongMultiTenant::Manifest::StaticSchemaReader.new(
      tables: tables,
      foreign_keys: fks,
      columns: columns,
      primary_keys: tables.map { |t| [t, "id"] }.to_h
    )
  end

  it "expands root → direct → fk via BFS" do
    schema = schema_for(
      tables: %w[organizations posts comments countries schema_migrations],
      fks: [
        { from_table: "posts", to_table: "organizations", column: "organization_id" },
        { from_table: "comments", to_table: "posts", column: "post_id" }
      ],
      columns: {
        "organizations" => %w[id name],
        "posts" => %w[id organization_id title],
        "comments" => %w[id post_id body],
        "countries" => %w[id code],
        "schema_migrations" => %w[version]
      }
    )
    yml = <<~YAML
      roots: [organizations]
      direct: { posts: organization_id }
    YAML
    source = StrongMultiTenant::Manifest::Source.new(yml)
    lock = described_class.build(source: source, schema_reader: schema)

    expect(lock["policies"]["organizations"]["mode"]).to eq "root"
    expect(lock["policies"]["posts"]["mode"]).to eq "direct"
    expect(lock["policies"]["comments"]).to include("mode" => "fk")
    expect(lock["policies"]["comments"]["fk_columns"]).to eq ["post_id"]
    expect(lock["policies"]["comments"]["parents"]).to eq ["posts"]

    expect(lock["skipped"]["unreachable"]).to include("countries")
    expect(lock["skipped"]["automatic"]).to include("schema_migrations")
  end

  it "promotes a derived table with denormalized tenant_column to :hybrid" do
    schema = schema_for(
      tables: %w[organizations posts comment_reports comments],
      fks: [
        { from_table: "posts", to_table: "organizations", column: "organization_id" },
        { from_table: "comments", to_table: "posts", column: "post_id" },
        { from_table: "comment_reports", to_table: "comments", column: "comment_id" }
      ],
      columns: {
        "organizations" => %w[id],
        "posts" => %w[id organization_id],
        "comments" => %w[id post_id],
        "comment_reports" => %w[id comment_id organization_id]
      }
    )
    yml = <<~YAML
      roots: [organizations]
      direct: { posts: organization_id }
    YAML
    source = StrongMultiTenant::Manifest::Source.new(yml)
    lock = described_class.build(source: source, schema_reader: schema)

    expect(lock["policies"]["comment_reports"]["mode"]).to eq "hybrid"
    expect(lock["policies"]["comment_reports"]["tenant_column"]).to eq "organization_id"
    expect(lock["policies"]["comment_reports"]["fk_columns"]).to eq ["comment_id"]
  end

  it "stops on self-referencing FK without infinite loop" do
    schema = schema_for(
      tables: %w[organizations tree_nodes],
      fks: [
        { from_table: "tree_nodes", to_table: "organizations", column: "organization_id" },
        { from_table: "tree_nodes", to_table: "tree_nodes", column: "parent_id" }
      ],
      columns: {
        "organizations" => %w[id],
        "tree_nodes" => %w[id organization_id parent_id]
      }
    )
    yml = "roots: [organizations]\n"
    source = StrongMultiTenant::Manifest::Source.new(yml)
    expect {
      described_class.build(source: source, schema_reader: schema)
    }.not_to raise_error
  end

  it "accumulates multiple fk_columns/parents when child points to several tenant tables" do
    schema = schema_for(
      tables: %w[organizations posts articles attachments],
      fks: [
        { from_table: "posts", to_table: "organizations", column: "organization_id" },
        { from_table: "articles", to_table: "organizations", column: "organization_id" },
        { from_table: "attachments", to_table: "posts", column: "post_id" },
        { from_table: "attachments", to_table: "articles", column: "article_id" }
      ],
      columns: {
        "organizations" => %w[id],
        "posts" => %w[id organization_id],
        "articles" => %w[id organization_id],
        "attachments" => %w[id post_id article_id]
      }
    )
    yml = <<~YAML
      roots: [organizations]
      direct: { posts: organization_id, articles: organization_id }
    YAML
    source = StrongMultiTenant::Manifest::Source.new(yml)
    lock = described_class.build(source: source, schema_reader: schema)

    attach = lock["policies"]["attachments"]
    expect(attach["mode"]).to eq "fk"
    expect(attach["fk_columns"]).to match_array(%w[post_id article_id])
    expect(attach["parents"]).to match_array(%w[posts articles])
  end

  it "marks explicit skip tables as skipped.explicit" do
    schema = schema_for(
      tables: %w[organizations active_storage_blobs],
      fks: [],
      columns: { "organizations" => %w[id], "active_storage_blobs" => %w[id] }
    )
    yml = <<~YAML
      roots: [organizations]
      skip: [active_storage_blobs]
    YAML
    source = StrongMultiTenant::Manifest::Source.new(yml)
    lock = described_class.build(source: source, schema_reader: schema)

    expect(lock["skipped"]["explicit"]).to eq ["active_storage_blobs"]
    expect(lock["policies"]).not_to have_key("active_storage_blobs")
  end
end
