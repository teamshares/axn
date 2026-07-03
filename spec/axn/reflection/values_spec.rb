# frozen_string_literal: true

require "spec_helper"

RSpec.describe Axn::Reflection::Values do
  describe ".serialize_value" do
    it "passes through JSON scalars" do
      expect(described_class.serialize_value(1)).to eq(1)
      expect(described_class.serialize_value("x")).to eq("x")
      expect(described_class.serialize_value(true)).to eq(true)
      expect(described_class.serialize_value(nil)).to be_nil
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
