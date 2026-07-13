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

    it "digs dotted paths through symbol-keyed nested hashes indifferently" do
      expect(extract("a.b.c", { a: { b: { c: 1 } } })).to eq(1)
    end

    it "returns nil for a missing key" do
      expect(extract(:missing, { name: "x" })).to be_nil
    end
  end

  describe "dotted paths with mixed segment types" do
    # A dotted path is resolved segment-by-segment with per-segment type dispatch, so "items.count"
    # behaves identically to `:count on :items`: the Hash segment is read by key, the Array segment
    # is reached via the reader method (PRO-2886).
    it "method-reads an Array segment nested under a Hash (items.count)" do
      expect(extract("items.count", { items: [10, 20, 30] })).to eq(3)
    end

    it "chains reader methods across nested Arrays" do
      expect(extract("rows.first", { rows: [%w[a b], %w[c d]] })).to eq(%w[a b])
    end

    it "reads a Hash key whose name collides with an Array method (per-segment dispatch)" do
      # The final `count` segment lands on a Hash, so it reads the key (99), not Array#count.
      expect(extract("data.count", { data: { count: 99 } })).to eq(99)
    end

    it "returns nil for a missing intermediate rather than raising" do
      expect(extract("a.b.c", { a: {} })).to be_nil
      expect(extract("a.b.c", { a: { b: nil } })).to be_nil
    end

    it "raises when a non-terminal segment lands on a value that can neither dig nor answer the reader" do
      expect { extract("a.b", { a: 5 }) }.to raise_error(/Unclear how to extract/)
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

  describe "nil source" do
    # A nil source means "absent" — extracting any field yields nil rather than raising, so a
    # subfield hanging off a nil/omitted parent validates against nil (optional passes, required
    # fails cleanly) instead of blowing up mid-extraction (PRO-2857).
    it "returns nil for any field" do
      expect(extract(:anything, nil)).to be_nil
      expect(extract("a.b", nil)).to be_nil
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
