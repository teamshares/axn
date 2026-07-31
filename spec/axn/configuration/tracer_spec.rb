# frozen_string_literal: true

RSpec.describe "Axn.config.tracer" do
  # OpenTelemetry is not a dependency of this gem, so it is absent unless a spec stubs it. That
  # makes "a configured tracer with OTel unloaded" the default state here.
  let(:fake_tracer) do
    Class.new do
      def in_span(*, **) = yield(nil)
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
end
