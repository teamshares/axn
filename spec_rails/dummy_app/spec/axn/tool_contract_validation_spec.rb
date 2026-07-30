# frozen_string_literal: true

# A colliding or unrenderable property name only harms a JSON projection, and for a tool axn the projection is
# what an adapter hands a model — so under Rails the engine drives validation at app setup rather than leaving it
# to a user's tool call.
#
# The hooks cannot be exercised by booting a colliding tool into the dummy app itself (that would fail every other
# spec's boot), so these drive the real callback chains: `ActiveSupport::Reloader.prepare!` runs the `to_prepare`
# callbacks the engine registered, which is also the path a development reload takes.
RSpec.describe "tool contract validation at app setup" do
  around do |example|
    original_adapters = Axn::Tools::Registry.adapters.dup
    Axn::Tools::Registry.reset_adapters!
    example.run
  ensure
    Axn::Tools::Registry.reset_adapters!
    original_adapters.each { |adapter| Axn.register_tool_adapter(adapter) }
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
    it "raises through the engine's hook, naming the offending class" do
      Axn.register_tool_adapter(:mcp)
      colliding_tool

      expect { reload_hooks.each(&:call) }.to raise_error(Axn::DuplicateFieldError) { |error|
        expect(error.message).to include("ToolBootSpec::Colliding has an invalid tool contract")
        expect(error.message).to include('both render as the JSON property "café"')
      }
    end

    it "raises again on a second reload rather than going quiet after the first" do
      Axn.register_tool_adapter(:mcp)
      colliding_tool

      expect { reload_hooks.each(&:call) }.to raise_error(Axn::DuplicateFieldError)
      expect { reload_hooks.each(&:call) }.to raise_error(Axn::DuplicateFieldError)
    end

    it "does not raise for a tool whose contract is fine" do
      Axn.register_tool_adapter(:mcp)
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
