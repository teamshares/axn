# frozen_string_literal: true

# Locks the failure-vs-exception contract for step composition (see
# internal-docs/specs/2026-06-24-steps-shaping-design.md). A step that calls fail! settles the
# parent as a FAILURE (on_failure); a step that raises an unclassified exception settles the parent
# as an EXCEPTION (on_exception, never on_failure), with exactly one global report at the step.
RSpec.describe "Step failure vs exception semantics" do
  let(:original_handler) { Axn.config.instance_variable_get(:@on_exception) }
  let(:reports) { [] }

  before do
    captured = reports
    Axn.config.instance_variable_set(:@on_exception, ->(e, **) { captured << e })
  end

  after { Axn.config.instance_variable_set(:@on_exception, original_handler) }

  describe "step calls fail! (deliberate failure)" do
    it "settles the parent as a failure, fires on_failure (not on_exception), and does not report" do
      failing = build_axn { def call = fail!("nope") }
      events = []
      parent = build_axn do
        step "validate", failing
        on_failure { events << :failure }
        on_exception { events << :exception }
        on_error { events << :error }
      end

      result = parent.call
      expect(result.outcome).to eq("failure")
      expect(events).to contain_exactly(:failure, :error)
      expect(reports).to be_empty
      expect(result.error).to eq("validate: nope")
    end
  end

  describe "step raises an unclassified exception (a bug)" do
    it "settles the parent as an exception, fires on_exception (not on_failure), reports exactly once" do
      exploding = build_axn { def call = raise TypeError, "boom" }
      events = []
      parent = build_axn do
        error "Onboarding failed"
        step "setup", exploding
        on_failure { events << :failure }
        on_exception { events << :exception }
        on_error { events << :error }
      end

      result = parent.call
      expect(result.outcome).to eq("exception")
      expect(events).to contain_exactly(:exception, :error)
      expect(reports.size).to eq(1)
      expect(reports.first).to be_a(TypeError)
      # Exception path surfaces the declared base error, not the step-prefixed internal message.
      expect(result.error).to eq("Onboarding failed")
    end
  end

  describe "step raises an exception it classifies as a failure via fails_on" do
    it "travels the failure path: parent failure, prefixed, no report" do
      expected_failure = build_axn do
        fails_on ArgumentError
        def call = raise ArgumentError, "bad arg"
      end
      parent = build_axn { step "check", expected_failure }

      result = parent.call
      expect(result.outcome).to eq("failure")
      # fails_on reclassifies to the failure bucket, but (like any exception) the raw message stays
      # hidden behind the default — what matters here is the failure path: prefixed, no report.
      expect(result.error).to eq("check: Something went wrong")
      expect(reports).to be_empty
    end
  end

  describe "step calls done! (early completion)" do
    it "settles ok, merges exposures, and continues to the next step" do
      early = build_axn do
        exposes :a
        def call
          expose :a, 1
          done!
        end
      end
      action = build_axn do
        exposes :a, :b
        step "first", early
        step :second, expects: [:a], exposes: [:b] do
          expose :b, a + 1
        end
      end

      result = action.call
      expect(result).to be_ok
      expect(result.a).to eq(1)
      expect(result.b).to eq(2)
    end
  end
end
