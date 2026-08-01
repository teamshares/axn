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

    it "creates no span when tracing is explicitly disabled, even with OpenTelemetry loaded" do
      # A bare-`defined?(OpenTelemetry)` gate would still try to trace here; stubbing the constant
      # in without a real tracer_provider proves the gate is Axn.config.tracer, not the constant.
      stub_const("OpenTelemetry", Module.new)
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
      # A configured tracer is returned without ever reaching auto-detection, so there is no path
      # from which a changing tracer_provider could clobber it — prove the structural claim rather
      # than just asserting the observable outcome.
      expect(OpenTelemetry).not_to receive(:tracer_provider)

      build_axn.call
      build_axn.call
      expect(recorder.calls.length).to eq(2)
    end
  end

  describe "span finalization without OpenTelemetry" do
    let(:tracer) do
      span = fake_span
      Class.new do
        define_method(:initialize) { @span = span }
        define_method(:in_span) { |_name, **, &block| block.call(@span) }
      end.new
    end

    let(:failing_axn) do
      build_axn do
        tag :account, -> { "acct-1" }
        dimension :kind, -> { "widget" }

        def call = fail!("nope")
      end
    end

    before { Axn.config.tracer = tracer }

    it "records declared facets on the span even though the OTel Status class is absent" do
      expect(defined?(OpenTelemetry)).to be_nil
      failing_axn.call
      expect(fake_span.attributes).to include(
        "axn.outcome" => "failure",
        "axn.tag.account" => "acct-1",
        "axn.dimension.kind" => "widget",
      )
    end

    it "still records the exception on the span" do
      expect(fake_span).to receive(:record_exception)
      failing_axn.call
    end
  end

  describe "a tracer that raises" do
    let(:runs) { [] }

    let(:counting_axn) do
      recorder = runs
      build_axn { define_method(:call) { recorder << :ran } }
    end

    after { Axn.config.reset!(:tracer) }

    it "runs the action exactly once when in_span raises before yielding" do
      Axn.config.tracer = Class.new { def in_span(*, **) = raise("backend down") }.new

      expect(counting_axn.call).to be_ok
      expect(runs.size).to eq(1)
    end

    it "does not absorb a failure raised after the action has run" do
      Axn.config.tracer = Class.new do
        define_method(:in_span) do |*, **, &block|
          block.call(nil)
          raise "flush failed"
        end
      end.new

      expect { counting_axn.call }.to raise_error("flush failed")
      expect(runs.size).to eq(1)
    end

    it "still settles the action's own exception onto the result rather than re-running it" do
      Axn.config.tracer = Class.new do
        define_method(:in_span) { |*, **, &block| block.call(nil) }
      end.new
      recorder = runs
      raising_axn = build_axn do
        define_method(:call) do
          recorder << :ran
          raise ArgumentError, "boom"
        end
      end

      result = raising_axn.call
      expect(result.outcome.to_s).to eq("exception")
      expect(runs.size).to eq(1)
    end
  end

  # A configured tracer is expressly allowed to coexist with a loaded OpenTelemetry — overriding axn's
  # spans without unloading OTel is one of the reasons the seam exists. So the presence of OTel's
  # classes says nothing about whether THIS span implements their optional methods.
  describe "span finalization with OpenTelemetry loaded but a custom span" do
    let(:minimal_span) do
      # Implements only what a configured tracer's span is asked for: set_attribute.
      Class.new do
        attr_reader :attributes

        def initialize = @attributes = {}
        def set_attribute(key, value) = @attributes[key] = value
      end.new
    end

    let(:tracer) do
      span = minimal_span
      Class.new do
        define_method(:initialize) { @span = span }
        define_method(:in_span) { |_name, **, &block| block.call(@span) }
      end.new
    end

    let(:failing_axn) do
      build_axn do
        tag :account, -> { "acct-1" }
        dimension :kind, -> { "widget" }

        def call = fail!("nope")
      end
    end

    before do
      status_class = Class.new { def self.error(_message) = :error_status }
      trace_module = Module.new
      trace_module.const_set(:Status, status_class)
      otel_module = Module.new
      otel_module.const_set(:Trace, trace_module)
      stub_const("OpenTelemetry", otel_module)

      Axn.config.tracer = tracer
    end

    it "records declared facets even though the span implements neither record_exception nor status=" do
      expect(minimal_span).not_to respond_to(:record_exception)
      expect(minimal_span).not_to respond_to(:status=)

      failing_axn.call

      expect(minimal_span.attributes).to include(
        "axn.outcome" => "failure",
        "axn.tag.account" => "acct-1",
        "axn.dimension.kind" => "widget",
      )
    end

    it "records declared facets even when the span's own record_exception raises" do
      raising_span = minimal_span
      raising_span.define_singleton_method(:record_exception) { |_exception| raise "span exploded" }

      failing_axn.call

      expect(raising_span.attributes).to include(
        "axn.tag.account" => "acct-1",
        "axn.dimension.kind" => "widget",
      )
    end
  end
end
