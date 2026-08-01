# frozen_string_literal: true

RSpec.describe "Axn::Internal::Tracing OpenTelemetry" do
  let(:mock_tracer) { instance_double("OpenTelemetry::Trace::Tracer") }
  let(:mock_tracer_provider) { instance_double("OpenTelemetry::Trace::TracerProvider") }

  # A real class registered as OpenTelemetry::Trace::Span below, rather than a double: axn decides
  # whether to hand a span an `OpenTelemetry::Trace::Status` by asking whether it IS an OpenTelemetry
  # span, so the fake has to actually be one for these examples to exercise that path.
  let(:otel_span_class) do
    Class.new do
      def set_attribute(_key, _value); end
      def record_exception(_exception); end
      def status=(_status); end
    end
  end
  let(:mock_span) { otel_span_class.new }

  before do
    # Save original OpenTelemetry if it exists
    @original_otel = defined?(OpenTelemetry) ? OpenTelemetry : nil

    # Create a simple OpenTelemetry module that we'll stub methods on. Declaring the
    # methods we stub lets verify_partial_doubles confirm they really exist on the fake.
    otel_module = Module.new { def self.tracer_provider; end }
    trace_module = Module.new
    status_class = Class.new
    mock_status = instance_double("Status")
    status_class.define_singleton_method(:error) { |_msg| mock_status }
    trace_module.const_set(:Status, status_class)
    trace_module.const_set(:Span, otel_span_class)
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
    # Clear the memos so the next example re-detects against the restored OpenTelemetry.
    Axn::Internal::Tracing.reset!

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
      expect(mock_tracer).to have_received(:in_span).with("axn.call", hash_including(attributes: { "axn.resource" => "Anonymous Axn" }))
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
          attributes: { "axn.resource" => "Anonymous Axn" },
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
          attributes: { "axn.resource" => "Anonymous Axn" },
        )
      end
    end
  end

  describe ".autodetected_tracer" do
    it "retries discovery after a provider fails to supply a tracer, rather than pinning the old one" do
      # Recording the new provider before its tracer exists would leave a mismatched pair that the
      # cache check reads as a hit — spans would go to the previous provider forever.
      # The SAME replacement provider has to still be current on the retry — that is what makes a
      # half-published pair read as a cache hit. A different provider on the third call would sidestep
      # the bug entirely by forcing a re-fetch for an unrelated reason.
      first = Object.new
      first.define_singleton_method(:tracer) { |*| :tracer_v1 }

      attempts = 0
      flaky = Object.new
      flaky.define_singleton_method(:tracer) do |*|
        attempts += 1
        raise "provider not ready" if attempts == 1

        :tracer_v2
      end

      providers = [first, flaky, flaky]
      allow(OpenTelemetry).to receive(:tracer_provider) { providers.shift || flaky }
      Axn::Internal::Tracing.reset!

      expect(Axn::Internal::Tracing.autodetected_tracer).to eq(:tracer_v1)
      expect { Axn::Internal::Tracing.autodetected_tracer }.to raise_error("provider not ready")
      expect(Axn::Internal::Tracing.autodetected_tracer).to eq(:tracer_v2)
    end
  end

  describe ".supports_record_exception_option?" do
    let(:accepting) { Class.new { def in_span(_name, record_exception: nil); end }.new }
    let(:rejecting) { Class.new { def in_span(_name, attributes: nil); end }.new }
    let(:splatting) { Class.new { def in_span(_name, **opts); end }.new }
    let(:positional) { Class.new { def in_span(_name, record_exception); end }.new }

    before { Axn::Internal::Tracing.reset! }

    it "reads the option off the tracer's own signature" do
      expect(Axn::Internal::Tracing.supports_record_exception_option?(accepting)).to be(true)
      expect(Axn::Internal::Tracing.supports_record_exception_option?(rejecting)).to be(false)
    end

    it "reads a **opts tracer as unsupported, since passing the option to a strict tracer would raise" do
      expect(Axn::Internal::Tracing.supports_record_exception_option?(splatting)).to be(false)
    end

    it "reads a positional parameter that merely shares the name as unsupported" do
      # `.method(:in_span).parameters` here is [[:req, :_name], [:req, :record_exception]] — the
      # name matches but the type doesn't, distinguishing this from the keyword case above.
      expect(Axn::Internal::Tracing.supports_record_exception_option?(positional)).to be(false)
    end

    # A configured tracer promises #in_span and nothing else, so the memo must not dispatch identity
    # or nil-ness to it — that would run on every call after the first, outside the probe's rescue.
    it "does not dispatch equal? or nil? to the tracer" do
      hostile = Class.new do
        def in_span(_name, record_exception: nil); end
        def equal?(_other) = raise("tracer#equal? must not be called")
        def nil? = raise("tracer#nil? must not be called")
      end.new

      expect(Axn::Internal::Tracing.supports_record_exception_option?(hostile)).to be(true)
      # Second call goes through the memo comparison, which is where a dispatched equal? would fire.
      expect(Axn::Internal::Tracing.supports_record_exception_option?(hostile)).to be(true)
    end

    it "is false for no tracer at all" do
      expect(Axn::Internal::Tracing.supports_record_exception_option?(nil)).to be(false)
    end

    it "does not leak one tracer's answer to another" do
      expect(Axn::Internal::Tracing.supports_record_exception_option?(accepting)).to be(true)
      expect(Axn::Internal::Tracing.supports_record_exception_option?(rejecting)).to be(false)
      expect(Axn::Internal::Tracing.supports_record_exception_option?(accepting)).to be(true)
    end

    it "memoizes the answer for a repeated tracer" do
      allow(accepting).to receive(:method).and_call_original
      2.times { Axn::Internal::Tracing.supports_record_exception_option?(accepting) }
      expect(accepting).to have_received(:method).with(:in_span).once
    end
  end
end
