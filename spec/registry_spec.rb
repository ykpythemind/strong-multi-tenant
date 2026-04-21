# frozen_string_literal: true

require "spec_helper"

RSpec.describe StrongMultiTenant::Registry do
  let(:lock) do
    {
      "source_digest" => "abc",
      "schema_digest" => "def",
      "policies" => {
        "organizations" => { "mode" => "root", "tenant_column" => "id" },
        "posts" => { "mode" => "direct", "tenant_column" => "organization_id" },
        "comments" => {
          "mode" => "fk", "fk_columns" => ["post_id"], "parents" => ["posts"],
          "parent_check" => "trust_app"
        }
      },
      "skipped" => {
        "explicit" => ["active_storage_blobs"],
        "automatic" => ["schema_migrations"],
        "unreachable" => ["countries"]
      }
    }
  end

  it "loads policies and skipped tables" do
    r = described_class.from_lock(lock)
    expect(r.lookup(:posts).tenant_column).to eq :organization_id
    expect(r.lookup(:comments).fk_columns).to eq [:post_id]
    expect(r.skipped?(:countries)).to be true
    expect(r.skipped?(:active_storage_blobs)).to be true
    expect(r.skipped?(:posts)).to be false
  end

  it "exposes digests" do
    r = described_class.from_lock(lock)
    expect(r.source_digest).to eq "abc"
    expect(r.schema_digest).to eq "def"
  end
end
