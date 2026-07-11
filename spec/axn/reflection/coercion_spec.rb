# frozen_string_literal: true

require "spec_helper"

RSpec.describe Axn::Reflection::Coercion do
  describe ".coerce_value" do
    it "parses a string into each supported Ruby type" do
      expect(described_class.coerce_value("2026-07-08", Date)).to eq(Date.new(2026, 7, 8))
      expect(described_class.coerce_value("2026-07-08T12:00:00+00:00", DateTime)).to eq(DateTime.new(2026, 7, 8, 12, 0, 0, "+00:00"))
      expect(described_class.coerce_value("2026-07-08T12:00:00Z", Time)).to eq(Time.utc(2026, 7, 8, 12, 0, 0))
      expect(described_class.coerce_value("active", Symbol)).to eq(:active)
      expect(described_class.coerce_value("123", Integer)).to eq(123)
      expect(described_class.coerce_value("1.5", Float)).to eq(1.5)
    end

    it "parses a zero-padded integer as base 10 (not octal)" do
      expect(described_class.coerce_value("08", Integer)).to eq(8)
    end

    it "returns the original value untouched when it is not a String" do
      d = Date.new(2026, 7, 8)
      expect(described_class.coerce_value(d, Date)).to equal(d)
      expect(described_class.coerce_value(123, Integer)).to eq(123)
    end

    it "returns the original string when the parse fails (coerce-or-leave)" do
      expect(described_class.coerce_value("nope", Date)).to eq("nope")
      expect(described_class.coerce_value("12.5", Integer)).to eq("12.5")
    end

    it "tries union members in order and falls through to the original when none parse" do
      expect(described_class.coerce_value("2026-07-08", [Date, Symbol])).to eq(Date.new(2026, 7, 8))
      expect(described_class.coerce_value("hello", [Date, Symbol])).to eq(:hello)
      expect(described_class.coerce_value("hello", [Date, Integer])).to eq("hello")
    end

    it "ignores a non-coercible target (e.g. String) as a coercion target" do
      expect(described_class.coerce_value("2026-07-08", [Date, String])).to eq(Date.new(2026, 7, 8))
      expect(described_class.coerce_value("hello", [String])).to eq("hello")
    end
  end

  describe ".coercible_klasses" do
    it "extracts the supported subset from a Class, array, or type hash" do
      expect(described_class.coercible_klasses(Date)).to eq([Date])
      expect(described_class.coercible_klasses([Date, String])).to eq([Date])
      expect(described_class.coercible_klasses({ klass: [Symbol, Integer] })).to eq([Symbol, Integer])
      expect(described_class.coercible_klasses({ klass: String })).to eq([])
      expect(described_class.coercible_klasses(:boolean)).to eq([])
    end
  end

  describe "round-trip with the encoder" do
    it "is the inverse of Values.serialize_value for string-encoded types" do
      [Date.new(2026, 7, 8), :active, Time.utc(2026, 7, 8, 12, 0, 0)].each do |value|
        encoded = Axn::Reflection::Values.serialize_value(value)
        expect(encoded).to be_a(String)
        expect(described_class.coerce_value(encoded, value.class)).to eq(value)
      end
    end
  end
end
