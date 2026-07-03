# frozen_string_literal: true

require "spec_helper"
require "bigdecimal"

RSpec.describe Axn::Reflection::Values do
  describe ".serialize_value" do
    it "passes through JSON scalars" do
      expect(described_class.serialize_value(1)).to eq(1)
      expect(described_class.serialize_value("x")).to eq("x")
      expect(described_class.serialize_value(true)).to eq(true)
      expect(described_class.serialize_value(nil)).to be_nil
    end

    it "keeps Integer/Float passing through unchanged (not floatified by the Numeric case)" do
      expect(described_class.serialize_value(3)).to be_a(Integer).and eq(3)
      expect(described_class.serialize_value(3.14)).to be_a(Float).and eq(3.14)
    end

    it "serializes other Numeric subclasses (BigDecimal, Rational) as JSON numbers (Float), matching the schema's number type" do
      # Regression: BigDecimal/Rational aren't Integer/Float, so without an explicit Numeric case
      # they fall through to as_json/to_s, producing STRINGS ("0.314e1", "1/3") that violate an
      # output_schema declaring `type: Numeric` => "number" (Axn::Reflection::Schema::TYPE_MAP).
      expect(described_class.serialize_value(BigDecimal("3.14"))).to be_a(Float).and eq(3.14)
      expect(described_class.serialize_value(Rational(1, 3))).to be_a(Float).and eq(1.0 / 3)
    end

    it "stringifies hash keys recursively" do
      expect(described_class.serialize_value({ a: { b: 1 } })).to eq("a" => { "b" => 1 })
    end

    it "maps arrays" do
      expect(described_class.serialize_value([1, { a: 2 }])).to eq([1, { "a" => 2 }])
    end

    it "serializes Time/DateTime/Date as ISO-8601/RFC3339 strings, matching the schema's date/date-time format" do
      # Regression: without an explicit case, Time/DateTime/Date fall through to `to_s` outside
      # Rails (no as_json, no meaningful to_h), producing a space-separated, non-RFC3339 string
      # that doesn't match the `format: "date-time"` / `format: "date"` advertised in the schema
      # (Axn::Reflection::Schema::FORMAT_MAP). They must serialize identically whether or not
      # ActiveSupport's json core_ext happens to be loaded.
      time = Time.utc(2026, 7, 3, 4, 39, 58)
      expect(described_class.serialize_value(time)).to eq(time.iso8601)
      expect(described_class.serialize_value(time)).to include("T")
      expect(described_class.serialize_value(time)).not_to include(" ")

      datetime = DateTime.new(2026, 7, 3, 4, 39, 58)
      expect(described_class.serialize_value(datetime)).to eq(datetime.iso8601)
      expect(described_class.serialize_value(datetime)).to include("T")

      date = Date.new(2026, 7, 3)
      expect(described_class.serialize_value(date)).to eq(date.iso8601)
      expect(described_class.serialize_value(date)).to eq("2026-07-03")
    end

    it "falls back to as_json, then to_h, then to_s" do
      # Test as_json path: explicitly define as_json
      as_json_obj = Object.new.tap { |o| def o.as_json(*) = { "k" => "v" } }
      expect(described_class.serialize_value(as_json_obj)).to eq("k" => "v")

      # Test to_h path: override respond_to? to hide as_json, implement to_h
      to_h_obj = Object.new.tap do |o|
        def o.respond_to?(name, *args)
          return false if name == :as_json

          super
        end

        def o.to_h = { "x" => 1 }
      end
      expect(described_class.serialize_value(to_h_obj)).to eq("x" => 1)

      # Test to_s path: override respond_to? to hide as_json and to_h, implement to_s
      to_s_obj = Object.new.tap do |o|
        def o.respond_to?(name, *args)
          return false if %i[as_json to_h].include?(name)

          super
        end

        def o.to_s = "S"
      end
      expect(described_class.serialize_value(to_s_obj)).to eq("S")
    end

    it "recurses the as_json result so nested Date/Time leaves and symbol keys are made JSON-safe" do
      # Regression (Codex P2): the `to_h` fallback branch already recurses
      # (`serialize_value(value.to_h)`), but the `as_json` branch used to return its result
      # verbatim. A value object's `as_json` can legitimately return a Hash/Array containing
      # symbol keys and/or raw Date/Time/Numeric leaves (as_json only promises "JSON-ish", not
      # fully JSON-safe/string-keyed) — those must be re-run through serialize_value exactly like
      # to_h's result is, or serialize_exposed's JSON-safe contract is broken.
      obj = Object.new
      def obj.as_json(*) = { created_at: Date.new(2026, 7, 3), nested: { at: Time.utc(2026, 7, 3, 4, 5, 6) } }

      result = described_class.serialize_value(obj)
      expect(result).to eq(
        "created_at" => Date.new(2026, 7, 3).iso8601,
        "nested" => { "at" => Time.utc(2026, 7, 3, 4, 5, 6).iso8601 },
      )
      expect(result).to eq("created_at" => "2026-07-03", "nested" => { "at" => "2026-07-03T04:05:06Z" })
    end

    it "recurses an as_json result that is an Array containing a Time" do
      obj = Object.new
      def obj.as_json(*) = [1, Time.utc(2026, 7, 3, 4, 5, 6), { updated_at: Date.new(2026, 7, 3) }]

      result = described_class.serialize_value(obj)
      expect(result).to eq([1, "2026-07-03T04:05:06Z", { "updated_at" => "2026-07-03" }])
    end

    it "leaves an already-JSON-safe as_json result unchanged (e.g. an ActiveRecord-like model)" do
      # Regression: an AR model's as_json already returns string-keyed JSON-safe scalars (it
      # formats Date/Time itself). Recursing through serialize_value must be a no-op for that shape.
      ar_like_obj = Object.new
      def ar_like_obj.as_json(*) = { "id" => 1, "name" => "widget", "active" => true, "note" => nil }

      expect(described_class.serialize_value(ar_like_obj)).to eq(
        "id" => 1, "name" => "widget", "active" => true, "note" => nil,
      )
    end
  end

  describe ".serialize_exposed" do
    it "serializes each declared field by wire key (string)" do
      klass = Class.new do
        include Axn
        exposes :count, type: Integer
        def call = expose(count: 3)
      end
      result = klass.call
      expect(described_class.serialize_exposed(result, klass.external_field_configs)).to eq("count" => 3)
    end
  end
end
