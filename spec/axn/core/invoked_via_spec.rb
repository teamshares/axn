# frozen_string_literal: true

# End-to-end coverage for the ambient invoked_via dimension: Axn::Extensions::InvokedVia.with stamps
# the WHOLE call tree (subtree semantics), and the stamp reaches every facet sink even when the action
# declares no facets of its own — which is exactly the regression the three declaration-gated guards
# (payload, log_facets, with_facet_log_context) would otherwise cause. Axn::Tools::Invoker's own
# adapter: wiring is covered separately in spec/axn/tools/invoker_spec.rb; this file exercises the
# shared mechanism (Extensions::InvokedVia / Internal::CurrentEntryPoint) that both go through.
RSpec.describe "invoked_via ambient dimension" do
  around do |example|
    original = Axn.config.instance_variable_get(:@on_exception)
    example.run
    Axn.config.instance_variable_set(:@on_exception, original)
  end

  let(:notifications) { [] }

  before { ActiveSupport::Notifications.subscribe("axn.call") { |*, payload| notifications << payload } }
  after { ActiveSupport::Notifications.unsubscribe("axn.call") }

  describe "absent by default" do
    it "sets no invoked_via anywhere for a plain direct call" do
      build_axn { def call; end }.call
      expect(notifications.first).not_to have_key(:dimensions)
    end
  end

  describe "stamping a call with no declared facets" do
    let(:action) { build_axn { def call; end } }

    it "reaches the notification payload dimensions" do
      Axn::Extensions::InvokedVia.with(:mcp) { action.call }
      expect(notifications.first[:dimensions]).to eq(invoked_via: :mcp)
    end

    it "reaches Axn.config.emit_metrics dimensions:" do
      captured = nil
      Axn.configure { |c| c.emit_metrics = proc { |dimensions:| captured = dimensions } }
      Axn::Extensions::InvokedVia.with(:mcp) { action.call }
      expect(captured).to eq(invoked_via: :mcp)
    ensure
      Axn.configure { |c| c.emit_metrics = nil }
    end

    it "reaches on_exception context[:dimensions]" do
      raising = build_axn { def call = raise("boom") }
      captured = nil
      Axn.config.instance_variable_set(:@on_exception, proc { |context:| captured = context[:dimensions] })
      Axn::Extensions::InvokedVia.with(:mcp) { raising.call }
      expect(captured).to eq(invoked_via: :mcp)
    end

    it "reaches SemanticLogger.tagged named tags" do
      tagged_calls = []
      semantic_logger = Module.new
      logger_klass = Class.new(Logger)
      semantic_logger.const_set(:Logger, logger_klass)
      semantic_logger.define_singleton_method(:tagged) do |*_tags, **named, &blk|
        tagged_calls << named
        blk.call
      end
      stub_const("SemanticLogger", semantic_logger)
      logger = logger_klass.new(File::NULL)
      allow(Axn.config).to receive(:logger).and_return(logger)

      Axn::Extensions::InvokedVia.with(:mcp) { action.call }

      expect(tagged_calls).to include(a_hash_including("axn.dimension.invoked_via": :mcp))
    end

    it "reaches the axn.tag.* / axn.dimension.* span attributes" do
      fake_span = Class.new do
        attr_reader :attributes

        def initialize = @attributes = {}
        def set_attribute(key, value) = @attributes[key] = value
        def record_exception(_exception) = nil
        def status=(_status); end
      end.new
      fake_tracer = Class.new do
        define_method(:initialize) { |span| @span = span }
        define_method(:in_span) { |_name, **, &block| block.call(@span) }
      end.new(fake_span)
      Axn.config.tracer = fake_tracer

      Axn::Extensions::InvokedVia.with(:mcp) { action.call }

      expect(fake_span.attributes).to include("axn.dimension.invoked_via" => :mcp)
    ensure
      Axn.config.reset!(:tracer)
    end
  end

  describe "subtree propagation" do
    it "stamps a nested sub-axn the same as its root" do
      child = build_axn { def call; end }
      parent = build_axn { def call; end }
      captured = []
      Axn::Extensions::InvokedVia.with(:mcp) do
        captured << Axn::Internal::CurrentEntryPoint.current
        parent.call
        child.call
        captured << Axn::Internal::CurrentEntryPoint.current
      end
      expect(captured).to eq(%i[mcp mcp])
    end

    it "does not leak past the block — a call after it ends is unstamped" do
      action = build_axn { def call; end }
      Axn::Extensions::InvokedVia.with(:mcp) {}
      Axn::Extensions::InvokedVia.with(:mcp) { action.call }
      action.call # outside any with block
      expect(notifications.last).not_to have_key(:dimensions)
    end
  end

  describe "an action that also declares its own dimension" do
    it "carries both the declared dimension and the ambient stamp" do
      action = build_axn do
        dimension(:plan) { "pro" }
        def call; end
      end
      Axn::Extensions::InvokedVia.with(:mcp) { action.call }
      expect(notifications.first[:dimensions]).to eq(plan: "pro", invoked_via: :mcp)
    end
  end
end
