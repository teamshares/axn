# frozen_string_literal: true

# `step … if:`/`unless:` run a step conditionally. Conditions accept a Proc (instance_exec'd on the
# parent) or a Symbol (a parent method), are combinable (AND), and are evaluated immediately before
# the step would run. See internal-docs/specs/2026-06-24-steps-shaping-design.md.
RSpec.describe "Conditional steps" do
  def marker_step(value)
    build_axn do
      exposes :ran
      define_method(:call) { expose :ran, value }
    end
  end

  describe "if:" do
    it "runs the step when a Proc condition is truthy" do
      step_axn = marker_step(:yes)
      action = build_axn do
        expects :go
        exposes :ran
        step :maybe, step_axn, if: -> { go }
      end
      expect(action.call!(go: true).ran).to eq(:yes)
    end

    it "skips the step when a Proc condition is falsey (no exposure, no failure)" do
      step_axn = marker_step(:yes)
      action = build_axn do
        expects :go, allow_blank: true
        exposes :ran, allow_blank: true
        step :maybe, step_axn, if: -> { go }
      end
      result = action.call!(go: false)
      expect(result).to be_ok
      expect(result.ran).to be_nil
    end

    it "accepts a Symbol naming a parent method" do
      step_axn = marker_step(:yes)
      action = build_axn do
        exposes :ran, allow_blank: true
        step :maybe, step_axn, if: :should_run?
        def should_run? = false
      end
      expect(action.call!.ran).to be_nil
    end
  end

  describe "unless:" do
    it "skips when truthy and runs when falsey" do
      step_axn = marker_step(:yes)
      action = build_axn do
        expects :skip, allow_blank: true
        exposes :ran, allow_blank: true
        step :maybe, step_axn, unless: -> { skip }
      end
      expect(action.call!(skip: true).ran).to be_nil
      expect(action.call!(skip: false).ran).to eq(:yes)
    end
  end

  describe "combined if: and unless: (AND)" do
    [[true, false, :yes], [true, true, nil], [false, false, nil], [false, true, nil]].each do |if_val, unless_val, expected|
      it "if=#{if_val} unless=#{unless_val} => #{expected.inspect}" do
        step_axn = marker_step(:yes)
        action = build_axn do
          expects :a, :b, allow_blank: true
          exposes :ran, allow_blank: true
          step :maybe, step_axn, if: -> { a }, unless: -> { b }
        end
        expect(action.call!(a: if_val, b: unless_val).ran).to eq(expected)
      end
    end
  end

  describe "later steps still run after a skip" do
    it "skips one step but runs the next" do
      first = marker_step(:first)
      second = build_axn do
        exposes :second_ran
        def call = expose(:second_ran, true)
      end
      action = build_axn do
        exposes :ran, :second_ran, allow_blank: true
        step :maybe, first, if: -> { false }
        step :always, second
      end
      result = action.call!
      expect(result.ran).to be_nil
      expect(result.second_ran).to be(true)
    end
  end

  describe "evaluation context" do
    it "reads the parent's expects inputs" do
      step_axn = marker_step(:yes)
      action = build_axn do
        expects :tier
        exposes :ran, allow_blank: true
        step :maybe, step_axn, if: -> { tier == "paid" }
      end
      expect(action.call!(tier: "paid").ran).to eq(:yes)
      expect(action.call!(tier: "free").ran).to be_nil
    end

    it "does not expose a bare reader for a prior step's exposure (read inputs, not intermediates)" do
      # Conditions run on the parent instance, which has readers for its expects inputs and its own
      # methods — but NOT for values exposed by earlier steps. Branch on an input (or restructure)
      # rather than a prior step's output.
      flagger = build_axn do
        exposes :flag
        def call = expose(:flag, true)
      end
      gated = marker_step(:yes)
      action = build_axn do
        exposes :flag, :ran, allow_blank: true
        step :flagger, flagger
        step :gated, gated, if: -> { flag }
      end
      expect { action.call! }.to raise_error(NameError, /flag/)
    end
  end

  describe "declaration-time validation" do
    it "raises when a condition is neither a Symbol nor callable" do
      step_axn = marker_step(:yes)
      expect do
        build_axn { step :maybe, step_axn, if: "nope" }
      end.to raise_error(ArgumentError, /Symbol or callable/)
    end
  end
end
