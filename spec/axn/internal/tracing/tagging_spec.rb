# frozen_string_literal: true

RSpec.describe "Axn tagging integration" do
  # --- Notification payload (no OpenTelemetry needed) ---
  describe "payload[:tags]" do
    let(:notifications) { [] }

    before do
      ActiveSupport::Notifications.subscribe("axn.call") do |_name, _start, _finish, _id, payload|
        notifications << payload
      end
    end

    after { ActiveSupport::Notifications.unsubscribe("axn.call") }

    it "populates tags/dimensions on the payload before the event is published (readable at callback time)" do
      seen = {}
      sub = ActiveSupport::Notifications.subscribe("axn.call") do |_name, _start, _finish, _id, payload|
        # Read by value inside the callback — a real subscriber can only see what's on the
        # payload at publish time, not mutations applied after `instrument` returns.
        seen[:tags] = payload[:tags]
        seen[:dimensions] = payload[:dimensions]
        seen[:outcome] = payload[:outcome]
      end
      build_axn do
        tag(:company_id) { 7 }
        dimension(:plan) { "pro" }
        def call; end
      end.call
      expect(seen[:tags]).to eq(company_id: 7)
      expect(seen[:dimensions]).to eq(plan: "pro")
      expect(seen[:outcome]).to eq("success")
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end

    it "includes resolved tags from proc, symbol, and literal resolvers" do
      action = build_axn do
        expects :n
        tag :from_proc, -> { n * 2 }
        tag :from_symbol, :computed
        tag :from_literal, "us5"
        def computed = 42
        def call; end
      end
      action.call(n: 5)
      expect(notifications.first[:tags]).to eq(from_proc: 10, from_symbol: 42, from_literal: "us5")
    end

    it "omits a tag whose resolver returns nil (conditional escape hatch)" do
      action = build_axn do
        tag(:present) { "yes" }
        tag(:absent) { nil }
        def call; end
      end
      action.call
      expect(notifications.first[:tags]).to eq(present: "yes")
    end

    it "isolates a raising resolver — siblings still land" do
      allow(Axn::Internal::PipingError).to receive(:swallow)
      action = build_axn do
        tag(:good) { "ok" }
        tag(:bad) { raise "boom" }
        def call; end
      end
      result = action.call
      expect(result).to be_ok
      expect(notifications.first[:tags]).to eq(good: "ok")
      expect_piping_error_called(message_substring: "resolving observability facet bad", error_class: RuntimeError, error_message: "boom")
    end

    it "coerces non-primitive values to strings" do
      action = build_axn do
        tag(:sym) { :active }
        def call; end
      end
      action.call
      expect(notifications.first[:tags]).to eq(sym: "active")
    end

    it "coerces array elements before they reach the payload" do
      action = build_axn do
        tag(:states) { %i[trial paid] }
        def call; end
      end
      action.call
      expect(notifications.first[:tags]).to eq(states: %w[trial paid])
    end

    it "sets no :tags key when no tags are declared" do
      build_axn { def call; end }.call
      expect(notifications.first).not_to have_key(:tags)
    end

    it "resolves input-phase facets from pre-body inputs regardless of logger" do
      # An input-phase facet resolves before the body runs, so a value the body later mutates in
      # place is captured at its pre-body state — and that timing must not depend on whether a
      # SemanticLogger is configured (the default here is a plain Logger).
      action = build_axn do
        expects :data
        tag(:snapshot) { data[:v] }
        def call = data[:v] = "mutated"
      end
      action.call(data: { v: "original" })
      expect(notifications.first[:tags]).to eq(snapshot: "original")
    end
  end

  # --- Span attributes (OpenTelemetry mock harness) ---
  describe "axn.tag.<name> span attributes" do
    let(:mock_tracer) { instance_double("OpenTelemetry::Trace::Tracer") }
    let(:mock_span) { instance_double("OpenTelemetry::Trace::Span") }
    let(:mock_tracer_provider) { instance_double("OpenTelemetry::Trace::TracerProvider") }

    before do
      @original_otel = defined?(OpenTelemetry) ? OpenTelemetry : nil
      otel_module = Module.new { def self.tracer_provider; end }
      trace_module = Module.new
      status_class = Class.new
      mock_status = instance_double("Status")
      status_class.define_singleton_method(:error) { |_msg| mock_status }
      trace_module.const_set(:Status, status_class)
      otel_module.const_set(:Trace, trace_module)
      stub_const("OpenTelemetry", otel_module)
      allow(OpenTelemetry).to receive(:tracer_provider).and_return(mock_tracer_provider)
      allow(mock_tracer_provider).to receive(:tracer).with("axn", Axn::VERSION).and_return(mock_tracer)
      allow(mock_tracer).to receive(:in_span).and_yield(mock_span)
      allow(mock_span).to receive(:set_attribute)
      allow(mock_span).to receive(:record_exception)
      allow(mock_span).to receive(:status=)
    end

    after do
      Axn::Internal::Tracing.instance_variable_set(:@tracer, nil)
      Axn::Internal::Tracing.instance_variable_set(:@tracer_provider, nil)
      Axn::Internal::Tracing.instance_variable_set(:@supports_record_exception, nil)
      if @original_otel && defined?(OpenTelemetry) && @original_otel != OpenTelemetry
        RSpec::Mocks.space.proxy_for(OpenTelemetry).reset
        Object.send(:remove_const, :OpenTelemetry) if defined?(OpenTelemetry)
        Object.const_set(:OpenTelemetry, @original_otel)
      end
    end

    it "sets each declared tag as an axn.tag.<name> attribute" do
      action = build_axn do
        tag :company_id, -> { 123 }
        def call; end
      end
      action.call
      expect(mock_span).to have_received(:set_attribute).with("axn.tag.company_id", 123)
    end

    it "sets no axn.tag.* attribute when none declared" do
      build_axn { def call; end }.call
      expect(mock_span).not_to have_received(:set_attribute).with(a_string_starting_with("axn.tag."), anything)
    end

    it "sets each declared dimension as an axn.dimension.<name> attribute" do
      action = build_axn do
        dimension :plan_tier, -> { "pro" }
        def call; end
      end
      action.call
      expect(mock_span).to have_received(:set_attribute).with("axn.dimension.plan_tier", "pro")
    end

    it "does not let a subscriber mutating the payload leak into span attributes" do
      # A subscriber receives its own copy of the facet maps, so clearing/mutating
      # them must not affect the (memoized) values the span reads afterward.
      sub = ActiveSupport::Notifications.subscribe("axn.call") do |_n, _s, _f, _i, payload|
        payload[:tags]&.clear
        payload[:tags][:injected] = "leaked" if payload[:tags]
      end
      action = build_axn do
        tag(:company_id) { 123 }
        def call; end
      end
      action.call
      expect(mock_span).to have_received(:set_attribute).with("axn.tag.company_id", 123)
      expect(mock_span).not_to have_received(:set_attribute).with("axn.tag.injected", anything)
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end
  end

  describe "dimensions" do
    describe "emit_metrics dimensions: kwarg" do
      let(:calls) { [] }
      after { Axn.configure { |c| c.emit_metrics = nil } }

      it "passes resolved dimensions to a block that declares dimensions:" do
        Axn.configure { |c| c.emit_metrics = proc { |resource:, result:, dimensions:| calls << { resource:, result:, dimensions: } } }
        action = build_axn do
          dimension :plan_tier, -> { "pro" }
          def call; end
        end
        action.call
        expect(calls.first[:dimensions]).to eq(plan_tier: "pro")
      end

      it "leaves an existing resource:/result: block untouched (backward compatible)" do
        Axn.configure { |c| c.emit_metrics = proc { |resource:, result:| calls << { resource:, result: } } }
        action = build_axn do
          dimension :plan_tier, -> { "pro" }
          def call; end
        end
        expect { action.call }.not_to raise_error
        expect(calls.first.keys.sort).to eq(%i[resource result])
      end

      it "passes an empty dimensions hash when none declared" do
        Axn.configure { |c| c.emit_metrics = proc { |dimensions:| calls << dimensions } }
        build_axn { def call; end }.call
        expect(calls.first).to eq({})
      end

      it "never passes tags to emit_metrics" do
        Axn.configure { |c| c.emit_metrics = proc { |dimensions:| calls << dimensions } }
        action = build_axn do
          tag :company_id, -> { 1 }
          def call; end
        end
        action.call
        expect(calls.first).to eq({})
      end
    end

    describe "payload[:dimensions]" do
      let(:notifications) { [] }
      before { ActiveSupport::Notifications.subscribe("axn.call") { |*, payload| notifications << payload } }
      after { ActiveSupport::Notifications.unsubscribe("axn.call") }

      it "keeps tags and dimensions in separate payload keys and namespaces" do
        action = build_axn do
          tag :company_id, -> { 1 }
          dimension :company_id, -> { "bounded" } # same name, independent
          def call; end
        end
        action.call
        expect(notifications.first[:tags]).to eq(company_id: 1)
        expect(notifications.first[:dimensions]).to eq(company_id: "bounded")
      end

      it "sets no :dimensions key when none declared" do
        build_axn { def call; end }.call
        expect(notifications.first).not_to have_key(:dimensions)
      end
    end
  end
end
