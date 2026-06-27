# frozen_string_literal: true

RSpec.describe Axn::Internal::CarriedPresentation do
  after { described_class.reset! }

  it "stores and retrieves a presentation by exception identity" do
    e = RuntimeError.new("boom")
    expect(described_class.get(e)).to be_nil
    described_class.set(e, "Outer: boom")
    expect(described_class.get(e)).to eq("Outer: boom")
  end

  it "keys by identity, not equality" do
    a = RuntimeError.new("x")
    b = RuntimeError.new("x") # equal message, different object
    described_class.set(a, "A")
    expect(described_class.get(b)).to be_nil
  end

  it "drops everything on reset!" do
    e = RuntimeError.new("boom")
    described_class.set(e, "Outer: boom")
    described_class.reset!
    expect(described_class.get(e)).to be_nil
  end
end
