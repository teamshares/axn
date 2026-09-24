# frozen_string_literal: true

# PRO-3278 review: `isolation_unsafe?` must answer for the THREAD asking, not for the process. It backs
# `Internal::Tracing.current_span`'s isolation-mismatch guard, and the two conditions it checks
# (`Fiber.scheduler`, per-thread; `isolation_level`, process-wide) are read live rather than cached, so a
# hybrid process — some threads running under a scheduler, others not — doesn't have one scheduler-bearing
# thread's mismatch permanently blind every other, unrelated thread for the rest of the process.
RSpec.describe "Axn::Core::NestingTracking.isolation_unsafe?" do
  after { Axn::Core::NestingTracking._reset_isolation_warning! }

  it "is false with no Fiber scheduler installed, regardless of isolation_level" do
    expect(Fiber.scheduler).to be_nil
    expect(Axn::Core::NestingTracking.isolation_unsafe?).to be(false)
  end

  it "does not read the sticky once-per-process warning flag: it stays scoped to live conditions" do
    # Simulate the flag a DIFFERENT thread's mismatch would have set — the exact state the review
    # finding described. If `isolation_unsafe?` merely read this ivar (the pre-fix implementation), it
    # would answer true for every thread in the process from here on, including this one, which has no
    # scheduler installed and is not actually affected.
    Axn::Core::NestingTracking.instance_variable_set(:@_isolation_mismatch_warned, true)

    expect(Fiber.scheduler).to be_nil
    expect(Axn::Core::NestingTracking.isolation_unsafe?).to be(false)
  ensure
    Axn::Core::NestingTracking.remove_instance_variable(:@_isolation_mismatch_warned)
  end

  it "is true only when a scheduler is installed AND isolation_level is :thread" do
    allow(Fiber).to receive(:scheduler).and_return(Object.new)
    allow(ActiveSupport::IsolatedExecutionState).to receive(:isolation_level).and_return(:thread)

    expect(Axn::Core::NestingTracking.isolation_unsafe?).to be(true)
  end

  it "is false when a scheduler is installed but isolation_level is already :fiber (correctly configured)" do
    allow(Fiber).to receive(:scheduler).and_return(Object.new)
    allow(ActiveSupport::IsolatedExecutionState).to receive(:isolation_level).and_return(:fiber)

    expect(Axn::Core::NestingTracking.isolation_unsafe?).to be(false)
  end
end

# PRO-3283: under the default :thread isolation, manually resumed Fibers with no scheduler share one
# nesting stack. When two call trees interleave on it, `tracking` must remove its OWN entry rather than
# the top (which belongs to the other tree), and warn once per process that nesting was misattributed.
RSpec.describe "Axn::Core::NestingTracking.tracking interleaved without a scheduler" do
  let(:logger) { instance_double(Logger, warn: nil, debug: nil, info: nil, error: nil) }
  let(:tracking) { Axn::Core::NestingTracking }
  let(:warnings) { [] }

  before do
    allow(Axn.config).to receive(:logger).and_return(logger)
    allow(logger).to receive(:warn) { |message| warnings << message }
  end

  after do
    tracking._reset_isolation_warning!
    # Each example asserts on the stack itself; clearing it here keeps one example's leftover entries
    # from failing the next.
    tracking._current_axn_stack.clear
  end

  def interleave_warnings = warnings.grep(/interleaved without a Fiber scheduler/)

  # A pushes, B pushes over it, A exits while B's entry is on top, then B exits. Returns what A read as
  # current_axn after B had pushed.
  def interleave(first, second)
    seen = nil
    fiber_a = Fiber.new do
      tracking.tracking(first) do
        Fiber.yield
        seen = tracking.current_axn
      end
    end
    fiber_b = Fiber.new { tracking.tracking(second) { Fiber.yield } }
    fiber_a.resume
    fiber_b.resume
    fiber_a.resume
    fiber_b.resume
    seen
  end

  it "runs with no scheduler installed (the premise of every example below)" do
    expect(Fiber.scheduler).to be_nil
  end

  it "characterizes the shared stack: A reads B's action while they overlap" do
    expect(interleave(:a, :b)).to eq(:b)
  end

  it "warns exactly once, even across two interleaves" do
    interleave(:a, :b)
    interleave(:c, :d)

    expect(interleave_warnings.size).to eq(1)
    expect(interleave_warnings.first).to include("manually", "log prefixes", "exception attribution", "isolation_level = :fiber")
  end

  it "removes this frame's own entry rather than the top when the frames cross" do
    left_when_a_exits = nil
    fiber_a = Fiber.new do
      tracking.tracking(:a) { Fiber.yield }
      left_when_a_exits = tracking._current_axn_stack.dup
    end
    fiber_b = Fiber.new { tracking.tracking(:b) { Fiber.yield } }
    fiber_a.resume
    fiber_b.resume
    fiber_a.resume
    expect(left_when_a_exits).to eq(%i[b])

    fiber_b.resume
    expect(tracking._current_axn_stack).to be_empty
  end

  it "leaves an empty stack that an ordinary nested call then reads correctly" do
    interleave(:a, :b)
    expect(tracking._current_axn_stack).to be_empty

    seen = []
    tracking.tracking(:outer) do
      tracking.tracking(:inner) { seen << tracking.current_axn }
      seen << tracking.current_axn
    end

    expect(seen).to eq(%i[inner outer])
    expect(tracking._current_axn_stack).to be_empty
  end

  it "still runs the outermost reset bookkeeping exactly when the healed stack becomes empty" do
    allow(Axn::Internal::ExceptionClassification).to receive(:reset!).and_call_original

    interleave(:a, :b)

    # A opens a fresh tree (one reset); B opens on A's entry (none); A's exit leaves B's entry behind
    # (none); B's exit empties the stack (one reset).
    expect(Axn::Internal::ExceptionClassification).to have_received(:reset!).twice
  end

  it "never warns for ordinary nesting, including an exception unwinding through nested frames" do
    tracking.tracking(:outer) { tracking.tracking(:inner) { nil } }
    expect do
      tracking.tracking(:outer) { tracking.tracking(:middle) { tracking.tracking(:inner) { raise "boom" } } }
    end.to raise_error(RuntimeError, "boom")

    expect(warnings).to be_empty
    expect(tracking._current_axn_stack).to be_empty
  end

  it "leaves the announcement to the isolation-mismatch warning when a scheduler is installed" do
    allow(Fiber).to receive(:scheduler).and_return(Object.new)

    interleave(:a, :b)

    expect(interleave_warnings).to be_empty
    expect(tracking._current_axn_stack).to be_empty
  end

  # The frame's own cleanup must not dispatch to the action it tracks: an action class is the author's, and
  # one overriding `equal?` would otherwise decide whether its frame leaves the stack.
  it "cleans up a frame whose action overrides equal?, whether it lies or raises" do
    liar = Class.new { def equal?(_other) = false }.new
    raiser = Class.new { def equal?(_other) = raise("equal? dispatched") }.new

    expect { tracking.tracking(liar) { nil } }.not_to raise_error
    expect { tracking.tracking(raiser) { nil } }.not_to raise_error
    expect(Axn::Internal::Identity.same?(interleave(liar, raiser), raiser)).to be(true) # `be(raiser)` would dispatch equal?
    expect(tracking._current_axn_stack).to be_empty
    expect(interleave_warnings.size).to eq(1)
  end

  it "does not let a raising logger escape the frame's exit" do
    allow(logger).to receive(:warn).and_raise(IOError, "closed stream")

    expect { interleave(:a, :b) }.not_to raise_error
    expect(tracking._current_axn_stack).to be_empty
  end
end
