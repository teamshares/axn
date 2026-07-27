# frozen_string_literal: true

RSpec.describe Axn::Tools::VersionGroup do
  # Minimal stand-ins: the group only reads tool_version.
  def member(version)
    Class.new do
      include Axn
      tool_version(version)
    end
  end

  def group(members)
    described_class.new(adapter: :mcp, tool_name: "approve_loan", members:)
  end

  it "sorts .all ascending by version regardless of input order" do
    v1 = member(1)
    v3 = member(3)
    g = group([v3, v1])
    expect(g.all).to eq([v1, v3])
  end

  it ".latest is the highest version" do
    v1 = member(1)
    v3 = member(3)
    expect(group([v1, v3]).latest).to eq(v3)
  end

  it "tolerates version gaps" do
    v1 = member(1)
    v3 = member(3)
    g = group([v1, v3])
    expect(g.all).to eq([v1, v3])
    expect(g.latest).to eq(v3)
  end

  it "raises on a duplicate (tool_name, version)" do
    a = member(2)
    b = member(2)
    expect { group([a, b]) }.to raise_error(ArgumentError, /v2/)
  end
end
