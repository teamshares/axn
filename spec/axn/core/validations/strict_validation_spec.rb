# frozen_string_literal: true

require "axn/testing/spec_helpers"

# ActiveModel's `strict:` asks `errors.add` to raise instead of recording the error. Axn already settles a
# contract violation by raising — into the same exception handling — so a strict raise can only arrive at that
# handling having skipped the composition: the user-facing message, the co-occurring violations, and (for a
# class outside StandardError) the guarantee that a call does not raise at all. It names a mode axn does not
# have, and is refused at declaration everywhere a validator's options are written.
RSpec.describe "a `strict:` that asks for ActiveModel's raising mode" do
  # A Hash subclass that denies its own class and hides its keys. ActiveModel classifies with `case`/`when` and
  # reads the plain Hash its `merge` builds, both C-level, so a bag like it still reaches `errors.add` carrying
  # `strict:` — the guard has to agree, or it is one a caller can switch off.
  let(:disowning_hash) do
    Class.new(Hash) do
      def is_a?(klass) = klass == Hash ? false : super
      def key?(_key) = false
    end
  end

  describe "Validation::Base.entry_declares_strict?" do
    it "reads a plain bag carrying strict:" do
      expect(Axn::Validation::Base.entry_declares_strict?({ klass: String, strict: true })).to be(true)
    end

    # ActiveModel reads `strict:` by truthiness, so a falsy one is inert — but `strict: true` is supported
    # nowhere, so the falsy spelling is a switch that cannot be turned on rather than a no-op inside a real
    # option (which is what `confirmation: false`/`coerce: false` are, and why those are left alone).
    it "reads the key rather than its value, so a falsy strict: is still one" do
      expect(Axn::Validation::Base.entry_declares_strict?({ klass: String, strict: false })).to be(true)
      expect(Axn::Validation::Base.entry_declares_strict?({ klass: String, strict: nil })).to be(true)
    end

    it "reads a bag without strict: as unstrict" do
      expect(Axn::Validation::Base.entry_declares_strict?({ klass: String, if: :flag })).to be(false)
    end

    it "reads a non-Hash entry as unstrict" do
      expect(Axn::Validation::Base.entry_declares_strict?(String)).to be(false)
      expect(Axn::Validation::Base.entry_declares_strict?(true)).to be(false)
      expect(Axn::Validation::Base.entry_declares_strict?(nil)).to be(false)
    end

    it "is not fooled by a bag that denies being a Hash and hides its keys" do
      bag = disowning_hash.new
      bag[:strict] = true

      expect(bag.is_a?(Hash)).to be(false) # the lie
      expect(Axn::Validation::Base.normalize_validator_options(bag)).to have_key(:strict) # what AM still sees
      expect(Axn::Validation::Base.entry_declares_strict?(bag)).to be(true)
    end
  end

  # The two tiers ActiveModel composes as `declaration_defaults.merge(entry_options)`. Both are refused, because
  # both reach `errors.add`: a declaration-level `strict:` governs every validator in the call, an entry's own
  # governs that one.
  describe "at the top of a declaration" do
    it "is refused on a top-level expects, naming the field and the fix" do
      expect { build_axn { expects :v, presence: true, strict: true } }
        .to raise_error(ArgumentError, /`strict:` inside the declaration on \["v"\].*axn does not have one.*Drop `strict:`/m)
    end

    it "is refused whatever the value — an option supported only in the off position is not one axn has" do
      expect { build_axn { expects :v, presence: true, strict: false } }
        .to raise_error(ArgumentError, /`strict:` inside the declaration on \["v"\]/)
      expect { build_axn { expects :v, presence: true, strict: ArgumentError } }
        .to raise_error(ArgumentError, /`strict:` inside the declaration on \["v"\]/)
    end

    it "is refused where it is the declaration's ONLY option, which validated nothing at all" do
      expect { build_axn { expects :v, optional: true, strict: true } }
        .to raise_error(ArgumentError, /`strict:` inside the declaration on \["v"\]/)
    end

    it "is refused on an exposes" do
      expect { build_axn { exposes :v, presence: true, strict: true } }
        .to raise_error(ArgumentError, /`strict:` inside the declaration on \["v"\]/)
    end

    it "is refused on a subfield" do
      expect do
        build_axn do
          expects :parent, type: Hash
          expects :zip, on: :parent, presence: true, strict: true
        end
      end.to raise_error(ArgumentError, /`strict:` inside the declaration on \["zip"\]/)
    end

    it "is refused on an ambient subfield" do
      expect { build_axn { expects :cid, on: :ambient_context, presence: true, strict: true } }
        .to raise_error(ArgumentError, /`strict:` inside the declaration on \["cid"\]/)
    end

    it "cannot be routed around as field metadata — registering :strict is refused" do
      expect { Axn::Extensions.config.register_field_metadata_key(:strict) }
        .to raise_error(ArgumentError, /Cannot register :strict as field metadata/)
      expect(Axn::Extensions.config.registered_field_metadata_keys).not_to include(:strict)
    end
  end

  describe "inside a validator's option bag" do
    it "is refused beside an ActiveModel validator, which is where it did raise" do
      expect { build_axn { expects :v, presence: { strict: true } } }
        .to raise_error(ArgumentError, /`strict:` inside presence: on \["v"\]/)
    end

    it "is refused beside one of axn's own validators, where it was dropped" do
      expect { build_axn { expects :v, type: { klass: String, strict: true } } }
        .to raise_error(ArgumentError, /`strict:` inside type: on \["v"\]/)
      expect { build_axn { expects :v, validate: { with: ->(_v) {}, strict: true } } }
        .to raise_error(ArgumentError, /`strict:` inside validate: on \["v"\]/)
    end

    it "names every offender at once, both tiers included" do
      expect { build_axn { expects :v, strict: true, presence: { strict: true }, format: { with: /z/, strict: true } } }
        .to raise_error(ArgumentError, %r{`strict:` inside the declaration / presence: / format: on \["v"\]})
    end
  end

  describe "inside an `of:` bag" do
    it "is refused at an Array's element position" do
      expect { build_axn { expects :v, type: Array, of: { klass: Integer, strict: true } } }
        .to raise_error(ArgumentError, /`strict:` inside an `of:` bag on :v/)
    end

    it "is refused in a bag nested inside a bag, which the entry scan cannot see" do
      expect { build_axn { expects :v, type: Array, of: { klass: Array, of: { klass: Integer, strict: true } } } }
        .to raise_error(ArgumentError, /`strict:` inside an `of:` bag on :v/)
    end

    it "is refused at each of a map's axes" do
      expect { build_axn { expects :v, type: Hash, of: { keys: { klass: Symbol, strict: true } } } }
        .to raise_error(ArgumentError, /`strict:` inside an `of:` bag on :v/)
      expect { build_axn { expects :v, type: Hash, of: { values: { klass: Integer, strict: true } } } }
        .to raise_error(ArgumentError, /`strict:` inside an `of:` bag on :v/)
    end

    # The axis guard refuses the other shared options with a reason particular to the axis ("nothing reads them
    # there"). `strict:` is left out of its set so this message — which names what axn does not have, true at
    # every position — is the one an author sees, exactly as for `on:`.
    it "is reported as strict: rather than as an option the axis would not read" do
      expect { build_axn { expects :v, type: Hash, of: { keys: { klass: Symbol, strict: true } } } }
        .to raise_error(ArgumentError, /\A`strict:` inside an `of:` bag/)
    end

    it "is refused in a bag reached through a shape member" do
      member = Axn::Core::Contract::ShapeConfig.new(field: :a, validations: { type: Array, of: { klass: Integer, strict: true } })

      expect { build_axn { expects :v, type: Hash, shape: { members: [member], container: Hash } } }
        .to raise_error(ArgumentError, /`strict:` inside an `of:` bag on :a/)
    end
  end

  describe "on a shape member" do
    it "is refused on a block-form member" do
      expect { build_axn { expects(:h, type: Hash) { field :x, presence: true, strict: true } } }
        .to raise_error(ArgumentError, /`strict:` inside the declaration on \["x"\]/)
    end

    it "is refused on a raw member, naming the member" do
      member = Axn::Core::Contract::ShapeConfig.new(field: :x, validations: { presence: true, strict: true })

      expect { build_axn { expects :h, type: Hash, shape: { members: [member], container: Hash } } }
        .to raise_error(ArgumentError, /`strict:` inside the declaration on shape member `x`/)
    end

    it "is refused inside a raw member's validator bag" do
      member = Axn::Core::Contract::ShapeConfig.new(field: :x, validations: { presence: { strict: true } })

      expect { build_axn { expects :h, type: Hash, shape: { members: [member], container: Hash } } }
        .to raise_error(ArgumentError, /`strict:` inside presence: on shape member `x`/)
    end
  end

  # What the refusal must not take with it: the shared options axn does support, at the positions that read them.
  describe "what stays legal" do
    it "accepts the other ActiveModel shared options at the declaration" do
      klass = build_axn do
        expects :v, optional: true, length: { minimum: 5 }, if: :never
        def never = false
      end

      expect(klass.call(v: "a")).to be_ok
    end

    it "accepts the other shared options nested in an entry" do
      klass = build_axn do
        expects :v, optional: true, length: { minimum: 5, if: :never, unless: :never, allow_nil: true, allow_blank: true }
        def never = false
      end

      expect(klass.call(v: "a")).to be_ok
    end

    it "accepts the tolerance push-down onto an `of:` bag, which writes into the same bag" do
      expect(build_axn { expects :v, type: Array, of: Integer, optional: true }.call).to be_ok
      expect(build_axn { expects :v, type: Hash, of: { values: Integer }, optional: true }.call).to be_ok
    end

    it "leaves a field NAMED strict alone — a name is not an option key" do
      klass = build_axn { expects :strict, type: :boolean }

      expect(klass.call(strict: true)).to be_ok
    end
  end

  # What the refusal replaces: the violation settles as an ordinary contract failure, which is the outcome
  # `strict:` pre-empted — the user-facing message intact, and every co-occurring violation reported.
  describe "the settlement strict: would have pre-empted" do
    it "keeps a user_facing violation's own message" do
      result = build_axn { expects :v, numericality: { greater_than: 5 }, user_facing: true }.call(v: 1)

      expect(result).not_to be_ok
      expect(result.error).to eq("V must be greater than 5")
    end

    it "reports every co-occurring violation in one exception" do
      result = build_axn { expects :v, numericality: { greater_than: 5 }, format: { with: /zz/ } }.call(v: 1)

      expect(result.exception).to be_a(Axn::InboundValidationError)
      expect(result.exception.message).to include("must be greater than 5").and include("is invalid")
    end
  end

  # ActiveModel's other context option, and axn has no validation contexts at any position. It is inert in the
  # OPPOSITE direction to `on:`: `validate` installs it as `unless: -> { Array(options[:except_on]).include?(
  # validation_context) }`, and axn calls `valid?` with no context, so the exclusion excludes nothing and the
  # entry runs on every call. An option whose only effect is to look like one.
  describe "except_on:" do
    it "is refused on a field's validator entry" do
      expect { build_axn { expects :f, type: String, format: { with: /x/, except_on: :publish } } }
        .to raise_error(ArgumentError, /`except_on:`.*excludes nothing/m)
    end

    it "is refused inside an of: bag" do
      expect { build_axn { expects :f, type: Array, of: { klass: String, except_on: :publish } } }
        .to raise_error(ArgumentError, /`except_on:`.*excludes nothing/m)
    end

    it "is refused at a map axis" do
      expect { build_axn { expects :f, type: Hash, of: { values: { klass: String, except_on: :publish } } } }
        .to raise_error(ArgumentError, /`except_on:`.*excludes nothing/m)
    end

    it "is refused inside a nested bag" do
      expect do
        build_axn { expects :f, type: Array, of: { klass: Array, of: { klass: String, except_on: :publish } } }
      end.to raise_error(ArgumentError, /`except_on:`.*excludes nothing/m)
    end

    it "leaves a supported gate alone" do
      expect { build_axn { expects :f, type: String, format: { with: /x/, if: :flag } } }.not_to raise_error
    end
  end
end
