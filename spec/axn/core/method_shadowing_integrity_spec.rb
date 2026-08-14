# frozen_string_literal: true

RSpec.describe "shadowing an axn instance method" do
  it "does not corrupt the framework when `result` is shadowed by a def" do
    klass = build_axn do
      exposes :out
      def result = "shadowed"
      def call = expose(out: 1)
    end

    result = klass.call

    expect(result).to be_ok
    expect(result.out).to eq(1)
  end

  it "does not corrupt the framework when `result` is shadowed by a declaration" do
    klass = build_axn do
      expects :result
      exposes :out
      def call = expose(out: result * 2)
    end

    outcome = klass.call(result: 21)

    expect(outcome).to be_ok
    expect(outcome.out).to eq(42)
  end
end
