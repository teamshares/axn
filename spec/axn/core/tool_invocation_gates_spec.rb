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
