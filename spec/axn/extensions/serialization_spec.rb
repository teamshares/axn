# frozen_string_literal: true

require "spec_helper"

RSpec.describe Axn::Extensions::Serialization do
  # An object with no own as_json, no to_h, and #to_s owned by Object — but `respond_to?` is
  # overridden to hide :as_json/:to_h rather than left to chance: another spec file's
  # `require "globalid"` adds a generic Object#as_json globally for the rest of this process (a
  # Rails app does the same), which would otherwise route a plain Object.new through the as_json
  # branch instead of the to_s fallback these examples mean to exercise.
  def opaque_object
    Object.new.tap do |o|
      def o.respond_to?(name, *args)
        return false if %i[as_json to_h].include?(name)

        super
      end
    end
  end

  describe ".render" do
    it "serializes each declared field by wire key (string)" do
      klass = Class.new do
        include Axn
        exposes :count, type: Integer
        def call = expose(count: 3)
      end

      expect(described_class.render(klass.call)).to eq("count" => 3)
    end

    # The configs are DERIVED from the result rather than passed in, so what lands in the body is
    # exactly the declared `exposes` — the same set output_schema reflects. An inbound-only field is
    # not part of that set and must not appear.
    it "renders the declared exposures and nothing else" do
      klass = Class.new do
        include Axn
        expects :multiplier, type: Integer
        exposes :product, type: Integer
        def call = expose(product: multiplier * 2)
      end

      expect(described_class.render(klass.call(multiplier: 4))).to eq("product" => 8)
    end

    # Adapter specs mock results with Axn::Result.ok, which builds a real (factory-made) action
    # behind the facade — so the derivation has to work there too, not just for a declared class.
    it "derives the configs from a mocked result" do
      expect(described_class.render(Axn::Result.ok(count: 3))).to eq("count" => 3)
    end

    # The renderer also refuses a field name with no UTF-8 rendering, and two names that collapse onto one
    # property. Neither is reachable through `render`: `exposes` rejects both when the class is defined
    # (spec/axn/core/validations/property_name_collision_spec.rb), and `render` derives its configs from a
    # declared class. Those two backstops are exercised against a directly-built config list in
    # spec/axn/internal/reflection/values_spec.rb.

    it "renders an ordinary field name as a frozen UTF-8 property" do
      klass = Class.new do
        include Axn
        exposes :count, type: Integer
        def call = expose(count: 3)
      end

      key = described_class.render(klass.call).keys.first
      expect(key).to eq("count")
      expect(key.encoding).to eq(Encoding::UTF_8)
      expect(key).to be_frozen
    end

    it "threads reject_opaque: to the values it serializes" do
      owner = opaque_object
      klass = Class.new do
        include Axn
        auto_log false
        exposes :owner

        define_method(:call) { expose(owner:) }
      end
      result = klass.call

      expect(described_class.render(result)["owner"]).to match(/\A#<Object:0x[0-9a-f]+>\z/)
      expect { described_class.render(result, reject_opaque: true) }
        .to raise_error(Axn::Extensions::Serialization::UnserializableValue, /`owner`/)
    end
  end
end
