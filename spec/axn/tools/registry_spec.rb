# frozen_string_literal: true

require "support/tool_adapter_helpers"

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

    it "stores an optional config source and exposes it" do
      source = Module.new
      Axn.register_tool_adapter(:mcp, source)
      expect(described_class.adapter_config_source(:mcp)).to be(source)
    end

    it "defaults the config source to nil" do
      Axn.register_tool_adapter(:mcp)
      expect(described_class.adapter_config_source(:mcp)).to be_nil
    end

    it "last registration wins for the same key" do
      first = Module.new
      second = Module.new
      Axn.register_tool_adapter(:mcp, first)
      Axn.register_tool_adapter(:mcp, second)
      expect(described_class.adapters.to_a).to eq([:mcp])
      expect(described_class.adapter_config_source(:mcp)).to be(second)
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

    it "records a subclass of an Axn base (the ApplicationAction inheritance pattern)" do
      base = stub_const("RegistrySpec::AppAction", Class.new { include Axn })
      sub = stub_const("RegistrySpec::AppActionSub", Class.new(base))
      expect(described_class.all_classes).to include(sub)
    end

    it "records a deeply-nested subclass chain" do
      base = stub_const("RegistrySpec::DeepBase", Class.new { include Axn })
      mid = stub_const("RegistrySpec::DeepMid", Class.new(base))
      leaf = stub_const("RegistrySpec::DeepLeaf", Class.new(mid))
      expect(described_class.all_classes).to include(mid, leaf)
    end

    it "contains no duplicates when a class is reached via multiple registration paths" do
      klass = stub_const("RegistrySpec::DoubleReg", Class.new { include Axn })
      # Simulate a second path reaching the same class (e.g. include + inherited).
      described_class.register_class(klass)
      expect(described_class.all_classes.count(klass)).to eq(1)
    end

    it "excludes a stale reference whose name now resolves to a different (live) class" do
      class_a = Class.new { include Axn }
      stub_const("PruneSpec::Thing", class_a)
      described_class.register_class(class_a)

      class_b = Class.new { include Axn }
      stub_const("PruneSpec::Thing", class_b)
      described_class.register_class(class_b)

      # "PruneSpec::Thing" now resolves to class_b, so class_a is stale and pruned.
      expect(described_class.all_classes).to include(class_b)
      expect(described_class.all_classes).not_to include(class_a)
    end
  end

  describe "pruning without autoloading" do
    let(:probe_path) { File.expand_path("../../support/fixtures/autoload_probe.rb", __dir__) }
    let(:injected) { [] }

    before do
      ENV.delete("AXN_AUTOLOAD_PROBE_LOADED")
      Object.const_set(:AutoloadProbe, Module.new) unless Object.const_defined?(:AutoloadProbe, false)
      # Register a real, still-pending autoload for AutoloadProbe::Thing.
      AutoloadProbe.autoload(:Thing, probe_path)
    end

    after do
      Object.send(:remove_const, :AutoloadProbe) if Object.const_defined?(:AutoloadProbe, false)
      ENV.delete("AXN_AUTOLOAD_PROBE_LOADED")
      # Drop the stale entries we injected so they can't leak into other examples. (Their name stub
      # is already torn down here, so match by object identity rather than by name.)
      injected.each { |k| described_class.send(:_classes).delete(k) }
    end

    # A stale class whose #name matches the pending autoload target, held in _classes.
    def stale_named_class
      Class.new { include Axn }.tap do |k|
        allow(k).to receive(:name).and_return("AutoloadProbe::Thing")
        injected << k
      end
    end

    it "does not trigger a pending autoload when deciding staleness (_currently_defined?)" do
      stale = stale_named_class

      expect(described_class.send(:_currently_defined?, stale)).to be(false)
      expect(AutoloadProbe.autoload?(:Thing)).to be_truthy
      expect(ENV.fetch("AXN_AUTOLOAD_PROBE_LOADED", nil)).to be_nil
    end

    it "does not trigger a pending autoload during all_classes enumeration" do
      stale = stale_named_class
      described_class.register_class(stale)

      described_class.all_classes

      expect(AutoloadProbe.autoload?(:Thing)).to be_truthy
      expect(ENV.fetch("AXN_AUTOLOAD_PROBE_LOADED", nil)).to be_nil
    end
  end

  describe "Axn.tools_for validation" do
    it "raises for an unregistered adapter" do
      expect { Axn.tools_for(:nope) }.to raise_error(ArgumentError, /not a registered tool adapter/)
    end
  end

  describe ".tools_for" do
    before do
      Axn.register_tool_adapter(:mcp)
      Axn.register_tool_adapter(:ruby_llm)
    end

    it "returns only member classes for the adapter" do
      mcp_only = stub_const("ToolsForSpec::McpOnly", Class.new do
        include Axn
        tool :mcp
      end)
      both = stub_const("ToolsForSpec::Both", Class.new do
        include Axn
        tool
      end)
      not_a_tool = stub_const("ToolsForSpec::NotATool", Class.new { include Axn })

      expect(Axn.tools_for(:mcp)).to include(mcp_only, both)
      expect(Axn.tools_for(:mcp)).not_to include(not_a_tool)
      expect(Axn.tools_for(:ruby_llm)).to include(both)
      expect(Axn.tools_for(:ruby_llm)).not_to include(mcp_only)
    end

    it "returns members sorted by tool_name (deterministic regardless of registration order)" do
      # Register in an order that is NOT tool_name order, so a Set-insertion-order return would differ.
      charlie = stub_const("ToolsForSpec::Charlie", Class.new do
        include Axn
        tool name: "charlie"
      end)
      alpha = stub_const("ToolsForSpec::Alpha", Class.new do
        include Axn
        tool name: "alpha"
      end)
      bravo = stub_const("ToolsForSpec::Bravo", Class.new do
        include Axn
        tool name: "bravo"
      end)

      members = Axn.tools_for(:mcp)
      expect(members).to eq([alpha, bravo, charlie])
    end

    it "exposes a subclass of an Axn base that declares `tool` (inheritance pattern)" do
      base = stub_const("ToolsForSpec::AppBase", Class.new { include Axn })
      sub = stub_const("ToolsForSpec::ConcreteTool", Class.new(base) { tool })
      expect(Axn.tools_for(:mcp)).to include(sub)
    end

    it "does NOT expose a subclass that declares `tool false`" do
      base = stub_const("ToolsForSpec::AppBase2", Class.new { include Axn })
      sub = stub_const("ToolsForSpec::OptedOutTool", Class.new(base) { tool false })
      expect(Axn.tools_for(:mcp)).not_to include(sub)
    end
  end

  describe ".tools_for (duplicate tool_name detection)" do
    before { Axn.register_tool_adapter(:mcp) }

    it "raises when two members derive the same tool_name from their class names" do
      stub_const("AgentTools::ListCompanies", Class.new do
        include Axn
        tool :mcp
      end)
      stub_const("Actions::Tools::ListCompanies", Class.new do
        include Axn
        tool :mcp
      end)

      expect { Axn.tools_for(:mcp) }.to raise_error(ArgumentError) do |error|
        expect(error.message).to include("list_companies")
        expect(error.message).to include("AgentTools::ListCompanies")
        expect(error.message).to include("Actions::Tools::ListCompanies")
        expect(error.message).to include("tool name:")
      end
    end

    it "raises when two distinctly-named classes share an explicit tool name: override" do
      stub_const("DupNameSpec::First", Class.new do
        include Axn
        tool :mcp, name: "dup"
      end)
      stub_const("DupNameSpec::Second", Class.new do
        include Axn
        tool :mcp, name: "dup"
      end)

      expect { Axn.tools_for(:mcp) }.to raise_error(ArgumentError, /dup/)
    end

    it "does not raise when the same tool_name is used under different adapters" do
      Axn.register_tool_adapter(:ruby_llm)

      # Both derive "widget": distinct class names, each with a leading segment
      # ("Tools"/"AgentTools") that's in the default tool_name_stripped_prefixes list.
      mcp_klass = stub_const("Tools::Widget", Class.new do
        include Axn
        tool :mcp
      end)
      ruby_llm_klass = stub_const("AgentTools::Widget", Class.new do
        include Axn
        tool :ruby_llm
      end)

      expect(mcp_klass.tool_name).to eq(ruby_llm_klass.tool_name)

      expect(Axn.tools_for(:mcp)).to contain_exactly(mcp_klass)
      expect(Axn.tools_for(:ruby_llm)).to contain_exactly(ruby_llm_klass)
    end

    it "returns members normally when no collision exists" do
      distinct_a = stub_const("NoDupSpec::AlphaTool", Class.new do
        include Axn
        tool :mcp
      end)
      distinct_b = stub_const("NoDupSpec::BetaTool", Class.new do
        include Axn
        tool :mcp
      end)

      expect(Axn.tools_for(:mcp)).to include(distinct_a, distinct_b)
    end

    it "detects a within-adapter collision produced by a per-adapter bag name" do
      stub_const("PerAdapterDup::First", Class.new do
        include Axn
        tool mcp: { name: "search" }
      end)
      stub_const("PerAdapterDup::Second", Class.new do
        include Axn
        tool mcp: { name: "search" }
      end)

      expect { Axn.tools_for(:mcp) }.to raise_error(ArgumentError, /search/)
    end

    it "does not collide when the shared derived names differ but only one adapter is overridden" do
      Axn.register_tool_adapter(:ruby_llm)
      a = stub_const("PerAdapterName::Alpha", Class.new do
        include Axn
        tool mcp: { name: "shared" }, ruby_llm: {}
      end)
      b = stub_const("PerAdapterName::Beta", Class.new do
        include Axn
        tool ruby_llm: { name: "shared" }
      end)

      # "shared" is the mcp name of Alpha and the ruby_llm name of Beta — different adapters, no clash.
      expect(Axn.tools_for(:mcp)).to contain_exactly(a)
      expect(Axn.tools_for(:ruby_llm)).to contain_exactly(a, b)
    end

    it "sorts members by the per-adapter name" do
      # Class-name-derived order is the OPPOSITE of the per-adapter override order ("Apple" <
      # "Zebra" by class name, but "zzz" > "aaa" by override), so this only passes when the sort
      # actually keys off the per-adapter tool_name rather than the zero-arg derived name.
      z = stub_const("PerAdapterSort::Apple", Class.new do
        include Axn
        tool mcp: { name: "zzz" }
      end)
      a = stub_const("PerAdapterSort::Zebra", Class.new do
        include Axn
        tool mcp: { name: "aaa" }
      end)

      expect(Axn.tools_for(:mcp)).to eq([a, z])
    end
  end

  describe "._adapter_dirs (broad-entry bypass fail-safe)", :aggregate_failures do
    it "skips a broad entry that reached tool_roots via in-place mutation, warning about it" do
      source = register_tool_adapter_with_roots(:mcp, roots: %w[agent_tools])
      source.config.tool_roots << "actions" # in-place mutation bypasses the setter's guard

      warnings = []
      allow(Axn.config.logger).to receive(:warn) { |*args, &block| warnings << (block ? block.call : args.first) }

      dirs = described_class.send(:_adapter_dirs, :mcp)

      actions_dir = described_class.send(:_resolve_tool_dir, "actions")
      agent_tools_dir = described_class.send(:_resolve_tool_dir, "agent_tools")

      expect(dirs).not_to include(actions_dir)
      expect(dirs).to include(agent_tools_dir)
      expect(warnings).to include(a_string_matching(/"actions"/))
    end
  end

  describe ".ensure_loaded! (non-Rails require fallback)", :aggregate_failures do
    let(:fixture_dir) { File.expand_path("../../support/fixtures/registry_tools", __dir__) }

    before do
      register_tool_adapter_with_roots(:mcp, roots: [fixture_dir])
    end

    it "requires .rb files under a configured tool dir and exposes them as tools" do
      skip "fixture already loaded" if Object.const_defined?("RegistryFixtures::LazyRegistryTool")

      tools = Axn.tools_for(:mcp)
      expect(Object.const_defined?("RegistryFixtures::LazyRegistryTool")).to be(true)
      expect(tools).to include(RegistryFixtures::LazyRegistryTool)
      expect(RegistryFixtures::LazyRegistryTool.tool_name).to eq("registry_fixtures_lazy_registry_tool")
    end
  end

  describe ".ensure_loaded! (non-Rails, isolates per-file load failures)", :aggregate_failures do
    let(:fixture_dir) { File.expand_path("../../support/fixtures/registry_tools_mixed", __dir__) }

    before do
      register_tool_adapter_with_roots(:mcp, roots: [fixture_dir])
    end

    it "loads the good tool despite a sibling file raising at load time, warning about the bad one" do
      skip "fixture already loaded" if Object.const_defined?("RegistryFixturesMixed::GoodMixedTool")

      warnings = []
      allow(Axn.config.logger).to receive(:warn) { |*args, &block| warnings << (block ? block.call : args.first) }

      tools = Axn.tools_for(:mcp)

      expect(Object.const_defined?("RegistryFixturesMixed::GoodMixedTool")).to be(true)
      expect(tools).to include(RegistryFixturesMixed::GoodMixedTool)
      expect(warnings).to include(a_string_matching(/bad_mixed_tool\.rb.*boom/))
    end

    it "loads the good tool despite a sibling file raising LoadError at load time, warning about it too" do
      skip "fixture already loaded" if Object.const_defined?("RegistryFixturesMixed::GoodMixedTool")

      warnings = []
      allow(Axn.config.logger).to receive(:warn) { |*args, &block| warnings << (block ? block.call : args.first) }

      tools = Axn.tools_for(:mcp)

      expect(Object.const_defined?("RegistryFixturesMixed::GoodMixedTool")).to be(true)
      expect(tools).to include(RegistryFixturesMixed::GoodMixedTool)
      expect(warnings).to include(a_string_matching(/load_error_mixed_tool\.rb.*LoadError/))
    end
  end

  describe ".ensure_loaded! (non-Rails, isolates a SyntaxError in one tool file from valid siblings)", :aggregate_failures do
    # A committed malformed `.rb` would fail rubocop, so the bad fixture is generated at runtime in a
    # temp dir. SyntaxError inherits from ScriptError (not StandardError/LoadError), so the per-file
    # rescue must catch ScriptError for the malformed file to be isolated rather than aborting the load.
    it "loads a valid sibling despite a SyntaxError file, warning about the bad one and not raising" do
      require "tmpdir"

      skip "fixture already loaded" if Object.const_defined?("SyntaxIsoFixture::Ok")

      dir = Dir.mktmpdir("axn_syntax_iso")
      begin
        File.write(File.join(dir, "ok_tool.rb"), <<~RUBY)
          module SyntaxIsoFixture
            class Ok
              include Axn
              tool :mcp
              def call = nil
            end
          end
        RUBY
        # Genuine syntax error: a def with a missing method-body expression.
        File.write(File.join(dir, "broken_tool.rb"), "class Broken\n  def call =\nend\n")

        register_tool_adapter_with_roots(:mcp, roots: [dir])

        warnings = []
        allow(Axn.config.logger).to receive(:warn) { |*args, &block| warnings << (block ? block.call : args.first) }

        tools = nil
        expect { tools = Axn.tools_for(:mcp) }.not_to raise_error

        expect(Object.const_defined?("SyntaxIsoFixture::Ok")).to be(true)
        expect(tools).to include(SyntaxIsoFixture::Ok)
        expect(warnings).to include(a_string_matching(/broken_tool\.rb.*SyntaxError/))
      ensure
        FileUtils.remove_entry(dir)
      end
    end
  end

  describe ".ensure_loaded! (non-Rails, rolls back registrations from a file that fails after the class body)", :aggregate_failures do
    let(:fixture_dir) { File.expand_path("../../support/fixtures/registry_tools_failed", __dir__) }

    before do
      register_tool_adapter_with_roots(:mcp, roots: [fixture_dir])
    end

    it "exposes the good tool but rolls back the class registered by the failing file" do
      skip "fixture already loaded" if Object.const_defined?("GoodFailedFixture::Ok")

      warnings = []
      allow(Axn.config.logger).to receive(:warn) { |*args, &block| warnings << (block ? block.call : args.first) }

      tools = Axn.tools_for(:mcp)

      expect(tools).to include(GoodFailedFixture::Ok)

      # The failing file DID define/register its class before raising, but ensure_loaded! rolled
      # it back out of _classes, so it must not surface as a tool even though the constant exists.
      expect(defined?(FailedFixture::PartialTool)).to be_truthy
      expect(tools).not_to include(FailedFixture::PartialTool)
      expect(described_class.send(:_classes)).not_to include(FailedFixture::PartialTool)

      expect(warnings).to include(a_string_matching(/partial_failed_fixture\.rb.*boom after class body/))
    end
  end

  describe ".ensure_loaded! (non-Rails, scopes rollback to the failing file's own classes)", :aggregate_failures do
    let(:fixture_dir) { File.expand_path("../../support/fixtures/registry_tools_nested", __dir__) }

    before do
      register_tool_adapter_with_roots(:mcp, roots: [fixture_dir])
    end

    it "keeps a valid tool required by the failing file, rolling back only the failing file's own class" do
      skip "fixture already loaded" if Object.const_defined?("NestedDep::Good")

      warnings = []
      allow(Axn.config.logger).to receive(:warn) { |*args, &block| warnings << (block ? block.call : args.first) }

      tools = Axn.tools_for(:mcp)

      # The dependency the failing file `require`d before raising was registered inside that file's
      # require window, but it is SOURCED FROM dep_good.rb, so the file-scoped rollback must keep it.
      expect(defined?(NestedDep::Good)).to be_truthy
      expect(tools).to include(NestedDep::Good)
      expect(described_class.send(:_classes)).to include(NestedDep::Good)

      # The failing file's OWN class is sourced from the failed file and must be rolled back.
      expect(defined?(NestedBad::Partial)).to be_truthy
      expect(tools).not_to include(NestedBad::Partial)
      expect(described_class.send(:_classes)).not_to include(NestedBad::Partial)

      expect(warnings).to include(a_string_matching(/bad_requires_dep\.rb.*boom after requiring dep/))
    end
  end

  describe ".ensure_loaded! (Rails eager_load_dir branch rolls back a failed dir's registrations)", :aggregate_failures do
    # Faithfully drives ensure_loaded!'s Rails branch by stubbing the Zeitwerk surface (rather than
    # adding a raising fixture under the dummy app's autoloaded tree, which would break CI boot).
    let(:dir) { File.expand_path("../../support/fixtures/registry_tools_nested", __dir__) }

    before { Axn.register_tool_adapter(:mcp) }

    it "deletes only added classes whose source is under the failed dir, preserving those outside it" do
      register_tool_adapter_with_roots(:mcp, roots: [dir])
      allow(described_class).to receive(:_rails_app?).and_return(true)

      loader = double("zeitwerk loader")
      stub_const("Rails", double(
                            application: double(config: double(eager_load: false)),
                            autoloaders: double(main: loader),
                          ))

      # Two classes registered DURING eager_load_dir: one sourced under the dir (must be rolled
      # back), one sourced elsewhere via a cross-dir require (must be preserved).
      under_dir = Class.new { include Axn }
      outside = Class.new { include Axn }
      described_class.send(:_classes).delete(under_dir)
      described_class.send(:_classes).delete(outside)

      allow(loader).to receive(:eager_load_dir) do
        described_class.register_class(under_dir)
        described_class.register_class(outside)
        raise "boom during eager load"
      end

      allow(described_class).to receive(:_class_source_file).and_call_original
      allow(described_class).to receive(:_class_source_file).with(under_dir)
                                                            .and_return(File.join(dir, "nested_tool.rb"))
      allow(described_class).to receive(:_class_source_file).with(outside)
                                                            .and_return("/somewhere/else/x.rb")

      warnings = []
      allow(Axn.config.logger).to receive(:warn) { |*args, &block| warnings << (block ? block.call : args.first) }

      described_class.ensure_loaded!

      expect(described_class.send(:_classes)).not_to include(under_dir)
      expect(described_class.send(:_classes)).to include(outside)
      expect(warnings).to include(a_string_matching(/tool dir skipped/))
    ensure
      described_class.send(:_classes).delete(under_dir)
      described_class.send(:_classes).delete(outside)
    end
  end

  describe ".ensure_loaded! (Rails branch warns instead of eager-loading an unmanaged dir)", :aggregate_failures do
    # Reproduces the PRO-2921 boot-ordering hole: axn's engine pushes app/actions into Zeitwerk
    # `after: :load_config_initializers`, so a `tools_for` call from within a
    # `config/initializers` file runs before that hook — the tool dir exists on disk but Zeitwerk
    # doesn't manage it yet. `eager_load_dir` would just raise/rescue in that case; we instead
    # check `loader.dirs` (Zeitwerk's managed root list) up front and warn loudly rather than
    # silently returning an empty/partial tool list.
    let(:dir) { File.expand_path("../../support/fixtures/registry_tools_nested", __dir__) }

    before do
      register_tool_adapter_with_roots(:mcp, roots: [dir])
      allow(described_class).to receive(:_rails_app?).and_return(true)
    end

    it "does not eager-load and warns when the dir is not under any managed root" do
      loader = double("zeitwerk loader")
      stub_const("Rails", double(
                            application: double(config: double(eager_load: false)),
                            autoloaders: double(main: loader),
                          ))
      allow(loader).to receive(:dirs).and_return(["/some/other/managed/root"])
      expect(loader).not_to receive(:eager_load_dir)

      warnings = []
      allow(Axn.config.logger).to receive(:warn) { |*args, &block| warnings << (block ? block.call : args.first) }

      expect { described_class.ensure_loaded! }.not_to raise_error

      expect(warnings).to include(a_string_matching(/not yet managed/))
    end

    it "eager-loads when the dir is under a managed root" do
      loader = double("zeitwerk loader")
      stub_const("Rails", double(
                            application: double(config: double(eager_load: false)),
                            autoloaders: double(main: loader),
                          ))
      allow(loader).to receive(:dirs).and_return([File.dirname(dir)])
      expect(loader).to receive(:eager_load_dir).with(dir)

      described_class.ensure_loaded!
    end
  end

  describe ".all_classes (prunes definitively-stale named entries from the backing Set)", :aggregate_failures do
    it "deletes a stale named class from _classes (not just from the return value)" do
      class_a = Class.new { include Axn }
      stub_const("PrunePersist::Thing", class_a)
      described_class.register_class(class_a)

      class_b = Class.new { include Axn }
      stub_const("PrunePersist::Thing", class_b)
      described_class.register_class(class_b)

      described_class.all_classes

      expect(described_class.send(:_classes)).not_to include(class_a)
      expect(described_class.send(:_classes)).to include(class_b)
    end

    it "drops a transient anonymous class from _classes (never a usable tool) and excludes it from the list" do
      anon = Class.new { include Axn }
      described_class.register_class(anon)

      result = described_class.all_classes

      expect(result).not_to include(anon)
      expect(described_class.send(:_classes)).not_to include(anon)
    ensure
      described_class.send(:_classes).delete(anon)
    end

    it "retains and returns a live named class" do
      live = stub_const("PruneLive::Thing", Class.new { include Axn })
      described_class.register_class(live)

      expect(described_class.all_classes).to include(live)
      expect(described_class.send(:_classes)).to include(live)
    end
  end

  describe ".member? (union of directory + declaration grants, minus except)" do
    # A class whose source file we pin under a chosen directory via const_source_location,
    # matching the existing member? tests' stubbing style.
    def klass_at(name, source_path, &blk)
      k = stub_const(name, Class.new { include Axn })
      k.class_eval(&blk) if blk
      allow(Object).to receive(:const_source_location).and_call_original
      allow(Object).to receive(:const_source_location).with(name).and_return([source_path, 1])
      k
    end

    let(:shared_dir) { File.expand_path("agent_tools") }

    it "grants every adapter whose roots contain the class (directory grant)" do
      register_tool_adapter_with_roots(:mcp, roots: %w[agent_tools])
      register_tool_adapter_with_roots(:ruby_llm, roots: %w[agent_tools])
      k = klass_at("MemberUnion::Shared", File.join(shared_dir, "shared.rb"))

      expect(described_class.member?(k, :mcp)).to be(true)
      expect(described_class.member?(k, :ruby_llm)).to be(true)
    end

    it "does NOT grant an adapter whose roots exclude the class" do
      register_tool_adapter_with_roots(:mcp, roots: %w[agent_tools])
      register_tool_adapter_with_roots(:openapi, roots: %w[http_tools])
      k = klass_at("MemberUnion::SharedOnly", File.join(shared_dir, "shared.rb"))

      expect(described_class.member?(k, :openapi)).to be(false)
    end

    it "adds a declared adapter on top of the directory grant (union, not replace)" do
      register_tool_adapter_with_roots(:mcp, roots: %w[agent_tools])
      register_tool_adapter_with_roots(:ruby_llm, roots: %w[agent_tools])
      register_tool_adapter_with_roots(:openapi, roots: %w[http_tools])
      k = klass_at("MemberUnion::PlusOpenapi", File.join(shared_dir, "shared.rb")) { tool :openapi }

      expect(described_class.member?(k, :mcp)).to be(true)      # still from directory
      expect(described_class.member?(k, :ruby_llm)).to be(true) # still from directory
      expect(described_class.member?(k, :openapi)).to be(true)  # added by declaration
    end

    it "subtracts an excepted adapter from the directory grant (all-but-a-few)" do
      register_tool_adapter_with_roots(:mcp, roots: %w[agent_tools])
      register_tool_adapter_with_roots(:openapi, roots: %w[agent_tools])
      k = klass_at("MemberUnion::AllBut", File.join(shared_dir, "shared.rb")) { tool except: :openapi }

      expect(described_class.member?(k, :mcp)).to be(true)
      expect(described_class.member?(k, :openapi)).to be(false)
    end

    it "except:-only does not re-expose the class to an adapter its directory never granted" do
      register_tool_adapter_with_roots(:mcp, roots: %w[agent_tools])
      register_tool_adapter_with_roots(:data_shifter_web, roots: %w[support_tools])
      k = klass_at("MemberUnion::NoLeak", File.join(shared_dir, "shared.rb")) { tool except: :mcp }

      expect(described_class.member?(k, :mcp)).to be(false) # excepted
      expect(described_class.member?(k, :data_shifter_web)).to be(false) # never granted, not :all
    end

    it "`tool false` opts out of every adapter regardless of directory" do
      register_tool_adapter_with_roots(:mcp, roots: %w[agent_tools])
      k = klass_at("MemberUnion::OptOut", File.join(shared_dir, "shared.rb")) { tool false }

      expect(described_class.member?(k, :mcp)).to be(false)
    end

    it "bare `tool` grants every registered adapter even with no matching root" do
      register_tool_adapter_with_roots(:mcp, roots: [])
      register_tool_adapter_with_roots(:openapi, roots: [])
      k = klass_at("MemberUnion::All", "/somewhere/else/thing.rb") { tool }

      expect(described_class.member?(k, :mcp)).to be(true)
      expect(described_class.member?(k, :openapi)).to be(true)
    end

    it "an adapter with no config source has an empty directory grant" do
      Axn.register_tool_adapter(:mcp) # no source
      k = klass_at("MemberUnion::NoSource", File.join(shared_dir, "shared.rb"))

      expect(described_class.member?(k, :mcp)).to be(false)
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

    it "a class with `configure(:mcp)` is an implicit member for :mcp only" do
      Axn.register_tool_adapter(:ruby_llm)
      k = stub_const("MemberSpec::ConfigNS", Class.new do
        include Axn
        configure(:mcp) { |c| c.some_setting = 1 }
      end)
      allow(Object).to receive(:const_source_location).and_return(nil)
      expect(described_class.member?(k, :mcp)).to be(true)
      expect(described_class.member?(k, :ruby_llm)).to be(false)
    end

    it "an undeclared class under a sibling dir whose name merely prefixes the tool dir is not a member" do
      register_tool_adapter_with_roots(:mcp, roots: [File.expand_path("spec/support")])
      k = stub_const("MemberSpec::SiblingPrefix", Class.new { include Axn })
      allow(Object).to receive(:const_source_location).with("MemberSpec::SiblingPrefix")
                                                      .and_return([File.expand_path("spec/support_helpers/x.rb"), 1])
      expect(described_class.member?(k, :mcp)).to be(false)
    end

    it "a class with a `configure(:foo)` bag is not a member for an unregistered :foo adapter" do
      allow(Object).to receive(:const_source_location).and_return(nil)
      k = stub_const("MemberSpec::UnregisteredAdapter", Class.new do
        include Axn
        configure(:foo) { |c| c.some_setting = 1 }
      end)
      expect(described_class.member?(k, :foo)).to be(false)
    end

    it "a subclass of a class with `configure(:mcp)` is an implicit member via the inherited bag" do
      allow(Object).to receive(:const_source_location).and_return(nil)
      parent = Class.new do
        include Axn
        configure(:mcp) { |c| c.some_setting = 1 }
      end
      subclass = stub_const("MemberSpec::InheritedConfig", Class.new(parent))
      expect(described_class.member?(subclass, :mcp)).to be(true)
    end
  end
end
