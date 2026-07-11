# frozen_string_literal: true

RSpec.describe Axn::FieldDeclarations do
  describe ".hydrate" do
    it "passes an existing Hash through untouched" do
      given = { arg: { type: Numeric }, other: {} }
      expect(described_class.hydrate(given)).to equal(given)
    end

    it "hydrates a single bare field name to empty opts" do
      expect(described_class.hydrate(:arg)).to eq(arg: {})
    end

    it "hydrates an array of bare field names to empty opts" do
      expect(described_class.hydrate(%i[foo bar])).to eq(foo: {}, bar: {})
    end

    it "merges hashes embedded in the array" do
      declarations = [:bar, { arg: { type: Numeric } }]
      expect(described_class.hydrate(declarations)).to eq(bar: {}, arg: { type: Numeric })
    end

    it "treats nil as no declarations" do
      expect(described_class.hydrate(nil)).to eq({})
    end
  end
end
