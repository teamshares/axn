# frozen_string_literal: true

RSpec.describe "Axn instantiation is private" do
  it "blocks direct instantiation via .new" do
    action = build_axn do
      exposes :foo, type: Integer, allow_blank: true
      def foo = 1
    end

    expect { action.new }.to raise_error(NoMethodError, /private method [`']new'/)
  end

  it "still allows the sanctioned .call entry point" do
    action = build_axn do
      exposes :foo, type: Integer, allow_blank: true
      def foo = 42
    end

    result = action.call
    expect(result).to be_ok
    expect(result.foo).to eq(42)
  end

  it "keeps .new private on subclasses while .call still works" do
    base = build_axn do
      exposes :foo, type: Integer, allow_blank: true
      def foo = 1
    end
    sub = Class.new(base) do
      def foo = 2
    end

    expect { sub.new }.to raise_error(NoMethodError, /private method [`']new'/)
    expect(sub.call.foo).to eq(2)
  end
end
