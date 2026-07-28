# frozen_string_literal: true

require "shellwords"
require "English"

require "spec_helper"
require "bigdecimal"

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

    it "threads reject_opaque: to the values it serializes" do
      owner = opaque_object
      klass = Class.new do
        include Axn
        auto_log false
        exposes :owner

        define_method(:call) { expose(owner:) }
      end
      result = klass.call

      expect(described_class.serialize_exposed(result, klass.external_field_configs)["owner"])
        .to match(/\A#<Object:0x[0-9a-f]+>\z/)
      expect { described_class.serialize_exposed(result, klass.external_field_configs, reject_opaque: true) }
        .to raise_error(Axn::Reflection::UnserializableValue, /`owner`/)
    end
  end

  # Stringifying a Hash's keys collapses two keys with the same #to_s into ONE JSON property, dropping
  # a value. Unlike an ugly rendering, the caller cannot tell from the output that anything went
  # missing — so this raises regardless of strictness.
  describe "colliding Hash keys" do
    it "raises rather than silently dropping a value" do
      expect { described_class.serialize_value({ id: 1, "id" => 2 }, path: "rec") }
        .to raise_error(
          Axn::Reflection::UnserializableValue,
          /`rec \(hash key "id"\)`.*two keys stringify to the same JSON property "id".*silently collapse and drop a value/m,
        )
    end

    it "names both original keys, so the caller can see which pair to fix" do
      expect { described_class.serialize_value({ id: 1, "id" => 2 }) }
        .to raise_error(Axn::Reflection::UnserializableValue, /\(:id and "id"\)/)
    end

    it "names the first colliding pair in insertion order when more than two keys collide" do
      third = Object.new.tap { |o| def o.to_s = "id" }

      expect { described_class.serialize_value({ "id" => 1, id: 2, third => 3 }) }
        .to raise_error(Axn::Reflection::UnserializableValue, /\("id" and :id\)/)
    end

    it "names the nested path of the offending Hash" do
      expect { described_class.serialize_value({ rows: [{ a: 1, "a" => 2 }] }, path: "out") }
        .to raise_error(Axn::Reflection::UnserializableValue, /`out\.rows\[0\] \(hash key "a"\)`/)
    end

    it "leaves a Hash whose keys stringify distinctly unchanged" do
      expect(described_class.serialize_value({ id: 1, "name" => "x", 2 => :b }))
        .to eq("id" => 1, "name" => "x", "2" => "b")
    end

    it "reports the collapse without naming a pair when the re-walk can't reproduce it" do
      # A key whose #to_s returns a different String on each call collides during rendering ("k1", which
      # the literal String key also produces) but groups distinctly on the error path's second walk. The
      # size comparison still proves a value was dropped, so the raise stands and says only what it knows.
      unstable = Object.new
      def unstable.to_s
        @calls = (@calls || 0) + 1
        "k#{@calls}"
      end

      expect { described_class.serialize_value({ unstable => 1, "k1" => 2 }, path: "rec") }
        .to raise_error(
          Axn::Reflection::UnserializableValue,
          /`rec` \(Hash\).*collapsed two of them into a single JSON property.*pair cannot be named/m,
        )
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

    it "renders the object address as a property name by default" do
      expect(described_class.serialize_value({ opaque_key => 1 }).keys.first)
        .to match(/\A#<Object:0x[0-9a-f]+>\z/)
    end

    it "raises under reject_opaque:, naming the offending key in the path" do
      expect { described_class.serialize_value({ opaque_key => 1 }, path: "data", reject_opaque: true) }
        .to raise_error(
          Axn::Reflection::UnserializableValue,
          /`data \(hash key #<Object:0x[0-9a-f]+>\)` \(Object\).*a Hash key is rendered via #to_s/m,
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
        .to raise_error(Axn::Reflection::UnserializableValue, /`out\.rows\[0\] \(hash key #<Object:0x/)
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
        "Cannot serialize exposed value at `items[1]` (Array): it is self-referential (a Array cycle), " \
        "which has no JSON representation. Expose a finite projection of it instead " \
        "(e.g. ids rather than the objects that point back).",
      )
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

      expect { described_class.serialize_exposed(klass.call, klass.external_field_configs) }
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
end
