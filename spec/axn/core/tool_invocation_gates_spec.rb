# frozen_string_literal: true

require "spec_helper"

RSpec.describe "tool invocation gates: coerce_input_types" do
  let(:action) do
    Class.new do
      include Axn
      expects :age, type: Integer
      expects :count, type: { klass: Integer, coerce: false }
      exposes :age, :count
      def call
        expose(age:, count:)
      end
    end
  end

  it "coerces a wire string when the per-call gate is set (field lacks explicit coerce:)" do
    result = Axn::Internal::CurrentCallOptions.with(coerce_input_types: true) do
      action.call(age: "42", count: 5)
    end
    expect(result).to be_ok
    expect(result.age).to eq(42)
  end

  it "honors a field-level `coerce: false` even under the per-call gate" do
    result = Axn::Internal::CurrentCallOptions.with(coerce_input_types: true) do
      action.call(age: "42", count: "5")
    end
    expect(result).not_to be_ok
    expect(result.exception).to be_a(Axn::InboundValidationError)
  end

  it "does not coerce on a normal call with no gate set" do
    result = action.call(age: "42", count: 5)
    expect(result).not_to be_ok
  end

  it "does not leak the gate into a nested sub-action" do
    inner = Class.new do
      include Axn
      expects :n, type: Integer
      def call; end
    end
    outer = Class.new do
      include Axn
      expects :age, type: Integer
      define_method(:call) { @inner_result = inner.call(n: "7") }
      attr_reader :inner_result
    end
    result = Axn::Internal::CurrentCallOptions.with(coerce_input_types: true) do
      outer.call(age: "1")
    end
    expect(result).to be_ok
    expect(result.__action__.inner_result).not_to be_ok # nested "7" was NOT coerced
  end
end

RSpec.describe "tool invocation gates: user_facing_input_errors" do
  let(:action) do
    Class.new do
      include Axn
      expects :name, type: String
      expects :status, type: String, inclusion: { in: %w[active closed] }
      def call; end
    end
  end

  def invoke(**args)
    Axn::Internal::CurrentCallOptions.with(user_facing_input_errors: true) { action.call(**args) }
  end

  it "settles a type violation as a non-reported user-facing failure" do
    expect(Axn.config).not_to receive(:on_exception)
    result = invoke(name: 123, status: "active")
    expect(result).not_to be_ok
    expect(result.outcome).to eq("failure")
    expect(result.exception).to be_a(Axn::InboundValidationError)
    expect(result.error).to match(/name/i)
  end

  it "surfaces per-field detail for an inclusion (enum) violation" do
    result = invoke(name: "ok", status: "nope")
    expect(result.error).to match(/not included/i)
  end

  it "composes multiple violations into one message" do
    result = invoke(name: 123, status: "nope")
    expect(result.error).to match(/name/i).and match(/status/i)
  end

  it "still REPORTS the same inputs on a normal call (no gate)" do
    expect(Axn.config).to receive(:on_exception).at_least(:once)
    result = action.call(name: 123, status: "active")
    expect(result).not_to be_ok
    expect(result.outcome).to eq("exception")
  end

  it "does NOT reclassify a fail! in the body" do
    failing = Class.new do
      include Axn
      def call = fail!("nope")
    end
    result = Axn::Internal::CurrentCallOptions.with(user_facing_input_errors: true) { failing.call }
    expect(result.outcome).to eq("failure")
    expect(result.exception).not_to be_a(Axn::InboundValidationError)
    expect(result.error).to eq("nope")
  end

  it "does NOT reclassify a genuine StandardError in the body (still reports)" do
    expect(Axn.config).to receive(:on_exception).at_least(:once)
    boom = Class.new do
      include Axn
      def call = raise "kaboom"
    end
    result = Axn::Internal::CurrentCallOptions.with(user_facing_input_errors: true) { boom.call }
    expect(result.outcome).to eq("exception")
  end
end
