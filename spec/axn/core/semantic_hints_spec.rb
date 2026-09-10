# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Axn semantic_hints" do
  after { Axn::Extensions.instance_variable_set(:@config, nil) }

  it "defaults to an empty array" do
    klass = Class.new { include Axn }
    expect(klass.semantic_hints).to eq([])
  end

  it "stores validated core-vocabulary hints" do
    klass = Class.new do
      include Axn
      semantic_hints :read_only, :idempotent
    end
    expect(klass.semantic_hints).to contain_exactly(:read_only, :idempotent)
  end

  it "rejects unknown hints" do
    expect do
      Class.new do
        include Axn
        semantic_hints :wat
      end
    end.to raise_error(ArgumentError, /unknown semantic hint.*:wat/i)
  end

  it "accepts adapter-registered vocabulary" do
    Axn::Extensions.config.register_semantic_hint(:open_world)
    klass = Class.new do
      include Axn
      semantic_hints :open_world
    end
    expect(klass.semantic_hints).to eq([:open_world])
  end

  # The regression this closes: `semantic_hints [:read_only, :idempotent]` (an Array handed to the
  # splat instead of two Symbols) used to reach `.to_sym` on the Array itself and raise a bare
  # `NoMethodError` rather than naming the actual mistake.
  it "rejects an Array handed to the splat instead of variadic Symbols" do
    expect do
      Class.new do
        include Axn
        semantic_hints [:read_only]
      end
    end.to raise_error(ArgumentError, /semantic_hints must be Symbols or Strings/)
  end

  it "rejects a non-Symbol, non-String value" do
    expect do
      Class.new do
        include Axn
        semantic_hints 42
      end
    end.to raise_error(ArgumentError, /semantic_hints must be Symbols or Strings/)
  end

  it "accepts Strings" do
    klass = Class.new do
      include Axn
      semantic_hints "read_only"
    end
    expect(klass.semantic_hints).to eq([:read_only])
  end

  it "inherits hints and lets a subclass replace them" do
    parent = Class.new do
      include Axn
      semantic_hints :read_only
    end
    child = Class.new(parent)
    expect(child.semantic_hints).to eq([:read_only])
    child.semantic_hints :destructive
    expect(child.semantic_hints).to eq([:destructive])
    expect(parent.semantic_hints).to eq([:read_only])
  end
end
