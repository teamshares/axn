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

  it "accepts a BasicObject proxy tracer, which cannot be introspected at all" do
    # Every reflection method lives on Object, so a BasicObject-based forwarder — the likeliest shape to
    # be wrapping a real tracer — has no `respond_to?` to ask. Rejecting it over the absence of a method
    # axn never needs would make the seam unusable for exactly that case.
    proxy = Class.new(BasicObject) do
      def in_span(_name, **) = yield(nil)
    end.new

    expect { Axn.config.tracer = proxy }.not_to raise_error
    expect(build_axn.call).to be_ok
  end

  it "rejects an object claiming to be nil rather than reading it as tracing-disabled" do
    liar = Class.new { def nil? = true }.new

    expect { Axn.config.tracer = liar }.to raise_error(ArgumentError, /must respond to #in_span/)
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

  # Tracing observes the call, so a misbehaving tracer must neither suppress nor duplicate it. Every
  # example here asserts the action ran EXACTLY once — the count, not just the outcome, is the point.
  describe "a tracer that misbehaves" do
    let(:runs) { [] }

    let(:counting_axn) do
      recorder = runs
      build_axn { define_method(:call) { recorder << :ran } }
    end

    after { Axn.config.reset!(:tracer) }

    it "runs the action exactly once when in_span returns without ever yielding" do
      Axn.config.tracer = Class.new { def in_span(*, **) = :never_yielded }.new

      expect(counting_axn.call).to be_ok
      expect(runs.size).to eq(1)
    end

    it "runs the action exactly once when in_span yields twice" do
      Axn.config.tracer = Class.new do
        define_method(:in_span) do |*, **, &block|
          block.call(nil)
          block.call(nil)
        end
      end.new

      expect(counting_axn.call).to be_ok
      expect(runs.size).to eq(1)
    end

    it "does not stamp an outcome on a span the action never ran inside" do
      # The result is still at its default `success` until the action settles, so finalizing a span the
      # action never entered would label a failed call as a successful one.
      span = Class.new do
        attr_reader :attributes

        def initialize = @attributes = {}
        def set_attribute(key, value) = @attributes[key] = value
        def record_exception(_exception) = nil
      end.new

      evented = Object.new
      evented.define_singleton_method(:start) { |*| raise "subscriber boom" }
      evented.define_singleton_method(:finish) { |*| nil }
      bad_subscriber = ActiveSupport::Notifications.subscribe("axn.call", evented)

      Axn.config.tracer = Class.new do
        define_method(:in_span) { |*, **, &block| block.call(span) }
      end.new
      failing = build_axn { def call = fail!("actually failed") }

      expect(failing.call.outcome.to_s).to eq("failure")
      expect(span.attributes).to be_empty
    ensure
      ActiveSupport::Notifications.unsubscribe(bad_subscriber)
    end

    it "does not re-enter a notification that already ran a subscriber's side effect" do
      # A subscriber can commit something and THEN raise. Retrying the notification in that state would
      # repeat the side effect, so a failure the notification itself caused is not retried.
      side_effects = []
      evented = Object.new
      evented.define_singleton_method(:start) do |*|
        side_effects << :notified
        raise "after side effect"
      end
      evented.define_singleton_method(:finish) { |*| nil }
      bad_subscriber = ActiveSupport::Notifications.subscribe("axn.call", evented)

      Axn.config.tracer = Class.new do
        define_method(:in_span) { |*, **, &block| block.call(nil) }
      end.new

      expect(counting_axn.call).to be_ok
      expect(side_effects.size).to eq(1)
      expect(runs.size).to eq(1)
    ensure
      ActiveSupport::Notifications.unsubscribe(bad_subscriber)
    end

    it "still emits the notification when it was the TRACER that failed before yielding" do
      events = []
      subscriber = ActiveSupport::Notifications.subscribe("axn.call") { |name, *| events << name }
      Axn.config.tracer = Class.new { def in_span(*, **) = raise("tracer down") }.new

      expect(counting_axn.call).to be_ok
      expect(events).to eq(["axn.call"])
      expect(runs.size).to eq(1)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    it "runs the action exactly once when an axn.call subscriber raises before the action starts" do
      # An EVENTED subscriber (one responding to start/finish) — not a lambda, which ActiveSupport
      # wraps as a timed subscriber that only runs at finish. `instrument` raises out of `start`, so
      # the action is never reached, and retrying the notification would fail identically: the fallback
      # has to run the action with the notification stripped off entirely.
      evented = Object.new
      evented.define_singleton_method(:start) { |*| raise "subscriber start boom" }
      evented.define_singleton_method(:finish) { |*| nil }
      bad_subscriber = ActiveSupport::Notifications.subscribe("axn.call", evented)

      Axn.config.tracer = Class.new do
        define_method(:in_span) { |*, **, &block| block.call(nil) }
      end.new

      expect(counting_axn.call).to be_ok
      expect(runs.size).to eq(1)
    ensure
      ActiveSupport::Notifications.unsubscribe(bad_subscriber)
    end

    it "does not start the action when a cancellation signal is in flight" do
      # The caller has abandoned this call, so the fallback must not fire: work that runs — and
      # possibly commits — after cancellation is a worse outcome than a lost span.
      Axn.config.tracer = Class.new { def in_span(*, **) = raise(Interrupt, "cancelled") }.new

      expect { counting_axn.call }.to raise_error(Interrupt)
      expect(runs.size).to eq(0)
    end

    it "propagates a failure from the wrapped stack instead of reporting a success" do
      # `with_logging` and `with_timing` run inside the traced block but OUTSIDE
      # `with_exception_handling`, so an error there is never settled onto the result. The tracing
      # guard must not absorb it — doing so hands the caller a default success for an action that
      # never ran, which is the worst possible outcome and strictly worse than no tracing at all.
      allow(Axn::Internal::Timing).to receive(:now).and_raise("clock unavailable")

      expect { counting_axn.call }.to raise_error("clock unavailable")
      expect(runs.size).to eq(0)
    end

    it "propagates a wrapped-stack failure that happens during the fallback notification too" do
      # The fallback path has its own guard, and it reaches `block.call` just as the main boundary
      # does — so the same rule has to hold there. Entered by failing the tracer before yield, then
      # failing the wrapped stack inside the fallback's notification attempt.
      Axn.config.tracer = Class.new { def in_span(*, **) = raise("tracer down") }.new
      allow(Axn::Internal::Timing).to receive(:now).and_raise("clock unavailable")

      expect { counting_axn.call }.to raise_error("clock unavailable")
      expect(runs.size).to eq(0)
    end

    it "propagates a wrapped-stack failure that the tracer itself swallowed" do
      # Rescuing around its own `yield` is ordinary tracer behavior — recording the exception is a
      # reason to do it. An observer returning normally is therefore not proof that the stack it
      # wrapped succeeded, so the failure cannot be left to propagate through the tracer.
      Axn.config.tracer = Class.new do
        define_method(:in_span) do |*, **, &block|
          block.call(nil)
        rescue StandardError
          :recorded_and_swallowed
        end
      end.new
      allow(Axn::Internal::Timing).to receive(:now).and_raise("clock unavailable")

      expect { counting_axn.call }.to raise_error("clock unavailable")
      expect(runs.size).to eq(0)
    end

    it "surfaces the wrapped stack's failure, not one the tracer raised in response to it" do
      # An exporter dying while it records an exception must not replace the call's real outcome with
      # its own error. The observer's failure is logged; the action's is what propagates.
      Axn.config.tracer = Class.new do
        define_method(:in_span) do |*, **, &block|
          block.call(nil)
        rescue StandardError
          raise "exporter failed"
        end
      end.new
      allow(Axn::Internal::Timing).to receive(:now).and_raise("clock unavailable")

      expect { counting_axn.call }.to raise_error("clock unavailable")
      expect(runs.size).to eq(0)
    end

    it "surfaces the wrapped stack's failure over the tracer's even in dev-loud mode" do
      # best_effort re-raises under best_effort_raises_in_dev, so logging the observer's error must
      # not be allowed to carry that error past the recorded one — in the environment where a
      # developer is most likely to be running.
      allow(Axn.config).to receive(:env).and_return(ActiveSupport::StringInquirer.new("development"))
      Axn.config.best_effort_raises_in_dev = true
      Axn.config.tracer = Class.new do
        define_method(:in_span) do |*, **, &block|
          block.call(nil)
        rescue StandardError
          raise "exporter failed"
        end
      end.new
      allow(Axn::Internal::Timing).to receive(:now).and_raise("clock unavailable")

      expect { counting_axn.call }.to raise_error("clock unavailable")
      expect(runs.size).to eq(0)
    ensure
      Axn.config.reset!(:best_effort_raises_in_dev)
    end

    it "surfaces a cancellation the tracer swallowed with a bare rescue Exception" do
      # A tracer wrapping its yield in `rescue Exception` can eat an Interrupt as easily as a
      # StandardError. A cancellation silently becoming a default success is the worst outcome here,
      # so every escaping class is recorded for re-raise — separately from what axn will settle.
      Axn.config.tracer = Class.new do
        define_method(:in_span) do |*, **, &block|
          block.call(nil)
        rescue Exception # rubocop:disable Lint/RescueException
          :swallowed
        end
      end.new
      allow(Axn::Internal::Timing).to receive(:now).and_raise(Interrupt, "cancelled")

      expect { counting_axn.call }.to raise_error(Interrupt)
      expect(runs.size).to eq(0)
    end

    it "refuses to report success when the tracer catches a throw from the wrapped stack" do
      # A `throw` cannot be re-thrown once an observer has caught it — the tag and value are gone. So
      # this is the one case axn cannot make transparent; it fails loudly instead of reporting a
      # success for an action that never completed.
      Axn.config.tracer = Class.new do
        define_method(:in_span) { |*, **, &block| catch(:cancel) { block.call(nil) } }
      end.new
      allow(Axn::Internal::Timing).to receive(:now) { throw(:cancel, :from_stack) }

      expect { counting_axn.call }.to raise_error(/absorbed a non-local exit from the action/)
      expect(runs.size).to eq(0)
    end

    it "does not start the action when the tracer throws instead of raising" do
      # A `throw` unwinds with NO exception in flight, so resumability cannot be inferred from `$!`
      # being absent — it has to come from the guarded step reporting that it returned normally.
      Axn.config.tracer = Class.new { def in_span(*, **) = throw(:cancel, :thrown) }.new

      expect(catch(:cancel) do
        counting_axn.call
        :no_throw
      end).to eq(:thrown)
      expect(runs.size).to eq(0)
    end

    it "does not start the action when a notification subscriber throws" do
      evented = Object.new
      evented.define_singleton_method(:start) { |*| throw(:cancel, :from_subscriber) }
      evented.define_singleton_method(:finish) { |*| nil }
      subscriber = ActiveSupport::Notifications.subscribe("axn.call", evented)
      Axn.config.tracer = Class.new do
        define_method(:in_span) { |*, **, &block| block.call(nil) }
      end.new

      expect(catch(:cancel) do
        counting_axn.call
        :no_throw
      end).to eq(:from_subscriber)
      expect(runs.size).to eq(0)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    it "does not start the action when an enclosing Timeout fires while the tracer stalls" do
      require "timeout"
      Axn.config.tracer = Class.new { def in_span(*, **) = sleep(5) }.new

      expect { Timeout.timeout(0.2) { counting_axn.call } }.to raise_error(Timeout::Error)
      expect(runs.size).to eq(0)
    end

    it "runs the action exactly once when resolving the tracer itself raises" do
      # Tracer DISCOVERY is a side channel too: a faulty OpenTelemetry provider must not cost the
      # action its run, even though the failure happens before there is any span to speak of.
      otel = Module.new { def self.tracer_provider = raise("provider exploded") }
      stub_const("OpenTelemetry", otel)
      Axn::Internal::Tracing.reset!

      expect(counting_axn.call).to be_ok
      expect(runs.size).to eq(1)
    end

    it "runs the action exactly once even when a tracing failure is re-raised dev-loud" do
      # best_effort re-raises under best_effort_raises_in_dev. The developer should see the tracing
      # error, but it must not swallow the action's execution on the way out.
      allow(Axn.config).to receive(:env).and_return(ActiveSupport::StringInquirer.new("development"))
      Axn.config.best_effort_raises_in_dev = true
      Axn.config.tracer = Class.new { def in_span(*, **) = raise("down before yield") }.new

      expect { counting_axn.call }.to raise_error("down before yield")
      expect(runs.size).to eq(1)
    ensure
      Axn.config.reset!(:best_effort_raises_in_dev)
    end

    it "runs the action exactly once when in_span raises before yielding" do
      Axn.config.tracer = Class.new { def in_span(*, **) = raise("backend down") }.new

      expect(counting_axn.call).to be_ok
      expect(runs.size).to eq(1)
    end

    it "swallows a failure raised after the action has run, keeping the settled result" do
      # `with_exception_handling` runs inside `with_tracing`, so by the time `in_span` regains control
      # the action's own outcome is already on the result — anything raised here is the span export
      # failing, and must not convert a settled success into a raise from `.call`.
      Axn.config.tracer = Class.new do
        define_method(:in_span) do |*, **, &block|
          block.call(nil)
          raise "flush failed"
        end
      end.new

      expect(counting_axn.call).to be_ok
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
      # Trace::Span must exist for these examples to mean anything: axn gates the status assignment on
      # the span BEING an OpenTelemetry span, so without this constant the branch is unreachable and
      # every "custom span gets no status" example below would pass without testing anything. None of
      # the spans in this describe are instances of it — that is the point.
      trace_module.const_set(:Span, Class.new)
      otel_module = Module.new
      otel_module.const_set(:Trace, trace_module)
      stub_const("OpenTelemetry", otel_module)

      Axn.config.tracer = tracer
    end

    it "does not hand an OpenTelemetry Status to a custom span that has its own status=" do
      # `status=` on a non-OpenTelemetry span means that span's OWN status type. Axn can only build an
      # OpenTelemetry::Trace::Status, so it must not offer one here on the strength of the name alone.
      own_status_span = Class.new do
        attr_reader :assigned_status

        def set_attribute(_key, _value) = nil

        def status=(value)
          @assigned_status = value
        end
      end.new

      Axn.config.tracer = Class.new do
        define_method(:initialize) { @span = own_status_span }
        define_method(:in_span) { |_name, **, &block| block.call(@span) }
      end.new

      failing_axn.call
      expect(own_status_span.assigned_status).to be_nil
    end

    it "records the exception on a BasicObject span, which cannot answer respond_to?" do
      recorded = []
      span = Class.new(BasicObject) do
        define_method(:set_attribute) { |_key, _value| nil }
        define_method(:record_exception) { |exception| recorded << exception.message }
      end.new

      Axn.config.tracer = Class.new do
        define_method(:in_span) { |_name, **, &block| block.call(span) }
      end.new

      failing_axn.call
      expect(recorded).to eq(["nope"])
    end

    it "records the exception on a span whose respond_to? answers false" do
      recorded = []
      span = Class.new do
        def set_attribute(_key, _value) = nil
        def respond_to?(*) = false

        define_method(:record_exception) { |exception| recorded << exception.message }
      end.new

      Axn.config.tracer = Class.new do
        define_method(:in_span) { |_name, **, &block| block.call(span) }
      end.new

      failing_axn.call
      expect(recorded).to eq(["nope"])
    end

    it "does not hand a status to a span that merely claims to be an OpenTelemetry span" do
      # The span is caller-supplied, so its own `is_a?` is not evidence of anything.
      liar = Class.new do
        attr_reader :assigned_status

        def set_attribute(_key, _value) = nil
        def is_a?(_klass) = true

        def status=(value)
          @assigned_status = value
        end
      end.new

      Axn.config.tracer = Class.new do
        define_method(:initialize) { @span = liar }
        define_method(:in_span) { |_name, **, &block| block.call(@span) }
      end.new

      failing_axn.call
      expect(liar.assigned_status).to be_nil
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
