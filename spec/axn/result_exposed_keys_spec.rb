# frozen_string_literal: true

RSpec.describe "Axn::Result#__exposed_keys__" do
  it "reports only the fields actually set, not the ones merely declared" do
    action = build_axn do
      exposes :a, :b, optional: true
      def call = expose(a: "SET")
    end

    result = action.call
    expect(result.declared_fields).to contain_exactly(:a, :b)
    expect(result.__exposed_keys__).to eq([:a])
  end

  it "includes a field explicitly exposed as nil" do
    action = build_axn do
      exposes :a, :b, optional: true
      def call = expose(a: "SET", b: nil)
    end

    expect(action.call.__exposed_keys__).to contain_exactly(:a, :b)
  end

  it "reports what was set before a fail!" do
    action = build_axn do
      exposes :a, :b, optional: true
      def call
        expose(a: "SET")
        fail! "boom"
      end
    end

    result = action.call
    expect(result).not_to be_ok
    expect(result.__exposed_keys__).to eq([:a])
  end

  it "reports what was set before an unhandled exception" do
    action = build_axn do
      exposes :a, optional: true
      def call
        expose(a: "SET")
        raise "kaboom"
      end
    end

    result = action.call
    expect(result.outcome).to be_exception
    expect(result.__exposed_keys__).to eq([:a])
  end

  it "is empty when the action exposed nothing" do
    action = build_axn do
      exposes :a, optional: true
      def call = nil
    end

    expect(action.call.__exposed_keys__).to eq([])
  end

  it "includes a field an outbound default: supplied, which the result genuinely carries" do
    action = build_axn do
      exposes :a, optional: true
      exposes :b, default: "DEFAULT"
      def call = expose(a: "SET")
    end

    result = action.call
    expect(result.b).to eq("DEFAULT")
    expect(result.__exposed_keys__).to contain_exactly(:a, :b)
  end

  it "includes a field an expects+exposes auto-copy supplied, which the result genuinely carries" do
    action = build_axn do
      expects :u
      exposes :u
      def call = nil
    end

    result = action.call(u: "FROM-INPUT")
    expect(result.u).to eq("FROM-INPUT")
    expect(result.__exposed_keys__).to eq([:u])
  end
end
