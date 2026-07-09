# frozen_string_literal: true

require "spec_helper"

RSpec.describe Axn::Reflection::Schema do
  it "builds an input schema with required/optional and descriptions" do
    klass = Class.new do
      include Axn
      expects :name, type: String, description: "the name"
      expects :limit, type: Integer, default: 20, optional: true
    end
    schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
    expect(schema[:type]).to eq("object")
    expect(schema[:properties][:name]).to include(type: "string", description: "the name")
    # optional: true implies allow_blank: true, so per Bug N the type now allows null too.
    expect(schema[:properties][:limit]).to include(type: %w[integer null], default: 20)
    expect(schema[:required]).to eq(["name"])
  end

  it "builds an output schema" do
    klass = Class.new do
      include Axn
      exposes :active, type: :boolean
    end
    schema = described_class.build_output(klass.external_field_configs)
    expect(schema[:properties][:active]).to include(type: "boolean")
  end

  it "drops nil from an output enum too when the field is not nullable (build_output shares build_property)" do
    klass = Class.new do
      include Axn
      exposes :status, inclusion: { in: [nil, "open"] }
      def call = expose(status: "open")
    end
    schema = described_class.build_output(klass.external_field_configs)
    expect(schema[:properties][:status][:enum]).to eq(["open"])
  end

  it "keeps a defaulted exposure in output_schema[:required] (outbound defaults are always applied before validation/serialization)" do
    klass = Class.new do
      include Axn
      exposes :status, type: String, default: "ok"
      def call = nil
    end
    schema = described_class.build_output(klass.external_field_configs)
    expect(schema[:required]).to include("status")
  end

  # EVERY exposed field is always serialized — Values.serialize_exposed iterates every outbound config
  # and unconditionally emits its property key (value nil if unset). JSON Schema `required` means
  # property PRESENCE, not non-nullness, so every serialized key must be listed in
  # output_schema[:required]; nullability is expressed by the property type (which includes "null").
  describe "all exposed fields are required in output_schema (serialize_exposed always emits every key)" do
    it "marks a nullable (allow_nil) exposure as required, with its type carrying \"null\"" do
      klass = Class.new do
        include Axn
        exposes :a, type: String
        exposes :b, type: String, allow_nil: true
        def call = expose(a: "hi")
      end
      schema = described_class.build_output(klass.external_field_configs)

      expect(schema[:required]).to include("a", "b")
      expect(Array(schema[:properties][:b][:type])).to include("string", "null")
    end

    it "marks an optional: true exposure as required (serialize_exposed still emits the key)" do
      klass = Class.new do
        include Axn
        exposes :c, type: String, optional: true
        def call = nil
      end
      schema = described_class.build_output(klass.external_field_configs)
      expect(schema[:required]).to include("c")
    end

    it "runtime: serialize_exposed emits every exposed key, including an unset nullable one (nil)" do
      klass = Class.new do
        include Axn
        exposes :a, type: String
        exposes :b, type: String, allow_nil: true
        def call = expose(a: "hi")
      end
      serialized = Axn::Reflection::Values.serialize_exposed(klass.call, klass.external_field_configs)
      expect(serialized.keys).to contain_exactly("a", "b")
      expect(serialized["b"]).to be_nil
    end
  end

  it "still keeps a defaulted expectation OUT of input_schema[:required] (input defaults make the field client-omittable)" do
    klass = Class.new do
      include Axn
      expects :limit, type: Integer, default: 20
    end
    schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
    expect(schema[:required] || []).not_to include("limit")
  end

  # A TOP-LEVEL default relaxes input requiredness when it is USABLE — present, not a Proc, and not
  # empty (`{}`/`""`/`[]`). Requiredness is derived from declared signals only; the default's value is
  # not run through the field's validators, so a non-blank but type-invalid default still relaxes the
  # field (an accepted, narrow divergence from runtime, noted per-case below).
  describe "a top-level default relaxes input requiredness when it is usable (present, non-Proc, non-blank)" do
    it "requires a Hash field whose default is a blank {} (runtime: call({}) fails \"Payload can't be blank\")" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash, default: {}
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
      expect(schema[:required]).to include("payload")
    end

    it "requires a String field whose default is a blank \"\" (runtime: call({}) fails \"Name can't be blank\")" do
      klass = Class.new do
        include Axn
        expects :name, type: String, default: ""
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
      expect(schema[:required]).to include("name")
    end

    it "does NOT require an Integer field whose default is 0 (runtime: call({}) ok — 0 is not blank)" do
      klass = Class.new do
        include Axn
        expects :count, type: Integer, default: 0
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
      expect(schema[:required] || []).not_to include("count")
    end

    it "does NOT require a Hash field whose blank {} default is paired with allow_blank: true (runtime: call({}) ok)" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash, default: {}, allow_blank: true
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
      expect(schema[:required] || []).not_to include("payload")
    end

    it "does NOT require a params field whose blank {} default has no presence to reject it (runtime: call ok)" do
      klass = Class.new do
        include Axn
        expects :p, type: :params, default: {}
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
      expect(schema[:required] || []).not_to include("p")
    end

    it "does NOT require a presence: false field whose blank {} default is accepted at runtime" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash, presence: false, default: {}
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
      expect(schema[:required] || []).not_to include("payload")
    end

    it "does NOT require a String field whose non-blank default \"x\" satisfies the contract (runtime: call({}) ok)" do
      klass = Class.new do
        include Axn
        expects :name, type: String, default: "x"
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
      expect(schema[:required] || []).not_to include("name")
    end

    it "does NOT require a String field whose default is type-mismatched (123) — a non-blank default is usable" do
      # accepted divergence: runtime rejects the omitted call ("Name is not a String"); the schema
      # reflects optional because requiredness is derived from declared signals, not by validating the default.
      klass = Class.new do
        include Axn
        expects :name, type: String, default: 123
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
      expect(schema[:required] || []).not_to include("name")
    end

    it "does NOT require a :uuid field whose default is not a valid uuid — a non-blank default is usable" do
      # accepted divergence: runtime rejects the omitted call ("Id is not a uuid"); the schema reflects optional.
      klass = Class.new do
        include Axn
        expects :id, type: :uuid, default: "not-a-uuid"
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
      expect(schema[:required] || []).not_to include("id")
    end

    it "does NOT require a :uuid field whose default IS a valid uuid (runtime: call({}) ok)" do
      klass = Class.new do
        include Axn
        expects :id, type: :uuid, default: "550e8400-e29b-41d4-a716-446655440000"
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
      expect(schema[:required] || []).not_to include("id")
    end

    it "requires a Hash field with a Proc default (uninspectable — must not call it — so unprovable → conservative), " \
       "matching runtime here where call({}) fails \"Payload can't be blank\" for `-> { {} }`" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash, default: -> { {} }
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
      expect(schema[:required]).to include("payload")
    end

    it "does NOT require a String allow_nil field whose default is type-mismatched (123) — a non-blank default is usable" do
      # accepted divergence: runtime rejects the omitted call ("Name is not a String") because the
      # default is applied before validation; the schema reflects optional (usable default).
      klass = Class.new do
        include Axn
        expects :name, type: String, allow_nil: true, default: 123
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
      expect(schema[:required] || []).not_to include("name")
    end

    it "does NOT require a String allow_nil field whose default \"x\" satisfies the contract (runtime: call({}) ok)" do
      klass = Class.new do
        include Axn
        expects :name, type: String, allow_nil: true, default: "x"
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
      expect(schema[:required] || []).not_to include("name")
    end

    it "does NOT require a String allow_nil field with NO default (no usable default → nil-tolerance applies; runtime: call({}) ok)" do
      klass = Class.new do
        include Axn
        expects :name, type: String, allow_nil: true
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
      expect(schema[:required] || []).not_to include("name")
    end

    it "does NOT require a Hash allow_nil field whose blank {} default satisfies its contract (runtime: call({}) ok — " \
       "allow_nil suppresses the auto-presence, so {} passes; requiredness hinges on the default, not nil-tolerance)" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash, allow_nil: true, default: {}
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
      expect(schema[:required] || []).not_to include("payload")
    end

    it "does NOT require a boolean allow_nil field with a Proc default — allow_nil alone makes it nil-tolerant" do
      # The Proc default is not usable (never inspected), but allow_nil folds nil-tolerance into the
      # type validator, so the field is optional on that declared signal.
      klass = Class.new do
        include Axn
        expects :flag, type: :boolean, allow_nil: true, default: -> { false }
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
      expect(schema[:required] || []).not_to include("flag")
    end

    # OUTPUT-side regression: this change is INPUT-only. `exposes` requiredness deliberately ignores
    # defaults (build_output passes for_output: true, which short-circuits the satisfies-check), so a
    # blank/invalid-looking default must NOT flip an exposed field to optional — outbound defaults are
    # always applied before serialization, so a defaulted exposure stays required regardless.
    it "keeps a defaulted exposure required even when its default would NOT satisfy an input contract (output unaffected)" do
      klass = Class.new do
        include Axn
        exposes :payload, type: Hash, default: {}
        def call = nil
      end
      schema = described_class.build_output(klass.external_field_configs)
      expect(schema[:required]).to include("payload")
    end
  end

  it "excludes the ambient_context parent from the input schema" do
    # ambient_context becomes a valid `on:` parent in Phase F; here assert the exclusion constant.
    expect(described_class::EXCLUDED_FROM_INPUT_SCHEMA).to include(:ambient_context)
  end

  it "still emits an enum for a literal array inclusion source" do
    klass = Class.new do
      include Axn
      expects :status, type: String, inclusion: { in: %w[open closed] }
    end
    schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
    expect(schema[:properties][:status]).to include(type: "string", enum: %w[open closed])
  end

  it "does not raise and skips :enum for a dynamic (method-name) inclusion source" do
    klass = Class.new do
      include Axn
      expects :channel, type: String, inclusion: { in: :valid_channels }

      def valid_channels = %w[email sms]
    end

    schema = nil
    expect { schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs) }.not_to raise_error

    expect(schema[:properties][:channel]).to include(type: "string")
    expect(schema[:properties][:channel]).not_to have_key(:enum)
  end

  # Schema reflection NEVER executes user code, hits external services, or depends on an action
  # instance. Requiredness is derived from declared signals only — no validator (custom `validate:`
  # proc, `model:` DB lookup, dynamic Symbol/Proc inclusion set, `if:`/`unless:` guard, numericality
  # bound, …) is ever run. These specs assert that observable guarantee: nothing runs and building
  # never raises.
  describe "reflection is side-effect-free: no validators or user code run during schema building" do
    it "does NOT execute a custom validate: proc while building input_schema (even with a valid default)" do
      ran = false
      klass = Class.new do
        include Axn
        expects :x, validate: ->(_v) { ran = true }, default: "hi"
      end

      schema = nil
      expect { schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs) }.not_to raise_error
      expect(ran).to be(false)
      # The usable "hi" default makes the field optional; the custom validator is never consulted.
      expect(schema[:required] || []).not_to include("x")
    end

    it "does NOT execute a custom validate: proc while building output_schema" do
      ran = false
      klass = Class.new do
        include Axn
        exposes :x, validate: ->(_v) { ran = true }
        def call = expose(x: "hi")
      end

      expect { described_class.build_output(klass.external_field_configs) }.not_to raise_error
      expect(ran).to be(false)
    end

    it "does NOT execute a Proc inclusion set while building input_schema" do
      ran = false
      klass = Class.new do
        include Axn
        set_proc = lambda do |_r|
          ran = true
          %w[a b]
        end
        expects :y, inclusion: { in: set_proc }, default: "a"
      end

      schema = nil
      expect { schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs) }.not_to raise_error
      expect(ran).to be(false)
      # No enum is emitted for a dynamic (Proc) set; the usable "a" default makes the field optional.
      expect(schema[:properties][:y]).not_to have_key(:enum)
      expect(schema[:required] || []).not_to include("y")
    end

    it "does NOT invoke a dynamic (Symbol) inclusion method while building input_schema" do
      klass = Class.new do
        include Axn
        expects :z, inclusion: { in: :allowed }, default: "a"
        def allowed = raise("dynamic inclusion method must not run during reflection")
      end

      expect { described_class.build_input(klass.internal_field_configs, klass.subfield_configs) }.not_to raise_error
    end

    it "does NOT evaluate a Proc numericality bound while building input_schema" do
      ran = false
      klass = Class.new do
        include Axn
        bound_proc = lambda do |_r|
          ran = true
          0
        end
        expects :n, numericality: { greater_than: bound_proc }, default: 5
      end

      expect { described_class.build_input(klass.internal_field_configs, klass.subfield_configs) }.not_to raise_error
      expect(ran).to be(false)
    end

    it "treats a field with a usable default as optional without evaluating its validators" do
      # The usable "open" default makes the field client-omittable; the inclusion set is never checked.
      klass = Class.new do
        include Axn
        expects :s, type: String, inclusion: { in: %w[open closed] }, default: "open"
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
      expect(schema[:required] || []).not_to include("s")
    end

    it "does NOT execute a type: validator's if: Proc while building input_schema" do
      ran = false
      klass = Class.new do
        include Axn
        expects :token, type: { klass: String, if: ->(_r) { ran = true } }, default: "hi"
      end

      schema = nil
      expect { schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs) }.not_to raise_error
      expect(ran).to be(false)
      # The usable "hi" default makes the field optional; the if:-gated validator is never consulted.
      expect(schema[:required] || []).not_to include("token")
    end

    it "does NOT execute a type: validator's if: Proc while building output_schema" do
      ran = false
      klass = Class.new do
        include Axn
        exposes :token, type: { klass: String, if: ->(_r) { ran = true } }
        def call = expose(token: "hi")
      end

      expect { described_class.build_output(klass.external_field_configs) }.not_to raise_error
      expect(ran).to be(false)
    end

    it "does NOT execute an if: Proc on an otherwise-pure inclusion validator while building input_schema" do
      ran = false
      klass = Class.new do
        include Axn
        expects :status, inclusion: { in: %w[open closed], if: ->(_r) { ran = true } }, default: "open"
      end

      schema = nil
      expect { schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs) }.not_to raise_error
      expect(ran).to be(false)
      # The if:-gated inclusion is not evaluated; the usable "open" default makes the field optional.
      expect(schema[:required] || []).not_to include("status")
    end

    it "does NOT evaluate a Symbol numericality bound while building input_schema" do
      klass = Class.new do
        include Axn
        expects :n, numericality: { greater_than: :min }, default: 5
        def min = raise("dynamic numericality bound must not run during reflection")
      end

      expect { described_class.build_input(klass.internal_field_configs, klass.subfield_configs) }.not_to raise_error
    end

    it "keeps a boolean field with no default/nil-tolerance required (type: :boolean is not nil-tolerant)" do
      # No usable default and no nil-tolerant signal, so the field stays required — decided from the
      # declared type token alone, without running any validator.
      klass = Class.new do
        include Axn
        expects :enabled, type: :boolean
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
      expect(schema[:required]).to include("enabled")
      expect(schema[:properties][:enabled][:type]).to eq("boolean")
    end

    it "emits an enum for a static Symbol-array inclusion and treats a defaulted field as optional" do
      # The static enum is normalized to Strings, and the usable :a default makes the field optional.
      klass = Class.new do
        include Axn
        expects :mode, inclusion: { in: %i[a b] }, default: :a
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
      expect(schema[:properties][:mode][:enum]).to eq(%w[a b])
      expect(schema[:required] || []).not_to include("mode")
    end
  end

  it "does not leak a Proc default into the schema" do
    klass = Class.new do
      include Axn
      expects :limit, type: Integer, default: -> { 20 }
    end
    schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
    expect(schema[:properties][:limit]).not_to have_key(:default)
  end

  it "still emits a literal default" do
    klass = Class.new do
      include Axn
      expects :limit, type: Integer, default: 20, optional: true
    end
    schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
    expect(schema[:properties][:limit]).to include(default: 20)
  end

  it "does not mark a defaulted (non-optional) field as required, but still emits its default" do
    klass = Class.new do
      include Axn
      expects :name, type: String
      expects :limit, type: Integer, default: 20
    end
    schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
    expect(schema[:required]).to include("name")
    expect(schema[:required]).not_to include("limit")
    expect(schema[:properties][:limit]).to include(default: 20)
  end

  it "marks a typed-but-no-presence boolean field as required (TypeValidator rejects nil)" do
    klass = Class.new do
      include Axn
      expects :enabled, type: :boolean
    end
    schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
    expect(schema[:required]).to include("enabled")
  end

  it "marks a typed-but-no-presence params field as required (TypeValidator rejects nil)" do
    klass = Class.new do
      include Axn
      expects :payload, type: :params
    end
    schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
    expect(schema[:required]).to include("payload")
  end

  it "does not mark a boolean field with allow_nil: true as required" do
    klass = Class.new do
      include Axn
      expects :flag, type: :boolean, allow_nil: true
    end
    schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
    expect(schema[:required] || []).not_to include("flag")
  end

  it "marks a Proc-defaulted boolean field as required (the Proc is uninspectable in reflection — we must " \
     "not call it — so its value can't be proven to satisfy the contract; conservative/safe direction, matching " \
     "the file's subfield-parent Proc handling. NB runtime would actually ACCEPT the omitted call here since " \
     "`-> { false }` yields a valid boolean, but that's only knowable by evaluating the Proc)" do
    klass = Class.new do
      include Axn
      expects :flag, type: :boolean, default: -> { false }
    end
    schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
    expect(schema[:required]).to include("flag")
  end

  it "does not mark a LITERAL-false-defaulted boolean field as required (a literal default IS inspectable: " \
     "`false` is a valid boolean and non-blank, so it satisfies the contract; runtime accepts calling with {})" do
    klass = Class.new do
      include Axn
      expects :flag, type: :boolean, default: false
    end
    schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
    expect(schema[:required] || []).not_to include("flag")
  end

  it "does not mark an optional: true field with no other validator as required (empty validations)" do
    klass = Class.new do
      include Axn
      expects :coupon, optional: true
    end
    schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
    expect(schema[:required] || []).not_to include("coupon")
  end

  it "does not mark an allow_nil: true field with no other validator as required (empty validations)" do
    klass = Class.new do
      include Axn
      expects :note, allow_nil: true
    end
    schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
    expect(schema[:required] || []).not_to include("note")
  end

  it "still marks an untyped, unvalidated field as required by default" do
    klass = Class.new do
      include Axn
      expects :name, type: String
    end
    schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
    expect(schema[:required]).to include("name")
  end

  it "maps type: :params to an object" do
    klass = Class.new do
      include Axn
      expects :params, type: :params
    end
    schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
    expect(schema[:properties][:params]).to include(type: "object")
  end

  it "maps type: Symbol to a JSON string on input (TYPE_MAP entry, matches serialize_exposed rendering a Symbol as its string form)" do
    klass = Class.new do
      include Axn
      expects :status, type: Symbol
    end
    schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
    expect(schema[:properties][:status]).to include(type: "string")
  end

  it "maps type: Symbol to a JSON string on output, not the object fallback (serialize_exposed emits a string)" do
    klass = Class.new do
      include Axn
      exposes :status, type: Symbol
      def call = expose(status: :ok)
    end
    schema = described_class.build_output(klass.external_field_configs)
    expect(schema[:properties][:status]).to include(type: "string")
  end

  it "maps a Numeric subclass (BigDecimal) to a JSON number on output, not the object fallback" do
    require "bigdecimal"
    klass = Class.new do
      include Axn
      exposes :amount, type: BigDecimal
      def call = expose(amount: BigDecimal("3.14"))
    end
    schema = described_class.build_output(klass.external_field_configs)
    expect(schema[:properties][:amount]).to include(type: "number")
  end

  it "maps a Numeric subclass (Rational) to a JSON number on input" do
    klass = Class.new do
      include Axn
      expects :ratio, type: Rational
    end
    schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
    expect(schema[:properties][:ratio]).to include(type: "number")
  end

  it "does NOT map Complex (a non-Float-coercible Numeric) to a number on output — it serializes to a String" do
    # Values.serialize_value emits Complex#to_s (Float(Complex) raises), so a "number" type would
    # contradict serialize_exposed; leave it untyped on output and permissive-string on input.
    klass = Class.new do
      include Axn
      exposes :z, type: Complex
      expects :w, type: Complex
      def call = expose(z: Complex(1, 2))
    end
    out = described_class.build_output(klass.external_field_configs)
    inp = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
    expect(out[:properties][:z]).not_to have_key(:type)
    expect(inp[:properties][:w]).to include(type: "string")
    expect(Axn::Reflection::Values.serialize_value(Complex(1, 2))).to be_a(String)
  end

  it "leaves a type: Numeric output untyped (it admits a Complex value that serializes to a String)" do
    # `type: Numeric` accepts real numbers (serialize to JSON number) AND Complex (serializes to String),
    # so the output wire form isn't knowable from the declaration — untyped on output keeps the schema
    # from contradicting serialize_exposed. Input stays "number" (a JSON number is a real Numeric).
    klass = Class.new do
      include Axn
      exposes :z, type: Numeric
      expects :w, type: Numeric
      def call = expose(z: Complex(1, 2))
    end
    out = described_class.build_output(klass.external_field_configs)
    inp = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
    expect(out[:properties][:z]).not_to have_key(:type)
    expect(inp[:properties][:w]).to include(type: "number")

    serialized = Axn::Reflection::Values.serialize_exposed(klass.call(w: 1), klass.external_field_configs)
    expect(serialized["z"]).to be_a(String) # "1+2i" — would fail a { type: "number" } schema
  end

  it "requires a parent when a shallow subfield has a default but a sibling shallow subfield is required (the synthesized parent misses the sibling)" do
    partial = Class.new do
      include Axn
      expects :payload, type: Hash
      expects :a, on: :payload, type: String
      expects :b, on: :payload, type: Integer, default: 1
    end
    covered = Class.new do
      include Axn
      expects :payload, type: Hash
      expects :a, on: :payload, type: String, default: "x"
      expects :b, on: :payload, type: Integer, default: 1
    end
    expect(described_class.build_input(partial.internal_field_configs, partial.subfield_configs)[:required]).to include("payload")
    expect(Array(described_class.build_input(covered.internal_field_configs, covered.subfield_configs)[:required])).not_to include("payload")
  end

  it "keeps a non-object parent's declared type and omits its subfield shape (a type: Array parent is not rewritten to object)" do
    klass = Class.new do
      include Axn
      expects :items, type: Array
      expects :count, on: :items, type: Integer
    end
    schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
    expect(schema[:properties][:items][:type]).to eq("array")
    expect(schema[:properties][:items]).not_to have_key(:properties)
  end

  it "drops format: uuid for a blank-tolerant uuid field (allow_blank accepts \"\", which a strict uuid-format validator would reject)" do
    blank_ok = Class.new do
      include Axn
      expects :id, type: :uuid, allow_blank: true
    end
    strict = Class.new do
      include Axn
      expects :id, type: :uuid
    end
    expect(described_class.build_input(blank_ok.internal_field_configs)[:properties][:id]).not_to have_key(:format)
    expect(described_class.build_input(strict.internal_field_configs)[:properties][:id]).to include(format: "uuid")
  end

  it "drops format: uuid from a blank-tolerant uuid member inside an anyOf union, but keeps it when strict" do
    blank_ok = Class.new do
      include Axn
      expects :id, type: [:uuid, Integer], allow_blank: true
    end
    strict = Class.new do
      include Axn
      expects :id, type: [:uuid, Integer]
    end
    blank_members = described_class.build_input(blank_ok.internal_field_configs)[:properties][:id][:anyOf]
    strict_members = described_class.build_input(strict.internal_field_configs)[:properties][:id][:anyOf]
    expect(blank_members).to include({ type: "string" })
    expect(blank_members).not_to include(hash_including(format: "uuid"))
    expect(strict_members).to include({ type: "string", format: "uuid" })
  end

  it "leaves an unknown exposed class untyped in output_schema (its serialized shape isn't statically knowable)" do
    blob = Class.new do
      def self.name = "Blob"
      def to_s = "blob"
    end
    stub_const("Blob", blob)
    klass = Class.new do
      include Axn
      exposes :thing, type: Blob
      def call = expose(thing: Blob.new)
    end
    prop = described_class.build_output(klass.external_field_configs)[:properties][:thing]
    expect(prop).not_to have_key(:type)
  end

  it "nests subfields under a string on: parent" do
    klass = Class.new do
      include Axn
      expects :payload, type: Hash
      expects :name, on: "payload", type: String
    end
    schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

    payload = schema[:properties][:payload]
    expect(payload).not_to be_nil
    expect(payload[:properties]).to have_key(:name)
  end

  it "forces an untyped parent with declared subfields to be typed object, and still nests them" do
    klass = Class.new do
      include Axn
      expects :payload
      expects :name, on: :payload, type: String
    end
    schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

    payload = schema[:properties][:payload]
    expect(payload[:type]).to eq("object")
    expect(payload[:properties]).to have_key(:name)
  end

  it "nests subfields under the wire key when the parent field is aliased" do
    klass = Class.new do
      include Axn
      expects :channel, type: Hash, as: :raw_channel
      expects :name, on: :raw_channel, type: String
    end
    schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

    chan = schema[:properties][:channel]
    expect(chan).not_to be_nil
    expect(chan[:properties]).to have_key(:name)
    expect(chan[:required]).to include("name")
  end

  it "does not raise when a dynamic inclusion source drives type inference (no explicit type)" do
    # No `type:` — so json_type_for reaches the inclusion branch. A Symbol/Proc `in:` is a
    # runtime-resolved source, not a literal array, so it must be skipped rather than `.any?`'d.
    klass = Class.new do
      include Axn
      expects :channel, inclusion: { in: :valid_channels }
    end
    expect do
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
      expect(schema[:properties][:channel]).not_to have_key(:enum)
    end.not_to raise_error
  end

  describe "mixed-type inclusion enums (Bug AA)" do
    it "infers a single type for a same-typed string enum" do
      klass = Class.new do
        include Axn
        expects :v, inclusion: { in: %w[open closed] }
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
      expect(schema[:properties][:v]).to include(type: "string", enum: %w[open closed])
    end

    it "infers a single type for a same-typed integer enum" do
      klass = Class.new do
        include Axn
        expects :v, inclusion: { in: [1, 2] }
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
      expect(schema[:properties][:v]).to include(type: "integer", enum: [1, 2])
    end

    it "emits no :type for a mixed Integer/Float enum, letting :enum constrain" do
      klass = Class.new do
        include Axn
        expects :v, inclusion: { in: [1, 1.5] }
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
      expect(schema[:properties][:v]).not_to have_key(:type)
      expect(schema[:properties][:v]).to include(enum: [1, 1.5])
    end

    it "emits no :type for a mixed String/Integer enum, letting :enum constrain" do
      klass = Class.new do
        include Axn
        expects :v, inclusion: { in: ["open", 1] }
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
      expect(schema[:properties][:v]).not_to have_key(:type)
      expect(schema[:properties][:v]).to include(enum: ["open", 1])
    end

    it "is unaffected by an explicit type: (short-circuits before the inclusion branch)" do
      klass = Class.new do
        include Axn
        expects :v, type: String, inclusion: { in: %w[open closed] }
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
      expect(schema[:properties][:v]).to include(type: "string", enum: %w[open closed])
    end
  end

  describe "model: fields" do
    it "emits a nested <field>_id (not the field itself) for a nested model: subfield" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash
        expects :company, on: :payload, model: { klass: Struct.new(:id), finder: :find }
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      payload = schema[:properties][:payload]
      expect(payload[:properties]).to have_key(:company_id)
      expect(payload[:properties]).not_to have_key(:company)
      expect(payload[:properties][:company_id]).not_to have_key(:type)
    end

    it "preserves an explicitly-declared nested <field>_id subfield instead of clobbering it with the " \
       "model-generated one, and does not duplicate the parent's required (declaration order: explicit id " \
       "subfield before the model: subfield — the reverse order is rejected at declaration time with " \
       "'expects does not support duplicate sub-keys')" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash
        expects :company_id, on: :payload, type: :uuid
        expects :company, on: :payload, model: { klass: Struct.new(:id), finder: :find }
      end
      payload = described_class.build_input(klass.internal_field_configs,
                                            klass.subfield_configs)[:properties][:payload]

      # The explicit uuid type/format survives — NOT overwritten by the generic, unconstrained
      # model-id property that `expects :company, on: :payload, model:` would otherwise generate.
      expect(payload[:properties][:company_id]).to include(type: "string", format: "uuid")

      # The parent's `required` lists company_id exactly once, even though both the explicit
      # subfield and the model: subfield each independently contribute a required entry.
      expect(Array(payload[:required]).count("company_id")).to eq(1)
    end

    it "leaves the <field>_id type unconstrained for a custom finder" do
      klass = Class.new do
        include Axn
        expects :company, model: { klass: Struct.new(:id), finder: :find_by_token }
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:properties][:company_id]).not_to have_key(:type)
    end

    it "leaves the <field>_id type unconstrained for the default :find finder too (PK may be integer, UUID, or string)" do
      klass = Class.new do
        include Axn
        expects :user, model: { klass: Struct.new(:id), finder: :find }
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:properties][:user_id]).not_to have_key(:type)
      expect(schema[:properties][:user_id]).to include(description: a_string_matching(/ID of the/))
    end

    it "preserves an explicitly-declared <field>_id property instead of clobbering it with the model-generated one, and does not duplicate required" do
      klass = Class.new do
        include Axn
        expects :company_id, type: :uuid
        expects :company, model: { klass: Struct.new(:id), finder: :find }
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      # The explicit uuid type/format survives — NOT overwritten by the generic, unconstrained
      # model-id property that `expects :company, model:` would otherwise generate.
      expect(schema[:properties][:company_id]).to include(type: "string", format: "uuid")
      expect(schema[:properties][:company_id]).not_to have_key(:description)

      # `required` lists company_id exactly once, even though both the explicit field and the
      # model: field each independently contribute a required "company_id" entry.
      expect(schema[:required].count("company_id")).to eq(1)
    end

    it "de-duplicates required company_id regardless of declaration order (model: first, explicit id second)" do
      klass = Class.new do
        include Axn
        expects :company, model: { klass: Struct.new(:id), finder: :find }
        expects :company_id, type: :uuid
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required].count("company_id")).to eq(1)
      expect(schema[:properties][:company_id]).to include(type: "string", format: "uuid")
    end
  end

  describe "shape: members" do
    it "marks a typed-but-no-presence boolean shape member as required" do
      klass = Class.new do
        include Axn
        expects :cfg, type: Hash do
          field :enabled, type: :boolean
          field :label, type: String
        end
      end
      props = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)[:properties][:cfg]

      expect(props[:required]).to include("enabled")
      expect(props[:required]).to include("label")
    end

    it "types a class-shaped field as object, not the string fallback from json_type_for" do
      cfg_klass = Data.define(:name)
      klass = Class.new do
        include Axn
        expects :cfg, type: cfg_klass do
          field :name, type: String
        end
      end
      prop = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)[:properties][:cfg]

      expect(prop[:type]).to eq("object")
      expect(prop[:properties]).to have_key(:name)
    end

    it "does not advertise object OUTPUT for a shaped reader-only class (no to_h)" do
      # A reader-only object (ShapeValidator accepts it via respond_to?) has no to_h, so its serialized
      # wire form is unknowable from the declaration — a String (to_s) outside Rails, or an
      # instance-variable dump via Object#as_json inside Rails, neither reliably matching the shape's
      # reader-named members. Leave the OUTPUT untyped rather than promise an object serialize_exposed
      # may contradict; the INPUT schema still describes the object a client should send.
      reader_only = Class.new do
        def initialize(name) = (@name = name)
        attr_reader :name # reader only — no to_h
      end
      klass = Class.new do
        include Axn
        exposes(:cfg, type: reader_only) { field :name, type: String }
        expects(:inp, type: reader_only) { field :name, type: String }
        def call = nil
      end

      out = described_class.build_output(klass.external_field_configs)[:properties][:cfg]
      inp = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)[:properties][:inp]
      expect(out).not_to have_key(:type)
      expect(out).not_to have_key(:properties)
      expect(inp[:type]).to eq("object") # input still describes the object a client should send
    end

    it "still advertises object OUTPUT for a shaped Data field (Data defines to_h → member-keyed object)" do
      cfg_klass = Data.define(:name)
      klass = Class.new do
        include Axn
        exposes(:cfg, type: cfg_klass) { field :name, type: String }
        define_method(:call) { expose(:cfg, cfg_klass.new(name: "x")) }
      end

      out = described_class.build_output(klass.external_field_configs)[:properties][:cfg]
      expect(out[:type]).to eq("object")
      expect(out[:properties]).to have_key(:name)
      expect(Axn::Reflection::Values.serialize_exposed(klass.call, klass.external_field_configs)["cfg"]).to eq({ "name" => "x" })
    end

    it "does not advertise object OUTPUT for a shaped class with a custom to_h/as_json (statically unknowable)" do
      # Values.serialize_value follows a custom as_json before to_h, and either can emit a scalar/array or
      # a differently-keyed hash — so a custom value class isn't provably a member-keyed object. Only
      # Hash/:params/Data/Struct (language-guaranteed member-keyed) get an object OUTPUT schema.
      custom = Class.new do
        def initialize(name) = (@name = name)

        attr_reader :name

        def to_h = { name: @name }
        # own as_json wins over to_h in serialize_value
        def as_json(*) = "scalar-#{@name}"
      end
      klass = Class.new do
        include Axn
        exposes(:cfg, type: custom) { field :name, type: String }
        def call = nil
      end

      out = described_class.build_output(klass.external_field_configs)[:properties][:cfg]
      expect(out).not_to have_key(:type)
      expect(out).not_to have_key(:properties)
    end

    it "allows null alongside object for a nil-allowed class-shaped field" do
      cfg_klass = Data.define(:name)
      klass = Class.new do
        include Axn
        expects :cfg, type: cfg_klass, allow_nil: true do
          field :name, type: String
        end
      end
      prop = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)[:properties][:cfg]

      expect(prop[:type]).to eq(%w[object null])
    end

    it "still types an explicit Hash shape as object" do
      klass = Class.new do
        include Axn
        expects :cfg, type: Hash do
          field :name, type: String
        end
      end
      prop = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)[:properties][:cfg]

      expect(prop[:type]).to eq("object")
    end
  end

  describe "union type: [A, B]" do
    it "preserves all classes as anyOf, not just the first" do
      klass = Class.new do
        include Axn
        expects :val, type: [String, Integer]
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:properties][:val][:anyOf]).to eq([{ type: "string" }, { type: "integer" }])
      expect(schema[:properties][:val]).not_to have_key(:type)
    end

    it "still yields a plain type for a single-class type:" do
      klass = Class.new do
        include Axn
        expects :name, type: String
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:properties][:name]).to include(type: "string")
      expect(schema[:properties][:name]).not_to have_key(:anyOf)
    end
  end

  describe "allow_nil: true typed fields permit null in the schema" do
    it "adds \"null\" to a scalar type's emitted type array" do
      klass = Class.new do
        include Axn
        expects :age, type: Integer, allow_nil: true
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:properties][:age][:type]).to eq(%w[integer null])
      expect(schema[:required] || []).not_to include("age")
    end

    it "does not add null to a type with no allow_nil/allow_blank" do
      klass = Class.new do
        include Axn
        expects :name, type: String
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:properties][:name][:type]).to eq("string")
    end

    it "adds a null branch to a union type's anyOf" do
      klass = Class.new do
        include Axn
        expects :val, type: [String, Integer], allow_nil: true
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:properties][:val][:anyOf]).to include(type: "null")
    end

    it "still emits items: for a nil-allowed array (type: becomes [\"array\", \"null\"], not the bare string)" do
      klass = Class.new do
        include Axn
        expects :items, type: Array, of: String, allow_nil: true
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:properties][:items][:type]).to eq(%w[array null])
      expect(schema[:properties][:items][:items]).to eq(type: "string")
    end

    it "still emits items: for a non-nil array (unchanged baseline behavior)" do
      klass = Class.new do
        include Axn
        expects :items, type: Array, of: String
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:properties][:items][:type]).to eq("array")
      expect(schema[:properties][:items][:items]).to eq(type: "string")
    end

    it "includes null in the enum for a nil-allowed inclusion field" do
      klass = Class.new do
        include Axn
        expects :status, type: String, inclusion: { in: %w[open closed] }, allow_nil: true
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:properties][:status][:type]).to eq(%w[string null])
      expect(schema[:properties][:status][:enum]).to eq(["open", "closed", nil])
    end

    it "does not add null to the enum for a non-nil-allowed inclusion field" do
      klass = Class.new do
        include Axn
        expects :status, type: String, inclusion: { in: %w[open closed] }
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:properties][:status][:enum]).to eq(%w[open closed])
    end

    it "drops nil from the enum when the inclusion set contains it but the field is not nullable: " \
       "an explicit nil is actually REJECTED at runtime here (auto presence, no presence: false/allow_nil)" do
      klass = Class.new do
        include Axn
        expects :status, inclusion: { in: [nil, "open"] }
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
      config = klass.internal_field_configs.find { |c| c.field == :status }

      # Regression guard: nullable is already false for this config (auto presence rejects nil), so
      # the type union omits "null" independently of this fix — this test is only about the enum.
      expect(described_class.nil_allowed?(config)).to be(false)
      expect(schema[:properties][:status][:enum]).to eq(["open"])
      expect(Array(schema[:properties][:status][:type])).not_to include("null")
    end

    it "includes null exactly once in the enum when the inclusion set already contains nil and the field is nullable " \
       "(avoids a duplicate nil)" do
      klass = Class.new do
        include Axn
        expects :status, type: String, inclusion: { in: [nil, "open"] }, allow_nil: true
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:properties][:status][:enum].count(nil)).to eq(1)
      expect(schema[:properties][:status][:enum]).to include(nil, "open")
      expect(Array(schema[:properties][:status][:type])).to include("null")
    end

    it "still appends null exactly once when nullable via allow_nil: true and the inclusion set does not already contain it" do
      klass = Class.new do
        include Axn
        expects :status, type: String, inclusion: { in: %w[a b] }, allow_nil: true
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:properties][:status][:enum]).to eq(["a", "b", nil])
    end

    it "does not leak a mutation of the returned enum array back into the contract's inclusion validation (Bug CC)" do
      klass = Class.new do
        include Axn
        expects :status, type: String, inclusion: { in: %w[open closed] }
      end
      schema = klass.input_schema
      schema[:properties][:status][:enum] << "hacked"

      fresh_schema = klass.input_schema
      expect(fresh_schema[:properties][:status][:enum]).to eq(%w[open closed])
      expect(klass.internal_field_configs.find { |c| c.field == :status }.validations[:inclusion][:in]).to eq(%w[open closed])
    end

    it "does not leak a mutation of the returned Hash default back into the contract's stored default (Bug CC)" do
      klass = Class.new do
        include Axn
        expects :opts, type: Hash, default: { a: 1 }
      end
      schema = klass.input_schema
      schema[:properties][:opts][:default][:b] = 2

      fresh_schema = klass.input_schema
      expect(fresh_schema[:properties][:opts][:default]).to eq(a: 1)
    end

    it "still emits a scalar default unchanged (Bug CC regression guard)" do
      klass = Class.new do
        include Axn
        expects :limit, type: Integer, default: 20, optional: true
      end
      schema = klass.input_schema
      expect(schema[:properties][:limit][:default]).to eq(20)
    end

    it "does not leak a mutation of a returned String default back into the contract's stored default (Bug FF)" do
      klass = Class.new do
        include Axn
        expects :name, type: String, default: "abc"
      end
      schema = klass.input_schema
      schema[:properties][:name][:default].upcase!

      fresh_schema = klass.input_schema
      expect(fresh_schema[:properties][:name][:default]).to eq("abc")
      expect(klass.internal_field_configs.find { |c| c.field == :name }.default).to eq("abc")
    end

    it "does not leak a mutation of a nested value inside a returned Hash default (Bug FF)" do
      klass = Class.new do
        include Axn
        expects :opts, type: Hash, default: { a: { b: 1 } }
      end
      schema = klass.input_schema
      schema[:properties][:opts][:default][:a][:b] = 99

      fresh_schema = klass.input_schema
      expect(fresh_schema[:properties][:opts][:default]).to eq(a: { b: 1 })
    end

    it "does not leak a mutation of a returned enum element back into the contract's inclusion validation (Bug FF)" do
      klass = Class.new do
        include Axn
        expects :status, type: String, inclusion: { in: %w[open closed] }
      end
      schema = klass.input_schema
      schema[:properties][:status][:enum][0] << "X"

      fresh_schema = klass.input_schema
      expect(fresh_schema[:properties][:status][:enum]).to eq(%w[open closed])
      expect(klass.internal_field_configs.find { |c| c.field == :status }.validations[:inclusion][:in]).to eq(%w[open closed])
    end

    it "types a parent with subfields as plain object even when allow_nil: true (Bug X: a nil parent can't yield its subfields at runtime)" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash, allow_nil: true
        expects :name, on: :payload, type: String
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:properties][:payload][:type]).to eq("object")
      expect(schema[:properties][:payload][:properties]).to have_key(:name)
    end
  end

  describe "a parent field with subfields is never nullable, even when allow_nil/allow_blank (Bug X)" do
    it "types the parent as plain object (not [object, null]) when its only subfield is optional" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash, allow_nil: true
        expects :nick, on: :payload, type: String, optional: true
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:properties][:payload][:type]).to eq("object")
    end
  end

  describe "a parent field with subfields is required unless a default materializes it (Bug Y)" do
    it "does not require an optional (no-default) parent with an all-optional subfield" do
      # accepted divergence: omitting yields a nil parent, which raises at runtime; the schema reflects
      # the parent as optional because `optional: true` is a nil-tolerant declared signal.
      klass = Class.new do
        include Axn
        expects :payload, optional: true
        expects :name, on: :payload, optional: true, type: String
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required] || []).not_to include("payload")
    end

    it "still requires a parent whose only literal default is a blank {} — runtime rejects it via the " \
       "parent's own auto-presence (calling with {} raises \"Payload can't be blank\"), so the schema " \
       "must not advertise it as optional (requiredness now decided by Axn's real validators)" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash, default: {}
        expects :nick, on: :payload, optional: true, type: String
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required]).to include("payload")
    end

    it "does not require a parent whose non-blank default satisfies its own contract and all children are optional" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash, default: { seeded: true }
        expects :nick, on: :payload, optional: true, type: String
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required] || []).not_to include("payload")
    end

    it "still requires a defaulted parent that has a required subfield" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash, default: {}
        expects :name, on: :payload, type: String
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required]).to include("payload")
    end

    it "still requires a parent with no default at all (unchanged baseline)" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash
        expects :name, on: :payload, type: String
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required]).to include("payload")
    end

    it "does not require a parent whose literal Hash default already supplies the required subfield's key" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash, default: { name: "system" }
        expects :name, on: :payload, type: String
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required] || []).not_to include("payload")
    end

    it "still requires the parent when a Proc default can't be inspected for coverage, even if it would supply the key at runtime" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash, default: -> { { name: "x" } }
        expects :name, on: :payload, type: String
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required]).to include("payload")
    end

    it "does not require a parent whose usable (non-blank) Hash default covers only some of its required subfields" do
      # accepted divergence: runtime rejects the omitted call (role uncovered); the schema reflects the
      # parent as optional because its non-blank Hash default is a usable declared signal.
      klass = Class.new do
        include Axn
        expects :payload, type: Hash, default: { name: "system" }
        expects :name, on: :payload, type: String
        expects :role, on: :payload, type: String
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required] || []).not_to include("payload")
    end
  end

  # A usable (non-blank, non-Proc) parent default makes the parent omittable purely on that declared
  # signal — the default's contents are never validated against the subfield contract. Only a blank
  # (`{}`) or Proc default keeps the parent required. Cases where the default doesn't actually satisfy a
  # required child are accepted divergences (runtime rejects the omitted call; the schema reflects optional).
  describe "a usable (non-blank) parent default makes the parent omittable regardless of subfield coverage" do
    it "does not require the parent when the default's key is present but the value is nil" do
      # accepted divergence: runtime rejects the omitted call (name is nil); schema reflects optional.
      klass = Class.new do
        include Axn
        expects :payload, type: Hash, default: { name: nil }
        expects :name, on: :payload, type: String
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required] || []).not_to include("payload")
    end

    it "does not require the parent when the default's value is present but the wrong type for the required child" do
      # accepted divergence: runtime rejects the omitted call (name is not a String); schema reflects optional.
      klass = Class.new do
        include Axn
        expects :payload, type: Hash, default: { name: 123 }
        expects :name, on: :payload, type: String
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required] || []).not_to include("payload")
    end

    it "still requires the parent when the default omits the required child's key entirely" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash, default: {}
        expects :name, on: :payload, type: String
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required]).to include("payload")
    end

    it "does not require the parent when the default's value is blank and the child has an explicit presence: true" do
      # accepted divergence: runtime rejects the omitted call (blank child); the non-blank Hash default
      # is still a usable declared signal, so the schema reflects the parent as optional.
      klass = Class.new do
        include Axn
        expects :payload, type: Hash, default: { name: "" }
        expects :name, on: :payload, type: String, presence: true
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required] || []).not_to include("payload")
    end

    it "does not require the parent when the default's value is blank and the child has Axn's implicit presence" do
      # accepted divergence: runtime rejects the omitted call (blank child); schema reflects optional
      # (the Hash default { name: "" } is non-blank and usable).
      klass = Class.new do
        include Axn
        expects :payload, type: Hash, default: { name: "" }
        expects :name, on: :payload, type: String
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required] || []).not_to include("payload")
    end

    it "does not require the parent when its usable Hash default happens to satisfy a required child's inclusion set" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash, default: { name: "a" }
        expects :name, on: :payload, type: String, inclusion: { in: %w[a b] }
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required] || []).not_to include("payload")
    end

    it "does not require the parent when the required child's inclusion set does NOT contain the default value" do
      # accepted divergence: runtime rejects the omitted call ("z" not in the set); schema reflects optional.
      klass = Class.new do
        include Axn
        expects :payload, type: Hash, default: { name: "z" }
        expects :name, on: :payload, type: String, inclusion: { in: %w[a b] }
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required] || []).not_to include("payload")
    end

    it "does not require the parent when the required child's inclusion set is action-dependent (a symbol method)" do
      # accepted divergence: runtime resolves :allowed_names and may reject the omitted call; schema
      # reflects optional purely on the usable Hash default (the method is never invoked in reflection).
      klass = Class.new do
        include Axn
        expects :payload, type: Hash, default: { name: "a" }
        expects :name, on: :payload, type: String, inclusion: { in: :allowed_names }
        def allowed_names = %w[a b]
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required] || []).not_to include("payload")
    end

    it "does not require the parent when the default's value would actually satisfy the required child" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash, default: { name: "system" }
        expects :name, on: :payload, type: String
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required] || []).not_to include("payload")
    end

    it "does not require the parent when the required :uuid child's default value is a String that is NOT a valid uuid" do
      # accepted divergence: runtime rejects the omitted call (uuid regex fails); schema reflects optional.
      klass = Class.new do
        include Axn
        expects :payload, type: Hash, default: { token: "not-a-uuid" }
        expects :token, on: :payload, type: :uuid
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required] || []).not_to include("payload")
    end

    it "does not require the parent when the required :uuid child's default value IS a valid uuid (the default " \
       "actually satisfies the uuid type at runtime, so the parent may be omitted)" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash, default: { token: "550e8400-e29b-41d4-a716-446655440000" }
        expects :token, on: :payload, type: :uuid
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required] || []).not_to include("payload")
    end

    it "does not require the parent when the required String child's default value is whitespace-only" do
      # accepted divergence: runtime's presence validator rejects the blank child; the schema reflects
      # optional because the Hash default { name: "   " } is non-blank and usable.
      klass = Class.new do
        include Axn
        expects :payload, type: Hash, default: { name: "   " }
        expects :name, on: :payload, type: String
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required] || []).not_to include("payload")
    end

    it "does not require the parent when its usable Hash default supplies a boolean child (false is valid at runtime)" do
      # A bare type: :boolean subfield has no implicit presence, so false is valid at runtime; the
      # non-blank Hash default is a usable declared signal, so the parent is optional (runtime agrees here).
      klass = Class.new do
        include Axn
        expects :payload, type: Hash, default: { flag: false }
        expects :flag, on: :payload, type: :boolean
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required] || []).not_to include("payload")
    end
  end

  # A truthy shallow-subfield default only materializes an OBJECT-shaped parent: runtime synthesizes a
  # missing parent as `{}` (apply_defaults_for_subfields!), which satisfies a Hash/`:params`/untyped
  # parent's own type but not a non-object one. A NON-Hash-typed parent's top-level type validator
  # rejects the synthesized `{}`, so omitting it still fails at runtime and it stays required.
  describe "a truthy shallow-subfield default materializes only an object-shaped parent" do
    some_data = Data.define(:name)

    it "keeps a NON-Hash-typed parent required even when a subfield default would supply a value" do
      # runtime rejects the omitted call (the synthesized `{}` is not a SomeData), so the schema must
      # match by keeping the parent required rather than advertising it as omittable.
      klass = Class.new do
        include Axn
        expects :payload, type: some_data
        expects :name, on: :payload, type: String, default: "x"
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required] || []).to include("payload")
    end

    it "keeps a type: Array parent required even when every shallow subfield has a default" do
      klass = Class.new do
        include Axn
        expects :items, type: Array
        expects :count, on: :items, type: Integer, default: 5
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required] || []).to include("items")
    end

    it "does NOT require the Hash-typed analog (the synthesized Hash satisfies a Hash parent, so it may be omitted)" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash
        expects :name, on: :payload, type: String, default: "x"
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required] || []).not_to include("payload")
    end
  end

  # A parent can carry a NON-Hash default that satisfies its own contract while its
  # subfields are read via object readers (e.g. `type: SomeData, default: SomeData.new(...)` +
  # `on: :payload`). Runtime validates the omitted parent by reading `payload.name` off the object, so
  # the synthesized value passed to the shallow-child satisfy-check must NOT be coerced with
  # with_indifferent_access (which raises NoMethodError on a Data/object). Schema generation must not
  # crash, and requiredness must match runtime (payload omittable — its default supplies name).
  describe "an object-backed (non-Hash) subfield parent default does not crash schema generation" do
    payload_data = Data.define(:name)

    it "builds input_schema without raising and leaves the object-defaulted parent omittable" do
      default_payload = payload_data.new(name: "x")
      klass = Class.new do
        include Axn
        expects :payload, type: payload_data, default: default_payload
        expects :name, on: :payload, type: String
      end

      schema = nil
      expect { schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs) }.not_to raise_error
      # Runtime `call({})` succeeds (default object supplies payload; name extracted via reader), so the
      # parent must NOT be required — matching the Hash-parent analog.
      expect(schema[:required] || []).not_to include("payload")
    end

    it "matches runtime: omitting the object-defaulted parent validates and extracts the subfield" do
      default_payload = payload_data.new(name: "x")
      klass = Class.new do
        include Axn
        expects :payload, type: payload_data, default: default_payload
        expects :name, on: :payload, type: String
        exposes :extracted_name
        def call = expose(:extracted_name, name)
      end

      result = klass.call
      expect(result).to be_ok
      expect(result.extracted_name).to eq("x")
    end
  end

  describe "a single validator's allow_nil: does not make the whole field nullable/optional (Bug T)" do
    it "does not treat a field as nullable/optional when only one of several validators allows nil" do
      klass = Class.new do
        include Axn
        expects :age, type: Integer, numericality: { greater_than: 0, allow_nil: true }
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required]).to include("age")
      expect(schema[:properties][:age][:type]).to eq("integer")
    end

    it "still treats a top-level allow_nil: true as nullable/optional (pushed into every validator)" do
      klass = Class.new do
        include Axn
        expects :x, type: Integer, allow_nil: true
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required] || []).not_to include("x")
      expect(schema[:properties][:x][:type]).to eq(%w[integer null])
    end

    it "still treats optional: true (no validations) as optional" do
      klass = Class.new do
        include Axn
        expects :coupon, optional: true
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required] || []).not_to include("coupon")
    end

    it "still requires a plain typed field with no allow_nil anywhere" do
      klass = Class.new do
        include Axn
        expects :name, type: String
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required]).to include("name")
      expect(schema[:properties][:name][:type]).to eq("string")
    end

    it "still requires a typed-but-no-presence boolean field" do
      klass = Class.new do
        include Axn
        expects :flag, type: :boolean
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required]).to include("flag")
    end
  end

  describe "a dotted subfield NAME denotes a deep extraction path and is omitted from the schema" do
    it "omits a dotted-name subfield's flat property from the parent (deep extraction, not single-level nesting)" do
      klass = Class.new do
        include Axn
        expects :foo, type: Hash
        expects "bar.baz", on: :foo
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      foo = schema[:properties][:foo]
      # The only subfield on :foo is the dotted-name one, so once it's filtered out there are no
      # nested subfields left at all — apply_nested_subfields! never materializes :properties/:required.
      expect(foo[:properties] || {}).not_to have_key("bar.baz")
      expect(foo[:properties] || {}).not_to have_key(:"bar.baz")
      expect(Array(foo[:required])).not_to include("bar.baz")
    end

    it "still nests a normal single-level subfield under its parent (regression guard)" do
      klass = Class.new do
        include Axn
        expects :foo, type: Hash
        expects :bar, on: :foo, type: String
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      foo = schema[:properties][:foo]
      expect(foo[:properties][:bar]).to include(type: "string")
    end

    it "keeps a normal sibling subfield while omitting a dotted-name subfield on the same parent" do
      klass = Class.new do
        include Axn
        expects :foo, type: Hash
        expects :bar, on: :foo, type: String
        expects "deep.path", on: :foo
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      foo = schema[:properties][:foo]
      expect(foo[:properties].keys).to eq([:bar])
      expect(foo[:properties]).not_to have_key("deep.path")
      expect(foo[:properties]).not_to have_key(:"deep.path")
    end

    it "leaves an optional (no-default) parent whose only subfield is a dotted name optional, matching its shallow analog" do
      shallow = Class.new do
        include Axn
        expects :foo, optional: true
        expects :bar, on: :foo, type: String, optional: true
      end
      dotted = Class.new do
        include Axn
        expects :foo, optional: true
        expects "bar.baz", on: :foo, type: String, optional: true
      end

      shallow_schema = described_class.build_input(shallow.internal_field_configs, shallow.subfield_configs)
      dotted_schema = described_class.build_input(dotted.internal_field_configs, dotted.subfield_configs)

      # accepted divergence: runtime rejects both omitted calls (a nil parent can't yield the child);
      # the schema reflects both as optional because `optional: true` is a nil-tolerant declared signal.
      # Parity is the criterion: a dotted-only subfield reflects identically to the shallow case.
      expect(shallow_schema[:required] || []).not_to include("foo")
      expect(dotted_schema[:required] || []).not_to include("foo")

      # The dotted subfield's own SHAPE is still omitted.
      expect(dotted_schema[:properties][:foo][:properties] || {}).not_to have_key("bar.baz")
    end

    it "still requires a parent with only an optional dotted child when its literal default is a blank {} " \
       "(runtime rejects the omitted call via the parent's auto-presence: \"Foo can't be blank\")" do
      klass = Class.new do
        include Axn
        expects :foo, type: Hash, default: {}
        expects "bar.baz", on: :foo, type: String, optional: true
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required]).to include("foo")
    end

    it "does not require a parent with only an optional dotted child when its non-blank default satisfies its own contract" do
      klass = Class.new do
        include Axn
        expects :foo, type: Hash, default: { seeded: true }
        expects "bar.baz", on: :foo, type: String, optional: true
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required] || []).not_to include("foo")
    end

    it "still requires the parent when its only child is a REQUIRED dotted subfield (deep required key not provably covered)" do
      klass = Class.new do
        include Axn
        expects :foo, type: Hash, default: {}
        expects "bar.baz", on: :foo, type: String
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required]).to include("foo")
    end
  end

  describe "a dotted `on:` PARENT or an `on:` pointing at another subfield contributes no shape and does " \
           "not force its top-level root required" do
    it "requires an allow_nil parent with a required SHALLOW child but not the dotted-deep analog it can't prove" do
      shallow = Class.new do
        include Axn
        expects :address, allow_nil: true
        expects :zip, on: :address
      end
      dotted = Class.new do
        include Axn
        expects :address, allow_nil: true
        expects :zip, on: "address.billing"
      end

      shallow_schema = described_class.build_input(shallow.internal_field_configs, shallow.subfield_configs)
      dotted_schema = described_class.build_input(dotted.internal_field_configs, dotted.subfield_configs)

      # A required SHALLOW child strands an omitted parent at runtime, so the nil-tolerant parent stays
      # required despite allow_nil. The dotted-deep child is not a shallow subfield of :address, so the
      # schema can't prove requiredness through it and keeps the parent optional (documented limitation:
      # deep required leaves don't force the root required).
      expect(shallow_schema[:required] || []).to include("address")
      expect(dotted_schema[:required] || []).not_to include("address")

      # The dotted parent's deep shape is not represented.
      address_props = dotted_schema[:properties][:address][:properties] || {}
      expect(address_props).not_to have_key("address.billing")
      expect(address_props).not_to have_key(:billing)
      expect(address_props).not_to have_key(:zip)
    end

    it "leaves the top-level root optional when only a DEEP leaf (subfield-of-a-subfield) is required" do
      # accepted divergence: runtime needs the omitted root, but the schema reflects it as optional
      # because `optional: true` is a nil-tolerant signal and the only required key (:leaf) is a deep
      # descendant the schema can't prove — the shallow child :mid is itself optional, so it doesn't
      # force the root required.
      klass = Class.new do
        include Axn
        expects :foo, optional: true
        expects :mid, on: :foo, optional: true
        expects :leaf, on: :mid
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required] || []).not_to include("foo")
      # :mid still nests directly under :foo (it's a shallow child of :foo); :leaf's shape (a deep
      # descendant rooted through :mid) is omitted.
      expect(schema[:properties][:foo][:properties]).to have_key(:mid)
      expect(schema[:properties][:foo][:properties]).not_to have_key(:leaf)
    end

    it "requires a nil-tolerant root when its shallow child is required, even alongside a deep chain" do
      # The shallow child :mid is required, so an omitted :foo strands it at runtime — the parent is
      # required regardless of the deeper :leaf the schema can't represent.
      klass = Class.new do
        include Axn
        expects :foo, optional: true
        expects :mid, on: :foo
        expects :leaf, on: :mid
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required] || []).to include("foo")
    end

    it "still requires a defaulted top-level root whose only descendant is an optional dotted-parent subfield " \
       "when its default is a blank {} (runtime rejects the omitted call: \"Address can't be blank\")" do
      klass = Class.new do
        include Axn
        expects :address, type: Hash, default: {}
        expects :zip, on: "address.billing", optional: true, type: String
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required]).to include("address")
    end

    it "does not require a defaulted top-level root whose only descendant is an optional dotted-parent " \
       "subfield when its non-blank default satisfies its own contract" do
      klass = Class.new do
        include Axn
        expects :address, type: Hash, default: { seeded: true }
        expects :zip, on: "address.billing", optional: true, type: String
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required] || []).not_to include("address")
    end
  end

  describe "a bare/active validator rejects nil even alongside a disabled presence (Bug KK)" do
    it "still requires amount and does not null its type: a bare numericality validator rejects nil regardless of presence: false" do
      klass = Class.new do
        include Axn
        expects :amount, numericality: true, presence: false
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required]).to include("amount")
      expect(schema[:properties][:amount][:type]).to eq("number") # inferred from numericality, not nulled
    end

    it "does not require x when presence: false is disabled and nothing else rejects nil" do
      klass = Class.new do
        include Axn
        expects :x, presence: false
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required] || []).not_to include("x")
    end

    it "still requires name (untyped presence baseline, regression guard)" do
      klass = Class.new do
        include Axn
        expects :name, type: String
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required]).to include("name")
    end

    it "still requires a typed-but-no-presence boolean field (regression guard)" do
      klass = Class.new do
        include Axn
        expects :flag, type: :boolean
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required]).to include("flag")
    end

    it "does not mark an allow_nil: true typed field as required, and still nulls its type (regression guard)" do
      klass = Class.new do
        include Axn
        expects :age, type: Integer, allow_nil: true
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required] || []).not_to include("age")
      expect(schema[:properties][:age][:type]).to eq(%w[integer null])
    end

    it "does not mark an optional: true field with no other validator as required (regression guard)" do
      klass = Class.new do
        include Axn
        expects :coupon, optional: true
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required] || []).not_to include("coupon")
    end

    it "still requires age when numericality has allow_nil: true but presence is added by default (regression guard)" do
      klass = Class.new do
        include Axn
        expects :age, type: Integer, numericality: { greater_than: 0, allow_nil: true }
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required]).to include("age")
    end
  end

  describe "nil-tolerant validators (absence/acceptance) do not make a field required (Bug LL)" do
    it "does not require a field validated with absence: true alongside presence: false" do
      klass = Class.new do
        include Axn
        expects :archived_at, presence: false, absence: true
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required] || []).not_to include("archived_at")
    end

    it "does not require a field validated with acceptance: true alongside presence: false" do
      # NOTE: acceptance: true alone is still required, because Axn auto-adds `presence: true`
      # to any field without an explicit `presence:` key (contract.rb `_parse_field_validations`)
      # — verified at runtime: `expects :flag, acceptance: true` alone rejects a nil/blank value
      # with "Flag can't be blank". Nil-tolerance for acceptance only surfaces once presence is
      # explicitly disabled, same as the absence: true case above.
      klass = Class.new do
        include Axn
        expects :flag, presence: false, acceptance: true
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required] || []).not_to include("flag")
    end

    it "still requires amount when a bare non-nil-tolerant validator is active alongside presence: false (regression guard)" do
      klass = Class.new do
        include Axn
        expects :amount, numericality: true, presence: false
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required]).to include("amount")
    end

    it "still requires a plain typed field with no allow_nil anywhere (regression guard)" do
      klass = Class.new do
        include Axn
        expects :name, type: String
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required]).to include("name")
    end

    it "still requires a typed-but-no-presence boolean field (regression guard)" do
      klass = Class.new do
        include Axn
        expects :flag2, type: :boolean
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required]).to include("flag2")
    end

    it "does not mark an allow_nil: true typed field as required (regression guard)" do
      klass = Class.new do
        include Axn
        expects :age, type: Integer, allow_nil: true
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required] || []).not_to include("age")
    end

    it "does not mark an optional: true field as required (regression guard)" do
      klass = Class.new do
        include Axn
        expects :coupon, optional: true
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required] || []).not_to include("coupon")
    end
  end

  describe "a parent with a required subfield must itself be required (Bug V)" do
    it "marks a defaulted/optional-looking parent as required when it has a required subfield" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash, default: {}
        expects :name, on: :payload, type: String
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required]).to include("payload")
      expect(schema[:properties][:payload][:required]).to include("name")
    end

    it "does not mark a defaulted parent as required when its only subfield is optional AND its default satisfies " \
       "its own contract (a blank {} default would still be rejected by the parent's auto-presence at runtime)" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash, default: { seeded: true }
        expects :nick, on: :payload, type: String, optional: true
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required] || []).not_to include("payload")
    end

    it "still marks a plain required parent (with a subfield) as required exactly once" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash
        expects :name, on: :payload, type: String
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required].count("payload")).to eq(1)
    end
  end

  describe "falsey subfield defaults are not optional-making in the schema (Bug Z2)" do
    it "still requires a nested subfield whose default is falsey (runtime only applies truthy subfield defaults)" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash
        expects :flag, on: :payload, type: :boolean, default: false
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:properties][:payload][:required]).to include("flag")
    end

    it "does not require a nested subfield whose default is truthy" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash
        expects :flag2, on: :payload, type: :boolean, default: true
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:properties][:payload][:required] || []).not_to include("flag2")
    end
  end

  describe "a falsey subfield default is not emitted in the schema (Bug HH)" do
    it "does not emit default: false for a subfield with a falsey default (runtime never applies it)" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash
        expects :flag, on: :payload, type: :boolean, default: false
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:properties][:payload][:properties][:flag]).not_to have_key(:default)
    end

    it "still emits default: for a subfield with a truthy default" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash
        expects :name, on: :payload, type: String, default: "anon"
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:properties][:payload][:properties][:name]).to include(default: "anon")
    end

    it "still emits default: false for a TOP-LEVEL field (unaffected by subfield gating)" do
      klass = Class.new do
        include Axn
        expects :flag, type: :boolean, default: false
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:properties][:flag]).to include(default: false)
    end
  end

  describe "a subfield's truthy default materializes the parent, making it omittable (Bug Z3)" do
    it "does not require the parent when a subfield default materializes it and no child is required" do
      klass = Class.new do
        include Axn
        expects :payload
        expects :name, on: :payload, default: "anon"
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required] || []).not_to include("payload")
    end

    it "still requires the parent when the subfield has no default at all" do
      klass = Class.new do
        include Axn
        expects :payload
        expects :name, on: :payload, type: String
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required]).to include("payload")
    end

    it "still requires the parent when the only subfield default is falsey (not applied at runtime)" do
      klass = Class.new do
        include Axn
        expects :payload
        expects :flag, on: :payload, type: :boolean, default: false
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required]).to include("payload")
    end
  end

  describe "presence alone does not infer type: string (Bug U)" do
    it "leaves a presence-only field untyped (accepts any JSON value) but still required" do
      klass = Class.new do
        include Axn
        expects :payload
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:properties][:payload]).not_to have_key(:type)
      expect(schema[:required]).to include("payload")
    end

    it "still infers type: string for an explicitly typed String field" do
      klass = Class.new do
        include Axn
        expects :name, type: String
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:properties][:name]).to include(type: "string")
    end

    it "leaves a length:-only field untyped, since length applies to arrays too, not just strings (Bug NN)" do
      klass = Class.new do
        include Axn
        expects :items, length: { minimum: 1 }
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:properties][:items]).not_to have_key(:type)
    end

    it "still infers type: string for an explicitly typed String field with a length: validation (regression guard)" do
      klass = Class.new do
        include Axn
        expects :name, type: String, length: { minimum: 2 }
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:properties][:name]).to include(type: "string")
    end
  end

  describe "acceptance: allow_nil: false rejects nil, unlike default acceptance (Bug OO)" do
    it "requires a field validated with acceptance: { allow_nil: false } alongside presence: false" do
      klass = Class.new do
        include Axn
        expects :flag, presence: false, acceptance: { allow_nil: false }
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required]).to include("flag")
    end

    it "does not require a field validated with acceptance: true alongside presence: false (default acceptance allows nil)" do
      klass = Class.new do
        include Axn
        expects :flag2, presence: false, acceptance: true
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required] || []).not_to include("flag2")
    end

    it "does not require a field validated with absence: true alongside presence: false (unchanged)" do
      klass = Class.new do
        include Axn
        expects :archived_at, presence: false, absence: true
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required] || []).not_to include("archived_at")
    end
  end

  describe "nil-tolerant inclusion/exclusion validators" do
    it "does not require a field whose exclusion set does not contain nil (nil is not excluded, so it passes)" do
      klass = Class.new do
        include Axn
        expects :role, presence: false, exclusion: { in: %w[admin] }
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required] || []).not_to include("role")
    end

    it "still requires a field whose inclusion set does not explicitly contain nil (nil is rejected)" do
      klass = Class.new do
        include Axn
        expects :role, inclusion: { in: %w[a b] }
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required]).to include("role")
    end

    it "does not require a field whose inclusion set explicitly contains nil as a member" do
      klass = Class.new do
        include Axn
        expects :role, presence: false, inclusion: { in: [nil, "a"] }
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required] || []).not_to include("role")
    end

    it "still requires a field with a dynamic (Proc) exclusion set, since nil-membership can't be determined (stays conservative)" do
      klass = Class.new do
        include Axn
        expects :role, presence: false, exclusion: { in: -> { %w[admin] } }
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required]).to include("role")
    end

    it "still requires a field when a bare non-nil-tolerant validator is active alongside a nil-tolerant exclusion (all validators must tolerate nil)" do
      klass = Class.new do
        include Axn
        expects :role, presence: false, exclusion: { in: %w[admin] }, numericality: true
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required]).to include("role")
    end
  end

  describe "normalizing default:/enum literals to their JSON wire form" do
    it "normalizes a Symbol default to its String form, matching the String type" do
      klass = Class.new do
        include Axn
        expects :x, type: Symbol, default: :draft
      end
      schema = klass.input_schema

      expect(schema[:properties][:x]).to include(type: "string", default: "draft")
    end

    it "normalizes Symbol inclusion enum members to Strings, not raw symbols" do
      klass = Class.new do
        include Axn
        expects :x, inclusion: { in: %i[draft open] }
      end
      schema = klass.input_schema

      expect(schema[:properties][:x][:enum]).to eq(%w[draft open])
    end

    it "normalizes a Time default to its iso8601 String form, matching format: date-time" do
      klass = Class.new do
        include Axn
        expects :x, type: Time, default: Time.utc(2026, 1, 2, 3, 4, 5)
      end
      schema = klass.input_schema

      expect(schema[:properties][:x]).to include(format: "date-time")
      expect(schema[:properties][:x][:default]).to eq(Time.utc(2026, 1, 2, 3, 4, 5).iso8601)
    end

    it "normalizes a non-Integer/Float Numeric (BigDecimal) default to a JSON number (Float)" do
      require "bigdecimal"
      klass = Class.new do
        include Axn
        expects :x, type: Numeric, default: BigDecimal("3.14")
      end
      schema = klass.input_schema

      expect(schema[:properties][:x][:default]).to be_a(Float).and eq(3.14)
    end

    it "still deep-copies a String/Hash/Array default (mutation-safety regression guard)" do
      klass = Class.new do
        include Axn
        expects :name, type: String, default: "abc"
        expects :opts, type: Hash, default: { a: 1 }
      end
      schema = klass.input_schema
      schema[:properties][:name][:default].upcase!
      schema[:properties][:opts][:default][:b] = 2

      fresh_schema = klass.input_schema
      expect(fresh_schema[:properties][:name][:default]).to eq("abc")
      expect(fresh_schema[:properties][:opts][:default]).to eq(a: 1)
    end
  end

  describe "allow_blank inclusion fields add nil (not the empty string) to their enum" do
    it "runtime: allow_blank accepts blank AND nil, rejects a non-member string" do
      klass = Class.new do
        include Axn
        expects :status, inclusion: { in: ["open"] }, allow_blank: true
      end

      expect(klass.call(status: "")).to be_ok
      expect(klass.call(status: nil)).to be_ok
      expect(klass.call(status: "x")).not_to be_ok
    end

    it "adds nil (but not \"\") to the enum for an allow_blank inclusion field" do
      # accepted divergence: runtime accepts "" for an allow_blank field; the schema's enum lists only
      # the declared member plus nil (the empty-string member is not synthesized).
      klass = Class.new do
        include Axn
        expects :status, inclusion: { in: ["open"] }, allow_blank: true
      end
      schema = klass.input_schema

      expect(schema[:properties][:status][:enum]).to match_array(["open", nil])
    end

    it "runtime: allow_nil (not allow_blank) rejects blank but accepts nil" do
      klass = Class.new do
        include Axn
        expects :status, inclusion: { in: ["open"] }, allow_nil: true
      end

      expect(klass.call(status: "")).not_to be_ok
      expect(klass.call(status: nil)).to be_ok
      expect(klass.call(status: "x")).not_to be_ok
    end

    it "does not add \"\" to the enum for an allow_nil (not allow_blank) inclusion field, mirroring runtime" do
      klass = Class.new do
        include Axn
        expects :status, inclusion: { in: ["open"] }, allow_nil: true
      end
      schema = klass.input_schema

      expect(schema[:properties][:status][:enum]).to eq(["open", nil])
    end

    it "does not add \"\" to the enum when neither allow_blank nor allow_nil is set (Bug #59, unchanged)" do
      klass = Class.new do
        include Axn
        expects :status, inclusion: { in: ["open"] }
      end
      schema = klass.input_schema

      expect(schema[:properties][:status][:enum]).to eq(["open"])
    end
  end

  # A blank-tolerant (allow_blank) inclusion field accepts "" at runtime even when its declared members
  # are NON-string, but the schema does not synthesize an empty-string member: enum_for_inclusion only
  # adds nil for a nullable field, and the advertised type is not widened to permit "".
  describe "a blank-tolerant inclusion field with NON-string members adds nil (not \"\") and does not widen its type" do
    it "runtime: a numeric allow_blank inclusion accepts \"\" and nil, rejects a non-member number" do
      klass = Class.new do
        include Axn
        expects :status, inclusion: { in: [1, 2] }, allow_blank: true
        def call; end
      end

      expect(klass.call(status: "")).to be_ok
      expect(klass.call(status: nil)).to be_ok
      expect(klass.call(status: 1)).to be_ok
      expect(klass.call(status: 3)).not_to be_ok
    end

    it "adds nil (but not \"\") to a numeric enum and does not widen the type to permit the blank string" do
      # accepted divergence: runtime accepts "" for this field; the schema's enum/type do not admit it.
      klass = Class.new do
        include Axn
        expects :status, inclusion: { in: [1, 2] }, allow_blank: true
      end
      schema = klass.input_schema
      prop = schema[:properties][:status]

      expect(prop[:enum]).to match_array([1, 2, nil])
      # type carries the integer members and nil (allow_blank ⇒ nullable), but not "string".
      expect(Array(prop[:type])).to include("integer", "null")
      expect(Array(prop[:type])).not_to include("string")
    end

    it "adds nil (but not \"\") to a numeric allow_blank enum even without an explicit type: (type inferred from members)" do
      klass = Class.new do
        include Axn
        expects :status, inclusion: { in: [10, 20] }, allow_blank: true
      end
      schema = klass.input_schema

      expect(schema[:properties][:status][:enum]).to match_array([10, 20, nil])
      expect(Array(schema[:properties][:status][:type])).to include("integer", "null")
      expect(Array(schema[:properties][:status][:type])).not_to include("string")
    end

    it "does not widen the type or append \"\" for a numeric allow_NIL (not allow_blank) inclusion (runtime rejects \"\")" do
      klass = Class.new do
        include Axn
        expects :status, inclusion: { in: [1, 2] }, allow_nil: true
        def call; end
      end
      schema = klass.input_schema

      expect(klass.call(status: "")).not_to be_ok
      expect(schema[:properties][:status][:enum]).to match_array([1, 2, nil])
      expect(Array(schema[:properties][:status][:type])).not_to include("string")
    end

    it "adds nil (but not \"\") to a STRING-typed allow_blank enum" do
      # accepted divergence: runtime accepts "" (String type admits it, inclusion is skipped for a blank
      # value); the schema's enum lists only the declared members plus nil.
      klass = Class.new do
        include Axn
        expects :status, type: String, inclusion: { in: %w[a b] }, allow_blank: true
        def call; end
      end
      expect(klass.call(status: "")).to be_ok

      schema = klass.input_schema
      prop = schema[:properties][:status]
      expect(prop[:enum]).to match_array(%w[a b] + [nil])
      expect(Array(prop[:type])).to include("string")
    end
  end

  # The schema never synthesizes an empty-string enum member, so a blank-tolerant inclusion field with a
  # co-declared non-string type: reflects no "" and no widened "string" type — matching runtime here,
  # where the co-declared Integer type rejects "".
  describe "a blank-tolerant inclusion field with a co-declared non-string type: does NOT reflect \"\"" do
    it "runtime: Integer type + inclusion + allow_blank REJECTS \"\" (TypeValidator: \"\" is not an Integer)" do
      klass = Class.new do
        include Axn
        expects :status, type: Integer, inclusion: { in: [1, 2] }, allow_blank: true
        def call; end
      end

      expect(klass.call(status: "")).not_to be_ok
      expect(klass.call(status: 1)).to be_ok
      expect(klass.call(status: nil)).to be_ok # allow_blank tolerates nil
    end

    it "does NOT append \"\" to the enum and does NOT widen the type to include \"string\" (matches runtime rejection)" do
      klass = Class.new do
        include Axn
        expects :status, type: Integer, inclusion: { in: [1, 2] }, allow_blank: true
      end
      schema = klass.input_schema
      prop = schema[:properties][:status]

      expect(prop[:enum]).not_to include("")
      expect(Array(prop[:type])).not_to include("string")
      # the declared integer members remain (nil tolerated via allow_blank ⇒ nullable)
      expect(prop[:enum]).to match_array([1, 2, nil])
    end

    it "does NOT append \"\" / widen the type on OUTPUT either (the same validators reject \"\" outbound)" do
      build = lambda do |val|
        Class.new do
          include Axn
          exposes :status, type: Integer, inclusion: { in: [1, 2] }, allow_blank: true
          define_method(:call) { expose(status: val) }
        end
      end
      # runtime: outbound rejects "" (not an Integer), accepts a member and nil
      expect(build.call("").call).not_to be_ok
      expect(build.call(1).call).to be_ok

      klass = Class.new do
        include Axn
        exposes :status, type: Integer, inclusion: { in: [1, 2] }, allow_blank: true
        def call = expose(status: 1)
      end
      schema = described_class.build_output(klass.external_field_configs)
      prop = schema[:properties][:status]

      expect(prop[:enum]).not_to include("")
      expect(Array(prop[:type])).not_to include("string")
    end
  end

  # On OUTPUT, enum_for_inclusion adds only nil for a nullable inclusion field — never "". The advertised
  # output type is therefore not widened to permit "", matching the input side.
  describe "an output blank-tolerant inclusion field adds nil (not \"\") to its enum and does not widen its type" do
    it "runtime: outbound validation accepts \"\" and nil for a numeric allow_blank inclusion exposure, rejects a non-member number" do
      build = lambda do |val|
        Class.new do
          include Axn
          exposes :status, inclusion: { in: [1, 2] }, allow_blank: true
          define_method(:call) { expose(status: val) }
        end
      end

      expect(build.call("").call).to be_ok
      expect(build.call(nil).call).to be_ok
      expect(build.call(1).call).to be_ok
      expect(build.call(3).call).not_to be_ok
    end

    it "adds nil (but not \"\") to the output enum and does not widen the type" do
      # accepted divergence: outbound runtime accepts ""; the output schema's enum/type do not admit it.
      klass = Class.new do
        include Axn
        exposes :status, inclusion: { in: [1, 2] }, allow_blank: true
        def call = expose(status: 1)
      end
      schema = described_class.build_output(klass.external_field_configs)
      prop = schema[:properties][:status]

      # enum lists nil (allow_blank ⇒ nil-tolerant) alongside the numeric members, but not "".
      expect(prop[:enum]).to match_array([1, 2, nil])
      expect(Array(prop[:type])).to include("integer", "null")
      expect(Array(prop[:type])).not_to include("string")
    end
  end

  describe "reflection is side-effect-free (never runs user code on defaults/collections)" do
    # A default or inclusion collection that is a lazy/dynamic object (e.g. an ActiveRecord::Relation)
    # must not have empty?/include? invoked during schema generation — that could issue a query.
    lazy_class = Class.new do
      def empty? = raise("side effect: empty? invoked during reflection")
      def include?(_) = raise("side effect: include? invoked during reflection")
    end

    it "does not call empty? on a non-literal default while deciding requiredness" do
      lazy = lazy_class
      klass = Class.new do
        include Axn
        expects :a, default: lazy.new
        def call = nil
      end

      expect { klass.input_schema }.not_to raise_error
      # a non-literal (non-empty-inspectable) default counts as present ⇒ the field is omittable
      expect(klass.input_schema[:required] || []).not_to include("a")
    end

    it "does not call include? on a non-literal inclusion collection while deciding nullability" do
      lazy = lazy_class
      klass = Class.new do
        include Axn
        expects :b, inclusion: { in: lazy.new }, presence: false
        def call = nil
      end

      expect { klass.input_schema }.not_to raise_error
      # unknown nil-membership ⇒ treated as nil-rejecting (stricter, safe direction) ⇒ not nullable
      expect(Array(klass.input_schema[:properties][:b][:type])).not_to include("null")
    end

    it "still inspects nil membership for a literal Array inclusion set" do
      klass = Class.new do
        include Axn
        expects :c, inclusion: { in: ["x", nil] }, presence: false
        def call = nil
      end
      expect(klass.input_schema[:properties][:c][:enum]).to include(nil)
    end

    it "does not call empty? on an Array/Hash/String SUBCLASS default (subclass may override empty?)" do
      evil_array = Class.new(Array) do
        def empty? = raise("side effect: subclass empty? invoked during reflection")
      end
      klass = Class.new do
        include Axn
        expects :a, default: evil_array.new
        def call = nil
      end

      expect { klass.input_schema }.not_to raise_error
    end

    it "detects nil membership by identity, without dispatching == on inclusion-set elements" do
      evil_elem = Class.new do
        def ==(_other) = raise("side effect: element == invoked during reflection")
      end
      element = evil_elem.new
      klass = Class.new do
        include Axn
        expects :b, inclusion: { in: [element, "x"] }, presence: false
        def call = nil
      end

      expect { klass.input_schema }.not_to raise_error
      # the element with a custom == is not nil, and nil isn't in the set ⇒ not nullable
      expect(Array(klass.input_schema[:properties][:b][:type])).not_to include("null")
    end

    it "does not traverse an Array/Hash SUBCLASS default when normalizing the schema literal" do
      evil_container = Class.new(Array) do
        def map(*) = raise("side effect: subclass map invoked during reflection")
        def each_with_object(*) = raise("side effect: subclass each_with_object invoked during reflection")
      end
      seeded = evil_container.new([1, 2])
      klass = Class.new do
        include Axn
        expects :a, default: seeded
        def call = nil
      end

      expect { klass.input_schema }.not_to raise_error
    end

    it "detects nil in a NULLABLE enum by identity, without dispatching == on members" do
      evil_elem = Class.new do
        def ==(_other) = raise("side effect: member == invoked during reflection")
      end
      element = evil_elem.new
      klass = Class.new do
        include Axn
        expects :b, inclusion: { in: [element, "x"] }, allow_nil: true
        def call = nil
      end

      expect { klass.input_schema }.not_to raise_error
    end
  end
end
