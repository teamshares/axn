# frozen_string_literal: true

RSpec.describe "Axn.config.tracer" do
  # OpenTelemetry is not a dependency of this gem, so it is absent unless a spec stubs it. That
  # makes "a configured tracer with OTel unloaded" the default state here.
  let(:fake_tracer) do
    Class.new do
      def in_span(*, **) = yield(nil)
    end.new
  end

  # A span stand-in shared by the examples below that need something for a fake tracer to yield.
  let(:fake_span) do
    Class.new do
      attr_reader :attributes

      def initialize = @attributes = {}
      def set_attribute(key, value) = @attributes[key] = value
      def record_exception(_exception) = nil
      def status=(_status); end
    end.new
  end

  after { Axn.config.reset!(:tracer) }

  it "auto-detects when unset" do
    expect(Axn::Internal::Tracing).to receive(:autodetected_tracer).and_return(fake_tracer)
    expect(Axn.config.tracer).to be(fake_tracer)
  end

  it "returns nil when unset and OpenTelemetry is absent" do
    expect(Axn.config.tracer).to be_nil
    expect(Axn.config.tracer?).to be(false)
  end

  it "returns a configured tracer without consulting auto-detection" do
    expect(Axn::Internal::Tracing).not_to receive(:autodetected_tracer)
    Axn.config.tracer = fake_tracer
    expect(Axn.config.tracer).to be(fake_tracer)
    expect(Axn.config.tracer?).to be(true)
  end

  it "treats an explicit nil as tracing disabled rather than as unset" do
    expect(Axn::Internal::Tracing).not_to receive(:autodetected_tracer)
    Axn.config.tracer = nil
    expect(Axn.config.tracer).to be_nil
    expect(Axn.config.tracer?).to be(false)
  end

  it "returns to auto-detection on reset!" do
    Axn.config.tracer = nil
    Axn.config.reset!(:tracer)
    expect(Axn::Internal::Tracing).to receive(:autodetected_tracer).and_return(fake_tracer)
    expect(Axn.config.tracer).to be(fake_tracer)
  end

  it "rejects an object that cannot receive a span, naming the contract" do
    expect { Axn.config.tracer = Object.new }.to raise_error(ArgumentError, /must respond to #in_span/)
  end

  it "rejects a callable, which would otherwise look like a lazy tracer" do
    expect { Axn.config.tracer = -> { fake_tracer } }.to raise_error(ArgumentError, /must respond to #in_span/)
  end

  describe "Axn::Internal::Tracing.autodetected_tracer" do
    it "is nil when OpenTelemetry is not loaded" do
      Axn::Internal::Tracing.reset!
      expect(Axn::Internal::Tracing.autodetected_tracer).to be_nil
    end
  end

  describe "the executor's span gate" do
    let(:recorder) do
      span = fake_span
      Class.new do
        attr_reader :calls

        define_method(:initialize) { @calls = [] }
        define_method(:in_span) do |name, **kwargs, &block|
          @calls << [name, kwargs]
          block.call(span)
        end
      end.new
    end

    it "creates a span through an injected tracer with OpenTelemetry not loaded" do
      expect(defined?(OpenTelemetry)).to be_nil
      Axn.config.tracer = recorder
      build_axn.call
      expect(recorder.calls).to eq([["axn.call", { attributes: { "axn.resource" => "Anonymous Axn" } }]])
    end

    it "creates no span when tracing is explicitly disabled" do
      Axn.config.tracer = nil
      expect(Axn::Internal::Tracing).not_to receive(:supports_record_exception_option?)
      expect(build_axn.call).to be_ok
    end

    it "passes record_exception: false only when the tracer's own in_span accepts it" do
      span = fake_span
      accepting = Class.new do
        attr_reader :kwargs

        define_method(:in_span) do |_name, record_exception: nil, **rest, &block|
          @kwargs = rest.merge(record_exception:)
          block.call(span)
        end
      end.new

      Axn.config.tracer = accepting
      build_axn.call
      expect(accepting.kwargs[:record_exception]).to be(false)

      # Negative case: a strict tracer whose #in_span never declares record_exception must never
      # receive it — sending it would raise ArgumentError outside best_effort and take the call
      # down. Without this half, the example above would pass even if the option were sent
      # unconditionally to every tracer.
      rejecting = Class.new do
        attr_reader :kwargs

        define_method(:in_span) do |_name, attributes:, &block|
          @kwargs = { attributes: }
          block.call(span)
        end
      end.new

      Axn.config.tracer = rejecting
      expect { build_axn.call }.not_to raise_error
      expect(rejecting.kwargs).to eq(attributes: { "axn.resource" => "Anonymous Axn" })
    end

    it "keeps using a configured tracer when the OpenTelemetry provider changes" do
      Axn.config.tracer = recorder
      otel = Module.new { def self.tracer_provider; end }
      stub_const("OpenTelemetry", otel)
      allow(OpenTelemetry).to receive(:tracer_provider).and_return(Object.new, Object.new)

      build_axn.call
      build_axn.call
      expect(recorder.calls.length).to eq(2)
    end
  end
end
