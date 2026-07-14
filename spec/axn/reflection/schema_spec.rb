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

    it "requires a presence-validated field whose default is a WHITESPACE-only string (presence rejects blank)" do
      klass = Class.new do
        include Axn
        expects :name, type: String, default: "   "
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
      expect(schema[:required]).to include("name") # ActiveModel presence rejects "   " (blank)
    end

    it "requires a presence-validated field whose default is false (presence rejects false)" do
      klass = Class.new do
        include Axn
        expects :flag, default: false # no type ⇒ auto-presence, which rejects false
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
      expect(schema[:required]).to include("flag")
    end

    it "does NOT require a type: :boolean field defaulting to false (no presence validator to reject it)" do
      klass = Class.new do
        include Axn
        expects :flag, type: :boolean, default: false
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
      expect(schema[:required] || []).not_to include("flag")
    end

    it "does not dispatch empty?/strip on a non-literal default while checking blankness (side-effect-free)" do
      lazy = Class.new do
        def empty? = raise("side effect: empty? during reflection")
        def strip = raise("side effect: strip during reflection")
      end
      klass = Class.new do
        include Axn
        expects :x, default: lazy.new
        def call = nil
      end
      expect { klass.input_schema }.not_to raise_error
    end

    it "does NOT require a presence: { allow_blank: true } field whose blank \"\" default it skips (runtime: call ok)" do
      klass = Class.new do
        include Axn
        expects :name, type: String, presence: { allow_blank: true }, default: ""
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
      expect(schema[:required] || []).not_to include("name")
    end

    it "DOES require a presence: { allow_nil: true } field with a blank \"\" default (allow_nil does not skip a non-nil blank)" do
      klass = Class.new do
        include Axn
        expects :name, type: String, presence: { allow_nil: true }, default: ""
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
      expect(schema[:required]).to include("name")
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

    it "constrains a type: TrueClass / FalseClass singleton via enum (not the whole boolean domain)" do
      # TypeValidator accepts only the singleton value, so a bare type: "boolean" would let a client send
      # the other value and pass schema validation while the action rejects it.
      t = Class.new do
        include Axn
        expects :flag, type: TrueClass
      end
      f = Class.new do
        include Axn
        expects :flag, type: FalseClass
      end
      tn = Class.new do
        include Axn
        expects :flag, type: TrueClass, allow_nil: true
      end

      t_prop = described_class.build_input(t.internal_field_configs, t.subfield_configs)[:properties][:flag]
      f_prop = described_class.build_input(f.internal_field_configs, f.subfield_configs)[:properties][:flag]
      tn_prop = described_class.build_input(tn.internal_field_configs, tn.subfield_configs)[:properties][:flag]

      expect(t_prop).to eq(type: "boolean", enum: [true])
      expect(f_prop).to eq(type: "boolean", enum: [false])
      # nullable adds nil to both the type and the enum
      expect(tn_prop[:type]).to eq(%w[boolean null])
      expect(tn_prop[:enum]).to eq([true, nil])
    end

    it "leaves type: :boolean as the full boolean domain (no enum)" do
      klass = Class.new do
        include Axn
        expects :flag, type: :boolean
      end
      prop = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)[:properties][:flag]
      expect(prop).to eq(type: "boolean")
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

  it "requires a Hash parent whether a sibling is required or every sibling is defaulted " \
     "(a subfield default resolves only the child, never synthesizing the parent)" do
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
    # `partial` is required because `a` is a required child; `covered` is required because its own
    # presence obligation stands — the child defaults resolve on the read path and do not synthesize payload.
    expect(described_class.build_input(partial.internal_field_configs, partial.subfield_configs)[:required]).to include("payload")
    expect(Array(described_class.build_input(covered.internal_field_configs, covered.subfield_configs)[:required])).to include("payload")
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

  it "strips null from a non-nestable (Array) parent when a required DEEP descendant forbids a nil parent (PRO-2872)" do
    # `items` is non-nestable (type: Array), so its subfield shape is omitted — but a required DEEP
    # descendant (`items.first.sku`) still forces `items` required (field_optional?). A nil parent
    # yields every descendant absent (PRO-2857), stranding the required sku, so `items` must also be
    # non-nullable: type exactly "array", no null branch. The dig reads a real reader segment (`Array#first`)
    # so the segment is answerable at declaration. The required `sku` carries a Proc default so the contract is legal under
    # PRO-2889 (satisfiability counts the Proc); strict reflection ignores Procs, so `items` is still
    # required + non-nullable. The Proc rescues omission at runtime — schema stricter than runtime, the safe divergence.
    klass = Class.new do
      include Axn
      expects :items, type: Array, allow_nil: true
      expects :sku, on: "items.first", type: String, default: -> { "x" }
      def call; end
    end
    schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

    expect(schema[:properties][:items][:type]).to eq("array")
    expect(schema[:required]).to include("items")
    expect(klass.call(items: nil)).to be_ok # Proc default rescues omission; schema stays stricter
    expect(klass.call).to be_ok
  end

  it "strips the null member from a non-nestable UNION parent when a required DEEP descendant forbids nil (PRO-2872)" do
    # A mixed union (type: [Hash, Array]) is non-nestable, so its subfield shape is omitted, but the
    # required deep descendant forces it required and non-nullable — the anyOf must carry no `null` member.
    # The required `sku` carries a Proc default so the contract is legal under PRO-2889 (satisfiability counts
    # the Proc); strict reflection ignores Procs, so `items` stays required + non-nullable while the Proc
    # rescues omission at runtime (schema stricter than runtime, the safe divergence).
    klass = Class.new do
      include Axn
      expects :items, type: [Hash, Array], allow_nil: true
      expects :sku, on: "items.first_item", type: String, default: -> { "x" }
      def call; end
    end
    schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

    members = schema[:properties][:items][:anyOf]
    expect(members).not_to include({ type: "null" })
    expect(schema[:required]).to include("items")
    expect(klass.call(items: nil)).to be_ok # Proc default rescues omission; schema stays stricter
  end

  it "keeps the null branch on a non-nestable parent when every deep descendant is optional (PRO-2872)" do
    # Negative control: an all-optional dropped subtree strands nothing, so a nil/omitted `items` is
    # accepted at runtime — the schema keeps the null branch and leaves `items` omittable, matching runtime.
    klass = Class.new do
      include Axn
      expects :items, type: Array, allow_nil: true
      expects :sku, on: "items.first", type: String, optional: true
      def call; end
    end
    schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

    expect(schema[:properties][:items][:type]).to eq(%w[array null])
    expect(Array(schema[:required])).not_to include("items")
    expect(klass.call(items: nil)).to be_ok
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

    it "forbids null on a required GENERATED (untyped) model id via not: { type: null }" do
      # The generated id is unconstrained (a PK has no fixed JSON type), so there's no type/anyOf branch to
      # strip — a null token resolves the model to nil and fails at runtime, so add an explicit not-null.
      klass = Class.new do
        include Axn
        expects :company, model: { klass: Struct.new(:id), finder: :find }
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required]).to include("company_id")
      expect(schema[:properties][:company_id][:not]).to eq(type: "null")
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

    it "does NOT require the model <field>_id when an explicit <field>_id field carries a default (runtime: omitting both is ok)" do
      klass = Class.new do
        include Axn
        expects :company_id, default: 1
        expects :company, model: { klass: Struct.new(:id), finder: :find }
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      # inbound defaults run before the model lookup, so the default supplies company_id and the omitted
      # call succeeds — the schema must not over-require it.
      expect(schema[:required] || []).not_to include("company_id")
    end

    it "DOES require the model <field>_id when an explicit <field>_id is only nullable (no default supplies the token)" do
      klass = Class.new do
        include Axn
        expects :company_id, optional: true
        expects :company, model: { klass: Struct.new(:id), finder: :find }
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      # optional-without-default doesn't supply the lookup token: omitting both leaves the model reader
      # nil and validation fails at runtime, so the id must stay required.
      expect(schema[:required]).to include("company_id")
    end

    it "strips the null branch from a required model id whose explicit field is typed-nullable (null is not a valid token)" do
      klass = Class.new do
        include Axn
        expects :company_id, type: String, allow_nil: true
        expects :company, model: { klass: Struct.new(:id), finder: :find }
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      # required (no default supplies the token) AND non-null: `{company_id: null}` resolves the model to
      # nil and fails at runtime, so the schema must not advertise null.
      expect(schema[:required]).to include("company_id")
      expect(schema[:properties][:company_id][:type]).to eq("string")
    end

    it "strips the null branch from a required NESTED model id whose explicit subfield is typed-nullable" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash
        expects :company_id, on: :payload, type: String, allow_nil: true
        expects :company, on: :payload, model: { klass: Struct.new(:id), finder: :find }
      end
      payload = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)[:properties][:payload]

      expect(payload[:required]).to include("company_id")
      expect(payload[:properties][:company_id][:type]).to eq("string") # no "null"
    end

    it "over-requires the parent of a nested model: subfield with a sibling defaulted id (accepted divergence)" do
      # Runtime synthesizes `payload` and the sibling id default supplies the token, so omitting `payload`
      # succeeds — but reconciling a nested self-referential id/model contract isn't attempted; the parent
      # reflects as required (the safe, stricter-than-runtime direction). Documented in docs/reference/class.md.
      klass = Class.new do
        include Axn
        expects :payload, type: Hash
        expects :company_id, on: :payload, default: 1
        expects :company, on: :payload, model: { klass: Struct.new(:id), finder: :find }
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required]).to include("payload")
    end

    it "requires the model <field>_id when a nil-tolerant model field has a required shallow subfield" do
      # `company` accepts nil, but a required `name` subfield still resolves off the record — the id must
      # stay required despite allow_nil. `name` carries a Proc default so the contract is legal under
      # PRO-2889 (satisfiability counts the Proc); strict reflection ignores Procs, so the override stands.
      klass = Class.new do
        include Axn
        expects :company, model: { klass: Struct.new(:id, :name), finder: :find }, allow_nil: true
        expects :name, on: :company, type: String, default: -> { "x" }
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required]).to include("company_id")
    end

    it "does NOT require the model <field>_id when a nil-tolerant model has ONLY an optional shallow subfield" do
      # `company` accepts nil and `name` is optional, so an omitted id resolves company to nil and the
      # optional subfield validates as absent — the omitted call succeeds, so the id must not be required.
      klass = Class.new do
        include Axn
        expects :company, model: { klass: Struct.new(:id, :name), finder: :find }, allow_nil: true
        expects :name, on: :company, type: String, optional: true
        def call = nil
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(Array(schema[:required])).not_to include("company_id")
      expect(klass.call).to be_ok # runtime agreement: omitting the id succeeds
    end

    it "does not require the model <field>_id for a nil-tolerant model with an optional defaulted subfield" do
      # The optional subfield never forces the id: omitting it resolves company to nil, the value-level
      # default supplies name="x" at read time (PRO-2889), and an optional String validates either way —
      # so the omitted call succeeds and the id stays out of `required`.
      klass = Class.new do
        include Axn
        expects :company, model: { klass: Struct.new(:id, :name), finder: :find }, allow_nil: true
        expects :name, on: :company, type: String, default: "x", optional: true
        def call = nil
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(Array(schema[:required])).not_to include("company_id")
      expect(klass.call).to be_ok # runtime agreement: the value-level default applies at read time, so omission succeeds
    end

    it "does not require the model <field>_id for an optional PROC-defaulted subfield either (optionality alone rescues it)" do
      klass = Class.new do
        include Axn
        expects :company, model: { klass: Struct.new(:id, :name), finder: :find }, allow_nil: true
        expects :name, on: :company, type: String, default: -> { "x" }, optional: true
        def call = nil
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(Array(schema[:required])).not_to include("company_id")
      expect(klass.call).to be_ok # runtime agreement: the optional subfield never forces the id, so omission succeeds
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

    describe "model id requiredness with value-level defaults (PRO-2889)" do
      let(:model_class) do
        Class.new do
          def self.fetch(_id) = nil
        end
      end

      before { stub_const("SchemaCo", model_class) }

      it "does not require the id when the nil-tolerant model's descendants are all defaulted/optional" do
        action = build_axn do
          expects :company, model: { klass: SchemaCo, finder: :fetch }, allow_nil: true
          expects :name, on: :company, type: String, default: "x"
          def call = nil
        end
        expect(action.input_schema[:required].to_a).not_to include("company_id")
      end

      it "keeps the id required for a Proc-defaulted descendant (strict mode: unknowable → required)" do
        action = build_axn do
          expects :company, model: { klass: SchemaCo, finder: :fetch }, allow_nil: true
          expects :name, on: :company, type: String, default: -> { "x" }
          def call = nil
        end
        expect(action.input_schema[:required]).to include("company_id")
      end
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

    # A shape member's name isn't symbolized at declaration (`field "bar"` keeps a String field), so its
    # emitted property must still key by symbol — every other schema property key (top-level config.field,
    # symbolized wire keys, implicit intermediates) is a Symbol. A string key would leave a duplicate
    # alongside the symbol key a colliding subfield writes, which collide unpredictably in JSON.
    context "with a string-named shape member (`field \"bar\"`)" do
      it "reflects a plain string-named member under the symbol key (no string duplicate)" do
        klass = Class.new do
          include Axn
          expects :payload, type: Hash do
            field "bar", type: Hash
          end
        end
        prop = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)[:properties][:payload]

        expect(prop[:properties].keys).to eq([:bar])
      end

      it "merges a colliding dotted subfield into the ONE symbol key, not a string duplicate" do
        klass = Class.new do
          include Axn
          expects :payload, type: Hash do
            field "bar", type: Hash
          end
          expects "bar.baz", on: :payload, type: String
        end
        prop = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)[:properties][:payload]

        expect(prop[:properties].keys).to eq([:bar])
        expect(prop[:properties][:bar][:properties]).to have_key(:baz)
      end

      it "overwrites the ONE symbol key with a colliding explicit subfield, not a string duplicate" do
        klass = Class.new do
          include Axn
          expects :payload, type: Hash do
            field "bar", type: Hash
          end
          expects :bar, on: :payload, type: Hash
        end
        prop = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)[:properties][:payload]

        expect(prop[:properties].keys).to eq([:bar])
      end
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

    it "does not advertise object OUTPUT for a Data/Struct that defines its OWN as_json (serialize follows it, not to_h)" do
      custom_data = Data.define(:name) do
        def as_json(*) = "scalar-#{name}"
      end
      klass = Class.new do
        include Axn
        exposes(:cfg, type: custom_data) { field :name, type: String }
        define_method(:call) { expose(:cfg, custom_data.new(name: "x")) }
      end

      out = described_class.build_output(klass.external_field_configs)[:properties][:cfg]
      expect(out).not_to have_key(:type) # own as_json may return a non-object, so don't promise one
      # a plain Data (inherited active_support as_json is member-keyed) still gets object output:
      plain_data = Data.define(:name)
      plain = Class.new do
        include Axn
        exposes(:cfg, type: plain_data) { field :name, type: String }
        def call = nil
      end
      expect(described_class.build_output(plain.external_field_configs)[:properties][:cfg][:type]).to eq("object")
    end

    it "detects a custom as_json provided by an INCLUDED MODULE (not just directly defined)" do
      json_mod = Module.new { def as_json(*) = "scalar" }
      mod_data = Data.define(:name) { include json_mod }
      klass = Class.new do
        include Axn
        exposes(:cfg, type: mod_data) { field :name, type: String }
        def call = nil
      end

      # serialize_value follows the module's as_json (owner != Object), so it isn't provably member-keyed.
      expect(described_class.build_output(klass.external_field_configs)[:properties][:cfg]).not_to have_key(:type)
    end

    it "does not advertise object OUTPUT for a shaped Data with a custom to_h (serialize follows to_h outside Rails)" do
      # Outside Rails (no as_json), serialize_value follows a custom to_h, which may return a non-object.
      custom_toh = Data.define(:name) { def to_h = "scalar" }
      klass = Class.new do
        include Axn
        exposes(:cfg, type: custom_toh) { field :name, type: String }
        def call = nil
      end
      expect(described_class.build_output(klass.external_field_configs)[:properties][:cfg]).not_to have_key(:type)
    end

    it "does not force object array items on OUTPUT for a shaped array whose element type isn't provably an object" do
      # of: a custom-as_json Data (serialize follows as_json), and the no-`of:` case (element type unknown).
      of_custom = Data.define(:name) { def as_json(*) = "scalar" }
      with_of = Class.new do
        include Axn
        exposes(:items, type: Array, of: of_custom) { field :name, type: String }
        def call = nil
      end
      no_of = Class.new do
        include Axn
        exposes(:items, type: Array) { field :name, type: String }
        def call = nil
      end

      expect(described_class.build_output(with_of.external_field_configs)[:properties][:items]).not_to have_key(:items)
      expect(described_class.build_output(no_of.external_field_configs)[:properties][:items]).not_to have_key(:items)
    end

    it "keeps scalar array item types when a shape reads members off the scalar element (of: String + field :length)" do
      # Runtime accepts string elements (OfValidator checks the class; ShapeValidator reads String#length),
      # so forcing object items would reject a valid string array. The scalar item type is preserved.
      klass = Class.new do
        include Axn
        expects(:items, type: Array, of: String) { field :length, type: Integer }
        def call = nil
      end
      items = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)[:properties][:items][:items]

      expect(items).to eq(type: "string")
    end

    it "does not advertise object array-items OUTPUT for `of:` a custom-as_json Data (but keeps them on input)" do
      of_data = Data.define(:name) { def as_json(*) = "scalar" }
      klass = Class.new do
        include Axn
        exposes(:items, type: Array, of: of_data)
        expects(:in_items, type: Array, of: of_data)
        def call = nil
      end

      out = described_class.build_output(klass.external_field_configs)[:properties][:items]
      inp = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)[:properties][:in_items]
      expect(out).not_to have_key(:items) # untyped elements — serialize follows the custom as_json
      expect(inp[:items][:type]).to eq("object") # input describes the object a client sends
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

    it "types an allow_nil parent as plain object when it has a REQUIRED subfield (a nil parent can't yield it)" do
      # `name` carries a Proc default so the contract is legal under PRO-2889 (satisfiability counts the
      # Proc); strict reflection ignores Procs, so the required-subfield override still types payload object.
      klass = Class.new do
        include Axn
        expects :payload, type: Hash, allow_nil: true
        expects :name, on: :payload, type: String, default: -> { "x" }
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:properties][:payload][:type]).to eq("object")
      expect(schema[:properties][:payload][:properties]).to have_key(:name)
    end
  end

  # A nil parent is now valid at runtime (subfields treated as absent) when the parent tolerates nil and
  # no required child is stranded — so the schema advertises `null` in exactly that case (PRO-2857).
  describe "a parent field with subfields is nullable iff it accepts nil and strands no required child" do
    it "types a nil-tolerant parent with an all-optional subfield as [object, null]" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash, allow_nil: true
        expects :nick, on: :payload, type: String, optional: true
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:properties][:payload][:type]).to eq(%w[object null])
    end

    it "keeps a nil-tolerant parent object-only when a required subfield can't be yielded by nil" do
      # `nick` carries a Proc default so the contract is legal under PRO-2889 (satisfiability counts the
      # Proc); strict reflection ignores Procs, so the required subfield still keeps payload object-only.
      klass = Class.new do
        include Axn
        expects :payload, type: Hash, allow_nil: true
        expects :nick, on: :payload, type: String, default: -> { "x" }
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:properties][:payload][:type]).to eq("object")
    end

    it "keeps a non-nil-tolerant parent (type: Hash) object-only even with an all-optional subfield" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash
        expects :nick, on: :payload, type: String, optional: true
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:properties][:payload][:type]).to eq("object")
    end

    it "stays nullable when a required shape (do…end) member coexists with only optional on: subfields" do
      # ShapeValidator skips a nil parent (allow_nil), so its required member does NOT strand nil — only a
      # required `on:` subfield does. Nullability must be decided from the on: subfields, not the merged
      # `required` (which also carries the shape member). The member stays in the nested `required`: it's
      # required IF a non-null object is sent.
      klass = Class.new do
        include Axn
        expects :payload, type: Hash, allow_nil: true do
          field :status, type: String
        end
        expects :note, on: :payload, type: String, optional: true
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
      prop = schema[:properties][:payload]

      expect(prop[:type]).to eq(%w[object null])
      expect(prop[:required]).to eq(["status"])
      expect(schema[:required] || []).not_to include("payload")
    end

    it "stays nullable when a shape member coexists with a PREPROCESSED (not defaulted) subfield" do
      # A preprocess does not synthesize an absent parent (unlike a default), so a nil parent stays nil and
      # ShapeValidator skips its required member — `payload: null`/omitted is accepted at runtime, so the
      # schema must keep advertising `null` (only defaults count as synthesizers).
      klass = Class.new do
        include Axn
        expects :payload, type: Hash, allow_nil: true do
          field :status, type: String
        end
        expects :note, on: :payload, optional: true, type: String, preprocess: ->(v) { v.to_s.strip }
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:properties][:payload][:type]).to eq(%w[object null])
      expect(schema[:required] || []).not_to include("payload")
    end

    it "does NOT treat a defaulted subfield as a synthesizer for a non-object parent (stays optional)" do
      # Runtime refuses to inject `{}` for a non-object `type: Array` parent, so a defaulted subfield can't
      # synthesize it and ShapeValidator skips an omitted/nil parent — the parent stays omittable. The
      # schema must agree (gating synthesis on object-shaped), not mark it required.
      klass = Class.new do
        include Axn
        expects :items, type: Array, allow_nil: true do
          field :status, type: String
        end
        expects :first, on: :items, optional: true, type: String, default: "x"
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required] || []).not_to include("items")
    end

    it "types the parent object-only + required when a defaulted subfield synthesizes it into a required shape member" do
      # A truthy-default `on:` subfield makes apply_defaults_for_subfields! materialize the nil parent, so
      # ShapeValidator no longer skips and enforces the required `status` member — runtime rejects
      # `payload: null`/omitted. Schema must agree: non-nullable AND required (unlike the no-default case).
      # The parent Proc default keeps the contract legal under PRO-2889 (satisfiability counts the Proc as a
      # rescue), while strict reflection ignores Procs so the shape-synthesis hazard still forces payload required.
      klass = Class.new do
        include Axn
        expects :payload, type: Hash, allow_nil: true, default: -> { {} } do
          field :status, type: String
        end
        expects :note, on: :payload, optional: true, type: String, default: "x"
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:properties][:payload][:type]).to eq("object")
      expect(schema[:required]).to include("payload")
    end

    it "types the parent object-only + required when a DEEP (dotted-name) subfield default synthesizes it " \
       "into a required shape member (PRO-2872)" do
      # `expects "address.zip", on: :payload, default: "x"` lands the defaulted config on a DEEPER node
      # (under an implicit `address`). Runtime still materializes `{}` under `payload` BEFORE writing the
      # default, so ShapeValidator no longer short-circuits on nil and enforces the required `status`
      # member — omission AND `payload: nil` FAIL. The shape-member hazard must walk the whole subtree,
      # not just direct children, so the schema agrees: payload required AND non-nullable.
      # The parent Proc default keeps the contract legal under PRO-2889 (satisfiability counts the Proc as a
      # rescue), while strict reflection ignores Procs so the shape-synthesis hazard still forces payload required.
      klass = Class.new do
        include Axn
        expects :payload, type: Hash, allow_nil: true, default: -> { {} } do
          field :status, type: String
        end
        expects "address.zip", on: :payload, default: "x"
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:properties][:payload][:type]).to eq("object")
      expect(schema[:required]).to include("payload")
      expect(klass.call).not_to be_ok                          # runtime agreement: omission fails
      expect(klass.call(payload: nil)).not_to be_ok            # runtime agreement: nil fails
      expect(klass.call(payload: { status: "ok" })).to be_ok   # a satisfying call passes
    end

    it "types the parent object-only + required when a DEEP (dotted-name) subfield PROC default synthesizes " \
       "it (the hazard counts Procs — materialization fires before the Proc runs, PRO-2872)" do
      # Same as above but the default is a Proc. Runtime materializes `{}` under `payload` BEFORE the Proc
      # is evaluated, so the required `status` member is still enforced — omission/nil FAIL. The hazard
      # predicate counts Procs, so the schema marks payload required AND non-nullable.
      # The parent Proc default keeps the contract legal under PRO-2889 (satisfiability counts the Proc as a
      # rescue), while strict reflection ignores Procs so the shape-synthesis hazard still forces payload required.
      klass = Class.new do
        include Axn
        expects :payload, type: Hash, allow_nil: true, default: -> { {} } do
          field :status, type: String
        end
        # optional: so the zip itself isn't a required descendant — the shape-member hazard clause,
        # not the required-child clause, must be what forces the parent.
        expects "address.zip", on: :payload, type: String, default: -> { "x" }, optional: true
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:properties][:payload][:type]).to eq("object")
      expect(schema[:required]).to include("payload")
      expect(klass.call).not_to be_ok               # runtime agreement: omission fails
      expect(klass.call(payload: nil)).not_to be_ok # runtime agreement: nil fails
    end

    it "requires the parent when a DEEP (dotted-name) subfield default would land under it (the default " \
       "resolves only the child on the read path, never synthesizing the parent, PRO-2903)" do
      # `expects "address.zip", on: :payload, default: "x"` on a plain Hash parent: the deep default resolves
      # only the child's value when read — it never synthesizes `payload` — so the parent keeps its own
      # presence obligation. The schema marks it required and runtime rejects omission.
      klass = Class.new do
        include Axn
        expects :payload, type: Hash
        expects "address.zip", on: :payload, default: "x"
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required] || []).to include("payload")
      expect(klass.call).not_to be_ok # runtime agreement: omission fails the parent's own presence
    end

    it "keeps the parent required when the only DEEP (dotted-name) subfield default is a Proc (rescue " \
       "excludes Procs — stricter than runtime, PRO-2872)" do
      # A Proc default's success is what would rescue omission, and a raising Proc would make omission FAIL,
      # so the rescue walk deliberately excludes Procs — the parent stays required. This is the safe,
      # stricter-than-runtime direction: runtime omission may pass when the Proc behaves, but reflecting
      # required never causes a failed call. Schema-only assertion (runtime may legitimately differ).
      klass = Class.new do
        include Axn
        expects :payload, type: Hash
        # optional: so nothing in the subtree requires presence — the rescue clause alone decides.
        expects "address.zip", on: :payload, type: String, default: -> { "x" }, optional: true
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required]).to include("payload")
    end

    it "does NOT force object on a MIXED-union parent (type: [Hash, Array]) with a subfield — preserves the array branch" do
      # Runtime reads the subfield from either branch (e.g. Array#length), so `payload: [1,2]` is valid;
      # forcing type: object would reject it. Keep the anyOf and omit the (unrepresentable) subfield shape.
      klass = Class.new do
        include Axn
        expects :payload, type: [Hash, Array]
        expects :length, on: :payload, type: Integer
      end
      prop = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)[:properties][:payload]

      expect(prop[:anyOf]).to match_array([{ type: "object" }, { type: "array" }])
      expect(prop).not_to have_key(:type)       # not overwritten to "object"
      expect(prop).not_to have_key(:properties) # subfield shape omitted (can't apply to the array branch)
    end
  end

  describe "a parent field with subfields is required unless a default materializes it (Bug Y)" do
    it "does not require an optional (no-default) parent with an all-optional subfield" do
      # Omitting yields a nil parent, which runtime now treats as "subfields absent" (PRO-2857) — the
      # all-optional children then pass, so reflecting the parent as optional matches runtime exactly.
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

    it "requires the Hash-typed analog too (a subfield default resolves only the child, never synthesizing the Hash parent)" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash
        expects :name, on: :payload, type: String, default: "x"
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required] || []).to include("payload")
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

  describe "a dotted subfield NAME nests as recursive object properties keyed by wire segment" do
    it "nests a dotted-name subfield under an implicit intermediate (bar -> baz), not a flat dotted key" do
      klass = Class.new do
        include Axn
        expects :foo, type: Hash
        expects "bar.baz", on: :foo
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      foo = schema[:properties][:foo]
      # The dotted name splits into an implicit :bar intermediate carrying the :baz leaf — never a flat
      # "bar.baz" property key.
      expect(foo[:properties]).not_to have_key("bar.baz")
      expect(foo[:properties]).not_to have_key(:"bar.baz")
      bar = foo[:properties][:bar]
      expect(bar[:type]).to eq("object")
      expect(bar[:properties]).to have_key(:baz)
      # The untyped :baz leaf is required (default presence), so its implicit :bar and the parent :foo
      # are required in turn.
      expect(bar[:required]).to eq(["baz"])
      expect(foo[:required]).to eq(["bar"])
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

    it "nests both a normal sibling subfield and a dotted-name subfield on the same parent" do
      klass = Class.new do
        include Axn
        expects :foo, type: Hash
        expects :bar, on: :foo, type: String
        expects "deep.path", on: :foo
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      foo = schema[:properties][:foo]
      expect(foo[:properties].keys).to contain_exactly(:bar, :deep)
      expect(foo[:properties][:bar]).to include(type: "string")
      deep = foo[:properties][:deep]
      expect(deep[:type]).to eq("object")
      expect(deep[:properties]).to have_key(:path)
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
      # the schema reflects both as optional because `optional: true` is a nil-tolerant declared signal
      # and the sole child is itself optional. Parity is the criterion: the dotted subfield's parent
      # reflects its optionality identically to the shallow case.
      expect(shallow_schema[:required] || []).not_to include("foo")
      expect(dotted_schema[:required] || []).not_to include("foo")

      # The dotted subfield nests under an implicit :bar intermediate (never a flat "bar.baz" key).
      expect(dotted_schema[:properties][:foo][:properties][:bar][:properties]).to have_key(:baz)
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

    it "requires the parent when its only child is a REQUIRED dotted subfield (a required descendant strands a nil parent)" do
      klass = Class.new do
        include Axn
        expects :foo, type: Hash, default: {}
        expects "bar.baz", on: :foo, type: String
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required]).to include("foo")
    end
  end

  describe "a dotted `on:` PARENT or an `on:` pointing at another subfield nests recursively and forces " \
           "its ancestor chain required when a descendant is required" do
    it "requires an allow_nil parent through both a required SHALLOW child and its dotted-deep analog" do
      # `zip` carries a Proc default in both routes so the contracts are legal under PRO-2889 (satisfiability
      # counts the Proc); strict reflection ignores Procs, so the required leaf still forces the chain.
      shallow = Class.new do
        include Axn
        expects :address, allow_nil: true
        expects :zip, on: :address, default: -> { "x" }
      end
      dotted = Class.new do
        include Axn
        expects :address, allow_nil: true
        expects :zip, on: "address.billing", default: -> { "x" }
      end

      shallow_schema = described_class.build_input(shallow.internal_field_configs, shallow.subfield_configs)
      dotted_schema = described_class.build_input(dotted.internal_field_configs, dotted.subfield_configs)

      # A required child strands an omitted parent at runtime, so the nil-tolerant parent stays required
      # despite allow_nil — whether the required leaf is shallow or reached through a dotted-deep chain
      # (a required descendant at any depth forces the ancestor chain required, PRO-2857).
      expect(shallow_schema[:required] || []).to include("address")
      expect(dotted_schema[:required] || []).to include("address")

      # The dotted parent nests through an implicit :billing intermediate carrying the required :zip leaf.
      billing = dotted_schema[:properties][:address][:properties][:billing]
      expect(billing[:type]).to eq("object")
      expect(billing[:properties]).to have_key(:zip)
      expect(billing[:required]).to eq(["zip"])
    end

    it "requires the top-level root when only a DEEP leaf (subfield-of-a-subfield) is required" do
      # A required descendant (:leaf) at any depth forces its whole ancestor chain required: the nil
      # parent (:foo) can't yield the descendant. `leaf` carries a Proc default so the contract is legal
      # under PRO-2889 (satisfiability counts the Proc); strict reflection ignores Procs, so the override stands.
      klass = Class.new do
        include Axn
        expects :foo, optional: true
        expects :mid, on: :foo, optional: true
        expects :leaf, on: :mid, default: -> { "x" }
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required] || []).to include("foo")
      # :mid nests under :foo, and :leaf nests recursively under :mid.
      mid = schema[:properties][:foo][:properties][:mid]
      expect(mid[:properties]).to have_key(:leaf)
    end

    it "requires a nil-tolerant root when its shallow child is required, even alongside a deep chain" do
      # The shallow child :mid is required, so an omitted :foo strands it at runtime — the parent is
      # required on that basis alone; the deeper :leaf (which also nests under :mid) merely reinforces it.
      # `mid` carries a Proc default so the contract is legal under PRO-2889 (satisfiability counts the Proc);
      # strict reflection ignores Procs, so :mid stays required and still forces :foo required.
      klass = Class.new do
        include Axn
        expects :foo, optional: true
        expects :mid, on: :foo, default: -> { {} }
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

  describe "falsey subfield defaults are optional-making in the schema (kwarg parity)" do
    it "does not require a nested subfield whose default is false (runtime applies any non-nil default)" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash
        expects :flag, on: :payload, type: :boolean, default: false
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:properties][:payload][:required] || []).not_to include("flag")
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

  describe "a false subfield default is emitted in the schema (kwarg parity)" do
    it "emits default: false for a subfield with a false default (runtime applies any non-nil default)" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash
        expects :flag, on: :payload, type: :boolean, default: false
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:properties][:payload][:properties][:flag]).to include(default: false)
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

  describe "a subfield default resolves only the child (value-level on the read path), never materializing the parent" do
    it "still requires the parent when a subfield carries a default and no child is required" do
      klass = Class.new do
        include Axn
        expects :payload
        expects :name, on: :payload, default: "anon"
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required]).to include("payload")
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

    it "still requires the parent when a subfield carries a false default (the default resolves the child's value, not the parent)" do
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

  # Deep subfields (PRO-2872): a dotted `on:` path, a subfield-of-a-subfield, and a dotted field
  # name nest as recursive object properties, keyed by wire key at every level. Intermediates
  # introduced by a dotted segment are IMPLICIT (no declaration of their own): bare object
  # properties whose requiredness/nullability derive purely from their descendants.
  describe "deep subfield nesting (PRO-2872)" do
    it "nests a subfield-of-a-subfield recursively" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash
        expects :meta, on: :payload, type: Hash
        expects :id, on: :meta, type: Integer
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      payload = schema[:properties][:payload]
      expect(payload[:type]).to eq("object")
      meta = payload[:properties][:meta]
      expect(meta[:type]).to eq("object")
      expect(meta[:properties][:id]).to include(type: "integer")
      expect(meta[:required]).to eq(["id"])
      expect(payload[:required]).to eq(["meta"])
      expect(schema[:required]).to include("payload")
    end

    it "nests a dotted on: path through an implicit intermediate object" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash
        expects :zip, on: "payload.address", type: String
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      address = schema[:properties][:payload][:properties][:address]
      expect(address[:type]).to eq("object")
      expect(address[:properties][:zip]).to include(type: "string")
      expect(address[:required]).to eq(["zip"])
    end

    it "nests a dotted field name through an implicit intermediate object" do
      klass = Class.new do
        include Axn
        expects :foo, type: Hash
        expects "bar.baz", on: :foo, type: String
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      bar = schema[:properties][:foo][:properties][:bar]
      expect(bar[:type]).to eq("object")
      expect(bar[:properties][:baz]).to include(type: "string")
      expect(bar[:required]).to eq(["baz"])
    end

    it "keys every level by wire key when on: chains through as: aliases" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash, as: :data
        expects :meta, on: :data, type: Hash, as: :details
        expects :id, on: :details, type: Integer
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:properties]).to have_key(:payload)
      expect(schema[:properties][:payload][:properties][:meta][:properties][:id]).to include(type: "integer")
    end

    it "makes an all-optional deep chain omittable and nullable at every level" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash, allow_nil: true
        expects :zip, on: "payload.address", type: String, optional: true
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      payload = schema[:properties][:payload]
      expect(payload[:type]).to eq(%w[object null])
      expect(payload[:properties][:address][:type]).to eq(%w[object null])
      expect(payload).not_to have_key(:required)
      expect(schema[:required]).to be_nil
    end

    it "keeps a deep subfield under a non-object explicit intermediate out of the schema (parent keeps its declared type)" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash
        expects :items, on: :payload, type: Array
        expects :first, on: :items, type: String, optional: true # reads Array#first (a real reader — answerable)
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      items = schema[:properties][:payload][:properties][:items]
      expect(items[:type]).to eq("array")
      expect(items).not_to have_key(:properties)
    end

    describe "transitive requiredness/nullability (a required descendant strands every nil/omitted ancestor)" do
      it "forces an optional: intermediate AND its nil-tolerant top-level parent required when a deep leaf " \
         "is required (fixes the old shallow-only divergence)" do
        # `id` carries a Proc default so the contract is legal under PRO-2889 (satisfiability counts the
        # Proc); strict reflection ignores Procs, so the transitive-requiredness override still stands.
        klass = Class.new do
          include Axn
          expects :payload, type: Hash, allow_nil: true
          expects :meta, on: :payload, type: Hash, optional: true
          expects :id, on: :meta, type: Integer, default: -> { 1 }
        end
        schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

        expect(schema[:required]).to include("payload")
        payload = schema[:properties][:payload]
        expect(payload[:type]).to eq("object")                       # null stripped: nil payload strands id
        expect(payload[:required]).to eq(["meta"])                   # optional: meta is overridden by its required child
        expect(payload[:properties][:meta][:type]).to eq("object")   # meta likewise non-nullable
      end

      it "keeps implicit intermediates required and non-nullable above a required deep leaf" do
        klass = Class.new do
          include Axn
          expects :payload, type: Hash
          expects :id, on: "payload.a.b", type: Integer
        end
        schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

        a = schema[:properties][:payload][:properties][:a]
        expect(a[:type]).to eq("object")
        expect(a[:required]).to eq(["b"])
        expect(a[:properties][:b][:type]).to eq("object")
        expect(a[:properties][:b][:required]).to eq(["id"])
      end

      it "lets a usable default on the depth-1 parent rescue omission despite a required deep child (default contents are trusted, the standing divergence)" do
        klass = Class.new do
          include Axn
          expects :payload, type: Hash, allow_nil: true
          expects :meta, on: :payload, type: Hash, default: { id: 1 }
          expects :id, on: :meta, type: Integer
        end
        schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

        payload = schema[:properties][:payload]
        # meta's default materializes it, so meta is omittable — and payload strands nothing.
        expect(Array(payload[:required])).not_to include("meta")
        expect(schema[:required]).to be_nil
        expect(payload[:properties][:meta][:required]).to eq(["id"])
      end

      it "counts a required deep leaf below a NON-OBJECT intermediate toward ancestor requiredness even " \
         "though its shape is omitted (runtime still validates it)" do
        # `first` reads a real reader segment (Array#first — answerable at declaration) and carries a Proc
        # default so the contract is legal under PRO-2889 (satisfiability counts the Proc); strict
        # reflection ignores Procs, so the deep-leaf-forces-ancestors override still stands.
        klass = Class.new do
          include Axn
          expects :payload, type: Hash, allow_nil: true
          expects :items, on: :payload, type: Array, optional: true
          expects :first, on: :items, type: String, default: -> { "x" }
        end
        schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

        # first is dropped from the schema shape (non-object parent) but runtime requires it,
        # which requires items present, which requires payload present.
        payload = schema[:properties][:payload]
        expect(payload[:required]).to eq(["items"])
        expect(payload[:type]).to eq("object")
        expect(schema[:required]).to include("payload")
        expect(payload[:properties][:items][:type]).to eq("array")
        expect(payload[:properties][:items]).not_to have_key(:properties)
      end
    end

    describe "model: subfields at depth" do
      it "emits <field>_id inside a deep nested object (not the model field itself)" do
        klass = Class.new do
          include Axn
          expects :payload, type: Hash
          expects :meta, on: :payload, type: Hash
          expects :company, on: :meta, model: { klass: Struct.new(:id), finder: :find }
        end
        schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

        meta = schema[:properties][:payload][:properties][:meta]
        expect(meta[:properties]).to have_key(:company_id)
        expect(meta[:properties]).not_to have_key(:company)
        expect(meta[:required]).to include("company_id")
        expect(meta[:properties][:company_id]).to include(not: { type: "null" }) # required id can't be null
      end

      it "still emits and consumes the id for a dotted ON: with a NON-dotted model name (a reader IS generated)" do
        # CONTRAST with the dropped dotted-NAME case above: here the NAME is plain (`:company`) and only the
        # `on:` is dotted, so ContractForSubfields generates a reader that runs the id->record lookup. The
        # `company_id` under `payload.org` stays represented and the runtime consumes it.
        model_klass = Class.new do
          def self.name = "Co"
          attr_reader :id

          def initialize(id) = @id = id
          def self.find(id) = id.nil? ? nil : new(id)
        end
        klass = Class.new do
          include Axn
          expects :payload, type: Hash
          expects :org, on: :payload, type: Hash
          expects :company, on: "payload.org", model: { klass: model_klass, finder: :find }
          def call = nil
        end
        schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

        org = schema[:properties][:payload][:properties][:org]
        expect(org[:properties]).to have_key(:company_id)
        expect(described_class.dropped_deep_subfields(klass.internal_field_configs, klass.subfield_configs)).to eq([])
        expect(klass.call(payload: { org: { company_id: 7 } })).to be_ok # runtime consumes the id
      end

      it "keeps an explicitly-declared deep sibling id instead of clobbering it with the generated one" do
        klass = Class.new do
          include Axn
          expects :payload, type: Hash
          expects :meta, on: :payload, type: Hash
          expects :company_id, on: :meta, type: :uuid
          expects :company, on: :meta, model: { klass: Struct.new(:id), finder: :find }
        end
        meta = described_class.build_input(klass.internal_field_configs,
                                           klass.subfield_configs)[:properties][:payload][:properties][:meta]

        expect(meta[:properties][:company_id]).to include(type: "string", format: "uuid")
        expect(Array(meta[:required]).count("company_id")).to eq(1)
      end

      it "requires the top-level model <field>_id when the model has a REQUIRED deep subfield (an omitted record strands it at runtime)" do
        # `theme` carries a Proc default so the contract is legal under PRO-2889 (satisfiability counts the
        # Proc); strict reflection ignores Procs, so the id stays required. The Proc rescues omission at
        # runtime — schema stricter than runtime, the safe divergence.
        klass = Class.new do
          include Axn
          expects :company, model: { klass: Struct.new(:id, :settings), finder: :find }, allow_nil: true
          expects :theme, on: "company.settings", type: String, default: -> { "x" }
          def call = nil
        end
        schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

        expect(schema[:required]).to include("company_id")
        expect(klass.call).to be_ok # Proc default rescues omission; schema stays stricter
      end

      it "does NOT require the model <field>_id when a nil-tolerant model has ONLY an optional deep subfield" do
        # An omitted id resolves company to nil; the optional deep subfield validates as absent (resolving
        # off a nil source yields nil), so the omitted call succeeds and the id must not be required.
        klass = Class.new do
          include Axn
          expects :company, model: { klass: Struct.new(:id, :settings), finder: :find }, allow_nil: true
          expects :theme, on: "company.settings", type: String, optional: true
          def call = nil
        end
        schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

        expect(Array(schema[:required])).not_to include("company_id")
        expect(klass.call).to be_ok # runtime agreement: omitting the id succeeds
      end

      it "does not require the model <field>_id when a deep dotted-name subfield is value-level defaulted (PRO-2889)" do
        # `expects "settings.theme", on: :company, default: "x"` lands the defaulted config on a DEEPER
        # node with a dotted NAME (no reader). PRO-2889: the value-level default "x" applies at read time
        # (validation resolves it through the shared `resolve_value`, no synthesis), so the deep subfield
        # is self-rescuing and the omitted call SUCCEEDS — the schema mirrors that and drops company_id
        # from `required`.
        klass = Class.new do
          include Axn
          expects :company, model: { klass: Struct.new(:id, :settings), finder: :find }, allow_nil: true
          expects "settings.theme", on: :company, default: "x"
          def call = nil
        end
        schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

        expect(Array(schema[:required])).not_to include("company_id")
        expect(klass.call).to be_ok # runtime agreement: the value-level default satisfies the deep subfield on omission
      end

      it "does not require the model <field>_id for an optional deep PROC default via a dotted NAME (optionality alone rescues it)" do
        # The optional deep subfield never forces the id: omitting it resolves company to nil, the deep
        # dotted-name default applies at read time (PRO-2889), and an optional String validates either
        # way — so the omitted call succeeds and the schema mirrors that.
        klass = Class.new do
          include Axn
          expects :company, model: { klass: Struct.new(:id, :settings), finder: :find }, allow_nil: true
          expects "settings.theme", on: :company, type: String, default: -> { "x" }, optional: true
          def call = nil
        end
        schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

        expect(Array(schema[:required])).not_to include("company_id")
        expect(klass.call).to be_ok # runtime agreement: the optional subfield never forces the id, so omission succeeds
      end
    end

    describe "composition with shape: members" do
      it "merges an implicit deep intermediate into an object-compatible shape member at the same key" do
        klass = Class.new do
          include Axn
          expects :payload, type: Hash do
            field :bar, type: Hash
          end
          expects "bar.baz", on: :payload, type: String
        end
        schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

        bar = schema[:properties][:payload][:properties][:bar]
        expect(Array(bar[:type])).to include("object")
        expect(bar[:properties][:baz]).to include(type: "string")
        expect(bar[:required]).to include("baz")
      end

      it "leaves a NON-object (union) shape member untouched and drops the colliding deep config (warned via dropped_deep_subfields)" do
        # `[Hash, String]`: non-nestable (the String branch blocks the drop pass) yet answerable (the Hash
        # branch reads a key), so the declaration is accepted while `bar.baz` still drops.
        klass = Class.new do
          include Axn
          expects :payload, type: Hash do
            field :bar, type: [Hash, String]
          end
          expects "bar.baz", on: :payload, type: String
        end
        schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

        bar = schema[:properties][:payload][:properties][:bar]
        expect(bar).to have_key(:anyOf)
        expect(Array(bar[:type])).not_to include("object")
        expect(bar).not_to have_key(:properties)
        dropped = described_class.dropped_deep_subfields(klass.internal_field_configs, klass.subfield_configs)
        expect(dropped.map(&:field)).to eq([:"bar.baz"])
      end

      it "leaves a mixed-union shape member untouched and drops the colliding deep config (emission and drop pass agree)" do
        klass = Class.new do
          include Axn
          expects :payload, type: Hash do
            field :bar, type: [Hash, Array]
          end
          expects "bar.baz", on: :payload, type: String
        end
        schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

        bar = schema[:properties][:payload][:properties][:bar]
        expect(bar).to have_key(:anyOf)
        expect(bar).not_to have_key(:properties)
        expect(Array(bar[:type])).not_to include("object")
        dropped = described_class.dropped_deep_subfields(klass.internal_field_configs, klass.subfield_configs)
        expect(dropped.map(&:field)).to eq([:"bar.baz"])
      end

      # A blocked merge omits the deep SHAPE but not the deep OBLIGATION: the colliding member's own
      # entry still inherits requiredness/non-nullability from the dropped subtree, because runtime
      # validates the dropped subfields regardless of representability. Here the deep `baz` is required
      # and resolves off `payload.bar`, so a nil/absent `bar` strands it (PRO-2857) — `bar` is
      # effectively required and non-nullable within `payload` even though its shape stays dropped.
      it "forces a blocked mixed-union member required + non-nullable when the dropped subtree requires presence" do
        klass = Class.new do
          include Axn
          expects :payload, type: Hash do
            field :bar, type: [Hash, Array], optional: true
          end
          expects :baz, on: "payload.bar", type: String
          def call = nil
        end
        schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

        payload = schema[:properties][:payload]
        bar = payload[:properties][:bar]
        expect(payload[:required]).to include("bar")
        expect(bar).to have_key(:anyOf)
        expect(bar).not_to have_key(:properties) # still blocked — no nested shape
        expect(bar[:anyOf]).not_to include(hash_including(type: "null")) # null admission stripped
        dropped = described_class.dropped_deep_subfields(klass.internal_field_configs, klass.subfield_configs)
        expect(dropped.map(&:field)).to eq([:baz])

        # Runtime agreement: the deep required baz can only resolve off a present, object-valued bar.
        expect(klass.call(payload: {})).not_to be_ok
        expect(klass.call(payload: { bar: nil })).not_to be_ok
        expect(klass.call(payload: { bar: { baz: "x" } })).to be_ok
      end

      it "leaves the blocked member's declared flags intact when the dropped subtree is all-optional (negative control)" do
        klass = Class.new do
          include Axn
          expects :payload, type: Hash do
            field :bar, type: [Hash, Array], optional: true
          end
          expects :baz, on: "payload.bar", type: String, optional: true
          def call = nil
        end
        schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

        payload = schema[:properties][:payload]
        bar = payload[:properties][:bar]
        expect(Array(payload[:required])).not_to include("bar")
        expect(bar[:anyOf]).to include(hash_including(type: "null")) # null branch preserved
        expect(bar).not_to have_key(:properties)
        expect(klass.call(payload: { bar: nil })).to be_ok # schema agrees: nil member accepted
      end

      # Union member variant (`[Hash, String]`): same required/non-nullable treatment. Only a present,
      # object-valued `bar` yields the deep `baz`; a nil/omitted or String-valued `bar` strands it, so the
      # schema forbids the nil/omitted member that runtime also rejects.
      it "forces a blocked union member required + non-nullable when the dropped subtree requires presence" do
        klass = Class.new do
          include Axn
          expects :payload, type: Hash do
            field :bar, type: [Hash, String], optional: true
          end
          expects :baz, on: "payload.bar", type: String
          def call = nil
        end
        schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

        payload = schema[:properties][:payload]
        bar = payload[:properties][:bar]
        expect(payload[:required]).to include("bar")
        expect(bar).to have_key(:anyOf)
        expect(bar[:anyOf]).not_to include(hash_including(type: "null")) # null admission stripped
        expect(bar).not_to have_key(:properties)
        dropped = described_class.dropped_deep_subfields(klass.internal_field_configs, klass.subfield_configs)
        expect(dropped.map(&:field)).to eq([:baz])

        expect(klass.call(payload: {})).not_to be_ok
        expect(klass.call(payload: { bar: nil })).not_to be_ok
      end

      it "leaves a non-object (union) member-of-a-member untouched and drops the deeper colliding config (implicit merge stops at the member)" do
        # `[Hash, String]` member-of-a-member: non-nestable (blocks the drop pass at depth 2) yet answerable
        # via its Hash branch, so the declaration is accepted while `bar.baz.qux` drops.
        klass = Class.new do
          include Axn
          expects :payload, type: Hash do
            field :bar, type: Hash do
              field :baz, type: [Hash, String]
            end
          end
          expects "bar.baz.qux", on: :payload
        end
        schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

        baz = schema[:properties][:payload][:properties][:bar][:properties][:baz]
        expect(baz).to have_key(:anyOf) # union member kept as-is
        expect(Array(baz[:type])).not_to include("object")
        expect(baz).not_to have_key(:properties) # no forced object / qux under it
        dropped = described_class.dropped_deep_subfields(klass.internal_field_configs, klass.subfield_configs)
        expect(dropped.map(&:field)).to eq([:"bar.baz.qux"])
      end

      it "leaves a mixed-union member-of-a-member untouched and drops the deeper colliding config" do
        klass = Class.new do
          include Axn
          expects :payload, type: Hash do
            field :bar, type: Hash do
              field :baz, type: [Hash, Array]
            end
          end
          expects "bar.baz.qux", on: :payload
        end
        schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

        baz = schema[:properties][:payload][:properties][:bar][:properties][:baz]
        expect(baz).to have_key(:anyOf)
        expect(baz).not_to have_key(:properties)
        expect(Array(baz[:type])).not_to include("object")
        dropped = described_class.dropped_deep_subfields(klass.internal_field_configs, klass.subfield_configs)
        expect(dropped.map(&:field)).to eq([:"bar.baz.qux"])
      end

      it "merges into an OBJECT member-of-a-member at depth 2 and does NOT drop the config (positive control)" do
        klass = Class.new do
          include Axn
          expects :payload, type: Hash do
            field :bar, type: Hash do
              field :baz, type: Hash
            end
          end
          expects "bar.baz.qux", on: :payload
        end
        schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

        baz = schema[:properties][:payload][:properties][:bar][:properties][:baz]
        expect(Array(baz[:type])).to include("object")
        expect(baz[:properties]).to have_key(:qux)
        dropped = described_class.dropped_deep_subfields(klass.internal_field_configs, klass.subfield_configs)
        expect(dropped).to eq([])
      end

      # An UNTYPED nil-tolerant member emits no `:type`, so nullability must be read from the member
      # config (nil_allowed?), not sniffed off the emitted property. (`optional: true` alone declares no
      # validator and raises at runtime, so the nil-tolerance is carried by a real validator here.)
      it "keeps a merged untyped nil-tolerant member nullable when the colliding deep child is optional" do
        klass = Class.new do
          include Axn
          expects :payload, type: Hash do
            field :bar, allow_nil: true, length: { maximum: 10 }
          end
          expects "bar.baz", on: :payload, type: String, optional: true
          def call = nil
        end
        schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

        bar = schema[:properties][:payload][:properties][:bar]
        expect(bar[:type]).to eq(%w[object null])
        expect(bar[:properties][:baz]).to include(type: %w[string null])
        expect(klass.call(payload: { bar: nil })).to be_ok # schema agrees: nil member accepted
      end

      it "strips null from a merged untyped nil-tolerant member when the colliding deep child is required" do
        klass = Class.new do
          include Axn
          expects :payload, type: Hash do
            field :bar, allow_nil: true, length: { maximum: 10 }
          end
          expects "bar.baz", on: :payload, type: String
          def call = nil
        end
        schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

        bar = schema[:properties][:payload][:properties][:bar]
        expect(bar[:type]).to eq("object") # a nil member strands the required leaf
        expect(bar[:required]).to include("baz")
        expect(klass.call(payload: { bar: nil })).not_to be_ok # schema agrees: nil member rejected
      end

      it "keeps a merged non-nil-tolerant typed member object-only even when the colliding deep child is optional" do
        klass = Class.new do
          include Axn
          expects :payload, type: Hash do
            field :bar, type: Hash
          end
          expects "bar.baz", on: :payload, type: String, optional: true
          def call = nil
        end
        schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

        bar = schema[:properties][:payload][:properties][:bar]
        expect(bar[:type]).to eq("object") # member rejects nil regardless of the child
        expect(klass.call(payload: { bar: nil })).not_to be_ok # schema agrees: nil member rejected
      end

      # A scalar shape member declared on the SECOND config at a merged node blocks the deep structure the
      # SAME as one on the first: emission consults every config's shape members, mirroring SubfieldTree,
      # so the config the tree dropped isn't quietly re-nested by the property (built from the first
      # config, which has no shape). (A subfield can't take a `do…end` block, so the shape rides a raw
      # `shape:` kwarg — the same structure the block DSL builds.)
      it "drops a deep config colliding with a non-object (union) shape member declared on the node's SECOND config" do
        x_member = Axn::Core::Contract::ShapeConfig.new(field: :x, validations: { type: { klass: [Hash, String] }, presence: true }, metadata: {})
        klass = Class.new do
          include Axn
          expects :foo, type: Hash
          expects :bar, on: :foo, type: Hash
          expects "bar.baz", on: :foo, type: Hash                                                  # baz config #1 (no shape)
          expects :baz, on: :bar, type: Hash, shape: { members: [x_member], container: Hash }      # baz config #2 (non-nestable member x)
          expects "baz.x.y", on: :bar                                                              # implicit x under baz + grandchild y
        end
        schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

        baz = schema[:properties][:foo][:properties][:bar][:properties][:baz]
        expect(baz[:properties]).not_to have_key(:y)                        # not force-nested under a blocking member
        expect(baz.dig(:properties, :x, :properties, :y)).to be_nil         # the deep x.y structure is dropped, matching the tree
        dropped = described_class.dropped_deep_subfields(klass.internal_field_configs, klass.subfield_configs)
        expect(dropped.map(&:field)).to eq([:"baz.x.y"])
      end

      # Two routes to a merged node each carry a nestable Hash member `x`, but their NESTED members at
      # `y` disagree: route 1's `y` is a nestable Hash, route 2's `y` is a non-nestable `[Hash, String]`
      # union. Emission carries ALL colliding members through the implicit hop, so at `y` it sees the
      # non-nestable route and drops `x.y.z`. The drop pass must carry them ALL too (not just the first
      # nestable `x`), or `x.y.z` validates at runtime yet is absent from BOTH the schema and
      # dropped_deep_subfields — a silent, unwarned gap. The union stays answerable at declaration (Hash branch).
      it "drops a deep config when merged colliding shape members carry disagreeing nested members" do
        y1 = Axn::Core::Contract::ShapeConfig.new(field: :y, validations: { type: { klass: Hash } }, metadata: {})
        x1 = Axn::Core::Contract::ShapeConfig.new(field: :x, validations: { type: { klass: Hash }, shape: { members: [y1], container: Hash } }, metadata: {})
        y2 = Axn::Core::Contract::ShapeConfig.new(field: :y, validations: { type: { klass: [Hash, String] }, presence: true }, metadata: {})
        x2 = Axn::Core::Contract::ShapeConfig.new(field: :x, validations: { type: { klass: Hash }, shape: { members: [y2], container: Hash } }, metadata: {})
        klass = Class.new do
          include Axn
          expects :foo, type: Hash
          expects :bar, on: :foo, type: Hash
          expects "bar.baz", on: :foo, type: Hash, shape: { members: [x1], container: Hash } # route 1: x -> y (Hash)
          expects :baz, on: :bar, type: Hash, shape: { members: [x2], container: Hash }      # route 2: x -> y (String)
          expects "x.y.z", on: :baz                                                          # implicit x, implicit y, leaf z
        end
        schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

        baz = schema.dig(:properties, :foo, :properties, :bar, :properties, :baz)
        expect(baz.dig(:properties, :x, :properties, :y, :properties, :z)).to be_nil # scalar y blocks the deep z
        dropped = described_class.dropped_deep_subfields(klass.internal_field_configs, klass.subfield_configs)
        expect(dropped.map(&:field)).to eq([:"x.y.z"]) # and it is warned, not silently gone
      end
    end

    describe "the same wire path declared via two routes" do
      it "builds the property from the first-declared config, unions requiredness, and intersects nullability" do
        klass = Class.new do
          include Axn
          expects :foo, type: Hash
          expects :bar, on: :foo, type: Hash
          expects "bar.baz", on: :foo, type: String, allow_nil: true # route 1: optional/nullable
          expects :baz, on: :bar, type: String # route 2: required, non-nullable
        end
        schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

        bar = schema[:properties][:foo][:properties][:bar]
        expect(bar[:required]).to eq(["baz"]) # union: route 2 requires it
        expect(bar[:properties][:baz][:type]).to eq("string") # intersection: null stripped (route 2 rejects nil)
      end

      # A merged node whose routes disagree on KIND: one is a plain object subfield, the other a `model:`
      # subfield. Emission must consult ALL configs (not just the first), emitting the model's `<leaf>_id`
      # AND the plain route's object property, each required per its OWN route — reading only `node.config`
      # (the first) would drop whichever kind wasn't declared first.
      describe "a model: route and a non-model route at the same node" do
        model = Struct.new(:id) do
          def self.find(id) = id.nil? ? nil : new(id)
        end
        before { stub_const("MergedRouteUser", model) }

        subject(:account) do
          klass = Class.new do
            include Axn
            expects :payload, type: Hash
            expects "account.user", on: :payload, type: Hash, optional: true # non-model route (first), optional
            expects :account, on: :payload, type: Hash
            expects :user, on: :account, model: { klass: MergedRouteUser, finder: :find } # model route (second), required
            def call = nil
          end
          described_class.build_input(klass.internal_field_configs, klass.subfield_configs)[:properties][:payload][:properties][:account]
        end

        it "emits the model's user_id (required, non-nullable) even though the model config is not first" do
          expect(account[:properties]).to have_key(:user_id)
          expect(account[:required]).to include("user_id")
          expect(account[:properties][:user_id]).to include(not: { type: "null" })
        end

        it "keeps the non-model route's user property and leaves it optional" do
          expect(account[:properties]).to have_key(:user)
          expect(Array(account[:required])).not_to include("user")
        end
      end

      it "runtime agreement: the merged model+non-model node resolves via user_id and rejects its omission" do
        stub_const("MergedRouteUser", Struct.new(:id) { def self.find(id) = id.nil? ? nil : new(id) })
        klass = Class.new do
          include Axn
          expects :payload, type: Hash
          expects "account.user", on: :payload, type: Hash, optional: true
          expects :account, on: :payload, type: Hash
          expects :user, on: :account, model: { klass: MergedRouteUser, finder: :find }
          def call = nil
        end

        expect(klass.call(payload: { account: { user_id: 7 } })).to be_ok       # model resolves via user_id
        expect(klass.call(payload: { account: { note: "x" } })).not_to be_ok    # omitted user_id strands the model
      end

      # The decision to NEST a merged node's children must consult ALL configs at the node, not just the
      # first non-model one, mirroring the drop pass's node_configs_block_nesting? check, which scans every
      # config. A merged
      # node with one nestable Hash route and one non-nestable mixed-union route cannot hold object
      # properties, so its deep child is dropped — and must NOT also be nested, or the input_schema warning
      # lies (claims omitted while it is present) and the outcome flips with declaration order.
      describe "nesting a merged node whose routes disagree on nestability" do
        it "drops the deep child and does not nest it (route 1 nestable declared first)" do
          klass = Class.new do
            include Axn
            expects :foo, type: Hash
            expects :bar, on: :foo, type: Hash
            expects "bar.baz", on: :foo, type: Hash         # route 1: nestable
            expects :baz, on: :bar, type: [Hash, Array]     # route 2: NON-nestable (mixed union)
            expects :qux, on: :baz, type: String
          end
          schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
          dropped = described_class.dropped_deep_subfields(klass.internal_field_configs, klass.subfield_configs)

          baz = schema.dig(:properties, :foo, :properties, :bar, :properties, :baz)
          expect(baz&.dig(:properties, :qux)).to be_nil      # not nested (a route rejects object nesting)
          expect(dropped.map(&:field)).to include(:qux)      # and warned as dropped — the two agree
        end

        it "reaches the same decision when the non-nestable route is declared first (order-invariant)" do
          klass = Class.new do
            include Axn
            expects :foo, type: Hash
            expects :bar, on: :foo, type: Hash
            expects :baz, on: :bar, type: [Hash, Array]     # route 2 FIRST
            expects "bar.baz", on: :foo, type: Hash         # route 1 SECOND
            expects :qux, on: :baz, type: String
          end
          schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
          dropped = described_class.dropped_deep_subfields(klass.internal_field_configs, klass.subfield_configs)

          baz = schema.dig(:properties, :foo, :properties, :bar, :properties, :baz)
          expect(baz&.dig(:properties, :qux)).to be_nil
          expect(dropped.map(&:field)).to include(:qux)
        end
      end

      # A merged model+non-model node's deep grandchild resolves off the model record at runtime (the
      # client sends `<leaf>_id`, not the object), so the drop pass omits it. Emission must not nest it
      # under the non-model route's object property either — the nesting gate consults every config, so a
      # model route at the node blocks nesting exactly as node_configs_block_nesting? does.
      it "does not nest a deep grandchild under a merged model+non-model node (agrees with dropped)" do
        stub_const("MergedRouteUser", Struct.new(:id) { def self.find(id) = id.nil? ? nil : new(id) })
        klass = Class.new do
          include Axn
          expects :payload, type: Hash
          expects "account.user", on: :payload, type: Hash, optional: true # non-model route (first)
          expects :account, on: :payload, type: Hash
          expects :user, on: :account, model: { klass: MergedRouteUser, finder: :find }, optional: true # model route
          # `name` carries a Proc default so the contract is legal under PRO-2889 (the nil-tolerant :user
          # model strands it otherwise); strict reflection ignores Procs, so the drop/nesting behavior is unchanged.
          expects :name, on: :user, type: String, default: -> { "x" } # deep grandchild
          def call = nil
        end
        schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
        dropped = described_class.dropped_deep_subfields(klass.internal_field_configs, klass.subfield_configs)

        user = schema.dig(:properties, :payload, :properties, :account, :properties, :user)
        expect(user&.dig(:properties, :name)).to be_nil # a model route sends user_id, not the object
        expect(dropped.map(&:field)).to include(:name)
      end
    end
  end

  # The schema's deep requiredness claims must AGREE with runtime outcomes (or diverge only in the
  # stricter direction). Each example asserts both sides against the same class.
  describe "runtime agreement for deep subfields" do
    it "required deep leaf with a Proc default: schema requires the chain (strict), the Proc rescues omission at runtime" do
      # `id` carries a Proc default so the contract is legal under PRO-2889 (satisfiability counts the Proc).
      # Strict reflection ignores Procs, so the schema still requires the whole chain, while the Proc rescues
      # an omitted/nil-meta call at runtime — the ALLOWED stricter divergence (schema never rejects a valid call).
      klass = Class.new do
        include Axn
        expects :payload, type: Hash, allow_nil: true
        expects :meta, on: :payload, type: Hash, optional: true
        expects :id, on: :meta, type: Integer, default: -> { 1 }
        def call = nil
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required]).to include("payload")
      expect(klass.call).to be_ok                                       # Proc default rescues omission
      expect(klass.call(payload: { meta: nil })).to be_ok               # Proc default rescues nil meta
      expect(klass.call(payload: { meta: { id: 7 } })).to be_ok
    end

    it "all-optional deep chain: schema omits requiredness, runtime accepts omission, nil parent, and full path" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash, allow_nil: true
        expects :zip, on: "payload.address", type: String, optional: true
        def call = nil
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required]).to be_nil
      expect(klass.call).to be_ok
      expect(klass.call(payload: nil)).to be_ok
      expect(klass.call(payload: { address: nil })).to be_ok
      expect(klass.call(payload: { address: { zip: "10001" } })).to be_ok
    end

    it "dotted field name: runtime digs the same path the schema advertises" do
      klass = Class.new do
        include Axn
        expects :foo, type: Hash
        expects "bar.baz", on: :foo, type: String
        def call = nil
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:properties][:foo][:properties][:bar][:required]).to eq(["baz"])
      expect(klass.call(foo: {})).not_to be_ok
      expect(klass.call(foo: { bar: {} })).not_to be_ok
      expect(klass.call(foo: { bar: { baz: "ok" } })).to be_ok
    end

    it "defaulted depth-1 parent with a required deep child: schema optional, runtime accepts omission (default materializes)" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash, allow_nil: true
        expects :meta, on: :payload, type: Hash, default: { id: 1 }
        expects :id, on: :meta, type: Integer
        def call = nil
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required]).to be_nil
      expect(klass.call).to be_ok
    end
  end

  # A deep subfield whose chain passes through a `model:` or non-object parent has no JSON-object
  # representation (PRO-2872 represents every OTHER deep chain). This query names exactly those
  # omitted configs so the caller can warn — it must NOT flag a represented (object-shaped) chain,
  # a shallow subfield, nor a subfield under the deliberately-excluded ambient_context parent.
  describe ".dropped_deep_subfields" do
    it "returns [] for the three deep forms under object-shaped parents (they are represented now)" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash
        expects :meta, on: :payload, type: Hash          # shallow — represented
        expects :id, on: :meta, type: Integer            # deep: subfield-of-subfield
        expects :deep, on: "payload.meta", type: String  # deep: dotted on:
        expects "bar.baz", on: :payload                  # deep: dotted field name
      end

      expect(described_class.dropped_deep_subfields(klass.internal_field_configs, klass.subfield_configs)).to eq([])
    end

    it "flags a deep subfield under a model: parent" do
      klass = Class.new do
        include Axn
        expects :user, model: { klass: Struct.new(:id, :profile), finder: :find }
        expects :name, on: "user.profile", type: String
      end

      dropped = described_class.dropped_deep_subfields(klass.internal_field_configs, klass.subfield_configs)
      expect(dropped.map(&:field)).to eq([:name])
    end

    it "flags a deep subfield under a non-object intermediate, regardless of declaration order" do
      # `:count` is Array-answerable (Array#count), so the segment is answerable at declaration; the deep path is
      # still dropped from the schema because it passes THROUGH the non-object Array intermediate.
      klass = Class.new do
        include Axn
        expects :payload, type: Hash
        expects :count, on: "payload.items", type: Integer
        expects :items, on: :payload, type: Array
      end

      dropped = described_class.dropped_deep_subfields(klass.internal_field_configs, klass.subfield_configs)
      expect(dropped.map(&:field)).to eq([:count])
    end

    it "returns [] when every subfield is a shallow child of a top-level field" do
      klass = Class.new do
        include Axn
        expects :address, type: Hash
        expects :city, on: :address, type: String
        expects :zip, on: :address, type: String
      end

      expect(described_class.dropped_deep_subfields(klass.internal_field_configs, klass.subfield_configs)).to eq([])
    end

    it "returns [] when there are no subfields at all" do
      klass = Class.new do
        include Axn
        expects :name, type: String
      end

      expect(described_class.dropped_deep_subfields(klass.internal_field_configs, klass.subfield_configs)).to eq([])
    end

    it "does not flag a shallow ambient_context subfield (its parent is intentionally excluded)" do
      klass = Class.new do
        include Axn
        expects :company, on: :ambient_context, type: Integer
        expects :limit, type: Integer, default: 20
      end

      expect(described_class.dropped_deep_subfields(klass.internal_field_configs, klass.subfield_configs)).to eq([])
    end
  end

  # PIN: exact input_schema Hashes captured from the pre-refactor (per-site recomputation) emission
  # logic, before PRO-2877 introduces a single bottom-up `{required, nullable}` derivation. This is a
  # pure consolidation refactor — computed once vs. recomputed at each emission site — so every one of
  # these Hashes must stay byte-identical after the derivation lands. One example per row of the
  # legal-contract table: object parent, model parent, `type: Array` parent, mixed union, a
  # representable deep chain, a defaulted subtree, nested shape members, and the shape-member
  # synthesis hazard (both a shallow and a deep dotted-name trigger).
  describe "single-pass derivation parity (PRO-2877)" do
    it "emits the same input_schema for a representable deep chain" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash
        expects :meta, on: :payload, type: Hash
        expects :id, on: "payload.meta", type: Integer
      end

      expect(klass.input_schema).to eq(
        type: "object",
        properties: {
          payload: {
            type: "object",
            properties: {
              meta: {
                type: "object",
                properties: { id: { type: "integer" } },
                required: ["id"],
              },
            },
            required: ["meta"],
          },
        },
        required: ["payload"],
      )
    end

    it "emits the same input_schema for a model: parent with a nested subfield" do
      klass = Class.new do
        include Axn
        expects :user, model: { klass: Struct.new(:id), finder: :find }
        expects :name, on: :user, type: String
      end

      schema = klass.input_schema
      expect(schema[:properties].keys).to eq([:user_id])
      expect(schema[:properties][:user_id]).to include(not: { type: "null" })
      expect(schema[:required]).to eq(["user_id"])
    end

    it "emits the same input_schema for a type: Array parent with a shape" do
      klass = Class.new do
        include Axn
        expects :items, type: Array do
          field :status, type: String
        end
      end

      expect(klass.input_schema).to eq(
        type: "object",
        properties: {
          items: {
            type: "array",
            items: {
              type: "object",
              properties: { status: { type: "string" } },
              required: ["status"],
            },
          },
        },
        required: ["items"],
      )
    end

    it "emits the same input_schema for a mixed-union (type: [Hash, Array]) parent with a subfield" do
      klass = Class.new do
        include Axn
        expects :payload, type: [Hash, Array]
        expects :length, on: :payload, type: Integer
      end

      expect(klass.input_schema).to eq(
        type: "object",
        properties: {
          payload: { anyOf: [{ type: "object" }, { type: "array" }] },
        },
        required: ["payload"],
      )
    end

    it "emits the same input_schema for a defaulted deep (dotted-name) subtree" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash
        expects "address.zip", on: :payload, default: "x"
      end

      expect(klass.input_schema).to eq(
        type: "object",
        properties: {
          payload: {
            type: "object",
            properties: {
              address: {
                type: %w[object null],
                properties: {
                  zip: { default: "x", not: { type: "null" } },
                },
              },
            },
          },
        },
        required: ["payload"],
      )
    end

    it "emits the same input_schema for nested shape members (member of a member)" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash do
          field :status, type: String
          field :meta, type: Hash do
            field :count, type: Integer
          end
        end
      end

      expect(klass.input_schema).to eq(
        type: "object",
        properties: {
          payload: {
            type: "object",
            properties: {
              status: { type: "string" },
              meta: {
                type: "object",
                properties: { count: { type: "integer" } },
                required: ["count"],
              },
            },
            required: %w[status meta],
          },
        },
        required: ["payload"],
      )
    end

    it "emits the same input_schema for the shape-member synthesis hazard: a nil-tolerant Hash parent " \
       "with a required do...end shape member plus a defaulted shallow on: subfield " \
       "(required_child?'s surviving second disjunct)" do
      # The parent Proc default keeps the contract legal under PRO-2889 (satisfiability counts the Proc as a
      # rescue) while strict reflection ignores Procs — the emitted schema is unchanged (Proc defaults are
      # never serialized, and the hazard still forces payload required + non-nullable).
      klass = Class.new do
        include Axn
        expects :payload, type: Hash, allow_nil: true, default: -> { {} } do
          field :status, type: String
        end
        expects :note, on: :payload, optional: true, type: String, default: "x"
      end

      expect(klass.input_schema).to eq(
        type: "object",
        properties: {
          payload: {
            type: "object",
            properties: {
              status: { type: "string" },
              note: { type: %w[string null], default: "x" },
            },
            required: ["status"],
          },
        },
        required: ["payload"],
      )
    end

    it "emits the same input_schema for the shape-member synthesis hazard triggered by a DEEP " \
       "(dotted-name) default" do
      # The parent Proc default keeps the contract legal under PRO-2889 (satisfiability counts the Proc as a
      # rescue) while strict reflection ignores Procs — the emitted schema is unchanged (Proc defaults are
      # never serialized, and the hazard still forces payload required + non-nullable).
      klass = Class.new do
        include Axn
        expects :payload, type: Hash, allow_nil: true, default: -> { {} } do
          field :status, type: String
        end
        expects "address.zip", on: :payload, default: "x"
      end

      expect(klass.input_schema).to eq(
        type: "object",
        properties: {
          payload: {
            type: "object",
            properties: {
              status: { type: "string" },
              address: {
                type: %w[object null],
                properties: {
                  zip: { default: "x", not: { type: "null" } },
                },
              },
            },
            required: ["status"],
          },
        },
        required: ["payload"],
      )
    end
  end

  describe "satisfiability mode (PRO-2889)" do
    it "counts a Proc default as a rescue only in satisfiability mode" do
      action = build_axn do
        expects :payload, type: Hash, allow_nil: true
        expects :id, on: :payload, type: Integer, default: -> { 1 }
        def call = nil
      end
      resolved = action._resolved_subfields
      id_node = resolved.roots[:payload].children[:id]

      strict = Axn::Reflection::Schema.derive_annotations(resolved.roots)
      sat    = Axn::Reflection::Schema.derive_annotations(resolved.roots, satisfiability: true)

      expect(strict[id_node].required).to be(true)   # schema: unknowable → required (safe direction)
      expect(sat[id_node].required).to be(false)     # detector: the Proc DOES apply at runtime
    end
  end

  describe "segment answerability predicates" do
    Cfg = Data.define(:validations) unless defined?(Cfg)

    describe ".branch_answers_segment?" do
      it "answers anything through :params, Hash (and subclasses), and untyped branches" do
        expect(described_class.branch_answers_segment?(:params, :anything)).to be(true)
        expect(described_class.branch_answers_segment?(Hash, :anything)).to be(true)
        expect(described_class.branch_answers_segment?(Class.new(Hash), :anything)).to be(true)
      end

      it "judges an exact builtin scalar by its public method surface" do
        expect(described_class.branch_answers_segment?(String, :length)).to be(true)
        expect(described_class.branch_answers_segment?(String, :baz)).to be(false)
        expect(described_class.branch_answers_segment?(Array, :count)).to be(true)
        expect(described_class.branch_answers_segment?(Array, :first_item)).to be(false)
      end

      it "maps :uuid to String and :boolean to TrueClass/FalseClass" do
        expect(described_class.branch_answers_segment?(:uuid, :length)).to be(true)
        expect(described_class.branch_answers_segment?(:uuid, :baz)).to be(false)
        expect(described_class.branch_answers_segment?(:boolean, :to_s)).to be(true)
        expect(described_class.branch_answers_segment?(:boolean, :baz)).to be(false)
      end

      it "is optimistic about non-Class branches and unknown/Data/Struct classes" do
        expect(described_class.branch_answers_segment?(Class.new, :anything)).to be(true)
        expect(described_class.branch_answers_segment?(Data.define(:x), :anything)).to be(true)
        expect(described_class.branch_answers_segment?(Struct.new(:x), :anything)).to be(true)
      end
    end

    describe ".config_answers_segment?" do
      it "is never refutable for a model: route" do
        cfg = Cfg.new(validations: { model: { klass: String }, type: { klass: String } })
        expect(described_class.config_answers_segment?(cfg, :baz)).to be(true)
      end

      it "answers when ANY declared branch answers (a union including Hash)" do
        cfg = Cfg.new(validations: { type: { klass: [Hash, String] } })
        expect(described_class.config_answers_segment?(cfg, :baz)).to be(true)
      end

      it "refutes when NO declared branch can answer the segment" do
        cfg = Cfg.new(validations: { type: { klass: String } })
        expect(described_class.config_answers_segment?(cfg, :baz)).to be(false)
      end

      it "treats an untyped config as object-shaped (answers anything)" do
        cfg = Cfg.new(validations: { presence: true })
        expect(described_class.config_answers_segment?(cfg, :baz)).to be(true)
      end
    end
  end

  describe "conditional validation (if:/unless:) reflection" do
    it "reflects a bare conditional field static-maximal (required, non-null) without executing the condition" do
      ran = false
      action = build_axn do
        expects :flag, type: :boolean
        expects :num, type: Integer, if: -> { ran = true }
      end
      schema = action.input_schema
      expect(schema[:required]).to include("num")
      expect(schema[:properties][:num][:type]).to eq("integer")
      expect(ran).to be false
    end

    it "keeps a tolerance-flagged conditional field optional (the static tolerance is unconditional)" do
      action = build_axn do
        expects :note, type: String, optional: true, if: :cond
      end
      schema = action.input_schema
      expect(schema[:required].to_a).not_to include("note")
      expect(schema[:properties][:note][:type]).to eq(%w[string null])
    end

    it "admits null on a gated exposes property (a closed gate can emit nil)" do
      action = build_axn do
        expects :flag, type: :boolean
        exposes :num, type: Integer, if: :flag
        def call; end
      end
      expect(action.output_schema[:properties][:num][:type]).to eq(%w[integer null])
    end

    it "reflects a gated shape member static-maximal (required inside its object)" do
      action = build_axn do
        expects :flag, type: :boolean
        expects :payload, type: Hash do
          field :note, type: String, if: :flag
        end
      end
      prop = action.input_schema[:properties][:payload]
      expect(prop[:required]).to include("note")
      expect(prop[:properties][:note][:type]).to eq("string")
    end
  end
end
