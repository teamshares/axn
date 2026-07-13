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

    it "leaves a blank string uncoerced (so Symbol can't smuggle a blank past presence)" do
      expect(described_class.coerce_value("", Symbol)).to eq("")
      expect(described_class.coerce_value("   ", Symbol)).to eq("   ")
      expect(described_class.coerce_value("", Date)).to eq("")
    end

    it "accepts ISO and Rails date/time wire formats" do
      expect(described_class.coerce_value("2026-07-08", Date)).to eq(Date.new(2026, 7, 8))
      # datetime-local (no seconds, no offset) — parsed in the local zone
      t = described_class.coerce_value("2026-07-08T14:30", Time)
      expect(t).to be_a(Time).and have_attributes(hour: 14, min: 30)
      # Rails Time#to_s (space separator + spaced offset)
      expect(described_class.coerce_value("2026-07-08 14:30:00 +0000", Time)).to eq(Time.new(2026, 7, 8, 14, 30, 0, "+00:00"))
    end

    it "leaves ambiguous / partial (non-ISO-shaped) date strings uncoerced instead of guessing against today" do
      expect(described_class.coerce_value("12", Date)).to eq("12")
      expect(described_class.coerce_value("01/02/2026", Date)).to eq("01/02/2026")
      expect(described_class.coerce_value("14:30", Time)).to eq("14:30")
      expect(described_class.coerce_value("July 8", Date)).to eq("July 8")
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

    describe ":boolean" do
      it "coerces the canonical truthy/falsy strings (case-insensitively)" do
        %w[1 true t yes y on TRUE On YES].each { |s| expect(described_class.coerce_value(s, :boolean)).to be(true) }
        %w[0 false f no n off FALSE Off NO].each { |s| expect(described_class.coerce_value(s, :boolean)).to be(false) }
      end

      it "coerces the integers 1 and 0" do
        expect(described_class.coerce_value(1, :boolean)).to be(true)
        expect(described_class.coerce_value(0, :boolean)).to be(false)
      end

      it "leaves an already-boolean value untouched" do
        expect(described_class.coerce_value(true, :boolean)).to be(true)
        expect(described_class.coerce_value(false, :boolean)).to be(false)
      end

      it "leaves an unrecognized string or integer uncoerced (never silently true)" do
        expect(described_class.coerce_value("maybe", :boolean)).to eq("maybe")
        expect(described_class.coerce_value(2, :boolean)).to eq(2)
        expect(described_class.coerce_value("2", :boolean)).to eq("2")
      end

      it "leaves a blank string uncoerced so presence still applies" do
        expect(described_class.coerce_value("", :boolean)).to eq("")
        expect(described_class.coerce_value("   ", :boolean)).to eq("   ")
      end

      it "does not route a non-String value to a non-boolean coercer in a union" do
        # Integer 1 must reach only :boolean; the Symbol coercer's to_sym would NoMethodError on it.
        expect(described_class.coerce_value(1, [Symbol, :boolean])).to be(true)
        # A String still follows declaration order: Symbol wins before :boolean.
        expect(described_class.coerce_value("true", [Symbol, :boolean])).to eq(:true) # rubocop:disable Lint/BooleanSymbol
      end
    end
  end

  describe ".coercible_klasses" do
    it "extracts the supported subset from a Class, array, or type hash" do
      expect(described_class.coercible_klasses(Date)).to eq([Date])
      expect(described_class.coercible_klasses([Date, String])).to eq([Date])
      expect(described_class.coercible_klasses({ klass: [Symbol, Integer] })).to eq([Symbol, Integer])
      expect(described_class.coercible_klasses({ klass: String })).to eq([])
      expect(described_class.coercible_klasses(:boolean)).to eq([:boolean])
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
