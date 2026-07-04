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

  it "drops nil from an output enum too when the field is not nullable (Codex review, build_output shares build_property)" do
    klass = Class.new do
      include Axn
      exposes :status, inclusion: { in: [nil, "open"] }
      def call = expose!(status: "open")
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

  it "still keeps a defaulted expectation OUT of input_schema[:required] (input defaults make the field client-omittable)" do
    klass = Class.new do
      include Axn
      expects :limit, type: Integer, default: 20
    end
    schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
    expect(schema[:required] || []).not_to include("limit")
  end

  # A TOP-LEVEL default only relaxes input requiredness when the default VALUE itself satisfies the
  # field's OWN contract — runtime applies the default and THEN validates, so a blank/type-mismatched
  # default still fails the omitted call and must keep the field required. Each case's requiredness is
  # asserted against verified runtime behavior of `klass.call({})` (recorded in comments below), decided
  # by the SAME real validator (Axn::Validation::Subfields.collect_errors) the subfield path already uses.
  describe "a top-level default only relaxes input requiredness when it satisfies the field's own contract (Codex review)" do
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

    it "does NOT require a String field whose non-blank default \"x\" satisfies the contract (runtime: call({}) ok)" do
      klass = Class.new do
        include Axn
        expects :name, type: String, default: "x"
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
      expect(schema[:required] || []).not_to include("name")
    end

    it "requires a String field whose default is type-mismatched (123) (runtime: call({}) fails \"Name is not a String\")" do
      klass = Class.new do
        include Axn
        expects :name, type: String, default: 123
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
      expect(schema[:required]).to include("name")
    end

    it "requires a :uuid field whose default is not a valid uuid (runtime: call({}) fails \"Id is not a uuid\")" do
      klass = Class.new do
        include Axn
        expects :id, type: :uuid, default: "not-a-uuid"
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
      expect(schema[:required]).to include("id")
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

    # Finding #73: a usable-but-INVALID default must NOT fall back to nil-tolerance. Executor applies
    # the default before validation on BOTH the absent and the nil path, so once a usable default
    # exists requiredness hinges solely on whether that default satisfies the contract — an allow_nil
    # field with a type-mismatched default is still required (runtime fails the omitted call).
    it "requires a String allow_nil field whose default is type-mismatched (123) despite nil-tolerance " \
       "(runtime: call({}) fails \"Name is not a String\" — the default is applied before validation, so allow_nil can't save it)" do
      klass = Class.new do
        include Axn
        expects :name, type: String, allow_nil: true, default: 123
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
      expect(schema[:required]).to include("name")
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

    it "requires a boolean allow_nil field with a Proc default (uninspectable → unprovable → conservative), even " \
       "though runtime here ACCEPTS the omitted call (`-> { false }` yields a valid boolean) — only knowable by " \
       "evaluating the Proc, which reflection must not do" do
      klass = Class.new do
        include Axn
        expects :flag, type: :boolean, allow_nil: true, default: -> { false }
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
      expect(schema[:required]).to include("flag")
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

  it "maps type: Symbol to a JSON string on input (Codex review: TYPE_MAP entry, matches serialize_exposed rendering a Symbol as its string form)" do
    klass = Class.new do
      include Axn
      expects :status, type: Symbol
    end
    schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
    expect(schema[:properties][:status]).to include(type: "string")
  end

  it "maps type: Symbol to a JSON string on output, not the object fallback (Codex review: schema said object while serialize_exposed emits a string)" do
    klass = Class.new do
      include Axn
      exposes :status, type: Symbol
      def call = expose!(status: :ok)
    end
    schema = described_class.build_output(klass.external_field_configs)
    expect(schema[:properties][:status]).to include(type: "string")
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

    it "drops nil from the enum when the inclusion set contains it but the field is not nullable (Codex review): " \
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
       "(Codex review, avoids a duplicate nil)" do
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
    it "requires an optional (no-default) parent with an all-optional subfield (omitting still yields a nil parent, which raises at runtime)" do
      klass = Class.new do
        include Axn
        expects :payload, optional: true
        expects :name, on: :payload, optional: true, type: String
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required]).to include("payload")
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

    it "does not require a parent whose literal Hash default already supplies the required subfield's key (Codex review)" do
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

    it "still requires the parent when a defaulted parent with multiple required subfields only covers some of the keys" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash, default: { name: "system" }
        expects :name, on: :payload, type: String
        expects :role, on: :payload, type: String
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required]).to include("payload")
    end
  end

  describe "a parent's default must actually SATISFY a required child, not merely supply its key (Codex review)" do
    it "still requires the parent when the default's key is present but the value is nil (default applied, then " \
       "validate_subfields_contract! rejects the nil, so calling with {} fails at runtime)" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash, default: { name: nil }
        expects :name, on: :payload, type: String
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required]).to include("payload")
    end

    it "still requires the parent when the default's value is present but the wrong type for the required child" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash, default: { name: 123 }
        expects :name, on: :payload, type: String
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required]).to include("payload")
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

    it "still requires the parent when the default's value is blank and the child has an explicit presence: true" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash, default: { name: "" }
        expects :name, on: :payload, type: String, presence: true
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required]).to include("payload")
    end

    it "still requires the parent when the default's value is blank and the child has Axn's implicit default " \
       "presence (a bare type: String subfield gets presence: true unless allow_nil/allow_blank/optional is set)" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash, default: { name: "" }
        expects :name, on: :payload, type: String
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required]).to include("payload")
    end

    it "does not require the parent when the required child's non-type validator (a LITERAL inclusion set) is " \
       "actually satisfied by the default — the real validator (collect_errors) evaluates the inclusion, so the " \
       "prior hand-rolled over-strictness is gone; runtime accepts calling with {} (child \"a\" is in the set)" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash, default: { name: "a" }
        expects :name, on: :payload, type: String, inclusion: { in: %w[a b] }
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required] || []).not_to include("payload")
    end

    it "still requires the parent when the required child's LITERAL inclusion set does NOT contain the default value" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash, default: { name: "z" }
        expects :name, on: :payload, type: String, inclusion: { in: %w[a b] }
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required]).to include("payload")
    end

    it "still requires the parent when the required child's inclusion set is ACTION-DEPENDENT (a symbol method), " \
       "since collect_errors needs an action instance we don't have in reflection → conservative (rescued)" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash, default: { name: "a" }
        expects :name, on: :payload, type: String, inclusion: { in: :allowed_names }
        def allowed_names = %w[a b]
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required]).to include("payload")
    end

    it "does not require the parent when the default's value would actually satisfy the required child (regression " \
       "guard for the #55 default-coverage case above: a non-blank, type-correct value still covers)" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash, default: { name: "system" }
        expects :name, on: :payload, type: String
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required] || []).not_to include("payload")
    end

    # #69: coverage is checked with the SAME matcher runtime uses (TypeValidator.value_matches?),
    # so a :uuid child is only "covered" by a default that is a real uuid — not just any String.
    it "still requires the parent when the required :uuid child's default value is a String that is NOT a valid " \
       "uuid (runtime applies the default, then TypeValidator's uuid regex rejects it, so calling with {} fails)" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash, default: { token: "not-a-uuid" }
        expects :token, on: :payload, type: :uuid
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required]).to include("payload")
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

    # #70: blank is checked with blank? (matching ActiveModel presence), not empty? — so a
    # whitespace-only String, which is blank? but not empty?, is correctly rejected as not covering.
    it "still requires the parent when the required String child's default value is whitespace-only (blank? under " \
       "ActiveModel presence, though not empty? — runtime's presence validator rejects it, so calling with {} fails)" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash, default: { name: "   " }
        expects :name, on: :payload, type: String
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required]).to include("payload")
    end

    # A bare type: :boolean subfield does NOT get Axn's implicit presence (unlike String/Integer/uuid),
    # so `false` is a VALID value at runtime and the parent may be omitted. Matches runtime exactly:
    # the blank? check is gated on the child actually having a presence validator.
    it "does not require the parent when the required :boolean child's default value is false (a boolean subfield " \
       "has no implicit presence, so false is valid at runtime and the parent may be omitted)" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash, default: { flag: false }
        expects :flag, on: :payload, type: :boolean
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required] || []).not_to include("payload")
    end
  end

  # Finding #71: a truthy subfield default makes runtime synthesize `provided_data[parent] = { child => default }`
  # (a HASH). If the parent is typed NON-Hash, that synthesized Hash fails the parent's OWN type validator, so
  # omitting the parent still raises at runtime — the schema must keep the parent required. Requiredness is now
  # decided by running the parent's real validators against the synthesized value.
  describe "a subfield default only relaxes a parent whose synthesized value satisfies the parent's OWN type (Finding #71)" do
    some_data = Data.define(:name)

    it "requires a NON-Hash-typed parent even when a subfield default would supply a value (the synthesized Hash " \
       "fails the parent's own type validator at runtime: \"Payload is not a SomeData\")" do
      klass = Class.new do
        include Axn
        expects :payload, type: some_data
        expects :name, on: :payload, type: String, default: "x"
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required]).to include("payload")
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

  describe "a dotted subfield NAME denotes a deep extraction path and is omitted from the schema (Codex review)" do
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

    it "requires an optional (no-default) parent whose only subfield is a dotted name, matching its shallow analog (Codex review regression)" do
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

      # Parity is the correctness criterion: a dotted-only subfield must not relax the parent's
      # requiredness relative to the shallow case — runtime validates both identically (a nil/omitted
      # parent raises trying to extract the child from it).
      expect(shallow_schema[:required]).to include("foo")
      expect(dotted_schema[:required]).to include("foo")

      # The dotted subfield's own SHAPE is still omitted (prior fix preserved).
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

  describe "a dotted `on:` PARENT or an `on:` pointing at another subfield rolls up to its top-level " \
           "root field for requiredness (Codex review)" do
    it "requires an allow_nil parent whose only subfield roots through a dotted on: parent, matching its " \
       "shallow analog (runtime raises identically for both when the parent is omitted)" do
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

      expect(shallow_schema[:required]).to include("address")
      expect(dotted_schema[:required]).to include("address")

      # The dotted parent's deep shape (an "address.billing" or "billing"/"zip" property nested under
      # :address) is not represented — only requiredness rolls up.
      address_props = dotted_schema[:properties][:address][:properties] || {}
      expect(address_props).not_to have_key("address.billing")
      expect(address_props).not_to have_key(:billing)
      expect(address_props).not_to have_key(:zip)
    end

    it "requires the top-level root when a required leaf is declared on: a subfield-of-a-subfield chain" do
      klass = Class.new do
        include Axn
        expects :foo, optional: true
        expects :mid, on: :foo
        expects :leaf, on: :mid
      end
      schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)

      expect(schema[:required]).to include("foo")
      # :mid still nests directly under :foo (it's a shallow child of :foo); :leaf's shape (a deep
      # descendant rooted through :mid) is omitted.
      expect(schema[:properties][:foo][:properties]).to have_key(:mid)
      expect(schema[:properties][:foo][:properties]).not_to have_key(:leaf)
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

  describe "nil-tolerant inclusion/exclusion validators (Codex review)" do
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

  describe "normalizing default:/enum literals to their JSON wire form (Codex review)" do
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

  describe "allow_blank inclusion fields reflect the empty string in their enum (Codex review)" do
    it "runtime: allow_blank accepts blank AND nil, rejects a non-member string" do
      klass = Class.new do
        include Axn
        expects :status, inclusion: { in: ["open"] }, allow_blank: true
      end

      expect(klass.call(status: "")).to be_ok
      expect(klass.call(status: nil)).to be_ok
      expect(klass.call(status: "x")).not_to be_ok
    end

    it "includes both \"\" and nil (and the declared member) in the enum for an allow_blank inclusion field" do
      klass = Class.new do
        include Axn
        expects :status, inclusion: { in: ["open"] }, allow_blank: true
      end
      schema = klass.input_schema

      expect(schema[:properties][:status][:enum]).to match_array(["open", "", nil])
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

  # Finding #72: a blank-tolerant (allow_blank) inclusion field accepts "" at runtime even when its declared
  # members are NON-string (numeric/symbol/boolean) — ActiveModel skips inclusion for a blank value. The old
  # code only appended "" when the enum already had a String member, so a numeric enum wrongly rejected "".
  describe "a blank-tolerant inclusion field with NON-string members reflects \"\" in its enum and a type that permits it (Finding #72)" do
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

    it "appends \"\" (and nil) to a numeric enum, and widens the advertised type to permit the blank string" do
      klass = Class.new do
        include Axn
        expects :status, inclusion: { in: [1, 2] }, allow_blank: true
      end
      schema = klass.input_schema
      prop = schema[:properties][:status]

      expect(prop[:enum]).to match_array([1, 2, "", nil])
      # type must accommodate the integer members, the blank "", and nil (allow_blank ⇒ nullable).
      expect(Array(prop[:type])).to include("integer", "string", "null")
    end

    it "still appends \"\" to a numeric allow_blank enum even without an explicit type: (type inferred from members)" do
      klass = Class.new do
        include Axn
        expects :status, inclusion: { in: [10, 20] }, allow_blank: true
      end
      schema = klass.input_schema

      expect(schema[:properties][:status][:enum]).to include("")
      expect(Array(schema[:properties][:status][:type])).to include("integer", "string")
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

    it "appends \"\" to a STRING-typed allow_blank enum (the empty string satisfies the String type, so runtime accepts it)" do
      klass = Class.new do
        include Axn
        expects :status, type: String, inclusion: { in: %w[a b] }, allow_blank: true
        def call; end
      end
      # runtime: "" passes (String type accepts "", inclusion is skipped for the blank value)
      expect(klass.call(status: "")).to be_ok

      schema = klass.input_schema
      prop = schema[:properties][:status]
      expect(prop[:enum]).to include("")
      # already a string type — permits "" without any widening
      expect(Array(prop[:type])).to include("string")
    end
  end

  # Finding #75: allow_blank on the inclusion validator makes ActiveModel SKIP the inclusion check for a
  # blank value, but a CO-DECLARED non-string type: validator still rejects "" (TypeValidator only skips
  # nil for allow_blank, not other blank values). So "" must be added to the enum / the type widened ONLY
  # when the empty string ACTUALLY satisfies the field's full contract — checked via the real validators,
  # not inferred from allow_blank alone. Requiredness/type asserted against verified runtime below.
  describe "a blank-tolerant inclusion field with a co-declared non-string type: does NOT reflect \"\" (Finding #75)" do
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
        def call = expose!(status: 1)
      end
      schema = described_class.build_output(klass.external_field_configs)
      prop = schema[:properties][:status]

      expect(prop[:enum]).not_to include("")
      expect(Array(prop[:type])).not_to include("string")
    end
  end

  # Finding #74: on OUTPUT, enum_for_inclusion adds "" for a blank-tolerant inclusion field (not gated
  # on for_output), so the advertised type must be widened to permit "" for output too — else a
  # consumer validating output type before enum would reject the valid blank. The SAME validators run
  # outbound, so an `exposes` blank-tolerant inclusion accepts "" outbound (verified below), making the
  # enum-and-type consistency the correct behavior in both directions.
  describe "an output blank-tolerant inclusion field keeps its enum and type CONSISTENT (both permit the blank) (Finding #74)" do
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

    it "widens the output type to permit \"\" (consistent with the enum), matching outbound runtime that accepts \"\"" do
      klass = Class.new do
        include Axn
        exposes :status, inclusion: { in: [1, 2] }, allow_blank: true
        def call = expose!(status: 1)
      end
      schema = described_class.build_output(klass.external_field_configs)
      prop = schema[:properties][:status]

      # enum lists the blank (and nil, since allow_blank ⇒ nil-tolerant) alongside the numeric members...
      expect(prop[:enum]).to match_array([1, 2, "", nil])
      # ...and the type must include "string" so the enum's "" isn't rejected by a type-then-enum consumer.
      expect(Array(prop[:type])).to include("integer", "string", "null")
    end
  end
end
