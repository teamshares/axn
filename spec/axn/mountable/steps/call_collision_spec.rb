# frozen_string_literal: true

# The generated #call IS the step orchestrator, so a class can't also define its own. We raise at
# declaration time in either order. See internal-docs/specs/2026-06-24-steps-shaping-design.md.
RSpec.describe "Steps + custom #call collision" do
  let(:child) { build_axn { def call = nil } }

  it "raises when a custom #call is defined after steps" do
    step_child = child
    expect do
      build_axn do
        step "a", step_child
        def call; end
      end
    end.to raise_error(ArgumentError, /steps and a custom #call/i)
  end

  it "raises when steps are declared after a custom #call" do
    step_child = child
    expect do
      build_axn do
        def call; end
        step "a", step_child
      end
    end.to raise_error(ArgumentError, /steps and a custom #call/i)
  end

  it "raises for the bulk steps(...) form too" do
    step_child = child
    expect do
      build_axn do
        def call; end
        steps(step_child)
      end
    end.to raise_error(ArgumentError, /steps and a custom #call/i)
  end

  it "allows a subclass to add steps to a steps-using parent (no custom #call)" do
    s1 = build_axn do
      exposes :a
      def call = expose(:a, 1)
    end
    s2 = build_axn do
      expects :a
      exposes :b
      def call = expose(:b, a + 1)
    end

    stub_const("ParentWithSteps", build_axn do
      exposes :a
      step :s1, s1
    end)
    subclass = Class.new(ParentWithSteps) do
      exposes :b
      step :s2, s2
    end

    result = subclass.call
    expect(result).to be_ok
    expect(result.a).to eq(1)
    expect(result.b).to eq(2)
  end

  it "does not trip the guard when steps use inherit: :lifecycle (child action subclasses the host)" do
    first = build_axn do
      exposes :a
      def call = expose(:a, 1)
    end
    action = nil
    expect do
      action = build_axn do
        exposes :a, :b
        step :first, first, inherit: :lifecycle
        step :second, expects: [:a], exposes: [:b], inherit: :lifecycle do
          expose :b, a + 1
        end
      end
    end.not_to raise_error

    result = action.call
    expect(result).to be_ok
    expect(result.b).to eq(2)
  end

  it "preserves a pre-existing self.method_added hook when steps are declared" do
    step_child = child
    observed = []
    sink = observed
    klass = Class.new do
      include Axn
      define_singleton_method(:method_added) { |name| sink << name }
      step "a", step_child
      def helper_after_steps; end
    end
    expect(klass).to be_truthy
    expect(observed).to include(:helper_after_steps)
  end
end
