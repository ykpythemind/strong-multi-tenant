# frozen_string_literal: true

require "spec_helper"

RSpec.describe StrongMultiTenant::Current do
  it "defaults to no bypass / empty allow_no_where set" do
    described_class.reset
    expect(described_class.bypass?).to be false
    expect(described_class.allow_no_where_tables).to be_empty
  end

  it "allow_no_where? coerces symbol" do
    described_class.reset
    described_class.allow_no_where_tables = Set.new([:posts])
    expect(described_class.allow_no_where?("posts")).to be true
    expect(described_class.allow_no_where?(:comments)).to be false
  end
end

RSpec.describe StrongMultiTenant, ".bypass / .with_tenant / .allow_no_where" do
  it "bypass toggles only within the block" do
    StrongMultiTenant.bypass do
      expect(StrongMultiTenant::Current.bypass?).to be true
    end
    expect(StrongMultiTenant::Current.bypass?).to be false
  end

  it "with_tenant restores prior tenant_id" do
    StrongMultiTenant::Current.tenant_id = 5
    StrongMultiTenant.with_tenant(99) do
      expect(StrongMultiTenant::Current.tenant_id).to eq 99
    end
    expect(StrongMultiTenant::Current.tenant_id).to eq 5
  end

  it "allow_no_where stacks correctly" do
    StrongMultiTenant.allow_no_where(:a) do
      StrongMultiTenant.allow_no_where(:b) do
        expect(StrongMultiTenant::Current.allow_no_where?(:a)).to be true
        expect(StrongMultiTenant::Current.allow_no_where?(:b)).to be true
      end
      expect(StrongMultiTenant::Current.allow_no_where?(:b)).to be false
    end
    expect(StrongMultiTenant::Current.allow_no_where?(:a)).to be false
  end
end
