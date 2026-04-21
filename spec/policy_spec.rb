# frozen_string_literal: true

require "spec_helper"

RSpec.describe StrongMultiTenant::Policy do
  it "builds a root policy" do
    p = described_class.build(table_name: "organizations", mode: "root", tenant_column: "id")
    expect(p.root?).to be true
    expect(p.tenant_column).to eq :id
  end

  it "builds a fk policy with fk_columns/parents" do
    p = described_class.build(
      table_name: "comments", mode: "fk",
      fk_columns: ["post_id"], parents: ["posts"]
    )
    expect(p.fk?).to be true
    expect(p.fk_columns).to eq [:post_id]
    expect(p.parents).to eq [:posts]
    expect(p.parent_check).to eq :trust_app
  end

  it "rejects invalid mode" do
    expect {
      described_class.build(table_name: "x", mode: "bogus")
    }.to raise_error(ArgumentError, /invalid mode/)
  end

  it "rejects invalid parent_check" do
    expect {
      described_class.build(table_name: "x", mode: "fk", fk_columns: ["y"], parents: ["z"], parent_check: "weird")
    }.to raise_error(ArgumentError, /invalid parent_check/)
  end
end
