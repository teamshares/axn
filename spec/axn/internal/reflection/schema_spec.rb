# frozen_string_literal: true

require "spec_helper"

RSpec.describe Axn::Internal::Reflection::Schema do
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
      serialized = Axn::Extensions::Serialization.render(klass.call)
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
        expects :par, type: :params, default: {}
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
      expect(schema[:required] || []).not_to include("par")
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
    expect(Axn::Internal::Reflection::Values.serialize_value(Complex(1, 2))).to be_a(String)
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

    serialized = Axn::Extensions::Serialization.render(klass.call(w: 1))
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
    expect(strict_members).to include({ type: "string", format: "uuid", minLength: 1 })
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

  # A bare-Array inclusion (`inclusion: %w[a b c]`) is equivalent at runtime to `{ in: %w[a b c] }`, so
  # reflection must emit the same enum and infer the same type from its members (PRO-2944).
  describe "bare-Array inclusion shorthand reflects identically to the { in: } / { within: } long form" do
    it "emits the enum and infers the type for a bare-Array string inclusion" do
      klass = Class.new do
        include Axn
        expects :s, inclusion: %w[a b c]
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
      expect(schema[:properties][:s]).to include(type: "string", enum: %w[a b c])
    end

    it "infers an integer type from a bare-Array integer inclusion" do
      klass = Class.new do
        include Axn
        expects :s, inclusion: [1, 2]
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
      expect(schema[:properties][:s]).to include(type: "integer", enum: [1, 2])
    end

    it "reflects a bare-Array inclusion identically to the { in: } long form" do
      bare = Class.new do
        include Axn
        expects :s, inclusion: %w[a b c]
      end
      long = Class.new do
        include Axn
        expects :s, inclusion: { in: %w[a b c] }
      end
      bare_prop = described_class.build_input(bare.internal_field_configs, bare.subfield_configs)[:properties][:s]
      long_prop = described_class.build_input(long.internal_field_configs, long.subfield_configs)[:properties][:s]
      expect(bare_prop).to eq(long_prop)
    end

    # Frozen because a container that answers with its own code is only storable frozen (see
    # `Internal::ShapeGraph.detached_option_array`) — which is also the form that reaches reflection as the caller's own
    # object, so it is the sharp version of this check.
    it "does not run user traversal code for an Array-subclass inclusion set (reflects no enum)" do
      exploding_array = Class.new(Array) do
        def map(*) = raise("reflection must not traverse an Array subclass")
        def each(*) = raise("reflection must not traverse an Array subclass")
      end.new(%w[a b]).freeze
      klass = Class.new do
        include Axn
        expects :s, inclusion: exploding_array
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
      expect(schema[:properties][:s]).not_to have_key(:enum)
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

    it "leaves the <field>_id type unconstrained for a non-ActiveRecord class's default :find finder too " \
       "(PK may be integer, UUID, or string, and there is no primary key to infer it from)" do
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

  # PRO-3384: a declared `id_type:` types the generated `<field>_id` directly, for exactly the cases
  # inference (spec_rails/dummy_app, an ActiveRecord class) can't reach — a PORO model, a custom
  # finder, or a non-Rails consumer. It wins over inference unconditionally, and shares the SAME
  # accepted vocabulary (FieldConfig::MODEL_ID_TYPE_TOKENS) that inference's AR-type map projects onto.
  describe "model: id_type:" do
    it "types the generated id from a declared id_type:, on a PORO model with the default finder" do
      klass = Class.new do
        include Axn
        expects :lead, model: { klass: Struct.new(:id), id_type: Integer }
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:properties][:lead_id]).to include(type: "integer")
    end

    it "types the generated id as a uuid, format included, exactly like a declared type: :uuid field" do
      klass = Class.new do
        include Axn
        expects :doc, model: { klass: Struct.new(:id), id_type: :uuid }
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:properties][:doc_id]).to include(type: "string", format: "uuid")
    end

    it "honors id_type: even under a custom finder (the declared layer ignores the finder gate " \
       "inference is confined to)" do
      klass = Class.new do
        include Axn
        expects :company, model: { klass: Struct.new(:id), finder: :find_by_token, id_type: String }
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:properties][:company_id]).to include(type: "string")
    end

    it "admits null for an optional id_type:-typed id, and the required pass still strips it when required" do
      optional = Class.new do
        include Axn
        expects :doc, model: { klass: Struct.new(:id), id_type: Integer }, allow_nil: true
      end
      required = Class.new do
        include Axn
        expects :doc, model: { klass: Struct.new(:id), id_type: Integer }
      end

      optional_schema = described_class.build_input(optional.internal_field_configs, optional.subfield_configs)
      required_schema = described_class.build_input(required.internal_field_configs, required.subfield_configs)

      expect(optional_schema[:properties][:doc_id][:type]).to eq(%w[integer null])
      expect(Array(optional_schema[:required])).not_to include("doc_id")

      expect(required_schema[:properties][:doc_id]).to include(type: "integer")
      expect(required_schema[:properties][:doc_id]).not_to have_key(:not)
      expect(required_schema[:required]).to include("doc_id")
    end

    it "types a NESTED on: model subfield's generated id from id_type: too" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash
        expects :company, on: :payload, model: { klass: Struct.new(:id), id_type: Integer }
      end
      payload = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)[:properties][:payload]

      expect(payload[:properties][:company_id]).to include(type: "integer")
    end

    it "rejects an id_type: outside the closed vocabulary at declaration time" do
      expect do
        Class.new do
          include Axn
          expects :company, model: { klass: Struct.new(:id), id_type: Hash }
        end
      end.to raise_error(ArgumentError, /id_type:.*must be one of/)
    end

    it "rejects a union id_type: (a lookup token is a scalar, never a list of them)" do
      expect do
        Class.new do
          include Axn
          expects :company, model: { klass: Struct.new(:id), id_type: [Integer, String] }
        end
      end.to raise_error(ArgumentError, /id_type:.*must be one of/)
    end

    it "keeps the declared and inferable vocabularies from drifting apart" do
      inferable = Axn::Internal::Reflection::Schema::AR_PRIMARY_KEY_TYPE_TOKENS.values
      declarable = Axn::Internal::FieldConfig::MODEL_ID_TYPE_TOKENS

      expect(inferable.uniq).to match_array(declarable)
    end

    # Codex review round 1 (PR #269): an explicit `<field>_id` sibling ALWAYS wins the emitted property
    # over the model-generated one (declaration-order independent — tested above), so a declared
    # `id_type:` that disagrees with the sibling's own `type:` was being silently discarded rather than
    # flagged as the authored contradiction it is.
    describe "conflicting with an explicit <field>_id sibling's own type:" do
      it "rejects id_type: Integer beside an explicit type: String sibling" do
        klass = Class.new do
          include Axn
          expects :company_id, type: String
          expects :company, model: { klass: Struct.new(:id), id_type: Integer }
        end

        expect do
          described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
        end.to raise_error(ArgumentError, /id_type:.*disagrees with the explicitly declared company_id/)
      end

      it "rejects it regardless of declaration order (explicit sibling declared first)" do
        klass = Class.new do
          include Axn
          expects :company, model: { klass: Struct.new(:id), id_type: Integer }
          expects :company_id, type: String
        end

        expect do
          described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
        end.to raise_error(ArgumentError, /id_type:.*disagrees/)
      end

      it "rejects it for a nested on: model subfield too" do
        klass = Class.new do
          include Axn
          expects :payload, type: Hash
          expects :company_id, on: :payload, type: String
          expects :company, on: :payload, model: { klass: Struct.new(:id), id_type: Integer }
        end

        expect do
          described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
        end.to raise_error(ArgumentError, /id_type:.*disagrees/)
      end

      it "does not raise when the two agree" do
        klass = Class.new do
          include Axn
          expects :company_id, type: Integer
          expects :company, model: { klass: Struct.new(:id), id_type: Integer }
        end

        expect(klass.input_schema[:properties][:company_id]).to include(type: "integer")
      end

      it "does not raise for a merely COMPATIBLE pairing (id_type: String beside an explicit :uuid " \
         "sibling — both project to the JSON type \"string\")" do
        klass = Class.new do
          include Axn
          expects :company_id, type: :uuid
          expects :company, model: { klass: Struct.new(:id), id_type: String }
        end

        expect(klass.input_schema[:properties][:company_id]).to include(type: "string", format: "uuid")
      end

      it "does not raise when the explicit sibling has no type: of its own to disagree with, and " \
         "merges the declared id_type: into the sibling's own property rather than losing it" do
        klass = Class.new do
          include Axn
          expects :company_id, default: 1
          expects :company, model: { klass: Struct.new(:id), id_type: Integer }
        end

        expect(klass.input_schema[:properties][:company_id]).to eq(default: 1, type: "integer")
      end

      it "does the same merge for a NESTED untyped sibling, regardless of which is declared first " \
         "(the sibling's OWN entry always wins the emitted property outright, so the merge has to run " \
         "after every child in the loop has been visited, not at the model's own visit)" do
        declared_model_first = Class.new do
          include Axn
          expects :payload, type: Hash, shape: { members: {} }
          expects :company, on: :payload, model: { klass: Struct.new(:id), id_type: Integer }
          expects :company_id, on: :payload, default: 1, as: :company_id_field
        end
        declared_sibling_first = Class.new do
          include Axn
          expects :payload, type: Hash, shape: { members: {} }
          expects :company_id, on: :payload, default: 1, as: :company_id_field
          expects :company, on: :payload, model: { klass: Struct.new(:id), id_type: Integer }
        end

        [declared_model_first, declared_sibling_first].each do |klass|
          company_id = klass.input_schema.dig(:properties, :payload, :properties, :company_id)
          expect(company_id).to eq(default: 1, type: "integer")
        end
      end

      it "drops the sibling's own now-redundant not: { type: \"null\" } once a real type: is merged in " \
         "(reject_null! already ran on the untyped sibling before this merge and, finding no type: to " \
         "narrow, fell back to that marker)" do
        klass = Class.new do
          include Axn
          expects :payload, type: Hash, shape: { members: {} }
          expects :company, on: :payload, model: { klass: Struct.new(:id), id_type: Integer }
          expects :company_id, on: :payload, default: 1, as: :company_id_field
        end

        company_id = klass.input_schema.dig(:properties, :payload, :properties, :company_id)
        expect(company_id).not_to have_key(:not)
        expect(company_id[:type]).to eq("integer")
      end

      # Codex review round 3 (PR #269): comparing base :type alone missed the REVERSE asymmetry —
      # id_type: :uuid asserts a format the plain explicit type: String sibling does not carry, so the
      # uuid-shape requirement silently vanished with no error, the same swallowed-contradiction class
      # the round-1 fix existed to close.
      it "rejects id_type: :uuid beside an explicit type: String sibling (the sibling admits any " \
         "string, silently dropping the uuid-format requirement)" do
        klass = Class.new do
          include Axn
          expects :company_id, type: String
          expects :company, model: { klass: Struct.new(:id), id_type: :uuid }
        end

        expect { klass.input_schema }.to raise_error(ArgumentError, /id_type:.*disagrees/)
      end

      # Codex review round 18 (PR #269): the round-3 rule above is right for a BARE type: String
      # sibling — but a sibling narrowed by its OWN inclusion: to uuid-shaped literals is not the same
      # "admits any string" case, and the plain type-pair comparison alone can't see that (it reads only
      # :type/:anyOf, never :enum). An explicit type: String sitting beside the SAME inclusion: made the
      # check treat the pairing as STRICTER than a bare inclusion: sibling with no type: at all — which
      # already tolerates this (see the enum-only branch's documented known limitation, just above) — so
      # this raised for a value-level-compatible declaration purely because a type: was also present.
      it "does not reject id_type: :uuid beside an explicit type: String, inclusion: [uuid-shaped " \
         "literal] sibling — an inclusion: set is checked on its own terms, the same tolerance the " \
         "enum-only case already gets, whether or not an explicit type: also sits beside it" do
        klass = Class.new do
          include Axn
          expects :company_id, type: String, inclusion: { in: ["0f8fad5b-d9cb-469f-a165-70867728950e"] }
          expects :company, model: { klass: Struct.new(:id), id_type: :uuid }
        end

        expect { klass.input_schema }.not_to raise_error
      end

      # Codex review round 4 (PR #269): the "any branch satisfies" check let a widening UNION sibling
      # through, since the branch that happened to match id_type: was enough to accept the whole thing
      # — but the WINNING property is the entire union, including the branch that doesn't satisfy it.
      it "rejects id_type: Integer beside an explicit union type: [Integer, String] sibling (one " \
         "branch matches, but the whole union — including the string branch — is what wins, silently " \
         "widening past what id_type: promised)" do
        klass = Class.new do
          include Axn
          expects :company_id, type: [Integer, String]
          expects :company, model: { klass: Struct.new(:id), id_type: Integer }
        end

        expect { klass.input_schema }.to raise_error(ArgumentError, /id_type:.*disagrees/)
      end

      it "does not raise for a union sibling where EVERY branch still satisfies id_type: (both " \
         "project to \"string\")" do
        klass = Class.new do
          include Axn
          expects :company_id, type: [String, :uuid]
          expects :company, model: { klass: Struct.new(:id), id_type: String }
        end

        expect(klass.input_schema[:properties][:company_id][:anyOf]).to contain_exactly(
          { type: "string", minLength: 1 },
          { type: "string", format: "uuid", minLength: 1 },
        )
      end
    end

    # Codex review round 3 (PR #269): a merged wire node reached by TWO `model:` routes (a dotted
    # `on:` path and a nested subfield resolving to the same wire path — `as:` disambiguates their
    # shared reader name so they still merge, the same construction schema_spec's own "merged node"
    # examples use elsewhere in this file) each carry their own `id_type:`, but only `model_configs.first`
    # was ever consulted — silently dropping whichever route was declared second, and changing the
    # answer with declaration order.
    describe "reconciling id_type: across multiple model: routes at one merged node" do
      it "rejects two model: routes at the same node declaring disagreeing id_type: values" do
        klass = Class.new do
          include Axn
          expects :payload, type: Hash
          expects :user, on: "payload.account", model: { klass: Struct.new(:id), id_type: Integer }, as: :user_route1
          expects :account, on: :payload, type: Hash
          expects :user, on: :account, model: { klass: Struct.new(:id), id_type: String }
        end

        expect { klass.input_schema }.to raise_error(ArgumentError, /disagree.*user_id/)
      end

      it "does not raise, and reconciles to the single value, when only one route declares id_type:" do
        klass = Class.new do
          include Axn
          expects :payload, type: Hash
          expects :user, on: "payload.account", type: Hash, optional: true, as: :user_nonmodel
          expects :account, on: :payload, type: Hash
          expects :user, on: :account, model: { klass: Struct.new(:id), id_type: Integer }
        end

        account = klass.input_schema[:properties][:payload][:properties][:account]
        expect(account[:properties][:user_id]).to include(type: "integer")
      end

      it "does not raise when both routes declare the SAME id_type:" do
        klass = Class.new do
          include Axn
          expects :payload, type: Hash
          expects :user, on: "payload.account", model: { klass: Struct.new(:id), id_type: Integer }, as: :user_route1
          expects :account, on: :payload, type: Hash
          expects :user, on: :account, model: { klass: Struct.new(:id), id_type: Integer }
        end

        account = klass.input_schema[:properties][:payload][:properties][:account]
        expect(account[:properties][:user_id]).to include(type: "integer")
      end
    end

    # Codex review round 10 (PR #269): a `shape:` member on the PARENT — declared via a `do...end`
    # block, not a subfield — can ALSO claim the generated `<field>_id` key by name. It's merged into
    # `prop[:properties]` by `apply_structured_schema!`, entirely BEFORE `apply_children!` (and so this
    # conflict check) ever runs, and outside the subfield tree `children` searches at all — so the
    # explicit-sibling lookup found nothing, the check never ran, and the shape member's `||=`-preserved
    # property silently discarded a declared `id_type:`.
    it "rejects a PARENT shape: member sharing the generated id's name, which the subfield-tree " \
       "lookup alone would miss entirely" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash do
          field :company_id, type: String
        end
        expects :company, on: :payload, model: { klass: Struct.new(:id), id_type: Integer }
      end

      expect { klass.input_schema }.to raise_error(ArgumentError, /id_type:.*disagrees/)
    end

    it "does not raise when a parent shape: member sharing the id's name agrees with the declared id_type:" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash do
          field :company_id, type: Integer
        end
        expects :company, on: :payload, model: { klass: Struct.new(:id), id_type: Integer }
      end

      payload = klass.input_schema[:properties][:payload]
      expect(payload[:properties][:company_id]).to include(type: "integer")
    end

    # Codex review round 11 (PR #269): at a MERGED parent node (two routes reaching the same wire path —
    # `as:` disambiguates their shared reader, the same construction this file's own "merged node"
    # examples use elsewhere), `apply_structured_schema!` merges a shape member into the emitted
    # property ONLY from the representative (first non-model) route — a member on a LATER, non-
    # representative route never reaches `prop[:properties]` at all. Searching every route
    # (`shape_members_at` alone) found a member that was never actually emitted, so the check believed
    # something had already claimed the key while nothing had: the model's own property was skipped in
    # favor of it, but nothing replaced it — `company_id` ended up `required` with no matching entry in
    # `properties`, JSON Schema admitting any value there.
    it "ignores a shape: member on a NON-representative route at a merged parent node — it never " \
       "reaches the emitted property, so it must not suppress the model's own generated id" do
      klass = Class.new do
        include Axn
        expects :root, type: Hash
        expects :sub, on: :root, type: Hash
        expects :payload, on: "root.sub", type: Hash, as: :payload_route1
        expects :payload, on: :sub, type: Hash do
          field :company_id, type: String
        end
        expects :company, on: :payload, model: { klass: Struct.new(:id), id_type: Integer }
      end

      payload = klass.input_schema.dig(:properties, :root, :properties, :sub, :properties, :payload)
      expect(payload[:properties][:company_id]).to include(type: "integer")
      expect(payload[:required]).to include("company_id")
    end

    # Codex review round 10 (PR #269): an `inclusion:` set's members are the AUTHOR'S OWN literals, and
    # one whose `inspect` raises would replace this ArgumentError with its own exception while the
    # message describing the conflict was still being built.
    it "renders a hostile enum literal (raising #inspect) safely rather than crashing the message itself" do
      hostile = Object.new
      def hostile.inspect = raise "hostile inspect ran"

      expect do
        Class.new do
          include Axn
          expects :company_id, inclusion: { in: [1, hostile] }
          expects :company, model: { klass: Struct.new(:id), id_type: Integer }
        end.input_schema
      end.to raise_error(ArgumentError, /disagrees.*enum/)
    end

    # Codex review round 5 (PR #269): `json_type_pairs` strips the `null` branch before comparing (see
    # `reject_model_id_type_conflict!`), so a sibling whose type is NilClass-only reduced to an empty
    # set — and a bare `.all?` on that empty set is vacuously true, letting a null-only sibling silently
    # win over a declared `id_type:` with no error at all.
    it "rejects a null-only explicit sibling (type: NilClass) beside a declared id_type: — a lookup " \
       "token can never be null, so nothing about the sibling actually satisfies the claim" do
      klass = Class.new do
        include Axn
        expects :company_id, type: NilClass, optional: true
        expects :company, model: { klass: Struct.new(:id), id_type: Integer }
      end

      expect { klass.input_schema }.to raise_error(ArgumentError, /id_type:.*disagrees/)
    end

    # Codex review round 16 (PR #269): the round-5 rule above is right when the model itself REQUIRES a
    # real id (verified: `.call` with no args raises there, so the id genuinely can never be supplied) —
    # but the same null-only sibling is not a conflict at all when the model ALSO tolerates nil
    # throughout (`allow_nil: true`): verified `.call` succeeds both with the id omitted and with it
    # explicitly nil, so nothing the declared `id_type:` asserts is ever actually contradicted.
    it "does not raise a null-only explicit sibling beside a declared id_type: when the model ALSO " \
       "tolerates nil throughout — a genuinely callable pairing, not a swallowed contradiction" do
      klass = Class.new do
        include Axn
        expects :company_id, type: NilClass, optional: true
        expects :company, model: { klass: Struct.new(:id), id_type: Integer }, allow_nil: true
      end

      expect { klass.input_schema }.not_to raise_error
      expect(klass.input_schema[:properties][:company_id]).to eq(type: "null")
    end

    # Codex review round 17 (PR #269): the merged type must not resurrect a null branch the
    # required-id null pass already stripped. An untyped `allow_nil:` sibling beside a REQUIRED
    # (non-nilable) model merges as `type: ["integer", "null"]` on the SIBLING's own nullability, but
    # the id is required by the MODEL, and a required nested model id can never actually resolve from
    # nil at runtime (verified: `.call(payload: { company_id: nil })` fails). The merge has to run
    # BEFORE the required-null pass so that pass gets the last, correct word — not after, where it
    # would silently widen a required property past what runtime accepts.
    it "does not let a nested untyped allow_nil: sibling reintroduce a null branch the required-id " \
       "null pass already removed (the model itself is required, not the sibling)" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash, shape: { members: {} }
        expects :company, on: :payload, model: { klass: Struct.new(:id), id_type: Integer }
        expects :company_id, on: :payload, allow_nil: true, as: :company_id_field
      end

      schema = klass.input_schema.dig(:properties, :payload)
      expect(schema[:properties][:company_id]).to eq(type: "integer")
      expect(schema[:required]).to include("company_id")
    end

    # Codex review round 7 (PR #269): comparing against `json_type_for` alone missed a RUNTIME
    # relaxation `build_property` applies afterward — a blank-tolerant explicit `type: :uuid` sibling
    # still projects `format: "uuid"` through `json_type_for` alone, so the check saw "satisfies" and
    # passed, but the ACTUAL winning property (built through `apply_single_type!`, which drops the uuid
    # format for a blank-tolerant field per its own documented reasoning) silently lost the format —
    # exactly the class of swallowed contradiction every earlier round's fix here already closed for
    # other shapes.
    it "rejects a blank-tolerant explicit type: :uuid sibling beside a required id_type: :uuid (the " \
       "sibling's OWN blank-tolerance drops its uuid format at emission, so the winning property " \
       "silently admits \"\" though the required model resolution never would)" do
      klass = Class.new do
        include Axn
        expects :company_id, type: :uuid, allow_blank: true
        expects :company, model: { klass: Struct.new(:id), id_type: :uuid }
      end

      expect { klass.input_schema }.to raise_error(ArgumentError, /id_type:.*disagrees/)
    end

    it "does not raise for a blank-tolerant explicit type: :uuid sibling beside an id_type: String " \
       "(String never asserted a format to lose)" do
      klass = Class.new do
        include Axn
        expects :company_id, type: :uuid, allow_blank: true
        expects :company, model: { klass: Struct.new(:id), id_type: String }
      end

      schema = klass.input_schema
      expect(schema[:properties][:company_id][:type]).to include("string")
      expect(schema[:properties][:company_id]).not_to have_key(:format)
    end

    # Codex review round 7 (PR #269): the generated `<field>_id` Symbol was interpolated raw into this
    # message's own UTF-8 text — a legal, ASCII-compatible but non-UTF-8 field name (a Latin-1 Symbol)
    # raised Encoding::CompatibilityError from the MESSAGE ITSELF, replacing the intended, actionable
    # ArgumentError with an unrelated crash.
    it "renders a non-UTF-8 (but ASCII-compatible) field name safely rather than crashing the message itself" do
      name = "caf\xE9".dup.force_encoding("ISO-8859-1").to_sym

      expect do
        Class.new do
          include Axn
          expects name, model: { klass: Struct.new(:id), id_type: Integer }
          expects :"#{name}_id", type: String
        end.input_schema
      end.to raise_error(ArgumentError, /disagrees/)
    end

    # Codex review round 8 (PR #269): gating the comparison on `explicit_id.validations.key?(:type)`
    # skipped a sibling that carries no `type:` at all but still gets one INFERRED by `inclusion:`/
    # `numericality:` (the same `json_type_for` branches `build_property` itself reads) — so the winning
    # property (a plain string, `inclusion:`-derived) silently discarded a declared `id_type: Integer`
    # with no error, the very thing the round-1 fix exists to catch.
    it "rejects an explicit sibling with no type: of its own whose OTHER validator (inclusion:) still " \
       "makes build_property infer a conflicting type" do
      klass = Class.new do
        include Axn
        expects :company_id, inclusion: { in: ["abc"] }
        expects :company, model: { klass: Struct.new(:id), id_type: Integer }
      end

      expect { klass.input_schema }.to raise_error(ArgumentError, /id_type:.*disagrees/)
    end

    # Codex review round 9 (PR #269): a HETEROGENEOUS `inclusion:` set (mixed value types) can't reduce
    # to one base type at all, so `json_type_for` emits `enum:` alone — neither `:type` nor `:anyOf` —
    # which the round-8 fix's gate didn't check, letting a declared `id_type: Integer` silently lose to
    # a sibling whose enum admits a String literal too.
    it "rejects an explicit sibling whose HETEROGENEOUS inclusion: set emits only enum: (no derivable " \
       "type at all), when a literal violates the declared id_type:" do
      klass = Class.new do
        include Axn
        expects :company_id, inclusion: { in: [1, "abc"] }
        expects :company, model: { klass: Struct.new(:id), id_type: Integer }
      end

      expect { klass.input_schema }.to raise_error(ArgumentError, /id_type:.*disagrees.*enum/)
    end

    it "does not raise for an enum-only sibling whose every literal matches the declared id_type:" do
      klass = Class.new do
        include Axn
        expects :company_id, inclusion: { in: %w[a b] }
        expects :company, model: { klass: Struct.new(:id), id_type: String }
      end

      expect(klass.input_schema[:properties][:company_id][:enum]).to eq(%w[a b])
    end

    it "names the base :type, not :enum, in the message when a sibling carries BOTH (a homogeneous " \
       "single-value inclusion: still derives a :type; the verdict came from comparing IT, not the " \
       "coincidental enum)" do
      klass = Class.new do
        include Axn
        expects :company_id, inclusion: { in: ["abc"] }
        expects :company, model: { klass: Struct.new(:id), id_type: Integer }
      end

      expect { klass.input_schema }.to raise_error(ArgumentError, /\(string\)/)
    end

    # (The companion "no type at all" case — a bare `default:` sibling that infers nothing — is already
    # covered above by "does not raise when the explicit sibling has no type: of its own to disagree
    # with"; re-verified passing unchanged by this round's fix, not duplicated here.)

    # Codex review round 8 (PR #269): `id_type:` types the generated `<field>_id` `expects` builds on
    # the INPUT schema; `exposes` never generates one at all (output reflects the exposed value itself),
    # so `id_type:` there was accepted at declaration and then silently did nothing.
    it "rejects id_type: on an exposes model: declaration — there is no generated <field>_id on output " \
       "for it to type" do
      expect do
        Class.new do
          include Axn
          exposes :user, model: { klass: Struct.new(:id), id_type: Integer }
        end
      end.to raise_error(ArgumentError, /exposes.*does not support model: id_type:/)
    end

    it "still allows model: on exposes without id_type:" do
      expect do
        Class.new do
          include Axn
          exposes :user, model: { klass: Struct.new(:id) }
        end
      end.not_to raise_error
    end

    # Codex review round 1 (PR #269): an explicit sibling always wins, so building the model's OWN
    # property (and, for an ActiveRecord class, dispatching into it to infer the id's type) is wasted
    # work whenever one exists — verified here with a token whose inference methods raise if reached;
    # the AR-specific case (a real primary_key/type_for_attribute call that must never run) lives in
    # spec_rails/dummy_app/spec/axn/internal/reflection/model_id_type_spec.rb.
    describe "skips id_type inference entirely when an explicit sibling will win" do
      it "never calls model_id_type_token for the discarded property, top-level" do
        klass = Class.new do
          include Axn
          expects :company_id, type: String
          expects :company, model: { klass: Struct.new(:id) }
        end

        expect(described_class).not_to receive(:model_id_type_token)
        klass.input_schema
      end

      it "never calls model_id_type_token for the discarded property, nested" do
        klass = Class.new do
          include Axn
          expects :payload, type: Hash
          expects :company_id, on: :payload, type: String
          expects :company, on: :payload, model: { klass: Struct.new(:id) }
        end

        expect(described_class).not_to receive(:model_id_type_token)
        klass.input_schema
      end

      it "still calls it when no explicit sibling exists (baseline sanity)" do
        klass = Class.new do
          include Axn
          expects :company, model: { klass: Struct.new(:id) }
        end

        expect(described_class).to receive(:model_id_type_token).and_call_original
        klass.input_schema
      end
    end

    # Codex review round 2 (PR #269): the "an explicit sibling will win" skip above matched ANY field
    # config named `<field>_id`, including one that is ITSELF a `model:` field — but such a config never
    # writes to that wire key at all (it emits its OWN generated id one level deeper,
    # `<field>_id_id`), so treating it as "something will provide this property" left the FIRST
    # model's id in `required` with no matching property at all — an invalid, previously-untyped-but-at-
    # least-PRESENT schema regressed to entirely absent.
    describe "a model field's generated id sharing a name with ANOTHER model field (not an explicit sibling)" do
      it "still emits company_id's own generated property when company_id is itself a model: field" do
        klass = Class.new do
          include Axn
          expects :company, model: { klass: Struct.new(:id) }
          expects :company_id, model: { klass: Struct.new(:id) }
        end
        schema = klass.input_schema

        expect(schema[:properties]).to have_key(:company_id)
        expect(schema[:properties]).to have_key(:company_id_id)
        expect(schema[:required]).to include("company_id", "company_id_id")
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

    # A shape member's name is symbolized at declaration (`field "bar"` stores `:bar`, as a top-level field
    # name does), and its emitted property keys by symbol to match — every other schema property key
    # (top-level config.field, symbolized wire keys, implicit intermediates) is a Symbol. A string key would
    # leave a duplicate alongside the symbol key a colliding subfield writes, which collide unpredictably in
    # JSON. These examples pin the emitted keys, so they hold either way; the normalization is what makes the
    # declaration guard and this output agree by construction rather than by parallel conversion.
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
          expects :baz, on: "payload.bar", type: String
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
      expect(Axn::Extensions::Serialization.render(klass.call)["cfg"]).to eq({ "name" => "x" })
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

    # The visibility rule is per-METHOD, and these two cases are why. Both describe a NON-PUBLIC override; they
    # reach opposite verdicts because the two serializers are reached differently — verified by serializing each
    # in both environments (with and without ActiveSupport's json core_ext), which change the mechanism but not
    # the verdict.
    %i[protected private].each do |visibility|
      # `as_json` is reached by DISPATCH — `projection_for` gates on `respond_to?` — so a non-public override
      # cannot be called at all: the value falls through to the public built-in `to_h` and what is emitted IS
      # keyed by the declared members. Blocking here would drop `type: object` from a schema the serializer
      # honours, which is an over-rejection rather than a missed one.
      it "still advertises object OUTPUT when an as_json override is #{visibility} (it cannot be dispatched)" do
        hidden = Struct.new(:name) do
          def as_json(*) = "scalar"
          send(visibility, :as_json)
        end
        klass = Class.new do
          include Axn
          exposes(:cfg, type: hidden) { field :name, type: String }
          def call = nil
        end

        # The runtime fact the schema has to agree with: still member-keyed.
        serialized = Axn::Internal::Reflection::Values.serialize_value(hidden.new("x"), path: "cfg")
        expect(serialized).to eq({ "name" => "x" })

        expect(described_class.build_output(klass.external_field_configs)[:properties][:cfg][:type]).to eq("object")
      end

      # `to_h` is the FALLBACK, and an override at any visibility SHADOWS `Struct#to_h`, so the built-in is gone
      # regardless: without the core_ext the value degrades to `to_s`, and with it `Struct#as_json` is
      # `to_h.as_json` — an implicit-receiver call, which reaches a non-public override — so the override's own
      # keys are emitted. Neither is keyed by the declared members, so advertising an object is the mismatch
      # `serializable_shape?` exists to prevent.
      #
      # Both visibilities, because the two obvious readers each miss one: `method_defined?` sees protected but
      # not private, `public_method_defined?` neither.
      it "does not advertise object OUTPUT for a Struct whose to_h override is #{visibility}" do
        hidden = Struct.new(:name) do
          def to_h = { custom: true }
          send(visibility, :to_h)
        end
        klass = Class.new do
          include Axn
          exposes(:cfg, type: hidden) { field :name, type: String }
          def call = nil
        end

        # Stated so it holds in both environments: whatever is emitted, it is not an object carrying the
        # declared member.
        serialized = Axn::Internal::Reflection::Values.serialize_value(hidden.new("x"), path: "cfg")
        expect(serialized.is_a?(Hash) && serialized.key?("name")).to be(false)

        out = described_class.build_output(klass.external_field_configs)[:properties][:cfg]
        expect(out).not_to have_key(:type)
      end
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

  # `of:` names what is inside a container, and on a Hash that is two axes. Only the VALUES axis has a JSON
  # Schema spelling: `additionalProperties` constrains every value the object carries. The keys axis emits
  # nothing at all — every JSON object key is a string, so `keys: String` would say nothing a client can act
  # on and `keys: Symbol` would be a lie on the wire.
  describe "Hash containers (maps)" do
    def input_property(field, &declaration)
      klass = build_axn(&declaration)
      described_class.build_input(klass.internal_field_configs, klass.subfield_configs)[:properties][field]
    end

    it "emits the values axis as additionalProperties" do
      prop = input_property(:counts) { expects :counts, type: Hash, of: { values: Integer } }

      expect(prop).to include(type: "object", additionalProperties: { type: "integer" })
    end

    # The same `anyOf` a union `of:` element type reflects as, one rung down: the two containers share the
    # builder, so a union reads the same whichever side of the map/array line it is declared on.
    it "emits a union values axis as anyOf branches under additionalProperties" do
      prop = input_property(:counts) { expects :counts, type: Hash, of: { values: [String, Integer] } }

      expect(prop[:additionalProperties]).to eq(anyOf: [{ type: "string" }, { type: "integer" }])
    end

    it "emits a Data values type's own members under additionalProperties" do
      point = Data.define(:x, :y)
      prop = input_property(:points) { expects :points, type: Hash, of: { values: point } }

      expect(prop[:additionalProperties]).to eq(type: "object", properties: { x: {}, y: {} })
    end

    it "emits nothing for the keys axis, and still emits the values axis beside it" do
      prop = input_property(:counts) { expects :counts, type: Hash, of: { keys: Symbol, values: Integer } }

      expect(prop).not_to have_key(:propertyNames)
      expect(prop[:additionalProperties]).to eq(type: "integer")
    end

    # A keys-only map constrains no value, so there is nothing for `additionalProperties` to say: emitting an
    # empty one would read as a constraint the declaration never made.
    it "emits no additionalProperties for a keys-only map" do
      prop = input_property(:counts) { expects :counts, type: Hash, of: { keys: Symbol } }

      expect(prop).not_to have_key(:additionalProperties)
      expect(prop[:type]).to eq("object")
    end

    # An axis naming an EMPTY union constrains exactly what an absent one does: `matches_axis?` waves every
    # value through when the axis names no class. So there is no schema to emit for it — the declaration is
    # refused outright, and a map whose axes name nothing never reaches the emitter.
    it "never reaches the emitter with a values axis naming an empty union" do
      expect { input_property(:counts) { expects :counts, type: Hash, of: { values: [] } } }
        .to raise_error(ArgumentError, /\Aof: values: names an empty union/)
    end

    it "still emits additionalProperties for a nil-allowed map, whose type is the [\"object\", \"null\"] pair" do
      prop = input_property(:counts) { expects :counts, type: Hash, of: { values: Integer }, allow_nil: true }

      expect(prop[:type]).to eq(%w[object null])
      expect(prop[:additionalProperties]).to eq(type: "integer")
    end

    it "emits it for a map declared as a shape member too" do
      klass = build_axn do
        expects :order, type: Hash do
          field :counts, type: Hash, of: { values: Integer }
        end
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema.dig(:properties, :order, :properties, :counts, :additionalProperties)).to eq(type: "integer")
    end

    it "takes the same path on output" do
      klass = build_axn do
        exposes :counts, type: Hash, of: { values: Integer }
        def call = expose(counts: {})
      end
      prop = described_class.build_output(klass.external_field_configs)[:properties][:counts]

      expect(prop[:additionalProperties]).to eq(type: "integer")
    end

    # Output goes through `effective_validations` like every other constraint: a per-validator gate can skip
    # the `of:` check on a given call, so the values it would have constrained cannot be promised outbound.
    it "emits nothing on output for a map whose of: entry carries a gate of its own" do
      klass = build_axn do
        exposes :counts, optional: true, type: Hash, of: { values: Integer, if: :flag }
        def call = nil
      end
      prop = described_class.build_output(klass.external_field_configs)[:properties][:counts]

      expect(prop).not_to have_key(:additionalProperties)
    end
  end

  # PRO-2917 (archived not-reproducible): a self-referential Data.define type does NOT overflow the
  # stack — the type-boundary expansion is one level deep (`klass.members.to_h { |m| [m, {}] }`), so a
  # self-reference collapses to a permissive `{}` placeholder rather than recursing. This guards that
  # invariant: if anyone later makes type-class expansion deep, these terminate-and-truncate assertions
  # break loudly, resurfacing the cycle-guard question deliberately instead of silently overflowing.
  describe "self-referential Data.define types terminate (PRO-2917)" do
    it "reflects a directly self-referential type as a one-level placeholder on input and output" do
      node = Data.define(:value, :children)
      klass = Class.new do
        include Axn
        expects :root, type: node do
          field :value, type: Integer
          field :children, type: Array, of: node
        end
        exposes :root, type: node do
          field :value, type: Integer
          field :children, type: Array, of: node
        end
        def call = nil
      end

      input = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
      output = described_class.build_output(klass.external_field_configs)

      # The self-reference is truncated one level down on BOTH paths: the nested `children` is a bare
      # `{}`, not a re-expanded object — proof the walk stops at the type boundary rather than recursing.
      input_items = input[:properties][:root][:properties][:children][:items]
      output_items = output[:properties][:root][:properties][:children][:items]
      expect(input_items[:properties]).to eq(value: {}, children: {})
      expect(output_items[:properties]).to eq(value: {}, children: {})
    end

    it "reflects a 2-hop type cycle (A -> B -> A) without overflowing" do
      b = Data.define(:a_ref)
      a = Data.define(:b_ref)
      klass = Class.new do
        include Axn
        expects :root, type: a do
          field :b_ref, type: Array, of: b
        end
      end

      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
      items = schema[:properties][:root][:properties][:b_ref][:items]
      # B's members expand one level to `{}`; the cycle back to A never forms in the walk.
      expect(items[:properties]).to eq(a_ref: {})
    end
  end

  describe "union type: [A, B]" do
    it "preserves all classes as anyOf, not just the first" do
      klass = Class.new do
        include Axn
        expects :val, type: [String, Integer]
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:properties][:val][:anyOf]).to eq([{ type: "string", minLength: 1 }, { type: "integer" }])
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

    it "types the parent object-only + required when a DEEP (via dotted on:) subfield default synthesizes it " \
       "into a required shape member (PRO-2872)" do
      # `expects :zip, on: "payload.address", default: "x"` lands the defaulted config on a DEEPER node
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
        expects :zip, on: "payload.address", default: "x"
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:properties][:payload][:type]).to eq("object")
      expect(schema[:required]).to include("payload")
      expect(klass.call).not_to be_ok                          # runtime agreement: omission fails
      expect(klass.call(payload: nil)).not_to be_ok            # runtime agreement: nil fails
      expect(klass.call(payload: { status: "ok" })).to be_ok   # a satisfying call passes
    end

    it "types the parent object-only + required when a DEEP (via dotted on:) subfield PROC default synthesizes " \
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
        expects :zip, on: "payload.address", type: String, default: -> { "x" }, optional: true
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:properties][:payload][:type]).to eq("object")
      expect(schema[:required]).to include("payload")
      expect(klass.call).not_to be_ok               # runtime agreement: omission fails
      expect(klass.call(payload: nil)).not_to be_ok # runtime agreement: nil fails
    end

    it "requires the parent when a DEEP (via dotted on:) subfield default would land under it (the default " \
       "resolves only the child on the read path, never synthesizing the parent, PRO-2903)" do
      # `expects :zip, on: "payload.address", default: "x"` on a plain Hash parent: the deep default resolves
      # only the child's value when read — it never synthesizes `payload` — so the parent keeps its own
      # presence obligation. The schema marks it required and runtime rejects omission.
      klass = Class.new do
        include Axn
        expects :payload, type: Hash
        expects :zip, on: "payload.address", default: "x"
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required] || []).to include("payload")
      expect(klass.call).not_to be_ok # runtime agreement: omission fails the parent's own presence
    end

    it "keeps the parent required when the only DEEP (via dotted on:) subfield default is a Proc (rescue " \
       "excludes Procs — stricter than runtime, PRO-2872)" do
      # A Proc default's success is what would rescue omission, and a raising Proc would make omission FAIL,
      # so the rescue walk deliberately excludes Procs — the parent stays required. This is the safe,
      # stricter-than-runtime direction: runtime omission may pass when the Proc behaves, but reflecting
      # required never causes a failed call. Schema-only assertion (runtime may legitimately differ).
      klass = Class.new do
        include Axn
        expects :payload, type: Hash
        # optional: so nothing in the subtree requires presence — the rescue clause alone decides.
        expects :zip, on: "payload.address", type: String, default: -> { "x" }, optional: true
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

      expect(prop[:anyOf]).to match_array([{ type: "object", minProperties: 1 }, { type: "array", minItems: 1 }])
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

  describe "a deep subfield via a dotted `on:` nests as recursive object properties keyed by wire segment" do
    it "nests a deep dotted-on: subfield under an implicit intermediate (bar -> baz), not a flat dotted key" do
      klass = Class.new do
        include Axn
        expects :foo, type: Hash
        expects :baz, on: "foo.bar"
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      foo = schema[:properties][:foo]
      # The dotted on: splits into an implicit :bar intermediate carrying the :baz leaf — never a flat
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

    it "nests both a normal sibling subfield and a deep dotted-on: subfield on the same parent" do
      klass = Class.new do
        include Axn
        expects :foo, type: Hash
        expects :bar, on: :foo, type: String
        expects :path, on: "foo.deep"
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

    it "leaves an optional (no-default) parent whose only subfield is a deep dotted-on: leaf optional, matching its shallow analog" do
      shallow = Class.new do
        include Axn
        expects :foo, optional: true
        expects :bar, on: :foo, type: String, optional: true
      end
      dotted = Class.new do
        include Axn
        expects :foo, optional: true
        expects :baz, on: "foo.bar", type: String, optional: true
      end

      shallow_schema = described_class.build_input(shallow.internal_field_configs, shallow.subfield_configs)
      dotted_schema = described_class.build_input(dotted.internal_field_configs, dotted.subfield_configs)

      # accepted divergence: runtime rejects both omitted calls (a nil parent can't yield the child);
      # the schema reflects both as optional because `optional: true` is a nil-tolerant declared signal
      # and the sole child is itself optional. Parity is the criterion: the deep dotted-on: parent
      # reflects its optionality identically to the shallow case.
      expect(shallow_schema[:required] || []).not_to include("foo")
      expect(dotted_schema[:required] || []).not_to include("foo")

      # The deep dotted-on: leaf nests under an implicit :bar intermediate (never a flat "bar.baz" key).
      expect(dotted_schema[:properties][:foo][:properties][:bar][:properties]).to have_key(:baz)
    end

    it "requires the parent when its only child is a REQUIRED deep dotted-on: subfield (a required descendant strands a nil parent)" do
      klass = Class.new do
        include Axn
        expects :foo, type: Hash, default: {}
        expects :baz, on: "foo.bar", type: String
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

    # Bare-collection shorthands (PRO-2944): nil-membership must be inspected the same as the { in: } form.
    it "does not require a field whose bare-Array exclusion set does not contain nil" do
      klass = Class.new do
        include Axn
        expects :role, presence: false, exclusion: %w[admin]
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required] || []).not_to include("role")
    end

    it "still requires a field whose bare-Array inclusion set does not contain nil" do
      klass = Class.new do
        include Axn
        expects :role, inclusion: %w[a b]
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required]).to include("role")
    end

    it "does not require a field whose bare-Array inclusion set explicitly contains nil" do
      klass = Class.new do
        include Axn
        expects :role, presence: false, inclusion: [nil, "a"]
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required] || []).not_to include("role")
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
      # Numeric members are pinned with a `type:` so the set survives the outbound exactness gate below —
      # what this example is about is the nil, not the numbers.
      klass = Class.new do
        include Axn
        exposes :status, type: Integer, inclusion: { in: [1, 2] }, allow_blank: true
        def call = expose(status: 1)
      end
      schema = described_class.build_output(klass.external_field_configs)
      prop = schema[:properties][:status]

      # enum lists nil (allow_blank ⇒ nil-tolerant) alongside the numeric members, but not "".
      expect(prop[:enum]).to match_array([1, 2, nil])
      expect(Array(prop[:type])).to include("integer", "null")
      expect(Array(prop[:type])).not_to include("string")
    end

    # An outbound enum has to hold the wire form of every value the runtime accepts, and the runtime accepts by
    # Ruby `==` — which can identify values that SERIALIZE differently. Two DateTimes for one instant in
    # different offsets are `==` and render as different ISO-8601 strings, so the emitted set rejects an element
    # the action validated and serialized successfully. The same gate covers every position, the keys axis
    # having been only the first place it showed.
    describe "an outbound enum whose members' equality crosses the wire form" do
      let(:utc) { DateTime.parse("2020-01-01T00:00:00+00:00") }
      let(:offset) { DateTime.parse("2020-01-01T09:00:00+09:00") }

      it "is the divergence itself: equal DateTimes, different ISO-8601" do
        expect(utc == offset).to be true
        expect(utc.iso8601).not_to eq(offset.iso8601)
      end

      it "stands the set down at a field" do
        moment = utc
        other = offset
        action = build_axn do
          exposes :f, type: DateTime, inclusion: { in: [moment] }
          define_method(:call) { expose(:f, other) }
        end
        result = action.call

        expect(result).to be_ok
        expect(Axn::Extensions::Serialization.render(result)["f"]).to eq(other.iso8601)
        expect(action.output_schema[:properties][:f]).not_to have_key(:enum)
      end

      it "stands the set down at an element position" do
        moment = utc
        other = offset
        action = build_axn do
          exposes :f, type: Array, of: { klass: DateTime, inclusion: { in: [moment] } }
          define_method(:call) { expose(:f, [other]) }
        end

        expect(action.call).to be_ok
        expect(action.output_schema.dig(:properties, :f, :items)).not_to have_key(:enum)
      end

      # Inbound is unaffected: there the set names what a client may SEND, and a set narrower than the runtime's
      # equality is stricter, which is the licensed direction.
      it "still emits the set inbound" do
        moment = utc
        action = build_axn { expects :f, type: DateTime, inclusion: { in: [moment] } }

        expect(action.input_schema.dig(:properties, :f, :enum)).to eq([moment.iso8601])
      end

      # A member whose equality admits only its own type settles it without asking the position anything.
      it "keeps a String, Symbol and pinned-numeric set at both positions" do
        action = build_axn do
          exposes :s, type: String, inclusion: { in: %w[a b] }
          exposes :n, type: Integer, inclusion: { in: [1, 2] }
          exposes :y, type: Array, of: { klass: Symbol, inclusion: { in: %i[a b] } }
          def call = expose(s: "a", n: 1, y: [:a])
        end

        expect(action.call).to be_ok
        expect(action.output_schema.dig(:properties, :s, :enum)).to eq(%w[a b])
        expect(action.output_schema.dig(:properties, :n, :enum)).to eq([1, 2])
        expect(action.output_schema.dig(:properties, :y, :items, :enum)).to eq(%w[a b])
      end
    end

    # The same declaration WITHOUT a `type:` admits Ruby's whole numeric tower, and `1 == 1.0` — so an action
    # may expose `1.0`, satisfy `inclusion:`, and serialize `1.0`, which the emitted set does not contain. The
    # set stands down outbound rather than reject the action's own output; inbound it is emitted, a set narrower
    # than the runtime's equality being the licensed direction there.
    it "stands an unpinned numeric set down on output, where equality crosses the wire form" do
      klass = Class.new do
        include Axn
        expects :status, inclusion: { in: [1, 2] }
        exposes :out, inclusion: { in: [1, 2] }
        def call = expose(out: 1.0)
      end

      expect(klass.call(status: 1.0)).to be_ok
      expect(klass.output_schema[:properties][:out]).not_to have_key(:enum)
      expect(klass.input_schema.dig(:properties, :status, :enum)).to eq([1, 2])
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

      it "emits and consumes the id for a model subfield reached via a dotted on: (a reader IS generated)" do
        # The NAME is plain (`:company`) and only the `on:` is dotted, so ContractForSubfields generates a
        # reader that runs the id->record lookup. The `company_id` under `payload.org` stays represented and
        # the runtime consumes it.
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

      it "does not require the model <field>_id when a deep dotted-on: subfield is value-level defaulted (PRO-2889)" do
        # `expects :theme, on: "company.settings", default: "x"` lands the defaulted config on a DEEPER
        # node. PRO-2889: the value-level default "x" applies at read time (validation resolves it through
        # the shared `resolve_value`, no synthesis), so the deep subfield is self-rescuing and the omitted
        # call SUCCEEDS — the schema mirrors that and drops company_id from `required`.
        klass = Class.new do
          include Axn
          expects :company, model: { klass: Struct.new(:id, :settings), finder: :find }, allow_nil: true
          expects :theme, on: "company.settings", default: "x"
          def call = nil
        end
        schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

        expect(Array(schema[:required])).not_to include("company_id")
        expect(klass.call).to be_ok # runtime agreement: the value-level default satisfies the deep subfield on omission
      end

      it "does not require the model <field>_id for an optional deep PROC default via a dotted on: (optionality alone rescues it)" do
        # The optional deep subfield never forces the id: omitting it resolves company to nil, the deep
        # dotted-on: default applies at read time (PRO-2889), and an optional String validates either
        # way — so the omitted call succeeds and the schema mirrors that.
        klass = Class.new do
          include Axn
          expects :company, model: { klass: Struct.new(:id, :settings), finder: :find }, allow_nil: true
          expects :theme, on: "company.settings", type: String, default: -> { "x" }, optional: true
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
          expects :baz, on: "payload.bar", type: String
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
          expects :baz, on: "payload.bar", type: String
        end
        schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

        bar = schema[:properties][:payload][:properties][:bar]
        expect(bar).to have_key(:anyOf)
        expect(Array(bar[:type])).not_to include("object")
        expect(bar).not_to have_key(:properties)
        dropped = described_class.dropped_deep_subfields(klass.internal_field_configs, klass.subfield_configs)
        expect(dropped.map(&:field)).to eq([:baz])
      end

      it "leaves a mixed-union shape member untouched and drops the colliding deep config (emission and drop pass agree)" do
        klass = Class.new do
          include Axn
          expects :payload, type: Hash do
            field :bar, type: [Hash, Array]
          end
          expects :baz, on: "payload.bar", type: String
        end
        schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

        bar = schema[:properties][:payload][:properties][:bar]
        expect(bar).to have_key(:anyOf)
        expect(bar).not_to have_key(:properties)
        expect(Array(bar[:type])).not_to include("object")
        dropped = described_class.dropped_deep_subfields(klass.internal_field_configs, klass.subfield_configs)
        expect(dropped.map(&:field)).to eq([:baz])
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
        # via its Hash branch, so the declaration is accepted while the deep `qux` drops.
        klass = Class.new do
          include Axn
          expects :payload, type: Hash do
            field :bar, type: Hash do
              field :baz, type: [Hash, String]
            end
          end
          expects :qux, on: "payload.bar.baz"
        end
        schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

        baz = schema[:properties][:payload][:properties][:bar][:properties][:baz]
        expect(baz).to have_key(:anyOf) # union member kept as-is
        expect(Array(baz[:type])).not_to include("object")
        expect(baz).not_to have_key(:properties) # no forced object / qux under it
        dropped = described_class.dropped_deep_subfields(klass.internal_field_configs, klass.subfield_configs)
        expect(dropped.map(&:field)).to eq([:qux])
      end

      it "leaves a mixed-union member-of-a-member untouched and drops the deeper colliding config" do
        klass = Class.new do
          include Axn
          expects :payload, type: Hash do
            field :bar, type: Hash do
              field :baz, type: [Hash, Array]
            end
          end
          expects :qux, on: "payload.bar.baz"
        end
        schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

        baz = schema[:properties][:payload][:properties][:bar][:properties][:baz]
        expect(baz).to have_key(:anyOf)
        expect(baz).not_to have_key(:properties)
        expect(Array(baz[:type])).not_to include("object")
        dropped = described_class.dropped_deep_subfields(klass.internal_field_configs, klass.subfield_configs)
        expect(dropped.map(&:field)).to eq([:qux])
      end

      it "merges into an OBJECT member-of-a-member at depth 2 and does NOT drop the config (positive control)" do
        klass = Class.new do
          include Axn
          expects :payload, type: Hash do
            field :bar, type: Hash do
              field :baz, type: Hash
            end
          end
          expects :qux, on: "payload.bar.baz"
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
          expects :baz, on: "payload.bar", type: String, optional: true
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
          expects :baz, on: "payload.bar", type: String
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
          expects :baz, on: "payload.bar", type: String, optional: true
          def call = nil
        end
        schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

        bar = schema[:properties][:payload][:properties][:bar]
        expect(bar[:type]).to eq("object") # member rejects nil regardless of the child
        expect(klass.call(payload: { bar: nil })).not_to be_ok # schema agrees: nil member rejected
      end

      # PRO-3399. An EXPLICIT subfield node at a wire position an ancestor `shape:` also describes used to
      # REPLACE the member's emitted property instead of conjoining with it, so every nested member the
      # ancestor declared vanished from the document while the runtime went on enforcing all of them — the
      # one direction input reflection may not err in. The implicit spelling of the identical contract was
      # correct throughout, which is what these pin: the two spellings must agree.
      describe "an explicit node at a key an ancestor shape member also declares (PRO-3399)" do
        it "emits the ancestor's members at the explicit node, and the runtime agrees" do
          klass = Class.new do
            include Axn
            expects :payload, type: Hash do
              field :inner, type: Hash do
                field :a, type: String
                field :b, type: String
              end
            end
            expects :inner, on: :payload, type: Hash
            def call = nil
          end
          schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

          inner = schema[:properties][:payload][:properties][:inner]
          expect(inner[:properties].keys).to contain_exactly(:a, :b)
          expect(inner[:required]).to contain_exactly("a", "b")

          expect(klass.call(payload: { inner: { a: "x" } })).not_to be_ok # b enforced, and now advertised
          expect(klass.call(payload: { inner: { a: "x", b: "y" } })).to be_ok
        end

        # The strongest form of the claim, and the one that would have caught the defect on its own: the same
        # contract spelled two ways must produce one document.
        it "emits exactly what the implicit spelling of the same contract emits" do
          explicit = Class.new do
            include Axn
            expects :payload, type: Hash do
              field :inner, type: Hash do
                field :a, type: String
              end
            end
            expects :inner, on: :payload, type: Hash
            expects :c, on: :inner, type: String
          end
          implicit = Class.new do
            include Axn
            expects :payload, type: Hash do
              field :inner, type: Hash do
                field :a, type: String
              end
            end
            expects :c, on: "payload.inner", type: String
          end

          expect(described_class.build_input(explicit.internal_field_configs, explicit.subfield_configs))
            .to eq(described_class.build_input(implicit.internal_field_configs, implicit.subfield_configs))
        end

        it "unions the ancestor's members with the node's OWN shape block rather than picking one" do
          klass = Class.new do
            include Axn
            expects :payload, type: Hash do
              field :inner, type: Hash do
                field :a, type: String
              end
            end
            expects :inner, on: :payload, type: Hash do
              field :b, type: String
            end
            def call = nil
          end
          schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

          inner = schema[:properties][:payload][:properties][:inner]
          expect(inner[:properties].keys).to contain_exactly(:a, :b)
          expect(inner[:required]).to contain_exactly("a", "b")
          expect(klass.call(payload: { inner: { b: "y" } })).not_to be_ok # the ancestor's `a` is enforced too
        end

        # The member contributes everything the node's own declaration does not state, not just `properties`:
        # a map's contents live in `additionalProperties`, which a contents-only merge would still have lost.
        it "carries a map member's additionalProperties onto the merged node" do
          klass = Class.new do
            include Axn
            expects :payload, type: Hash do
              field :inner, type: Hash, of: { keys: { klass: Symbol }, values: { klass: String } }
            end
            expects :inner, on: :payload, type: Hash
            expects :c, on: :inner, type: Integer
            def call = nil
          end
          schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

          inner = schema[:properties][:payload][:properties][:inner]
          expect(inner[:additionalProperties]).to eq(type: "string")
          expect(inner[:properties][:c]).to include(type: "integer")
          # Unexempted, deliberately: the runtime derives its shaped-key exemption from the node's OWN
          # `shape:`, so a carried member exempts nothing there either and the map's value check applies to
          # `c` as well. Both sides reject the same value.
          expect(klass.call(payload: { inner: { c: 1 } })).not_to be_ok
        end

        it "carries the ancestor's members through TWO explicit hops" do
          klass = Class.new do
            include Axn
            expects :payload, type: Hash do
              field :l1, type: Hash do
                field :l2, type: Hash do
                  field :a, type: String
                end
              end
            end
            expects :l1, on: :payload, type: Hash
            expects :l2, on: :l1, type: Hash
            expects :extra, on: :l2, type: String
            def call = nil
          end
          schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

          l2 = schema[:properties][:payload][:properties][:l1][:properties][:l2]
          expect(l2[:properties].keys).to contain_exactly(:a, :extra)
          expect(klass.call(payload: { l1: { l2: { extra: "x" } } })).not_to be_ok
        end

        it "strips the null branch a nil-tolerant node would admit when the member forbids nil" do
          klass = Class.new do
            include Axn
            expects :payload, type: Hash do
              field :inner, type: Hash do
                field :a, type: String
              end
            end
            expects :inner, on: :payload, type: Hash, allow_nil: true
            def call = nil
          end
          schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

          inner = schema[:properties][:payload][:properties][:inner]
          expect(inner[:type]).to eq("object")
          expect(klass.call(payload: { inner: nil })).not_to be_ok # schema agrees: nil rejected
        end

        # The cap is charged on every colliding member, merged or not — a non-nestable member contributes no
        # contents and still forbids nil.
        it "strips the null branch for a NON-nestable member that forbids nil" do
          klass = Class.new do
            include Axn
            expects :payload, type: Hash do
              field :inner, type: [Hash, Array]
            end
            expects :inner, on: :payload, type: Hash, allow_nil: true
            def call = nil
          end
          schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

          expect(schema[:properties][:payload][:properties][:inner][:type]).to eq("object")
          expect(klass.call(payload: { inner: nil })).not_to be_ok
        end

        # PRO-3405. A name declared twice at one node — once by the ancestor's nested shape, once by the
        # node's own child — used to resolve by precedence (`base_properties.merge(member_props)`, the
        # child winning outright), discarding the ancestor's constraint though the runtime enforces both.
        # Conjoined via `allOf` instead, same as any other collision this ticket closes: `String` and
        # `Array` are disjoint (and neither is coercible, so the stand-down below never applies), so the
        # honest conjunction is empty, matching a contract nothing satisfies (both spellings, measured).
        # Every spelling agrees, which is what a fix must preserve — correcting only the explicit path
        # would reopen the divergence PRO-3399 closed.
        it "conjoins a colliding child name via allOf rather than letting one side win" do
          klass = Class.new do
            include Axn
            expects :payload, type: Hash do
              field :inner, type: Hash do
                field :a, type: String
              end
            end
            expects :inner, on: :payload, type: Hash
            expects :a, on: :inner, type: Array
            def call = nil
          end
          schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

          a_prop = schema[:properties][:payload][:properties][:inner][:properties][:a]
          expect(a_prop[:type]).to eq("array")
          expect(a_prop[:allOf]).to eq([{ type: "string", minLength: 1 }])
          expect(klass.call(payload: { inner: { a: "x" } })).not_to be_ok # ancestor wants String…
          expect(klass.call(payload: { inner: { a: [1] } })).not_to be_ok # …node wants Array: nothing satisfies both

          implicit = Class.new do
            include Axn
            expects :payload, type: Hash do
              field :inner, type: Hash do
                field :a, type: String
              end
            end
            expects :a, on: "payload.inner", type: Array
          end
          expect(described_class.build_input(implicit.internal_field_configs, implicit.subfield_configs))
            .to eq(schema)
        end

        # A coercible child's emitted type ("integer") names its TARGET, not the wire form the ancestor's
        # own check reads — the ancestor's check is UNCONDITIONAL (measured: it also rejects an
        # already-Integer wire value here, independent of coercion), so conjoining the ancestor's REAL
        # String constraint is what matches the runtime, not standing the whole child down. This is the
        # child-level twin of the node-level case below — a coercible type is approximate exactly the way
        # an unknown class's fallback is, so `conjoin_shape_member_property` drops it and adopts the
        # ancestor's own emission wholesale.
        it "conjoins the ancestor's real constraint over a colliding child's coercible-target type" do
          klass = Class.new do
            include Axn
            configure { |c| c.coerce_input_types = true }
            expects :payload, type: Hash do
              field :inner, type: Hash do
                field :a, type: String
              end
            end
            expects :inner, on: :payload, type: Hash
            expects :a, on: :inner, type: Integer
            def call = nil
          end
          schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

          a_prop = schema[:properties][:payload][:properties][:inner][:properties][:a]
          expect(a_prop).to eq(type: "string", minLength: 1)
          expect(klass.call(payload: { inner: { a: "5" } })).to be_ok # the coercible wire form still works
          expect(klass.call(payload: { inner: { a: 5 } })).not_to be_ok # a raw wire integer never satisfies the ancestor
        end

        # The conjunction actually being ENFORCED, not just an empty one: two compatible String
        # constraints, one on each side, both alive in the final document — and pinned across all three
        # spellings, which must agree (the property PRO-3399 established).
        it "enforces both sides of a satisfiable colliding-child conjunction, identically in every spelling" do
          explicit_child = Class.new do
            include Axn
            expects :payload, type: Hash do
              field :inner, type: Hash do
                field :a, type: String, length: { minimum: 3 }
              end
            end
            expects :inner, on: :payload, type: Hash
            expects :a, on: :inner, type: String, format: { with: /\Aabc/ }
            def call = nil
          end
          own_shape = Class.new do
            include Axn
            expects :payload, type: Hash do
              field :inner, type: Hash do
                field :a, type: String, length: { minimum: 3 }
              end
            end
            expects(:inner, on: :payload, type: Hash) { field :a, type: String, format: { with: /\Aabc/ } }
            def call = nil
          end
          dotted = Class.new do
            include Axn
            expects :payload, type: Hash do
              field :inner, type: Hash do
                field :a, type: String, length: { minimum: 3 }
              end
            end
            expects :a, on: "payload.inner", type: String, format: { with: /\Aabc/ }
            def call = nil
          end

          schema = described_class.build_input(explicit_child.internal_field_configs, explicit_child.subfield_configs)
          expect(described_class.build_input(own_shape.internal_field_configs, own_shape.subfield_configs)).to eq(schema)
          expect(described_class.build_input(dotted.internal_field_configs, dotted.subfield_configs)).to eq(schema)

          a_prop = schema[:properties][:payload][:properties][:inner][:properties][:a]
          expect(a_prop[:pattern]).to eq("^abc") # the node's own format survives at the top
          expect(a_prop[:allOf]).to eq([{ type: "string", minLength: 3 }]) # the ancestor's length floor, conjoined

          [explicit_child, own_shape, dotted].each do |klass|
            expect(klass.call(payload: { inner: { a: "abcdef" } })).to be_ok       # satisfies length AND format
            expect(klass.call(payload: { inner: { a: "ab" } })).not_to be_ok       # fails the ancestor's length floor
            expect(klass.call(payload: { inner: { a: "xyzxyz" } })).not_to be_ok   # fails the node's own format
          end
        end

        # A non-nestable member BELOW the explicit hop blocks at the deeper implicit node, exactly as it does
        # with no explicit hop at all — the carry is what makes the two agree, so this pins both halves.
        it "blocks and drops at a non-nestable member reached THROUGH the explicit hop, matching the implicit control" do
          explicit = Class.new do
            include Axn
            expects :payload, type: Hash do
              field :inner, type: Hash do
                field :deep, type: [Hash, Array]
              end
            end
            expects :inner, on: :payload, type: Hash
            expects :x, on: "payload.inner.deep", type: String
          end
          implicit = Class.new do
            include Axn
            expects :payload, type: Hash do
              field :inner, type: Hash do
                field :deep, type: [Hash, Array]
              end
            end
            expects :x, on: "payload.inner.deep", type: String
          end

          expect(described_class.build_input(explicit.internal_field_configs, explicit.subfield_configs))
            .to eq(described_class.build_input(implicit.internal_field_configs, implicit.subfield_configs))
          expect(described_class.dropped_deep_subfields(explicit.internal_field_configs, explicit.subfield_configs).map(&:field))
            .to eq([:x])
        end

        # A model's generated `<field>_id` is skipped only when something else has ALREADY written that key.
        # A `shape:` member on a non-representative route of a merged node is declared but never emitted, so
        # treating it as that something skipped the generated property and left `company_id` `required` with
        # no entry in `properties` — which JSON Schema reads as "any value permitted", looser than emitting
        # nothing at all. Both spellings of the intermediate are pinned: the explicit node (where the carry
        # introduced it) and the dotted `on:` (where it predates this change).
        describe "a carried shape member that was never emitted does not claim a model's id key" do
          def merged_route_klass(intermediate)
            cid = Axn::Core::Contract::ShapeConfig.new(
              field: :company_id, validations: { type: { klass: String }, presence: true }, metadata: {},
            )
            inner_member = Axn::Core::Contract::ShapeConfig.new(
              field: :inner,
              validations: { type: { klass: Hash }, presence: true, shape: { members: [cid], container: Hash } },
              metadata: {},
            )
            Class.new do
              include Axn
              expects :outer, type: Hash
              expects :mid, on: :outer, type: Hash
              # Two routes to the wire key `outer.mid.payload`; the FIRST is the representative, and it is the
              # one whose shape `apply_structured_schema!` emits — so the second route's member never reaches
              # the document at all.
              expects :payload, on: "outer.mid", type: Hash, as: :p1
              expects :payload, on: :mid, type: Hash, shape: { members: [inner_member], container: Hash }
              instance_exec(&intermediate)
              def call = nil
            end
          end

          it "emits the generated id at an EXPLICIT intermediate" do
            klass = merged_route_klass(proc do
              expects :inner, on: :p1, type: Hash
              expects :company, on: :inner, model: { klass: Object, finder: :inspect, id_type: String }
            end)
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema.dig(:properties, :outer, :properties, :mid, :properties, :payload, :properties, :inner)
            expect(inner[:required]).to include("company_id")
            expect(inner[:properties]).to have_key(:company_id) # required AND defined
            expect(inner[:properties][:company_id]).to include(type: "string") # the declared id_type, not untyped
          end

          it "emits the generated id at an IMPLICIT intermediate" do
            klass = merged_route_klass(proc do
              expects :company, on: "p1.inner", model: { klass: Object, finder: :inspect, id_type: String }
            end)
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema.dig(:properties, :outer, :properties, :mid, :properties, :payload, :properties, :inner)
            expect(inner[:required]).to include("company_id")
            expect(inner[:properties]).to have_key(:company_id)
            expect(inner[:properties][:company_id]).to include(type: "string")
          end
        end

        # PRO-3405. Every case below used to discard the ancestor member's contents outright — no shared
        # `properties`/`required` keyword surface with the node's own emission, so there was nowhere to
        # put them structurally. They still don't get keyword-merged (that stays the object-vs-object
        # path above), but they are no longer DROPPED: the member is conjoined as a sibling `allOf`
        # branch, so the document keeps every constraint the runtime enforces.
        context "a member the emitter cannot structurally merge conjoins via allOf instead of dropping" do
          # The node's OWN type governs nesting: a `type: Hash` node under a `[Hash, Array]` member still
          # nests its subfields, because runtime narrows to the Hash branch there and such a contract
          # resolves for real. Only the member's own contents stay OUT OF `properties` — they still reach
          # the document, via the allOf branch below. If this ever starts dropping `c` from `properties`,
          # the drop pass has been widened to block at explicit hops, which it must not be.
          it "still nests an explicit node's children under a mixed-union member, and drops nothing" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, type: [Hash, Array]
              end
              expects :inner, on: :payload, type: Hash
              expects :c, on: :inner, type: String
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            expect(inner[:type]).to eq("object")
            expect(inner[:properties]).to have_key(:c)
            expect(inner[:allOf]).to eq([{ anyOf: [{ type: "object", minProperties: 1 }, { type: "array", minItems: 1 }] }])
            expect(described_class.dropped_deep_subfields(klass.internal_field_configs, klass.subfield_configs)).to eq([])
            expect(klass.call(payload: { inner: { c: "x" } })).to be_ok # and it really resolves
          end

          # The measured divergence this closes: the ancestor member requires an object with AT LEAST one
          # property (or a non-empty array) — a bare `{}` satisfies neither branch, and the runtime has
          # always rejected it. Before this fix the document accepted it (the member was dropped whole).
          it "conjoins a mixed-union member's own presence floor onto a nil-tolerant node" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, type: [Hash, Array]
              end
              expects :inner, on: :payload, type: Hash, allow_nil: true
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            expect(inner[:type]).to eq("object") # allow_nil stripped: the ancestor member forbids nil
            expect(inner[:allOf]).to eq([{ anyOf: [{ type: "object", minProperties: 1 }, { type: "array", minItems: 1 }] }])
            expect(klass.call(payload: { inner: {} })).not_to be_ok # the divergence: the document used to accept this
          end

          # A direct unit test of the conjoin helper itself, at the one combination no declaration reaches
          # through `.input_schema` in one build (the node's OWN emitted property is always overwritten
          # before anything else could read the stale reference) but that a future caller easily could: an
          # EXPLICIT node with no type or shape of its own emits `{}`, which routes through
          # merge_shape_member_property rather than a bare `member_prop.dup` specifically so that a caller
          # adding the node's own children afterward (as apply_nested_subfields! does) writes into a properties
          # Hash of its own, never into the ancestor's.
          it "conjoins an empty node property without aliasing the member's own properties Hash" do
            member_prop = { type: "object", properties: { a: { type: "string" } }, required: ["a"], minProperties: 1 }

            conjoined = described_class.conjoin_shape_member_property(member_prop, {})
            conjoined[:properties][:b] = { type: "integer" } # simulate a node's own child being added afterward

            expect(member_prop[:properties]).not_to have_key(:b)
          end

          it "conjoins via allOf when the ancestor member's own type has no object branch at all" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, type: String
              end
              expects :inner, on: :payload, type: Hash
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            expect(inner[:type]).to eq("object")
            expect(inner[:allOf]).to eq([{ type: "string", minLength: 1 }])
            # honest emptiness: String and Hash are disjoint, so nothing satisfies the conjunction —
            # matching the contract, which nothing satisfies either.
            expect(klass.call(payload: { inner: {} })).not_to be_ok
            expect(klass.call(payload: { inner: "x" })).not_to be_ok
          end

          # A non-object NODE type (not a union — plain `Array`) beside an object-shaped ancestor member:
          # `properties` stays absent (there is nowhere at the top level to put an object's properties
          # under an array-typed node), but the member's whole Hash-shaped constraint now reaches the
          # document via allOf, rather than vanishing.
          it "conjoins via allOf into a node whose own type cannot hold object properties" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, type: Hash do
                  field :a, type: String
                end
              end
              expects :inner, on: :payload, type: Array
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            expect(inner[:type]).to eq("array")
            expect(inner).not_to have_key(:properties)
            expect(inner[:allOf]).to eq(
              [{ type: "object", properties: { a: { type: "string", minLength: 1 } }, required: ["a"], minProperties: 1 }],
            )
            expect(schema[:properties][:payload][:required]).to include("inner") # obligation kept
            # honest emptiness: Array and the member's required Hash shape are disjoint.
            expect(klass.call(payload: { inner: [] })).not_to be_ok
            expect(klass.call(payload: { inner: { a: "x" } })).not_to be_ok
          end

          # The deep twin of the top-level case above: a nested key, not the node itself, collision-free at
          # depth 0 but conjoined at depth 1 via merge_emitted_maps rather than apply_explicit_child! — the
          # OTHER site this fix touches. Object (node's own shape) vs scalar (ancestor's), not two scalars.
          it "conjoins a nested key's ancestor-declared shape with the node's OWN differently-shaped child" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, type: Hash do
                  field :deep, type: String
                end
              end
              expects(:inner, on: :payload, type: Hash) do
                field :deep, type: Hash do
                  field :z, type: String
                end
              end
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            deep = schema[:properties][:payload][:properties][:inner][:properties][:deep]
            expect(deep[:type]).to eq("object")
            expect(deep[:properties]).to have_key(:z)
            expect(deep[:allOf]).to eq([{ type: "string", minLength: 1 }])
            # the divergence this closes: an object satisfying the node's own shape used to pass, though
            # the ancestor member requires deep to be a String.
            expect(klass.call(payload: { inner: { deep: { z: "x" } } })).not_to be_ok
          end

          # A shape member (or the node's own shape) whose declared type is APPROXIMATE — an unknown class
          # like `Object`/`Enumerable`, which `single_type_for` reflects on input as a permissive `{type:
          # "string"}` HINT rather than a real constraint — must not be conjoined as if that hint were
          # exact: doing so emits a string-vs-object intersection nothing satisfies, though the runtime
          # accepts any Hash for both sides (Codex review, PR #278). Only the fake TYPE (`type`/`anyOf`) is
          # dropped from the approximate side; everything else — here, the presence floor `single_type_for`
          # attached under its "string" assumption — survives as a harmless residue, RETARGETED to the
          # surviving object type's own keyword (`minProperties`, not `minLength` — round 13:
          # `retarget_unknown_class_length` translates it once the collision reveals the real type, since
          # JSON Schema would otherwise silently ignore a `minLength` on an object instance and the presence
          # floor would enforce nothing at all).
          it "does not conjoin an ancestor member's approximate type hint against the node's real object shape" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, type: Object
              end
              expects :inner, on: :payload, type: Hash
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            expect(inner).to eq(type: "object", minProperties: 1, allOf: [{ minProperties: 1 }])
            expect(klass.call(payload: { inner: { a: 1 } })).to be_ok # the working contract this protects
          end

          # The mirror: the NODE's own type is the approximate one, and the ancestor member's real Hash
          # shape survives — its `properties`/`required` reach the document, rather than the node's fake
          # "string" hint discarding them. The node's own presence floor (`single_type_for`'s "string"
          # fallback) survives too, RETARGETED to `minProperties` (round 13's `retarget_unknown_class_
          # length`, same reasoning as the sibling test above) as a harmless top-level sibling of the
          # ancestor's real shape in `allOf`.
          it "does not conjoin the node's own approximate type hint against a real ancestor shape, and keeps the ancestor's" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, type: Hash do
                  field :a, type: String
                end
              end
              expects :inner, on: :payload, type: Object
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            expect(inner).to eq(
              minProperties: 1,
              not: { type: "null" },
              allOf: [{ type: "object", properties: { a: { type: "string", minLength: 1 } }, required: ["a"], minProperties: 1 }],
            )
            expect(klass.call(payload: { inner: { a: "x" } })).to be_ok
            expect(klass.call(payload: { inner: {} })).not_to be_ok # the ancestor's required `a` still enforced
          end

          # Two approximate hints beside each other never contradict — nothing is lost by conjoining them
          # normally, so this is the one combination where the plain conjoin still runs.
          it "conjoins normally when BOTH sides are approximate, since two string hints cannot contradict" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, type: Object
              end
              expects :inner, on: :payload, type: Enumerable
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            expect(inner[:type]).to eq("string")
            expect(inner[:allOf]).to eq([{ type: "string", minLength: 1 }])
          end

          # A mixed union with ONE exact branch is still approximate as a WHOLE: `Object` alone already
          # admits everything the union could narrow to, so the exact `String` branch beside it adds
          # nothing the runtime doesn't already accept via `Object`. Codex review (PR #278 round 2) — an
          # earlier `.all?` reading let this union through as "exact" because String isn't approximate,
          # conjoining the union's collapsed `"string"` emission as though it meant only strings.
          it "treats a mixed union with an approximate branch as approximate as a whole" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, type: [Object, String]
              end
              expects :inner, on: :payload, type: Hash
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            expect(inner).to eq(type: "object", minProperties: 1, allOf: [{ minProperties: 1 }])
            expect(klass.call(payload: { inner: { a: 1 } })).to be_ok
          end

          # The same approximate-type judgment, one level deeper: the collision is between the ancestor's
          # NESTED field and the node's OWN shape block (spelling B, reached through merge_emitted_maps
          # rather than apply_explicit_child!). `merge_emitted_maps` re-resolves each side's config PER
          # COLLIDING KEY via `shape_members_at` rather than trusting the property Hash, so it can tell a
          # real `type: String` from the `Object` fallback apart at THIS depth too (Codex review, PR #278
          # round 3 — this was a KNOWN RESIDUAL through round 2, left deliberately unfixed pending exactly
          # this plumbing).
          it "does not conjoin an approximate type hint one level deeper either, through merge_emitted_maps" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, type: Hash do
                  field :deep, type: Object
                end
              end
              expects(:inner, on: :payload, type: Hash) do
                field :deep, type: Hash do
                  field :z, type: String
                end
              end
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            deep = schema[:properties][:payload][:properties][:inner][:properties][:deep]
            expect(deep).to eq(
              type: "object", properties: { z: { type: "string", minLength: 1 } }, required: ["z"], minProperties: 1,
              allOf: [{ minProperties: 1 }]
            )
            expect(klass.call(payload: { inner: { deep: { z: "x" } } })).to be_ok
            expect(klass.call(payload: { inner: { deep: {} } })).not_to be_ok # the node's own required `z` still enforced
          end

          # coerce:/preprocess: transform the wire value before validation runs, so a node declaring either
          # judges a DIFFERENT value than the ancestor member's declaration does — but the ancestor's own
          # check is UNCONDITIONAL (measured: it rejects an already-Integer wire value here too, regardless
          # of the node's coercion), so the coercible node's emitted "integer" names its TARGET, not the
          # wire form the ancestor actually reads. That makes it approximate exactly the way an unknown
          # class's `single_type_for` fallback is: `conjoin_shape_member_property` drops it and adopts the
          # ancestor's real String constraint wholesale, which is what actually matches the runtime for
          # BOTH the coercible wire string ("5") and the raw wire integer (5) it never satisfies.
          it "conjoins the ancestor's real constraint over a node whose own declaration coerces" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, type: String
              end
              expects :inner, on: :payload, type: { klass: Integer, coerce: true }
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            expect(inner).to eq(type: "string", minLength: 1)
            expect(klass.call(payload: { inner: "5" })).to be_ok # the coercible wire form still works
            expect(klass.call(payload: { inner: 5 })).not_to be_ok # a raw wire integer never satisfies the ancestor
          end

          # An ABSENT coerce: is not evidence of no transform: the class/global coerce_input_types setting
          # (and Axn::Tools::Invoker, always on) coerces every coercible field whose own coerce: is silent,
          # and reflection cannot resolve that ambient, per-call/per-class flag — the same conservatism
          # `boolean_coercion_can_flip_truthiness?` already applies elsewhere in this file. So a plain `type:
          # Integer` node with no coerce: at all is approximate too, exactly as an explicit coerce: true is.
          it "conjoins the ancestor's real constraint over a plain coercible type with no explicit coerce:" do
            klass = Class.new do
              include Axn
              configure { |c| c.coerce_input_types = true }
              expects :payload, type: Hash do
                field :inner, type: String
              end
              expects :inner, on: :payload, type: Integer
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            expect(inner).to eq(type: "string", minLength: 1)
            expect(klass.call(payload: { inner: "5" })).to be_ok
            expect(klass.call(payload: { inner: 5 })).not_to be_ok
          end

          # The mirror: an explicit coerce: false opts back out even on a coercible type, so a genuinely
          # non-transforming node conjoins normally — the stand-down is not "any coercible type", it is
          # "unless coercion is provably off".
          it "does not stand down when coerce: false explicitly rules the ambient flag out" do
            klass = Class.new do
              include Axn
              configure { |c| c.coerce_input_types = true }
              expects :payload, type: Hash do
                field :inner, type: String
              end
              expects :inner, on: :payload, type: { klass: Integer, coerce: false }
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            expect(inner[:allOf]).to eq([{ type: "string", minLength: 1 }])
            expect(klass.call(payload: { inner: "5" })).not_to be_ok # never coerced: a String fails the ancestor's own type too
          end

          # Approximateness is judged on the route that actually PRODUCED member_prop, not on every route
          # matching the key: at a merged ancestor node, `apply_structured_schema!` builds `member_prop`
          # from the REPRESENTATIVE route alone, so a LATER, non-representative route's exact type never
          # reaches the document at all — judging the whole `members` list let that unreached route mask
          # the representative's own approximate one (Codex review, PR #278 round 4). Two routes to
          # `outer.mid.payload`, the FIRST (representative) declaring `inner` as the approximate `Object`,
          # the SECOND (never emitted) declaring it as the real `Hash`.
          it "judges approximateness on the route that actually produced member_prop, not every merged route" do
            klass = Class.new do
              include Axn
              expects :outer, type: Hash
              expects :mid, on: :outer, type: Hash
              expects :payload, on: "outer.mid", type: Hash, as: :p1 do
                field :inner, type: Object
              end
              expects :payload, on: :mid, type: Hash do
                field :inner, type: Hash
              end
              expects :inner, on: :p1, type: Hash
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema.dig(:properties, :outer, :properties, :mid, :properties, :payload, :properties, :inner)
            expect(inner).to eq(type: "object", minProperties: 1, allOf: [{ minProperties: 1 }])
            expect(klass.call(outer: { mid: { payload: { inner: { a: 1 } } } })).to be_ok
          end

          # A mixed union node beside a real ancestor constraint: the ancestor's check is UNCONDITIONAL
          # (it runs regardless of which union branch the node's own type nominally admits), so an
          # `Integer` branch that's ALSO approximate (coercible) does not shield the union from the
          # ancestor — the whole node collapses to the ancestor's real Hash-shape requirement, because
          # nothing satisfies the ancestor without also being the Hash the union's other branch names
          # (Codex review, PR #278 round 4 — measured: even a wire value the Integer branch would coerce
          # successfully, or one that's already a valid Integer, fails the ancestor's Hash check either
          # way, so there is nothing for the Integer branch to protect).
          it "conjoins the ancestor's real constraint over a union node with one coercible branch" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, type: Hash do
                  field :a, type: String
                end
              end
              expects :inner, on: :payload, type: [Hash, Integer]
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            expect(inner).to eq(type: "object", properties: { a: { type: "string", minLength: 1 } }, required: ["a"], minProperties: 1)
            expect(klass.call(payload: { inner: { a: "x" } })).to be_ok
            expect(klass.call(payload: { inner: { other: 1 } })).not_to be_ok # non-empty Hash, but missing the ancestor's required `a`
            expect(klass.call(payload: { inner: 5 })).not_to be_ok # a wire integer never satisfies the ancestor's Hash requirement
          end

          # preprocess: is judged the same way as coercion — the node's own emitted type is approximate,
          # even with NO declared type token to weigh at all, since a Proc can rewrite the wire value into
          # anything. The ancestor's constraint is still independently enforced against the RAW value, so
          # it must not be discarded just because the node also transforms its own reading (Codex review,
          # PR #278 round 5).
          it "conjoins the ancestor's real constraint over a node whose own declaration preprocesses" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, type: Hash do
                  field :a, type: String
                end
              end
              expects :inner, on: :payload, type: Hash, preprocess: ->(v) { v }
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            # The node's own `minProperties: 1` (its presence floor, a TYPE-CONDITIONAL keyword — see
            # strip_intrinsically_typed_keys) survives stripping alongside the ancestor's full shape,
            # landing as a (redundant but harmless) sibling of the allOf rather than the node's `type:
            # "object"` winning outright the way it would if nothing else on it had survived.
            expect(inner).to eq(
              minProperties: 1,
              allOf: [{ type: "object", properties: { a: { type: "string", minLength: 1 } }, required: ["a"], minProperties: 1 }],
              not: { type: "null" },
            )
            expect(klass.call(payload: { inner: { a: "x" } })).to be_ok
            expect(klass.call(payload: { inner: { b: 1 } })).not_to be_ok # missing the ancestor's required `a`
          end

          # When both colliding sides are OBJECT-shaped, `merge_shape_member_property`'s shallow keyword
          # union lets the SECOND side's `:type` silently overwrite the first's — safe for `properties`/
          # `required`/the size bounds (those are explicitly unioned/intersected), but NOT for nullability:
          # a nullable `["object", "null"]` on one side must not overwrite the OTHER side's non-nullable
          # `"object"` (Codex review, PR #278 round 22): an ancestor `deep` Hash member that REQUIRES `a`
          # (non-nullable) beside a colliding node's OWN `deep` declared `allow_nil: true` (nullable) let
          # the node's nullable type win outright, so the merged schema admitted `deep: null` even though
          # the ancestor's own (unconditional, raw-value) check rejects null there. Both routes are
          # enforced, so null survives only when BOTH tolerate it — `merge_emitted_type` reconciles this
          # explicitly rather than leaving it to the shallow merge's "second side wins" default.
          it "keeps a nested object collision non-nullable when either colliding side forbids null" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, type: Hash do
                  field :deep, type: Hash do
                    field :a, type: String
                  end
                end
              end
              expects(:inner, on: :payload, type: Hash) do
                field :deep, type: Hash, allow_nil: true
              end
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            deep = schema[:properties][:payload][:properties][:inner][:properties][:deep]
            expect(deep).to eq(type: "object", properties: { a: { type: "string", minLength: 1 } }, required: ["a"], minProperties: 1)
            expect(klass.call(payload: { inner: { deep: nil } })).not_to be_ok # the ancestor's required `a` forbids null here
            expect(klass.call(payload: { inner: { deep: { a: "x" } } })).to be_ok
          end

          # A map's `values:`/`keys:` axes (`additionalProperties`/`propertyNames`) are their own nested
          # schema, both enforced when both colliding sides declare one — the object-vs-object merge above
          # reconciles `properties`/`required`/the size bounds but, before this fix, still let the shallow
          # `merge` at its TOP overwrite one side's `additionalProperties` with the other's outright
          # (Codex review, PR #278 round 24): an ancestor `deep` Hash member whose values axis requires
          # `> 0` beside a colliding node's own `deep` values axis requiring `< 10` emitted only the `< 10`
          # constraint, so `deep: { x: -1 }` passed the schema though the ancestor's own validator (which
          # runs unconditionally, regardless of what the node's own map declares) rejects it. Fixed by
          # conjoining the two nested axis schemas the same way any other single-position collision is.
          it "conjoins colliding values-axis constraints on a nested map rather than letting one win" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :deep, type: Hash, of: { values: { klass: Integer, comparison: { greater_than: 0 } } }
              end
              expects(:deep, on: :payload, type: Hash, of: { values: { klass: Integer, comparison: { less_than: 10 } } })
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            deep = schema[:properties][:payload][:properties][:deep]
            expect(deep).to eq(
              type: "object",
              additionalProperties: { type: "integer", exclusiveMaximum: 10, allOf: [{ type: "integer", exclusiveMinimum: 0 }] },
              minProperties: 1,
            )
            expect(klass.call(payload: { deep: { x: 5 } })).to be_ok
            expect(klass.call(payload: { deep: { x: -1 } })).not_to be_ok # fails the ancestor's own values-axis floor
            expect(klass.call(payload: { deep: { x: 20 } })).not_to be_ok # fails the node's own values-axis ceiling
          end

          # The conjunction above threads NO axis-level configs through, so `unknown_class_approximate?`
          # never fires for either axis — harmless when both axes are exactly typed (Integer), but wrong
          # once one axis is an UNKNOWN-CLASS hint (Codex review, PR #278 round 25): an ancestor `deep`
          # Hash member with `values: Object` (a permissive `single_type_for` HINT, `{type: "string"}`, not
          # a real constraint) beside a colliding node's own `values: Hash` axis (a REAL `{type: "object"}`)
          # conjoined the fake String hint as though it were exact, producing `additionalProperties: {
          # type: "object", allOf: [{ type: "string" }] }` — a node nothing satisfies, though `{ x: {} }`
          # passes both runtime axis validators. Fixed by threading each axis's OWN declared klass token
          # into the recursive conjunction via `axis_configs_for`, so the approximate axis gets the same
          # `unknown_class_approximate?` stripping an approximate FIELD already gets.
          it "strips an approximate axis's fake type hint rather than conjoining it as exact" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :deep, type: Hash, of: { values: Object }
              end
              expects(:deep, on: :payload, type: Hash, of: { values: Hash })
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            deep = schema[:properties][:payload][:properties][:deep]
            expect(deep).to eq(type: "object", additionalProperties: { type: "object" }, minProperties: 1)
            expect(klass.call(payload: { deep: { x: {} } })).to be_ok
          end

          # `axis_configs_for` only carried each axis's own `:klass` into its view, dropping the REST of
          # the axis bag — harmless one level deep, but wrong once the axis itself is ANOTHER map bag with
          # its own nested `values:`/`keys:` axis (Codex review, PR #278 round 26): outer `klass: Hash`
          # axes whose nested values are respectively `Object` and `Hash` lost that inner structure here,
          # so when the merge recursed one level deeper for the INNER axis, `axis_configs_for` found no
          # `:of` to read on the view at all, and the inner `Object` axis's approximate `{type: "string"}`
          # hint was conjoined as exact all over again — the runtime accepts a value containing the nested
          # Hash, but the emitted `additionalProperties` node was unsatisfiable. Fixed by carrying the
          # axis's own `:of` forward into the view alongside its synthesized `:type`, so `axis_configs_for`
          # can keep recursing exactly as deep as the collision itself goes.
          it "preserves nested axis provenance through a doubly-nested map collision" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :deep, type: Hash, of: { values: { klass: Hash, of: { values: Object } } }
              end
              expects(:deep, on: :payload, type: Hash, of: { values: { klass: Hash, of: { values: Hash } } })
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            deep = schema[:properties][:payload][:properties][:deep]
            expect(deep).to eq(
              type: "object",
              additionalProperties: { type: "object", additionalProperties: { type: "object" } },
              minProperties: 1,
            )
            expect(klass.call(payload: { deep: { x: { y: {} } } })).to be_ok
          end

          # An axis's OWN `shape:` names members the same way a field's `shape:` does — `shape_members_at`
          # reads `config.validations.dig(:shape, :members)` off whatever config it's handed — but the
          # view built above only carried `:type`/`:of` forward, not `:shape` (Codex review, PR #278 round
          # 27): two `values: { klass: Hash, shape: { … } }` axes colliding, one naming a child `a` as
          # `Object` and the other as `Hash`, needs the SAME per-child lookup an ordinary object's
          # `properties` collision already gets — without `:shape` on the view, `shape_members_at` found
          # nothing, so the `Object` child's approximate hint was conjoined as exact against the `Hash`
          # child's real one, producing a node nothing satisfies though a nonempty Hash passes both
          # runtime axis validators. Fixed by carrying the axis's own `:shape` forward too.
          it "preserves an axis's own shape members through a collision" do
            object_member = Axn::Core::Contract::ShapeConfig.new(field: :a, validations: { type: Object })
            hash_member = Axn::Core::Contract::ShapeConfig.new(field: :a, validations: { type: Hash })
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :deep, type: Hash, of: { values: { klass: Hash, shape: { members: [object_member] } } }
              end
              expects(:deep, on: :payload, type: Hash, of: { values: { klass: Hash, shape: { members: [hash_member] } } })
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            deep = schema[:properties][:payload][:properties][:deep]
            expect(deep).to eq(
              type: "object",
              additionalProperties: { type: "object", properties: { a: { type: "object" } }, required: ["a"] },
              minProperties: 1,
            )
            expect(klass.call(payload: { deep: { x: { a: { b: 1 } } } })).to be_ok
          end

          # A CLASSLESS axis (legally `klass:`-free — constraining only via its named `shape:` members)
          # still has structure worth keeping even though it names no token at all — round 27's own fix
          # skipped the WHOLE view whenever no `:klass` was found, discarding a classless axis's `:shape`
          # right along with it (Codex review, PR #278 round 29): two `values: { shape: { members: [...] }
          # }` axes colliding, one naming child `a` as `Object` and the other as `Hash`, needs the same
          # per-child config lookup an ordinary object's `properties` collision already gets — without a
          # view at all for either axis, `shape_members_at` found nothing for either side, and the `Object`
          # child's approximate hint was conjoined as exact against the `Hash` child's real one. Fixed by
          # only skipping an axis that is TRULY empty (no token, no `:of`, no `:shape`).
          it "preserves a classless axis's own shape members through a collision" do
            object_member = Axn::Core::Contract::ShapeConfig.new(field: :a, validations: { type: Object })
            hash_member = Axn::Core::Contract::ShapeConfig.new(field: :a, validations: { type: Hash })
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :deep, type: Hash, of: { values: { shape: { members: [object_member] } } }
              end
              expects(:deep, on: :payload, type: Hash, of: { values: { shape: { members: [hash_member] } } })
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            deep = schema[:properties][:payload][:properties][:deep]
            expect(deep).to eq(
              type: "object",
              additionalProperties: { type: "object", properties: { a: { type: "object" } }, required: ["a"] },
              minProperties: 1,
            )
            expect(klass.call(payload: { deep: { x: { a: { b: 1 } } } })).to be_ok
          end

          # An approximate side's TYPE is untrustworthy, but a literal-value `enum` (from `inclusion:`) is
          # not premised on the type at all — JSON Schema applies it to the instance regardless of any
          # `type` keyword, and the runtime keeps enforcing it too. Dropping the whole member — type hint
          # AND exact enum together — let the document accept a value the runtime's inclusion check
          # rejects (Codex review, PR #278 round 5).
          it "keeps an approximate member's exact inclusion enum even though its type hint is dropped" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, type: Object, inclusion: { in: [{ allowed: true }] }
              end
              expects :inner, on: :payload, type: Hash
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            expect(inner).to eq(type: "object", minProperties: 1, allOf: [{ enum: [{ allowed: true }], minProperties: 1 }])
            expect(klass.call(payload: { inner: { allowed: true } })).to be_ok
            expect(klass.call(payload: { inner: { other: true } })).not_to be_ok # not in the ancestor's inclusion list
          end

          # Two sides that are BOTH unknown-class hints never contradict each other (they both fall back to
          # the SAME permissive shape), so this stays unstripped — but an unknown-class member beside a
          # TRANSFORMING node is a different pairing: the node's own emission is forced to `{}` first (it
          # names a post-transform value nothing else reads), and the ancestor's hint, having nothing real
          # to contradict, keeps its FULL property rather than being stripped to just its (here, absent)
          # enum. That is what lets the coercible wire string the runtime accepts still validate (Codex
          # review, PR #278 round 6 — treating both emitted type hints as exact here produced an integer
          # node with an incompatible string allOf branch, admitting nothing).
          it "keeps an unknown-class ancestor's full hint beside a node that transforms, rather than stripping both" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, type: Object
              end
              expects :inner, on: :payload, type: { klass: Integer, coerce: true }
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            expect(inner).to eq(type: "string", minLength: 1)
            expect(klass.call(payload: { inner: "5" })).to be_ok
          end

          # An approximate side's `enum` survives stripping only when it describes the SAME (raw) value
          # the other side reads — a TRANSFORMING side's enum describes its OWN post-transform value
          # instead, so `type`/`anyOf`/`enum` are all still stripped in pass 1 before pass 2 (the
          # enum-preserving stand-down for an unknown-class side) ever runs, unlike the plain-`inclusion:`-
          # on-an-unknown-class case above (Codex review, PR #278 round 6: keeping `enum: [5]` — a target
          # Integer — unstripped conjoined against the ancestor's raw String requirement produced a node
          # nothing satisfies, though the runtime accepts the wire string "5").
          #
          # But dropping the enum's VALUES entirely (rather than just the `type` binding it came with) is
          # its own, opposite-direction gap (Codex review, PR #278 round 9): with nothing surviving beside
          # it, the node contributes nothing beyond the ancestor's bare `type: "string"`, so the schema
          # admits every non-empty string — including "6", though the runtime coerces "6" to Integer 6 and
          # rejects it (only 5 is in the inclusion list). Since `Integer(s, 10)` and `Float(s)` both
          # round-trip through `#to_s`, a numeric enum value's decimal string spelling is a wire form the
          # coercer accepts for it — retaining both spellings (`enum: [5, "5"]`) keeps the schema correct
          # without dropping the constraint or inventing a general coercion inverse.
          it "translates a numeric enum belonging to a config that also transforms its input into its wire-string spelling" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, type: String
              end
              expects :inner, on: :payload, type: { klass: Integer, coerce: true }, inclusion: { in: [5] }
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            expect(inner).to eq(enum: [5, "5"], not: { type: "null" }, allOf: [{ type: "string", minLength: 1 }])
            expect(klass.call(payload: { inner: "5" })).to be_ok
            expect(klass.call(payload: { inner: "6" })).not_to be_ok # coerces to 6, fails inclusion in [5]
          end

          # coerce: false only rules out the COERCION reason a type is approximate — it says nothing about
          # the SEPARATE unknown-class reason, so an unknown class explicitly opted out of coercion is
          # still approximate on its own terms (Codex review, PR #278 round 6 — the opt-out was short-
          # circuiting the whole approximateness check, so `Object` conjoined its fake string type against
          # a real ancestor Hash shape and admitted nothing).
          it "keeps an unknown class approximate even when coerce: false rules out the coercion reason" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, type: Hash do
                  field :a, type: String
                end
              end
              expects :inner, on: :payload, type: { klass: Object, coerce: false }
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            expect(inner).to eq(
              minProperties: 1,
              not: { type: "null" },
              allOf: [{ type: "object", properties: { a: { type: "string", minLength: 1 } }, required: ["a"], minProperties: 1 }],
            )
            expect(klass.call(payload: { inner: { a: "x" } })).to be_ok
          end

          # A shape member can never coerce at all — `coerce:`/`coerce: true` is refused on one at
          # declaration ("it has no reader for a coerced value to resolve onto"), and the ambient
          # `coerce_input_types` flag is a FIELD/reader mechanism a member never routes through either. So
          # an `Integer`-typed member's declared type being merely "coercible in principle" is not a reason
          # to distrust it — its own exact `inclusion:` enum must survive a collision with a node that
          # cannot coerce it either (Codex review, PR #278 round 7 — treating the member as approximate
          # here dropped its `enum` for no reason, since neither side could ever coerce this value).
          it "never treats a shape member as coercible, even when its declared type is one of Coercion::SUPPORTED" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, type: Integer, inclusion: { in: [5] }
              end
              expects :inner, on: :payload, type: { klass: Integer, coerce: false }
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            expect(inner).to eq(type: "integer", allOf: [{ type: "integer", enum: [5] }])
            expect(klass.call(payload: { inner: 5 })).to be_ok
            expect(klass.call(payload: { inner: 6 })).not_to be_ok # not in the member's inclusion list
          end

          # A transforming node's own `length:` is TYPE-CONDITIONAL (JSON Schema never applies it to an
          # instance of some other type), unlike `type`/`anyOf`/`enum` — so it survives stripping alongside
          # the ancestor's real constraint, matching `single_type_for`'s own pre-existing, out-of-scope
          # approximation for how a transforming field's declared size bounds already reflect with no
          # collision at all (Codex review, PR #278 round 8: dropping `length:` here entirely let `"a"`
          # pass `input_schema` though the node's own — identity-preprocessed — length floor rejects it).
          it "keeps a transforming node's own length: floor alongside the ancestor's real constraint" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, type: String
              end
              expects :inner, on: :payload, type: String, length: { minimum: 3 }, preprocess: ->(v) { v }
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            expect(inner).to eq(minLength: 3, allOf: [{ type: "string", minLength: 1 }], not: { type: "null" })
            expect(klass.call(payload: { inner: "abc" })).to be_ok
            expect(klass.call(payload: { inner: "a" })).not_to be_ok # fails the node's own (identity-preprocessed) length floor
          end

          # `const` (NUMERIC_BOUND_KEYS' spelling for a non-nullable `equal_to:`) carries the SAME intrinsic
          # type binding `enum` does — a literal value is itself of some JSON type — so it belongs beside
          # `type`/`anyOf`/`enum` in strip_intrinsically_typed_keys, not among the type-conditional keywords
          # that survive. Found by auditing every keyword the emitter can produce for this same class of gap,
          # rather than waiting for another round to surface it one keyword at a time.
          #
          # DROPPING it outright (Codex review, PR #278 round 9) is its OWN gap in the opposite direction:
          # once `const` is gone with nothing left to survive alongside it, the node contributes NOTHING
          # beyond the ancestor's bare `type: "string"` — so the schema admits every non-empty string,
          # including "6", though the runtime coerces "6" to Integer 6 and rejects it (only 5 passes the
          # equality check). Schema looser than runtime — the one forbidden direction.
          #
          # The fix: since `Coercion::COERCERS[Integer]` parses via `Integer(s, 10)` and `Float` via
          # `Float(s)`, both round-trip through `#to_s` — so a numeric const/enum value's decimal string
          # spelling is a WIRE form the coercer accepts, and retaining both spellings as an `enum` (rather
          # than dropping the constraint) keeps the schema correct without inventing a general coercion-
          # inverse: `enum: [5, "5"]` accepts "5" (matches runtime) and rejects "6" (matches runtime) and
          # rejects the JSON integer 5 too (correctly — the ancestor's own raw-wire `type: "string"`, kept
          # in the `allOf` sibling, still requires the wire form itself to be a String). A non-numeric
          # literal (Symbol/Date/anything else) has no such safe, construction-only translation available
          # and is dropped as before — a narrower, still-tolerated imprecision, filed as a follow-up rather
          # than solved here.
          it "translates a transforming node's own numeric const: into its wire-string spelling instead of dropping it" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, type: String
              end
              expects :inner, on: :payload, type: { klass: Integer, coerce: true }, comparison: { equal_to: 5 }
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            expect(inner).to eq(enum: [5, "5"], not: { type: "null" }, allOf: [{ type: "string", minLength: 1 }])
            expect(klass.call(payload: { inner: "5" })).to be_ok
            expect(klass.call(payload: { inner: "6" })).not_to be_ok # coerces to 6, fails the node's own equal_to: 5
            expect(klass.call(payload: { inner: 5 })).not_to be_ok # fails the ancestor's raw-wire type: String
          end

          # By the time an inclusion enum reaches this function, apply_inclusion_enum! has already rendered
          # any Symbol/Date/Time/DateTime member into its own wire-string spelling (Values.serialize_value —
          # the SAME encoder used for output normalization elsewhere in this file) — `:allowed` became
          # `"allowed"` before strip_intrinsically_typed_keys ever saw it. Dropping a String literal here
          # for being "non-numeric" (Codex review, PR #278 round 10) throws away a spelling that is ALREADY
          # the coercer's accepted wire input (`.to_sym` inverts `.to_s` exactly), leaving the schema unable
          # to distinguish "allowed" (passes) from "other" (coerces to :other, fails inclusion).
          it "retains a coercing node's own already wire-normalized Symbol/Date/Time inclusion enum" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, type: String
              end
              expects :inner, on: :payload, type: { klass: Symbol, coerce: true }, inclusion: { in: [:allowed] }
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            expect(inner).to eq(minLength: 1, enum: ["allowed"], not: { type: "null" }, allOf: [{ type: "string", minLength: 1 }])
            expect(klass.call(payload: { inner: "allowed" })).to be_ok
            expect(klass.call(payload: { inner: "other" })).not_to be_ok # coerces to :other, fails inclusion in [:allowed]
          end

          # A numeric literal's wire-string translation (the round 9 fix, two tests above) is only sound
          # when the transform IS the known coercer — a `preprocess:` can compose with coercion in either
          # order and arbitrarily rescale the result, so its presence invalidates any inference about the
          # net wire-to-value mapping regardless of whether `coerce:` is ALSO explicitly true (Codex
          # review, PR #278 round 10: the reported repro paired `preprocess:` with `coerce: false`, but
          # `coerce: true` alongside the SAME preprocess is just as unsound and isn't already caught by the
          # explicit-`coerce: false` branch — under `coerce: true, preprocess: ->(v) { Integer(v) + 1 },
          # comparison: { equal_to: 5 }`, wire "4" is accepted (coerced then preprocessed to 5) and wire "5"
          # is rejected (preprocessed to 6) — the OPPOSITE of what synthesizing `enum: [5, "5"]` would have
          # advertised). Falls back to dropping the constraint entirely, same as before the round 9 fix
          # existed — a known, tolerated imprecision reflection cannot close without executing the Proc.
          it "does not synthesize a wire spelling for a node whose transform is a preprocess, even beside coerce: true" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, type: String
              end
              expects :inner, on: :payload, type: { klass: Integer, coerce: true }, preprocess: ->(v) { Integer(v) + 1 },
                              comparison: { equal_to: 5 }
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            expect(inner).to eq(type: "string", minLength: 1)
            expect(klass.call(payload: { inner: "4" })).to be_ok # coerced then preprocessed to 5, satisfies equal_to: 5
            expect(klass.call(payload: { inner: "5" })).not_to be_ok # coerced then preprocessed to 6, fails equal_to: 5
          end

          # Round 20 tried exempting a REQUIRED node's own `nil_allowed?` whenever it also has a
          # `preprocess:`, on the premise that the Proc runs before presence is judged and so MIGHT turn a
          # wire `nil` into something non-nil (`preprocess: ->(_) { "x" }` beside an ancestor member
          # constrained to `inclusion: { in: [nil] }` does exactly that, and runtime accepts wire nil). But
          # round 21 showed that same exemption cannot be scoped safely: reflection cannot tell that
          # CONSTANT-preprocess case apart from an ordinary IDENTITY (or any other nil-preserving)
          # `preprocess: ->(v) { v }`, where the Proc does NOT rescue nil and the required check correctly
          # rejects it — `preprocess:` is an opaque Proc, and reflection must not execute it to find out
          # which case it is. So this remains `not: { type: "null" }` even though round 20's OWN scenario
          # would (if it were reachable) accept wire nil at runtime — a known, deliberately unfixed residual
          # (the same "cannot execute user code" limit already accepted for pattern/format and numeric
          # bounds under preprocess elsewhere in this file), preferred over risking the FAR more common
          # identity/pass-through case silently becoming schema-loose.
          it "still rejects null for a required, preprocessing node even beside a nil-tolerant ancestor" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, type: String, optional: true, inclusion: { in: [nil] }
              end
              expects :inner, on: :payload, type: String, preprocess: ->(_) { "x" }
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            expect(inner).to eq(minLength: 1, allOf: [{ type: %w[string null], enum: [nil] }], not: { type: "null" })
            # Deliberately NOT asserting be_ok here: this specific contract does runtime-accept wire nil (the
            # ancestor's own validators skip for nil; the node's constant preprocess always produces "x"),
            # but the schema above cannot honestly express that without the round-21 regression — see the
            # comment above for why this residual is accepted rather than solved.
          end

          # The scenario round 21 actually flagged: an ORDINARY nil-tolerant ancestor (not the exotic
          # "constrained to only nil" case above) beside a required node whose preprocess is IDENTITY —
          # the far more common shape a `preprocess:`-plus-nullability collision takes, and the one round
          # 20's (reverted) exemption got backwards: it would have skipped `reject_null!` here too, letting
          # the schema accept wire `nil` though the identity preprocess never rescues it and the required
          # check genuinely rejects it at runtime.
          it "rejects null for a required, identity-preprocessing node beside an ordinary nil-tolerant ancestor" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, type: String, optional: true
              end
              expects :inner, on: :payload, type: String, preprocess: ->(v) { v }
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            expect(inner).to include(not: { type: "null" })
            expect(klass.call(payload: { inner: nil })).not_to be_ok # identity preprocess never rescues nil; required check rejects it
            expect(klass.call(payload: { inner: "abc" })).to be_ok
          end

          # A type-conditional bound (round 8's `length:`) is safe to KEEP from a `preprocess:`-tainted
          # side ONLY when it does not conjoin into an EMPTY interval with a bound the OTHER side
          # independently asserts (Codex review, PR #278 round 11): the ancestor's `minLength: 3` runs
          # against the RAW value, the node's own `maxLength: 1` runs against `v[0]` (always a single
          # character) — genuinely satisfiable at runtime (a 3+ char string always has a 1-char first
          # character), but conjoining both bounds unstripped produces `minLength: 3, maxLength: 1`, which
          # no string can satisfy. `drop_conflicting_size_bounds` detects the empty interval and drops the
          # node's own (untrustworthy, preprocess-derived) pair rather than emitting it.
          it "drops a preprocessing node's own size bound rather than conjoin it into an empty interval" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, type: String, length: { minimum: 3 }
              end
              expects :inner, on: :payload, type: String, length: { maximum: 1 }, preprocess: ->(v) { v[0] }
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            expect(inner).to eq(type: "string", minLength: 3)
            expect(klass.call(payload: { inner: "abc" })).to be_ok # ancestor's raw length passes, node's transformed check is vacuous
            expect(klass.call(payload: { inner: "ab" })).not_to be_ok # fails the ancestor's own raw minLength: 3
          end

          # An unknown-class member's TYPE-CONDITIONAL constraints are just as trustworthy as an exactly-
          # typed member's — nothing about it transforms the value, so a real `length:` validator still
          # runs against the SAME raw value the colliding node reads. Slicing the approximate side down to
          # `.slice(:enum)` (rather than `.except(:type, :anyOf)`, dropping only the fake type) discarded
          # this along with the fake type for no reason (Codex review, PR #278 round 11): `type: Object,
          # length: { minimum: 3 }` beside an explicit `type: String` node let a 1-character string pass
          # the schema though the member's real length floor rejects it at runtime.
          it "keeps an unknown-class member's real length: validator, not just its enum" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, type: Object, length: { minimum: 3 }
              end
              expects :inner, on: :payload, type: String
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            expect(inner).to eq(type: "string", minLength: 1, allOf: [{ minLength: 3 }])
            expect(klass.call(payload: { inner: "abc" })).to be_ok
            expect(klass.call(payload: { inner: "a" })).not_to be_ok # fails the member's own real length: { minimum: 3 }
          end

          # `minLength`/`maxLength` is only the RIGHT keyword when the surviving side turns out to be a
          # String — `single_type_for`'s "string" fallback names it regardless of what the collision reveals
          # the real type to be, and JSON Schema silently ignores `minLength` for a non-string instance
          # (Codex review, PR #278 round 13, following directly from the fix above): `type: Object, length:
          # { minimum: 3 }` beside a colliding `type: Hash` node kept `minLength: 3` sitting inertly beside
          # the object schema, so a one-property Hash passed the schema though the member's real length
          # floor (`Hash#length`, its key count) rejects it at runtime. `retarget_unknown_class_length`
          # renames it to `minProperties` once the surviving type is known to be an object (or `minItems`
          # for an Array), so the constraint is actually enforced rather than left type-inapplicable.
          it "retargets an unknown-class member's length: to the surviving object type's own size keyword" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, type: Object, length: { minimum: 3 }
              end
              expects :inner, on: :payload, type: Hash
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            expect(inner).to eq(type: "object", minProperties: 1, allOf: [{ minProperties: 3 }])
            expect(klass.call(payload: { inner: { a: 1, b: 2, c: 3 } })).to be_ok
            expect(klass.call(payload: { inner: { a: 1 } })).not_to be_ok # fails the member's own real length: { minimum: 3 }
          end

          # A UNION survivor (`type: [Hash, Array]`) has no top-level `type` — its own emission is `anyOf`
          # branches, one per member type — so reading `other_prop[:type]` alone (the fix above) missed it
          # and dropped the bound entirely (Codex review, PR #278 round 15): `type: Object, length: {
          # minimum: 3 }` beside a colliding `type: [Hash, Array]` node let a one-item Array OR a
          # one-property Hash pass, though the member's real length floor rejects both. A single retargeted
          # keyword can't serve every branch — `minProperties` would be silently ignored (vacuously true)
          # for an Array instance — so each branch gets its OWN paired `{type:, sizeKey:}` entry in a new
          # `anyOf`, which is what makes the bound actually discriminate by the instance's real type.
          it "retargets an unknown-class member's length: into each branch of a union survivor" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, type: Object, length: { minimum: 3 }
              end
              expects :inner, on: :payload, type: [Hash, Array]
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            expect(inner).to eq(
              anyOf: [{ type: "object", minProperties: 1 }, { type: "array", minItems: 1 }],
              allOf: [{ anyOf: [{ type: "object", minProperties: 3 }, { type: "array", minItems: 3 }] }],
            )
            expect(klass.call(payload: { inner: { a: 1, b: 2, c: 3 } })).to be_ok
            expect(klass.call(payload: { inner: [1, 2, 3] })).to be_ok
            expect(klass.call(payload: { inner: { a: 1 } })).not_to be_ok # fails the member's own real length: { minimum: 3 }
            expect(klass.call(payload: { inner: [1] })).not_to be_ok # fails the member's own real length: { minimum: 3 }
          end

          # `:boolean` accepts several wire spellings for one native value, unlike Integer/Float's single
          # canonical `#to_s` — but `Coercion.boolean_wire_spellings` is the single source for the WHOLE
          # accepted set, so a coercible boolean literal is translated the same way a numeric one is
          # (Codex review, PR #278 round 11): dropping it entirely let a raw String ancestor's schema
          # accept "false", though coercion turns that into `false` and fails `inclusion: { in: [true] }`
          # at runtime.
          it "translates a coercing node's own boolean inclusion enum into its wire spellings" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, type: String
              end
              expects :inner, on: :payload, type: { klass: :boolean, coerce: true }, inclusion: { in: [true] }
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            expect(inner).to eq(
              enum: [true, 1, "1", "true", "t", "yes", "y", "on"],
              not: { type: "null" },
              allOf: [{ type: "string", minLength: 1 }],
            )
            expect(klass.call(payload: { inner: "true" })).to be_ok
            expect(klass.call(payload: { inner: "false" })).not_to be_ok # coerces to false, fails inclusion in [true]
          end

          # `drop_conflicting_size_bounds` (round 11) checked only `minimum`/`maximum`, missing exactly the
          # keywords `numericality:`/`comparison:` actually emit for a strict bound — `exclusiveMinimum`/
          # `exclusiveMaximum` (Codex review, PR #278 round 12): an ancestor `numericality: { greater_than:
          # 3 }` beside a colliding preprocessing node's `comparison: { less_than: 2 }` accepts raw `4` at
          # runtime (the ancestor checks 4 > 3; the node's own check runs on `4 - 3 = 1 < 2`), but keeping
          # both bounds conjoined `exclusiveMinimum: 3` with `exclusiveMaximum: 2` — a node no integer can
          # satisfy.
          it "drops a preprocessing node's own exclusive numeric bound rather than conjoin it into an empty interval" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, type: Integer, numericality: { greater_than: 3 }
              end
              expects :inner, on: :payload, type: Integer, comparison: { less_than: 2 }, preprocess: ->(v) { v - 3 }
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            expect(inner).to eq(type: "integer", exclusiveMinimum: 3)
            expect(klass.call(payload: { inner: 4 })).to be_ok # ancestor's raw bound passes; node's transformed check is vacuous (4-3=1 < 2)
            expect(klass.call(payload: { inner: 3 })).not_to be_ok # fails the ancestor's own exclusiveMinimum: 3
          end

          # Round 12's own conflict check compares the bounds as a CONTINUOUS interval — it misses an
          # interval that's non-empty over the reals but contains no INTEGER at all (Codex review, PR #278
          # round 23): an ancestor Integer member's `comparison: { greater_than: 1 }` (`exclusiveMinimum:
          # 1`) beside a colliding Integer node's `preprocess: ->(v) { v - 1 }, comparison: { less_than: 2
          # }` (`exclusiveMaximum: 2`) accepts raw `2` at runtime (the ancestor's own check reads the raw
          # value 2, which is `> 1`; the node's own check runs on the preprocessed `1`, which is `< 2`),
          # but `exclusiveMinimum: 1` conjoined with `exclusiveMaximum: 2` describes an integer strictly
          # between 1 and 2 — none exists — an unsatisfiable schema for a satisfiable contract. Fixed by
          # also treating an integer-only domain with no integral point in the combined interval as a
          # conflict, so the node's own bound stands down the same way an outright-empty interval already
          # does.
          it "drops a preprocessing node's own numeric bound when the combined interval has no integer, not just when it's empty" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, type: Integer, comparison: { greater_than: 1 }
              end
              expects :inner, on: :payload, type: Integer, comparison: { less_than: 2 }, preprocess: ->(v) { v - 1 }
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            expect(inner).to eq(type: "integer", exclusiveMinimum: 1)
            expect(klass.call(payload: { inner: 2 })).to be_ok # ancestor's raw bound (2 > 1) and node's transformed check (2-1=1 < 2) both pass
            expect(klass.call(payload: { inner: 1 })).not_to be_ok # fails the ancestor's own exclusiveMinimum: 1
          end

          # A wire-spelling candidate is safe only if it ACTUALLY round-trips through the real coercer for
          # THIS declared type — a union target changes which candidates survive, which a class-only check
          # (round 9-11: "it's a String, so it's already safe") cannot see (Codex review, PR #278 round
          # 12): under a `[Integer, String]` coercing type, the literal "5" decodes to Integer 5 (Integer is
          # tried first and succeeds), never remaining String "5" — so no wire value could ever satisfy an
          # inclusion check against the literal String "5", and it must be dropped; "ok" is untouched by
          # either coercion target and survives unchanged.
          it "drops a wire-unreachable string enum entry under a union coercion target, keeping a reachable one" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, type: String
              end
              expects :inner, on: :payload, type: { klass: [Integer, String], coerce: true }, inclusion: { in: %w[5 ok] }
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            expect(inner).to eq(enum: ["ok"], not: { type: "null" }, allOf: [{ type: "string", minLength: 1 }])
            expect(klass.call(payload: { inner: "ok" })).to be_ok
            expect(klass.call(payload: { inner: "5" })).not_to be_ok # decodes to Integer 5, never String "5" — never in the inclusion set
          end

          # An all-`nil` literal set must not be discarded merely because compacting it first (to classify
          # the REST) leaves nothing behind — `nil` is never wire-transformed by coercion at all (round 8's
          # own justification), so `enum: [nil]` round-trips trivially and is exactly as safe to keep as any
          # other coercible literal (Codex review, PR #278 round 12): a nil-tolerant coercing `Integer` node
          # with `inclusion: { in: [nil] }` beside a nil-tolerant String ancestor accepts nil and rejects
          # every non-nil wire value at runtime (nothing else is in the inclusion set), but the previous
          # compact-first check returned `nil` — "no safe translation" — for this literal set, dropping the
          # constraint and letting the schema accept "5".
          it "keeps an all-nil enum rather than treating it as having no safe translation" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, type: String, optional: true
              end
              expects :inner, on: :payload, type: { klass: Integer, coerce: true }, inclusion: { in: [nil] }, optional: true
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            expect(inner).to eq(enum: [nil], allOf: [{ type: %w[string null] }])
            expect(klass.call(payload: { inner: nil })).to be_ok
            expect(klass.call(payload: { inner: "5" })).not_to be_ok # coerces to 5, not in the inclusion set [nil]
          end

          # `merge_shape_member_property` reassigns `properties`/`required` unconditionally from the
          # recursive merge/merge_emitted_required result, which is `nil` (nothing to merge) when NEITHER
          # colliding side has any children at all — writing that `nil` through leaves an INVALID document:
          # JSON Schema requires `properties` to be an object and `required` to be an array, never `null`
          # (Codex review, PR #278 round 13). Two colliding bare `type: Hash` declarations, neither with a
          # `field`/`expects` block, is the minimal repro.
          it "omits properties:/required: entirely rather than writing them in as null when neither colliding side has children" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, type: Hash do
                  field :deep, type: Hash
                end
              end
              expects(:inner, on: :payload, type: Hash) do
                field :deep, type: Hash
              end
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            deep = schema[:properties][:payload][:properties][:inner][:properties][:deep]
            expect(deep).to eq(type: "object", minProperties: 1)
            expect(deep).not_to have_key(:properties)
            expect(deep).not_to have_key(:required)
            expect(klass.call(payload: { inner: { deep: { a: 1 } } })).to be_ok
          end

          # A `pattern`/`format` retained from a `preprocess:`-tainted side has no cheap, always-correct
          # emptiness check the way a numeric interval does ("do these two regexes share a match" isn't
          # decidable at this cost), so it is dropped outright rather than risk conjoining two DISJOINT
          # patterns into a node nothing can satisfy (Codex review, PR #278 round 13): an ancestor
          # `/\Aa+\z/` beside a colliding `preprocess: ->(_) { "b" }, format: /\Ab+\z/` node accepts raw "a"
          # at runtime (the node's own check runs on the CONSTANT "b", which its pattern matches
          # unconditionally), but conjoining both patterns requires one wire string to match both — none can.
          # Once its own pattern AND its own presence floor (round 22's `drop_length_bound_beside_sibling_
          # pattern` — see the test below) are both stripped, the node contributes NOTHING at all, so the
          # conjunction routes through the empty-side merge and the ancestor's exact property (a plain,
          # scalar `type: "string"`, which already excludes null on its own — no separate `not: {type:
          # "null"}` needed) is the whole story.
          it "drops a preprocessing node's own pattern rather than conjoin it with the ancestor's disjoint one" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, type: String, format: { with: /\Aa+\z/ }
              end
              expects :inner, on: :payload, type: String, format: { with: /\Ab+\z/ }, preprocess: ->(_) { "b" }
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            expect(inner).to eq(type: "string", minLength: 1, pattern: "^a+$")
            expect(klass.call(payload: { inner: "a" })).to be_ok # matches the ancestor's raw pattern; node's own check is vacuous
            expect(klass.call(payload: { inner: "x" })).not_to be_ok # fails the ancestor's own raw pattern
          end

          # A retained `minLength`/`maxLength` has no cheap, always-correct compatibility check against a
          # sibling `pattern`/`format` the way it does against a discrete literal set (regex satisfiability
          # analysis isn't something reflection can do safely and generally) — so it is stood down
          # UNCONDITIONALLY whenever the sibling has ANY pattern/format, the same "cannot verify, so don't
          # risk it" resolution round 13 already uses for a transforming side's OWN pattern (Codex review,
          # PR #278 round 22): an ancestor `format: { with: /\Aa\z/ }` (matching only the single string "a",
          # length 1) beside a colliding node's `length: { minimum: 3 }, preprocess: ->(v) { v * 3 }` accepts
          # wire "a" at runtime (the ancestor's own check matches "a" exactly; the node's own check runs on
          # the preprocessed "aaa"), but conjoining `minLength: 3` with the ancestor's pattern produced a
          # node no string can satisfy at all.
          it "drops a transforming node's own length: bound when a sibling pattern's compatibility can't be verified" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, type: String, format: { with: /\Aa\z/ }
              end
              expects :inner, on: :payload, type: String, length: { minimum: 3 }, preprocess: ->(v) { v * 3 }
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            expect(inner).to eq(type: "string", minLength: 1, pattern: "^a$")
            expect(klass.call(payload: { inner: "a" })).to be_ok # matches the ancestor's raw pattern; node's own check runs on preprocessed "aaa"
          end

          # A wire-spelling candidate's SERIALIZED form matching the emitted literal isn't enough — a
          # `Date`/`Symbol`/`Time` value and a plain String that merely happens to render the same way are
          # indistinguishable once serialized, but only one of them is what a coercing `inclusion:`
          # validator actually holds (Codex review, PR #278 round 13): under `type: { klass: [Date, String],
          # coerce: true }, inclusion: { in: ["2026-01-01", "fallback"] } }`, the literal "2026-01-01" was
          # DECLARED as a plain String — but `Date.parse("2026-01-01")` renders back to the identical text,
          # so a serialized-form comparison wrongly treated it as a safe spelling. It coerces to a Date,
          # which is never `==` a String even when they render the same, so no wire value could ever satisfy
          # the inclusion check via that entry; "fallback" is untouched by either coercion target and
          # survives (comparing the coerced result against the RAW, pre-normalization literal by plain `==`
          # is what tells the two apart).
          it "excludes a wire spelling whose serialized form matches but whose coerced type does not" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, type: String
              end
              expects :inner, on: :payload, type: { klass: [Date, String], coerce: true },
                              inclusion: { in: %w[2026-01-01 fallback] }
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            expect(inner).to eq(enum: ["fallback"], not: { type: "null" }, allOf: [{ type: "string", minLength: 1 }])
            expect(klass.call(payload: { inner: "fallback" })).to be_ok
            expect(klass.call(payload: { inner: "2026-01-01" })).not_to be_ok # coerces to a Date, never String "2026-01-01"
          end

          # Two DIFFERENT declared literals can normalize to the identical wire spelling — matching only
          # the FIRST one that renders that way (the fix above) still gets this wrong when the first match
          # happens to be the wrong-typed one (Codex review, PR #278 round 15): `inclusion: { in:
          # ["2026-01-01", Date.new(2026, 1, 1)] }` under a `[Date, String]` coercing type has BOTH entries
          # render to "2026-01-01" — picking only the String (declared first) made the candidate "2026-01-01"
          # fail to round-trip (it coerces to a Date, never that String) even though it round-trips fine
          # against the SECOND entry, the Date literal itself. Checking every raw literal sharing that
          # spelling — not just the first — is what recovers the safe spelling.
          it "matches a normalized literal against every source literal sharing that spelling, not just the first" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, type: String
              end
              expects :inner, on: :payload, type: { klass: [Date, String], coerce: true },
                              inclusion: { in: ["2026-01-01", Date.new(2026, 1, 1)] }
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            expect(inner).to eq(enum: ["2026-01-01"], not: { type: "null" }, allOf: [{ type: "string", minLength: 1 }])
            expect(klass.call(payload: { inner: "2026-01-01" })).to be_ok
            expect(klass.call(payload: { inner: "other" })).not_to be_ok # coerces to neither Date literal, fails inclusion
          end

          # A size/numeric bound retained on a transforming side can be unsatisfiable at the SCHEMA level
          # even with no COMPETING bound on the other side at all — `enum`/`const` names the EXACT set of
          # values the position may take, and JSON Schema evaluates every keyword against the SAME instance,
          # so if not one of those literals could ever satisfy the bound, nothing can ever satisfy the
          # conjunction (Codex review, PR #278 round 17): an ancestor `inclusion: { in: ["a"] }` (a single,
          # 1-character literal) beside a colliding node's `length: { minimum: 3 }, preprocess: ->(v) { v *
          # 3 } }` accepts raw "a" at runtime (the ancestor's own check requires the RAW value to equal "a";
          # the node's own check runs on the preprocessed "aaa"), but the SCHEMA required one wire string to
          # both equal "a" (length 1) and have length >= 3 — impossible, regardless of what preprocess does
          # at runtime, since `enum` and `minLength` are both asked of the identical schema instance.
          it "drops a retained size bound the other side's own literal enum could never satisfy" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, type: String, inclusion: { in: ["a"] }
              end
              expects :inner, on: :payload, type: String, length: { minimum: 3 }, preprocess: ->(v) { v * 3 }
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            expect(inner).to eq(type: "string", enum: ["a"], minLength: 1)
            expect(klass.call(payload: { inner: "a" })).to be_ok # ancestor's literal "a" passes; node's check runs on preprocessed "aaa"
          end

          # `collision_types` (round 13/15's union-aware helper), not a bare `other_prop[:type]` read: a
          # UNION survivor spells its types under `anyOf`, not a top-level `type` (Codex review, PR #278
          # round 17): an ancestor `type: [Integer, String]` beside the SAME coercing `comparison: {
          # greater_than: 5 }` node let a raw (already-numeric) wire integer `3` through, since
          # `other_prop[:type]` was nil for the union and the bound was dropped though an Integer branch
          # genuinely admits — and needs — it. Round 17 kept the bound UNSCOPED (a plain top-level keyword,
          # not retargeted per branch the way length: is), documenting the union's OTHER, non-numeric
          # branch (a wire String that coerces to a violating number) as an accepted residual — but round
          # 33 closed that residual too: a bare `exclusiveMinimum:` beside the survivor's own `anyOf` left
          # the STRING branch completely uncontained (JSON Schema silently ignores a numeric keyword for a
          # non-numeric instance), so wire `"3"` satisfied `type: "string"` and was never checked against
          # the bound at all — the schema admitted it though the runtime coerces it to `3` and rejects it.
          # Fixed by narrowing THIS side's own `:type` to just the numeric-admitting subset, so the eventual
          # conjunction with the survivor's own `anyOf` requires an instance to be BOTH.
          it "narrows a coercing node's own type to the numeric branch when a union survivor also admits a string" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, type: [Integer, String]
              end
              expects :inner, on: :payload, type: { klass: Integer, coerce: true }, comparison: { greater_than: 5 }
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            expect(inner).to eq(
              exclusiveMinimum: 5,
              type: "integer",
              allOf: [{ anyOf: [{ type: "integer" }, { type: "string", minLength: 1 }] }],
            )
            expect(klass.call(payload: { inner: 6 })).to be_ok
            expect(klass.call(payload: { inner: 3 })).not_to be_ok # a raw wire integer, fails comparison: { greater_than: 5 } directly
            expect(klass.call(payload: { inner: "3" })).not_to be_ok # coerces to 3, which also fails comparison: { greater_than: 5 }
          end

          # Narrowing the survivor's TYPE down to just the numeric branch (the fix directly above) is only
          # safe when there's no non-numeric LITERAL witness that specifically needs the excluded branch
          # (Codex review, PR #278 round 36): a member declared as `type: [Integer, String], inclusion: {
          # in: ["6"] }` beside the SAME coercing node accepts wire "6" at runtime (the member's own type
          # union admits the String, and the node coerces it to 6, satisfying `> 5`), but narrowing to
          # `type: "integer"` excludes "6" itself (it's a String) — conjoined with the member's own `enum:
          # ["6"]`, nothing satisfies the result. Fixed by retargeting via the SAME literal mechanism the
          # untyped case already uses (keeping each literal that, once coerced, satisfies the bound, in
          # its ORIGINAL form) whenever a non-numeric literal witness exists, narrowing the type only when
          # there is none to lose.
          it "retargets via literals instead of narrowing the type when a non-numeric witness exists" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, type: [Integer, String], inclusion: { in: ["6"] }
              end
              expects :inner, on: :payload, type: { klass: Integer, coerce: true }, comparison: { greater_than: 5 }
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            expect(inner).to eq(
              enum: ["6"],
              not: { type: "null" },
              allOf: [{ anyOf: [{ type: "integer" }, { type: "string", minLength: 1 }], enum: ["6"] }],
            )
            expect(klass.call(payload: { inner: "6" })).to be_ok # coerces to 6, satisfying comparison: { greater_than: 5 }
          end

          # Round 8's premise (a KNOWN coercer preserves a bound's measured property) holds for Symbol
          # (`.to_s`/`.to_sym` are exact inverses) but not for Time/DateTime/Date, whose canonical rendering
          # can have a different length than whatever wire spelling was actually parsed (Codex review, PR
          # #278 round 18): a raw `String` member's `length: { is: 20 }` beside a colliding `type: { klass:
          # Time, coerce: true }, length: { is: 23 } }` node accepts "2026-08-25T12:00:00Z" (wire length 20)
          # at runtime — the ancestor checks that raw string; the node's own check runs on `Time#to_s` of
          # the parsed value (length 23) — but conjoining both `minLength`/`maxLength` pairs unstripped
          # produced an interval nothing satisfies (`>= 23` and `<= 20`). `drop_conflicting_size_bounds` (and
          # the `pattern`/`format` drop beside it) now run regardless of transform kind, not only under
          # `preprocess:`.
          it "drops a coercing node's own conflicting length: bound when the coercer does not preserve size" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, type: String, length: { is: 20 }
              end
              expects :inner, on: :payload, type: { klass: Time, coerce: true }, length: { is: 23 }
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            expect(inner).to eq(type: "string", minLength: 20, maxLength: 20)
            expect(klass.call(payload: { inner: "2026-08-25T12:00:00Z" })).to be_ok # wire length 20; Time#to_s (length 23) never schema-checked
          end

          # `drop_bounds_contradicted_by_other_literals` (round 17) concatenated the other side's `const`
          # and `enum` instead of intersecting them, even though both are enforced (an AND, not an OR) when
          # both are declared — hiding a real conflict (Codex review, PR #278 round 18): an ancestor member
          # with `const: 1` (from `comparison: { equal_to: 1 }`) AND `enum: [1, 5]` (from `inclusion: { in:
          # [1, 5] } }`) truly admits only `1` (`5` is in the inclusion list but fails the separate equality
          # check) — but concatenating `[1, 1, 5]` let the unrelated `5` survive the "does every literal
          # violate this bound" check, hiding the conflict a colliding `comparison: { greater_than: 3 }`
          # (after a preprocess mapping 1 -> 4) actually has with the position's TRUE, intersected value set
          # of just `{1}`.
          it "intersects the other side's const: and enum: before checking bound contradiction, not concatenates them" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, type: Integer, comparison: { equal_to: 1 }, inclusion: { in: [1, 5] }
              end
              expects :inner, on: :payload, type: Integer, preprocess: ->(v) { v == 1 ? 4 : v }, comparison: { greater_than: 3 }
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            expect(inner).to eq(type: "integer", enum: [1, 5], const: 1)
            expect(klass.call(payload: { inner: 1 })).to be_ok # the ancestor's true (intersected) value set is just {1}; preprocessed to 4, passes > 3
          end

          # A floor and its ceiling in the SAME family must be judged TOGETHER, not independently — a
          # DIFFERENT literal can satisfy EACH one on its own while no literal satisfies both at once
          # (Codex review, PR #278 round 19): an ancestor `enum: ["a", "aaaa"]` beside a colliding node's
          # `length: { is: 2 }, preprocess: ->(_) { "aa" }` has "a" (length 1) satisfy `maxLength: 2` but
          # fail `minLength: 2`, and "aaaa" (length 4) satisfy `minLength: 2` but fail `maxLength: 2` — so
          # judged independently EACH keyword survives (some literal satisfies THAT one), yet the true
          # combined interval (exactly length 2) admits neither literal at all.
          it "drops a whole bound family when no single literal satisfies every bound in it jointly" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, type: String, inclusion: { in: %w[a aaaa] }
              end
              expects :inner, on: :payload, type: String, length: { is: 2 }, preprocess: ->(_) { "aa" }
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            expect(inner).to eq(type: "string", enum: %w[a aaaa], minLength: 1)
            expect(klass.call(payload: { inner: "a" })).to be_ok # preprocessed to constant "aa", satisfies length: { is: 2 }
            expect(klass.call(payload: { inner: "aaaa" })).to be_ok # preprocessed to constant "aa", satisfies length: { is: 2 }
          end

          # A union branch whose type has no matching JSON size keyword (Integer) must be OMITTED from the
          # retargeted `anyOf`, not left as a bare, unconstrained `{type:}` — the underlying `length:`
          # validator still runs against whatever the runtime value is (`#to_s.length` when the value has
          # no native `#length`), so admitting every instance of that type unconditionally accepts values
          # the validator actually rejects (Codex review, PR #278 round 19): an ancestor `type: Object,
          # length: { minimum: 3 }` beside an explicit `type: { klass: [String, Integer], coerce: false }`
          # node let wire integer `1` through unconstrained, though `1.to_s.length` (1) fails `minimum: 3`.
          # Reflection may be STRICTER than the runtime (never looser), so omitting the inexpressible branch
          # — rejecting every integer at this position rather than admitting all of them — is the safe
          # direction, even though some individually-valid integers are no longer admitted either.
          it "omits a union branch with no matching size keyword rather than leaving it unconstrained" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, type: Object, length: { minimum: 3 }
              end
              expects :inner, on: :payload, type: { klass: [String, Integer], coerce: false }
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            expect(inner).to eq(
              anyOf: [{ type: "string", minLength: 1 }, { type: "integer" }],
              allOf: [{ anyOf: [{ type: "string", minLength: 3 }] }],
            )
            expect(klass.call(payload: { inner: 1 })).not_to be_ok # "1".length is 1, fails the member's own length: { minimum: 3 }
            expect(klass.call(payload: { inner: "abc" })).to be_ok
          end

          # Omitting an inexpressible union branch WHOLESALE (the fix above) is itself too strict when a
          # SIBLING declaration at the SAME position names a specific literal of that type — the runtime's
          # `length:` validator measures a non-string value via `#to_s.length`, so a literal whose rendered
          # form happens to satisfy the bound is a CONCRETE, known-satisfiable witness the schema should not
          # discard (Codex review, PR #278 round 20): `type: { klass: [String, Integer], coerce: false },
          # inclusion: { in: [123, "a"] }` beside the SAME ancestor `length: { minimum: 3 }` needs the
          # Integer branch to admit `123` specifically — `"123".length` is 3 — but the blanket omission
          # rejected every integer, turning a satisfiable contract's schema unsatisfiable once conjoined
          # with the sibling `enum: [123, "a"]` (123 failing the string-only branch, "a" failing its own
          # length). Each sibling literal of an inexpressible type is checked against the bound via its own
          # wire rendering and, if it passes, added to a dedicated `enum`-only branch.
          it "preserves a sibling literal of an inexpressible type when its wire rendering satisfies the bound" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, type: Object, length: { minimum: 3 }
              end
              expects :inner, on: :payload, type: { klass: [String, Integer], coerce: false }, inclusion: { in: [123, "a"] }
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            expect(inner).to eq(
              anyOf: [{ type: "string", minLength: 1 }, { type: "integer" }],
              enum: [123, "a"],
              allOf: [{ anyOf: [{ type: "string", minLength: 3 }, { enum: [123] }] }],
            )
            expect(klass.call(payload: { inner: 123 })).to be_ok # "123".length is 3, satisfies the member's own length: { minimum: 3 }
            expect(klass.call(payload: { inner: "a" })).not_to be_ok # "a".length is 1, fails the member's own length: { minimum: 3 }
          end

          # Round 20's fix only reads the SIBLING's own literals (`declared_literals(other_prop)`) — it
          # misses the case where the approximate MEMBER ITSELF is the only side naming a literal witness
          # (Codex review, PR #278 round 23): an ancestor `type: Object, length: { minimum: 3 },
          # inclusion: { in: [123] }` colliding with an explicit `type: { klass: [String, Integer], coerce:
          # false }` node (no `inclusion:` of its own) accepts raw `123` at runtime ("123".length is 3,
          # satisfying the ancestor's own length floor), but the member's OWN retained `enum: [123]` was
          # conjoined against an `anyOf` that omitted the inexpressible Integer branch entirely (there was
          # no literal on the OTHER side to rescue it), leaving `enum: [123]` unsatisfiable beside a
          # `type: "string"`-only `anyOf`. Fixed by also checking the member's own literals when recovering
          # an inexpressible branch, not only the sibling's.
          it "preserves the approximate member's own literal when it's the only witness for an inexpressible branch" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, type: Object, length: { minimum: 3 }, inclusion: { in: [123] }
              end
              expects :inner, on: :payload, type: { klass: [String, Integer], coerce: false }
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            expect(inner).to eq(
              anyOf: [{ type: "string", minLength: 1 }, { type: "integer" }],
              allOf: [{ enum: [123], anyOf: [{ type: "string", minLength: 3 }, { enum: [123] }] }],
            )
            expect(klass.call(payload: { inner: 123 })).to be_ok # "123".length is 3, satisfies the member's own length: { minimum: 3 }
          end

          # An UNTYPED survivor (no `type:`/`anyOf` at all, only a literal `const`/`enum`) leaves
          # `collision_types` empty, and retargeting onto `nil` DROPPED the length bound outright rather
          # than merely narrowing it (Codex review, PR #278 round 28): an ancestor `type: Object, length: {
          # minimum: 3 }` colliding with an untyped node whose `inclusion:` names both a one-key and a
          # three-key Hash emitted only the `enum` — no `minProperties` anywhere — so the schema wrongly
          # accepted the one-key Hash the runtime length floor rejects. Fixed by deriving the retargeted
          # type(s) from the literal VALUES themselves (a Hash literal is "object" regardless of whether
          # anything declared `type: Hash`) whenever there's no declared type to read at all.
          it "retargets a length bound from the literal values themselves when the survivor is untyped" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, type: Object, length: { minimum: 3 }
              end
              expects :inner, on: :payload, inclusion: { in: [{ a: 1 }, { a: 1, b: 2, c: 3 }] }
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            expect(inner).to eq(enum: [{ a: 1 }, { a: 1, b: 2, c: 3 }], not: { type: "null" }, allOf: [{ minProperties: 3 }])
            expect(klass.call(payload: { inner: { a: 1 } })).not_to be_ok # only 1 key, fails the ancestor's own length: { minimum: 3 }
            expect(klass.call(payload: { inner: { a: 1, b: 2, c: 3 } })).to be_ok
          end

          # The SAME "no declared type to read" gap applies to a numeric bound, not just a length one
          # (Codex review, PR #278 round 28): an untyped shape member's `inclusion: { in: [3, 6, "ok"] }`
          # beside a colliding coercing Integer node requiring `> 5` dropped the bound entirely (collision_
          # types is empty, so nothing "admits a number"), leaving just the raw `enum: [3, 6, "ok"]` — the
          # schema wrongly accepted `3` and `"ok"`, though the runtime rejects both (3 fails the
          # comparison; "ok" is never coerced, being a String, and fails the node's own Integer check) and
          # accepts only `6`. Fixed by filtering the literals down to the ones the bound actually admits
          # (never a non-Numeric one) and retargeting to `enum`, instead of discarding the bound wholesale.
          it "retargets a numeric bound to only the literals it admits when the survivor is untyped" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, inclusion: { in: [3, 6, "ok"] }
              end
              expects :inner, on: :payload, type: { klass: Integer, coerce: true }, comparison: { greater_than: 5 }
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            # `type: "integer"` survives here (round 32) since the ancestor `field :inner` declares no
            # `type:` of its own to strip the node's own type FOR — a purely cosmetic sharpening (the
            # `enum: [6]` already pins the value exactly either way, so admissibility is unchanged).
            expect(inner).to eq(enum: [6], type: "integer", allOf: [{ enum: [3, 6, "ok"] }])
            expect(klass.call(payload: { inner: 3 })).not_to be_ok # fails the node's own comparison: { greater_than: 5 }
            expect(klass.call(payload: { inner: 6 })).to be_ok
            expect(klass.call(payload: { inner: "ok" })).not_to be_ok # never coerced (not numeric-shaped) and fails the node's own Integer check
          end

          # A SOLE derived type with no size keyword (round 28's own fix, deriving "integer" from a
          # literal-only survivor) went through `retarget_length_to_type`'s single-type branch, which
          # retargets BLINDLY — safe only when that one type actually HAS a size keyword, since then the
          # untouched sibling `enum` still filters each literal correctly alongside it. A type with NONE
          # (like "integer") has no such safety net (Codex review, PR #278 round 29): an approximate
          # `Object` member's `length: { minimum: 3 }` colliding with an untyped node whose `inclusion:` is
          # `[1, 123]` (both Integers) emitted both as valid, though the runtime's own length check
          # (`#to_s.length`) rejects `1` (rendered length 1) and accepts `123` (rendered length 3). Fixed
          # by routing this case through `retarget_length_to_union` too, reusing its existing wire-
          # rendering literal filter instead of leaving the bound with nothing to filter by.
          it "filters literals by wire-rendered length when the survivor's sole type has no size keyword" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, type: Object, length: { minimum: 3 }
              end
              expects :inner, on: :payload, inclusion: { in: [1, 123] }
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            expect(inner).to eq(type: "integer", enum: [1, 123], allOf: [{ anyOf: [{ enum: [123] }] }])
            expect(klass.call(payload: { inner: 1 })).not_to be_ok # "1".length is 1, fails the member's own length: { minimum: 3 }
            expect(klass.call(payload: { inner: 123 })).to be_ok # "123".length is 3, satisfies the member's own length: { minimum: 3 }
          end

          # With no literal witness on EITHER side to salvage (no `inclusion:`/`comparison:` anywhere),
          # a sole survivor type with no size keyword left `retarget_length_to_union` with an empty
          # `branches` list — returning `prop` as-is there doesn't merely drop the bound, it deletes the
          # ONLY constraint the property had (Codex review, PR #278 round 31): an ancestor `type: Object,
          # length: { minimum: 3 }` member colliding with an exactly-typed-but-unsized `type: { klass:
          # Integer, coerce: false }` node emitted just `{type: "integer"}` — admitting EVERY integer,
          # though the runtime's own length check (`#to_s.length`) rejects `1` and accepts only integers
          # whose decimal rendering is long enough. There is no JSON Schema keyword for "the string
          # rendering of a non-string value has this size" (round 19's own limit), and round 19 already
          # established the doctrine for exactly this situation in the MULTI-type union case — omit
          # (reject) a type this can't express a bound for, rather than admit it unconditionally. This
          # extends that SAME doctrine to the single-type case round 28/29 introduced, rather than leaving
          # it as the one path that still silently drops the bound.
          it "rejects a sole non-sized type when no literal witness survives to narrow it" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, type: Object, length: { minimum: 3 }
              end
              expects :inner, on: :payload, type: { klass: Integer, coerce: false }
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            expect(inner).to eq(type: "integer", allOf: [{ enum: [] }])
            # satisfies the member's own length: { minimum: 3 } at runtime — a documented, tolerated
            # residual: reflection cannot express this bound and stands unsatisfiable rather than loose
            expect(klass.call(payload: { inner: 123 })).to be_ok
          end

          # `strip_intrinsically_typed_keys` dropped a transforming node's own `type`/`anyOf`
          # UNCONDITIONALLY — correct only when the OTHER side actually makes a competing type claim to
          # strip them FOR (Codex review, PR #278 round 32): an ancestor `field :inner` (genuinely
          # UNTYPED — no `type:` at all, no validators) colliding with an explicit `type: { klass: Integer,
          # coerce: true }` node dropped the node's own `type: "integer"` anyway, and with no literal
          # constraint to translate either, the merged schema retained only the ancestor's generic
          # presence/null constraints — accepting a non-numeric string like "abc" the runtime's own
          # (uncoerced, since coercion only parses valid Integer strings) type check rejects. Fixed by only
          # stripping `type`/`anyOf` when the other side actually has one to conflict with.
          it "keeps a transforming node's own type when the sibling makes no competing type claim" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner
              end
              expects :inner, on: :payload, type: { klass: Integer, coerce: true }
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            expect(inner).to eq(type: "integer")
            expect(klass.call(payload: { inner: "5" })).to be_ok # coerces to 5
            expect(klass.call(payload: { inner: "abc" })).not_to be_ok # never coerces to a number and fails the node's own Integer check
          end

          # Round 32's fix checked only the sibling's `:type`/`:anyOf` — a sibling with NO type at all but
          # a mixed-literal `:enum`/`:const` still carries an intrinsic type claim through its literal
          # VALUES, and can conflict with a kept transformed type exactly as a typed sibling can (Codex
          # review, PR #278 round 33): a `field :inner, inclusion: { in: ["raw", true] }` sibling (no
          # `type:`, but a String/Boolean literal set) beside an Integer node whose `preprocess` always
          # returns a constant accepted raw "raw" at runtime (the node's own check runs on the constant,
          # always Integer-valid), but keeping the node's post-transform `type: "integer"` — with NOTHING
          # of its own to keep it consistent, since this node has no `comparison:`/`inclusion:` of its own
          # to populate a narrowing `enum:` — conjoined it with the sibling's `enum: ["raw", true]`, and
          # neither literal is ever an integer. Fixed by treating the sibling's own `enum`/`const` as a
          # competing claim too — UNLESS `prop` itself has a numeric bound or its own `const`/`enum` that
          # will populate a consistent narrowed enum later in this same function (round 28/30's own tests
          # cover exactly that case, and keeping the type there is correct, not a bug).
          it "strips a transforming node's own type beside a sibling's literal-only claim" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, inclusion: { in: ["raw", true] }
              end
              expects :inner, on: :payload, type: Integer, preprocess: ->(_v) { 10 }
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            expect(inner).to eq(enum: ["raw", true], not: { type: "null" })
            expect(klass.call(payload: { inner: "raw" })).to be_ok # ancestor's inclusion passes; node's own check runs on the preprocessed constant 10
          end

          # Round 33's own exemption also spared the kept type whenever `prop` had its OWN `enum`/`const`
          # — reasoning that its eventual narrowed enum would keep the type consistent. But a node's own
          # `enum`/`const` runs through `translated_literal_constraint`, which translates a literal into
          # EVERY wire spelling reflection can vouch for — routinely BOTH a native and a String form — so
          # the eventual enum is not guaranteed to share the kept type at all, unlike the numeric-bound
          # path (which keeps each retained literal in its ORIGINAL form) round 28/30 actually exercise
          # (Codex review, PR #278 round 34): a sibling `inclusion: { in: ["5", true] }` (mixed literal
          # types, so genuinely untyped) beside `type: { klass: Integer, coerce: true }, inclusion: { in:
          # [5] }` accepts wire "5" at runtime (coerces to 5, satisfying the node's own inclusion), but
          # kept `type: "integer"` conjoined with the translated `enum: [5, "5"]` already excludes the
          # String spelling "5" (it fails `type: "integer"`), and conjoining THAT against the sibling's own
          # `enum: ["5", true]` (which the native `5` can never satisfy either) left nothing that could
          # ever satisfy the whole schema. Fixed by only exempting the NUMERIC-bound path, not a node's own
          # enum/const.
          it "strips a transforming node's own type when its own literal translates to a mixed wire type" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, inclusion: { in: ["5", true] }
              end
              expects :inner, on: :payload, type: { klass: Integer, coerce: true }, inclusion: { in: [5] }
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            expect(inner).to eq(enum: [5, "5"], not: { type: "null" }, allOf: [{ enum: ["5", true] }])
            expect(klass.call(payload: { inner: "5" })).to be_ok # coerces to 5, satisfying the node's own inclusion: { in: [5] }
          end

          # Even the NUMERIC-BOUND exemption itself (round 34's remaining case, believed safe because it
          # keeps each retained literal in its ORIGINAL declared form) can retain a literal whose original
          # form simply ISN'T the kept type (Codex review, PR #278 round 35): a sibling `inclusion: { in:
          # ["6", true] }` (mixed literal types, genuinely untyped) beside a coercing Integer node's
          # `comparison: { greater_than: 5 }` accepts wire "6" at runtime (coerces to 6, satisfying the
          # bound), but `drop_numeric_bounds_unless_type_admits_number` retains the ORIGINAL literal "6"
          # (a String) in the retargeted enum while the exemption keeps `type: "integer"` — "6" itself is
          # never an integer. Rather than adding yet another narrower upfront heuristic, this is caught by
          # a single, unconditional POST-HOC check: whenever the stripped result ends up with both a
          # `:type` and an `:enum`, every enum member must actually BE one of the kept type(s).
          it "drops the kept type when the numeric-bound-retargeted enum ends up a different JSON type" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, inclusion: { in: ["6", true] }
              end
              expects :inner, on: :payload, type: { klass: Integer, coerce: true }, comparison: { greater_than: 5 }
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            expect(inner).to eq(enum: ["6"], not: { type: "null" }, allOf: [{ enum: ["6", true] }])
            expect(klass.call(payload: { inner: "6" })).to be_ok # coerces to 6, satisfying comparison: { greater_than: 5 }
          end

          # `round_tripping_wire_spellings` only ever tried a numeric literal's OWN native form and its
          # canonical `#to_s` spelling — but a numeric coercer's actual inverse admits other spellings too
          # (Codex review, PR #278 round 35): a raw String member restricted to `inclusion: { in: ["05"] }`
          # beside a coercing Integer node restricted to `comparison: { equal_to: 5 }` is satisfiable at
          # runtime (`Integer("05", 10) == 5`), but this function only generated `[5, "5"]` for the literal
          # `5` — never "05" — so the translated enum shared no member with the sibling's own `enum:
          # ["05"]`, though the runtime accepts wire "05". Fixed by also trying the sibling's own declared
          # String literals as round-trip candidates, rather than assuming `#to_s` is the complete inverse.
          it "tries a sibling's own literal spellings when inverting a numeric coercer" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, type: String, inclusion: { in: ["05"] }
              end
              expects :inner, on: :payload, type: { klass: Integer, coerce: true }, comparison: { equal_to: 5 }
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            expect(inner).to eq(
              enum: [5, "5", "05"],
              not: { type: "null" },
              allOf: [{ type: "string", minLength: 1, enum: ["05"] }],
            )
            expect(klass.call(payload: { inner: "05" })).to be_ok # coerces to 5 (Integer("05", 10)), satisfying comparison: { equal_to: 5 }
            expect(klass.call(payload: { inner: "5" })).not_to be_ok # not in the sibling's own inclusion: { in: ["05"] }
          end

          # The SAME gap exists for every OTHER coercer, not just a numeric one (Codex review, PR #278
          # round 36): `Coercion.boolean_wire_spellings(true)` only names its OWN canonical spellings
          # (`TRUTHY_STRINGS`, all lowercase), but `coerce_boolean` itself downcases before comparing — a
          # raw String member restricted to `inclusion: { in: ["TRUE"] }` beside a coercing `:boolean` node
          # restricted to `inclusion: { in: [true] }` is satisfiable at runtime (`coerce_boolean("TRUE") ==
          # true`), but "TRUE" was never among the generated candidates either, since round 35's fix only
          # added sibling candidates for the Integer/Float branch. Fixed by trying sibling candidates
          # universally, regardless of which coercer is actually in play.
          it "tries a sibling's own literal spellings when inverting a boolean coercer" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, type: String, inclusion: { in: ["TRUE"] }
              end
              expects :inner, on: :payload, type: { klass: :boolean, coerce: true }, inclusion: { in: [true] }
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            expect(inner).to eq(
              enum: [true, 1, "1", "true", "t", "yes", "y", "on", "TRUE"],
              not: { type: "null" },
              allOf: [{ type: "string", minLength: 1, enum: ["TRUE"] }],
            )
            expect(klass.call(payload: { inner: "TRUE" })).to be_ok # coerce_boolean downcases before comparing, satisfying inclusion: { in: [true] }
            expect(klass.call(payload: { inner: "true" })).not_to be_ok # not in the sibling's own inclusion: { in: ["TRUE"] }
          end

          # `reject_unretargetable_length_bound` (round 31's own fix) left a PRE-EXISTING `:enum` alone
          # whenever the property already had one — but that stale enum is exactly the set
          # `sibling_literals` was built from, and reaching this branch at all means NONE of its non-null
          # members survived the wire-rendering reachability check (Codex review, PR #278 round 32): a
          # nullable `type: Object, length: { minimum: 3 }, inclusion: { in: [nil, 1] }` member colliding
          # with a nullable, non-coercing Integer node has no retargetable branch (`1.to_s` is too short),
          # but leaving the ancestor's own stale `enum: [nil, 1]` in place admitted `1` anyway — the
          # runtime rejects it, though `nil` (which bypasses the bound entirely) proves the contract
          # itself remains satisfiable. Fixed by ALWAYS overwriting the enum, keeping only an admitted
          # `nil` (every non-null literal already failed the same reachability check).
          it "empties a stale enum down to just an admitted nil when no length-valid witness survives" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, type: Object, length: { minimum: 3 }, inclusion: { in: [nil, 1] }, allow_nil: true
              end
              expects :inner, on: :payload, type: { klass: Integer, coerce: false }, allow_nil: true
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            expect(inner).to eq(type: %w[integer null], allOf: [{ enum: [nil] }])
            expect(klass.call(payload: { inner: nil })).to be_ok
            expect(klass.call(payload: { inner: 1 })).not_to be_ok # "1".length is 1, fails the member's own length: { minimum: 3 }
          end

          # Checking a literal against a numeric bound with a RAW `is_a?(Numeric)` test misses a String
          # literal that COERCES into a number — the same coercer this position's own runtime check reads
          # its wire value through (Codex review, PR #278 round 29): an untyped sibling `enum: ["6", "ok"]`
          # beside a coercing Integer node's `comparison: { greater_than: 5 }` has the known coercer turn
          # wire "6" into 6 (satisfying `> 5`) at runtime, but `"6".is_a?(Numeric)` is false, so it was
          # excluded and the schema kept `enum: []` — unsatisfiable for a satisfiable contract. Fixed by
          # coercing each literal through the SAME coercer before checking whether it satisfies the bound,
          # while still retaining the literal's ORIGINAL (wire) form in the narrowed `enum`.
          it "coerces survivor literals through the declared coercer before retargeting a numeric bound" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, inclusion: { in: %w[6 ok] }
              end
              expects :inner, on: :payload, type: { klass: Integer, coerce: true }, comparison: { greater_than: 5 }
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            expect(inner).to eq(
              enum: ["6"],
              not: { type: "null" },
              allOf: [{ type: "string", minLength: 1, enum: %w[6 ok] }],
            )
            expect(klass.call(payload: { inner: "6" })).to be_ok # coerces to 6, satisfying comparison: { greater_than: 5 }
            expect(klass.call(payload: { inner: "ok" })).not_to be_ok # never coerces to a number and fails the node's own Integer check
          end

          # `retarget_numeric_bound_to_literals` REPLACES the whole `:enum` from scratch — unlike the
          # length-retargeting functions, which only ever add to or leave an existing `:enum` untouched —
          # so silently losing a `nil` member here loses the position's own null-tolerance entirely, not
          # merely simplifying an intersection (Codex review, PR #278 round 30): an untyped shape member's
          # `inclusion: { in: [nil, 3] }, allow_nil: true` beside a colliding coercing Integer node's
          # `comparison: { greater_than: 5 }, allow_nil: true` accepts wire `nil` at runtime (both
          # declarations skip their own validator for it), but `3` alone fails the bound, and the resulting
          # `enum: []` (nil dropped along with everything else) made the property reject every value, nil
          # included. Fixed by preserving an admitted `nil` in the replacement enum.
          it "preserves an admitted nil literal when retargeting a numeric bound" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, inclusion: { in: [nil, 3] }, allow_nil: true
              end
              expects :inner, on: :payload, type: { klass: Integer, coerce: true }, comparison: { greater_than: 5 }, allow_nil: true
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            # `type: ["integer", "null"]` survives here (round 32) for the same reason — the ancestor
            # `field :inner` declares no `type:` of its own, so there's nothing to strip the node's own
            # type FOR. Purely cosmetic: `enum: [nil]` already pins the value exactly either way.
            expect(inner).to eq(enum: [nil], type: %w[integer null], allOf: [{ enum: [nil, 3] }])
            expect(klass.call(payload: { inner: nil })).to be_ok # both declarations skip their own validator for nil
            expect(klass.call(payload: { inner: 3 })).not_to be_ok # fails the node's own comparison: { greater_than: 5 }
          end

          # `const` (from `comparison:`) and `enum` (from `inclusion:`) are BOTH enforced when a node
          # declares both — translating each to its wire spellings and then CONCATENATING them turns an
          # intersection into a union (Codex review, PR #278 round 14): `inclusion: { in: [5, 6] },
          # comparison: { equal_to: 5 }` concatenated to `enum: [5, "5", 6, "6"]`, wrongly advertising "6" —
          # it coerces to 6, which passes inclusion but fails the equality check (only 5 satisfies both).
          # `translated_literal_constraint` intersects the two translated sets instead, keeping only the
          # wire forms both constraints actually agree on.
          it "intersects translated const: and enum: constraints rather than concatenating them" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, type: String
              end
              expects :inner, on: :payload, type: { klass: Integer, coerce: true }, inclusion: { in: [5, 6] },
                              comparison: { equal_to: 5 }
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            expect(inner).to eq(enum: [5, "5"], not: { type: "null" }, allOf: [{ type: "string", minLength: 1 }])
            expect(klass.call(payload: { inner: "5" })).to be_ok
            expect(klass.call(payload: { inner: "6" })).not_to be_ok # coerces to 6, passes inclusion but fails equal_to: 5
          end

          # Intersecting the const:/enum: translated spellings via plain `&` compares candidates with
          # Ruby's `eql?`/`hash` — which, unlike `==`, treats an Integer and a numerically-equal Float as
          # DIFFERENT (`5.eql?(5.0)` is false) — so it never recognizes that two DIFFERENT wire spellings
          # (one from each constraint) actually decode to the identical target value (Codex review, PR
          # #278 round 24): a coercing Float node declaring BOTH `comparison: { equal_to: 5 }` (`const: 5`,
          # an Integer) AND `inclusion: { in: [5.0] }` (`enum: [5.0]`, a Float) accepts wire "5" at runtime
          # (it coerces to 5.0, which equals both 5 and 5.0), but the translated sets `[5, "5"]` and `[5.0,
          # "5.0"]` share no member under plain equality, intersecting to an empty, unsatisfiable enum.
          # Fixed by comparing candidates via their COERCED value instead of the raw candidate token.
          it "intersects numeric const:/enum: candidates by their coerced value, not raw token equality" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, type: String
              end
              expects :inner, on: :payload, type: { klass: Float, coerce: true }, comparison: { equal_to: 5 },
                              inclusion: { in: [5.0] }
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            expect(inner).to eq(enum: [5, "5", 5.0, "5.0"], not: { type: "null" }, allOf: [{ type: "string", minLength: 1 }])
            expect(klass.call(payload: { inner: "5" })).to be_ok
            expect(klass.call(payload: { inner: "6" })).not_to be_ok
          end

          # `declared_literals` intersects a property's OWN const:/enum: via the same plain `&` — a
          # SEPARATE call site from `translated_literal_constraint`'s, reached whenever a colliding side's
          # bound needs checking against the OTHER side's literals rather than translating its own (Codex
          # review, PR #278 round 25): an ancestor Numeric member declaring BOTH `comparison: { equal_to: 5
          # }` (`const: 5`) and `inclusion: { in: [5.0] }` (`enum: [5.0]`) beside a colliding Integer node
          # that preprocesses `5` to `10` before requiring `> 6` accepts raw `5` at runtime (the ancestor's
          # own checks both pass against 5; the node's own check runs on the preprocessed 10), but `[5] &
          # [5.0]` returned `[]`, read as "no literals declared" — so the node's own (truly contradicted)
          # `exclusiveMinimum: 6` was kept rather than dropped, conjoining `const: 5`, `enum: [5.0]`, and
          # `exclusiveMinimum: 6` into a node nothing satisfies. Fixed by the same coerced/numeric-aware
          # comparison `intersect_wire_spellings` already uses for the other call site.
          it "intersects declared_literals by value, not raw token equality, when checking a sibling bound" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, type: Numeric, comparison: { equal_to: 5 }, inclusion: { in: [5.0] }
              end
              expects :inner, on: :payload, type: Integer, preprocess: ->(v) { v + 5 }, comparison: { greater_than: 6 }
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            expect(inner).to eq(type: "number", const: 5, enum: [5.0])
            expect(klass.call(payload: { inner: 5 })).to be_ok
            expect(klass.call(payload: { inner: 6 })).not_to be_ok # fails the ancestor's own equal_to: 5
          end

          # A native (non-string) whole-number Float literal (`5.0`) is INDISTINGUISHABLE from its bare
          # integer form under JSON Schema's own equality — the spec itself defines any zero-fractional-
          # part number as satisfying `type: "integer"` too, regardless of how it was written — so a
          # coercing Float node's `inclusion: { in: [5.0] }` colliding with an ancestor whose type admits a
          # bare JSON number lets native `5` satisfy the schema (`enum: [5.0]` matches it) though the
          # runtime rejects it (`Coercion.coerce_value` only ever parses a String, so `5` is never coerced
          # and fails the node's own Float check). A round-24 fix dropped the native candidate outright to
          # close this — but round 25 found that the SAME ambiguity, and the SAME resulting mismatch,
          # already exists for a coercing Float field with a whole-number literal that ISN'T colliding with
          # anything at all (a plain `expects :inner, type: { klass: Float, coerce: true }, inclusion: {
          # in: [5.0] }` with no ancestor member in play), which `single_type_for` has never guarded either
          # — this is a general JSON-Schema/Ruby-numeric-typing gap, not something specific to the
          # shape-member conjunction PRO-3405 is about. Fixing it only in the conjunction path made THAT
          # one narrow case unconditionally unsatisfiable (rejecting the one wire value — native `5.0` —
          # the runtime does accept) while leaving the more common, non-colliding case still silently loose
          # — an inconsistency worse than either extreme alone. Reverted: the conjunction path now matches
          # the same tolerated imprecision the standalone path already has, tracked as a separate, broader
          # follow-up rather than patched here.
          it "still surfaces the pre-existing native-Float/Integer JSON ambiguity, matching the non-colliding path" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, type: Numeric
              end
              expects :inner, on: :payload, type: { klass: Float, coerce: true }, inclusion: { in: [5.0] }
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            expect(inner).to eq(enum: [5.0, "5.0"], not: { type: "null" }, allOf: [{ type: "number" }])
            expect(klass.call(payload: { inner: 5.0 })).to be_ok
            # native Integer 5 is never coerced (not a String) and fails the node's own Float check — a
            # documented, tolerated schema/runtime gap (the schema admits it too), not asserted against here
            expect(klass.call(payload: { inner: 5 })).not_to be_ok
          end

          # A numeric bound (`minimum`/`maximum`/`exclusiveMinimum`/`exclusiveMaximum`) surviving a
          # transforming side is only trustworthy when the SURVIVING type actually admits a number — unlike
          # `length:` under a coercing Symbol (whose rendered form has the same length as the wire string),
          # a numeric bound describes the coerced value's magnitude, which has no relationship to a wire
          # value the runtime never reads as a number at all (Codex review, PR #278 round 14): under a raw
          # `String` ancestor, a colliding coercing `comparison: { greater_than: 5 }` node kept
          # `exclusiveMinimum: 5` sitting beside `type: "string"`, where JSON Schema silently ignores it —
          # so the schema enforced nothing, though the runtime's coercion+comparison check does. Unlike a
          # discrete literal, an open-ended numeric range has no small, enumerable set of wire-string
          # candidates to verify by round-trip, so it is dropped rather than left inert under a keyword
          # JSON Schema will never apply — a residual, accepted imprecision (the schema can no longer
          # express ">5 after coercion" at all) rather than a wrong answer in either direction.
          it "drops a coercing node's own numeric bound when the surviving type does not admit a number" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, type: String
              end
              expects :inner, on: :payload, type: { klass: Integer, coerce: true }, comparison: { greater_than: 5 }
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            expect(inner).to eq(type: "string", minLength: 1)
            expect(klass.call(payload: { inner: "6" })).to be_ok
            expect(klass.call(payload: { inner: "3" })).not_to be_ok # coerces to 3, fails comparison: { greater_than: 5 }
          end

          it "conjoins via allOf an Array member, whose shape describes ELEMENTS rather than the node" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, type: Array, of: Hash
              end
              expects :inner, on: :payload, type: Hash
              def call = nil
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            inner = schema[:properties][:payload][:properties][:inner]
            expect(inner).not_to have_key(:items)
            expect(inner).not_to have_key(:properties)
            expect(inner[:allOf]).to eq([{ type: "array", items: { type: "object" }, minItems: 1 }])
            # honest emptiness: Hash and Array are disjoint.
            expect(klass.call(payload: { inner: {} })).not_to be_ok
            expect(klass.call(payload: { inner: [{}] })).not_to be_ok
          end

          it "leaves a sibling member with no explicit node of its own untouched" do
            klass = Class.new do
              include Axn
              expects :payload, type: Hash do
                field :inner, type: Hash do
                  field :a, type: String
                end
                field :other, type: String
              end
              expects :inner, on: :payload, type: Hash
            end
            schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

            expect(schema[:properties][:payload][:properties][:other]).to include(type: "string")
          end
        end

        # Reflection is static-maximal on input, so a gate changes nothing about what is merged.
        it "merges a gated member exactly as an ungated one" do
          gated = Class.new do
            include Axn
            expects :payload, type: Hash do
              field :inner, type: Hash, if: -> { false } do
                field :a, type: String
              end
            end
            expects :inner, on: :payload, type: Hash
          end
          ungated = Class.new do
            include Axn
            expects :payload, type: Hash do
              field :inner, type: Hash do
                field :a, type: String
              end
            end
            expects :inner, on: :payload, type: Hash
          end

          expect(described_class.build_input(gated.internal_field_configs, gated.subfield_configs))
            .to eq(described_class.build_input(ungated.internal_field_configs, ungated.subfield_configs))
        end
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
          # as: disambiguates the two routes' shared :baz reader (wire key stays :baz, so they still merge)
          expects :baz, on: "foo.bar", type: Hash, as: :baz_route1                                 # baz config #1 (no shape)
          expects :baz, on: :bar, type: Hash, shape: { members: [x_member], container: Hash }      # baz config #2 (non-nestable member x)
          expects :y, on: "baz_route1.x" # implicit x under baz + grandchild y
        end
        schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

        baz = schema[:properties][:foo][:properties][:bar][:properties][:baz]
        expect(baz[:properties]).not_to have_key(:y)                        # not force-nested under a blocking member
        expect(baz.dig(:properties, :x, :properties, :y)).to be_nil         # the deep x.y structure is dropped, matching the tree
        dropped = described_class.dropped_deep_subfields(klass.internal_field_configs, klass.subfield_configs)
        expect(dropped.map(&:field)).to eq([:y])
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
          # as: disambiguates the two routes' shared :baz reader (wire key stays :baz, so they still merge)
          expects :baz, on: "foo.bar", type: Hash, shape: { members: [x1], container: Hash }, as: :baz_route1 # route 1: x -> y (Hash)
          expects :baz, on: :bar, type: Hash, shape: { members: [x2], container: Hash }      # route 2: x -> y (String)
          expects :z, on: "baz.x.y"                                                          # implicit x, implicit y, leaf z
        end
        schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

        baz = schema.dig(:properties, :foo, :properties, :bar, :properties, :baz)
        expect(baz.dig(:properties, :x, :properties, :y, :properties, :z)).to be_nil # scalar y blocks the deep z
        dropped = described_class.dropped_deep_subfields(klass.internal_field_configs, klass.subfield_configs)
        expect(dropped.map(&:field)).to eq([:z]) # and it is warned, not silently gone
      end
    end

    describe "the same wire path declared via two routes" do
      it "builds the property from the first-declared config, unions requiredness, and intersects nullability" do
        klass = Class.new do
          include Axn
          expects :foo, type: Hash
          expects :bar, on: :foo, type: Hash
          expects :baz, on: "foo.bar", type: String, allow_nil: true, as: :baz_route1 # route 1: optional/nullable; as: disambiguates the shared :baz reader
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
            # as: disambiguates the shared :user reader; wire key stays :user, so the two routes still merge
            expects :user, on: "payload.account", type: Hash, optional: true, as: :user_nonmodel # non-model route (first), optional
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
          expects :user, on: "payload.account", type: Hash, optional: true, as: :user_nonmodel # as: disambiguates the shared :user reader
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
            # as: disambiguates the shared :baz reader; wire key stays :baz, so the two routes still merge
            expects :baz, on: "foo.bar", type: Hash, as: :baz_route1 # route 1: nestable
            expects :baz, on: :bar, type: [Hash, Array] # route 2: NON-nestable (mixed union)
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
            # as: disambiguates the shared :baz reader; wire key stays :baz, so the two routes still merge
            expects :baz, on: :bar, type: [Hash, Array] # route 2 FIRST
            expects :baz, on: "foo.bar", type: Hash, as: :baz_route1 # route 1 SECOND
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
          # as: disambiguates the shared :user reader; wire key stays :user, so the two routes still merge
          expects :user, on: "payload.account", type: Hash, optional: true, as: :user_nonmodel # non-model route (first)
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

    it "deep dotted-on: subfield: runtime digs the same path the schema advertises" do
      klass = Class.new do
        include Axn
        expects :foo, type: Hash
        expects :baz, on: "foo.bar", type: String
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
    it "returns [] for the deep forms under object-shaped parents (they are represented now)" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash
        expects :meta, on: :payload, type: Hash          # shallow — represented
        expects :id, on: :meta, type: Integer            # deep: subfield-of-subfield
        expects :deep, on: "payload.meta", type: String  # deep: dotted on: (explicit parent)
        expects :baz, on: "payload.bar"                  # deep: dotted on: (implicit intermediate)
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
  # synthesis hazard (both a shallow and a deep dotted-on: trigger).
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
            minProperties: 1,
            properties: {
              meta: {
                type: "object",
                minProperties: 1,
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
            minItems: 1,
            items: {
              type: "object",
              properties: { status: { type: "string", minLength: 1 } },
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
          payload: { anyOf: [{ type: "object", minProperties: 1 }, { type: "array", minItems: 1 }] },
        },
        required: ["payload"],
      )
    end

    it "emits the same input_schema for a defaulted deep (dotted-on:) subtree" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash
        expects :zip, on: "payload.address", default: "x"
      end

      expect(klass.input_schema).to eq(
        type: "object",
        properties: {
          payload: {
            type: "object",
            minProperties: 1,
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
            minProperties: 1,
            properties: {
              status: { type: "string", minLength: 1 },
              meta: {
                type: "object",
                minProperties: 1,
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
              status: { type: "string", minLength: 1 },
              note: { type: %w[string null], default: "x" },
            },
            required: ["status"],
          },
        },
        required: ["payload"],
      )
    end

    it "emits the same input_schema for the shape-member synthesis hazard triggered by a DEEP " \
       "(dotted-on:) default" do
      # The parent Proc default keeps the contract legal under PRO-2889 (satisfiability counts the Proc as a
      # rescue) while strict reflection ignores Procs — the emitted schema is unchanged (Proc defaults are
      # never serialized, and the hazard still forces payload required + non-nullable).
      klass = Class.new do
        include Axn
        expects :payload, type: Hash, allow_nil: true, default: -> { {} } do
          field :status, type: String
        end
        expects :zip, on: "payload.address", default: "x"
      end

      expect(klass.input_schema).to eq(
        type: "object",
        properties: {
          payload: {
            type: "object",
            properties: {
              status: { type: "string", minLength: 1 },
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

      strict = Axn::Internal::Reflection::Schema.derive_annotations(resolved.roots)
      sat    = Axn::Internal::Reflection::Schema.derive_annotations(resolved.roots, satisfiability: true)

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

    it "leaves a gated exposes property untyped (a closed gate can emit any exposed value)" do
      action = build_axn do
        expects :flag, type: :boolean
        exposes :num, type: Integer, if: :flag
        def call; end
      end
      prop = action.output_schema[:properties][:num]
      expect(prop).not_to have_key(:type)
      expect(prop).not_to have_key(:format)
      expect(prop).not_to have_key(:enum)
    end

    it "output_schema is a superset of what a closed outbound gate can emit (untyped, and the wrong-typed value passes)" do
      action = build_axn do
        expects :flag, type: :boolean
        exposes :num, type: Integer, if: :flag
        def call = expose(:num, "oops")
      end
      # Closed gate skips num's type validator, so a String flows through: the call succeeds…
      result = action.call(flag: false)
      expect(result).to be_ok
      expect(result.num).to eq("oops")
      # …and the output schema advertises no type the emitted value could contradict.
      expect(action.output_schema[:properties][:num]).not_to have_key(:type)
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

    it "drops output requiredness for a gated shape member when the outbound gate is closed (Codex round 2)" do
      action = build_axn do
        expects :flag, type: :boolean
        exposes :payload, type: Hash, allow_blank: true do
          field :note, type: String, if: :flag
        end
        def call
          expose payload: {}
        end
      end
      # Runtime legitimately serializes an empty payload with the gate closed — proving that an output
      # `required: ["note"]` claim would otherwise be a lie about what the serializer can emit.
      result = action.call(flag: false)
      expect(result).to be_ok
      expect(result.payload).to eq({})

      payload_prop = action.output_schema[:properties][:payload]
      expect(payload_prop[:required].to_a).not_to include("note")

      # INPUT stays static-maximal for the equivalent input shape: the gated member is still required.
      input_action = build_axn do
        expects :flag, type: :boolean
        expects :payload, type: Hash do
          field :note, type: String, if: :flag
        end
      end
      expect(input_action.input_schema[:properties][:payload][:required]).to include("note")
    end

    it "drops output requiredness for a shape member whose presence is only NESTED-gated (Codex round 13)" do
      action = build_axn do
        expects :flag, type: :boolean
        exposes :payload, type: Hash, allow_blank: true do
          field :note, presence: { if: :flag }
        end
        def call
          expose payload: {}
        end
      end
      # Runtime legitimately serializes an empty payload with the nested gate closed — the presence
      # check on `note` never runs — proving an output `required: ["note"]` claim would be a lie.
      result = action.call(flag: false)
      expect(result).to be_ok
      expect(result.payload).to eq({})

      payload_prop = action.output_schema[:properties][:payload]
      expect(payload_prop[:required].to_a).not_to include("note")

      # INPUT stays static-maximal for the equivalent input shape: the nested-gated member is still
      # required (a client is still expected to send it).
      input_action = build_axn do
        expects :flag, type: :boolean
        expects :payload, type: Hash do
          field :note, presence: { if: :flag }
        end
      end
      expect(input_action.input_schema[:properties][:payload][:required]).to include("note")
    end

    it "keeps output requiredness for a shape member with an UNGATED presence alongside a nested-gated type" do
      action = build_axn do
        expects :flag, type: :boolean
        exposes :payload, type: Hash do
          field :note, presence: true, type: { klass: Integer, if: :flag }
        end
        def call
          expose payload: { note: "oops" }
        end
      end
      # The nested-gated TYPE check can be skipped by a closed gate, but presence is ungated — the
      # serializer can never emit `payload` without a `note` key — so requiredness is still owed.
      result = action.call(flag: false)
      expect(result).to be_ok
      expect(result.payload).to eq(note: "oops")

      payload_prop = action.output_schema[:properties][:payload]
      expect(payload_prop[:required]).to include("note")
    end

    it "does not force a gated required subfield's ancestors (own-level nested required kept)" do
      action = build_axn do
        expects :data, optional: true
        expects :user, type: String, on: :data, if: -> { data.present? }
      end
      schema = action.input_schema
      expect(schema[:required].to_a).not_to include("data")
      expect(schema[:properties][:data][:type]).to eq(%w[object null])
      expect(schema[:properties][:data][:required]).to eq(["user"])
      expect(schema[:properties][:data][:properties][:user][:type]).to eq("string")
    end

    it "keeps ancestor-forcing when any config at the node is ungated" do
      action = build_axn do
        expects :data, type: Hash
        expects :user, type: String, on: :data, if: :cond
        expects :role, type: String, on: :data
      end
      schema = action.input_schema
      expect(schema[:required]).to include("data")
      expect(schema[:properties][:data][:required]).to match_array(%w[user role])
    end

    it "reflects a merged node's parent per its UNGATED optional route (ancestor-forcing ignores the gated route)" do
      # `root.data.user` merges an UNGATED optional route and a gated required route. Ancestor-forcing
      # uses the ungated subset, so the ungated-optional route leaves `data` omittable while the gated
      # route's own-level obligation is still emitted in the node's nested `required`.
      action = build_axn do
        expects :strict, type: :boolean, default: false
        expects :root, type: Hash, allow_blank: true
        expects :data, on: :root, optional: true
        expects :user, on: :data, type: String, optional: true
        expects :user, on: "root.data", type: String, if: :strict, as: :user_gated # as: disambiguates the shared :user reader
      end
      root = action.input_schema[:properties][:root]
      # data is NOT forced required by the gated route
      expect(root[:required].to_a).not_to include("data")
      data = root[:properties][:data]
      expect(data[:type]).to eq(%w[object null])
      # the gated route's own-level nested requiredness is kept static-maximal
      expect(data[:required]).to eq(["user"])
    end

    it "reflects a blank `if:` as no gate at all: required, with no allOf clause emitted" do
      action = build_axn do
        expects :num, type: Integer, if: nil
      end
      schema = action.input_schema
      expect(schema[:required]).to include("num")
      expect(schema).not_to have_key(:allOf)
    end

    describe "per-validator (nested) gates reach reflection (Codex round 12)" do
      it "does not force ancestors for a subfield gated by a nested presence condition (own-level required kept)" do
        action = build_axn do
          expects :data, optional: true
          expects :user, on: :data, presence: { if: -> { data.present? } }
        end
        schema = action.input_schema
        expect(schema[:required].to_a).not_to include("data")
        expect(schema[:properties][:data][:type]).to eq(%w[object null])
        expect(schema[:properties][:data][:required]).to eq(["user"]) # own-level static-maximal
      end

      it "still forces ancestors when a nested-gated presence sits alongside an ungated nil-rejecting type" do
        action = build_axn do
          expects :data, type: Hash
          expects :user, on: :data, type: String, presence: { if: -> { data.present? } }
        end
        expect(action.input_schema[:required]).to include("data")
      end

      it "leaves an exposed property untyped when its type is nested-gated" do
        action = build_axn do
          expects :flag, type: :boolean
          exposes :amount, type: { klass: Integer, if: :flag }
          def call = expose(:amount, "oops")
        end
        prop = action.output_schema[:properties][:amount]
        expect(prop).not_to have_key(:type)
      end

      it "drops a nested-gated inclusion's enum while keeping an UNGATED sibling type's contribution" do
        action = build_axn do
          expects :flag, type: :boolean
          exposes :name, type: String, inclusion: { in: %w[a b], if: :flag }
          def call = expose(:name, "zzz")
        end
        prop = action.output_schema[:properties][:name]
        expect(prop).not_to have_key(:enum)   # gated inclusion dropped
        expect(prop[:type]).to eq("string")   # ungated sibling type kept
      end

      it "admits null on an exposed property whose only check is a nested-gated presence" do
        action = build_axn do
          expects :flag, type: :boolean
          exposes :note, presence: { if: :flag }
          def call = expose(:note, nil)
        end
        prop = action.output_schema[:properties][:note]
        expect(prop).not_to have_key(:type) # untyped → null admissible
      end

      it "keeps INPUT static-maximal for a nested-gated type (the gate only relaxes at runtime)" do
        action = build_axn do
          expects :flag, type: :boolean
          expects :amount, type: { klass: Integer, if: :flag }
        end
        schema = action.input_schema
        expect(schema[:required]).to include("amount")
        expect(schema[:properties][:amount][:type]).to eq("integer")
      end

      it "output schema is a superset: a closed nested gate lets a wrong-typed value through while the property is untyped" do
        action = build_axn do
          expects :flag, type: :boolean, default: false
          exposes :amount, type: { klass: Integer, if: :flag }
          def call = expose(:amount, "oops")
        end
        result = action.call(flag: false) # closed gate skips the type check
        expect(result).to be_ok
        expect(result.amount).to eq("oops")
        expect(action.output_schema[:properties][:amount]).not_to have_key(:type)
      end
    end

    describe "declarative Symbol conditions (allOf/if/then emission)" do
      it "emits an exact conditional for a Symbol referencing a declared sibling field" do
        action = build_axn do
          expects :promo_enabled, type: :boolean
          expects :coupon_code, type: String, if: :promo_enabled?
        end
        schema = action.input_schema
        expect(schema[:required].to_a).not_to include("coupon_code")
        expect(schema[:allOf]).to eq([{
                                       if: {
                                         required: ["promo_enabled"],
                                         properties: { promo_enabled: { not: { enum: [false, nil] } } },
                                       },
                                       then: { required: ["coupon_code"] },
                                     }])
        expect(schema[:properties][:coupon_code][:type]).to eq("string")
      end

      it "emits else for unless:" do
        action = build_axn do
          expects :skip_check, type: :boolean
          expects :coupon_code, type: String, unless: :skip_check
        end
        clause = action.input_schema[:allOf].first
        expect(clause[:if][:required]).to eq(["skip_check"])
        expect(clause[:else]).to eq({ required: ["coupon_code"] })
        expect(clause).not_to have_key(:then)
      end

      it "falls back for an unless: gate when boolean coercion can flip the referenced truthiness" do
        # The referenced field admits both boolean coercion and a String wire form: wire "false" is
        # schema-admissible (String branch) and truthy to the emitted `if`, but runtime coerces it to
        # `false`, opening the unless-gate and requiring coupon_code. An emitted `else` clause would be
        # looser than runtime, so fall back to unconditional required.
        action = build_axn do
          expects :skip_check, coerce: [:boolean, String]
          expects :coupon_code, type: String, unless: :skip_check
          def call; end
        end
        schema = action.input_schema
        expect(schema[:allOf]).to be_nil
        expect(schema[:required]).to include("coupon_code")
      end

      it "STILL emits for an if: gate with the same flippable reference (stricter direction)" do
        # A truthy->falsey flip on an if: gate keeps the emitted `then` requiring the field while the
        # runtime gate closes — schema stricter than runtime, the safe direction, so the clause stays.
        action = build_axn do
          expects :skip_check, coerce: [:boolean, String]
          expects :coupon_code, type: String, if: :skip_check
          def call; end
        end
        expect(action.input_schema[:allOf]).not_to be_nil
      end

      it "STILL emits for a plain boolean unless: gate (a String wire value is schema-rejected)" do
        # A plain `type: :boolean` property admits no string, so no schema-valid input can be coerced
        # from truthy to falsey — no flip is possible, and the exact `else` clause is emitted.
        action = build_axn do
          expects :skip_check, type: :boolean
          expects :coupon_code, type: String, unless: :skip_check
          def call; end
        end
        expect(action.input_schema[:allOf]).not_to be_nil
      end

      it "falls back for an unless: gate on a coercible-typed reference with no explicit coerce flag" do
        # `type: [:boolean, String]` carries no per-field coerce flag, but the class-level
        # coerce_input_types override could enable coercion — reflection must not resolve per-class
        # config, so it conservatively assumes a flip is possible and falls back.
        action = build_axn do
          expects :skip_check, type: [:boolean, String]
          expects :coupon_code, type: String, unless: :skip_check
          def call; end
        end
        schema = action.input_schema
        expect(schema[:allOf]).to be_nil
        expect(schema[:required]).to include("coupon_code")
      end

      it "falls back for an unless: gate on a Symbol-branch reference (schema emits Symbol as string)" do
        # `type: [:boolean, Symbol]` emits an `anyOf` including a `string` branch (Symbol -> "string"),
        # so wire "false" is schema-admissible through it and truthy to the emitted `if`, while runtime
        # boolean coercion flips it to `false`, opening the unless-gate. The string-shaped branch is
        # derived from the emission logic (single_type_for), not a String/:uuid hand-list, so Symbol is
        # correctly recognized as flippable and the clause falls back.
        action = build_axn do
          expects :skip_check, type: [:boolean, Symbol]
          expects :coupon_code, type: String, unless: :skip_check
          def call; end
        end
        schema = action.input_schema
        expect(schema[:allOf]).to be_nil
        expect(schema[:required]).to include("coupon_code")
      end

      it "STILL emits for an if: gate with the same Symbol-branch reference (stricter direction)" do
        action = build_axn do
          expects :skip_check, type: [:boolean, Symbol]
          expects :coupon_code, type: String, if: :skip_check
          def call; end
        end
        expect(action.input_schema[:allOf]).not_to be_nil
      end

      it "falls back for an unless: gate on a Float-coercible reference (runtime coerces integer 0 to false)" do
        # `coerce: [:boolean, Float]` emits an anyOf with a `number` branch. Runtime's coerce_boolean maps
        # a non-String integer 0 to `false` BEFORE any Float parse is attempted, so wire `{skip_check: 0}`
        # is schema-admissible (the number branch) and truthy to the emitted `if`, while runtime settles
        # it falsey and opens the unless-gate. A number-shaped branch admits coerce_boolean's falsey path
        # exactly like a string-shaped one, so this must fall back just like the String/Symbol cases above.
        action = build_axn do
          expects :skip_check, coerce: [:boolean, Float]
          expects :coupon_code, type: String, unless: :skip_check
          def call; end
        end
        schema = action.input_schema
        expect(schema[:allOf]).to be_nil
        expect(schema[:required]).to include("coupon_code")
      end

      it "STILL emits for an if: gate with the same Float-coercible reference (stricter direction)" do
        action = build_axn do
          expects :skip_check, coerce: [:boolean, Float]
          expects :coupon_code, type: String, if: :skip_check
          def call; end
        end
        expect(action.input_schema[:allOf]).not_to be_nil
      end

      it "falls back for an unless: gate on an Integer-coercible reference (same integer-0 hazard)" do
        action = build_axn do
          expects :skip_check, coerce: [:boolean, Integer]
          expects :coupon_code, type: String, unless: :skip_check
          def call; end
        end
        schema = action.input_schema
        expect(schema[:allOf]).to be_nil
        expect(schema[:required]).to include("coupon_code")
      end

      it "falls back to unconditional required when any guard fails" do
        fallback_required = lambda do |&decl|
          schema = build_axn(&decl).input_schema
          expect(schema[:allOf]).to be_nil
          expect(schema[:required]).to include("coupon_code")
        end

        # Proc condition (opaque)
        fallback_required.call do
          expects :flag, type: :boolean
          expects :coupon_code, type: String, if: -> { flag }
        end
        # Symbol naming a non-field action method (opaque)
        fallback_required.call do
          expects :coupon_code, type: String, if: :some_method
        end
        # referenced field carries a default (settled value can diverge from the wire)
        fallback_required.call do
          expects :flag, type: :boolean, default: true
          expects :coupon_code, type: String, if: :flag
        end
        # referenced field carries a preprocess
        fallback_required.call do
          expects :flag, preprocess: ->(v) { !v.nil? }, optional: true
          expects :coupon_code, type: String, if: :flag
        end
        # referenced field is model:-routed (lookup success isn't wire-expressible)
        fallback_required.call do
          expects :user, model: { klass: Struct.new(:id), finder: :find }, optional: true
          expects :coupon_code, type: String, if: :user
        end
        # both if: and unless: given
        fallback_required.call do
          expects :a, :b, type: :boolean
          expects :coupon_code, type: String, if: :a, unless: :b
        end
      end

      it "emits no clause for an already-optional gated field (nothing to make conditional)" do
        action = build_axn do
          expects :flag, type: :boolean
          expects :coupon_code, type: String, optional: true, if: :flag
        end
        schema = action.input_schema
        expect(schema[:allOf]).to be_nil
        expect(schema[:required].to_a).not_to include("coupon_code")
      end

      it "matches the referenced field through an as: alias and emits its wire key" do
        action = build_axn do
          expects :promo, type: :boolean, as: :promotion
          expects :coupon_code, type: String, if: :promotion
        end
        clause = action.input_schema[:allOf].first
        expect(clause[:if][:required]).to eq(["promo"])
      end

      it "falls back when the referenced reader is a user method, not the framework-generated one" do
        # (a) user defines its own predicate BEFORE the boolean field: predicate generation defers to
        # it, so runtime evaluates the USER method while the wire value could differ — must not emit.
        pre = build_axn do
          def promo_enabled? = true
          expects :promo_enabled, type: :boolean
          expects :coupon_code, type: String, if: :promo_enabled?
        end
        schema = pre.input_schema
        expect(schema[:allOf]).to be_nil
        expect(schema[:required]).to include("coupon_code")

        # (a') user defines its own predicate AFTER the field declaration.
        post_pred = build_axn do
          expects :promo_enabled, type: :boolean
          def promo_enabled? = true
          expects :coupon_code, type: String, if: :promo_enabled?
        end
        schema = post_pred.input_schema
        expect(schema[:allOf]).to be_nil
        expect(schema[:required]).to include("coupon_code")

        # (b) user redefines the PLAIN reader after expects: same hazard, the def shadows the reader.
        plain = build_axn do
          expects :flag, type: :boolean
          def flag = true
          expects :coupon_code, type: String, if: :flag
        end
        schema = plain.input_schema
        expect(schema[:allOf]).to be_nil
        expect(schema[:required]).to include("coupon_code")
      end

      it "still emits for the generated readers (source_location check does not false-positive)" do
        # Generated plain reader.
        plain = build_axn do
          expects :flag, type: :boolean
          expects :coupon_code, type: String, if: :flag
        end
        expect(plain.input_schema[:allOf]).not_to be_nil
        # Generated boolean predicate alias (shares the aliased reader's source_location).
        pred = build_axn do
          expects :promo_enabled, type: :boolean
          expects :coupon_code, type: String, if: :promo_enabled?
        end
        expect(pred.input_schema[:allOf]).not_to be_nil
      end

      it "still emits when a subfield default sits beneath the referenced field (value-level defaults never synthesize the parent)" do
        action = build_axn do
          expects :opts, optional: true
          expects :mode, on: :opts, default: "x"
          expects :coupon_code, type: String, if: :opts
          def call; end
        end
        schema = action.input_schema
        # A subfield default resolves the CHILD's value on the read path and never materializes the
        # parent (PRO-2903), so a wire-omitted opts settles nil/falsey exactly as the clause reads it.
        expect(schema[:allOf]).not_to be_nil
        expect(schema[:required].to_a).not_to include("coupon_code")
        # Runtime agreement: omit everything → opts stays nil, the gate is closed, the call passes.
        expect(action.call.ok?).to be true
        # And a present opts opens the gate exactly as the clause advertises.
        expect(action.call(opts: { other: 1 }).ok?).to be false
        expect(action.call(opts: { other: 1 }, coupon_code: "C").ok?).to be true
      end

      it "still emits when the referenced field's subfield carries no default" do
        action = build_axn do
          expects :opts, optional: true
          expects :mode, on: :opts, optional: true
          expects :coupon_code, type: String, if: :opts
        end
        expect(action.input_schema[:allOf]).not_to be_nil
      end

      it "falls back when a blank same-key nested override un-gates a nil-rejecting entry (Codex round 14)" do
        # `presence: { if: nil }` OVERRIDES and drops the declaration `if: :flag` for the presence check
        # (AM's measured per-key merge), so presence runs UNCONDITIONALLY — name is required for every
        # call. An allOf conditioning name on `flag` would be looser than runtime (it would accept
        # `{flag: false}` without name, which runtime rejects), so fall back to unconditional required.
        action = build_axn do
          expects :flag, type: :boolean
          expects :name, type: String, if: :flag, presence: { if: nil }
          def call; end
        end
        schema = action.input_schema
        expect(schema[:allOf]).to be_nil
        expect(schema[:required]).to include("name")
        # Runtime agreement: the gate is dropped, so name is required even when flag is false.
        expect(action.call(flag: false).ok?).to be false
        expect(action.call(flag: false, name: "x").ok?).to be true
      end

      it "falls back when a non-blank nested gate ties a nil-rejecting entry to a DIFFERENT condition" do
        # `presence: { if: :other }` gates presence on `other`, not the declaration's `flag`, so an allOf
        # keyed on `flag` would mis-model requiredness. Fall back to unconditional required.
        action = build_axn do
          expects :flag, :other, type: :boolean
          expects :name, type: String, if: :flag, presence: { if: :other }
          def call; end
        end
        schema = action.input_schema
        expect(schema[:allOf]).to be_nil
        expect(schema[:required]).to include("name")
      end

      it "STILL emits when the nested-gated entry is nil-TOLERANT (harmless for requiredness)" do
        # A gate on a nil-tolerant check (`length: { allow_nil: true, ... }`) never affects whether the
        # field may be omitted — the field is nil-rejecting only via the ungated declaration-gated slot,
        # so the clause conditioning name on `flag` stays exact.
        action = build_axn do
          expects :flag, :other, type: :boolean
          expects :name, type: String, if: :flag, length: { allow_nil: true, minimum: 2, if: :other }
          def call; end
        end
        schema = action.input_schema
        expect(schema[:allOf]).to eq([{
                                       if: {
                                         required: ["flag"],
                                         properties: { flag: { not: { enum: [false, nil] } } },
                                       },
                                       then: { required: ["name"] },
                                     }])
        expect(schema[:required].to_a).not_to include("name")
      end
    end
  end

  # Reflection must never raise on user data. Schema.normalize_schema_literal walks a literal `default:`
  # itself and routes only scalar leaves to Values.serialize_value, so the serializer's checks are out of
  # reach here — but the colliding-key one raises unconditionally, making it the single check that would
  # surface in input_schema if that traversal ever handed a Hash to the serializer. This pins that it
  # doesn't.
  it "reflects a literal default whose Hash keys stringify to one property rather than raising" do
    klass = Class.new do
      include Axn
      expects :rec, default: { id: 1, "id" => 2 }
    end

    expect { klass.input_schema }.not_to raise_error
    expect(klass.input_schema[:properties][:rec][:default]).to eq({ id: 1, "id" => 2 })
  end

  # Scalar leaves DO route to Values.serialize_value, which refuses a non-finite Float outright because
  # JSON has no literal for one. Reflection reports the declaration anyway: a reflected literal promises
  # nothing about encodability, while serialize_exposed's output does, which is where that refusal belongs.
  it "reflects a non-finite Float default as declared rather than raising" do
    klass = Class.new do
      include Axn
      expects :limit, type: Numeric, default: Float::INFINITY
    end

    expect { klass.input_schema }.not_to raise_error
    expect(klass.input_schema[:properties][:limit][:default]).to eq(Float::INFINITY)
  end

  # `build_input` is public, so a config a downstream caller built itself reaches the emitter without passing
  # the declaration walk — and its member names are then whatever the caller made them. A member's property key
  # and its `required` entry are ONE name, so they are rendered from one conversion of it: two conversions are
  # two answers the caller can give, and a name that gave them differently listed a required property this
  # emitter never emitted (a schema no input can satisfy). Declared members can't reach this — the walk stores
  # the Symbol it judged — which is exactly why the tolerance needs its own example.
  it "lists a caller-built member as required under the same name it emitted" do
    flipping = Class.new(String) do
      def to_sym
        @reads = (@reads || 0) + 1
        @reads == 1 ? :first : :second
      end
    end.new("ignored")
    member = Struct.new(:field, :validations).new(flipping, { presence: true })
    config = Axn::Core::Contract::FieldConfig.new(field: :payload, reader_as: :payload,
                                                  validations: { type: { klass: Hash }, shape: { members: [member], container: Hash } })

    schema = described_class.build_input([config])

    expect(schema.dig(:properties, :payload, :required)).to eq(schema.dig(:properties, :payload, :properties).keys.map(&:to_s))
  end

  # A container sitting directly inside a container has no member name to hang the next level on, so the
  # emitter reaches it by recursing over the `of:` bag itself (`contents_node_schema`) rather than through
  # `shape:`'s named members. These pin the three shapes that recursion can produce at the inner rung.
  describe "a recursive of:" do
    it "emits items inside items" do
      action = build_axn { expects :matrix, type: Array, of: { klass: Array, of: Integer } }

      expect(action.input_schema[:properties][:matrix]).to include(
        type: "array",
        items: { type: "array", items: { type: "integer" } },
      )
    end

    it "emits a union at the inner rung as anyOf" do
      action = build_axn { expects :m, type: Array, of: { klass: Array, of: [String, Integer] } }

      expect(action.input_schema.dig(:properties, :m, :items, :items)).to eq(
        anyOf: [{ type: "string" }, { type: "integer" }],
      )
    end

    # A bag hands its `of:`/`shape:` to the next level as ActiveModel entries verbatim
    # (`OfValidator#inner_contract_validations`), so a per-validator gate written on one really can skip that
    # level on a given call. OUTPUT therefore drops it, exactly as `effective_validations` drops a gated entry
    # at a field — an output schema must not promise what a closed gate may not enforce. INPUT keeps it, for
    # the same reason `effective_validations` leaves input untouched: static-maximal is the safe direction
    # there, since a gate can only relax enforcement at runtime.
    describe "a gate on an inner rung" do
      let(:action) do
        build_axn do
          exposes :rows, type: Array, of: { klass: Array, of: { klass: Integer, if: :flag } }, allow_blank: true
          def call = nil
        end
      end

      it "drops the gated rung from the OUTPUT schema" do
        expect(action.output_schema.dig(:properties, :rows, :items)).to eq({ type: "array" })
      end

      it "keeps it on INPUT" do
        inbound = build_axn { expects :rows, type: Array, of: { klass: Array, of: { klass: Integer, if: :flag } } }

        expect(inbound.input_schema.dig(:properties, :rows, :items)).to eq({ type: "array", items: { type: "integer" } })
      end

      it "keeps an UNgated rung on output" do
        ungated = build_axn do
          exposes :rows, type: Array, of: { klass: Array, of: Integer }, allow_blank: true
          def call = nil
        end

        expect(ungated.output_schema.dig(:properties, :rows, :items)).to eq({ type: "array", items: { type: "integer" } })
      end
    end

    it "emits a map nested inside an array" do
      action = build_axn { expects :m, type: Array, of: { klass: Hash, of: { values: Integer } } }

      expect(action.input_schema.dig(:properties, :m, :items)).to include(
        type: "object", additionalProperties: { type: "integer" },
      )
    end

    # `contents_node_schema` seeds the node from `klass:` only when the bag names one, where the read it replaced
    # took `of[:klass]` unconditionally and turned a nil into `items: { anyOf: [] }` — a schema no element can
    # satisfy. No declaration produces a klass-less bag today (`of: {}` and `of: []` are both refused as
    # constraining nothing), so this is a config assigned onto a class —
    # but it is exactly the shape a `shape:`-only bag will canonicalize to, which is why the behavior is pinned
    # rather than left to be rediscovered.
    it "emits no items for a bag that names no class" do
      config = Axn::Core::Contract::FieldConfig.new(field: :m, reader_as: :m,
                                                    validations: { type: { klass: Array }, of: { container: Array } })

      expect(described_class.build_input([config]).dig(:properties, :m)).not_to have_key(:items)
    end
  end

  # `null` is a first-class JSON type, so a declared `NilClass` has an exact JSON Schema spelling. It reached
  # `single_type_for`'s final branch instead — the "unknown Ruby class, keep a permissive string hint" fallback,
  # whose premise ("a JSON client can't send a Ruby object anyway") is true of a PORO and false of nil.
  #
  # The rule the emitted `"null"` follows: it comes from the NULLABILITY decision (`nil_allowed?`), never from a
  # type token. A token contributes a branch; whether that branch survives is the nullability question, asked
  # once. Otherwise a required `type: [String, NilClass]` — which rejects nil, because its `presence:` entry
  # does — would advertise `null` as acceptable, and a nullable one would advertise it twice.
  describe "a declared NilClass token" do
    it "reflects as null rather than the unknown-class string fallback" do
      action = build_axn { expects :f, type: NilClass, optional: true }

      expect(action.input_schema[:properties][:f]).to include(type: "null")
    end

    it "emits no emptiness floor for it (null has no size)" do
      action = build_axn { expects :f, type: NilClass, optional: true }

      expect(action.input_schema[:properties][:f]).not_to have_key(:minLength)
    end

    it "names null exactly once when the field is also nullable" do
      action = build_axn { expects :f, type: NilClass, optional: true }

      expect(action.input_schema[:properties][:f][:type]).to eq("null")
    end

    it "emits a union naming it as an anyOf branch when the field admits nil" do
      action = build_axn { expects :f, type: [String, NilClass], optional: true }

      expect(action.input_schema[:properties][:f][:anyOf]).to eq([{ type: "string" }, { type: "null" }])
    end

    # The discriminating case for "nullability decides, not the token": this field REJECTS nil at runtime (the
    # default presence check), so the branch the token contributed must not survive into the document.
    it "drops the branch on a required field, which rejects nil" do
      action = build_axn { expects :f, type: [String, NilClass] }

      expect(action.call(f: nil)).not_to be_ok
      expect(action.input_schema[:properties][:f]).to include(type: "string")
      expect(action.input_schema[:properties][:f][:anyOf]).to be_nil
    end

    # A lone `NilClass` with no tolerance admits NOTHING at runtime: the presence check rejects nil, and nothing
    # else is a NilClass. `"null"` was emitted anyway, which advertised the single value the contract rejects —
    # schema LOOSER than runtime, the one direction reflection may never err in. `enum: []` is the faithful node,
    # the spelling used wherever a contract admits nothing. Refusing the declaration outright is PRO-3220's.
    it "emits the unsatisfiable node for a required lone NilClass, which admits nothing at all" do
      action = build_axn { expects :f, type: NilClass }

      expect(action.call(f: nil)).not_to be_ok
      expect(action.call(f: "x")).not_to be_ok
      expect(action.call).not_to be_ok
      expect(action.input_schema[:properties][:f]).to eq(enum: [])
    end

    it "emits it on output too, where the action cannot settle successfully either" do
      action = build_axn do
        exposes :f, type: NilClass
        def call = expose(:f, nil)
      end

      expect(action.call).not_to be_ok
      expect(action.output_schema[:properties][:f]).to eq(enum: [])
    end

    # The soundness half: every nil-TOLERANT spelling is satisfiable, so none of them may be emptied. Each of
    # these accepts nil at runtime and keeps its `"null"`.
    [{ optional: true }, { allow_nil: true }, { allow_blank: true }, { presence: false }].each do |tolerance|
      it "keeps null under #{tolerance.keys.first}: #{tolerance.values.first}, which nil really does satisfy" do
        action = build_axn { expects :f, type: NilClass, **tolerance }

        expect(action.call(f: nil)).to be_ok
        expect(action.input_schema[:properties][:f]).to include(type: "null")
      end
    end

    context "at an of: bag position, where there is no presence check to make it inert" do
      it "reflects an element bag's klass" do
        action = build_axn { expects :f, type: Array, of: { klass: NilClass } }

        expect(action.call(f: [nil])).to be_ok
        expect(action.input_schema.dig(:properties, :f, :items)).to eq(type: "null")
      end

      # The position's mirror of a required field-level lone `NilClass`: a validator on the bag that rejects nil
      # leaves the position admitting nothing at all, so the node has to say so rather than advertise `null`.
      it "empties a lone null position another validator on the bag rejects" do
        action = build_axn { expects :f, type: Array, of: { klass: NilClass, presence: true } }

        expect(action.call(f: [nil])).not_to be_ok
        expect(action.input_schema.dig(:properties, :f, :items)).to eq(enum: [])
      end

      it "empties it on output too, at a map's values axis" do
        action = build_axn do
          exposes :m, type: Hash, of: { values: { klass: NilClass, presence: true } }
          def call = expose(:m, { a: nil })
        end

        expect(action.call).not_to be_ok
        expect(action.output_schema.dig(:properties, :m, :additionalProperties)).to eq(enum: [])
      end

      it "reflects a union element bag as distinct branches" do
        action = build_axn { expects :f, type: Array, of: { klass: [String, NilClass] } }

        expect(action.call(f: ["a", nil])).to be_ok
        expect(action.input_schema.dig(:properties, :f, :items))
          .to eq(anyOf: [{ type: "string" }, { type: "null" }])
      end

      it "reflects a map's values axis" do
        action = build_axn { expects :f, type: Hash, of: { values: [Integer, NilClass] } }

        expect(action.call(f: { a: nil })).to be_ok
        expect(action.input_schema.dig(:properties, :f, :additionalProperties))
          .to eq(anyOf: [{ type: "integer" }, { type: "null" }])
      end

      it "reflects a nested bag at depth 2" do
        action = build_axn { expects :f, type: Array, of: { klass: Array, of: [Integer, NilClass] } }

        expect(action.call(f: [[1, nil]])).to be_ok
        expect(action.input_schema.dig(:properties, :f, :items, :items))
          .to eq(anyOf: [{ type: "integer" }, { type: "null" }])
      end

      it "reflects a shape member's own union" do
        action = build_axn do
          expects :f, type: Array, of: Hash do
            field :s, type: [String, NilClass], allow_nil: true
          end
        end

        expect(action.input_schema.dig(:properties, :f, :items, :properties, :s, :anyOf))
          .to eq([{ type: "string" }, { type: "null" }])
      end
    end
  end

  # The ceiling twin of the emptiness floor. Emitting it only shrinks the schema-valid set, so it preserves the
  # documented direction (docs/reference/class.md:270 — stricter than the runtime, never looser) by construction.
  describe "size ceilings" do
    it "emits maxItems for an Array length maximum" do
      action = build_axn { expects :tags, type: Array, of: String, length: { maximum: 2 } }

      expect(action.input_schema[:properties][:tags][:maxItems]).to eq(2)
    end

    it "emits maxProperties for a Hash length maximum" do
      action = build_axn { expects :meta, type: Hash, length: { maximum: 3 } }

      expect(action.input_schema[:properties][:meta][:maxProperties]).to eq(3)
    end

    it "emits maxLength for a String length maximum" do
      action = build_axn { expects :name, type: String, length: { maximum: 5 } }

      expect(action.input_schema[:properties][:name][:maxLength]).to eq(5)
    end

    it "emits both bounds from a range" do
      prop = build_axn { expects :tags, type: Array, length: { in: 2..4 } }.input_schema[:properties][:tags]

      expect(prop[:minItems]).to eq(2)
      expect(prop[:maxItems]).to eq(4)
    end

    it "counts one less for an exclusive range end, as ActiveModel does" do
      prop = build_axn { expects :tags, type: Array, length: { in: 2...4 } }.input_schema[:properties][:tags]

      expect(prop[:maxItems]).to eq(3)
    end

    it "emits both bounds from an exact length" do
      prop = build_axn { expects :tags, type: Array, length: { is: 2 } }.input_schema[:properties][:tags]

      expect(prop[:minItems]).to eq(2)
      expect(prop[:maxItems]).to eq(2)
    end

    it "emits a zero ceiling, which names size 0 as the only admissible size" do
      prop = build_axn { expects :tags, type: Array, length: { maximum: 0 }, allow_empty: true }.input_schema[:properties][:tags]

      expect(prop[:maxItems]).to eq(0)
    end

    # `absence:` names size 0 as the only admissible size just as surely as `length: { maximum: 0 }` does —
    # it rejects every non-blank value — so it carries the ceiling through the same derivation. Without it the
    # node said nothing at all while the runtime admitted the empty container only: a schema LOOSER than the
    # contract.
    it "emits a zero ceiling for absence: alongside a dropped floor" do
      prop = build_axn { expects :tags, type: Array, absence: true, allow_empty: true }.input_schema[:properties][:tags]

      expect(prop[:maxItems]).to eq(0)
    end

    it "emits it for a Hash field on its own size key" do
      meta = build_axn { expects :meta, type: Hash, absence: true, allow_empty: true }.input_schema[:properties][:meta]

      expect(meta[:maxProperties]).to eq(0)
    end

    # ActiveSupport gives String a `blank?` of its own, under which `"  "` is blank and two characters long —
    # so an `absence:` there bounds WHITESPACE, which no size key expresses, and reading a ceiling out of it
    # would advertise a bound the runtime does not carry.
    it "emits no ceiling for a String absence:, whose blank values are not its empty ones" do
      name = build_axn { expects :name, type: String, absence: true, allow_empty: true }.input_schema[:properties][:name]

      expect(name).not_to have_key(:maxLength)
    end

    # A union emits one branch per token and no bound lands on a branch with no size keyword, so a token that
    # cannot carry the ceiling must not veto it for the tokens that can.
    it "keeps the ceiling on the size-bearing branch of a union whose other token carries no size" do
      prop = build_axn do
        expects :f, type: [Array, Integer], presence: false, absence: true
      end.input_schema[:properties][:f]

      expect(prop[:anyOf]).to include(a_hash_including(type: "array", maxItems: 0))
      expect(prop[:anyOf]).to include(a_hash_including(type: "integer"))
      expect(prop[:anyOf].find { |b| b[:type] == "integer" }).not_to have_key(:maxItems)
    end

    # A String branch IS size-bearing, and an `absence:` bounds whitespace there rather than size — so one
    # among the tokens takes the ceiling off the whole union rather than putting a wrong bound on that branch.
    it "drops the ceiling from a union carrying a String" do
      prop = build_axn do
        expects :f, type: [Array, String], presence: false, absence: true
      end.input_schema[:properties][:f]

      expect(prop[:anyOf].map(&:keys).flatten).not_to include(:maxItems, :maxLength)
    end

    # The blank-is-empty classification the ceiling turns on reads the declared token, and a token is a
    # caller's own Class or Module — so it is classified with `case`/`when ::Array` rather than `Kernel#Array`,
    # which would DISPATCH `to_ary` on it. Asked of the derivation directly, since other (pre-existing) readers
    # on the same path still use `Kernel#Array`.
    it "classifies declared type tokens without dispatching to_ary" do
      dispatched = []
      token = Class.new do
        define_singleton_method(:to_ary) do
          dispatched << :to_ary
          [String]
        end
      end

      expect(described_class.declared_type_tokens({ type: token })).to eq([token])
      expect(described_class.declared_type_tokens({ type: { klass: token } })).to eq([token])
      expect(dispatched).to eq([])
    end

    # The same classification, asked of the nil-tolerance funnel: `Validation::Base.type_admits_nil?` is what
    # every requiredness and nullability answer turns on AND what each declaration guard that stands down on a
    # nil tolerance asks at class-definition time, so a token deciding how it is read there decides a guard's
    # verdict. Asked of the derivation directly, because other (pre-existing) readers on the declaration path
    # still use `Kernel#Array` — see PRO-3233.
    it "judges a type entry's nil tolerance without dispatching to_ary" do
      dispatched = []
      token = Class.new do
        define_singleton_method(:to_ary) do
          dispatched << :to_ary
          [NilClass]
        end
      end

      expect(Axn::Validation::Base.type_admits_nil?(token)).to be(false)
      expect(Axn::Validation::Base.type_admits_nil?({ klass: token })).to be(false)
      expect(dispatched).to eq([])
    end

    # `single_type_for` is the emitter's type resolver AND what the blank axis reads to decide whether a
    # declared type's branch can carry a size at all — so a declaration guard inherits every dispatch it makes.
    # Each of the four spellings a token could answer for itself is replaced by a native one: identity for `==`,
    # `Module#===` for `is_a?`, the ancestry out of the method table for `<`/`<=`/`>=`, and an identity scan of
    # TYPE_MAP/FORMAT_MAP for a `Hash#key?` that would hash the token.
    it "resolves a declared token's type without dispatching to it" do
      dispatched = []
      token = Class.new(Array) do
        %i[hash eql? == is_a? < <= >= ancestors].each do |name|
          define_singleton_method(name) do |*args, &blk|
            dispatched << name
            super(*args, &blk)
          end
        end
      end

      expect(described_class.single_type_for(token, for_output: false)).to eq({ type: "string" })
      expect(described_class.single_type_for(token, for_output: true)).to eq({})
      expect(dispatched).to eq([])
    end

    # The reviewer's case end to end: an `Array` subclass whose singleton `hash` RAISES. `TYPE_MAP.key?(token)`
    # ran it from the declaration guard, so the class could not be defined — while an empty instance satisfies
    # the contract at runtime, which is the direction a declaration guard may never err in.
    it "declares a token whose hash raises, and accepts its empty instance" do
      token = Class.new(Array)
      token.define_singleton_method(:hash) { raise ArgumentError, "hash ran" }
      token.define_singleton_method(:name) { "Token" }

      action = nil
      expect do
        action = build_axn { expects :f, type: token, presence: false, absence: true }
      end.not_to raise_error
      expect(action.call(f: token.new).ok?).to be(true)
    end

    # A ceiling derived from `absence:` is one axn infers rather than one the author wrote, so it is taken only
    # from a check that always runs — unlike a `length:` bound, which is emitted as written whatever gates it.
    it "emits no ceiling for a GATED absence:" do
      prop = build_axn do
        expects :tags, type: Array, absence: { if: -> { false } }, allow_empty: true
      end.input_schema[:properties][:tags]

      expect(prop).not_to have_key(:maxItems)
    end

    it "emits it beside the nullability branch a tolerance adds" do
      prop = build_axn { expects :tags, type: Array, absence: true, optional: true }.input_schema[:properties][:tags]

      expect(prop[:type]).to eq(%w[array null])
      expect(prop[:maxItems]).to eq(0)
    end

    # Nothing carries a size for an Integer to bound, so the ceiling the declaration names is emitted nowhere
    # rather than onto a key that would not mean it.
    it "emits no ceiling where the declared type has no size" do
      prop = build_axn { expects :n, type: Integer, absence: true, presence: false }.input_schema[:properties][:n]

      expect(prop.keys).not_to include(:maxItems, :maxLength, :maxProperties)
    end

    it "emits the ceiling on every size-bearing branch of a union" do
      prop = build_axn { expects :f, type: [String, Array], length: { maximum: 2 } }.input_schema[:properties][:f]

      expect(prop[:anyOf]).to include(a_hash_including(type: "string", maxLength: 2))
      expect(prop[:anyOf]).to include(a_hash_including(type: "array", maxItems: 2))
    end

    it "emits no ceiling for a per-call bound ActiveModel resolves against the record" do
      prop = build_axn { expects :tags, type: Array, length: { maximum: :max_tags } }.input_schema[:properties][:tags]

      expect(prop).not_to have_key(:maxItems)
    end

    it "emits no ceiling for an infinite one, which no finite number expresses" do
      prop = build_axn { expects :tags, type: Array, length: { maximum: Float::INFINITY } }.input_schema[:properties][:tags]

      expect(prop).not_to have_key(:maxItems)
    end

    it "emits no ceiling for a type with no size" do
      prop = build_axn { expects :n, type: Integer, length: { maximum: 2 } }.input_schema[:properties][:n]

      expect(prop).not_to have_key(:maxItems)
      expect(prop).not_to have_key(:maxLength)
    end

    it "emits no ceiling where the declaration names none" do
      prop = build_axn { expects :tags, type: Array, of: String }.input_schema[:properties][:tags]

      expect(prop).not_to have_key(:maxItems)
      expect(prop[:minItems]).to eq(1)
    end
  end

  describe "Validation::Base.declared_length_ceiling" do
    it "reads a maximum, an exact length, and a range end" do
      expect(Axn::Validation::Base.declared_length_ceiling({ maximum: 2 })).to eq(2)
      expect(Axn::Validation::Base.declared_length_ceiling({ is: 3 })).to eq(3)
      expect(Axn::Validation::Base.declared_length_ceiling({ in: 1..4 })).to eq(4)
    end

    it "answers nil where the ceiling is open" do
      expect(Axn::Validation::Base.declared_length_ceiling({ minimum: 2 })).to be_nil
      expect(Axn::Validation::Base.declared_length_ceiling({})).to be_nil
    end

    it "answers :unverifiable for a bound ActiveModel resolves per call" do
      expect(Axn::Validation::Base.declared_length_ceiling({ maximum: :max })).to eq(:unverifiable)
    end

    it "admits only a non-negative Integer as emittable" do
      expect(Axn::Validation::Base.emittable_length_ceiling?(0)).to be(true)
      expect(Axn::Validation::Base.emittable_length_ceiling?(2)).to be(true)
      expect(Axn::Validation::Base.emittable_length_ceiling?(Float::INFINITY)).to be(false)
      expect(Axn::Validation::Base.emittable_length_ceiling?(2.5)).to be(false)
      expect(Axn::Validation::Base.emittable_length_ceiling?(:unverifiable)).to be(false)
      expect(Axn::Validation::Base.emittable_length_ceiling?(nil)).to be(false)
    end
  end

  # `enum` (from `inclusion:`) and the size bounds (from `length:`) projected; nothing else did. A declared
  # numeric bound was enforced at runtime and advertised nowhere, which is LOOSER than the runtime — the one
  # direction reflection is not licensed to err in (docs/reference/class.md: stricter, never looser).
  #
  # Bounds are read through `Validation::Base.declared_numeric_bounds`, the same reader/mapper split
  # `length:` uses (`declared_length_checks` -> `size_bounds_for`), so the runtime bound and the emitted
  # bound cannot disagree about one declaration.
  describe "numeric bounds" do
    def prop_for(field = :n, &declaration)
      build_axn(&declaration).input_schema[:properties][field]
    end

    it "emits exclusiveMinimum for greater_than" do
      expect(prop_for { expects :n, type: Integer, numericality: { greater_than: 0 } })
        .to include(exclusiveMinimum: 0)
    end

    it "emits minimum for greater_than_or_equal_to" do
      expect(prop_for { expects :n, type: Integer, numericality: { greater_than_or_equal_to: 1 } })
        .to include(minimum: 1)
    end

    it "emits exclusiveMaximum for less_than" do
      expect(prop_for { expects :n, type: Integer, numericality: { less_than: 10 } })
        .to include(exclusiveMaximum: 10)
    end

    it "emits maximum for less_than_or_equal_to" do
      expect(prop_for { expects :n, type: Integer, numericality: { less_than_or_equal_to: 10 } })
        .to include(maximum: 10)
    end

    it "emits both bounds when both are declared" do
      expect(prop_for { expects :n, type: Integer, numericality: { greater_than: 0, less_than: 10 } })
        .to include(exclusiveMinimum: 0, exclusiveMaximum: 10)
    end

    it "emits const for equal_to" do
      expect(prop_for { expects :n, type: Integer, numericality: { equal_to: 5 } }).to include(const: 5)
    end

    it "emits a Float bound" do
      expect(prop_for { expects :n, type: Float, numericality: { greater_than: 0.5 } })
        .to include(exclusiveMinimum: 0.5)
    end

    # ActiveModel resolves an `in:` range through `Object#in?`, inclusive of both ends unless the range
    # excludes its own, which is the same resolution `length:`'s range already gets.
    it "expands an inclusive in: range into both bounds" do
      expect(prop_for { expects :n, type: Integer, numericality: { in: 1..10 } })
        .to include(minimum: 1, maximum: 10)
    end

    it "expands an exclusive-end in: range into an exclusiveMaximum" do
      expect(prop_for { expects :n, type: Integer, numericality: { in: 1...10 } })
        .to include(minimum: 1, exclusiveMaximum: 10)
    end

    it "reads the same bounds off a comparison: entry" do
      expect(prop_for { expects :n, type: Integer, comparison: { greater_than: 0 } })
        .to include(exclusiveMinimum: 0)
    end

    # `comparison:` has no `in:` check of its own (ActiveModel's COMPARE_CHECKS names five operators and
    # `other_than:`), so reading a range there would emit a bound nothing enforces.
    it "does not expand an in: range on a comparison: entry, which ActiveModel never reads" do
      prop = prop_for { expects :n, type: Integer, comparison: { in: 1..10 } }

      expect(prop).not_to have_key(:minimum)
      expect(prop).not_to have_key(:maximum)
    end

    it "narrows the type to integer under only_integer, even when type: names a wider Numeric" do
      expect(prop_for { expects :n, type: Numeric, numericality: { only_integer: true } })
        .to include(type: "integer")
    end

    # A UNION had been standing down from that narrowing, which left a `"number"` branch advertising values the
    # validator rejects. Narrowing both branches of `[Integer, Float]` converges them, so the node collapses.
    it "narrows every numeric branch of a union, not only a lone type" do
      action = build_axn { expects :n, type: [Integer, Float], numericality: { only_integer: true } }

      expect(action.input_schema[:properties][:n]).to eq(type: "integer")
      expect(action.call(n: 1.5)).not_to be_ok
      expect(action.call(n: 2)).to be_ok
    end

    # A string branch is not dropped — ActiveModel parses a numeric STRING, so `"2"` is a value the position
    # really accepts — but it is not left unconstrained either: it carries the validator's own integer test, so
    # it stops advertising `"abc"`. And the Float branch goes: no Float satisfies `only_integer:` (`2.0.to_s` is
    # "2.0"), and retagging it `"integer"` had advertised the JSON `2`, which `is_a?(Float)` rejects.
    it "patterns the string branch and drops a numeric branch no value can occupy" do
      action = build_axn { expects :n, type: [String, Float], numericality: { only_integer: true } }
      prop = action.input_schema[:properties][:n]

      expect(prop).to eq(type: "string", pattern: "^[+-]?\\d+$", minLength: 1)
      expect(action.call(n: "2")).to be_ok
      expect(action.call(n: "abc")).not_to be_ok
      expect(action.call(n: 2)).not_to be_ok
      expect(action.call(n: 2.0)).not_to be_ok
    end

    # Every branch dropping is the CONTRACT rather than a case to fall back from. No Float's `to_s` is an
    # integer literal and a JSON integer is not a Float, so this position admits nothing at all — restoring the
    # node advertised `1.5` where the runtime rejects it. A node nothing satisfies is the faithful projection,
    # on the same terms two disagreeing `equal_to:` bounds already emit `enum: []`; refusing the declaration
    # outright belongs to the contradiction detectors, not to the emitter.
    it "emits a node nothing satisfies where the narrowing empties the union" do
      action = build_axn { expects :n, type: Float, numericality: { only_integer: true } }

      expect(action.input_schema[:properties][:n]).to eq(enum: [])
      expect(action.call(n: 1.5)).not_to be_ok
      expect(action.call(n: 2.0)).not_to be_ok
      expect(action.call(n: 2)).not_to be_ok
    end

    # `only_numeric: true` is what makes ActiveModel demand a Numeric OBJECT rather than parse a string, so the
    # branch that exists to carry `"2"` has nothing left to carry.
    it "drops the string branch when only_numeric: demands a real numeric" do
      action = build_axn do
        expects :n, type: [String, Integer], numericality: { only_integer: true, only_numeric: true }
      end

      expect(action.input_schema[:properties][:n]).to eq(type: "integer")
      expect(action.call(n: 2)).to be_ok
      expect(action.call(n: "2")).not_to be_ok
    end

    it "empties the node when only_numeric: leaves a String position nothing to hold" do
      action = build_axn do
        expects :n, type: String, numericality: { only_integer: true, only_numeric: true }
      end

      expect(action.input_schema[:properties][:n]).to eq(enum: [])
      expect(action.call(n: "2")).not_to be_ok
    end

    # `only_numeric:` narrows on its OWN, without `only_integer:` beside it — the pass used to be gated on
    # `only_integer:`, so this whole family went unapplied and the document accepted values the validator refuses.
    describe "only_numeric: standing without only_integer:" do
      it "drops the string branch, which no value can occupy" do
        action = build_axn { expects :n, type: [String, Integer], numericality: { only_numeric: true } }

        expect(action.input_schema[:properties][:n]).to eq(type: "integer")
        expect(action.call(n: 1)).to be_ok
        expect(action.call(n: "abc")).not_to be_ok
        # The numeric STRING is the telling one: bare `numericality:` accepts it, and `only_numeric:` does not.
        expect(action.call(n: "1")).not_to be_ok
      end

      it "empties a lone String position it leaves nothing to hold" do
        action = build_axn { expects :n, type: String, numericality: { only_numeric: true } }

        expect(action.input_schema[:properties][:n]).to eq(enum: [])
        expect(action.call(n: "1")).not_to be_ok
      end

      # Not just the string branch: the option demands a Numeric OBJECT, so every branch naming values that are
      # not Numerics is unreachable in the same way.
      [[Array, [1]], [Hash, { a: 1 }], [TrueClass, true]].each do |(klass, value)|
        it "drops a #{klass} branch on the same reading" do
          action = build_axn { expects :n, type: [klass, Integer], numericality: { only_numeric: true } }

          expect(action.input_schema[:properties][:n]).to eq(type: "integer")
          expect(action.call(n: value)).not_to be_ok
          expect(action.call(n: 1)).to be_ok
        end
      end

      # A narrowing that empties every TYPE branch has said nothing about nil, which the validators SKIP
      # wherever the field tolerates one — so the node admits nil and nothing else, and the bare empty set
      # rejected the very value the position accepts. Found by a differential scan of the emitted schema
      # against runtime truth, not by a review.
      it "admits nil where the emptied narrowing sits on a nullable position" do
        action = build_axn do
          exposes :n, type: String, numericality: { only_numeric: true }, optional: true
          def call = expose(:n, nil)
        end

        expect(action.call).to be_ok
        expect(action.output_schema[:properties][:n]).to eq(enum: [nil])
      end

      it "still empties completely where the position is NOT nullable" do
        action = build_axn { expects :n, type: String, numericality: { only_numeric: true } }

        expect(action.input_schema[:properties][:n]).to eq(enum: [])
      end

      # A MISSING emitted type is not evidence the branch is non-Numeric. `type: Numeric` emits `{}` on output
      # deliberately — its values have more than one wire form — and reading that absence as proof emptied a
      # position the action satisfies perfectly well.
      # The same lesson one step further: an ABSENT emitted type is not evidence, and neither is an APPROXIMATE
      # one. A token that is a SUPERTYPE of Numeric — `Object`, `Comparable` — admits a Numeric value while
      # `single_type_for` renders it as a `"string"` branch, so dropping that branch as "names non-Numerics"
      # emptied a contract an Integer satisfies.
      it "keeps a branch a broad token renders approximately" do
        action = build_axn { expects :n, type: Object, numericality: { only_numeric: true } }

        expect(action.call(n: 1)).to be_ok
        expect(action.input_schema[:properties][:n]).not_to eq(enum: [])
      end

      it "reads Comparable the same way, being a supertype of Numeric too" do
        action = build_axn { expects :n, type: Comparable, numericality: { only_numeric: true } }

        expect(action.call(n: 1)).to be_ok
        expect(action.input_schema[:properties][:n]).not_to eq(enum: [])
      end

      # The control that keeps the guard honest: an EXACT non-numeric token still empties, because there really
      # is no value of it a Numeric can be.
      it "still empties a lone String position, which no Numeric can occupy" do
        action = build_axn { expects :n, type: String, numericality: { only_numeric: true } }

        expect(action.call(n: "1")).not_to be_ok
        expect(action.input_schema[:properties][:n]).to eq(enum: [])
      end

      it "keeps an untyped branch, whose absent type proves nothing" do
        action = build_axn do
          exposes :n, type: Numeric, numericality: { only_numeric: true }
          def call = expose(:n, 1)
        end
        result = action.call

        expect(result).to be_ok
        expect(Axn::Extensions::Serialization.render(result)["n"]).to eq(1)
        expect(action.output_schema[:properties][:n]).to eq({})
      end

      it "still names the type on input, where Numeric has one wire form to advertise" do
        action = build_axn { expects :n, type: Numeric, numericality: { only_numeric: true } }

        expect(action.input_schema[:properties][:n]).to eq(type: "number")
        expect(action.call(n: 1)).to be_ok
        expect(action.call(n: "a")).not_to be_ok
      end

      # NULLABILITY owns the null branch: ActiveModel skips a nil before any validator sees it, so neither
      # option says anything about it and dropping it would reject a value the contract accepts.
      it "keeps the null branch, which the validator never judges" do
        action = build_axn do
          expects :n, type: [String, Integer, NilClass], numericality: { only_numeric: true }, optional: true
        end

        expect(action.input_schema.dig(:properties, :n, :anyOf)).to eq([{ type: "integer" }, { type: "null" }])
        expect(action.call(n: nil)).to be_ok
        expect(action.call(n: "abc")).not_to be_ok
      end

      # A Proc/Symbol `only_numeric:` still narrows, and that is not an oversight: ActiveModel reads this one
      # TRUTHILY (`options[:only_numeric] && !raw_value.is_a?(Numeric)`) rather than resolving it per call, so a
      # callable token means the demand is always on — the opposite of `only_integer:`, which IS resolved.
      it "narrows under a callable token, which ActiveModel reads truthily" do
        action = build_axn { expects :n, type: [String, Integer], numericality: { only_numeric: -> { false } } }

        expect(action.input_schema[:properties][:n]).to eq(type: "integer")
        expect(action.call(n: "abc")).not_to be_ok
        expect(action.call(n: 1)).to be_ok
      end
    end

    # `only_integer:` drops a branch naming non-Numerics just as `only_numeric:` does — no Array, Hash or
    # boolean satisfies either (`[1].to_s` is "[1]", `true.to_s` is "true", neither an integer literal), so the
    # branch was advertising an element the validator rejects on every call. A String branch is the exception
    # and survives: ActiveModel parses a numeric string, so it carries the integer test as a pattern instead.
    describe "only_integer: reaching a branch that names non-Numerics" do
      it "drops an Array branch at a bag position" do
        action = build_axn { expects :f, type: Array, of: { klass: [Array, Integer], numericality: { only_integer: true } } }

        expect(action.call(f: [1])).to be_ok
        expect(action.call(f: [[1]])).not_to be_ok
        expect(action.input_schema.dig(:properties, :f, :items)).to eq(type: "integer")
      end

      it "drops a boolean branch at a field" do
        action = build_axn { expects :n, type: [TrueClass, FalseClass, Integer], numericality: { only_integer: true } }

        expect(action.call(n: 1)).to be_ok
        expect(action.call(n: true)).not_to be_ok
        expect(action.input_schema[:properties][:n]).to eq(type: "integer")
      end

      it "keeps the string branch, which the validator really does parse" do
        action = build_axn { expects :n, type: [String, Integer], numericality: { only_integer: true } }

        expect(action.call(n: "2")).to be_ok
        expect(action.input_schema.dig(:properties, :n, :anyOf))
          .to eq([{ type: "string", pattern: "^[+-]?\\d+$", minLength: 1 }, { type: "integer" }])
      end
    end

    # The same drop under a BARE `numericality:`, and the reason it is the validator's rather than either
    # option's: ActiveModel asks `is_number?` BEFORE it reads any option, and `only_numeric:` is one more
    # restriction inside that check rather than the thing that establishes it. So no spelling of the validator
    # can be satisfied by a value that does not parse as a number, and the options govern only the two things
    # they alone decide — whether the string branch survives, and whether a numeric branch retags to "integer".
    #
    # Soundness rests on "no Array, Hash or boolean parses as a number", which is exact for booleans (a
    # `TrueClass` subclass is legal and can never be instantiated — `new` and `allocate` both raise) and, for the
    # containers, rests on the footing the two options above already stand on: a subclass reimplementing BOTH
    # `to_s` and `to_i` to impersonate a number satisfies the validator, and `only_integer:` has been dropping
    # its branch since before this. One footing for all three spellings, not a new one for this.
    describe "a bare numericality:, which demands a number before any option is read" do
      it "drops a boolean branch at a field" do
        action = build_axn { expects :n, type: [TrueClass, Integer], numericality: true }

        expect(action.call(n: 1)).to be_ok
        expect(action.call(n: true)).not_to be_ok
        expect(action.input_schema[:properties][:n]).to eq(type: "integer")
      end

      it "drops an Array branch at a field" do
        action = build_axn { expects :n, type: [Array, Integer], numericality: true }

        expect(action.call(n: 1)).to be_ok
        expect(action.call(n: [1])).not_to be_ok
        expect(action.input_schema[:properties][:n]).to eq(type: "integer")
      end

      it "drops a boolean branch at a bag position" do
        action = build_axn { expects :f, type: Array, of: { klass: [TrueClass, Integer], numericality: true } }

        expect(action.call(f: [1])).to be_ok
        expect(action.call(f: [true])).not_to be_ok
        expect(action.input_schema.dig(:properties, :f, :items)).to eq(type: "integer")
      end

      # An option-less entry is not the only spelling that reaches here: an entry whose options carry no
      # emittable bound leaves `restrict_union_to_bounded_branches!` nothing to narrow on, so the drop is the
      # only thing standing between the document and a branch the runtime rejects.
      it "drops the branch under an entry whose only option emits no bound" do
        action = build_axn { expects :n, type: [TrueClass, Integer], numericality: { other_than: 5 } }

        expect(action.call(n: 1)).to be_ok
        expect(action.call(n: true)).not_to be_ok
        expect(action.input_schema[:properties][:n]).to eq(type: "integer")
      end

      # The string branch is the one this may not touch: bare `numericality:` really does accept a numeric
      # string, so the branch is reachable. That it carries no PATTERN saying which strings is PRO-3240 item 3,
      # excluded by name in the wire audit; what this pins is that the branch stays.
      it "keeps the string branch, whose numeric strings the validator accepts" do
        action = build_axn { expects :n, type: [String, Integer], numericality: true }

        expect(action.call(n: "1")).to be_ok
        expect(action.input_schema.dig(:properties, :n, :anyOf))
          .to eq([{ type: "string", minLength: 1 }, { type: "integer" }])
      end

      # Every branch dropping is the contract, not a case to fall back from — no boolean is a number, so the
      # position admits nothing and the node says so. Same projection `only_numeric:` already emits for the
      # same contract, which is the point: the two spellings now agree.
      it "empties a node whose every branch names non-Numerics" do
        action = build_axn { expects :n, type: [TrueClass, FalseClass], numericality: true }

        expect(action.call(n: true)).not_to be_ok
        expect(action.call(n: false)).not_to be_ok
        expect(action.input_schema[:properties][:n]).to eq(enum: [])
      end

      # Nullability owns the nil, and a narrowing that empties every TYPE branch has said nothing about it —
      # the validators skip a nil wherever the field tolerates one, so the position admits nil and nothing else.
      it "leaves the nil a nullable position still admits" do
        action = build_axn { expects :n, type: TrueClass, numericality: true, optional: true }

        expect(action.call(n: nil)).to be_ok
        expect(action.call(n: true)).not_to be_ok
        expect(action.input_schema[:properties][:n]).to eq(enum: [nil])
      end

      # A broad token still shields the branch, for the reason it always has: `single_type_for` renders `Object`
      # APPROXIMATELY as a `"string"` branch, so that branch's emitted type is no evidence about what the
      # position holds, and dropping it would empty a contract a plain `1` satisfies.
      it "keeps the branch a broad token reaches a Numeric through" do
        action = build_axn { expects :n, type: Object, numericality: true }

        expect(action.call(n: 1)).to be_ok
        expect(action.input_schema[:properties][:n]).to eq(type: "string", minLength: 1)
      end

      # A tolerated BLANK never reaches the validator — ActiveModel skips a blank before `is_number?` runs — so a
      # branch the numeric check excludes may still be occupied by its own blank, and dropping it outright refused
      # output the action produced. Each droppable type has exactly ONE blank, so the branch narrows TO it rather
      # than vanishing: right in both directions at once, since that blank is then the only value the branch
      # admits and the runtime agrees. Skipping the validator is only half the question, though — the value still
      # has to get past the POSITION, which is why a required position's empty container is still dropped.
      describe "a blank the position still admits at a branch the numeric check excludes" do
        it "narrows a boolean branch to its blank instead of dropping it" do
          action = build_axn { exposes :n, type: :boolean, numericality: { allow_blank: true } }

          expect(action.output_schema[:properties][:n]).to eq(type: "boolean", enum: [false])
        end

        it "accepts outbound the false it exposed" do
          action = build_axn do
            exposes :n, type: :boolean, numericality: { allow_blank: true }
            def call = expose(:n, false)
          end

          expect(action.call).to be_ok
        end

        it "keeps only the branch whose blank survives, dropping the one whose value is not blank" do
          action = build_axn { expects :n, type: [TrueClass, FalseClass], numericality: true, optional: true }

          # `true` is not blank, so nothing skips the validator there; `false` is, so that branch stays.
          expect(action.call(n: false)).to be_ok
          expect(action.call(n: true)).not_to be_ok
          expect(action.input_schema[:properties][:n]).to eq(type: %w[boolean null], enum: [false, nil])
        end

        it "narrows an Array branch to the empty array a tolerant position admits" do
          action = build_axn { expects :n, type: [Array, Integer], numericality: true, optional: true }

          expect(action.call(n: [])).to be_ok
          expect(action.call(n: [1])).not_to be_ok
          expect(action.input_schema.dig(:properties, :n, :anyOf))
            .to eq([{ type: "array", enum: [[]] }, { type: "integer" }, { type: "null" }])
        end

        # The half the entry's tolerance cannot answer. A REQUIRED position rejects an empty container on its own,
        # so no `[]` reaches the branch however blank-tolerant the entry is — and emitting the witness there would
        # name a branch nothing satisfies, `enum: [[]]` sitting beside the `minItems: 1` the same declaration
        # writes. Read through the very predicate the size floor comes from, so the two cannot disagree.
        it "still drops a required position's empty container" do
          action = build_axn { expects :n, type: [Array, Integer], numericality: { allow_blank: true } }

          expect(action.call(n: [])).not_to be_ok
          expect(action.input_schema[:properties][:n]).to eq(type: "integer")
        end

        # `:boolean` is the one token a required position admits a blank for — measured, `type: :boolean` accepts
        # `false` while `type: FalseClass` accepts nothing at all — so an explicitly-named `false` is held to the
        # same emptiness question the containers are.
        it "drops an explicitly-named false the required position refuses" do
          action = build_axn { expects :n, type: [FalseClass, Integer], numericality: { only_numeric: true, allow_blank: true } }

          expect(action.call(n: false)).not_to be_ok
          expect(action.input_schema[:properties][:n]).to eq(type: "integer")
        end

        # The witness reaches a consumer INSIDE a schema, and schemas are rebuilt per call and caller-mutable, so
        # a shared mutable `[]`/`{}` would let one consumer's mutation reach every schema emitted afterwards —
        # measured, appending to one action's witness changed a DIFFERENT action class's enum. Frozen on the same
        # terms `EMPTY_ENUM` and `NULL_BRANCH` already are, so a mutating consumer gets a FrozenError instead.
        it "hands out a witness no consumer can mutate into another action's schema" do
          one = build_axn { expects :n, type: [Array, Integer], numericality: true, optional: true }
          witness = one.input_schema.dig(:properties, :n, :anyOf, 0, :enum, 0)

          expect(witness).to be_frozen
          expect { witness << 99 }.to raise_error(FrozenError)

          other = build_axn { expects :z, type: [Array, Integer], numericality: true, optional: true }
          expect(other.input_schema.dig(:properties, :z, :anyOf, 0, :enum)).to eq([[]])
        end

        it "hands out an unmutatable object witness too" do
          action = build_axn { expects :n, type: [Hash, Integer], numericality: true, optional: true }
          witness = action.input_schema.dig(:properties, :n, :anyOf, 0, :enum, 0)

          expect(witness).to be_frozen
          expect { witness[:x] = 1 }.to raise_error(FrozenError)
        end

        # Not new with the bare spelling: `only_numeric:` had been dropping the branch too, so a blank-tolerant
        # position under it refused the output it produced. One rule for every spelling closes that as well.
        it "accepts outbound the false an only_numeric: position exposed" do
          action = build_axn do
            exposes :n, type: :boolean, numericality: { only_numeric: true, allow_blank: true }
            def call = expose(:n, false)
          end

          expect(action.call).to be_ok
          expect(action.output_schema[:properties][:n]).to eq(type: "boolean", enum: [false])
        end
      end

      # The boundary, and the one measured counterexample that draws it. `comparison:` is a different validator
      # with no numericality behind it, and `other_than:` is its INVERTED operator: `true != 5` passes, so the
      # boolean branch is reachable and may not be dropped. Nothing above reads a `comparison:` entry, and
      # `other_than:` writes no emittable bound either, so the branch stands — which is correct.
      it "does not drop a branch a comparison: other_than: really admits" do
        action = build_axn { expects :n, type: [TrueClass, Integer], comparison: { other_than: 5 } }

        expect(action.call(n: true)).to be_ok
        expect(action.input_schema.dig(:properties, :n, :anyOf))
          .to eq([{ type: "boolean", enum: [true] }, { type: "integer" }])
      end
    end

    # Without `only_numeric:` the string branch is exactly what keeps that position satisfiable.
    it "keeps the string branch when only_integer: stands alone" do
      action = build_axn { expects :n, type: [String, Integer], numericality: { only_integer: true } }

      expect(action.input_schema.dig(:properties, :n, :anyOf))
        .to eq([{ type: "string", pattern: "^[+-]?\\d+$", minLength: 1 }, { type: "integer" }])
      expect(action.call(n: "2")).to be_ok
    end

    # `Numeric` DOES admit an Integer, so its branch narrows rather than drops — the decision is the declared
    # token's, never the emitted type's, which is what reading `"number"` alone got wrong.
    it "narrows rather than drops a numeric branch whose token admits an Integer" do
      action = build_axn { expects :n, type: [String, Numeric], numericality: { only_integer: true } }

      expect(action.input_schema.dig(:properties, :n, :anyOf))
        .to eq([{ type: "string", pattern: "^[+-]?\\d+$", minLength: 1 }, { type: "integer" }])
      expect(action.call(n: 2)).to be_ok
      expect(action.call(n: "2")).to be_ok
      expect(action.call(n: "abc")).not_to be_ok
    end

    # ActiveModel resolves `only_integer:` per call against the record, so a Proc/Symbol token narrows NOTHING
    # statically: when it comes back false the validator skips the integer check entirely and every non-integer
    # the other options admit is still accepted. Reflection may not run it, so the narrowing stands down in both
    # directions — the same refusal a Symbol/Proc numeric bound already gets.
    describe "a per-call only_integer: token, which proves nothing about any single call" do
      it "leaves a union unnarrowed rather than rejecting the Float the position accepts" do
        action = build_axn do
          exposes :n, type: [Integer, Float], numericality: { only_integer: -> { false } }
          def call = expose(:n, 1.5)
        end
        result = action.call

        expect(result).to be_ok
        expect(action.output_schema.dig(:properties, :n, :anyOf)).to eq([{ type: "integer" }, { type: "number" }])
      end

      it "reads a Symbol token the same way" do
        action = build_axn do
          exposes :n, type: [Integer, Float], numericality: { only_integer: :whole_only? }
          def call = expose(:n, 1.5)
          def whole_only? = false
        end
        result = action.call

        expect(result).to be_ok
        expect(action.output_schema.dig(:properties, :n, :anyOf)).to eq([{ type: "integer" }, { type: "number" }])
      end

      # The emptied-node contract is earned by a STATIC narrowing. Under a per-call token the Float branch is
      # reachable, so emptying it advertised that nothing is acceptable at a position that took `1.5`.
      it "does not empty a Float node the validator still admits" do
        action = build_axn do
          exposes :n, type: Float, numericality: { only_integer: -> { false } }
          def call = expose(:n, 1.5)
        end
        result = action.call

        expect(result).to be_ok
        expect(action.output_schema[:properties][:n]).to eq(type: "number")
      end

      # The string branch's `pattern` is ActiveModel's own integer test translated — and with the check skipped
      # the validator merely parses the number, so `"1.5"` passes where the emitted pattern rejects it.
      it "omits the integer-literal pattern a string branch would otherwise carry" do
        action = build_axn do
          exposes :n, type: String, numericality: { only_integer: -> { false } }
          def call = expose(:n, "1.5")
        end
        result = action.call

        expect(result).to be_ok
        expect(Axn::Extensions::Serialization.render(result)["n"]).to eq("1.5")
        expect(action.output_schema[:properties][:n]).not_to have_key(:pattern)
      end

      it "still narrows on a static token, which is what the per-call one is measured against" do
        action = build_axn do
          exposes :n, type: [Integer, Float], numericality: { only_integer: true }
          def call = expose(:n, 2)
        end

        expect(action.call).to be_ok
        expect(action.output_schema[:properties][:n]).to eq(type: "integer")
      end
    end

    # A `length:` asks the same question a `format:` does one paragraph down, and had the same answer missing:
    # ActiveModel measures the VALUE's own `#length` while `minLength`/`maxLength` measure the serialized string.
    describe "an outbound length: whose subject is not the string the wire carries" do
      it "is the divergence itself: a Time's #to_s is longer than its serialized form" do
        moment = Time.utc(2026, 8, 25, 12)

        expect(moment.to_s.length).to eq(23)
        expect(Axn::Internal::Reflection::Values.serialize_value(moment).length).to eq(20)
      end

      it "stands the size down on output for a Time field" do
        moment = Time.utc(2026, 8, 25, 12)
        action = build_axn do
          exposes :t, type: Time, length: { is: 23 }
          define_method(:call) { expose(:t, moment) }
        end
        result = action.call

        expect(result).to be_ok
        expect(Axn::Extensions::Serialization.render(result)["t"]).to eq("2026-08-25T12:00:00Z")
        expect(action.output_schema[:properties][:t]).not_to have_key(:minLength)
        expect(action.output_schema[:properties][:t]).not_to have_key(:maxLength)
      end

      it "stands it down at a bag position, which asks the same question" do
        moment = Time.utc(2026, 8, 25, 12)
        action = build_axn do
          exposes :ts, type: Array, of: { klass: Time, length: { is: 23 } }
          define_method(:call) { expose(:ts, [moment]) }
        end
        result = action.call

        expect(result).to be_ok
        expect(action.output_schema.dig(:properties, :ts, :items)).not_to have_key(:minLength)
      end

      it "keeps it for a String, which IS the string it serializes to" do
        action = build_axn do
          exposes :s, type: String, length: { is: 3 }
          def call = expose(:s, "abc")
        end

        expect(action.call).to be_ok
        expect(action.output_schema[:properties][:s]).to include(minLength: 3, maxLength: 3)
      end

      # A COLLECTION size is exempt by construction: the count the runtime measured is the count the serializer
      # writes, whatever the elements themselves render as.
      it "keeps an Array's own size, whose count survives serialization" do
        moment = Time.utc(2026, 8, 25, 12)
        action = build_axn do
          exposes :ts, type: Array, of: Time, length: { is: 1 }
          define_method(:call) { expose(:ts, [moment]) }
        end

        expect(action.call).to be_ok
        expect(action.output_schema[:properties][:ts]).to include(minItems: 1, maxItems: 1)
      end

      it "still emits inbound, where the subject is the string that was sent" do
        action = build_axn { expects :t, type: Time, length: { is: 23 } }

        expect(action.input_schema[:properties][:t]).to include(minLength: 23, maxLength: 23)
      end
    end

    # `format:` is checked by ActiveModel against `value.to_s`, and on OUTPUT that is not always the string the
    # wire carries: the VALUE serializer renders a Time as `iso8601`. The pattern the runtime measured against
    # "2026-08-25 12:00:00 UTC" would be measured against "2026-08-25T12:00:00Z" and reject the action's output.
    describe "an outbound pattern whose subject is not the string the wire carries" do
      it "is the divergence itself: a Time's #to_s is not its serialized form" do
        moment = Time.utc(2026, 8, 25, 12)

        expect(moment.to_s).to eq("2026-08-25 12:00:00 UTC")
        expect(Axn::Internal::Reflection::Values.serialize_value(moment)).to eq("2026-08-25T12:00:00Z")
      end

      it "stands the pattern down on output for a Time position" do
        moment = Time.utc(2026, 8, 25, 12)
        action = build_axn do
          exposes :f, type: Time, format: { with: / / }
          define_method(:call) { expose(:f, moment) }
        end
        result = action.call

        expect(result).to be_ok
        expect(Axn::Extensions::Serialization.render(result)["f"]).to eq("2026-08-25T12:00:00Z")
        expect(action.output_schema[:properties][:f]).not_to have_key(:pattern)
      end

      it "keeps it for a String, which IS the string it serializes to" do
        action = build_axn do
          exposes :f, type: String, format: { with: /\Aab\z/ }
          def call = expose(:f, "ab")
        end

        expect(action.call).to be_ok
        expect(action.output_schema.dig(:properties, :f, :pattern)).to eq("^ab$")
      end

      # Inbound the subject really is the string that was sent, so nothing stands down there.
      it "still emits the pattern inbound for that same Time position" do
        prop = prop_for(:f) { expects :f, type: Time, format: { with: / / } }

        expect(prop[:pattern]).to eq(" ")
      end

      # A KEY is exempt: `canonical_wire_key` dispatches `to_s`, which is the subject the validator used.
      it "keeps a keys-axis pattern, whose subject the key serializer shares" do
        action = build_axn do
          exposes :m, type: Hash, of: { keys: { klass: String, format: { with: /\A[a-z]+\z/ } }, values: Integer }
          def call = expose(:m, { "ab" => 1 })
        end

        expect(action.call).to be_ok
        expect(action.output_schema.dig(:properties, :m, :propertyNames)).to eq(pattern: "^[a-z]+$")
      end
    end

    # Every Numeric but Integer and Float reaches the wire through `Float()`, which ROUNDS — so a bound the Ruby
    # value satisfies can be violated by the number actually serialized.
    describe "an outbound bound across a lossy numeric serialization" do
      it "stands down for a BigDecimal position, whose wire value rounds onto the bound" do
        value = BigDecimal("0.099999999999999999")
        action = build_axn do
          exposes :f, type: BigDecimal, comparison: { less_than: 0.1 }
          define_method(:call) { expose(:f, value) }
        end
        result = action.call

        expect(result).to be_ok
        expect(Axn::Extensions::Serialization.render(result)["f"]).to eq(0.1)
        expect(action.output_schema[:properties][:f]).not_to have_key(:exclusiveMaximum)
      end

      it "keeps it for Integer and Float, which serialize exactly" do
        action = build_axn do
          exposes :i, type: Integer, numericality: { less_than: 10 }
          exposes :f, type: Float, numericality: { less_than: 10 }
          def call = expose(i: 5, f: 5.5)
        end

        expect(action.call).to be_ok
        expect(action.output_schema.dig(:properties, :i, :exclusiveMaximum)).to eq(10)
        expect(action.output_schema.dig(:properties, :f, :exclusiveMaximum)).to eq(10)
      end

      # Inbound a JSON number arrives as an Integer or Float already, so the bound is emitted regardless.
      it "still emits the bound inbound for that same BigDecimal position" do
        prop = prop_for(:f) { expects :f, type: BigDecimal, comparison: { less_than: 0.1 } }

        expect(prop[:exclusiveMaximum]).to eq(0.1)
      end
    end

    # Both patterns are enforced at runtime and a node has one `pattern` slot, so the declared `format:` had been
    # overwriting the one `only_integer:` installs — and the node then advertised a value the integer test
    # rejects. `allOf` is JSON Schema's spelling for the conjunction, and it is free at a property: the
    # conditional `allOf` this emitter writes lives at the schema ROOT.
    it "composes a declared format: with the integer pattern instead of replacing it" do
      action = build_axn do
        expects :n, type: String, numericality: { only_integer: true }, format: { with: /\A[0-9a-z]+\z/ }
      end
      prop = action.input_schema[:properties][:n]

      expect(prop).not_to have_key(:pattern)
      expect(prop[:allOf]).to eq([{ pattern: "^[+-]?\\d+$" }, { pattern: "^[0-9a-z]+$" }])
      expect(action.call(n: "2")).to be_ok
      expect(action.call(n: "abc")).not_to be_ok
      expect(action.call(n: "2a")).not_to be_ok
    end

    # Either alone still takes the plain slot — the composition is reached only when two patterns actually meet.
    it "leaves a lone pattern in its own slot" do
      formatted = prop_for(:n) { expects :n, type: String, format: { with: /\A[0-9a-z]+\z/ } }
      integral = prop_for(:n) { expects :n, type: String, numericality: { only_integer: true } }

      expect(formatted[:pattern]).to eq("^[0-9a-z]+$")
      expect(formatted).not_to have_key(:allOf)
      expect(integral[:pattern]).to eq("^[+-]?\\d+$")
      expect(integral).not_to have_key(:allOf)
    end

    # A union leaves the node's own `type:` unset, so a pattern written at the node sat on nothing and a union
    # `format:` reflected nowhere at all — the string branch advertised values the validator rejects. It follows
    # the branches now, exactly as a numeric bound already did.
    it "writes a format: into the string branch of a union" do
      action = build_axn { expects :n, type: [String, Integer], format: { with: /\A[0-9a-z]+\z/ } }

      expect(action.input_schema.dig(:properties, :n, :anyOf))
        .to eq([{ type: "string", minLength: 1, pattern: "^[0-9a-z]+$" }, { type: "integer" }])
      expect(action.call(n: "ABC")).not_to be_ok
      expect(action.call(n: "abc")).to be_ok
      expect(action.call(n: 5)).to be_ok
    end

    # The pattern is derived from the validator that actually runs rather than restated beside it.
    it "emits ActiveModel's own integer test, translated" do
      prop = prop_for(:n) { expects :n, type: String, numericality: { only_integer: true } }

      expect(prop[:pattern])
        .to eq(Axn::Internal::Reflection::Pattern.ecma_source(
                 Axn::Validation::Base.integer_literal_regexp, for_output: false
               ))
    end

    # A pattern the TYPE resolution installed has to survive a union collapsing to one branch — the same node
    # reached by two paths must not say two different things.
    it "keeps the pattern when the union collapses to a single branch" do
      collapsed = prop_for(:n) { expects :n, type: [String, Float], numericality: { only_integer: true } }
      union = prop_for(:n) { expects :n, type: [String, Numeric], numericality: { only_integer: true } }

      expect(collapsed[:pattern]).to eq(union[:anyOf].first[:pattern])
    end

    # Deduping is a CONSEQUENCE of the narrowing converging two branches, never a tidy-up of its own: a union
    # that narrows nothing is emitted exactly as it was built, duplicate branches included.
    it "leaves a union that narrows nothing exactly as built" do
      prop = prop_for(:a) { expects :a, type: Hash, of: { values: { klass: [Symbol, String] } } }

      expect(prop[:additionalProperties]).to eq(anyOf: [{ type: "string" }, { type: "string" }])
    end

    # The contents path builds its node from the class alone, so it has to reach the same narrowing rather than
    # carry a second reading of it.
    it "narrows a union at a bag position too" do
      action = build_axn { expects :f, type: Array, of: { klass: [Integer, Float], numericality: { only_integer: true } } }

      expect(action.input_schema.dig(:properties, :f, :items)).to eq(type: "integer")
      expect(action.call(f: [1.5])).not_to be_ok
      expect(action.call(f: [2])).to be_ok
    end

    describe "stand-downs" do
      it "emits nothing for other_than, an inverted operator with no keyword" do
        expect(prop_for { expects :n, type: Integer, numericality: { other_than: 5 } })
          .not_to have_key(:const)
      end

      it "emits nothing for odd/even, a parity check with no keyword" do
        prop = prop_for { expects :n, type: Integer, numericality: { odd: true } }

        expect(prop).not_to have_key(:minimum)
        expect(prop).not_to have_key(:multipleOf)
      end

      # ActiveModel resolves a Symbol or Proc bound per call against the record, so no fixed number expresses
      # it — the same stand-down a Symbol `length:` bound already gets.
      it "emits nothing for a Symbol bound" do
        expect(prop_for { expects :n, type: Integer, numericality: { greater_than: :floor } })
          .not_to have_key(:exclusiveMinimum)
      end

      it "emits nothing for a Proc bound" do
        expect(prop_for { expects :n, type: Integer, numericality: { greater_than: ->(_r) { 1 } } })
          .not_to have_key(:exclusiveMinimum)
      end

      it "emits nothing for an infinite bound, which no fixed number expresses" do
        expect(prop_for { expects :n, type: Integer, numericality: { less_than: Float::INFINITY } })
          .not_to have_key(:exclusiveMaximum)
      end

      # `comparison:` accepts any Comparable, so a bound may be a String or a Date. JSON Schema's numeric
      # bound keywords take a NUMBER, so emitting one there would produce an invalid document.
      it "emits nothing for a non-numeric comparison bound" do
        prop = prop_for { expects :n, type: String, comparison: { greater_than: "b" } }

        expect(prop).not_to have_key(:exclusiveMinimum)
        expect(prop).not_to have_key(:minimum)
      end

      it "emits nothing on a non-numeric emitted type" do
        expect(prop_for { expects :n, type: String, numericality: { greater_than: 0 } })
          .not_to have_key(:exclusiveMinimum)
      end

      it "emits nothing for a disabled entry" do
        expect(prop_for { expects :n, type: Integer, numericality: false, optional: true })
          .not_to have_key(:exclusiveMinimum)
      end
    end

    # A gated entry is counted as if its gate were open — the static-maximal policy every constraint in this
    # emitter follows, since a condition can only relax enforcement at runtime, never tighten it.
    it "emits a gated bound, static-maximally" do
      expect(prop_for { expects :n, type: Integer, numericality: { greater_than: 0, if: -> { false } } })
        .to include(exclusiveMinimum: 0)
    end

    it "agrees with the runtime on the same value" do
      action = build_axn { expects :n, type: Integer, numericality: { greater_than: 0, less_than: 10 } }

      expect(action.call(n: 5)).to be_ok
      expect(action.call(n: 0)).not_to be_ok
      expect(action.call(n: 10)).not_to be_ok
      expect(action.input_schema[:properties][:n])
        .to include(exclusiveMinimum: 0, exclusiveMaximum: 10)
    end
  end

  # `pattern` was emitted nowhere, so a declared `format:` was enforced at runtime and advertised nowhere.
  #
  # JSON Schema's `pattern` is an ECMA-262 source with NO flags available, so a faithful translation is only
  # sometimes possible — and the failure mode that matters is a FALSE EMIT, a pattern that means something
  # other than the Ruby regex it came from. Standing down costs nothing (it emits nothing, which is where this
  # started), so anything not provably translatable stands down. `Reflection::Pattern` owns that judgment.
  describe "pattern" do
    def prop_for(&declaration)
      build_axn(&declaration).input_schema[:properties][:s]
    end

    it "emits an already-ECMA-shaped source unchanged" do
      expect(prop_for { expects :s, type: String, format: { with: /[a-z]+/ } }).to include(pattern: "[a-z]+")
    end

    # `\A`/`\z` are Ruby-only. ECMA's `^`/`$` mean start/end of INPUT whenever no `m` flag is set, and a
    # `pattern` can never set one — so the translation is exact rather than approximate.
    it "translates \\A and \\z to the ECMA input anchors" do
      expect(prop_for { expects :s, type: String, format: { with: /\A[A-Z]{2}\z/ } })
        .to include(pattern: "^[A-Z]{2}$")
    end

    it "emits the bare Regexp form of format:" do
      expect(prop_for { expects :s, type: String, format: /\Aab\z/ }).to include(pattern: "^ab$")
    end

    # Ruby's `^`/`$` are ALWAYS line anchors; ECMA's, with no flag available, are input anchors. So the
    # emitted pattern matches a subset of what the runtime accepts — stricter, which is the documented and
    # licensed direction, rather than a divergence.
    # `multiline: true` is required for the declaration to RUN at all: ActiveModel's FormatValidator refuses a
    # `^`/`$` pattern without it ("using multiline anchors … may present a security risk"), so the bare spelling
    # raises on every call and is not a working narrowing to document.
    it "emits a Ruby line anchor as an input anchor, which is stricter" do
      action = build_axn { expects :s, type: String, format: { with: /^\d+$/, multiline: true } }

      expect(action.call(s: "123")).to be_ok
      expect(action.input_schema[:properties][:s]).to include(pattern: "^\\d+$")
    end

    it "notes that the bare ^/$ spelling ActiveModel refuses never reaches a call" do
      action = build_axn { expects :s, type: String, format: { with: /^\d+$/ } }

      expect(action.call(s: "123")).not_to be_ok
      expect(action.call(s: "123").exception).to be_a(ArgumentError)
    end

    it "agrees with the runtime on the same value" do
      action = build_axn { expects :s, type: String, format: { with: /\A[A-Z]{2}\z/ } }

      expect(action.call(s: "US")).to be_ok
      expect(action.call(s: "usa")).not_to be_ok
      expect(action.input_schema[:properties][:s]).to include(pattern: "^[A-Z]{2}$")
    end

    it "reaches a shape member's own format:" do
      action = build_axn do
        expects :rows, type: Array, of: Hash do
          field :sku, type: String, format: { with: /\A[A-Z]+\z/ }
        end
      end

      expect(action.input_schema.dig(:properties, :rows, :items, :properties, :sku))
        .to include(pattern: "^[A-Z]+$")
    end

    describe "stand-downs" do
      def stands_down(&declaration)
        expect(prop_for(&declaration)).not_to have_key(:pattern)
      end

      # Ruby sets FIXEDENCODING on ANY non-ASCII regex, so gating on `options.zero?` refused every accented
      # or non-Latin pattern — a plausible declaration, not an exotic one. That bit pins the regex's encoding
      # and says nothing about matching semantics, and a JSON Schema pattern is a Unicode string, so it
      # translates faithfully. `/n` (NOENCODING) is the one encoding flag that DOES change semantics — it
      # matches bytes rather than characters — and still stands down.
      it "emits a non-ASCII pattern, whose FIXEDENCODING bit is not a semantic flag" do
        prop = prop_for { expects :s, type: String, format: { with: /\A[é-ü]+\z/ } }

        expect(prop).to include(pattern: "^[é-ü]+$")
      end

      it "agrees with the runtime on a non-ASCII pattern" do
        action = build_axn { expects :s, type: String, format: { with: /\Aé+\z/ } }

        expect(action.call(s: "éé")).to be_ok
        expect(action.call(s: "ab")).not_to be_ok
        expect(action.input_schema[:properties][:s]).to include(pattern: "^é+$")
      end

      it "stands down on /n, the one encoding flag that changes matching semantics" do
        stands_down { expects :s, type: String, format: { with: Regexp.new("a", Regexp::NOENCODING) } }
      end

      it "stands down on a case-insensitive regex, which a pattern cannot express" do
        stands_down { expects :s, type: String, format: { with: /abc/i } }
      end

      it "stands down on Ruby's dotall flag, which ECMA spells differently" do
        stands_down { expects :s, type: String, format: { with: /a.b/m } }
      end

      it "stands down on extended mode, which changes what the source means" do
        stands_down { expects :s, type: String, format: { with: / a b /x } }
      end

      # Ruby's `\s` is the ASCII whitespace set; ECMA's also includes NBSP, the Unicode Zs category and the
      # line/paragraph separators. So an emitted `\s` accepts strings the runtime rejects — looser, the one
      # direction reflection may not err in. `\d`/`\w` are the SAME set in both dialects and stay.
      # Where the referenced group did not participate in the match, Ruby FAILS the backreference and ECMA
      # matches the EMPTY STRING — so `/\A(a|(b))\2c\z/` rejects "ac" in Ruby and `^(a|(b))\2c$` accepts it.
      # Proving participation means parsing the alternation, so they stand down.
      #
      # Note this divergence is invisible to a Ruby-side JSON Schema validator, which compiles `pattern` with
      # Ruby's own engine — so it is asserted from the specification, not from a differential run.
      # Ruby reads `\xHH` as a BYTE and ECMA as a CHARACTER, which diverges at and above 0x80 — and the
      # multi-byte spelling is both legal and reachable: `/\xC3\xA9/` matches the single character "é" in Ruby
      # while the same source as an ECMA pattern means the two characters "Ã©", so it would reject what the
      # runtime accepts AND accept what it rejects. Found by sweeping the allowlist rather than by a review.
      it "stands down on a hex escape, whose unit differs between the dialects" do
        stands_down { expects :s, type: String, format: { with: Regexp.new("\\xC3\\xA9") } }
      end

      it "stands down on an octal escape" do
        stands_down { expects :s, type: String, format: { with: Regexp.new("\\012") } }
      end

      # `\uHHHH` is the same codepoint in both dialects and stays. The braced `\u{…}` form is refused
      # separately, since ECMA needs the `u` flag for it.
      it "still emits a \\uHHHH escape, which agrees in both dialects" do
        expect(prop_for { expects :s, type: String, format: { with: Regexp.new("\\A\\u0041\\z") } })
          .to include(pattern: "^\\u0041$")
      end

      # A flagless ECMA pattern counts UTF-16 CODE UNITS where Ruby counts CHARACTERS — and which side that
      # favours DEPENDS ON THE QUANTIFIER, so it cannot be licensed on input as a narrowing:
      #
      #   ^.$     needs 1 unit, "😀" has 2  => ECMA rejects, Ruby accepts  (stricter)
      #   ^.{2}$  needs 2 units, "😀" has 2 => ECMA ACCEPTS, Ruby rejects  (LOOSER)
      #
      # Determining which applies means parsing the quantifier context, so anything able to match a character
      # outside the BMP stands down at BOTH positions.
      it "stands down on a counted dot, where ECMA is LOOSER than Ruby" do
        action = build_axn { expects :s, type: String, format: { with: /\A.{2}\z/ } }

        expect(action.call(s: "\u{1F600}")).not_to be_ok
        expect(action.input_schema[:properties][:s]).not_to have_key(:pattern)
      end

      it "stands down on a dot on input as well as output" do
        stands_down { expects :s, type: String, format: { with: /\A.\z/ } }
      end

      it "stands down on a complement escape on input" do
        stands_down { expects :s, type: String, format: { with: /\A\D{2}\z/ } }
      end

      it "stands down on a negated class on input" do
        stands_down { expects :s, type: String, format: { with: /\A[^a]{2}\z/ } }
      end

      # The line anchors are the one construct that stays input-licensed: `^`/`$` are ZERO-WIDTH assertions, so
      # no code units are consumed and no quantifier can reverse the direction — Ruby's line anchors match at a
      # strict superset of ECMA's input-anchor positions whatever surrounds them.
      it "still emits a line anchor on input, which no quantifier can reverse" do
        action = build_axn { expects :s, type: String, format: { with: /^\d+$/, multiline: true } }

        expect(action.input_schema[:properties][:s]).to include(pattern: "^\\d+$")
      end

      # On INPUT a narrowing is licensed — the document may admit fewer values than the runtime. On OUTPUT the
      # direction flips: the schema describes what the action PRODUCES, so a narrowing rejects values axn
      # successfully serialized. Only translations that are EXACT survive there, which is the same reasoning
      # `effective_validations` already applies to a self-gated entry on output.
      describe "on output, where a narrowing rejects what the action serializes" do
        it "stands down on a dot, whose ECMA reading excludes more than Ruby's" do
          action = build_axn do
            exposes :s, type: String, format: { with: /\A.\z/ }, allow_blank: true
            def call = expose(:s, "\r")
          end

          expect(action.call).to be_ok
          expect(action.output_schema[:properties][:s]).not_to have_key(:pattern)
        end

        it "stands down on a line anchor" do
          action = build_axn do
            exposes :s, type: String, format: { with: /^\d+$/, multiline: true }
            def call = expose(:s, "123")
          end

          expect(action.call).to be_ok
          expect(action.output_schema[:properties][:s]).not_to have_key(:pattern)
        end

        # A flagless ECMA pattern counts UTF-16 CODE UNITS where Ruby counts CHARACTERS, so anything that can
        # match a character outside the BMP is a narrowing outbound: Ruby sees one character in "😀" and ECMA
        # sees a surrogate pair. `\w`/`\d` are safe (ASCII-only, they never match one), and a BMP character
        # like "é" is safe (one code unit either way) — it is the COMPLEMENTS and the negated classes that
        # match astral input, plus a literal astral character in the source.
        it "stands down on a complement escape, which matches astral input" do
          action = build_axn do
            exposes :s, type: String, format: { with: /\A\D\z/ }
            define_method(:call) { expose(:s, "\u{1F600}") }
          end

          expect(action.call).to be_ok
          expect(action.output_schema[:properties][:s]).not_to have_key(:pattern)
        end

        it "stands down on \\W for the same reason" do
          action = build_axn do
            exposes :s, type: String, format: { with: /\A\W\z/ }
            define_method(:call) { expose(:s, "\u{1F600}") }
          end

          expect(action.call).to be_ok
          expect(action.output_schema[:properties][:s]).not_to have_key(:pattern)
        end

        it "stands down on a negated character class, which has the same reach" do
          action = build_axn do
            exposes :s, type: String, format: { with: /\A[^0-9]\z/ }
            define_method(:call) { expose(:s, "\u{1F600}") }
          end

          expect(action.call).to be_ok
          expect(action.output_schema[:properties][:s]).not_to have_key(:pattern)
        end

        it "stands down on a literal astral character in the source" do
          action = build_axn do
            exposes :s, type: String, format: { with: Regexp.new("\\A[\u{1F600}]\\z") }
            define_method(:call) { expose(:s, "\u{1F600}") }
          end

          expect(action.call).to be_ok
          expect(action.output_schema[:properties][:s]).not_to have_key(:pattern)
        end

        # The controls: an ASCII-only pattern, and a BMP non-ASCII one, both still emit outbound.
        it "still emits an ASCII-only pattern" do
          action = build_axn do
            exposes :s, type: String, format: { with: /\A\d+\z/ }
            def call = expose(:s, "123")
          end

          expect(action.output_schema[:properties][:s]).to include(pattern: "^\\d+$")
        end

        it "still emits a BMP non-ASCII pattern, which needs no surrogate pair" do
          action = build_axn do
            exposes :s, type: String, format: { with: /\Aé+\z/ }
            def call = expose(:s, "éé")
          end

          expect(action.output_schema[:properties][:s]).to include(pattern: "^é+$")
        end

        it "stands down on the complements on input too, since a quantifier can reverse the direction" do
          expect(prop_for { expects :s, type: String, format: { with: /\A\D\z/ } }).not_to have_key(:pattern)
        end

        # An EXACT translation still emits on output — the stand-down is about narrowing, not about output.
        it "still emits an exactly-translated pattern" do
          action = build_axn do
            exposes :s, type: String, format: { with: /\A[A-Z]{2}\z/ }
            def call = expose(:s, "US")
          end

          expect(action.call).to be_ok
          expect(action.output_schema[:properties][:s]).to include(pattern: "^[A-Z]{2}$")
        end

        it "still emits the LINE ANCHOR narrowing on input, the one a quantifier cannot reverse" do
          action = build_axn { expects :s, type: String, format: { with: /^\d+$/, multiline: true } }

          expect(action.input_schema[:properties][:s]).to include(pattern: "^\\d+$")
        end
      end

      it "stands down on a numeric backreference" do
        stands_down { expects :s, type: String, format: { with: /\A(a|(b))\2c\z/ } }
      end

      # `input_schema` must not RAISE. The guard patterns are UTF-8, so matching them against a source in an
      # incompatible encoding raises `Encoding::CompatibilityError` — which breaks reflection outright rather
      # than degrading it, the one failure mode a stand-down design must not have.
      it "stands down on a non-UTF-8 source instead of raising" do
        euc = Regexp.new("あ".encode("EUC-JP"))
        action = build_axn { expects :s, type: String, format: { with: euc } }

        expect { action.input_schema }.not_to raise_error
        expect(action.input_schema[:properties][:s]).not_to have_key(:pattern)
      end

      it "still emits an ASCII-only source whose Regexp declares another encoding" do
        ascii = Regexp.new("\\Aab\\z".encode("EUC-JP"))
        action = build_axn { expects :s, type: String, format: { with: ascii } }

        expect(action.input_schema[:properties][:s]).to include(pattern: "^ab$")
      end

      # A difference INSIDE Ruby that is easy to miss: Ruby's `\w` is ASCII-only but its `\b` is Unicode-aware,
      # while ECMA's unflagged `\b` goes through its ASCII `\w`. So Ruby REJECTS "é" here and the emitted
      # `^\Bé\B$` would accept it.
      it "stands down on a word-boundary escape, which Ruby reads Unicode-aware" do
        action = build_axn { expects :s, type: String, format: { with: /\A\Bé\B\z/ } }

        expect(action.call(s: "é")).not_to be_ok
        expect(action.input_schema[:properties][:s]).not_to have_key(:pattern)
      end

      it "stands down on \\b for the same reason" do
        stands_down { expects :s, type: String, format: { with: /\A\bab\z/ } }
      end

      # The escapes that STAY are the ones measured ASCII-only on both sides, which is what makes them safe.
      it "still emits \\d and \\w, which are ASCII-only in both dialects" do
        expect(prop_for { expects :s, type: String, format: { with: /\A\d\w+\z/ } })
          .to include(pattern: "^\\d\\w+$")
      end

      it "stands down on \\s, whose character set differs between the dialects" do
        stands_down { expects :s, type: String, format: { with: /\A\s+\z/ } }
      end

      it "stands down on \\S for the same reason" do
        stands_down { expects :s, type: String, format: { with: /\A\S+\z/ } }
      end

      it "still emits \\d and \\w, which agree in both dialects" do
        expect(prop_for { expects :s, type: String, format: { with: /\A\d\w+\z/ } })
          .to include(pattern: "^\\d\\w+$")
      end

      it "stands down on \\Z, which permits a trailing newline where $ does not" do
        stands_down { expects :s, type: String, format: { with: /\Aa\Z/ } }
      end

      it "stands down on \\h, a Ruby-only escape" do
        stands_down { expects :s, type: String, format: { with: /\A\h+\z/ } }
      end

      it "stands down on a POSIX bracket class" do
        stands_down { expects :s, type: String, format: { with: /[[:alpha:]]+/ } }
      end

      it "stands down on \\p, which ECMA needs a u flag for" do
        stands_down { expects :s, type: String, format: { with: /\p{Alpha}+/ } }
      end

      it "stands down on an atomic group" do
        stands_down { expects :s, type: String, format: { with: /(?>ab)c/ } }
      end

      it "stands down on an inline flag group" do
        stands_down { expects :s, type: String, format: { with: /(?i)abc/ } }
      end

      it "stands down on a named capture" do
        stands_down { expects :s, type: String, format: { with: /(?<y>\d+)/ } }
      end

      it "stands down on a possessive quantifier" do
        stands_down { expects :s, type: String, format: { with: /a++b/ } }
      end

      # Ruby reads a `[` inside a character class as a nested class UNION (`[a[bc]]` is {a,b,c}); ECMA reads
      # `[a[bc]` as a class containing `[` and then a literal `]`, so the emitted pattern accepts "[" which the
      # runtime rejects. Found by sweeping the construct list rather than by a review — the escape half of this
      # design is an allowlist, and the construct half is not, which is where these keep coming from.
      it "stands down on a nested character-class union" do
        stands_down { expects :s, type: String, format: { with: /\A[a[bc]]+\z/ } }
      end

      it "stands down on a nested union inside a negated class" do
        stands_down { expects :s, type: String, format: { with: /\A[^a[b]]+\z/ } }
      end

      # The controls: two separate classes, and an ESCAPED bracket inside one, must keep emitting.
      it "still emits two separate character classes" do
        expect(prop_for { expects :s, type: String, format: { with: /\A[a]b[c]\z/ } })
          .to include(pattern: "^[a]b[c]$")
      end

      it "still emits an escaped bracket inside a class" do
        expect(prop_for { expects :s, type: String, format: { with: /\A[\[a]+\z/ } })
          .to include(pattern: "^[\\[a]+$")
      end

      it "stands down on a class intersection" do
        stands_down { expects :s, type: String, format: { with: /[\w&&[^a]]+/ } }
      end

      it "stands down on a braced escape ECMA needs a u flag for" do
        stands_down { expects :s, type: String, format: { with: /\u{1F600}/ } }
      end

      # A `without:` pattern's honest spelling is `not: { pattern: ... }`, and `not:` is a single slot that
      # `reject_null!` already writes into — two writers, one key, and the second silently clobbers the first.
      # Booked as unemitted alongside `exclusion:`, which has the same shape.
      it "stands down on format: { without: }" do
        stands_down { expects :s, type: String, format: { without: /\d/ } }
      end

      it "stands down on a pattern ActiveModel resolves per call" do
        stands_down { expects :s, type: String, format: { with: ->(_r) { /a/ } } }
      end

      it "stands down on a non-string emitted type" do
        expect(prop_for { expects :s, type: Integer, format: { with: /\A\d+\z/ } }).not_to have_key(:pattern)
      end

      it "stands down on a disabled entry" do
        stands_down { expects :s, type: String, format: false, optional: true }
      end

      # `{b}` is not a well-formed quantifier, so Ruby reads it as three literal characters. A strict ECMA
      # engine may instead treat it as a parse error, which would make a consumer's validator throw on a
      # document axn published — so the brace stands down rather than risk it.
      it "stands down on a brace that is not a quantifier" do
        stands_down { expects :s, type: String, format: { with: /\Aa{b}c\z/ } }
      end

      # `\A` translates to `^` only as a leading anchor. Inside an alternation its position would have to be
      # tracked to translate safely — and inside a character class `[\A]` would become `[^]`, a negated empty
      # class matching nothing — so anywhere but the ends, it stands down.
      it "stands down on \\A anywhere but the start" do
        stands_down { expects :s, type: String, format: { with: /(\Aa|b)/ } }
      end

      it "stands down on \\z anywhere but the end" do
        stands_down { expects :s, type: String, format: { with: /a\z|b/ } }
      end
    end

    # Lookahead and lookbehind are shared with ECMA, so they translate rather than stand down — the allowlist
    # is not "punctuation only".
    # Written without a `.`, which stands down on its own account (code-unit sensitivity) — the claim here is
    # that a LOOKAHEAD survives translation, and a dot inside it would test something else.
    it "keeps a lookahead" do
      expect(prop_for { expects :s, type: String, format: { with: /\A(?=\w*\d)\w+\z/ } })
        .to include(pattern: "^(?=\\w*\\d)\\w+$")
    end

    it "keeps a non-capturing group and an escaped literal" do
      expect(prop_for { expects :s, type: String, format: { with: /\A(?:a|b)\.c\z/ } })
        .to include(pattern: "^(?:a|b)\\.c$")
    end
  end

  # A bag's value validators land on the node the bag describes — `items` for an Array's element,
  # `additionalProperties` for a map's values, `propertyNames` for its keys — through the SAME projector that
  # serves a named position, so a keyword cannot reach a field and be forgotten one rung down.
  describe "value constraints at an of: bag position" do
    def prop_for(field, &declaration)
      build_axn(&declaration).input_schema[:properties][field]
    end

    it "emits pattern into items" do
      prop = prop_for(:codes) { expects :codes, type: Array, of: { klass: String, format: { with: /\A[A-Z]{2}\z/ } } }

      expect(prop[:items]).to include(type: "string", pattern: "^[A-Z]{2}$")
    end

    it "emits enum into items" do
      prop = prop_for(:tags) { expects :tags, type: Array, of: { klass: String, inclusion: { in: %w[a b] } } }

      expect(prop[:items]).to include(enum: %w[a b])
    end

    # The element's OWN length, so the string keyword — not the array's size, which is the field's `length:`.
    it "emits the element's own size bound into items, not the array's" do
      prop = prop_for(:codes) { expects :codes, type: Array, of: { klass: String, length: { maximum: 2 } } }

      expect(prop[:items]).to include(maxLength: 2)
      expect(prop).not_to have_key(:maxItems)
    end

    it "emits a numeric bound into items" do
      prop = prop_for(:qtys) { expects :qtys, type: Array, of: { klass: Integer, numericality: { greater_than: 0 } } }

      expect(prop[:items]).to include(type: "integer", exclusiveMinimum: 0)
    end

    it "emits into additionalProperties for a map's values axis" do
      prop = prop_for(:counts) { expects :counts, type: Hash, of: { values: { klass: Integer, numericality: { greater_than: 0 } } } }

      expect(prop[:additionalProperties]).to include(type: "integer", exclusiveMinimum: 0)
    end

    it "emits at the nested node a nested bag names" do
      prop = prop_for(:m) { expects :m, type: Array, of: { klass: Array, of: { klass: String, format: { with: /\Ax/ } } } }

      expect(prop.dig(:items, :items)).to include(type: "string", pattern: "^x")
    end

    it "agrees with the runtime on the same value" do
      action = build_axn { expects :codes, type: Array, of: { klass: String, format: { with: /\A[A-Z]{2}\z/ } } }

      expect(action.call(codes: %w[US])).to be_ok
      expect(action.call(codes: %w[usa])).not_to be_ok
      expect(action.input_schema.dig(:properties, :codes, :items)).to include(pattern: "^[A-Z]{2}$")
    end

    # A validator-only bag names no class, and the node was seeded from `klass:` alone — so it stayed empty,
    # every keyword that keys off a type declined to emit, and the parent dropped `items` entirely. The FIELD
    # path infers a type from the validators in exactly this case (`json_type_for`), so the fix is to call it
    # rather than to write a second inference beside it.
    describe "a validator-only bag, which names no class" do
      it "infers a numeric type and emits the bound" do
        action = build_axn { expects :f, type: Array, of: { numericality: { greater_than: 0 } } }

        expect(action.call(f: [1])).to be_ok
        expect(action.call(f: [-1])).not_to be_ok
        expect(action.input_schema.dig(:properties, :f, :items)).to include(type: "number", exclusiveMinimum: 0)
      end

      it "narrows to integer under only_integer, as a field does" do
        prop = prop_for(:f) { expects :f, type: Array, of: { numericality: { only_integer: true } } }

        expect(prop[:items]).to include(type: "integer")
      end

      it "infers a type from an inclusion set too, matching the field path" do
        prop = prop_for(:f) { expects :f, type: Array, of: { inclusion: { in: %w[a b] } } }

        expect(prop[:items]).to include(type: "string", enum: %w[a b])
      end

      it "keeps the declared class when the bag names one" do
        prop = prop_for(:f) { expects :f, type: Array, of: { klass: String, numericality: { greater_than: 0 } } }

        # `klass:` wins, exactly as `type:` wins at a field — and a numeric bound then stands down on a
        # non-numeric emitted type.
        expect(prop[:items]).to include(type: "string")
        expect(prop[:items]).not_to have_key(:exclusiveMinimum)
      end

      it "reaches a map axis too" do
        prop = prop_for(:m) { expects :m, type: Hash, of: { values: { numericality: { greater_than: 0 } } } }

        expect(prop[:additionalProperties]).to include(type: "number", exclusiveMinimum: 0)
      end

      # ActiveModel's `numericality:` accepts a numeric STRING unless `only_numeric: true` is given, so an
      # action may expose "1" successfully and serialize it as a JSON string. On OUTPUT an inferred numeric type
      # therefore rejects the action's own output; on input it is merely stricter, which is licensed.
      #
      # The gate lives in `json_type_for`, so it covers the FIELD path too — where this was a pre-existing bug
      # that the positional inference above would otherwise have propagated.
      describe "a numericality-inferred type on output, where a numeric string may be exposed" do
        it "stands down at a bag position" do
          action = build_axn do
            exposes :codes, type: Array, of: { numericality: { greater_than: 0 } }
            def call = expose(:codes, ["1"])
          end

          expect(action.call).to be_ok
          expect(action.output_schema.dig(:properties, :codes)).not_to have_key(:items)
        end

        it "stands down at a field, which had the same bug" do
          action = build_axn do
            exposes :n, numericality: { greater_than: 0 }
            def call = expose(:n, "1")
          end

          expect(action.call).to be_ok
          expect(action.output_schema[:properties][:n]).to eq({})
        end

        # `only_numeric:` proves the value is a NUMERIC, which is not the same as a JSON number, so on its own
        # it infers nothing on output: `Complex(1, 2)` is a Numeric that serializes as the STRING "1+2i", and an
        # inferred `"number"` rejected output the action had produced successfully.
        it "stands down under only_numeric: alone, which does not prove a JSON number" do
          action = build_axn do
            exposes :n, numericality: { greater_than: 0, only_numeric: true }
            def call = expose(:n, 1)
          end

          expect(action.call).to be_ok
          expect(action.output_schema[:properties][:n]).to eq({})
        end

        it "is why: a Numeric that satisfies the validator serializes as a string" do
          action = build_axn do
            exposes :n, numericality: { only_numeric: true }
            def call = expose(:n, Complex(1, 2))
          end
          result = action.call

          expect(result).to be_ok
          expect(Axn::Extensions::Serialization.render(result)["n"]).to eq("1+2i")
          expect(action.output_schema[:properties][:n]).to eq({})
        end

        it "reaches a bag position the same way" do
          action = build_axn do
            exposes :ns, type: Array, of: { numericality: { only_numeric: true } }
            def call = expose(:ns, [Complex(1, 2)])
          end
          result = action.call

          expect(result).to be_ok
          expect(Axn::Extensions::Serialization.render(result)["ns"]).to eq(["1+2i"])
          expect(action.output_schema[:properties][:ns]).not_to have_key(:items)
        end

        # Together the two options pin the value to an Integer: among Numerics only an Integer's `#to_s` is an
        # integer literal, which is the test `only_integer:` applies. So the pair infers, and infers "integer".
        it "infers where only_numeric: and only_integer: together pin an Integer" do
          action = build_axn do
            exposes :n, numericality: { only_numeric: true, only_integer: true }
            def call = expose(:n, 7)
          end

          expect(action.call).to be_ok
          expect(action.output_schema[:properties][:n]).to eq(type: "integer")
        end

        it "stands down again where that only_integer: is resolved per call" do
          action = build_axn do
            exposes :n, numericality: { only_numeric: true, only_integer: -> { false } }
            def call = expose(:n, 1.5)
          end
          result = action.call

          expect(result).to be_ok
          expect(Axn::Extensions::Serialization.render(result)["n"]).to eq(1.5)
          expect(action.output_schema[:properties][:n]).to eq({})
        end

        # The `inclusion:` branch of the same inference had the identical defect, and it is gated on the same
        # predicate the outbound `enum` already uses rather than a second reading of it. `Integer#==` falls back
        # to `other == self`, so a value object comparing equal to a member passes the validator and serializes
        # as its own string — which is why the set may not name a type unless the position pins the class.
        describe "an inclusion-inferred type on output, where a member's equality reaches another class" do
          # A plain value object, not a hostile one: comparing equal to a Numeric is ordinary for a money type.
          cents = Class.new do
            attr_reader :n

            def initialize(n) = @n = n
            def ==(other) = n == (other.is_a?(self.class) ? other.n : other)
            def to_s = "$#{n}"
          end

          # The exact rendering of an opaque object is not the point and is not asserted: it depends on which
          # JSON core extensions are loaded (ActiveSupport's `Object#as_json` reports `instance_values`, so this
          # renders as a Hash in a full run and as its `#to_s` without it). What matters either way is that it
          # is NOT a JSON integer, so an inferred `"integer"` rejects it.
          it "is the divergence itself: an Integer member matches a foreign class" do
            expect([1].include?(cents.new(1))).to be(true)
            expect(Axn::Internal::Reflection::Values.serialize_value(cents.new(1))).not_to be_a(Integer)
          end

          it "stands the inferred type down for a bare numeric set" do
            action = build_axn do
              exposes :n, inclusion: { in: [1] }
              define_method(:call) { expose(:n, cents.new(1)) }
            end
            result = action.call

            expect(result).to be_ok
            expect(Axn::Extensions::Serialization.render(result)["n"]).not_to be_a(Integer)
            expect(action.output_schema[:properties][:n]).to eq({})
          end

          it "still infers where a declared type: pins the numeric class" do
            action = build_axn do
              exposes :n, type: Integer, inclusion: { in: [1, 2] }
              def call = expose(:n, 1)
            end

            expect(action.call).to be_ok
            expect(action.output_schema[:properties][:n]).to include(type: "integer", enum: [1, 2])
          end

          # A String member cannot be `==` to a foreign class — `String#==` returns false rather than deferring —
          # so the set names its type outbound exactly as before.
          it "still infers from a String set, whose equality cannot reach another class" do
            action = build_axn do
              exposes :n, inclusion: { in: %w[a b] }
              def call = expose(:n, "a")
            end

            expect(action.call).to be_ok
            expect(action.output_schema[:properties][:n]).to include(type: "string", enum: %w[a b])
          end

          it "still infers on INPUT, where a narrowing is licensed" do
            action = build_axn { expects :n, inclusion: { in: [1, 2] } }

            expect(action.input_schema[:properties][:n]).to include(type: "integer", enum: [1, 2])
          end
        end

        # The BOUND stands down under `only_numeric:` for a second, independent reason: a Numeric may be a
        # BigDecimal, and every Numeric but Integer and Float reaches the wire through `Float()`, which rounds.
        # Measured — `BigDecimal("1e-400")` satisfies `greater_than: 0`, serializes as `0.0`, and an emitted
        # `exclusiveMinimum: 0` rejects the action's own output.
        it "keeps the bound down: a Numeric the wire rounds satisfies it and the emitted node would not" do
          action = build_axn do
            exposes :n, numericality: { greater_than: 0, only_numeric: true }
            def call = expose(:n, BigDecimal("1e-400"))
          end
          result = action.call

          expect(result).to be_ok
          expect(Axn::Extensions::Serialization.render(result)["n"]).to eq(0.0)
          expect(action.output_schema[:properties][:n]).not_to have_key(:exclusiveMinimum)
        end

        # `const` names exactly one value, so it cannot say "this number OR null" — and a nullable position
        # really does admit nil. Measured: the action exposes nil successfully while `const: 1` refused it,
        # even beside a `"null"` in the node's own `type:`.
        it "spells a nullable equal_to: as an enum, which can carry the null" do
          action = build_axn do
            exposes :n, type: Integer, comparison: { equal_to: 1 }, optional: true
            def call = expose(:n, nil)
          end

          expect(action.call).to be_ok
          expect(action.output_schema[:properties][:n]).to include(enum: [1, nil])
          expect(action.output_schema[:properties][:n]).not_to have_key(:const)
        end

        it "keeps const where the position admits no nil" do
          action = build_axn do
            exposes :n, type: Integer, comparison: { equal_to: 1 }
            def call = expose(:n, 1)
          end

          expect(action.call).to be_ok
          expect(action.output_schema[:properties][:n]).to include(const: 1)
        end

        it "still emits when a declared type: requires a real numeric" do
          action = build_axn do
            exposes :n, type: Integer, numericality: { greater_than: 0 }
            def call = expose(:n, 1)
          end

          expect(action.output_schema[:properties][:n]).to include(type: "integer", exclusiveMinimum: 0)
        end

        it "still infers on INPUT, where a narrowing is licensed" do
          prop = prop_for(:f) { expects :f, type: Array, of: { numericality: { greater_than: 0 } } }

          expect(prop[:items]).to include(type: "number", exclusiveMinimum: 0)
        end

        # A bare numeric `inclusion:` set infers NOTHING on output. The reading this used to assert — that
        # `include?` compares by membership so "the exposed value really is an Integer" — does not hold:
        # `include?` compares by `==`, and `Integer#==` falls back to `other == self`, so a value object
        # comparing equal to a member passes and serializes as something that is not a JSON integer. The set
        # names a type outbound only where the position pins the class, which is the gate the `enum` beside it
        # already used.
        it "stands an inclusion-inferred type down on output for a bare numeric set" do
          action = build_axn do
            exposes :n, inclusion: { in: [1, 2] }
            def call = expose(:n, 1)
          end

          expect(action.call).to be_ok
          expect(action.output_schema[:properties][:n]).to eq({})
        end
      end

      # `format:`/`length:` alone infer nothing, at a bag position AND at a field — there is no type to infer
      # from a pattern or a size, since both apply to more than one JSON type. Pinned as the shared limitation
      # it is, so the asymmetry above cannot creep back unnoticed.
      # A classless bag is legal (PRO-3193), and its node names no type — so nothing there said the position
      # rejects nil, the parent dropped `items` entirely, and the document accepted `[null]` the positional
      # validator refuses on every call.
      it "rejects null at an untyped position that admits none" do
        action = build_axn { expects :f, type: Array, of: { presence: true } }

        expect(action.call(f: ["a"])).to be_ok
        expect(action.call(f: [nil])).not_to be_ok
        expect(action.input_schema.dig(:properties, :f, :items)).to eq(not: { type: "null" })
      end

      # Outbound the schema may say LESS than the contract and never more, and an untyped OUTPUT position is
      # untyped precisely because the emitter could not prove what it serializes to. Writing a claim there
      # would be inventing one in the direction reflection may not err.
      it "writes no such claim on output, where an untyped position is one it could not prove" do
        action = build_axn do
          exposes :f, type: Array, of: { presence: true }
          def call = expose(:f, ["a"])
        end

        expect(action.call).to be_ok
        expect(action.output_schema[:properties][:f]).not_to have_key(:items)
      end

      it "infers nothing from format: alone, exactly as a field does not" do
        bagged = build_axn { expects :f, type: Array, of: { format: { with: /\Aa/ } } }
        fielded = build_axn { expects :f, format: { with: /\Aa/ } }

        # No TYPE is inferred at either position, which is the claim — neither a pattern nor a size names one
        # JSON type. The element node is not EMPTY, though: the position still rejects nil (`nil.to_s` is `""`,
        # which this pattern refuses), so it says that much and nothing more.
        expect(bagged.input_schema.dig(:properties, :f, :items)).to eq(not: { type: "null" })
        expect(bagged.input_schema.dig(:properties, :f, :items)).not_to have_key(:type)
        expect(fielded.input_schema[:properties][:f]).to eq({})
      end
    end

    describe "keys axis, where propertyNames earns its place" do
      # PRO-3165 emitted nothing for `keys:` because every JSON object key is already a string, so a bare
      # `keys: String` says nothing actionable. That reasoning holds — and stops holding the moment the axis
      # carries a constraint a client can act on.
      it "still emits nothing for a bare type axis" do
        prop = prop_for(:m) { expects :m, type: Hash, of: { keys: String, values: Integer } }

        expect(prop).not_to have_key(:propertyNames)
      end

      it "still emits nothing for a bag axis that only names a class" do
        prop = prop_for(:m) { expects :m, type: Hash, of: { keys: { klass: String }, values: Integer } }

        expect(prop).not_to have_key(:propertyNames)
      end

      it "emits propertyNames for a constrained keys axis" do
        prop = prop_for(:m) do
          expects :m, type: Hash, of: { keys: { klass: String, format: { with: /\A[a-z]+\z/ } }, values: Integer }
        end

        expect(prop[:propertyNames]).to eq(pattern: "^[a-z]+$")
      end

      # A JSON object key is always a string — but a Symbol AXIS rejects one, so on input the rendered form
      # would name a key axn refuses. Emitted on output only, through the key serializer. The full treatment
      # (and the Time case that showed the value serializer was the wrong renderer) is under "a keys axis emits
      # only what a JSON property name can be" below.
      it "emits a Symbol inclusion set on output, and stands down on input" do
        inbound = prop_for(:m) do
          expects :m, type: Hash, of: { keys: { klass: Symbol, inclusion: { in: %i[a b] } }, values: Integer }
        end
        outbound = build_axn do
          exposes :m, type: Hash, of: { keys: { klass: Symbol, inclusion: { in: %i[a b] } }, values: Integer }
          def call = expose(:m, { a: 1 })
        end

        expect(inbound).not_to have_key(:propertyNames)
        expect(outbound.output_schema.dig(:properties, :m, :propertyNames)).to eq(enum: %w[a b])
      end

      it "emits a keys-axis length bound" do
        prop = prop_for(:m) do
          expects :m, type: Hash, of: { keys: { klass: String, length: { maximum: 4 } }, values: Integer }
        end

        expect(prop[:propertyNames]).to eq(maxLength: 4)
      end

      # A numeric bound survives no string-ification, so there is no `propertyNames` subschema that says it —
      # the constraint is enforced in Ruby and reflects nowhere, exactly as PRO-3165 decided for a bare axis.
      it "emits nothing for a keys-axis numeric bound, which no propertyNames expresses" do
        action = build_axn do
          expects :m, type: Hash, of: { keys: { klass: Integer, numericality: { greater_than: 0 } }, values: Integer }
        end

        expect(action.call(m: { 1 => 2 })).to be_ok
        expect(action.call(m: { -1 => 2 })).not_to be_ok
        expect(action.input_schema[:properties][:m]).not_to have_key(:propertyNames)
      end

      # JSON Schema's `propertyNames` applies to EVERY key, including ones `properties` matches, while the
      # runtime EXEMPTS a shape-named key from both axes (PRO-3166). Emitting the bare constraint would make
      # the node unsatisfiable whenever a member name fails it — required, and forbidden by propertyNames — so
      # the emitted union is the runtime rule verbatim: a key is one the shape names, or one the axis admits.
      it "unions the shaped key names in when a shape sits beside a constrained keys axis" do
        prop = prop_for(:m) do
          expects :m, type: Hash, of: { keys: { klass: String, format: { with: /\A\d+\z/ } }, values: Integer } do
            field :label, type: Integer
          end
        end

        expect(prop[:propertyNames]).to eq(anyOf: [{ pattern: "^\\d+$" }, { enum: ["label"] }])
      end

      # The exemption has to reach EVERY node where a shape's `properties` and a keys axis's `propertyNames`
      # meet, not only the field's own. A nested bag composes both in `contents_node_schema`, and the block
      # form folds into exactly that bag (PRO-3191), so both spellings land on the same node.
      it "unions them on a NESTED shaped map too" do
        action = build_axn do
          expects :rows, type: Array, of: { klass: Hash,
                                            of: { keys: { klass: String, format: { with: /\A\d+\z/ } }, values: Integer },
                                            shape: { members: [Struct.new(:field, :validations).new(:label, { type: Integer })] } }
        end

        expect(action.input_schema.dig(:properties, :rows, :items, :propertyNames))
          .to eq(anyOf: [{ pattern: "^\\d+$" }, { enum: ["label"] }])
        expect(action.call(rows: [{ "label" => 1, "42" => 2 }])).to be_ok
      end

      it "unions them for the block form, which folds into the same bag" do
        action = build_axn do
          expects :rows, type: Array, of: { klass: Hash,
                                            of: { keys: { klass: String, format: { with: /\A\d+\z/ } }, values: Integer } } do
            field :label, type: Integer
          end
        end

        expect(action.input_schema.dig(:properties, :rows, :items, :propertyNames))
          .to eq(anyOf: [{ pattern: "^\\d+$" }, { enum: ["label"] }])
        expect(action.call(rows: [{ "label" => 1, "42" => 2 }])).to be_ok
      end

      it "keeps that node satisfiable — the runtime accepts the exempt key the axis would reject" do
        action = build_axn do
          expects :m, type: Hash, of: { keys: { klass: String, format: { with: /\A\d+\z/ } }, values: Integer } do
            field :label, type: Integer
          end
        end

        expect(action.call(m: { "label" => 1, "42" => 2 })).to be_ok
        expect(action.call(m: { "label" => 1, "nope" => 2 })).not_to be_ok
      end
    end

    # The projector reads named keys, so forwarding the recursion edges to it would be inert TODAY — this
    # pins the helper's own contract instead, since what it returns is consumed as "the constraints on this
    # value" and `of:`/`shape:` describe a nested node rather than a keyword on this one.
    describe "bag_value_constraints" do
      it "keeps the value validators and a TRUE tolerance, and drops everything else that describes the position" do
        bag = { klass: String, container: Array, message: "m", of: { klass: Integer },
                shape: { members: [] }, format: { with: /a/ }, allow_nil: true }

        expect(described_class.send(:bag_value_constraints, bag, for_output: false))
          .to eq(format: { with: /a/ }, allow_nil: true)
      end

      # A FALSE tolerance is `_canonicalize_bag_tolerance!`'s default rather than an author's own statement, and
      # it never reaches the validator this hash feeds — `OfValidator#inner_contract_validations` excludes it
      # from what it hands `validates`. Forwarding it here would feed a FIELD-only reading (ActiveModel merges
      # its declaration-wide `allow_blank: false` into every entry it builds) a fact this position's own runtime
      # never acts on, so it is dropped rather than kept the way a genuine `true` is.
      it "drops a FALSE tolerance, which the position's own runtime never sees" do
        bag = { klass: String, format: { with: /a/ }, allow_nil: false, allow_blank: false }

        expect(described_class.send(:bag_value_constraints, bag, for_output: false)).to eq(format: { with: /a/ })
      end
    end

    describe "constraints that stay unemitted" do
      it "emits nothing for exclusion:, as at a field" do
        prop = prop_for(:roles) { expects :roles, type: Array, of: { klass: String, exclusion: { in: %w[admin] } } }

        expect(prop[:items]).to eq(type: "string")
      end

      it "emits nothing for a validate: callable" do
        prop = prop_for(:codes) { expects :codes, type: Array, of: { klass: String, validate: ->(v) { "no" if v == "x" } } }

        expect(prop[:items]).to eq(type: "string")
      end

      it "emits nothing for acceptance:" do
        prop = prop_for(:flags) { expects :flags, type: Array, of: { klass: String, acceptance: { accept: %w[yes] } } }

        expect(prop[:items]).to eq(type: "string")
      end
    end
  end

  # Codex round 1 found six emission defects, all confirmed with a real JSON Schema validator. They are three
  # root causes, not six instances, and each is fixed at the root:
  #
  #   * a keyword ASSIGNED where it should be RECONCILED with what is already there (enum vs a singleton type
  #     enum; a bound from one validator vs the same bound from another; a range-derived bound vs an explicit one)
  #   * a position's nullability HARD-CODED false, where a field's is derived
  #   * an escape passed through whose character set differs between the two dialects
  describe "reconciling a keyword with what is already on the node" do
    def prop_for(field = :f, &declaration)
      build_axn(&declaration).input_schema[:properties][field]
    end

    # `single_contents_schema` constrains TrueClass to `enum: [true]`, because the runtime accepts only the
    # singleton. An inclusion set must narrow that, never widen it.
    it "intersects an inclusion enum with a singleton type enum rather than replacing it" do
      prop = prop_for { expects :f, type: Array, of: { klass: TrueClass, inclusion: { in: [true, false] } } }

      expect(prop[:items]).to include(enum: [true])
    end

    # A set disjoint from the position's own type never reaches the emitter: the satisfiability guard refuses
    # the declaration first, which is the stronger answer.
    it "never sees a disjoint set, because the declaration is refused" do
      expect { build_axn { expects :f, type: Array, of: { klass: TrueClass, inclusion: { in: [false] } } } }
        .to raise_error(ArgumentError, /can never match/)
    end

    # Both validators are enforced, so the emitted bound is the STRONGEST of the two, not whichever the
    # iteration reached last.
    it "intersects the same bound declared by numericality: and comparison:" do
      prop = prop_for do
        expects :f, type: Integer, numericality: { greater_than: 10 }, comparison: { greater_than: 0 }
      end

      expect(prop).to include(exclusiveMinimum: 10)
    end

    it "intersects in the other direction too" do
      prop = prop_for do
        expects :f, type: Integer, numericality: { less_than: 10 }, comparison: { less_than: 100 }
      end

      expect(prop).to include(exclusiveMaximum: 10)
    end

    # The size bounds already reach every size-bearing `anyOf` branch; the numeric bounds did not, so a union
    # emitted no bound at all and the schema accepted what the runtime rejected.
    it "applies a numeric bound to every numeric anyOf branch" do
      action = build_axn { expects :n, type: [Integer, Float], numericality: { greater_than: 0 } }

      expect(action.call(n: -1)).not_to be_ok
      expect(action.input_schema[:properties][:n][:anyOf])
        .to eq([{ type: "integer", exclusiveMinimum: 0 }, { type: "number", exclusiveMinimum: 0 }])
    end

    # A branch that cannot carry the bound was left advertising values the validator rejects: the string branch
    # accepted "abc" while ActiveModel rejected it on every call. Input reflection may be stricter than the
    # runtime but never looser, and dropping the branch is the licensed direction — it says less than the runtime
    # allows (ActiveModel does accept the numeric string "5"), and it cannot say more, no `minimum` applying to a
    # JSON string. One survivor is no longer a union, so the node collapses rather than emit a one-branch anyOf.
    it "drops a union branch that cannot carry the bound, rather than leave it lying" do
      action = build_axn { expects :n, type: [Integer, String], numericality: { greater_than: 0 } }
      prop = action.input_schema[:properties][:n]

      expect(prop).to eq(type: "integer", exclusiveMinimum: 0)
      expect(action.call(n: "abc")).not_to be_ok
      expect(action.call(n: 5)).to be_ok
    end

    # The nullability branch is not dropped with them: a nil is SKIPPED by the validator rather than bounded by
    # it, so removing that branch would reject a value the contract admits.
    it "keeps the nullability branch, which the validator skips rather than bounds" do
      action = build_axn { expects :n, type: [Integer, String], numericality: { greater_than: 0 }, optional: true }

      expect(action.input_schema.dig(:properties, :n, :anyOf))
        .to eq([{ type: "integer", exclusiveMinimum: 0 }, { type: "null" }])
      expect(action.call(n: nil)).to be_ok
    end

    # The narrowing is OUTPUT-forbidden — there the schema describes what the action produces, and dropping a
    # branch would reject a value axn serialized. Outbound there is no bound to drop in the first place: the
    # projection stands down entirely unless the validator proves the value is numeric.
    it "does not narrow the union on output" do
      action = build_axn do
        exposes :n, type: [Integer, String], numericality: { greater_than: 0 }
        def call = expose(:n, "5")
      end

      expect(action.call).to be_ok
      expect(action.output_schema[:properties][:n]).not_to include(:exclusiveMinimum)
    end

    # A union merely CONTAINING a numeric branch is not a union carrying a bound; narrowing on the former would
    # drop the string branch of a plain `type: [String, Integer]`.
    it "leaves a union that declares no bound at all alone" do
      prop = prop_for(:n) { expects :n, type: [Integer, String] }

      expect(prop[:anyOf]).to eq([{ type: "integer" }, { type: "string", minLength: 1 }])
    end

    it "intersects a range-derived bound with an explicitly declared one" do
      prop = prop_for { expects :f, type: Integer, numericality: { greater_than_or_equal_to: 10, in: 0..100 } }

      expect(prop).to include(minimum: 10, maximum: 100)
    end

    it "intersects a range's ceiling with an explicit one" do
      prop = prop_for { expects :f, type: Integer, numericality: { less_than_or_equal_to: 50, in: 0..100 } }

      expect(prop).to include(minimum: 0, maximum: 50)
    end

    # `equal_to` is an EQUALITY, not an ordering: two different values intersect to NOTHING. The emitted node
    # says so, rather than saying less.
    #
    # That is the faithful projection, and standing down would be the papering-over PRO-3220 explicitly warns
    # against ("the emitter is faithfully projecting a contract that is already broken, and teaching it to paper
    # over that would hide the defect rather than close it"). The corollary in guards-and-projections.md forbids
    # an unsatisfiable node for a SATISFIABLE contract; this contract admits nothing, and the emitter already
    # projects that family unsatisfiably elsewhere — `length: { maximum: 0 }` on a required Array emits
    # `minItems: 1, maxItems: 0`. Refusing the declaration outright stays PRO-3220's.
    it "emits an unsatisfiable enum when two equality bounds contradict" do
      action = build_axn { expects :f, type: Integer, numericality: { equal_to: 1 }, comparison: { equal_to: 2 } }

      expect(action.call(f: 1)).not_to be_ok
      expect(action.call(f: 2)).not_to be_ok
      expect(action.input_schema[:properties][:f]).to include(enum: [])
      expect(action.input_schema[:properties][:f]).not_to have_key(:const)
    end

    it "dominates any enum the position already carried" do
      action = build_axn do
        expects :f, type: Integer, inclusion: { in: [1, 2] },
                    numericality: { equal_to: 1 }, comparison: { equal_to: 2 }
      end

      expect(action.input_schema[:properties][:f][:enum]).to eq([])
    end

    it "emits it at a bag position too" do
      action = build_axn do
        expects :f, type: Array, of: { klass: Integer, numericality: { equal_to: 1 }, comparison: { equal_to: 2 } }
      end

      expect(action.input_schema.dig(:properties, :f, :items)).to include(enum: [])
    end

    it "still emits const when two equality bounds agree" do
      prop = prop_for { expects :f, type: Integer, numericality: { equal_to: 5 }, comparison: { equal_to: 5 } }

      expect(prop).to include(const: 5)
    end

    it "agrees with the runtime on the value each finding named" do
      both = build_axn { expects :f, type: Integer, numericality: { greater_than: 10 }, comparison: { greater_than: 0 } }
      ranged = build_axn { expects :f, type: Integer, numericality: { greater_than_or_equal_to: 10, in: 0..100 } }

      expect(both.call(f: 5)).not_to be_ok
      expect(ranged.call(f: 5)).not_to be_ok
      expect(both.input_schema[:properties][:f][:exclusiveMinimum]).to eq(10)
      expect(ranged.input_schema[:properties][:f][:minimum]).to eq(10)
    end
  end

  describe "a position's nullability, derived rather than assumed" do
    def prop_for(field = :f, &declaration)
      build_axn(&declaration).input_schema[:properties][field]
    end

    # A bag naming NilClass admits nil at that position — until another validator on the same bag rejects it.
    # That is the same question `nil_accepted?` answers for a field, asked of the bag.
    it "keeps the null branch when the bag admits nil" do
      prop = prop_for { expects :f, type: Array, of: { klass: [String, NilClass] } }

      expect(prop[:items]).to eq(anyOf: [{ type: "string" }, { type: "null" }])
    end

    it "drops the null branch when another validator on the bag rejects nil" do
      action = build_axn { expects :f, type: Array, of: { klass: [String, NilClass], presence: true } }

      expect(action.call(f: [nil])).not_to be_ok
      # One surviving branch collapses onto the plain type, exactly as `apply_type_info!` does at a field.
      expect(action.input_schema.dig(:properties, :f, :items)).to eq(type: "string", minLength: 1)
    end

    it "keeps nil in a positional enum that admits it" do
      action = build_axn { expects :f, type: Array, of: { inclusion: { in: ["a", nil] } } }

      expect(action.call(f: [nil])).to be_ok
      expect(action.input_schema.dig(:properties, :f, :items, :enum)).to eq(["a", nil])
    end

    it "still strips nil from an enum at a position that rejects it" do
      action = build_axn { expects :f, type: Array, of: { klass: String, inclusion: { in: ["a", nil] } } }

      expect(action.call(f: [nil])).not_to be_ok
      expect(action.input_schema.dig(:properties, :f, :items, :enum)).to eq(["a"])
    end
  end

  describe "a keys axis emits only what a JSON property name can be" do
    def prop_for(field = :f, &declaration)
      build_axn(&declaration).input_schema[:properties][field]
    end

    # A JSON object property name is always a string. A Symbol has a faithful wire form; an Integer key does
    # not (the runtime accepts `{1 => v}`, and no `propertyNames` set can say so), so the axis stands down
    # rather than emit a set no key can satisfy.
    # A JSON client can only send STRING keys, and a Symbol axis rejects one — measured, `{ "a" => 1 }` fails
    # where `{ a: 1 }` passes. So advertising `enum: ["a", "b"]` inbound tells a client to send a key axn will
    # refuse, which is PRO-3165's "a `keys: Symbol` would be a lie on the wire" in a different costume. It
    # stands down on input, and on OUTPUT it emits — there the serializer really does render the key as "a".
    it "stands down on a Symbol set for INPUT, which a JSON key cannot satisfy" do
      prop = prop_for(:m) do
        expects :m, type: Hash, of: { keys: { klass: Symbol, inclusion: { in: %i[a b] } }, values: Integer }
      end

      expect(prop).not_to have_key(:propertyNames)
    end

    it "emits a Symbol set on OUTPUT, through the key serializer" do
      action = build_axn do
        exposes :m, type: Hash, of: { keys: { klass: Symbol, inclusion: { in: %i[a b] } }, values: Integer }
        def call = expose(:m, { a: 1 })
      end

      expect(action.call).to be_ok
      expect(action.output_schema.dig(:properties, :m, :propertyNames)).to eq(enum: %w[a b])
    end

    # Round 11 gated the ENUM on this, which was the keyword rather than the class: a JSON key is a String, so
    # a `keys:` axis whose declared class excludes String can never be satisfied from JSON AT ALL, and every
    # inbound `propertyNames` keyword is equally a lie there — not just the set.
    it "stands down entirely on input when the axis excludes String keys" do
      prop = prop_for(:m) do
        expects :m, type: Hash, of: { keys: { klass: Symbol, format: { with: /\Aa\z/ } }, values: Integer }
      end

      expect(prop).not_to have_key(:propertyNames)
    end

    it "stands down for a length: on such an axis too" do
      prop = prop_for(:m) do
        expects :m, type: Hash, of: { keys: { klass: Symbol, length: { maximum: 1 } }, values: Integer }
      end

      expect(prop).not_to have_key(:propertyNames)
    end

    it "still emits those keywords on OUTPUT, where the key is serialized to a String" do
      action = build_axn do
        exposes :m, type: Hash, of: { keys: { klass: Symbol, format: { with: /\Aa\z/ } }, values: Integer }
        def call = expose(:m, { a: 1 })
      end

      expect(action.call).to be_ok
      expect(action.output_schema.dig(:properties, :m, :propertyNames)).to eq(pattern: "^a$")
    end

    # ...but only those keywords whose SUBJECT survives the trip. `format:` and the enum already read the wire
    # form the serializer writes (`#to_s` and `canonical_wire_key`), so they project. `length:` does not:
    # ActiveModel measures the key OBJECT's `#length`, while `minLength`/`maxLength` measure the property name.
    # A class is free to have both — a path whose `#length` counts segments serializes to `"a/b"` — and then the
    # emitted bound rejects output the action itself produced.
    describe "a keys-axis length:, whose subject is the key object rather than its wire form" do
      let(:segmented_key) do
        Class.new do
          def initialize(*parts) = @parts = parts
          def length = @parts.length
          def to_s = @parts.join("/")
          def hash = to_s.hash
          def eql?(other) = other.is_a?(self.class) && other.to_s == to_s
        end
      end

      before { stub_const("SegmentedKey", segmented_key) }

      # The divergence itself, pinned so the examples below cannot go vacuously green on a key whose two
      # measurements happen to agree.
      it "is a class whose #length disagrees with its serialized form" do
        key = SegmentedKey.new("a", "b")

        expect(key.length).to eq(2)
        expect(key.to_s).to eq("a/b")
      end

      it "stands down on output, where the bound would reject the action's own serialized output" do
        action = build_axn do
          exposes :m, type: Hash, of: { keys: { klass: SegmentedKey, length: { is: 2 } }, values: Integer }
          def call = expose(:m, { SegmentedKey.new("a", "b") => 1 })
        end
        result = action.call

        expect(result).to be_ok
        expect(Axn::Extensions::Serialization.render(result)["m"].keys).to eq(["a/b"])
        expect(action.output_schema[:properties][:m]).not_to have_key(:propertyNames)
      end

      # `presence:` is the same defect wearing a different keyword: ActiveModel asks the key OBJECT's `blank?`,
      # so a key that is present can still serialize to the EMPTY property name, and what `presence:` emits at a
      # `propertyNames` node is a length floor.
      describe "a keys-axis presence:, whose emitted floor measures the property name" do
        let(:blank_wire_key) do
          Class.new do
            def to_s = ""
            def hash = "".hash
            def eql?(other) = other.is_a?(self.class)
          end
        end

        before { stub_const("BlankWireKey", blank_wire_key) }

        it "is a class that is present while its serialized form is empty" do
          key = BlankWireKey.new

          expect(key.blank?).to be(false)
          expect(key.to_s).to eq("")
        end

        it "stands down on output, where the floor would reject the action's own serialized output" do
          action = build_axn do
            exposes :m, type: Hash, of: { keys: { klass: BlankWireKey, presence: true }, values: Integer }
            def call = expose(:m, { BlankWireKey.new => 1 })
          end
          result = action.call

          expect(result).to be_ok
          expect(Axn::Extensions::Serialization.render(result)["m"].keys).to eq([""])
          expect(action.output_schema[:properties][:m]).not_to have_key(:propertyNames)
        end

        it "keeps the floor for a String axis, whose key IS its own wire form" do
          action = build_axn do
            exposes :m, type: Hash, of: { keys: { klass: String, presence: true }, values: Integer }
            def call = expose(:m, { "a" => 1 })
          end

          expect(action.call).to be_ok
          expect(action.output_schema.dig(:properties, :m, :propertyNames)).to eq(minLength: 1)
        end

        it "keeps it inbound, where the key is the wire string itself" do
          action = build_axn { expects :m, type: Hash, of: { keys: { klass: String, presence: true }, values: Integer } }

          expect(action.input_schema.dig(:properties, :m, :propertyNames)).to eq(minLength: 1)
        end
      end

      it "keeps a format: declared beside it, whose subject IS the #to_s the serializer writes" do
        action = build_axn do
          exposes :m, type: Hash, of: {
            keys: { klass: SegmentedKey, length: { is: 2 }, format: { with: %r{\A[a-z]/[a-z]\z} } },
            values: Integer,
          }
          def call = expose(:m, { SegmentedKey.new("a", "b") => 1 })
        end

        expect(action.call).to be_ok
        expect(action.output_schema.dig(:properties, :m, :propertyNames)).to eq(pattern: "^[a-z]/[a-z]$")
      end

      # A broad token ADMITS a String without guaranteeing one, and the two questions have opposite ancestry
      # directions: `Object` is in String's ancestry, so a JSON key really can satisfy a `klass: Object` axis —
      # but so can this key. Asking the reachability question here kept the bound on an axis that promises
      # nothing at all about what its keys are.
      it "stands down for a broad token that merely ADMITS a String" do
        action = build_axn do
          exposes :m, type: Hash, of: { keys: { klass: Object, length: { is: 2 } }, values: Integer }
          def call = expose(:m, { SegmentedKey.new("a", "b") => 1 })
        end
        result = action.call

        expect(result).to be_ok
        expect(Axn::Extensions::Serialization.render(result)["m"].keys).to eq(["a/b"])
        expect(action.output_schema[:properties][:m]).not_to have_key(:propertyNames)
      end
    end

    # No `klass:` means the keys may be anything, the class above included, so nothing can be promised about
    # what their length becomes on the wire. Input is unaffected: there the key IS the string it was sent as.
    it "stands a length: down on output for a klass-less axis, whose keys may be anything" do
      action = build_axn do
        exposes :m, type: Hash, of: { keys: { length: { is: 2 } }, values: Integer }
        def call = expose(:m, { "ab" => 1 })
      end

      expect(action.call).to be_ok
      expect(action.output_schema[:properties][:m]).not_to have_key(:propertyNames)
      expect(prop_for(:m) { expects :m, type: Hash, of: { keys: { length: { is: 2 } }, values: Integer } })
        .to include(propertyNames: { minLength: 2, maxLength: 2 })
    end

    # The set has the same shape of bug as the bound, one subject over: the runtime matches a key by Ruby `==`,
    # which can identify values that serialize DIFFERENTLY. `1 == 1.0`, so an axis admitting the numeric tower
    # accepts a `1.0` key against a member of `1` and then serializes "1.0" — a property name the emitted set
    # does not contain. One gate answers both, rather than a keyword-by-keyword table.
    it "stands an inclusion set down on output where Ruby equality crosses wire forms" do
      action = build_axn do
        exposes :m, type: Hash, of: { keys: { klass: Numeric, inclusion: { in: [1] } }, values: Integer }
        def call = expose(:m, { 1.0 => 5 })
      end
      result = action.call

      expect([1].include?(1.0)).to be true
      expect(result).to be_ok
      expect(Axn::Extensions::Serialization.render(result)["m"].keys).to eq(["1.0"])
      expect(action.output_schema[:properties][:m]).not_to have_key(:propertyNames)
    end

    # A String SUBCLASS is its own wire form — it IS a String — so the subtype direction keeps the projection
    # that the supertype direction must refuse.
    it "keeps the projection for a String subclass, which is its own wire form" do
      stub_const("Slug", Class.new(String))
      action = build_axn do
        exposes :m, type: Hash, of: { keys: { klass: Slug, length: { is: 2 } }, values: Integer }
        def call = expose(:m, { Slug.new("ab") => 1 })
      end

      expect(action.call).to be_ok
      expect(action.output_schema.dig(:properties, :m, :propertyNames)).to eq(minLength: 2, maxLength: 2)
    end

    # String and Symbol are the classes whose `#length` IS their own name's length, so the two measurements
    # cannot come apart and the bound stays emitted.
    it "keeps a length: on output for the classes whose #length is their serialized length" do
      [String, Symbol, :uuid, [String, Symbol]].each do |token|
        action = build_axn do
          exposes :m, type: Hash, of: { keys: { klass: token, length: { is: 2 } }, values: Integer }
        end

        expect(action.output_schema.dig(:properties, :m, :propertyNames))
          .to eq({ minLength: 2, maxLength: 2 }), "expected #{token.inspect} to keep its key length bound"
      end
    end

    it "still emits inbound for a klass-less axis, which a String key can satisfy" do
      prop = prop_for(:m) do
        expects :m, type: Hash, of: { keys: { format: { with: /\Aa\z/ } }, values: Integer }
      end

      expect(prop[:propertyNames]).to eq(pattern: "^a$")
    end

    # A `:uuid` axis is string-shaped, so a JSON key really can satisfy it.
    it "still emits inbound for a uuid axis, whose values are Strings" do
      prop = prop_for(:m) do
        expects :m, type: Hash, of: { keys: { klass: :uuid, length: { maximum: 36 } }, values: Integer }
      end

      expect(prop[:propertyNames]).to eq(maxLength: 36)
    end

    # Reflection must not hand back the objects the contract itself holds: a consumer mutating a returned
    # member in place would change which keys the DECLARED action accepts. The value-enum path dups through
    # `normalize_schema_literal`; this one was returning the inclusion array's own Strings.
    # A JSON key can only ever equal a STRING member, so the reachable subset is not an approximation — it is
    # exactly the set of JSON-supplied keys the runtime accepts. Standing down from the whole constraint
    # instead let `{"zzz" => 1}` through the document while the runtime rejected it.
    it "projects the reachable String subset of a mixed set" do
      action = build_axn do
        expects :m, type: Hash, of: { keys: { klass: [String, Integer], inclusion: { in: ["a", 1] } }, values: Integer }
      end

      expect(action.call(m: { "a" => 1 })).to be_ok
      expect(action.call(m: { "zzz" => 1 })).not_to be_ok
      expect(action.input_schema.dig(:properties, :m, :propertyNames)).to eq(enum: %w[a])
    end

    # When NO member is reachable the axis stands down rather than emitting `enum: []`, matching the class gate
    # above — both are "no JSON key can satisfy this axis". Deliberately unlike the contradictory-equality case,
    # which emits an unsatisfiable node: there the contract admits NOTHING, where here a Ruby caller passing
    # `{1 => 1}` satisfies it perfectly well and only the JSON wire cannot reach it.
    # This USED to stand the set down, on the reasoning that a Ruby caller satisfies the axis perfectly well and
    # only the wire cannot reach it. That reasoning conflates two audiences: `input_schema` is a JSON Schema, and
    # its reader is a JSON client, for which no key whatever satisfies this axis. Standing down told that client
    # every key was acceptable — measured, the document accepted `{"x" => 1}` the runtime rejects, which is the
    # one direction reflection may never err in. The empty set says what is true OF THE WIRE, and it says
    # something useful besides: this declaration cannot be driven from JSON at all.
    #
    # The axis whose CLASS excludes String keeps its stand-down and is a different case — see PRO-3165 below.
    it "admits no key when the axis is reachable from JSON but no member of its set is" do
      action = build_axn do
        expects :m, type: Hash, of: { keys: { klass: [String, Integer], inclusion: { in: [1, 2] } }, values: Integer }
      end

      expect(action.call(m: { 1 => 1 })).to be_ok # a Ruby caller still satisfies it
      expect(action.call(m: { "1" => 1 })).not_to be_ok # and no JSON-supplied key does
      expect(action.input_schema.dig(:properties, :m, :propertyNames)).to eq(enum: [])
    end

    # Outbound, the set is emitted only where the axis guarantees a key that IS its own property name. This
    # axis does not: the emitted set would be exact here (an accepted key is the String "a" or the Integer 1,
    # which serialize to "a" and "1"), but exactness rests on the numeric tower admitting no OTHER type that
    # is `==` to 1, and that reasoning does not survive the next class. Saying less on output costs nothing —
    # a missing `propertyNames` accepts what the action produces, which is the only promise output makes.
    it "stands the set down on output for an axis whose keys are not their own wire form" do
      action = build_axn do
        exposes :m, type: Hash, of: { keys: { klass: [String, Integer], inclusion: { in: ["a", 1] } }, values: Integer }
        def call = expose(:m, { "a" => 1 })
      end

      expect(action.call).to be_ok
      expect(action.output_schema[:properties][:m]).not_to have_key(:propertyNames)
    end

    it "detaches the emitted members from the ones the validator holds" do
      member = +"a"
      action = build_axn { expects :m, type: Hash, of: { keys: { klass: String, inclusion: { in: [member] } }, values: Integer } }
      emitted = action.input_schema.dig(:properties, :m, :propertyNames, :enum)

      expect(emitted.first).not_to be_equal(member)
      emitted.first << "ZZZ"
      expect(member).to eq("a")
      expect(action.call(m: { "a" => 1 })).to be_ok
    end

    it "still emits a String set on input, which a JSON key CAN satisfy" do
      prop = prop_for(:m) do
        expects :m, type: Hash, of: { keys: { klass: String, inclusion: { in: %w[a b] } }, values: Integer }
      end

      expect(prop[:propertyNames]).to eq(enum: %w[a b])
    end

    # A map key is rendered by the KEY serializer, not the value serializer: a Time VALUE serializes as
    # `iso8601` and a Time KEY as `to_s`. Asserted against the serializer itself rather than through an emitted
    # enum, which is where it actually decides what the map produces — and which is what the axis emits
    # nothing for, a Time key not being its own property name.
    it "serializes a map key by the key serializer, not the value serializer" do
      moment = Time.now
      action = build_axn do
        exposes :m, type: Hash, of: { keys: { klass: Time, inclusion: { in: [moment] } }, values: Integer }
        define_method(:call) { expose(:m, { moment => 1 }) }
      end
      result = action.call

      expect(result).to be_ok
      expect(Axn::Extensions::Serialization.render(result)["m"].keys)
        .to eq([Axn::Internal::Reflection::Values.canonical_wire_key(moment)])
      expect(Axn::Extensions::Serialization.render(result)["m"].keys.first).not_to eq(moment.iso8601)
      expect(action.output_schema[:properties][:m]).not_to have_key(:propertyNames)
    end

    it "stands down on a set whose members have no property-name form" do
      action = build_axn do
        expects :m, type: Hash, of: { keys: { klass: Integer, inclusion: { in: [1] } }, values: Integer }
      end

      expect(action.call(m: { 1 => 2 })).to be_ok
      expect(action.input_schema[:properties][:m]).not_to have_key(:propertyNames)
    end

    # Originally asserted the opposite — "don't render half of it" — which was wrong: the half that renders is
    # the whole of what a JSON key can reach, since a String key can never equal the Integer member. The
    # subset is exact rather than partial. (Full treatment in "projects the reachable String subset" below.)
    it "projects the reachable half of a mixed set rather than standing down" do
      action = build_axn { expects :m, type: Hash, of: { keys: { inclusion: { in: ["a", 1] } }, values: Integer } }

      expect(action.call(m: { "a" => 1 })).to be_ok
      expect(action.call(m: { "zzz" => 1 })).not_to be_ok
      expect(action.input_schema.dig(:properties, :m, :propertyNames)).to eq(enum: %w[a])
    end

    it "keeps the string-shaped constraints beside an unsatisfiable set" do
      # A klass-less axis is reachable from JSON, and no member of this set is — so the set admits no key at
      # all. The size bound still emits beside it: both are enforced, and the emitter's job is to say what the
      # position holds rather than to tidy away a keyword the empty set already subsumes.
      prop = prop_for(:m) do
        expects :m, type: Hash,
                    of: { keys: { length: { maximum: 4 }, inclusion: { in: [1, 2] } }, values: Integer }
      end

      expect(prop[:propertyNames]).to eq(maxLength: 4, enum: [])
    end
  end

  # A position's tolerance is projected exactly as a FIELD's is, by the same helpers — which is the
  # requirement, not a convenience: the field-level behaviour is precise and non-obvious (an `allow_blank`
  # DROPS a length floor because the empty value passes, while an `allow_nil` KEEPS it because the empty value
  # still fails), and a second implementation would drift from it.
  # A bag naming no class at all — `of: { shape: … }`, "these members, class unconstrained" — starts from an
  # untyped node, so there is no `null` branch on it for the shape overlay to preserve. The overlay therefore asks
  # the BAG for its nullability rather than reading it back off the node, which is the same source the
  # nullability reconciler reads and so cannot disagree with it.
  # The shape is an ENTRY, so ActiveModel lets it override the position's tolerance per key. Nullability is
  # derived from that resolution rather than from the bag tier alone, or the document advertises a null the
  # runtime refuses — looser than the contract, which is the direction this layer must never err in.
  describe "a shape entry may override the position's tolerance" do
    let(:member) do
      Axn::Core::Contract::ShapeConfig.new(field: :a, validations: { type: { klass: String }, presence: true })
    end

    it "emits no null branch when the shape entry refuses the position's allow_nil:" do
      # `build_axn` class_evals its block, so the member has to be captured in a local rather than read
      # off the example group.
      m = member
      action = build_axn { expects :f, type: Array, of: { allow_nil: true, shape: { members: [m], allow_nil: false } } }

      expect(action.call(f: [nil])).not_to be_ok
      expect(described_class.build_input(action.internal_field_configs, action.subfield_configs)
        .dig(:properties, :f, :items, :type)).to eq("object")
    end

    it "emits the null branch when the shape entry does not override it" do
      m = member
      action = build_axn { expects :f, type: Array, of: { allow_nil: true, shape: { members: [m] } } }

      expect(action.call(f: [nil])).to be_ok
      expect(described_class.build_input(action.internal_field_configs, action.subfield_configs)
        .dig(:properties, :f, :items, :type)).to eq(%w[object null])
    end

    # The other half of the conjunction. A tolerant shape entry cannot WIDEN a position whose own `klass:`
    # still rejects the nil — `validate_position` reports the type mismatch however willingly the shape skips
    # itself — so reading the shape entry alone advertised a null the runtime refuses.
    it "emits no null branch when a tolerant shape entry sits on a strictly typed position" do
      m = member
      action = build_axn { expects :f, type: Array, of: { klass: Hash, shape: { members: [m], allow_nil: true } } }

      expect(action.call(f: [nil])).not_to be_ok
      expect(described_class.build_input(action.internal_field_configs, action.subfield_configs)
        .dig(:properties, :f, :items, :type)).to eq("object")
    end

    it "emits the null branch only when BOTH the position and the shape entry admit it" do
      m = member
      both = build_axn { expects :f, type: Array, of: { klass: Hash, allow_nil: true, shape: { members: [m] } } }

      expect(both.call(f: [nil])).to be_ok
      expect(described_class.build_input(both.internal_field_configs, both.subfield_configs)
        .dig(:properties, :f, :items, :type)).to eq(%w[object null])
    end
  end

  describe "a shaped position's null branch survives the members overlay" do
    def items_node(bag)
      klass = build_axn { expects :f, type: Array, of: bag }
      described_class.build_input(klass.internal_field_configs, klass.subfield_configs)[:properties][:f][:items]
    end

    it "keeps null on a classless shaped position declaring allow_nil:" do
      expect(items_node(shape: { members: [] }, allow_nil: true)[:type]).to eq(%w[object null])
    end

    it "keeps null on a classless shaped position declaring allow_blank:" do
      expect(items_node(shape: { members: [] }, allow_blank: true)[:type]).to eq(%w[object null])
    end

    # A classless bag that declares NO tolerance gets no null branch, even though its own empty validator set
    # would admit one: the shape's members are what reject a nil there, and answering from the bag's value
    # constraints alone emits a document looser than the contract for every shaped position that HAS members
    # (`expects :items, type: Array do field :status, type: String end` rejects `[nil]`).
    it "leaves a classless shaped position that declares no tolerance a bare object" do
      expect(items_node(shape: { members: [] })[:type]).to eq("object")
    end

    it "keeps a distributing shape block with required members non-nullable, matching its runtime" do
      action = build_axn do
        expects :f, type: Array do
          field :a, type: String
        end
      end

      expect(action.call(f: [nil])).not_to be_ok
      expect(described_class.build_input(action.internal_field_configs, action.subfield_configs)
        .dig(:properties, :f, :items, :type)).to eq("object")
    end

    it "keeps null on a CLASSED shaped position declaring allow_nil:" do
      expect(items_node(klass: Hash, shape: { members: [] }, allow_nil: true)[:type]).to eq(%w[object null])
    end

    it "leaves a classed shaped position with no tolerance a bare object" do
      action = build_axn { expects :f, type: Array, of: { klass: Hash, shape: { members: [] } } }

      expect(action.call(f: [nil])).not_to be_ok
      expect(items_node(klass: Hash, shape: { members: [] })[:type]).to eq("object")
    end
  end

  # A tolerated nil KEY has no null branch to travel in — a JSON property name is always a string, so it
  # reaches the wire as `""`. Outbound the document has to admit that name or it rejects a result the action
  # produced; inbound it must not, because a JSON caller cannot send a nil key and the `""` it can send is a
  # genuine blank the axis's own validators reject.
  describe "a tolerated nil map key and its empty wire form" do
    let(:pattern) { { with: /\A[A-Z]+\z/ } }

    def output_property_names(axis, value)
      klass = Class.new do
        include Axn
        exposes :m, type: Hash, of: { keys: axis }
        define_method(:call) { expose(:m, value) }
      end
      [klass.call, described_class.build_output(klass.external_field_configs).dig(:properties, :m, :propertyNames)]
    end

    it "withholds a pattern the serialized empty key cannot satisfy, on output" do
      result, property_names = output_property_names({ klass: String, format: { with: /\A[A-Z]+\z/ }, allow_nil: true },
                                                     { nil => 1 })

      expect(result).to be_ok
      # The nil key is still a nil in Ruby; it is the WIRE form the emitted document describes, and there it
      # is the empty name — which is the whole reason the pattern cannot stand.
      expect(JSON.parse(JSON.generate(result.m))).to eq("" => 1)
      expect(property_names).to be_nil.or eq({})
    end

    it "widens an enum instead of dropping it" do
      _result, property_names = output_property_names({ klass: String, inclusion: { in: %w[A B] }, allow_nil: true },
                                                      { nil => 1 })

      expect(property_names[:enum]).to include("A", "B", "")
    end

    it "leaves an untolerant axis's pattern alone" do
      _result, property_names = output_property_names({ klass: String, format: { with: /\A[A-Z]+\z/ } }, { "AB" => 1 })

      expect(property_names[:pattern]).to eq("^[A-Z]+$")
    end

    it "keeps the pattern on INPUT, where the runtime still rejects a blank key" do
      action = build_axn do
        expects :m, type: Hash, of: { keys: { klass: String, format: { with: /\A[A-Z]+\z/ }, allow_nil: true } }
      end

      expect(action.call(m: { "" => 1 })).not_to be_ok
      expect(described_class.build_input(action.internal_field_configs, action.subfield_configs)
        .dig(:properties, :m, :propertyNames, :pattern)).to eq("^[A-Z]+$")
    end
  end

  describe "a tolerant of: bag's projection" do
    def items_for(&declaration)
      klass = build_axn(&declaration)
      described_class.build_input(klass.internal_field_configs, klass.subfield_configs)[:properties][:f][:items]
    end

    it "adds a null branch for a nil-tolerant element position" do
      expect(items_for { expects :f, type: Array, of: { klass: String, allow_nil: true } })
        .to include(type: %w[string null])
    end

    it "keeps a length floor under allow_nil:, which does not admit the empty value" do
      expect(items_for { expects :f, type: Array, of: { klass: String, length: { minimum: 2 }, allow_nil: true } })
        .to include(type: %w[string null], minLength: 2)
    end

    it "drops the length floor under allow_blank:, which does admit the empty value" do
      node = items_for { expects :f, type: Array, of: { klass: String, length: { minimum: 2 }, allow_blank: true } }

      expect(node).to include(type: %w[string null])
      expect(node).not_to include(:minLength)
    end

    it "leaves an untolerant position unchanged" do
      expect(items_for { expects :f, type: Array, of: { klass: String, length: { minimum: 2 } } })
        .to eq(type: "string", minLength: 2)
    end

    it "projects a tolerant values axis through additionalProperties" do
      klass = build_axn { expects :f, type: Hash, of: { values: { klass: String, allow_nil: true } } }
      node = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)[:properties][:f]

      expect(node[:additionalProperties]).to include(type: %w[string null])
    end
  end
end
