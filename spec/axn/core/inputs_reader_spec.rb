# frozen_string_literal: true

RSpec.describe "#inputs reader" do
  it "returns declared inbound fields with resolved defaults" do
    action = build_axn do
      expects :a
      expects :b, default: 99
      exposes :captured, optional: true
      def call = expose(captured: inputs)
    end

    expect(action.call(a: 1).captured).to eq(a: 1, b: 99)
  end

  it "applies preprocessing to the returned values" do
    action = build_axn do
      expects :a, preprocess: ->(v) { v * 10 }
      exposes :captured, optional: true
      def call = expose(captured: inputs)
    end

    expect(action.call(a: 2).captured).to eq(a: 20)
  end

  it "excludes undeclared passthrough keys" do
    action = build_axn do
      expects :a
      exposes :captured, optional: true
      def call = expose(captured: inputs)
    end

    expect(action.call(a: 1, z: 99).captured).to eq(a: 1)
  end

  it "omits absent optional fields" do
    action = build_axn do
      expects :a
      expects :b, optional: true
      exposes :captured, optional: true
      def call = expose(captured: inputs)
    end

    expect(action.call(a: 1).captured).to eq(a: 1)
  end

  it "round-trips through a child call via splat" do
    child = build_axn do
      expects :a, :b
      exposes :sum, optional: true
      def call = expose(sum: a + b)
    end
    c = child
    parent = build_axn do
      expects :a, :b
      exposes :sum, optional: true
      define_method(:call) { expose(c.call(**inputs)) }
    end

    expect(parent.call(a: 2, b: 3).sum).to eq(5)
  end

  it "supports subsetting and override with Hash methods" do
    child = build_axn do
      expects :a, :b
      exposes :pair, optional: true
      def call = expose(pair: [a, b])
    end
    c = child
    parent = build_axn do
      expects :a, :b
      exposes :pair, optional: true
      define_method(:call) { expose(c.call(**inputs.except(:b), b: 0)) }
    end

    expect(parent.call(a: 1, b: 9).pair).to eq([1, 0])
  end
end
