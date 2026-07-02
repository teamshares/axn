# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Axn extension_metadata" do
  it "returns an empty hash when unset" do
    klass = Class.new { include Axn }
    expect(klass.extension_metadata(:mcp)).to eq({})
  end

  it "stores per-adapter metadata and merges on repeat" do
    klass = Class.new { include Axn }
    klass.set_extension_metadata(:mcp, title: "T")
    klass.set_extension_metadata(:mcp, annotations: { read_only_hint: true })
    expect(klass.extension_metadata(:mcp)).to eq(title: "T", annotations: { read_only_hint: true })
    expect(klass.extension_metadata(:ruby_llm)).to eq({})
  end

  it "inherits metadata without mutating the parent (copy-on-write)" do
    parent = Class.new { include Axn }
    parent.set_extension_metadata(:mcp, title: "parent")
    child = Class.new(parent)
    child.set_extension_metadata(:mcp, title: "child")
    expect(child.extension_metadata(:mcp)).to eq(title: "child")
    expect(parent.extension_metadata(:mcp)).to eq(title: "parent")
  end

  it "does not leak mutation of the returned hash into the stored metadata (Bug W)" do
    klass = Class.new { include Axn }
    klass.set_extension_metadata(:mcp, title: "T")

    m = klass.extension_metadata(:mcp)
    m[:extra] = 1

    expect(klass.extension_metadata(:mcp)).to eq(title: "T")
  end
end
