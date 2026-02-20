# frozen_string_literal: true

RSpec.describe "Axn::Internal::Tracing OpenTelemetry" do
  let(:mock_tracer) { instance_double("OpenTelemetry::Trace::Tracer") }
  let(:mock_span) { instance_double("OpenTelemetry::Trace::Span") }
  let(:mock_tracer_provider) { instance_double("OpenTelemetry::Trace::TracerProvider") }

  before do
    # Save original OpenTelemetry if it exists
    @original_otel = defined?(OpenTelemetry) ? OpenTelemetry : nil

    # Create a simple OpenTelemetry module that we'll stub methods on
    otel_module = Module.new
    trace_module = Module.new
    status_class = Class.new
    mock_status = instance_double("Status")
    status_class.define_singleton_method(:error) { |_msg| mock_status }
    trace_module.const_set(:Status, status_class)
    otel_module.const_set(:Trace, trace_module)
    stub_const("OpenTelemetry", otel_module)

    # Set up the tracer_provider method on the mocked OpenTelemetry module
    allow(OpenTelemetry).to receive(:tracer_provider).and_return(mock_tracer_provider)
    allow(mock_tracer_provider).to receive(:tracer).with("axn", Axn::VERSION).and_return(mock_tracer)
    allow(mock_tracer).to receive(:in_span).and_yield(mock_span)

    allow(mock_span).to receive(:set_attribute)
    allow(mock_span).to receive(:record_exception)
    allow(mock_span).to receive(:status=)
  end

  after do
    # Clear the cached tracer so it's recreated with the restored OpenTelemetry
    Axn::Internal::Tracing.instance_variable_set(:@tracer, nil)
    Axn::Internal::Tracing.instance_variable_set(:@tracer_provider, nil)
    Axn::Internal::Tracing.instance_variable_set(:@supports_record_exception, nil)

    # Restore original if it existed, but don't conflict with stub_const cleanup
    if @original_otel && defined?(OpenTelemetry) && @original_otel != OpenTelemetry
      RSpec::Mocks.space.proxy_for(OpenTelemetry).reset
      Object.send(:remove_const, :OpenTelemetry) if defined?(OpenTelemetry)
      Object.const_set(:OpenTelemetry, @original_otel)
    end
  end

  shared_examples "creates span with outcome" do |outcome|
    it "creates OpenTelemetry span with correct name and attributes" do
      action.call
      expect(mock_tracer_provider).to have_received(:tracer).with("axn", Axn::VERSION)
      expect(mock_tracer).to have_received(:in_span).with("axn.call", hash_including(attributes: { "axn.resource" => "AnonymousClass" }))
    end

    it "sets #{outcome} outcome attribute on span" do
      action.call
      expect(mock_span).to have_received(:set_attribute).with("axn.outcome", outcome)
    end
  end

  context "when action succeeds" do
    let(:action) { build_axn }

    include_examples "creates span with outcome", "success"

    it "does not record exception or set error status" do
      action.call
      expect(mock_span).not_to have_received(:record_exception)
      expect(mock_span).not_to have_received(:status=)
    end

    it "wraps execution so child spans would be captured" do
      # Verify that in_span is called with a block that contains the instrument call
      # This ensures child spans created during execution would be nested under this span
      expect(mock_tracer).to receive(:in_span).and_yield(mock_span)
      action.call
    end
  end

  context "when action fails with fail!" do
    let(:action) do
      build_axn do
        def call
          fail! "intentional failure"
        end
      end
    end

    include_examples "creates span with outcome", "failure"

    it "records exception on span" do
      result = action.call
      expect(result.exception).to be_a(Axn::Failure)
      expect(mock_span).to have_received(:record_exception).with(an_instance_of(Axn::Failure))
    end

    it "sets error status on span" do
      action.call
      expect(mock_span).to have_received(:status=)
    end
  end

  context "when action raises an exception" do
    let(:action) do
      build_axn do
        def call
          raise "intentional exception"
        end
      end
    end

    include_examples "creates span with outcome", "exception"

    it "records exception on span" do
      result = action.call
      expect(result.exception).to be_a(RuntimeError)
      expect(mock_span).to have_received(:record_exception).with(an_instance_of(RuntimeError))
    end

    it "sets error status on span" do
      action.call
      expect(mock_span).to have_received(:status=)
    end
  end

  context "with named action class" do
    let(:action) do
      build_axn do
        def self.name
          "TestAction"
        end
      end
    end

    it "uses class name as resource in span attributes" do
      action.call
      expect(mock_tracer).to have_received(:in_span).with("axn.call", hash_including(attributes: { "axn.resource" => "TestAction" }))
    end
  end

  describe "record_exception option" do
    context "when OpenTelemetry supports record_exception option" do
      before do
        allow(Axn::Internal::Tracing).to receive(:supports_record_exception_option?).and_return(true)
      end

      it "passes record_exception: false to in_span" do
        action = build_axn
        action.call
        expect(mock_tracer).to have_received(:in_span).with(
          "axn.call",
          attributes: { "axn.resource" => "AnonymousClass" },
          record_exception: false,
        )
      end
    end

    context "when OpenTelemetry does not support record_exception option" do
      before do
        allow(Axn::Internal::Tracing).to receive(:supports_record_exception_option?).and_return(false)
      end

      it "does not pass record_exception to in_span" do
        action = build_axn
        action.call
        expect(mock_tracer).to have_received(:in_span).with(
          "axn.call",
          attributes: { "axn.resource" => "AnonymousClass" },
        )
      end
    end
  end

  describe ".supports_record_exception_option?" do
    before do
      # Clear the cached value
      Axn::Internal::Tracing.remove_instance_variable(:@supports_record_exception) if Axn::Internal::Tracing.instance_variable_defined?(:@supports_record_exception)
    end

    it "caches the result" do
      # First call - will check OpenTelemetry
      first_result = Axn::Internal::Tracing.supports_record_exception_option?
      expect(Axn::Internal::Tracing.instance_variable_defined?(:@supports_record_exception)).to be true

      # Second call should return cached value
      second_result = Axn::Internal::Tracing.supports_record_exception_option?
      expect(first_result).to eq(second_result)
    end

    # NOTE: Testing the actual detection requires a real OpenTelemetry::Trace::Tracer class
    # with specific method signatures. The implementation uses introspection on the tracer's
    # in_span method parameters, which is tested indirectly through the integration tests above.
  end
end
