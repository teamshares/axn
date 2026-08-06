# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Axn class-level schema reflection" do
  let(:klass) do
    Class.new do
      include Axn
      expects :token, type: String, sensitive: true, description: "secret"
      exposes :status, type: String
      def call = expose(status: "ok")
    end
  end

  it "exposes input_schema over expects" do
    expect(klass.input_schema[:properties][:token]).to include(type: "string", description: "secret")
    expect(klass.input_schema[:required]).to eq(["token"])
  end

  it "exposes output_schema over exposes" do
    expect(klass.output_schema[:properties][:status]).to include(type: "string")
  end

  it "does NOT let sensitive: true change the input schema" do
    plain = Class.new do
      include Axn
      expects :token, type: String, description: "secret"
    end
    expect(klass.input_schema).to eq(plain.input_schema)
  end

  describe "optional? agrees with input_schema requiredness for fields without a usable default" do
    [
      { type: Array },
      { type: Array, allow_empty: true },
      { type: Array, optional: true },
      { type: Array, allow_nil: true },
      { type: Array, presence: false },
      { type: Array, optional: true, allow_empty: false },
      { type: String, allow_empty: true },
      # A declared type nil itself satisfies: with the inferred presence check dropped, nothing rejects an
      # omitted value, so both mirrors have to read the field as omittable.
      { type: Object, presence: false },
      { type: NilClass, presence: false },
      { type: [Array, NilClass], presence: false },
      { type: Object }, # the inferred presence check is what rejects nil here, so it stays required
    ].each do |opts|
      it "agrees for #{opts.inspect}" do
        klass = Class.new do
          include Axn
          def call = nil
        end
        klass.expects :v, **opts

        config = klass.internal_field_configs.find { _1.field == :v }
        schema_requires = Array(klass.input_schema[:required]).include?("v")

        expect(config.optional?).to eq(!schema_requires)
      end
    end

    # The agreement above is between the two mirrors; this pins both against the RUNTIME for a type nil
    # itself satisfies, where the type check reports no defect and the inferred presence check is dropped.
    {
      "type: Object" => { type: Object, presence: false },
      "type: NilClass" => { type: NilClass, presence: false },
      "a union with a NilClass member" => { type: [Array, NilClass], presence: false },
      # ActiveModel's confirmation check compares nothing when the confirmation accessor is nil, so it
      # cannot reject a nil (or anything else) on its own.
      "a confirmation check with nothing else rejecting nil" => { presence: false, confirmation: true },
    }.each do |label, opts|
      it "reads #{label} as omittable, which is what the runtime does with an omitted value" do
        klass = Class.new do
          include Axn
          def call = nil
        end
        klass.expects :v, **opts

        expect(klass.call).to be_ok # the runtime accepts the omitted value
        config = klass.internal_field_configs.find { _1.field == :v }
        expect(config.optional?).to be(true)
        expect(Array(klass.input_schema[:required])).not_to include("v")
      end
    end

    # ActiveModel reaches the comparison for a nil on ONE length check only — a `maximum:` with no
    # nil/blank tolerance declared — where the nil measures 0 and clears any maximum. Every other check
    # records its error on a nil whatever its bound, so a floor of 0 rejects a nil while admitting size 0.
    # Each cell pins both mirrors against the runtime.
    {
      "a maximum-only length check" => [{ presence: false, length: { maximum: 3 } }, true],
      "a maximum of 0, which a nil still clears" => [{ presence: false, length: { maximum: 0 } }, true],
      "a length floor of 0, which admits size 0 but not a nil" => [{ presence: false, length: { minimum: 0 } }, false],
      "an exact length of 0, likewise" => [{ presence: false, length: { is: 0 } }, false],
      "a length floor of 1" => [{ presence: false, length: { minimum: 1 } }, false],
      "a maximum whose entry is blank-intolerant, which picks up ActiveModel's own floor" =>
        [{ presence: false, length: { maximum: 3, allow_blank: false } }, false],
      "a maximum whose entry declines nil explicitly" =>
        [{ presence: false, length: { maximum: 3, allow_nil: false } }, false],
      "a range, whose lower bound is a floor" => [{ presence: false, length: { in: 1..3 } }, false],
      "a range starting at 0, whose lower bound is still a floor" => [{ presence: false, length: { within: 0..3 } }, false],
      "a maximum-only check alongside a type that rejects nil" => [{ type: String, length: { maximum: 3 } }, false],
    }.each do |label, (opts, omissible)|
      it "reads #{label} the way the runtime treats an omitted value" do
        klass = Class.new do
          include Axn
          def call = nil
        end
        klass.expects :v, **opts

        expect(klass.call.ok?).to be(omissible)
        config = klass.internal_field_configs.find { _1.field == :v }
        expect(config.optional?).to be(omissible)
        expect(Array(klass.input_schema[:required]).include?("v")).to be(!omissible)
      end
    end

    # ActiveModel's acceptance check skips a nil unless `allow_nil: false`, and even then accepts one that is
    # a MEMBER of the accept set. With no set given the default is ["1", true], which excludes nil, so the
    # absence of a set is not tolerance.
    {
      "an accept set containing nil, with the nil skip disabled" =>
        [{ presence: false, acceptance: { accept: [nil], allow_nil: false } }, true],
      "an accept set without nil" =>
        [{ presence: false, acceptance: { accept: ["1"], allow_nil: false } }, false],
      "a bare acceptance check, which skips nil by default" => [{ presence: false, acceptance: true }, true],
      "the nil skip disabled with no accept set of its own" =>
        [{ presence: false, acceptance: { allow_nil: false } }, false],
      "an accept set that is nil" => [{ presence: false, acceptance: { accept: nil, allow_nil: false } }, false],
      "an empty accept set" => [{ presence: false, acceptance: { accept: [], allow_nil: false } }, false],
      "an accept set containing nil alongside the skip" =>
        [{ presence: false, acceptance: { accept: [nil], allow_nil: true } }, true],
      "an accept set resolved per call, which nothing here can read" =>
        [{ presence: false, acceptance: { accept: -> { [nil] }, allow_nil: false } }, false],
      "an accept set containing nil alongside a type that rejects nil" =>
        [{ type: String, acceptance: { accept: [nil], allow_nil: false } }, false],
    }.each do |label, (opts, omissible)|
      it "reads #{label} the way the runtime treats an omitted value" do
        klass = Class.new do
          include Axn
          def call = nil
        end
        klass.expects :v, **opts

        expect(klass.call.ok?).to be(omissible)
        config = klass.internal_field_configs.find { _1.field == :v }
        expect(config.optional?).to be(omissible)
        expect(Array(klass.input_schema[:required]).include?("v")).to be(!omissible)
      end
    end

    it "keeps a field required when a confirmation check sits alongside something that does reject nil" do
      klass = Class.new do
        include Axn
        def call = nil
      end
      klass.expects :v, type: String, confirmation: true

      expect(klass.call).not_to be_ok
      config = klass.internal_field_configs.find { _1.field == :v }
      expect(config.optional?).to be(false)
      expect(Array(klass.input_schema[:required])).to include("v")
    end

    it "keeps a nil-rejecting type required, the inferred presence check or not" do
      klass = Class.new do
        include Axn
        def call = nil
      end
      klass.expects :v, type: Array, presence: false

      expect(klass.call).not_to be_ok
      config = klass.internal_field_configs.find { _1.field == :v }
      expect(config.optional?).to be(false)
      expect(Array(klass.input_schema[:required])).to include("v")
    end

    # An omitted call resolves the default, so a default the field's own checks reject makes the key
    # un-omittable — whatever else the field tolerates. Each of these fails on an omitted call, so none may
    # be advertised as omissible.
    {
      "an empty default the emptiness check rejects, under a nil-tolerance" =>
        { type: Array, optional: true, allow_empty: false, default: [] },
      "an empty String default under a nil-tolerance" =>
        { type: String, optional: true, allow_empty: false, default: "" },
      "an empty default on a type that takes no presence check" =>
        { type: :params, allow_empty: false, default: {} },
      "an empty Set default, a container the axis is declared on" =>
        { type: Set, optional: true, allow_empty: false, default: Set.new },
    }.each do |label, opts|
      it "requires the key for #{label}" do
        klass = Class.new do
          include Axn
          def call = nil
        end
        klass.expects :v, **opts

        expect(klass.call).not_to be_ok # the omitted call resolves the default and fails
        expect(Array(klass.input_schema[:required])).to include("v")
      end
    end

    # A container SUBCLASS is judged by whose `empty?` would answer. One that INHERITS the built-in's is Ruby's
    # own code, safe to run inside a verdict, and its empty instance is as empty as the built-in's. One that
    # OVERRIDES it is the caller's code, which reflection must not run — so it is simply not recognized here,
    # which is also what matches the runtime, since that same override is what the emptiness check will ask.
    describe "a container subclass as a default" do
      def field_required?(**opts)
        klass = Class.new do
          include Axn
          def call = nil
        end
        klass.expects :v, **opts
        [klass.call.ok?, Array(klass.input_schema[:required]).include?("v")]
      end

      {
        "an Array subclass" => [Class.new(Array), Class.new(Array) { def empty? = false }],
        "a Hash subclass" => [Class.new(Hash), Class.new(Hash) { def empty? = false }],
        "a String subclass" => [Class.new(String), Class.new(String) { def empty? = false }],
        "a Set subclass" => [Class.new(Set), Class.new(Set) { def empty? = false }],
      }.each do |label, (inheriting, overriding)|
        it "requires the key for an empty #{label} that inherits empty?" do
          runtime_ok, required = field_required?(type: inheriting, optional: true, allow_empty: false, default: inheriting.new)

          expect(runtime_ok).to be(false) # the omitted call resolves the default and fails
          expect(required).to be(true)
        end

        # Pinned so a "simplification" to "treat anything unrecognized as unusable" cannot land: the runtime
        # ACCEPTS this omitted call, and marking the key required would be stricter than the contract.
        it "leaves the key omittable for #{label} that overrides empty?" do
          runtime_ok, required = field_required?(type: overriding, optional: true, allow_empty: false, default: overriding.new)

          expect(runtime_ok).to be(true)
          expect(required).to be(false)
        end
      end
    end

    # A default the field ACCEPTS still relaxes the key, and emptiness is `empty?`: a whitespace-only String
    # default passes the emptiness check, so it keeps working.
    {
      "a non-empty default alongside allow_empty: false" =>
        { type: Array, optional: true, allow_empty: false, default: [1] },
      "a whitespace-only String default, which is blank but not empty" =>
        { type: String, optional: true, allow_empty: false, default: " " },
      "a non-empty default on a type that takes no presence check" =>
        { type: :params, allow_empty: false, default: { a: 1 } },
      "an empty default with no emptiness check to reject it" =>
        { type: Array, optional: true, default: [] },
      "a non-empty Set default" =>
        { type: Set, optional: true, allow_empty: false, default: Set["x"] },
    }.each do |label, opts|
      it "still omits the key for #{label}" do
        klass = Class.new do
          include Axn
          def call = nil
        end
        klass.expects :v, **opts

        expect(klass.call).to be_ok
        expect(Array(klass.input_schema[:required])).not_to include("v")
      end
    end

    # The one divergence: `optional?` answers only the nil-tolerance question, while schema requiredness
    # also admits a usable default. Pinned so the scope of the agreement above stays explicit.
    it "reports a defaulted field non-optional though the schema omits it from required" do
      klass = Class.new do
        include Axn
        def call = nil
      end
      klass.expects :v, type: Integer, default: 1

      config = klass.internal_field_configs.find { _1.field == :v }
      expect(config.optional?).to be(false)
      expect(Array(klass.input_schema[:required])).not_to include("v")
    end

    # The mirror image of that divergence, from the same cause: `optional?` reads the validator set alone, so
    # a nil-tolerant field reports optional even where a declared default its own checks reject means no
    # omitted (or explicitly null) call can pass. The schema, which does read the default, requires the key —
    # and matches the runtime.
    it "reports a nil-tolerant field optional though its rejected default makes the schema require it" do
      klass = Class.new do
        include Axn
        def call = nil
      end
      klass.expects :v, type: Array, optional: true, allow_empty: false, default: []

      expect(klass.call).not_to be_ok
      expect(klass.call(v: nil)).not_to be_ok
      config = klass.internal_field_configs.find { _1.field == :v }
      expect(config.optional?).to be(true)
      expect(Array(klass.input_schema[:required])).to include("v")
    end

    # A Proc default is unknowable at declaration (schema resolves it toward required) and a blank literal
    # default is rejected by the default `presence: true`, so neither widens the divergence above.
    {
      "a Proc default" => { type: Integer, default: -> { 1 } },
      "a blank literal default" => { type: Array, default: [] },
    }.each do |label, opts|
      it "still agrees for #{label}, which the schema cannot use to omit the field" do
        klass = Class.new do
          include Axn
          def call = nil
        end
        klass.expects :v, **opts

        config = klass.internal_field_configs.find { _1.field == :v }
        expect(config.optional?).to be(false)
        expect(Array(klass.input_schema[:required])).to include("v")
      end
    end
  end

  # THE nil axis across axn's whole validator vocabulary: every key a declaration may carry, in the option
  # shapes that change the answer. Each row declares the validator with the inferred presence check
  # suppressed, so the validator under test is the only thing that could reject an omitted value, then holds
  # the runtime, `optional?` and schema requiredness to one answer. It exists to fail when a validator or an
  # option shape is added whose nil behavior nobody has judged — the allowlist behind `optional?` has one row
  # per validator, and a missing row is silent until something like this walks the vocabulary.
  # ActiveModel applies a DECLARATION-WIDE `allow_nil:`/`allow_blank:` to every validator in the `validates`
  # call, so an entry that carries none of its own still runs tolerant. A raw shape member is where that
  # spelling survives to be judged — a field declaration pushes the tolerance down into each entry before it
  # is ever read — so each row here holds the runtime, the member's `optional?` and the emitted property to
  # one answer.
  describe "a declaration-wide tolerance on a raw shape member" do
    def shaped(member_validations)
      member = Axn::Core::Contract::ShapeConfig.new(field: :name, validations: member_validations)
      klass = Class.new do
        include Axn
        def call = nil
      end
      klass.expects :payload, type: Hash, shape: { members: [member] }
      klass
    end

    {
      "a hash-level allow_nil: true" => [{ type: String, allow_nil: true }, true],
      "a hash-level allow_blank: true" => [{ type: String, allow_blank: true }, true],
      "a hash-level allow_nil: false" => [{ type: String, allow_nil: false }, false],
      "a hash-level allow_blank: false" => [{ type: String, allow_blank: false }, false],
      "an entry-level tolerance" => [{ type: { klass: String, allow_nil: true } }, true],
      "an entry-level allow_nil: false over a hash-level true" =>
        [{ type: { klass: String, allow_nil: false }, allow_nil: true }, false],
      "no tolerance at all" => [{ type: String }, false],
      # A declaration-wide `on:` is merged into every validator, and axn validates with no context — so no
      # spelling of it can match and nothing in the declaration runs at all.
      "a hash-level on: naming a context" => [{ type: String, on: :publish }, true],
      "a hash-level on: nil" => [{ type: String, on: nil }, true],
      "a hash-level on: false" => [{ type: String, on: false }, true],
      "a hash-level on: []" => [{ type: String, on: [] }, true],
    }.each do |label, (member_validations, tolerant)|
      it "reads #{label} the way the runtime treats a nil member" do
        klass = shaped(member_validations)

        expect(klass.call(payload: { name: nil }).ok?).to be(tolerant)

        member = klass.internal_field_configs.find { _1.field == :payload }.validations.dig(:shape, :members).first
        expect(member.optional?).to be(tolerant)

        prop = klass.input_schema.dig(:properties, :payload)
        expect(Array(prop[:required]).include?("name")).to be(!tolerant)
        expect(Array(prop.dig(:properties, :name, :type)).include?("null")).to be(tolerant)
      end
    end

    # A declaration-wide `allow_blank:` reaches the length validator too, so the floor it names is one the
    # contract does not enforce and the schema must not advertise.
    it "emits no floor for a length: the declaration tolerates blank around" do
      klass = shaped(type: String, length: { minimum: 3 }, allow_blank: true)

      expect(klass.call(payload: { name: "" })).to be_ok
      prop = klass.input_schema.dig(:properties, :payload, :properties, :name)
      expect(prop).not_to have_key(:minLength)
    end

    it "keeps the floor when the declaration tolerates nothing" do
      klass = shaped(type: String, length: { minimum: 3 })

      expect(klass.call(payload: { name: "" })).not_to be_ok
      expect(klass.input_schema.dig(:properties, :payload, :properties, :name, :minLength)).to eq(3)
    end

    # The strip that discards shared keys before judging is what keeps a shared-ONLY hash from reading as a
    # validator, which would have `validates` raise for a set with nothing in it.
    it "still reads a validations hash carrying only shared options as no validators at all" do
      expect(Axn::Validation::Base.validator_entries(strict: true)).to eq({})
      expect(Axn::Validation::Base.nil_accepted?(strict: true)).to be(true)
    end
  end

  describe "the nil axis across every validator axn accepts" do
    def declare(**opts)
      klass = Class.new do
        include Axn
        def call = nil
      end
      klass.expects :v, **opts
      klass
    end

    {
      # ActiveModel's own
      "absence" => [{ absence: true }, true],
      "acceptance, bare" => [{ acceptance: true }, true],
      "acceptance, an accept set containing nil" => [{ acceptance: { accept: [nil], allow_nil: false } }, true],
      "acceptance, an accept set without nil" => [{ acceptance: { accept: ["1"], allow_nil: false } }, false],
      "acceptance, no accept set of its own" => [{ acceptance: { allow_nil: false } }, false],
      "comparison, other_than" => [{ comparison: { other_than: 0 } }, false],
      "comparison, greater_than" => [{ comparison: { greater_than: 0 } }, false],
      "confirmation" => [{ confirmation: true }, true],
      "exclusion, a set without nil" => [{ exclusion: [1, 2] }, true],
      "exclusion, a set containing nil" => [{ exclusion: [nil, 1] }, false],
      "format with:, a regexp that rejects the empty string" => [{ format: { with: /x/ } }, false],
      "format with:, a regexp that matches the empty string" => [{ format: { with: /\A\z/ } }, true],
      "format with:, a regexp that matches anything" => [{ format: { with: /\A.*\z/ } }, true],
      "format without:, a regexp that rejects the empty string" => [{ format: { without: /x/ } }, true],
      "format without:, a regexp that matches the empty string" => [{ format: { without: /\A\z/ } }, false],
      "format without:, a regexp that matches anything" => [{ format: { without: // } }, false],
      "format with:, resolved per call" => [{ format: { with: ->(_record) { /x/ } } }, false],
      "format, the bare shorthand ActiveModel reads as with:" => [{ format: /\A\z/ }, true],
      "inclusion, a set containing nil" => [{ inclusion: [nil, 1] }, true],
      "inclusion, a Hash set keyed by nil" => [{ inclusion: { in: { nil => :allowed } } }, true],
      "inclusion, a Hash set without a nil key" => [{ inclusion: { in: { "a" => 1 } } }, false],
      "exclusion, a Hash set keyed by nil" => [{ exclusion: { in: { nil => 1 } } }, false],
      "exclusion, a Hash set without a nil key" => [{ exclusion: { in: { "a" => 1 } } }, true],
      "inclusion, a set without nil" => [{ inclusion: [1, 2] }, false],
      "length, maximum only" => [{ length: { maximum: 3 } }, true],
      "length, a floor" => [{ length: { minimum: 1 } }, false],
      "length, a range" => [{ length: { in: 1..3 } }, false],
      "numericality" => [{ numericality: true }, false],
      "presence, true" => [{ presence: true }, false],
      "presence, false" => [{ presence: false }, true],
      # axn's own
      "type that rejects nil" => [{ type: String }, false],
      "type that nil satisfies" => [{ type: Object }, true],
      "of" => [{ type: Array, of: Integer }, false],
      "shape" => [{ type: Hash, shape: { members: [] } }, false],
    }.each do |label, (validator_opts, omissible)|
      it "reads #{label} the way the runtime treats an omitted value" do
        opts = validator_opts.key?(:presence) ? validator_opts : { presence: false, **validator_opts }
        klass = declare(**opts)

        expect(klass.call.ok?).to be(omissible)
        config = klass.internal_field_configs.find { _1.field == :v }
        expect(config.optional?).to be(omissible)
        expect(Array(klass.input_schema[:required]).include?("v")).to be(!omissible)
      end
    end

    # The emptiness check needs no presence suppression to be the interesting entry: `:params` takes no
    # inferred presence check of its own, and pairing one with `allow_empty: false` is a declared
    # contradiction. Its own entry skips a nil (the nil axis is the type check's business), so the type is
    # what decides here.
    it "reads the emptiness check allow_empty: false installs the way the runtime treats an omitted value" do
      klass = declare(type: :params, allow_empty: false)

      expect(klass.call).not_to be_ok
      config = klass.internal_field_configs.find { _1.field == :v }
      expect(config.optional?).to be(false)
      expect(Array(klass.input_schema[:required])).to include("v")
    end

    # A `model:` field is keyed in the schema by the id token it resolves from, so its requiredness is
    # asserted against that key rather than the field name.
    it "reads model: the way the runtime treats an omitted value" do
      finder = Class.new { def self.find(_id) = new }
      klass = declare(presence: false, model: { klass: finder, finder: :find })

      expect(klass.call).not_to be_ok
      config = klass.internal_field_configs.find { _1.field == :v }
      expect(config.optional?).to be(false)
      expect(Array(klass.input_schema[:required])).to eq(["v_id"])
    end

    # A custom `validate:` is user code, which reflection may never run — so its verdict on a nil is unknown,
    # and unknown resolves to nil-REJECTING. The runtime here accepts the omitted value (the block returns no
    # error), leaving both mirrors deliberately stricter than the runtime: the safe direction, and the same
    # trade the Proc-default divergence makes.
    it "reads a custom validate: as nil-rejecting, which is stricter than its runtime" do
      klass = declare(presence: false, validate: ->(_value) {}) # no error returned: the value passes

      expect(klass.call).to be_ok
      config = klass.internal_field_configs.find { _1.field == :v }
      expect(config.optional?).to be(false)
      expect(Array(klass.input_schema[:required])).to include("v")
    end

    # `uniqueness:` is accepted as a declaration key but ActiveModel ships no such validator — it is
    # ActiveRecord's — so the check raises when the validator set is built rather than judging a nil.
    it "reaches ActiveModel's unknown-validator error for uniqueness:" do
      klass = declare(presence: false, uniqueness: true)

      expect(klass.call.exception).to be_a(ArgumentError)
      expect(klass.call.exception.message).to include("Unknown validator")
    end
  end

  describe "unrepresentable-subfield omission warning" do
    let(:deep_klass) do
      Class.new do
        include Axn
        expects :user, model: { klass: Struct.new(:id, :profile), finder: :find }
        expects :name, on: "user.profile", type: String # deep under a model: parent — no object representation
      end
    end

    it "warns, naming the omitted field" do
      expect(Axn.config.logger).to receive(:warn).with(/input_schema omits deep subfield.*model: or non-object parent.*\bname\b/m)
      deep_klass.input_schema
    end

    it "warns at most once per class across repeated input_schema calls" do
      expect(Axn.config.logger).to receive(:warn).once
      3.times { deep_klass.input_schema }
    end

    it "does not warn for a representable deep chain (object-shaped parents)" do
      representable = Class.new do
        include Axn
        expects :payload, type: Hash
        expects :meta, on: :payload, type: Hash
        expects :id, on: :meta, type: Integer
      end
      expect(Axn.config.logger).not_to receive(:warn)
      representable.input_schema
    end

    it "does not warn when every subfield is shallow" do
      shallow_klass = Class.new do
        include Axn
        expects :payload, type: Hash
        expects :meta, on: :payload, type: String
      end
      expect(Axn.config.logger).not_to receive(:warn)
      shallow_klass.input_schema
    end
  end

  describe "emptiness constraints" do
    def schema_for(**opts)
      klass = Class.new do
        include Axn
        def call = nil
      end
      klass.expects :v, **opts
      klass.input_schema.dig(:properties, :v)
    end

    def output_schema_for(**opts)
      klass = Class.new do
        include Axn
        def call = nil
      end
      klass.exposes :v, **opts
      klass.output_schema.dig(:properties, :v)
    end

    it "emits minItems for a required Array" do
      expect(schema_for(type: Array)).to include(type: "array", minItems: 1)
    end

    it "emits minProperties for a required Hash" do
      expect(schema_for(type: Hash)).to include(type: "object", minProperties: 1)
    end

    it "emits minLength for a required String" do
      expect(schema_for(type: String)).to include(type: "string", minLength: 1)
    end

    it "omits the constraint when the field allows empty" do
      expect(schema_for(type: Array, allow_empty: true)).to eq(type: "array")
    end

    it "omits the constraint when the field is optional" do
      expect(schema_for(type: Array, optional: true)).not_to have_key(:minItems)
    end

    it "emits it for the may-be-nil-but-not-empty cell alongside a nullable type" do
      prop = schema_for(type: Array, optional: true, allow_empty: false)
      expect(prop[:type]).to eq(%w[array null])
      expect(prop[:minItems]).to eq(1)
    end

    it "honors an author-declared length minimum" do
      expect(schema_for(type: Array, length: { minimum: 3 })[:minItems]).to eq(3)
    end

    # Every spelling ActiveModel resolves into a floor, read the same way it reads them — otherwise a
    # field that rejects an empty value at runtime advertises no floor (or a looser one) in its schema.
    describe "every length: spelling that names a floor" do
      it "reads an exact size" do
        expect(schema_for(type: Array, length: { is: 2 })[:minItems]).to eq(2)
        expect(schema_for(type: Array, allow_nil: true, length: { is: 2 })[:minItems]).to eq(2)
      end

      it "reads a range's lower bound" do
        expect(schema_for(type: Array, length: { in: 2..5 })[:minItems]).to eq(2)
        expect(schema_for(type: Array, length: { within: 2..5 })[:minItems]).to eq(2)
      end

      it "reads ActiveModel's implicit floor for a blank-intolerant entry with no floor of its own" do
        # `allow_nil: true` pushes `allow_blank: false` into the entry, which is what makes LengthValidator
        # add `minimum: 1` — so the runtime rejects [] and the schema has to say so.
        prop = schema_for(type: Array, allow_nil: true, length: { maximum: 3 })
        expect(prop[:minItems]).to eq(1)
      end

      it "falls back to the presence floor for a per-call minimum it cannot resolve" do
        expect(schema_for(type: Array, length: { minimum: :cap })[:minItems]).to eq(1)
      end

      it "falls back to the presence floor for an unemittable infinite minimum" do
        expect(schema_for(type: Array, length: { minimum: Float::INFINITY })[:minItems]).to eq(1)
      end

      # Only a floor of a positive whole size is carried, and the emptiness reconciliation leans on exactly
      # that same set — so no floor the runtime honors goes unadvertised here.
      # ActiveModel expands a bare `length: 2..5` into `in: 2..5` and enforces the floor, so the schema has to
      # read the entry in that expanded form however the author typed it. A gated type entry is one way an
      # entry reaches reflection exactly as written, since the nil-skip pass that would otherwise normalize it
      # stands down when the type check can be skipped.
      it "reads a bare Range shorthand under a gated type, which ActiveModel expands into a floor" do
        opts = { type: { klass: String, if: -> { true } }, length: 2..5 }
        klass = Class.new do
          include Axn
          def call = nil
        end
        klass.expects :v, **opts

        expect(klass.call(v: "a")).not_to be_ok # ActiveModel enforces the expanded floor
        expect(klass.call(v: "ab")).to be_ok
        expect(schema_for(**opts)[:minLength]).to eq(2)
      end

      # A type nil itself satisfies leaves its siblings as written for the same reason a gated one does.
      it "reads a bare Range shorthand under a nil-admitting type" do
        expect(schema_for(type: Object, length: 2..5)[:minLength]).to eq(2)
        expect(schema_for(type: { klass: String, if: -> { true } }, length: 2...5)[:minLength]).to eq(2)
      end

      it "reads a bare Range shorthand identically wherever the entry reaches reflection normalized" do
        expect(schema_for(type: String, length: 2..5)[:minLength]).to eq(2)
        expect(schema_for(type: String, optional: true, length: 2..5)[:minLength]).to be_nil
      end

      # The emptiness axis reads the same expanded form, so its deferral and the emitted floor agree on a
      # shorthand exactly as they do on the long form.
      it "keeps the emptiness axis and the emitted floor agreeing on a bare shorthand" do
        opts = { type: String, optional: true, allow_empty: false, length: 2..5 }
        klass = Class.new do
          include Axn
          def call = nil
        end
        klass.expects :v, **opts

        expect(klass.call(v: nil)).to be_ok
        expect(klass.call(v: "")).not_to be_ok
        expect(klass.call(v: "a")).not_to be_ok
        expect(klass.call(v: "ab")).to be_ok
        expect(schema_for(**opts)).to eq(type: %w[string null], minLength: 2)
      end

      it "carries no floor for a bare shorthand that names none, as ActiveModel names none either" do
        expect(schema_for(type: String, length: 3)[:minLength]).to eq(1) # the presence floor
      end

      it "carries no fractional floor, which ActiveModel refuses as a bound anyway" do
        expect(schema_for(type: Array, length: { minimum: 0.5 })[:minItems]).to eq(1) # the presence floor
      end

      it "carries the flag's own floor when the author's floor has no whole size to carry" do
        expect(schema_for(type: Array, optional: true, allow_empty: false, length: { minimum: Float::INFINITY }))
          .to eq(type: %w[array null], minItems: 1)
        expect(schema_for(type: Array, optional: true, allow_empty: false, length: { minimum: 0.5 }))
          .to eq(type: %w[array null], minItems: 1)
      end

      it "emits no floor for a maximum that admits an empty value" do
        expect(schema_for(type: Array, optional: true, length: { maximum: 3 })).not_to have_key(:minItems)
      end
    end

    # A gated entry MAY be open on a given call, so its floor is emitted as if the gate were open —
    # static-maximal, which can leave the input schema stricter than a closed-gate runtime but never looser,
    # and is the policy for every gated constraint here.
    describe "an entry a gate may skip" do
      it "emits the floor of a gated presence:, which a call may run" do
        expect(schema_for(type: Array, presence: { if: :flag })).to eq(type: "array", minItems: 1)
      end

      it "emits the floor of a gated length:, which a call may run" do
        expect(schema_for(type: Array, presence: false, length: { minimum: 3, if: :flag })).to eq(type: "array", minItems: 3)
      end
    end

    # A shape block is what establishes that a custom class or module is an OBJECT — before it runs the
    # property carries the permissive fallback type — so the floor has to be derived from the type the
    # property ends up with, or it lands under a key that cannot express it.
    describe "on a shaped type whose JSON type the shape establishes" do
      let(:bag) do
        Class.new do
          def self.name = "Bag"
          def initialize(members = {}) = @members = members
          def empty? = @members.empty?
          def x = @members[:x]
        end
      end

      def shaped_schema_for(**opts, &blk)
        klass = Class.new do
          include Axn
          def call = nil
        end
        klass.expects(:v, **opts, &blk)
        klass.input_schema.dig(:properties, :v)
      end

      it "floors the object by its own key, with no key from the pre-shape type left behind" do
        klass = bag
        prop = shaped_schema_for(type: klass) { field :x, type: String, method_call: true }

        expect(prop[:type]).to eq("object")
        expect(prop).not_to have_key(:minLength) # a string floor over an object constrains nothing
        expect(prop[:minProperties]).to eq(1)
      end

      it "carries an author-declared floor under that same key" do
        klass = bag
        prop = shaped_schema_for(type: klass, length: { minimum: 2 }) { field :x, type: String, method_call: true }

        expect(prop).not_to have_key(:minLength)
        expect(prop[:minProperties]).to eq(2)
      end

      it "keeps a shaped Hash flooring exactly as it does without the shape" do
        prop = shaped_schema_for(type: Hash) { field :x, type: String }

        expect(prop).to include(type: "object", minProperties: 1)
        expect(prop).not_to have_key(:minLength)
      end

      it "keeps a shaped Array flooring by items count" do
        prop = shaped_schema_for(type: Array, of: Hash) { field :x, type: String }

        expect(prop[:minItems]).to eq(1)
        expect(prop[:items]).to include(type: "object")
      end

      it "leaves an unshaped unmappable type on its permissive fallback" do
        expect(shaped_schema_for(type: bag)).to eq(type: "string", minLength: 1)
        expect(schema_for(type: Set)).to eq(type: "string", minLength: 1)
      end
    end

    it "emits nothing for a type with no empty state" do
      expect(schema_for(type: Integer)).not_to have_key(:minLength)
    end

    # A union emits `anyOf` instead of a single `type:`, and the validators reject empty whichever branch
    # the value takes — so the floor has to follow the type into every branch that can hold an empty value.
    describe "on a union's anyOf branches" do
      it "floors every size-bearing branch of a required union" do
        expect(schema_for(type: [Hash, Array])).to eq(
          anyOf: [{ type: "object", minProperties: 1 }, { type: "array", minItems: 1 }],
        )
      end

      it "leaves a branch with no empty state unconstrained" do
        expect(schema_for(type: [Integer, Array])).to eq(
          anyOf: [{ type: "integer" }, { type: "array", minItems: 1 }],
        )
      end

      it "floors no branch at all when the union tolerates blank" do
        expect(schema_for(type: [Hash, Array], allow_blank: true)).to eq(
          anyOf: [{ type: "object" }, { type: "array" }, { type: "null" }],
        )
      end

      it "never floors the nullability branch" do
        expect(schema_for(type: [Hash, Array], optional: true, allow_empty: false)).to eq(
          anyOf: [{ type: "object", minProperties: 1 }, { type: "array", minItems: 1 }, { type: "null" }],
        )
      end
    end

    # Never emit a constraint the contract accepts (the rule the uuid-format relaxation follows): a
    # blank-tolerant entry admits the empty value, and "empty or at least N" is not expressible as a floor.
    describe "blank tolerance" do
      it "emits no floor for an explicit length minimum the field tolerates blank around" do
        expect(schema_for(type: String, length: { minimum: 3 }, allow_blank: true)).to eq(type: %w[string null])
      end

      it "emits no floor for a blank-tolerant presence check" do
        expect(schema_for(type: String, presence: { allow_blank: true })).to eq(type: "string")
      end

      it "keeps the floor for allow_empty: false, whose own check is explicitly blank-intolerant" do
        expect(schema_for(type: Array, allow_nil: true, allow_empty: false)).to eq(type: %w[array null], minItems: 1)
      end

      # Blank-tolerance on ONE entry says an empty value stands THAT entry aside — not that an empty value
      # gets through. Where something else rejects every empty value, "empty or at least 3" is not what the
      # contract admits: only 3 or more is, and the floor is exact.
      describe "a blank-tolerant length: alongside a check that rejects every empty value" do
        def action_for(**opts)
          klass = Class.new do
            include Axn
            def call = nil
          end
          klass.expects :v, **opts
          klass
        end

        it "keeps the floor when the inferred presence check rejects the empty value" do
          opts = { type: String, length: { minimum: 3, allow_blank: true } }
          action = action_for(**opts)
          expect(action.call(v: "")).not_to be_ok
          expect(action.call(v: "a")).not_to be_ok
          expect(action.call(v: "abc")).to be_ok
          expect(schema_for(**opts)).to eq(type: "string", minLength: 3)
        end

        it "keeps the floor when the emptiness check rejects the empty value" do
          opts = { type: String, optional: true, allow_empty: false, length: { minimum: 3, allow_blank: true } }
          expect { action_for(**opts) }.to raise_error(ArgumentError, /length:.*allow_empty: false/m)
        end

        it "keeps the floor when an explicit presence: rejects the empty value" do
          opts = { type: String, presence: true, length: { minimum: 3, allow_blank: true } }
          action = action_for(**opts)
          expect(action.call(v: "")).not_to be_ok
          expect(action.call(v: "a")).not_to be_ok
          expect(schema_for(**opts)).to eq(type: "string", minLength: 3)
        end

        it "emits no floor when nothing else rejects the empty value" do
          opts = { type: String, optional: true, length: { minimum: 3, allow_blank: true } }
          expect(action_for(**opts).call(v: "")).to be_ok
          expect(schema_for(**opts)).to eq(type: %w[string null])
        end

        it "emits no floor when the only other check is one that is switched off" do
          opts = { type: String, presence: false, length: { minimum: 3, allow_blank: true } }
          expect(action_for(**opts).call(v: "")).to be_ok
          expect(schema_for(**opts)).to eq(type: "string")
        end
      end
    end

    # Wherever `allow_empty: false` is honored at runtime the floor has to follow, or the schema goes
    # back to advertising the empty value the contract rejects.
    describe "alongside an author-declared length: under a nil-tolerance" do
      it "floors a length: that only caps the size" do
        expect(schema_for(type: Array, optional: true, allow_empty: false, length: { maximum: 3 }))
          .to eq(type: %w[array null], minItems: 1)
      end

      it "floors an explicitly disabled length:" do
        expect(schema_for(type: Array, optional: true, allow_empty: false, length: false))
          .to eq(type: %w[array null], minItems: 1)
      end

      it "carries the author's own floor, which optional: alone would have dropped" do
        expect(schema_for(type: Array, optional: true, allow_empty: false, length: { minimum: 3 }))
          .to eq(type: %w[array null], minItems: 3)
      end

      it "still drops the floor when allow_empty: is not declared at all" do
        expect(schema_for(type: Array, optional: true, length: { minimum: 3 })).to eq(type: %w[array null])
      end
    end

    it "floors a :params field under allow_empty: false, which takes no default presence check" do
      expect(schema_for(type: :params, allow_empty: false)).to eq(type: "object", minProperties: 1)
    end

    it "leaves a :params field floorless under allow_empty: true" do
      expect(schema_for(type: :params, allow_empty: true)).to eq(type: "object")
    end

    # Outbound is honest in the same direction: exposure validators do run, so a required exposure that
    # rejects empty never emits an empty value — unless a gate could skip the check that promises it.
    describe "on output_schema" do
      it "emits the floor for a required collection" do
        expect(output_schema_for(type: Array)).to eq(type: "array", minItems: 1)
      end

      it "floors a union's branches outbound too" do
        expect(output_schema_for(type: [Hash, Array])).to eq(
          anyOf: [{ type: "object", minProperties: 1 }, { type: "array", minItems: 1 }],
        )
      end

      it "omits the floor when a nested gate could skip the presence check that promises it" do
        expect(output_schema_for(type: Array, presence: { if: :flag })).to eq(type: "array")
      end
    end
  end
end
