# frozen_string_literal: true

require "support/tool_adapter_helpers"

RSpec.describe Axn::Tools do
  before { Axn::Tools::Registry.reset_adapters! }
  after { Axn::Tools::Registry.reset_adapters! }

  describe ".register_adapter / .adapters" do
    it "registers keys and reports them" do
      described_class.register_adapter(:mcp)
      described_class.register_adapter(:ruby_llm)

      expect(described_class.adapters).to contain_exactly(:mcp, :ruby_llm)
    end

    it "keeps an already-supplied config source on a re-registration with no source" do
      source = register_adapter_with_roots(:mcp, roots: ["agent_tools"])
      described_class.register_adapter(:mcp)

      expect(Axn::Tools::Registry.adapter_config_source(:mcp)).to eq(source)
    end
  end

  describe ".for" do
    it "returns the adapter's member classes" do
      described_class.register_adapter(:mcp)
      tool_class = stub_const("ToolsFacadeSpec::Member", Class.new do
        include Axn
        tool :mcp
      end)

      expect(described_class.for(:mcp)).to include(tool_class)
    end

    it "accepts a String adapter key" do
      described_class.register_adapter(:mcp)

      expect { described_class.for("mcp") }.not_to raise_error
    end

    it "raises for an unregistered adapter, naming what is registered" do
      described_class.register_adapter(:mcp)

      expect { described_class.for(:nope) }
        .to raise_error(ArgumentError, /:nope is not a registered tool adapter \(registered: \[:mcp\]\)/)
    end

    it "forwards all_versions: to the registry" do
      described_class.register_adapter(:mcp)
      allow(Axn::Tools::Registry).to receive(:members).and_return([])

      described_class.for(:mcp, all_versions: true)

      expect(Axn::Tools::Registry).to have_received(:members).with(:mcp, all_versions: true)
    end
  end

  describe ".versions" do
    it "returns the version group for a tool_name" do
      described_class.register_adapter(:mcp)
      solo = stub_const("ToolsFacadeSpec::Solo", Class.new do
        include Axn
        tool :mcp
      end)

      expect(described_class.versions(:mcp, solo.tool_name(:mcp)).all).to eq([solo])
    end

    it "returns nil for an unknown tool_name" do
      described_class.register_adapter(:mcp)

      expect(described_class.versions(:mcp, "nope")).to be_nil
    end

    it "raises for an unregistered adapter" do
      expect { described_class.versions(:nope, "x") }.to raise_error(ArgumentError, /not a registered tool adapter/)
    end
  end

  it "keeps the adapter guard private" do
    expect(described_class).not_to respond_to(:_registered_adapter!)
  end
end
