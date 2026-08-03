# frozen_string_literal: true

require "shellwords"
require "English"

require "spec_helper"
require "bigdecimal"
require "json"
require "singleton"

RSpec.describe Axn::Reflection::Values do
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

  # The surface is the deliverable, not an implementation detail: an adapter renders through
  # Axn::Extensions::Serialization.render, and what stays public does so for core's own callers rather
  # than for an adapter — serialize_value for Reflection::Schema, which renders a literal `default:`
  # through it so the schema's wire form and the serializer's cannot disagree; canonical_wire_key because
  # the same canonicalization is core's answer to what a JSON property name is, kept public so a
  # declaration-time check can share this one definition rather than re-deriving it. Anything else
  # appearing here is a new public promise about the renderer's own decisions, which is what constrains
  # core's routing later.
  describe "public surface" do
    it "exposes only the two methods reserved for core's own callers" do
      expect(described_class.singleton_class.public_instance_methods(false).sort).to eq(%i[canonical_wire_key serialize_value])
    end

    it "no longer answers the as_json-routing question that projection_for owns" do
      expect(described_class).not_to respond_to(:follow_as_json?)
    end
  end

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

    it "serializes a Symbol as its String form (matching TYPE_MAP's Symbol => \"string\")" do
      # JSON has no symbol type — a Symbol must render as a String, matching the schema's
      # `type: Symbol` => "string" mapping (Axn::Reflection::Schema::TYPE_MAP), not fall through
      # to the generic `to_s` else-branch incidentally.
      expect(described_class.serialize_value(:ok)).to be_a(String).and eq("ok")
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

      # Test to_s path: the shared helper already hides as_json/to_h, so only #to_s is left to reach
      to_s_obj = opaque_object.tap { |o| def o.to_s = "S" }
      expect(described_class.serialize_value(to_s_obj)).to eq("S")
    end

    it "recurses the as_json result so nested Date/Time leaves and symbol keys are made JSON-safe" do
      # Regression: the `to_h` fallback branch already recurses
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

  # The renderer's own field-name guards, reached with a config list built directly rather than through a
  # declaration. `expects`/`exposes` reject both of these names when the class is defined (see
  # spec/axn/core/validations/property_name_collision_spec.rb), and every public route into the renderer
  # derives its configs from a declared class — so these two branches are module-internal backstops for a
  # config list assembled by some other route, and the two layers have to agree on what a property name may
  # be. serialize_exposed is core-internal, so these reach it the way Extensions::Serialization does.
  describe "field names a config list can carry that no declaration can" do
    def bare_field_configs(*names)
      names.map { |name| Axn::Core::Contract::FieldConfig.new(field: name, validations: {}, reader_as: name) }
    end

    it "holds a field name to the same encodability rule as a nested Hash key" do
      configs = bare_field_configs("\xFF".b.to_sym)

      expect { described_class.send(:serialize_exposed, Object.new, configs) }
        .to raise_error(Axn::Reflection::UnserializableValue, /no UTF-8 rendering|UTF-8/)
    end

    it "names the offending field without interpolating its bytes, so reporting cannot itself raise" do
      configs = bare_field_configs("\xFF".b.to_sym)

      # Symbol#inspect escapes the bytes to ASCII; interpolating the raw ones would raise
      # Encoding::CompatibilityError from building the message rather than reporting the defect.
      message = begin
        described_class.send(:serialize_exposed, Object.new, configs)
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
    # would silently overwrite — the same collapse the Hash branch raises on, reachable one level up. Only
    # the first name needs a reader: the collision raises before the second config's value is read.
    it "raises when two field names render as the same JSON property" do
      iso = "\xE9".dup.force_encoding(Encoding::ISO_8859_1).to_sym
      configs = bare_field_configs(iso, :é)
      exposed = Class.new { define_method(iso) { "FIRST" } }.new

      expect { described_class.send(:serialize_exposed, exposed, configs) }
        .to raise_error(Axn::Reflection::UnserializableValue, /two exposed fields render as the same JSON property/)
    end
  end

  # Stringifying a Hash's keys collapses two keys with the same #to_s into ONE JSON property, dropping
  # a value. Unlike an ugly rendering, the caller cannot tell from the output that anything went
  # missing — so this raises regardless of strictness.
  # A post-condition behind the specific detectors: every known route to dropping an entry raises with a
  # precise message before this can fire. It exists for the routes nobody has thought of, since a caller can
  # override any method the walk touches — so an unforeseen drop surfaces loudly instead of as a body quietly
  # short a value. That makes it unreachable through the public API by construction, which is why these
  # examples drive the helper directly and stub the capture to prove it is wired in; there is no honest input
  # that reaches it.
  # JSON.generate dispatches #to_json on a String subclass, and on a plain String carrying a singleton
  # #to_json — so returning the caller's own String would leave the encoder taking its rendering from caller
  # code, however carefully the bytes were checked.
  describe "String values the encoder would ask for a rendering" do
    it "returns a plain String rather than a subclass whose to_json would be dispatched" do
      subclass = Class.new(String) { def to_json(*) = "NOT JSON" }

      rendered = described_class.serialize_value({ k: subclass.new("real") })
      expect(rendered["k"].class).to eq(String)
      expect(JSON.generate(rendered)).to eq('{"k":"real"}')
    end

    it "strips a singleton to_json, which instance_of? cannot screen for" do
      value = "plain".dup
      def value.to_json(*) = "NOT JSON"

      expect(JSON.generate(described_class.serialize_value({ k: value }))).to eq('{"k":"plain"}')
    end

    it "keeps a subclass whose to_json raises outside StandardError from escaping the encoder" do
      hostile = Class.new(String) { def to_json(*) = raise(SystemStackError, "boom") }

      expect { JSON.generate(described_class.serialize_value({ k: hostile.new("x") })) }.not_to raise_error
    end

    it "preserves encoding and multibyte content, and leaves the caller's object alone" do
      caller_owned = "café".dup

      expect(described_class.serialize_value(caller_owned)).to eq("café")
      expect(described_class.serialize_value(caller_owned).encoding).to eq(Encoding::UTF_8)
      expect(described_class.serialize_value("hi 🎉")).to eq("hi 🎉")
      expect(caller_owned).not_to be_frozen
    end
  end

  describe "the dropped-entry backstop" do
    it "raises when rendering produced fewer entries than were captured" do
      expect { described_class.send(:no_entries_lost!, 1, 2, "rec") }
        .to raise_error(Axn::Reflection::UnserializableValue, /produced 1 of its 2 entries.*bug in axn/m)
    end

    it "passes when the counts agree" do
      expect(described_class.send(:no_entries_lost!, 2, 2, "rec")).to be_nil
    end

    it "is wired into the Hash branch" do
      allow(described_class).to receive(:capture_hash_entries).and_return([["k", :k, 1], ["k", :k, 2]])

      expect { described_class.serialize_value({ a: 1 }, path: "rec") }
        .to raise_error(Axn::Reflection::UnserializableValue, /produced 1 of its 2 entries/)
    end

    # Deliberately absent from the Array branch: `map` yields exactly one rendered element per captured one,
    # so the counts cannot diverge there and the check would be provably dead code.
    it "renders every element of an Array, which needs no backstop to guarantee" do
      expect(described_class.serialize_value([1, { a: 2 }, nil]).size).to eq(3)
    end
  end

  describe "colliding Hash keys" do
    it "raises rather than silently dropping a value" do
      expect { described_class.serialize_value({ id: 1, "id" => 2 }, path: "rec") }
        .to raise_error(
          Axn::Reflection::UnserializableValue,
          # Also pins the remediation clause: every message states the problem AND the fix (AGENTS.md).
          /`rec \(hash key\)`.*two keys stringify to the same JSON property "id".*silently collapse and drop a value.*Key the Hash by one of them/m,
        )
    end

    it "names both original keys by class, so the caller can see which pair to fix" do
      expect { described_class.serialize_value({ id: 1, "id" => 2 }) }
        .to raise_error(Axn::Reflection::UnserializableValue, /\(one of class Symbol, one of class String\)/)
    end

    it "names the first colliding pair in insertion order when more than two keys collide" do
      third = Object.new.tap { |o| def o.to_s = "id" }

      expect { described_class.serialize_value({ "id" => 1, id: 2, third => 3 }) }
        .to raise_error(Axn::Reflection::UnserializableValue, /\(one of class String, one of class Symbol\)/)
    end

    it "names the nested path of the offending Hash" do
      expect { described_class.serialize_value({ rows: [{ a: 1, "a" => 2 }] }, path: "out") }
        .to raise_error(Axn::Reflection::UnserializableValue, /`out\.rows\[0\] \(hash key\)`/)
    end

    it "leaves a Hash whose keys stringify distinctly unchanged" do
      expect(described_class.serialize_value({ id: 1, "name" => "x", 2 => :b }))
        .to eq("id" => 1, "name" => "x", "2" => "b")
    end

    # A JSON property name is UTF-8 text, so two keys holding the same characters in different encodings are
    # ONE property even though Ruby holds them as distinct, non-`eql?` Strings. Comparing the keys as the
    # caller wrote them would pass the pair through, and `JSON.generate` would then emit the property twice —
    # which `JSON.parse` collapses, dropping a value.
    it "catches two keys that are the same property name in different encodings" do
      iso = "\xE9".dup.force_encoding(Encoding::ISO_8859_1)
      source = { iso => "FIRST", "é" => "second" }

      expect(source.size).to eq(2)
      expect(iso).not_to eql("é")
      expect { described_class.serialize_value(source, path: "rec") }
        .to raise_error(
          Axn::Reflection::UnserializableValue,
          /two keys stringify to the same JSON property "é".*silently collapse and drop a value/m,
        )
    end

    it "renders a transcodable non-UTF-8 key as the UTF-8 property name an encoder emits" do
      rendered = described_class.serialize_value({ "\x82\xA0".dup.force_encoding(Encoding::Shift_JIS) => 1 }, path: "rec")
      key = rendered.keys.first

      expect(rendered).to eq("あ" => 1)
      expect(key.encoding).to eq(Encoding::UTF_8)
      expect(key.frozen?).to be(true)
      expect(key.instance_of?(String)).to be(true)
    end

    it "leaves an ordinary ASCII or UTF-8 payload's property names exactly as they render" do
      rendered = described_class.serialize_value({ id: 1, "héllo" => 2, "party 🎉" => 3 })

      expect(rendered).to eq("id" => 1, "héllo" => 2, "party 🎉" => 3)
      expect(rendered.keys.map(&:encoding).uniq).to eq([Encoding::UTF_8])
    end

    it "names the pair by the #to_s each key returned, without asking a key twice" do
      # A key whose #to_s returns a different String on each call: the collapse is the one the FIRST call
      # produced ("k1", which the literal String key also produces), so that is the pair named. Re-deriving
      # the wire keys on the error path would group them distinctly and lose the pair entirely.
      unstable = Object.new
      def unstable.to_s
        @calls = (@calls || 0) + 1
        "k#{@calls}"
      end

      expect { described_class.serialize_value({ unstable => 1, "k1" => 2 }, path: "rec") }
        .to raise_error(
          Axn::Reflection::UnserializableValue,
          /two keys stringify to the same JSON property "k1".*silently collapse and drop a value/m,
        )
    end

    it "catches keys mutated into agreement after insertion, which the Hash itself still holds separately" do
      # Ruby does not rehash on mutation, so both entries are really there — but both keys now stringify
      # alike, so rendering them would collapse two entries into one property and drop a value. Capturing
      # the entries as a list is what keeps them both visible: re-inserting them into a Hash would merge
      # them (the mutated keys are `eql?` now), losing one with nothing left to detect.
      first_key = [1]
      second_key = [2]
      source = { first_key => "first", second_key => "SECOND" }
      second_key.replace([1])

      expect(source.size).to eq(2)
      expect { described_class.serialize_value(source, path: "rec") }
        .to raise_error(
          Axn::Reflection::UnserializableValue,
          /two keys stringify to the same JSON property "\[1\]".*silently collapse and drop a value/m,
        )
    end

    it "raises its own StandardError rather than a key's exception when a key's #to_s only fails on a later call" do
      # Naming the collapsing pair must not project a key a second time: this key's second #to_s raises a
      # SystemStackError, which is outside StandardError and would sail straight through the `rescue
      # StandardError` every adapter maps serialization failures with.
      volatile = Object.new
      def volatile.to_s
        @calls = (@calls || 0) + 1
        raise SystemStackError, "stack level too deep" if @calls > 1

        "k"
      end

      expect { described_class.serialize_value({ volatile => 1, "k" => 2 }, path: "rec") }
        .to raise_error(
          Axn::Reflection::UnserializableValue,
          /two keys stringify to the same JSON property "k".*silently collapse and drop a value/m,
        )
    end
  end

  # Every method a caller can override is a way to replace the failure being reported with an exception of
  # the caller's own — and one outside StandardError sails through the `rescue StandardError` an adapter maps
  # serialization failures with, reinstating exactly the escape this module exists to close. So nothing
  # between "this Hash cannot be serialized" and "the error is constructed" may dispatch a key's code.
  describe "keys whose own methods raise while the failure is being reported" do
    it "reports the collision as its own StandardError when a colliding key's #inspect raises" do
      key = Object.new
      def key.to_s = "dup"
      def key.inspect = raise(SystemStackError, "stack level too deep")

      expect { described_class.serialize_value({ "dup" => 1, key => 2 }, path: "rec") }
        .to raise_error(Axn::Reflection::UnserializableValue) do |error|
          expect(error).to be_a(StandardError)
          expect(error.message).to match(/two keys stringify to the same JSON property "dup"/)
        end
    end

    it "reports the collision when a colliding key's #class raises" do
      key = Object.new
      def key.to_s = "k"
      def key.class = raise(SystemStackError, "stack level too deep")

      expect { described_class.serialize_value({ key => 1, "k" => 2 }, path: "rec") }
        .to raise_error(Axn::Reflection::UnserializableValue, /\(one of class Object, one of class String\)/)
    end

    it "reports an opaque key whose #class raises, under reject_opaque:" do
      key = Object.new
      def key.class = raise(SystemStackError, "stack level too deep")

      expect { described_class.serialize_value({ key => 1 }, path: "data", reject_opaque: true) }
        .to raise_error(Axn::Reflection::UnserializableValue, /`data \(hash key\)` \(Object\).*a Hash key is rendered via #to_s/m)
    end

    it "serializes a key whose #to_s returns a String subclass with a hostile #-@, under a property it owns" do
      # The wire key is copied out of whatever #to_s returned, and the copy must not be made by any
      # operation the returned String can intercept — `-@` and `initialize_copy` are both overridable.
      hostile = Class.new(String) { def -@ = raise(SystemStackError, "stack level too deep") }
      key = Object.new
      key.define_singleton_method(:to_s) { hostile.new("k") }

      serialized = described_class.serialize_value({ key => 1 }, path: "rec")

      expect(serialized).to eq("k" => 1)
      expect(serialized.keys.first.instance_of?(String)).to be(true)
    end

    it "reports a collision on a key whose #to_s returns a String subclass with a hostile #-@" do
      hostile = Class.new(String) { def -@ = raise(SystemStackError, "stack level too deep") }
      key = Object.new
      key.define_singleton_method(:to_s) { hostile.new("k") }

      expect { described_class.serialize_value({ key => 1, "k" => 2 }, path: "rec") }
        .to raise_error(Axn::Reflection::UnserializableValue, /same JSON property "k".*silently collapse/m)
    end

    it "disambiguates a colliding pair by class, so a shared rendering still identifies both keys" do
      expect { described_class.serialize_value({ nil => 1, "" => 2 }, path: "rec") }
        .to raise_error(Axn::Reflection::UnserializableValue, /property "" \(one of class NilClass, one of class String\)/)

      expect { described_class.serialize_value({ 1 => "a", "1" => "b" }, path: "rec") }
        .to raise_error(Axn::Reflection::UnserializableValue, /property "1" \(one of class Integer, one of class String\)/)
    end

    it "says both keys share a class when they do, which is itself the actionable fact" do
      first = Object.new.tap { |o| def o.to_s = "shared" }
      second = Object.new.tap { |o| def o.to_s = "shared" }

      expect { described_class.serialize_value({ first => 1, second => 2 }, path: "rec") }
        .to raise_error(Axn::Reflection::UnserializableValue, /property "shared" \(both of class Object\)/)
    end
  end

  # Serializing an element runs user code (`to_h`/`as_json`), and that code can reach back into the very
  # container being serialized. Iterating it live would skip whatever the code removed, yielding a body
  # that is quietly missing entries with nothing in the output to say so — worse than any raise. Every
  # container is therefore rendered from entries captured before the first element is projected.
  describe "a container mutated by one of its own values' projections" do
    # Deletes `key`/index 1 from the container it was put in the first time its projection runs.
    def saboteur(container, key)
      Object.new.tap do |o|
        o.instance_variable_set(:@container, container)
        o.instance_variable_set(:@key, key)
        def o.to_h
          @container.is_a?(Array) ? @container.delete_at(@key) : @container.delete(@key)
          { x: 1 }
        end
      end
    end

    it "renders every Hash entry present when serialization began" do
      source = {}
      source[:a] = saboteur(source, :b)
      source[:b] = "SHOULD APPEAR"

      expect(described_class.serialize_value(source, path: "rec")).to eq("a" => { "x" => 1 }, "b" => "SHOULD APPEAR")
    end

    it "renders every Array element present when serialization began" do
      source = []
      source << saboteur(source, 1) << "SHOULD APPEAR"

      expect(described_class.serialize_value(source, path: "rows")).to eq([{ "x" => 1 }, "SHOULD APPEAR"])
    end

    # A KEY's #to_s is caller code on the same terms as an element's projection, and it is dispatched a pass
    # LATER than the walk that captures entries — because a deletion during the walk itself makes Ruby skip
    # the following entry, which then never reaches the capture and so cannot be missed by any check.
    it "renders every Hash entry present when a key's #to_s deletes a later one" do
      source = {}
      deleter = Object.new
      deleter.instance_variable_set(:@source, source)
      def deleter.to_s
        @source.delete(:later)
        "first"
      end
      source[deleter] = "A"
      source[:later] = "SHOULD APPEAR"

      expect(described_class.serialize_value(source, path: "rec")).to eq("first" => "A", "later" => "SHOULD APPEAR")
    end

    it "renders the entries a Hash held at the start when a key's #to_s adds one, and does not raise" do
      # Adding during a live iteration is what Ruby answers with `RuntimeError: can't add a new key into hash
      # during iteration`, so a key projected mid-walk could replace the serialization with that error. The
      # guarantee covers entries present when serialization began; one appearing afterwards is simply not part
      # of the snapshot, so it lands in the source Hash and not in the output.
      source = {}
      adder = Object.new
      adder.instance_variable_set(:@source, source)
      def adder.to_s
        @source[:added] = "AFTERWARDS"
        "first"
      end
      source[adder] = "A"

      expect(described_class.serialize_value(source, path: "rec")).to eq("first" => "A")
      expect(source[:added]).to eq("AFTERWARDS")
    end
  end

  # Walking a container inherently dispatches its `each`, and nothing else: every Enumerable convenience over
  # `each` is separately overridable, so a subclass defining one — while `each` itself walks the real entries
  # — could substitute contents or refuse outright on a container that is perfectly traversable.
  describe "a container subclass overriding iteration helpers other than #each" do
    it "renders a Hash subclass's real entries, not what its each_with_object/map/to_a return" do
      decoy = Class.new(Hash) do
        def each_with_object(memo) = memo
        def map(*) = [%w[decoy 99]]
        def to_a = [[:decoy, 99]]
        def transform_keys(*) = { decoy: 99 }
        def each_key = [:decoy].each
      end.new
      decoy[:real] = "data"

      expect(described_class.serialize_value(decoy, path: "rec")).to eq("real" => "data")
    end

    it "renders an Array subclass's real elements, not what its each_with_object/map/to_a return" do
      decoy = Class.new(Array) do
        def each_with_object(memo) = memo.tap { |m| m << "DECOY" }
        def map(*) = ["DECOY"]
        def to_a = ["DECOY"]
        def each_with_index(*) = [["DECOY", 0]].each
        def size = 99
      end.new
      decoy << "data" << "more"

      expect(described_class.serialize_value(decoy, path: "rows")).to eq(%w[data more])
    end

    it "serializes an Array subclass whose each_with_object raises" do
      exploding = Class.new(Array) { def each_with_object(*) = raise(TypeError, "no folding over me") }.new
      exploding << "data"

      expect(described_class.serialize_value(exploding, path: "rows")).to eq(["data"])
    end
  end

  # A Hash/Array SUBCLASS can override the copying methods (`dup`/`initialize_copy`) to return something
  # other than the receiver's entries, or to refuse to copy at all. The capture therefore walks the
  # original's own entries and never dispatches `dup`, so what renders is what the container actually holds
  # and a container that was traversable stays traversable.
  describe "a container subclass whose #dup is not a faithful copy" do
    it "renders a Hash subclass's real entries rather than what its #dup returns" do
      decoy = Class.new(Hash) { def dup = { decoy: 99 } }.new
      decoy[:real] = "data"

      expect(described_class.serialize_value(decoy, path: "rec")).to eq("real" => "data")
    end

    it "serializes a Hash subclass that cannot be duped at all" do
      # A Singleton-including Hash raises TypeError on #dup ("can't dup instance of singleton"), so a
      # snapshot taken by dispatching #dup would crash on a Hash it could otherwise walk entry by entry.
      undupable = Class.new(Hash) { include Singleton }.instance
      undupable[:real] = "data"

      expect { undupable.dup }.to raise_error(TypeError)
      expect(described_class.serialize_value(undupable, path: "rec")).to eq("real" => "data")
    end

    it "renders an Array subclass's real elements rather than what its #dup returns" do
      decoy = Class.new(Array) { def dup = ["decoy"] }.new
      decoy << "data"

      expect(described_class.serialize_value(decoy, path: "rows")).to eq(["data"])
    end

    it "serializes an Array subclass whose #dup raises" do
      exploding = Class.new(Array) { def dup = raise(TypeError, "no copies of me") }.new
      exploding << "data"

      expect(described_class.serialize_value(exploding, path: "rows")).to eq(["data"])
    end
  end

  # An identity-keyed Hash compares keys by object identity, so it can hold two `==`-equal-but-distinct
  # keys — entries that a capture re-keyed by the caller's keys would merge, dropping a value AND leaving
  # the collapse check with a single entry and so nothing to report. The captured list cannot merge them.
  describe "a compare_by_identity Hash" do
    it "round-trips its entries" do
      source = {}.compare_by_identity
      source[:a] = 1
      source["b"] = 2

      expect(described_class.serialize_value(source, path: "rec")).to eq("a" => 1, "b" => 2)
    end

    it "keeps two ==-equal-but-distinct keys distinct, so the collision check still names the pair" do
      source = {}.compare_by_identity
      source["k"] = 1
      source["k".dup] = 2

      expect(source.size).to eq(2)
      expect { described_class.serialize_value(source, path: "rec") }
        .to raise_error(Axn::Reflection::UnserializableValue, /two keys stringify to the same JSON property "k"/)
    end
  end

  # serialize_value's last resort is `value.to_s`. When that #to_s is the one inherited from Object,
  # the result is an object address — complete, but useless in a response body or an LLM's tool
  # result. Callers can set reject_opaque: true to reject it; the default keeps rendering it, since a
  # lossless-but-ugly value is not worth failing an MCP call over.
  describe "default-to_s values under reject_opaque:" do
    let(:opaque) { opaque_object }

    it "renders the object address by default" do
      expect(described_class.serialize_value(opaque, path: "owner")).to match(/\A#<Object:0x[0-9a-f]+>\z/)
    end

    it "raises under reject_opaque:, naming the path and how to fix it" do
      expect { described_class.serialize_value(opaque, path: "owner", reject_opaque: true) }
        .to raise_error(
          Axn::Reflection::UnserializableValue,
          /`owner` \(Object\).*only via the default Object#to_s.*declare it `type: String`/m,
        )
    end

    it "allows a value with a meaningful custom to_s under reject_opaque:" do
      money = opaque_object.tap { |o| def o.to_s = "$5.00" }

      expect(described_class.serialize_value(money, reject_opaque: true)).to eq("$5.00")
    end

    # A `to_hash` is a projection only where ActiveSupport's generic Object#as_json exists to delegate to it
    # (a Rails app — see spec_rails). With no `as_json` in reach the routing chain is `to_h` then `to_s`,
    # which never consults `to_hash`, so such a value renders as an address and is opaque here. Pinned
    # because the same value serializes its `to_hash` under Rails.
    it "treats a value declaring only to_hash as opaque, since nothing here routes through to_hash" do
      only_to_hash = opaque_object.tap { |o| def o.to_hash = { label: "public" } }

      expect(described_class.serialize_value(only_to_hash)).to match(/\A#<Object:0x[0-9a-f]+>\z/)
      expect { described_class.serialize_value(only_to_hash, path: "dto", reject_opaque: true) }
        .to raise_error(Axn::Reflection::UnserializableValue, /`dto`.*only via the default Object#to_s/m)
    end

    it "checks inside an Array, naming the indexed path" do
      expect { described_class.serialize_value([1, opaque], path: "rows", reject_opaque: true) }
        .to raise_error(Axn::Reflection::UnserializableValue, /`rows\[1\]`/)
    end

    it "checks inside a Hash, naming the keyed path" do
      expect { described_class.serialize_value({ owner: opaque }, path: "rec", reject_opaque: true) }
        .to raise_error(Axn::Reflection::UnserializableValue, /`rec\.owner`/)
    end

    it "checks a value reached through a custom to_h, since the checks live inside the recursion" do
      wrapper = Object.new
      wrapper.instance_variable_set(:@inner, opaque)
      def wrapper.to_h = { inner: @inner }

      expect { described_class.serialize_value(wrapper, path: "w", reject_opaque: true) }
        .to raise_error(Axn::Reflection::UnserializableValue, /`w\.inner`/)
    end

    it "checks a value reached through a custom as_json, the other recursion route" do
      # The as_json branch recurses just like the to_h one, so the check has to be threaded through both;
      # a value nested in an as_json result is the shape a missed thread would render silently.
      wrapper = Object.new
      wrapper.instance_variable_set(:@inner, opaque)
      def wrapper.as_json(*) = { inner: @inner }

      expect { described_class.serialize_value(wrapper, path: "w", reject_opaque: true) }
        .to raise_error(Axn::Reflection::UnserializableValue, /`w\.inner`.*only via the default Object#to_s/m)
    end

    it "renders a value whose #to_s is served by method_missing instead of rejecting it" do
      # `method(:to_s)` can't resolve an undef'd #to_s that no respond_to_missing? advertises, so the
      # predicate has no owner to compare. The value renders through method_missing fine, and reject_opaque
      # must not invent a failure for it.
      dynamic = opaque_object
      dynamic.singleton_class.class_eval do
        undef_method :to_s
        def method_missing(name, ...) = name == :to_s ? "dynamic" : super
        def respond_to_missing?(_name, _include_private = false) = false
      end

      expect(described_class.serialize_value(dynamic, reject_opaque: true)).to eq("dynamic")
    end

    it "leaves every ordinary value untouched under reject_opaque:" do
      as_json_obj = Object.new.tap { |o| def o.as_json(*) = { "k" => "v" } }

      expect(described_class.serialize_value(:ok, reject_opaque: true)).to eq("ok")
      expect(described_class.serialize_value(BigDecimal("3.14"), reject_opaque: true)).to eq(3.14)
      expect(described_class.serialize_value(Date.new(2026, 7, 3), reject_opaque: true)).to eq("2026-07-03")
      expect(described_class.serialize_value({ a: [1, nil, true] }, reject_opaque: true)).to eq("a" => [1, nil, true])
      expect(described_class.serialize_value(as_json_obj, reject_opaque: true)).to eq("k" => "v")
    end

    it "still raises on a cycle under reject_opaque:, with the cycle reason rather than a to_s reason" do
      cyclic = [1]
      cyclic << cyclic

      expect { described_class.serialize_value(cyclic, path: "items", reject_opaque: true) }
        .to raise_error(Axn::Reflection::UnserializableValue, /self-referential/)
    end

    it "raises on colliding keys under either setting, since a dropped value is wrong output" do
      [false, true].each do |reject_opaque|
        expect { described_class.serialize_value({ id: 1, "id" => 2 }, reject_opaque:) }
          .to raise_error(Axn::Reflection::UnserializableValue, /silently collapse/)
      end
    end
  end

  # A Hash's keys render via `to_s` and never the as_json/to_h chain, so an opaque key becomes an
  # object address used as a JSON PROPERTY NAME.
  describe "default-to_s Hash keys under reject_opaque:" do
    let(:opaque_key) { Object.new }

    # `#method` is overridable, so the owner lookups ask Object's implementation. A value whose own #method
    # raises must not be able to replace a serialization decision with its exception.
    it "never dispatches a value's or key's own #method when checking to_s ownership" do
      # Built on the masking helper so the value reaches the `to_s` fallback under the full suite, where a
      # generic Object#as_json exists: without a to_h it would otherwise be an undeclared projection and be
      # rejected for that reason instead, never exercising the owner lookup under test.
      hostile_value = opaque_object.tap do |o|
        def o.to_s = "meaningful"
        def o.method(_name) = raise(SystemStackError, "boom")
      end
      # A Hash key never consults the as_json chain, so it needs no masking.
      hostile_key = Object.new.tap do |o|
        def o.to_s = "meaningful"
        def o.method(_name) = raise(SystemStackError, "boom")
      end

      expect(described_class.serialize_value(hostile_value, reject_opaque: true)).to eq("meaningful")
      expect(described_class.serialize_value({ hostile_key => 1 }, reject_opaque: true)).to eq("meaningful" => 1)
    end

    # By contrast, overriding respond_to? is a supported Ruby idiom (a method_missing proxy depends on it),
    # so it stays dispatched — the value genuinely owns the answer to "do you respond to this?".
    it "still honors a respond_to? override, which is the value's own answer to give" do
      hidden = opaque_object.tap { |o| def o.to_s = "S" }

      expect(described_class.serialize_value(hidden, reject_opaque: true)).to eq("S")
    end

    # The fast path that skips Symbol/String keys must not ask the key what it is: a key answering that
    # question itself could route around the gate, or replace the serialization failure with its own error.
    it "does not let a key claiming to be a Symbol route around the gate" do
      liar = Object.new.tap do |o|
        def o.is_a?(klass) = klass == Symbol ? true : super
      end

      expect { described_class.serialize_value({ liar => 1 }, path: "data", reject_opaque: true) }
        .to raise_error(Axn::Reflection::UnserializableValue, /a Hash key is rendered via #to_s/)
    end

    it "never dispatches a key's own is_a?, so one that raises cannot escape" do
      hostile = Object.new.tap do |o|
        def o.is_a?(_klass) = raise(SystemStackError, "boom")
        def o.to_s = "k"
      end

      expect(described_class.serialize_value({ hostile => 1 }, reject_opaque: true)).to eq("k" => 1)
    end

    it "renders the object address as a property name by default" do
      expect(described_class.serialize_value({ opaque_key => 1 }).keys.first)
        .to match(/\A#<Object:0x[0-9a-f]+>\z/)
    end

    it "raises under reject_opaque:, naming the offending key in the path" do
      expect { described_class.serialize_value({ opaque_key => 1 }, path: "data", reject_opaque: true) }
        .to raise_error(
          Axn::Reflection::UnserializableValue,
          # Also pins the remediation clause: every message states the problem AND the fix (AGENTS.md).
          /`data \(hash key\)` \(Object\).*a Hash key is rendered via #to_s.*key the Hash by a Symbol, String, or Integer/m,
        )
    end

    it "allows Symbol, String, and Integer keys under reject_opaque:" do
      expect(described_class.serialize_value({ a: 1, "b" => 2, 3 => 4 }, reject_opaque: true))
        .to eq("a" => 1, "b" => 2, "3" => 4)
    end

    it "allows a key with a meaningful custom to_s under reject_opaque:" do
      key = Object.new.tap { |o| def o.to_s = "custom" }

      expect(described_class.serialize_value({ key => 1 }, reject_opaque: true)).to eq("custom" => 1)
    end

    it "checks keys of a nested Hash, naming the nested path" do
      expect { described_class.serialize_value({ rows: [{ opaque_key => 1 }] }, path: "out", reject_opaque: true) }
        .to raise_error(Axn::Reflection::UnserializableValue, /`out\.rows\[0\] \(hash key\)` \(Object\)/)
    end
  end

  # `axn/reflection` is loadable on its own (it composes only its own reflection files), and adapters are
  # pointed at it. Serializing ANY Hash or Array now reaches CycleGuard, and raising needs
  # UnserializableValue — both of which live outside that entrypoint, so values.rb requires them itself.
  # Asserted in a subprocess: the suite has all of axn loaded, so it cannot observe this in-process.
  describe "the axn/reflection entrypoint on its own" do
    def ruby(snippet)
      lib = File.expand_path("../../../lib", __dir__)
      out = `ruby -I#{lib} -e #{Shellwords.escape(snippet)} 2>&1`
      [out.strip, $CHILD_STATUS.success?]
    end

    # Compared INSIDE the subprocess: Hash#inspect formatting is Ruby-version-dependent (3.4 renders
    # `{"a" => [1]}`, 3.3 `{"a"=>[1]}`), so asserting on its text would pass on one matrix ruby and fail
    # on another. What matters here is that the call works at all without the top-level entrypoint.
    it "serializes ordinary structured output without loading all of axn" do
      out, ok = ruby('require "axn/reflection"; print Axn::Reflection::Values.serialize_value({ a: [1] }) == { "a" => [1] }')

      expect(ok).to be(true), "subprocess failed: #{out}"
      expect(out).to eq("true")
    end

    it "can still raise its own UnserializableValue" do
      out, ok = ruby(<<~RUBY)
        require "axn/reflection"
        cyclic = [1]
        cyclic << cyclic
        begin
          Axn::Reflection::Values.serialize_value(cyclic)
        rescue Axn::Reflection::UnserializableValue => e
          print e.class
        end
      RUBY

      expect(ok).to be(true), "subprocess failed: #{out}"
      expect(out).to eq("Axn::Reflection::UnserializableValue")
    end
  end

  describe Axn::Reflection::UnserializableValue do
    it "renders a supplied reason verbatim after the path and the value's class" do
      error = described_class.new(path: "data (hash key :x)", value: :x, reason: "it is bad.")

      expect(error.message).to eq("Cannot serialize exposed value at `data (hash key :x)` (Symbol): it is bad.")
    end

    it "falls back to the cycle reason when none is supplied, so the two-kwarg call form keeps working" do
      error = described_class.new(path: "items[1]", value: [])

      expect(error.message).to eq(
        "Cannot serialize exposed value at `items[1]` (Array): it is self-referential (an Array cycle), " \
        "which has no JSON representation. Expose a finite projection of it instead " \
        "(e.g. ids rather than the objects that point back).",
      )
    end

    it "agrees the article with the class name, both ways" do
      expect(described_class.new(path: "items", value: []).message).to include("(an Array cycle)")
      expect(described_class.new(path: "data", value: {}).message).to include("(a Hash cycle)")
    end

    # `class` is itself overridable, so a value that overrides it could otherwise replace this error with
    # its own exception at the moment the message is rendered.
    it "reports the real class of a value whose #class raises, without running the override" do
      value = Object.new
      def value.class = raise(SystemStackError, "stack level too deep")

      expect(described_class.new(path: "items", value:).message)
        .to include("`items` (Object): it is self-referential (an Object cycle)")
    end

    # `class.name` is nil for an anonymous class, so the article is keyed off `class.to_s`, which is a
    # String either way.
    it "takes 'a' for an anonymous class, whose to_s renders as #<Class:0x…>" do
      anonymous = Class.new.new

      expect(described_class.new(path: "items", value: anonymous).message).to match(/\(a #<Class:0x[0-9a-f]+> cycle\)/)
    end

    # `Module#to_s` hands back a constant path's own bytes, and a constant may hold non-UTF-8 ones — so
    # naming the offending value's class could destroy the report it was building. A Symbol built from a
    # String already TAGGED UTF-8 must hold valid UTF-8 bytes — `const_set`/`to_sym` reject anything else
    # in that encoding outright — so a constant reaches this state by being interned from a String tagged
    # with a DIFFERENT encoding whose bytes have no UTF-8 mapping at all: ASCII-8BIT holding `\xFF`, which
    # `String#encode(Encoding::UTF_8)` refuses (`Encoding::UndefinedConversionError`), unlike a
    # transcodable encoding such as ISO-8859-1.
    #
    # `path` is genuinely non-ASCII rather than an artifact of this test: a real axn path is built from
    # field names and canonicalized wire keys, which preserve legitimate non-ASCII (see `:naïve` elsewhere
    # in this suite). The join only raises when that surrounding text is non-ASCII too — two
    # same-or-ASCII-only-compatible encodings concatenate fine regardless of validity, so an all-ASCII
    # `path` would not reproduce this.
    describe "naming a value whose class holds bytes with no UTF-8 rendering" do
      let(:unrenderable_class) do
        name = "UnrenderableCafeValue".dup
        name[15] = "\xFF".dup.force_encoding(Encoding::BINARY)
        Object.const_set(name, Class.new) unless Object.const_defined?(name)
        Object.const_get(name)
      end

      it "renders the class name rather than raising from the report" do
        error = described_class.new(path: "thïng", value: unrenderable_class.new, reason: "nope")

        expect { error.message }.not_to raise_error
        expect(error.message).to include("thïng")
      end

      it "renders it in the cycle wording too" do
        error = described_class.new(path: "thïng", value: unrenderable_class.new)

        expect { error.message }.not_to raise_error
      end
    end
  end

  # A cycle has no JSON representation, so this is a serialization FAILURE rather than something to
  # paper over: serialize_exposed renders a response body, and a caller can't tell an elided-cycle
  # marker from a real value. Raising as a StandardError also lets an adapter's existing rescue map it
  # to an error response — which a SystemStackError, being outside StandardError, could not do.
  describe "self-referential values" do
    it "raises, naming the path to the offending value" do
      cyclic = [{ sku: "A" }]
      cyclic << cyclic

      expect { described_class.serialize_value(cyclic, path: "items") }
        .to raise_error(Axn::Reflection::UnserializableValue, /`items\[1\]`.*self-referential.*no JSON representation/m)
    end

    it "names the offending exposure when reached through serialize_exposed" do
      klass = Class.new do
        include Axn
        auto_log false
        exposes :items

        def call = expose(items: [1].tap { |a| a << a })
      end

      expect { Axn::Extensions::Serialization.render(klass.call) }
        .to raise_error(Axn::Reflection::UnserializableValue, /`items\[1\]`/)
    end

    it "is a StandardError, so an adapter's existing rescue catches it" do
      cyclic = {}
      cyclic[:self] = cyclic

      expect(Axn::Reflection::UnserializableValue.ancestors).to include(StandardError)
      expect { described_class.serialize_value(cyclic) }.to raise_error(StandardError)
    end

    # Guards on the SOURCE object, since #as_json/#to_h build a fresh Hash per call — keying on the
    # produced Hash would never see the repeat.
    it "catches an object whose own projection points back at it" do
      node = Class.new do
        def initialize = @me = self
        def to_h = { child: @me }
      end.new

      expect { described_class.serialize_value(node, path: "node") }
        .to raise_error(Axn::Reflection::UnserializableValue, /`node.child`/)
    end

    # Ancestry, not every-container-ever-seen: a container referenced twice as siblings is legitimate.
    it "does not false-positive on a diamond (same object referenced twice, acyclic)" do
      shared = { x: 1 }

      expect(described_class.serialize_value({ p: shared, q: shared }))
        .to eq("p" => { "x" => 1 }, "q" => { "x" => 1 })
    end

    it "leaves acyclic nesting untouched" do
      expect(described_class.serialize_value({ a: [1, { b: 2 }] })).to eq("a" => [1, { "b" => 2 }])
    end
  end

  # A body an encoder refuses is not JSON, so this is the same category as a cycle: unconditional, at both
  # `reject_opaque:` settings, since no adapter can want output `JSON.generate` won't accept. Core is also
  # the only layer that still knows the value was at `records[3].price` — an encoder refusing it downstream
  # reports no path at all.
  describe "values JSON.generate refuses" do
    def binary(bytes) = bytes.dup.force_encoding(Encoding::BINARY)

    describe "a non-finite Float" do
      [Float::INFINITY, -Float::INFINITY, Float::NAN].each do |value|
        it "raises for #{value}, naming the path" do
          expect { described_class.serialize_value(value, path: "price") }
            .to raise_error(Axn::Reflection::UnserializableValue, /`price` \(Float\).*non-finite number.*Expose a finite number/m)
        end

        it "raises for #{value} at both reject_opaque: settings" do
          [false, true].each do |reject_opaque|
            expect { described_class.serialize_value(value, path: "price", reject_opaque:) }
              .to raise_error(Axn::Reflection::UnserializableValue)
          end
        end
      end

      it "names the nested path inside an Array" do
        expect { described_class.serialize_value([{ price: Float::INFINITY }], path: "records") }
          .to raise_error(Axn::Reflection::UnserializableValue, /`records\[0\]\.price`/)
      end

      it "names the nested path behind a custom to_h" do
        wrapper = Class.new { def to_h = { ratio: Float::NAN } }.new

        expect { described_class.serialize_value(wrapper, path: "stats") }
          .to raise_error(Axn::Reflection::UnserializableValue, /`stats\.ratio`/)
      end

      it "names the offending exposure when reached through serialize_exposed" do
        klass = Class.new do
          include Axn
          auto_log false
          exposes :ratio

          def call = expose(ratio: Float::INFINITY)
        end

        expect { Axn::Extensions::Serialization.render(klass.call) }
          .to raise_error(Axn::Reflection::UnserializableValue, /`ratio`/)
      end

      # The Numeric arm coerces with Float(), which is where a BigDecimal/Rational becomes non-finite —
      # so the check belongs on that path too, and the error names the class actually exposed.
      it "raises for a BigDecimal that coerces to a non-finite Float" do
        [BigDecimal("Infinity"), BigDecimal("-Infinity"), BigDecimal("NaN"), BigDecimal("1e400")].each do |value|
          expect { described_class.serialize_value(value, path: "total") }
            .to raise_error(Axn::Reflection::UnserializableValue, /`total` \(BigDecimal\).*non-finite number/m)
        end
      end

      it "raises for a Rational too large for a double" do
        expect { described_class.serialize_value(Rational(10**400, 1), path: "total") }
          .to raise_error(Axn::Reflection::UnserializableValue, /`total` \(Rational\).*non-finite number/m)
      end

      it "still serializes finite Floats and coercible Numerics" do
        expect(described_class.serialize_value([0.0, -1.5, 1e308])).to eq([0.0, -1.5, 1e308])
        expect(described_class.serialize_value(BigDecimal("3.14"))).to eq(3.14)
      end

      # Complex has no Float form at all, so it renders as its string form ("1+2i") — an encodable
      # String, and a schema TYPE question rather than an encode failure (see schema_spec).
      it "leaves a Complex rendering as its string form" do
        expect(described_class.serialize_value(Complex(1, 2))).to eq("1+2i")
      end
    end

    describe "a String with no UTF-8 rendering" do
      it "raises for invalid UTF-8 bytes, naming the path" do
        expect { described_class.serialize_value("bad: \xFF".dup, path: "note") }
          .to raise_error(Axn::Reflection::UnserializableValue, /`note` \(String\).*no UTF-8 rendering.*String#scrub/m)
      end

      # valid_encoding? is NOT the predicate: these bytes are perfectly valid BINARY, and
      # JSON.generate still refuses them.
      it "raises for a BINARY String holding a high byte, which valid_encoding? calls valid" do
        value = binary("\xFF")
        expect(value.valid_encoding?).to be true

        expect { described_class.serialize_value(value, path: "blob") }
          .to raise_error(Axn::Reflection::UnserializableValue, /`blob` \(String\).*no UTF-8 rendering/m)
      end

      it "raises at both reject_opaque: settings" do
        [false, true].each do |reject_opaque|
          expect { described_class.serialize_value(binary("\xFF"), path: "blob", reject_opaque:) }
            .to raise_error(Axn::Reflection::UnserializableValue)
        end
      end

      it "names the nested path inside an Array, inside a Hash, and behind a custom to_h" do
        expect { described_class.serialize_value([binary("\xFF")], path: "rows") }
          .to raise_error(Axn::Reflection::UnserializableValue, /`rows\[0\]`/)

        expect { described_class.serialize_value({ rows: [{ note: binary("\xFF") }] }, path: "out") }
          .to raise_error(Axn::Reflection::UnserializableValue, /`out\.rows\[0\]\.note`/)

        wrapper = Class.new { def to_h = { note: "bad: \xFF".dup } }.new
        expect { described_class.serialize_value(wrapper, path: "doc") }
          .to raise_error(Axn::Reflection::UnserializableValue, /`doc\.note`/)
      end

      it "does not over-reject: a BINARY String that is pure ASCII still serializes" do
        expect(described_class.serialize_value(binary("abc"))).to eq("abc")
      end

      it "does not over-reject: ordinary UTF-8, multibyte included" do
        expect(described_class.serialize_value("héllo")).to eq("héllo")
        expect(described_class.serialize_value("party 🎉")).to eq("party 🎉")
      end

      # The question is whether the bytes have a UTF-8 RENDERING, not whether they are literally UTF-8:
      # a valid ISO-8859-1 or Shift_JIS String transcodes cleanly and encodes fine.
      it "does not over-reject a String valid in a non-UTF-8 encoding that transcodes cleanly" do
        expect { JSON.generate({ "k" => "h\xE9llo".dup.force_encoding(Encoding::ISO_8859_1) }) }.not_to raise_error

        expect(described_class.serialize_value("h\xE9llo".dup.force_encoding(Encoding::ISO_8859_1))).to eq("h\xE9llo".dup.force_encoding(Encoding::ISO_8859_1))
        expect(described_class.serialize_value("\x82\xA0".dup.force_encoding(Encoding::Shift_JIS))).to eq("\x82\xA0".dup.force_encoding(Encoding::Shift_JIS))
      end

      # A String SUBCLASS can override the predicates; String's own unbound methods are what answer, so a
      # value claiming valid UTF-8 over bytes that have none is still caught.
      it "is not fooled by a String subclass whose valid_encoding? lies" do
        liar = Class.new(String) do
          def valid_encoding? = true
          def encoding = Encoding::UTF_8
          def ascii_only? = true
        end.new("bad: \xFF".dup)

        expect { described_class.serialize_value(liar, path: "note") }
          .to raise_error(Axn::Reflection::UnserializableValue, /no UTF-8 rendering/)
      end

      it "raises for a Symbol whose bytes have no UTF-8 rendering, naming the Symbol" do
        expect { described_class.serialize_value(binary("\xFF").to_sym, path: "code") }
          .to raise_error(Axn::Reflection::UnserializableValue, /`code` \(Symbol\).*no UTF-8 rendering/m)
      end

      it "raises for a to_s fallback that returns bytes with no UTF-8 rendering, naming the value's class" do
        value = opaque_object
        def value.to_s = "bad: \xFF".dup

        expect { described_class.serialize_value(value, path: "label") }
          .to raise_error(Axn::Reflection::UnserializableValue, /`label`.*no UTF-8 rendering/m)
      end

      # A property name is a String in the output just as a leaf is, so the same bytes break it.
      it "raises for a Hash key whose String form has no UTF-8 rendering, naming the key position" do
        expect { described_class.serialize_value({ binary("\xFF") => 1 }, path: "rec") }
          .to raise_error(Axn::Reflection::UnserializableValue, /`rec \(hash key\)` \(String\).*property name/m)

        expect { described_class.serialize_value({ "bad: \xFF".dup => 1 }, path: "rec") }
          .to raise_error(Axn::Reflection::UnserializableValue, /`rec \(hash key\)` \(String\).*property name/m)

        expect { described_class.serialize_value({ binary("\xFF").to_sym => 1 }, path: "rec") }
          .to raise_error(Axn::Reflection::UnserializableValue, /`rec \(hash key\)` \(Symbol\).*property name/m)
      end
    end

    # The contract this whole family exists for: what serialize_value returns is something an encoder
    # accepts. Asserted over the representative shapes rather than described in a comment.
    it "returns JSON that JSON.generate accepts, for every value it serializes" do
      values = [
        nil, 1, 10**40, -2.5, 1e308, true, false, :sym, "plain", "héllo 🎉", binary("abc"),
        "h\xE9llo".dup.force_encoding(Encoding::ISO_8859_1), "\x82\xA0".dup.force_encoding(Encoding::Shift_JIS),
        BigDecimal("3.14"), Rational(1, 3), Complex(1, 2),
        Time.at(0).utc, Date.new(2026, 7, 3), DateTime.new(2026, 7, 3),
        { id: 1, nested: [1, "two", :three, { deep: BigDecimal("1.5") }] }, [[1], { a: { b: [2.5] } }],
        { 1 => "a", nil => "b", binary("ascii-key") => "c" }, opaque_object,
        Class.new { def to_h = { note: "héllo", ratio: 0.5 } }.new
      ]

      values.each do |value|
        serialized = described_class.serialize_value(value, path: "v")

        expect { JSON.generate({ "v" => serialized }) }
          .not_to raise_error, "JSON.generate refused the serialization of a #{value.class}"
      end
    end

    # An encoder ACCEPTING the output is only half the promise: a property name emitted twice is valid JSON
    # text that `JSON.parse` collapses to one entry, dropping a value with nothing in the output to say so.
    # Counting entries after a full round trip is what holds the other half — including for keys that are one
    # property name in two encodings, which are distinct Ruby Strings and so collide only on the wire.
    it "round-trips every Hash it renders through an encoder without losing an entry" do
      hashes = [
        { id: 1, "name" => "x", 2 => :b },
        # One property name in two encodings: distinct Ruby Strings, so a Hash really holds both — and a
        # single JSON property, so an encoder emits it twice and a parser keeps one.
        { "\xE9".dup.force_encoding(Encoding::ISO_8859_1) => "FIRST", "é" => "second" },
        { "é" => 1, "e" => 2, "\x82\xA0".dup.force_encoding(Encoding::Shift_JIS) => 3, binary("ascii-key") => 4 },
        { "h\xE9llo".dup.force_encoding(Encoding::ISO_8859_1) => 1, "héllo!" => 2 },
        { rows: [{ "a" => 1, "b" => nil }, { "a" => 2 }], "party 🎉" => "héllo", "" => nil },
      ]

      hashes.each do |hash|
        rendered = begin
          described_class.serialize_value(hash, path: "v")
        rescue Axn::Reflection::UnserializableValue
          # Refusing the Hash is the other way to keep the promise. What a caller must never be handed is
          # output that encodes cleanly and parses back holding fewer entries than it was given.
          next
        end
        parsed = JSON.parse(JSON.generate(rendered))

        expect(parsed.size).to eq(rendered.size), "an entry was dropped: #{rendered.size} properties rendered, #{parsed.size} survived"
        expect(parsed).to eq(rendered)
      end
    end
  end
end
