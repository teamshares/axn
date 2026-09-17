# frozen_string_literal: true

# PRO-3278: the public facade over `Internal::Tracing.current_span` — `Axn::Extensions::Tracing` is the
# documented extension-author surface a downstream gem (axn-ruby_llm) reaches for instead of
# `OpenTelemetry::Trace.current_span`. `current_span` is covered exhaustively in
# spec/axn/internal/tracing/current_span_spec.rb; this file covers the facade's delegation and
# `annotate_span`'s own behavior.
RSpec.describe "Axn::Extensions::Tracing" do
  let(:fake_span) do
    Class.new do
      attr_reader :attributes

      def initialize = @attributes = {}
      def set_attribute(key, value) = @attributes[key] = value
    end.new
  end

  let(:fake_tracer) do
    span = fake_span
    Class.new { define_method(:in_span) { |*, **, &block| block.call(span) } }.new
  end

  after { Axn.config.reset!(:tracer) }

  describe ".current_span" do
    it "delegates to Internal::Tracing.current_span" do
      Axn.config.tracer = fake_tracer
      seen = nil
      build_axn { define_method(:call) { seen = Axn::Extensions::Tracing.current_span } }.call

      expect(seen).to equal(fake_span)
    end

    it "is nil outside any action" do
      expect(Axn::Extensions::Tracing.current_span).to be_nil
    end
  end

  # PRO-3359: the public facade over `Internal::Tracing.caller_and_root_names`, exhaustively covered
  # in spec/axn/internal/tracing/nesting_attribution_spec.rb — this only proves the delegation.
  describe ".caller_axn_name / .root_axn_name" do
    it "delegates to Internal::Tracing.caller_and_root_names for the currently-running action" do
      Axn.config.tracer = fake_tracer
      seen = {}
      child = build_axn do
        define_method(:call) do
          seen[:caller] = Axn::Extensions::Tracing.caller_axn_name
          seen[:root] = Axn::Extensions::Tracing.root_axn_name
        end
      end
      stub_const("FacadeParent", build_axn { define_method(:call) { child.call } })

      FacadeParent.call

      expect(seen[:caller]).to eq("FacadeParent")
      expect(seen[:root]).to eq("FacadeParent")
    end

    it "is nil for a top-level call" do
      Axn.config.tracer = fake_tracer
      seen = {}
      build_axn do
        define_method(:call) do
          seen[:caller] = Axn::Extensions::Tracing.caller_axn_name
          seen[:root] = Axn::Extensions::Tracing.root_axn_name
        end
      end.call

      expect(seen[:caller]).to be_nil
      expect(seen[:root]).to be_nil
    end

    it "is nil outside any action" do
      expect(Axn::Extensions::Tracing.caller_axn_name).to be_nil
      expect(Axn::Extensions::Tracing.root_axn_name).to be_nil
    end

    # The executor's own call site passes `@action` — a reference it holds independently of the
    # stack, so `Identity.same?(stack[-1], action)` genuinely proves that action is on top right now.
    # This facade instead DERIVES `action` from the stack itself (`NestingTracking.current_axn`,
    # i.e. `stack.last`), which makes that same check trivially true regardless of which fiber is
    # actually asking — it only proves the two reads agree, not that either one is genuinely this
    # fiber's own frame. A foreign fiber's frame sitting on top of the calling fiber's own (still
    # live, still on the stack) frame passes it exactly as easily as a genuine self-reference would.
    it "does not misattribute when a foreign fiber's frame sits on top of the calling fiber's own action" do
      expect(Fiber.scheduler).to be_nil

      seen = { caller: :unset, root: :unset }
      klass_r = build_axn do
        define_method(:call) do
          Fiber.yield # let F get pushed on top and suspend before resuming here
          seen[:caller] = Axn::Extensions::Tracing.caller_axn_name
          seen[:root] = Axn::Extensions::Tracing.root_axn_name
        end
      end
      klass_f = build_axn { define_method(:call) { Fiber.yield } }
      stub_const("FacadeSelfR", klass_r)
      stub_const("FacadeForeignF", klass_f)

      span_class = fake_span.class
      Axn.config.tracer = Class.new { define_method(:in_span) { |*, **, &block| block.call(span_class.new) } }.new

      fiber_r = Fiber.new { FacadeSelfR.call }
      fiber_r.resume # push R, suspend inside R's own body before F exists

      fiber_f = Fiber.new { FacadeForeignF.call }
      fiber_f.resume # push F on top of R, suspend before F's own pop — stack is [R, F]

      fiber_r.resume # R resumes (Fiber.current is fiber_r again); stack still reads [R, F]

      expect(seen[:caller]).to be_nil
      expect(seen[:root]).to be_nil

      fiber_f.resume # drain F (R's own mispopping ensure already removed F's frame, not its own)
    end
  end

  describe ".annotate_span" do
    it "sets each attribute on the same span finalize_span later writes axn.outcome onto" do
      Axn.config.tracer = fake_tracer
      build_axn { define_method(:call) { Axn::Extensions::Tracing.annotate_span("gen_ai.request.model" => "gpt-4o-mini") } }.call

      expect(fake_span.attributes).to include(
        "gen_ai.request.model" => "gpt-4o-mini",
        "axn.outcome" => "success",
      )
    end

    it "no-ops without raising when there is no tracer" do
      Axn.config.tracer = nil
      result = nil
      build_axn { define_method(:call) { result = Axn::Extensions::Tracing.annotate_span("x" => 1) } }.call

      expect(result).to be_nil
    end

    it "no-ops without raising outside any action" do
      expect { Axn::Extensions::Tracing.annotate_span("x" => 1) }.not_to raise_error
      expect(Axn::Extensions::Tracing.annotate_span("x" => 1)).to be_nil
    end

    it "no-ops without raising when the tracer yielded nil as the span" do
      Axn.config.tracer = Class.new { def in_span(*, **) = yield(nil) }.new
      result = :unset
      build_axn { define_method(:call) { result = Axn::Extensions::Tracing.annotate_span("x" => 1) } }.call

      expect(result).to be_nil
    end

    it "skips nil values rather than passing them to the span" do
      Axn.config.tracer = fake_tracer
      build_axn do
        define_method(:call) { Axn::Extensions::Tracing.annotate_span("present" => 1, "absent" => nil) }
      end.call

      expect(fake_span.attributes).to have_key("present")
      expect(fake_span.attributes).not_to have_key("absent")
    end

    it "converts Symbol keys to String, since OTel attribute keys are Strings" do
      Axn.config.tracer = fake_tracer
      build_axn { define_method(:call) { Axn::Extensions::Tracing.annotate_span(gen_ai_model: "gpt-4o-mini") } }.call

      expect(fake_span.attributes).to include("gen_ai_model" => "gpt-4o-mini")
    end

    it "swallows and warn-logs when the span's own set_attribute raises, and the action still succeeds" do
      raising_span = Object.new
      raising_span.define_singleton_method(:set_attribute) { |*, **| raise "span closed" }
      Axn.config.tracer = Class.new do
        define_method(:in_span) { |*, **, &block| block.call(raising_span) }
      end.new

      result = build_axn { define_method(:call) { Axn::Extensions::Tracing.annotate_span("x" => 1) } }.call

      expect(result).to be_ok
    end

    it "re-raises under best_effort_raises_in_dev, matching every other tracing side channel" do
      raising_span = Object.new
      raising_span.define_singleton_method(:set_attribute) { |*, **| raise "span closed" }
      Axn.config.tracer = Class.new do
        define_method(:in_span) { |*, **, &block| block.call(raising_span) }
      end.new
      allow(Axn.config).to receive(:env).and_return(ActiveSupport::StringInquirer.new("development"))
      Axn.config.best_effort_raises_in_dev = true

      klass = build_axn { define_method(:call) { Axn::Extensions::Tracing.annotate_span("x" => 1) } }

      expect { klass.call }.to raise_error("span closed")
    ensure
      Axn.config.reset!(:best_effort_raises_in_dev)
    end

    it "still sets attributes on a BasicObject-based span, which cannot answer respond_to?" do
      span = Class.new(BasicObject) do
        define_method(:set_attribute) { |key, value| (@attrs ||= {})[key] = value }
        define_method(:attrs) { @attrs || {} }
      end.new
      Axn.config.tracer = Class.new { define_method(:in_span) { |*, **, &block| block.call(span) } }.new

      build_axn { define_method(:call) { Axn::Extensions::Tracing.annotate_span("x" => 1) } }.call

      expect(span.attrs).to include("x" => 1)
    end
  end
end
