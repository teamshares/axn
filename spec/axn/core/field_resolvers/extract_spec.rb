# frozen_string_literal: true

RSpec.describe Axn::Core::FieldResolvers::Extract do
  def extract(field, data)
    Axn::Core::FieldResolvers.resolve(type: :extract, field:, provided_data: data)
  end

  describe "Hash sources" do
    it "reads a key whose name collides with an Enumerable/Hash method" do
      expect(extract(:zip, { zip: "12345" })).to eq("12345")
      expect(extract(:count, { count: 5 })).to eq(5)
      expect(extract(:first, { first: "a" })).to eq("a")
      expect(extract(:min, { min: 1 })).to eq(1)
    end

    it "reads ordinary keys (string or symbol, indifferently)" do
      expect(extract(:name, { name: "x" })).to eq("x")
      expect(extract(:name, { "name" => "x" })).to eq("x")
    end

    it "digs dotted paths" do
      expect(extract("a.b", { a: { b: 1 } })).to eq(1)
    end

    it "returns nil for a missing key" do
      expect(extract(:missing, { name: "x" })).to be_nil
    end
  end

  describe "Array sources" do
    # Arrays respond to #dig but only with integer indices, so a field named after an Array
    # method must use the reader method, not dig.
    it "uses the reader method rather than digging by name" do
      expect(extract(:count, [1, 2, 3])).to eq(3)
      expect(extract(:first, %w[a b])).to eq("a")
      expect(extract(:length, [1, 2])).to eq(2)
    end
  end

  describe "object sources (non-diggable)" do
    it "uses the reader method" do
      obj = Data.define(:zip).new(zip: "v")
      expect(extract(:zip, obj)).to eq("v")
    end

    it "raises when the object does not respond to the field" do
      expect { extract(:nope, Object.new) }.to raise_error(/Unclear how to extract/)
    end
  end
end
