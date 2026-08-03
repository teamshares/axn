# frozen_string_literal: true

# A colliding or unrenderable property name only harms a JSON projection, and for a tool axn the projection is
# what an adapter hands a model — so under Rails the engine drives validation at app setup rather than leaving it
# to a user's tool call.
#
# The hooks cannot be exercised by booting a colliding tool into the dummy app itself (that would fail every other
# spec's boot), so these drive the real callback chains: `ActiveSupport::Reloader.prepare!` runs the `to_prepare`
# callbacks the engine registered, which is also the path a development reload takes.
RSpec.describe "tool contract validation at app setup" do
  # Scoped to the examples that register their own adapters: the boot-state examples above must see the app's
  # real registrations, since those are precisely what boot used.
  shared_context "with an isolated adapter registry" do
    around do |example|
      original = Axn::Tools::Registry.adapters.to_a
      sources = original.to_h { |adapter| [adapter, Axn::Tools::Registry.adapter_config_source(adapter)] }
      Axn::Tools::Registry.reset_adapters!
      example.run
    ensure
      Axn::Tools::Registry.reset_adapters!
      sources.each { |adapter, source| Axn::Tools.register_adapter(adapter, source) }
    end
  end

  # A colliding contract no eager rule sees: two shape members whose names canonicalize to one JSON property.
  # Named, because the registry drops anonymous classes from enumeration.
  def colliding_tool
    latin1 = "caf\xE9".dup.force_encoding("ISO-8859-1").to_sym
    stub_const("ToolBootSpec::Colliding", Class.new do
      include Axn
      tool :mcp
      expects(:payload, type: Hash) do
        field :café, type: String
        field latin1, type: Integer
      end
      def call; end
    end)
  end

  # The block Rails will run on each reload. Invoked directly rather than through
  # `ActiveSupport::Reloader.prepare!`: Rails wires `to_prepare_blocks` into the reloader during boot, so in an
  # already-booted app `prepare!` does not re-run them. Wiring them is Rails' job; what is axn's is that the
  # block exists, comes from the engine, and validates.
  def reload_hooks
    Rails.application.config.to_prepare_blocks.select { |block| block.source_location.first.end_with?("lib/axn/rails/engine.rb") }
  end

  # The end-to-end assertion, and the only one that proves the guarantee rather than the plumbing: a real,
  # directory-resident tool axn was validated during boot, before any spec touched it.
  #
  # `config/initializers/axn_tool_validation.rb` registers the `:boot_check` adapter with
  # `actions/boot_validated` as a tool root, and that directory holds one valid tool. Nothing else references
  # that class — so if the memo below is populated, the only thing that can have populated it is axn's
  # `after_initialize` hook projecting it at setup. If the hook did not run (or enumerated nothing), referencing
  # the class here autoloads it fresh and the memo is nil.
  #
  # This is what the directly-invoked-block examples further down cannot show: those would pass identically if
  # enumeration always returned an empty set.
  describe "validation actually performed at boot" do
    subject(:tool) { Actions::BootValidated::ValidTool }

    # The witness is `@_axn_resolved_subfields`, the per-class cache `input_schema` populates on its way to
    # building a schema: nil for a class that has only been declared, set once one has been projected. So a
    # populated cache on a class no spec has touched means boot projected it. (The validation verdict itself is
    # deliberately not memoized for schema projections — see the module — so there is no verdict ivar to read.)
    it "projected a real tool's contract before any spec referenced it" do
      expect(tool.instance_variable_get(:@_axn_resolved_subfields)).not_to be_nil
    end

    # And projecting it is what validates it: the same projection re-run raises for an invalid contract, so a
    # clean boot over this tool means its contract passed.
    it "validates on every projection, so the boot pass was a real check" do
      expect { tool.input_schema }.not_to raise_error
      expect { tool.output_schema }.not_to raise_error
    end

    it "enumerated it as a tool, which is what made it reachable" do
      expect(Axn::Tools::Registry.adapters).to include(:boot_check)
      expect(Axn::Tools::Registry.tool_classes).to include(tool)
    end

    # What boot leaves free is the RENDER path, the one projection whose verdict is memoized (it builds an output
    # schema solely to validate, so it would otherwise pay for one on every call).
    it "leaves render's outbound verdict already established" do
      walks = 0
      allow(Axn::Reflection::PropertyNames).to receive(:reject_colliding_emitted_properties!).and_wrap_original do |original, *args, &block|
        walks += 1
        original.call(*args, &block)
      end

      Axn::Extensions::Serialization.render(tool.call(widget_id: "abc"))

      expect(walks).to eq(0)
    end
  end

  describe "the engine's hooks" do
    # `to_prepare` is not redundant with `after_initialize`: Zeitwerk unloads on code change, so a one-shot hook
    # would validate only the first boot and every reload after it would go unchecked.
    it "registers a reload hook from the engine" do
      expect(reload_hooks.size).to eq(1)
    end

    # The dummy app boots clean, and every other spec in this suite depends on that — which is itself the
    # assertion that setup validation does not fire spuriously on valid contracts.
    it "leaves a valid app booted" do
      expect(Rails.application.initialized?).to be(true)
      expect { Axn.validate_tool_contracts! }.not_to raise_error
    end
  end

  describe "a reload with an invalid tool contract" do
    include_context "with an isolated adapter registry"

    it "raises through the engine's hook, naming the offending class" do
      Axn::Tools.register_adapter(:mcp)
      colliding_tool

      expect { reload_hooks.each(&:call) }.to raise_error(Axn::DuplicateFieldError) { |error|
        expect(error.message).to include("ToolBootSpec::Colliding has an invalid tool contract")
        expect(error.message).to include('both render as the JSON property "café"')
      }
    end

    it "raises again on a second reload rather than going quiet after the first" do
      Axn::Tools.register_adapter(:mcp)
      colliding_tool

      expect { reload_hooks.each(&:call) }.to raise_error(Axn::DuplicateFieldError)
      expect { reload_hooks.each(&:call) }.to raise_error(Axn::DuplicateFieldError)
    end

    it "does not raise for a tool whose contract is fine" do
      Axn::Tools.register_adapter(:mcp)
      stub_const("ToolBootSpec::Fine", Class.new do
        include Axn
        tool :mcp
        expects :a, optional: true
        def call; end
      end)

      expect { reload_hooks.each(&:call) }.not_to raise_error
    end
  end
end
