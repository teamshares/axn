# frozen_string_literal: true

RSpec.describe Axn::Tools::Registry do
  before { described_class.reset_adapters! }
  after { described_class.reset_adapters! }

  describe "adapter registration" do
    it "registers and reports adapter keys" do
      Axn.register_tool_adapter(:mcp)
      Axn.register_tool_adapter(:ruby_llm)
      expect(described_class.adapters).to contain_exactly(:mcp, :ruby_llm)
    end

    it "is idempotent" do
      Axn.register_tool_adapter(:mcp)
      Axn.register_tool_adapter(:mcp)
      expect(described_class.adapters.to_a).to eq([:mcp])
    end

    it "coerces string keys to symbols" do
      Axn.register_tool_adapter("mcp")
      expect(described_class.adapters).to include(:mcp)
    end
  end

  describe "global class tracking" do
    it "records every include-Axn class" do
      klass = stub_const("RegistrySpec::Recorded", Class.new { include Axn })
      expect(described_class.all_classes).to include(klass)
    end

    it "excludes anonymous classes" do
      anon = Class.new { include Axn }
      expect(described_class.all_classes).not_to include(anon)
    end
  end

  describe "Axn.tools_for validation" do
    it "raises for an unregistered adapter" do
      expect { Axn.tools_for(:nope) }.to raise_error(ArgumentError, /not a registered tool adapter/)
    end
  end
end
