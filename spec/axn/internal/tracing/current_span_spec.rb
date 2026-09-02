# frozen_string_literal: true

# PRO-3278: axn opens an `axn.call` span per action (`Executor#emit_observed`) but never stored or
# exposed a reference to it, so a consumer wanting to annotate its own span had to ask OpenTelemetry
# "what's current" — `OpenTelemetry::Trace.current_span`, resolved through `OpenTelemetry::Context.current`,
# which is ambient, mutable, process-wide state that anything else running mid-chain can move (verified
# against the Datadog OTel bridge in production; the general failure is not specific to it). This suite
# proves the REPLACEMENT: `Internal::Tracing.current_span` is always the span the CURRENT action's own
# tracer yielded, never an ancestor's, independent of whatever the ambient lookup answers.
RSpec.describe "Axn::Internal::Tracing.current_span" do
  # A tracer that yields a FRESH, distinct span object on every call — unlike the single canned
  # `mock_span` in opentelemetry_spec.rb, needed here so nesting examples can tell "my own span" apart
  # from a parent's or sibling's by identity.
  let(:distinct_span_tracer) do
    Class.new do
      def in_span(*, **)
        span = Class.new do
          attr_reader :attributes

          def initialize = @attributes = {}
          def set_attribute(key, value) = @attributes[key] = value
        end.new
        yield(span)
      end
    end.new
  end

  after { Axn.config.reset!(:tracer) }

  describe "the headline defect: ambient lookup disagrees with axn's own span" do
    before do
      otel_module = Module.new { def self.tracer_provider; end }
      trace_module = Module.new
      # A sentinel visibly unrelated to anything a real tracer would yield — the honest
      # generalization of the production reading (Span::INVALID), not a special-cased stand-in for it.
      trace_module.define_singleton_method(:current_span) { :not_my_span }
      otel_module.const_set(:Trace, trace_module)
      stub_const("OpenTelemetry", otel_module)
      Axn.config.tracer = distinct_span_tracer
    end

    it "shows the bug as a property: the ambient lookup never matches what this level's own tracer yielded" do
      seen = []
      innermost = build_axn { define_method(:call) { seen << [:innermost, OpenTelemetry::Trace.current_span, Axn::Internal::Tracing.current_span] } }
      middle = build_axn do
        define_method(:call) do
          seen << [:middle, OpenTelemetry::Trace.current_span, Axn::Internal::Tracing.current_span]
          innermost.call
        end
      end
      outer = build_axn do
        define_method(:call) do
          seen << [:outer, OpenTelemetry::Trace.current_span, Axn::Internal::Tracing.current_span]
          middle.call
        end
      end

      outer.call

      seen.each do |_level, ambient, own|
        expect(ambient).to eq(:not_my_span)
        expect(ambient).not_to equal(own)
      end
    end

    it "resolves to the exact span each level's own tracer yielded, in a 3-deep nested chain" do
      spans = {}
      innermost = build_axn { define_method(:call) { spans[:innermost] = Axn::Internal::Tracing.current_span } }
      middle = build_axn do
        define_method(:call) do
          spans[:middle_before] = Axn::Internal::Tracing.current_span
          innermost.call
          spans[:middle_after] = Axn::Internal::Tracing.current_span
        end
      end
      outer = build_axn do
        define_method(:call) do
          spans[:outer_before] = Axn::Internal::Tracing.current_span
          middle.call
          spans[:outer_after] = Axn::Internal::Tracing.current_span
        end
      end

      outer.call

      expect(spans[:innermost]).not_to be_nil
      expect(spans.values.compact.map(&:object_id).uniq.size).to eq(3), "expected 3 distinct spans (outer, middle, innermost)"
      # The parent sees its OWN span again once the child returns — not the child's, not nil.
      expect(spans[:middle_before]).to equal(spans[:middle_after])
      expect(spans[:outer_before]).to equal(spans[:outer_after])
    end

    it "does not leak a sibling's span: sequential children never see each other's span" do
      spans = {}
      first_child = build_axn { define_method(:call) { spans[:first] = Axn::Internal::Tracing.current_span } }
      second_child = build_axn { define_method(:call) { spans[:second] = Axn::Internal::Tracing.current_span } }
      parent = build_axn do
        define_method(:call) do
          first_child.call
          second_child.call
        end
      end

      parent.call

      expect(spans[:first]).not_to equal(spans[:second])
    end
  end

  describe "nil-ness" do
    it "is nil when the tracer is explicitly nil" do
      Axn.config.tracer = nil
      seen = nil
      build_axn { define_method(:call) { seen = Axn::Internal::Tracing.current_span } }.call

      expect(seen).to be_nil
    end

    it "is nil when unset and OpenTelemetry is absent (the suite default)" do
      expect(defined?(OpenTelemetry)).to be_nil
      seen = nil
      build_axn { define_method(:call) { seen = Axn::Internal::Tracing.current_span } }.call

      expect(seen).to be_nil
    end

    it "is nil when the tracer yields nil as the span" do
      Axn.config.tracer = Class.new { def in_span(*, **) = yield(nil) }.new
      seen = :unset
      build_axn { define_method(:call) { seen = Axn::Internal::Tracing.current_span } }.call

      expect(seen).to be_nil
    end

    it "is nil in the body when the tracer returns without ever yielding (the untraced fallback)" do
      Axn.config.tracer = Class.new { def in_span(*, **) = :never_yielded }.new
      seen = :unset
      build_axn { define_method(:call) { seen = Axn::Internal::Tracing.current_span } }.call

      expect(seen).to be_nil
    end

    it "is nil in the body when the tracer raises before yielding (fallback runs untraced)" do
      Axn.config.tracer = Class.new { def in_span(*, **) = raise("tracer down") }.new
      seen = :unset
      build_axn { define_method(:call) { seen = Axn::Internal::Tracing.current_span } }.call

      expect(seen).to be_nil
    end

    it "sees only the FIRST span when the tracer yields twice; the second yield never overwrites it" do
      spans = []
      Axn.config.tracer = Class.new do
        define_method(:in_span) do |*, **, &block|
          first_span = Object.new.tap { |s| s.define_singleton_method(:set_attribute) { |*, **| } }
          second_span = Object.new.tap { |s| s.define_singleton_method(:set_attribute) { |*, **| } }
          block.call(first_span)
          block.call(second_span)
        end
      end.new
      build_axn { define_method(:call) { spans << Axn::Internal::Tracing.current_span } }.call

      expect(spans.size).to eq(1)
    end

    it "does not fall back to an ancestor's span when this action's own in_span never yields" do
      seen = {}
      child = build_axn { define_method(:call) { seen[:child] = Axn::Internal::Tracing.current_span } }
      parent = build_axn do
        define_method(:call) do
          seen[:parent] = Axn::Internal::Tracing.current_span
          child.call
        end
      end

      # Force only the child's own `in_span` to decline, by toggling on nesting depth: the outer
      # call is depth 1 (parent, gets a span), the inner is depth 2 (child, never yielded).
      tracer = Class.new do
        def initialize = @depth = 0

        def in_span(*, **, &block)
          @depth += 1
          return :never_yielded if @depth == 2

          block.call(Object.new.tap { |s| s.define_singleton_method(:set_attribute) { |*, **| } })
        ensure
          @depth -= 1
        end
      end.new
      Axn.config.tracer = tracer

      parent.call

      expect(seen[:parent]).not_to be_nil
      expect(seen[:child]).to be_nil
    end
  end

  describe "lifetime / retention" do
    it "is nil after .call returns" do
      Axn.config.tracer = distinct_span_tracer
      build_axn.call

      expect(Axn::Internal::Tracing.current_span).to be_nil
    end

    it "does not retain a live span on the action instance carried by the axn.call notification payload" do
      Axn.config.tracer = distinct_span_tracer
      captured_action = nil
      subscriber = ActiveSupport::Notifications.subscribe("axn.call") { |*, payload| captured_action = payload[:action] }

      build_axn.call

      expect(captured_action).not_to be_nil
      expect(Axn::Internal::NativeMethods.ivar_get(captured_action, Axn::Internal::Tracing::SPAN_IVAR)).to be_nil
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    it "does not retain a live span on the action instance a global on_exception handler captures" do
      Axn.config.tracer = distinct_span_tracer
      captured_action = nil
      Axn.config.on_exception = ->(_e, action:, **) { captured_action = action }
      failing = build_axn { def call = raise("boom") }

      failing.call

      expect(captured_action).not_to be_nil
      expect(Axn::Internal::NativeMethods.ivar_get(captured_action, Axn::Internal::Tracing::SPAN_IVAR)).to be_nil
    ensure
      Axn.config.on_exception = nil
    end

    it "never sets a span when the tracer stores the block and invokes it after the boundary exits" do
      holder = Class.new do
        attr_reader :saved

        def in_span(*, **, &block)
          @saved = block
          raise Interrupt
        end
      end.new
      Axn.config.tracer = holder

      expect { build_axn.call }.to raise_error(Interrupt)

      span = Object.new.tap { |s| s.define_singleton_method(:set_attribute) { |*, **| } }
      holder.saved.call(span)

      expect(Axn::Internal::Tracing.current_span).to be_nil
    end

    it "still removes the span reference when span finalization raises a signal" do
      # `Axn::Internal::Tracing.current_span` alone cannot tell "the ivar was cleared" apart from
      # "the nesting stack is simply empty again" once `.call` has returned — both read nil either
      # way. Capture the action instance itself (via the `axn.call` notification, which still fires
      # on the way out even though the call goes on to raise) and read its ivar directly.
      captured_action = nil
      subscriber = ActiveSupport::Notifications.subscribe("axn.call") { |*, payload| captured_action = payload[:action] }

      raising_span = Object.new
      raising_span.define_singleton_method(:set_attribute) { |*, **| raise NoMemoryError, "span boom" }
      Axn.config.tracer = Class.new { define_method(:in_span) { |*, **, &block| block.call(raising_span) } }.new
      failing = build_axn { def call = fail!("nope") }

      expect { failing.call }.to raise_error(NoMemoryError)
      expect(captured_action).not_to be_nil
      expect(Axn::Internal::NativeMethods.ivar_get(captured_action, Axn::Internal::Tracing::SPAN_IVAR)).to be_nil
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    it "does not raise when an action freezes itself mid-body, though the ended span is unavoidably retained" do
      # `remove_instance_variable` cannot mutate a frozen object at all, so cleanup checks `frozen?`
      # first and skips rather than raising (PRO-3278 review). This does not — cannot — actually free
      # the ivar: nothing can strip state off an object Ruby has frozen. The freeze itself already
      # breaks other axn machinery unrelated to this seam (`Executor#action_result_finalized?`'s own
      # memoization raises `FrozenError`, reproduced identically on the pre-PR baseline) — out of scope
      # here; this only confirms the span cleanup added by this PR is not what's escaping.
      Axn.config.tracer = distinct_span_tracer
      captured_action = nil
      subscriber = ActiveSupport::Notifications.subscribe("axn.call") { |*, payload| captured_action = payload[:action] }
      klass = build_axn { define_method(:call) { freeze } }

      expect { klass.call }.to raise_error(FrozenError) # the pre-existing, unrelated crash

      expect(captured_action).not_to be_nil
      expect(captured_action).to be_frozen
      expect(Axn::Internal::NativeMethods.ivar_get(captured_action, Axn::Internal::Tracing::SPAN_IVAR)).not_to be_nil
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end
  end

  describe "where it can be read from" do
    it "is visible from before/after/around hooks" do
      Axn.config.tracer = distinct_span_tracer
      seen = {}
      klass = build_axn do
        before { seen[:before] = Axn::Internal::Tracing.current_span }
        after { seen[:after] = Axn::Internal::Tracing.current_span }
        around do |chain|
          seen[:around_before] = Axn::Internal::Tracing.current_span
          chain.call
          seen[:around_after] = Axn::Internal::Tracing.current_span
        end
        def call
          @seen = Axn::Internal::Tracing.current_span
        end
      end

      klass.call

      seen.each_value { |span| expect(span).not_to be_nil }
    end

    it "is visible from an on_exception callback" do
      Axn.config.tracer = distinct_span_tracer
      seen = nil
      failing = build_axn do
        on_exception { seen = Axn::Internal::Tracing.current_span }
        def call = raise("boom")
      end

      failing.call

      expect(seen).not_to be_nil
    end

    it "is nil from Axn.config.emit_metrics (runs outside the span, in with_tracing's own outer ensure)" do
      Axn.config.tracer = distinct_span_tracer
      seen = :unset
      Axn.config.emit_metrics = ->(**) { seen = Axn::Internal::Tracing.current_span }

      build_axn.call

      expect(seen).to be_nil
    ensure
      Axn.config.reset!(:emit_metrics)
    end

    it "is nil outside any action" do
      expect(Axn::Internal::Tracing.current_span).to be_nil
    end

    it "is nil from a thread the action body itself spawned" do
      Axn.config.tracer = distinct_span_tracer
      seen = :unset
      build_axn { define_method(:call) { Thread.new { seen = Axn::Internal::Tracing.current_span }.join } }.call

      expect(seen).to be_nil
    end

    it "gives each of two concurrently-running actions of the same class only its own span" do
      Axn.config.tracer = distinct_span_tracer
      results = Queue.new
      klass = build_axn do
        define_method(:call) do
          sleep 0.01
          results << Axn::Internal::Tracing.current_span
        end
      end

      threads = 2.times.map { Thread.new { klass.call } }
      threads.each(&:join)

      first = results.pop
      second = results.pop
      expect(first).not_to equal(second)
    end
  end

  describe "reader safety" do
    it "still returns the real span when the action class overrides instance_variable_get for that one ivar" do
      Axn.config.tracer = distinct_span_tracer
      seen = :unset
      klass = build_axn do
        span_ivar = Axn::Internal::Tracing::SPAN_IVAR
        define_method(:instance_variable_get) { |name| name == span_ivar ? "hijacked" : super(name) }
        define_method(:call) { seen = Axn::Internal::Tracing.current_span }
      end

      klass.call

      expect(seen).not_to eq("hijacked")
      expect(seen).not_to be_nil
    end

    it "still returns the real span when the action class's instance_variable_get raises for that one ivar" do
      Axn.config.tracer = distinct_span_tracer
      seen = :unset
      klass = build_axn do
        span_ivar = Axn::Internal::Tracing::SPAN_IVAR
        define_method(:instance_variable_get) { |name| name == span_ivar ? raise("sabotage") : super(name) }
        define_method(:call) { seen = Axn::Internal::Tracing.current_span }
      end

      klass.call

      expect(seen).not_to be_nil
    end
  end

  describe "isolation-mismatch defense (PRO-3278)" do
    it "returns nil rather than a possibly-wrong span once the fiber-isolation mismatch has been detected" do
      Axn.config.tracer = distinct_span_tracer
      seen = :unset
      allow(Axn::Core::NestingTracking).to receive(:isolation_unsafe?).and_return(true)

      build_axn { define_method(:call) { seen = Axn::Internal::Tracing.current_span } }.call

      expect(seen).to be_nil
    end

    it "refuses a span belonging to a different fiber even with no scheduler installed (PRO-3278 round-2 review)" do
      # `isolation_unsafe?` only sees a Fiber SCHEDULER mismatch — manually interleaved Fibers (no
      # scheduler at all) share `Thread.current`, and so share `_current_axn_stack` under
      # `isolation_level == :thread` regardless. Reproduced directly: fiber A pushes and yields
      # mid-body, fiber B pushes and yields mid-body, A resumes — `Core::NestingTracking.current_axn`
      # genuinely resolves to B's action, not A's. `current_span` must still refuse to hand back B's
      # span to A: it tags each published span with the thread+fiber that set it and checks that tag
      # against the actual caller, independent of whatever `current_axn` (wrongly) resolved to.
      expect(Fiber.scheduler).to be_nil # confirms no scheduler is involved in this reproduction at all

      span_a = Object.new.tap { |s| s.define_singleton_method(:set_attribute) { |*, **| } }
      span_b = Object.new.tap { |s| s.define_singleton_method(:set_attribute) { |*, **| } }
      seen_by_a = :unset

      klass_a = build_axn do
        define_method(:call) do
          Fiber.yield
          seen_by_a = Axn::Internal::Tracing.current_span
        end
      end
      klass_b = build_axn { define_method(:call) { Fiber.yield } }

      Axn.config.tracer = Class.new { define_method(:in_span) { |*, **, &block| block.call(span_a) } }.new
      fiber_a = Fiber.new { klass_a.call }

      Axn.config.tracer = Class.new { define_method(:in_span) { |*, **, &block| block.call(span_b) } }.new
      fiber_b = Fiber.new { klass_b.call }

      fiber_a.resume # push A onto the shared stack, then suspend before A's own pop
      fiber_b.resume # push B on top, then suspend before B's own pop — stack is now [A, B]
      fiber_a.resume # A resumes; current_axn wrongly resolves to B, but current_span must still refuse it

      # A's `ensure` pops the TOP of the shared stack — B's frame, not its own — so A's frame is what
      # remains here (verified: depth 1, and it is A's). Resume B so its own `ensure` pops that and the
      # stack lands back at zero. Without this the abandoned Fiber strands a frame for the rest of the
      # PROCESS, which silently prepends a phantom entry to `axn_stack` in every example that runs
      # afterwards — invisible in defined order, ~30 failures under a reversed or randomised one.
      fiber_b.resume

      expect(seen_by_a).to be_nil
      expect(seen_by_a).not_to equal(span_b)
    end
  end
end
