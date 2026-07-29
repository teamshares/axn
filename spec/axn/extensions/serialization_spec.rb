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

    # A field name is a property name in the output on the same terms as a nested Hash key, so it carries the
    # same UTF-8 promise. Declaration accepts any symbol, so a name with no UTF-8 rendering is reachable.
    it "holds a field name to the same encodability rule as a nested Hash key" do
      unencodable = "\xFF".b.to_sym
      klass = Class.new do
        include Axn
        auto_log false
        exposes unencodable

        define_method(:call) { expose(unencodable => 1) }
      end

      expect { described_class.render(klass.call) }
        .to raise_error(Axn::Reflection::UnserializableValue, /no UTF-8 rendering|UTF-8/)
    end

    it "names the offending field without interpolating its bytes, so reporting cannot itself raise" do
      unencodable = "\xFF".b.to_sym
      klass = Class.new do
        include Axn
        auto_log false
        exposes unencodable

        define_method(:call) { expose(unencodable => 1) }
      end

      # Symbol#inspect escapes the bytes to ASCII; interpolating the raw ones would raise
      # Encoding::CompatibilityError from building the message rather than reporting the defect.
      message = begin
        described_class.render(klass.call)
      rescue Axn::Reflection::UnserializableValue => e
        e.message
      end

      # The message itself is UTF-8 prose (it contains em dashes), so the property is that building it
      # succeeded and produced valid UTF-8 — not that it is ASCII-only.
      expect(message).to be_a(String)
      expect(message.encoding).to eq(Encoding::UTF_8)
      expect(message).to satisfy(&:valid_encoding?)
      expect(message).to include('\xFF')
    end

    # Canonicalizing field names to UTF-8 means two distinct Symbols can converge on one property, which
    # would silently overwrite — the same collapse the Hash branch raises on, reachable one level up.
    it "raises when two field names render as the same JSON property" do
      iso = "\xE9".dup.force_encoding(Encoding::ISO_8859_1).to_sym
      utf = :é
      klass = Class.new do
        include Axn
        auto_log false
        exposes iso
        exposes utf

        define_method(:call) { expose(iso => "FIRST", utf => "second") }
      end

      expect { described_class.render(klass.call) }
        .to raise_error(Axn::Reflection::UnserializableValue, /two exposed fields render as the same JSON property/)
    end

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
        .to raise_error(Axn::Reflection::UnserializableValue, /`owner`/)
    end
  end
end
