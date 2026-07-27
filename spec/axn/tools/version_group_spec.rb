# frozen_string_literal: true

RSpec.describe Axn::Tools::VersionGroup do
  # Minimal stand-ins: the group only reads tool_version and _tool_version_default.
  def member(version, default: false)
    Class.new do
      include Axn
      tool_version(version, default:)
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

  it ".default is the earliest version when none is flagged" do
    v1 = member(1)
    v3 = member(3)
    expect(group([v3, v1]).default).to eq(v1)
  end

  it ".default is the flagged version when one declares default: true" do
    v1 = member(1)
    v2 = member(2, default: true)
    v3 = member(3)
    expect(group([v1, v2, v3]).default).to eq(v2)
  end

  it "tolerates version gaps" do
    v1 = member(1)
    v3 = member(3)
    g = group([v1, v3])
    expect(g.default).to eq(v1)
    expect(g.latest).to eq(v3)
  end

  it "raises on a duplicate (tool_name, version)" do
    a = member(2)
    b = member(2)
    expect { group([a, b]) }.to raise_error(ArgumentError, /v2/)
  end

  it "raises when more than one version is flagged default: true" do
    a = member(1, default: true)
    b = member(2, default: true)
    expect { group([a, b]) }.to raise_error(ArgumentError, /default/)
  end
end
