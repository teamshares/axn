# frozen_string_literal: true

# PRO-3359: an `axn.call` span records only its own identity (`axn.resource`), so a dashboard built on
# a nested axn (e.g. `Axn::RubyLLM::Ask`) can never group by what TRIGGERED it — the caller's identity
# lives on the parent span, and Datadog span analytics cannot group a child by an ancestor's attribute.
# This suite proves `axn.caller_resource` (the immediately-enclosing axn) and `axn.root_resource` (the
# outermost axn) are stamped only when they can be trusted, sourced from `_current_axn_stack` at
# `Executor#finalize_span` time via `Internal::Tracing.caller_and_root_names`.
RSpec.describe "axn.caller_resource / axn.root_resource span attribution" do
  def fake_span_class
    Class.new do
      attr_reader :attributes

      def initialize = @attributes = {}
      def set_attribute(key, value) = @attributes[key] = value
    end
  end

  # A tracer that yields a fresh, distinct recording span on every call and remembers each one in
  # call order (pre-order: a parent's span is pushed before any child's, since children run from
  # inside the parent's own body) — so after the outermost `.call` returns, every level's finalized
  # attributes can be inspected by index.
  let(:spans) { [] }
  let(:recording_tracer) do
    collected = spans
    span_class = fake_span_class
    Class.new do
      define_method(:initialize) { |initial_collected| @collected = initial_collected }
      define_method(:in_span) do |*, **, &block|
        span = span_class.new
        @collected << span
        block.call(span)
      end
    end.new(collected)
  end

  after { Axn.config.reset!(:tracer) }

  it "stamps caller and root on a depth-2 child; the parent gets neither" do
    Axn.config.tracer = recording_tracer
    child = build_axn { def call; end }
    stub_const("Depth2Child", child)
    stub_const("Depth2Parent", build_axn { define_method(:call) { Depth2Child.call } })

    Depth2Parent.call

    parent_span, child_span = spans
    expect(parent_span.attributes).not_to include("axn.caller_resource", "axn.root_resource")
    expect(child_span.attributes["axn.caller_resource"]).to eq("Depth2Parent")
    expect(child_span.attributes["axn.root_resource"]).to eq("Depth2Parent")
  end

  it "attributes each level relative to its own immediate caller and the shared root" do
    Axn.config.tracer = recording_tracer
    stub_const("Inner3", build_axn { def call; end })
    stub_const("Middle3", build_axn { define_method(:call) { Inner3.call } })
    stub_const("Outer3", build_axn { define_method(:call) { Middle3.call } })

    Outer3.call

    outer_span, middle_span, inner_span = spans
    expect(outer_span.attributes).not_to include("axn.caller_resource", "axn.root_resource")
    expect(middle_span.attributes["axn.caller_resource"]).to eq("Outer3")
    expect(middle_span.attributes["axn.root_resource"]).to eq("Outer3")
    expect(inner_span.attributes["axn.caller_resource"]).to eq("Middle3")
    expect(inner_span.attributes["axn.root_resource"]).to eq("Outer3")
  end

  it "stamps neither attribute on a plain top-level call" do
    Axn.config.tracer = recording_tracer
    build_axn { def call; end }.call

    expect(spans.first.attributes).not_to include("axn.caller_resource", "axn.root_resource")
  end

  it "stamps nothing when NestingTracking.isolation_unsafe? is true" do
    Axn.config.tracer = recording_tracer
    allow(Axn::Core::NestingTracking).to receive(:isolation_unsafe?).and_return(true)
    stub_const("UnsafeInner", build_axn { def call; end })
    stub_const("UnsafeOuter", build_axn { define_method(:call) { UnsafeInner.call } })

    UnsafeOuter.call

    _, inner_span = spans
    expect(inner_span.attributes).not_to include("axn.caller_resource", "axn.root_resource")
  end

  describe "the self-attribution hole (a root must never name itself as its own caller)" do
    # `NestingTracking.tracking`'s `ensure` pops whatever is on TOP of the shared `_current_axn_stack`,
    # not necessarily its own frame — under a same-thread Fiber interleave with no scheduler installed,
    # that stack can hold a DIFFERENT fiber's frame on top when this action's own `finalize_span` runs.
    # Reproduced exactly as spec/axn/internal/tracing/current_span_spec.rb:415 does for `current_span`.
    it "does not attribute a root action to itself when a concurrent fiber's frame is still on top" do
      expect(Fiber.scheduler).to be_nil

      span_class = fake_span_class
      span_a = span_class.new
      span_b = span_class.new

      klass_a = build_axn { define_method(:call) { Fiber.yield } }
      klass_b = build_axn { define_method(:call) { Fiber.yield } }

      Axn.config.tracer = Class.new { define_method(:in_span) { |*, **, &block| block.call(span_a) } }.new
      fiber_a = Fiber.new { klass_a.call }

      Axn.config.tracer = Class.new { define_method(:in_span) { |*, **, &block| block.call(span_b) } }.new
      fiber_b = Fiber.new { klass_b.call }

      fiber_a.resume # push A, suspend before A's own pop
      fiber_b.resume # push B on top, suspend before B's own pop — stack is [A, B]
      fiber_a.resume # A resumes and FINISHES: finalize_span(span_a) runs while the stack still reads [A, B]

      expect(span_a.attributes).not_to include("axn.caller_resource", "axn.root_resource")
      expect(span_b.attributes).not_to include("axn.caller_resource", "axn.root_resource")

      fiber_b.resume # drain B so the shared stack empties (spec_helper's leak detector requires this)
    end

    it "does not attribute a root action to an unrelated fiber parked lower on the shared stack" do
      span_class = fake_span_class
      span_a = span_class.new
      span_b = span_class.new

      klass_b = build_axn { define_method(:call) { Fiber.yield } }
      klass_a = build_axn { def call; end }

      Axn.config.tracer = Class.new { define_method(:in_span) { |*, **, &block| block.call(span_b) } }.new
      fiber_b = Fiber.new { klass_b.call }
      fiber_b.resume # push B, suspend — stack is [B]

      Axn.config.tracer = Class.new { define_method(:in_span) { |*, **, &block| block.call(span_a) } }.new
      klass_a.call # runs on the current fiber: pushes A on top (stack = [B, A]) and finishes immediately

      expect(span_a.attributes).not_to include("axn.caller_resource", "axn.root_resource")

      fiber_b.resume # drain B
    end
  end

  it "names an anonymous or factory-built caller 'Anonymous Axn'" do
    Axn.config.tracer = recording_tracer
    child = build_axn { def call; end }
    parent = build_axn { define_method(:call) { child.call } }

    parent.call

    _, child_span = spans
    expect(child_span.attributes["axn.caller_resource"]).to eq("Anonymous Axn")
    expect(child_span.attributes["axn.root_resource"]).to eq("Anonymous Axn")
  end

  it "attributes a nested axn invoked through a tool call to the tool's own axn, not the Invoker" do
    Axn.config.tracer = recording_tracer
    stub_const("ToolChild", build_axn { def call; end })
    stub_const("ToolCaller", build_axn { define_method(:call) { Axn::Tools::Invoker.new.call(ToolChild, {}) } })

    ToolCaller.call

    _, child_span = spans
    expect(child_span.attributes["axn.caller_resource"]).to eq("ToolCaller")
    expect(child_span.attributes["axn.root_resource"]).to eq("ToolCaller")
  end

  it "still lands axn.tag.* when the span raises setting caller/root, and the call still succeeds" do
    raising_span = Class.new do
      attr_reader :attributes

      def initialize = @attributes = {}

      def set_attribute(key, value)
        raise "boom" if key.start_with?("axn.caller_resource", "axn.root_resource")

        @attributes[key] = value
      end
    end.new
    Axn.config.tracer = Class.new { define_method(:in_span) { |*, **, &block| block.call(raising_span) } }.new

    stub_const("RaisingChild", build_axn do
      tag :marker, -> { "present" }
      def call; end
    end)
    stub_const("RaisingParent", build_axn { define_method(:call) { RaisingChild.call } })

    result = RaisingParent.call

    expect(result).to be_ok
    expect(raising_span.attributes["axn.tag.marker"]).to eq("present")
  end

  it "keeps the caller attribute even when the root ran untraced (the two slots are independent)" do
    # A ONE-SHOT flag, not a depth counter: the untraced fallback runs the declined call's body
    # OUTSIDE `in_span` (after it has already returned), so a depth counter that decrements via
    # `ensure` sees every nested call start back at depth 1 too. Declining only the very first
    # invocation, ever, is what makes exactly the root untraced and everything nested under it traced.
    captured = []
    span_class = fake_span_class
    tracer = Class.new do
      define_method(:initialize) do |initial_collected, initial_span_class|
        @first = true
        @collected = initial_collected
        @span_class = initial_span_class
      end

      def in_span(*, **, &block)
        if @first
          @first = false
          return :never_yielded
        end

        span = @span_class.new
        @collected << span
        block.call(span)
      end
    end.new(captured, span_class)
    Axn.config.tracer = tracer

    stub_const("TracedInner", build_axn { def call; end })
    stub_const("TracedMiddle", build_axn { define_method(:call) { TracedInner.call } })
    stub_const("UntracedRoot", build_axn { define_method(:call) { TracedMiddle.call } })

    UntracedRoot.call

    middle_span, inner_span = captured
    expect(middle_span.attributes).not_to include("axn.caller_resource", "axn.root_resource")
    expect(inner_span.attributes["axn.caller_resource"]).to eq("TracedMiddle")
    expect(inner_span.attributes["axn.root_resource"]).to be_nil
  end

  it "still attributes through an ancestor whose own tracer yielded a nil span (uses the tag's identity, not its span)" do
    captured = []
    span_class = fake_span_class
    tracer = Class.new do
      define_method(:initialize) do |initial_collected, initial_span_class|
        @depth = 0
        @collected = initial_collected
        @span_class = initial_span_class
      end

      def in_span(*, **, &block)
        @depth += 1
        if @depth == 1
          block.call(nil) # the parent's own span is nil
        else
          span = @span_class.new
          @collected << span
          block.call(span)
        end
      ensure
        @depth -= 1
      end
    end.new(captured, span_class)
    Axn.config.tracer = tracer

    stub_const("NilSpanChild", build_axn { def call; end })
    stub_const("NilSpanParent", build_axn { define_method(:call) { NilSpanChild.call } })

    NilSpanParent.call

    child_span = captured.first
    expect(child_span.attributes["axn.caller_resource"]).to eq("NilSpanParent")
  end

  it "degrades to no attribute when a caller's resolved_axn_name raises, without losing axn.tag.*" do
    span = fake_span_class.new
    Axn.config.tracer = Class.new { define_method(:in_span) { |*, **, &block| block.call(span) } }.new

    # `with_tracing` itself calls `resolved_axn_name` unconditionally on ITS OWN class, uncaught, to
    # name its own span (executor.rb:400) — a plain, unconditional override would blow up the parent's
    # own execution before my new code ever ran. Flip the raise on only once the parent's own name has
    # already resolved (inside its own `#call`, i.e. strictly after `with_tracing`'s first line), so
    # only the CHILD's ancestor lookup — the thing this example is actually about — sees it fail.
    should_raise = false
    stub_const("RaisingNameChild", build_axn do
      tag :marker, -> { "ok" }
      def call; end
    end)
    stub_const("RaisingNameParent", build_axn do
      define_method(:call) do
        should_raise = true
        RaisingNameChild.call
      end
    end)
    RaisingNameParent.define_singleton_method(:resolved_axn_name) do
      raise "boom" if should_raise

      "RaisingNameParent"
    end

    result = RaisingNameParent.call

    expect(result).to be_ok
    expect(span.attributes).not_to include("axn.caller_resource", "axn.root_resource")
    expect(span.attributes["axn.tag.marker"]).to eq("ok")
  end
end
