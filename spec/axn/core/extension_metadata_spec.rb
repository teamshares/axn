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

  it "does not leak mutation of a nested Hash value into the stored metadata (Bug BB)" do
    klass = Class.new { include Axn }
    klass.set_extension_metadata(:mcp, annotations: { read_only_hint: true })

    m = klass.extension_metadata(:mcp)
    m[:annotations][:extra] = 1

    expect(klass.extension_metadata(:mcp)[:annotations]).to eq(read_only_hint: true)
  end

  it "does not leak mutation of a nested Array value into the stored metadata (Bug BB)" do
    klass = Class.new { include Axn }
    klass.set_extension_metadata(:mcp, tags: %w[a b])

    m = klass.extension_metadata(:mcp)
    m[:tags] << "c"

    expect(klass.extension_metadata(:mcp)[:tags]).to eq(%w[a b])
  end

  it "does not leak mutation of a String leaf value into the stored metadata (Bug II)" do
    klass = Class.new { include Axn }
    klass.set_extension_metadata(:mcp, title: "T")

    klass.extension_metadata(:mcp)[:title].upcase!

    expect(klass.extension_metadata(:mcp)[:title]).to eq("T")
  end

  it "preserves a Class-ref metadata value by identity (Bug BB — no Marshal/deep_dup)" do
    some_class = Struct.new(:foo)
    klass = Class.new { include Axn }
    klass.set_extension_metadata(:mcp, model: some_class)

    expect(klass.extension_metadata(:mcp)[:model]).to be(some_class)
  end
end
