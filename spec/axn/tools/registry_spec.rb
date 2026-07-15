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

  describe ".member?" do
    before { Axn.register_tool_adapter(:mcp) }

    it "explicit `tool :mcp` is a member for :mcp but not :ruby_llm" do
      Axn.register_tool_adapter(:ruby_llm)
      k = stub_const("MemberSpec::Explicit", Class.new do
        include Axn
        tool :mcp
      end)
      expect(described_class.member?(k, :mcp)).to be(true)
      expect(described_class.member?(k, :ruby_llm)).to be(false)
    end

    it "bare `tool` is a member for every adapter" do
      Axn.register_tool_adapter(:ruby_llm)
      k = stub_const("MemberSpec::All", Class.new do
        include Axn
        tool
      end)
      expect(described_class.member?(k, :mcp)).to be(true)
      expect(described_class.member?(k, :ruby_llm)).to be(true)
    end

    it "`tool false` is never a member, even under a tool path" do
      allow(Axn.config).to receive(:tool_paths).and_return([File.expand_path("spec")])
      k = stub_const("MemberSpec::OptOut", Class.new do
        include Axn
        tool false
      end)
      allow(Object).to receive(:const_source_location).with("MemberSpec::OptOut")
                                                      .and_return([File.expand_path("spec/dummy.rb"), 1])
      expect(described_class.member?(k, :mcp)).to be(false)
    end

    it "an undeclared class whose source is under a tool_path auto-registers for all adapters" do
      Axn.register_tool_adapter(:ruby_llm)
      allow(Axn.config).to receive(:tool_paths).and_return([File.expand_path("spec")])
      k = stub_const("MemberSpec::AutoReg", Class.new { include Axn })
      allow(Object).to receive(:const_source_location).with("MemberSpec::AutoReg")
                                                      .and_return([File.expand_path("spec/some_tool.rb"), 1])
      expect(described_class.member?(k, :mcp)).to be(true)
      expect(described_class.member?(k, :ruby_llm)).to be(true)
    end

    it "an undeclared class outside every tool_path is not a member" do
      allow(Axn.config).to receive(:tool_paths).and_return([File.expand_path("spec")])
      k = stub_const("MemberSpec::Outside", Class.new { include Axn })
      allow(Object).to receive(:const_source_location).with("MemberSpec::Outside")
                                                      .and_return(["/somewhere/else/x.rb", 1])
      expect(described_class.member?(k, :mcp)).to be(false)
    end

    it "a class with `configure(:mcp)` is an implicit member for :mcp only" do
      Axn.register_tool_adapter(:ruby_llm)
      allow(Axn.config).to receive(:tool_paths).and_return([])
      k = stub_const("MemberSpec::ConfigNS", Class.new do
        include Axn
        configure(:mcp) { |c| c.some_setting = 1 }
      end)
      allow(Object).to receive(:const_source_location).and_return(nil)
      expect(described_class.member?(k, :mcp)).to be(true)
      expect(described_class.member?(k, :ruby_llm)).to be(false)
    end
  end
end
