# frozen_string_literal: true

require "axn/testing/spec_helpers"

# `uniqueness:` and a bare `message:` are both in `KNOWN_VALIDATION_KEYS`, so a declaration carrying either
# passed the unknown-key check and declared cleanly — and then raised `ArgumentError: Unknown validator:
# '…Validator'` on EVERY call, at every position and every declared type. ActiveModel resolves a validator by
# `const_get("#{key.to_s.camelize}Validator")` from the class being declared on, and neither name exists:
# uniqueness is an ActiveRecord validator, and `message:` is not one of AM's shared options, so at a field's
# top level it is read as a validator named `message`.
#
# Both are refused at declaration instead. They stay in the known set — as `on:` does for
# `_reject_validator_context_scope!` — so the refusal names the real problem rather than reporting a
# recognized option as unknown.
RSpec.describe "a validator key ActiveModel cannot resolve" do
  # The class `validates` resolves a validator constant from, so this asks the question the runtime asks.
  def resolves_validator?(key)
    Axn::Validation::Base.const_get("#{key.to_s.camelize}Validator")
    true
  rescue NameError
    false
  end

  # The drift guard, and the reason this file's scope is exactly two keys: every OTHER key the field grammar
  # admits resolves to a real validator class. Asserted as a set equality so it catches both directions — a
  # new key added to `KNOWN_VALIDATION_KEYS` with no validator behind it, and one of these three growing one.
  #
  # `:coerce` is the honest third: it never reaches `validates` at all, because `_expand_coerce_sugar!`
  # DELETES the key and folds it into the type bag, so its missing constant is unreachable rather than a hole.
  it "is exactly uniqueness:, message: and coerce: among the keys the grammar admits" do
    keys = Axn::Core::Contract::ClassMethods::KNOWN_VALIDATION_KEYS -
           Axn::Validation::Base.shared_validation_option_keys

    expect(keys.reject { |key| resolves_validator?(key) }).to contain_exactly(:coerce, :message, :uniqueness)
  end

  {
    uniqueness: { spelling: { uniqueness: true }, message: /uniqueness: on .* ActiveRecord/m },
    message: { spelling: { message: "nope" }, message: /message: on .* inside/m },
  }.each do |key, config|
    spelling = config[:spelling]
    pattern = config[:message]

    describe "#{key}:" do
      it "is refused on a top-level expects" do
        expect { build_axn { expects :v, type: String, **spelling } }.to raise_error(ArgumentError, pattern)
      end

      it "is refused on an exposes" do
        expect { build_axn { exposes :v, type: String, **spelling } }.to raise_error(ArgumentError, pattern)
      end

      it "is refused on an on: subfield" do
        expect do
          build_axn do
            expects :parent, type: Hash
            expects :v, on: :parent, type: String, **spelling
          end
        end.to raise_error(ArgumentError, pattern)
      end

      # Labeled by the member's own name rather than as a "shape member", which is what the block form
      # gives all four of these guards: it reaches them through `_parse_field_configs`, where a member is
      # parsed exactly as a field of that name. The raw-member route below is the one that carries the
      # member label, because it calls them itself.
      it "is refused on a block-form shape member" do
        expect do
          build_axn { expects(:h, type: Hash) { field :v, type: String, **spelling } }
        end.to raise_error(ArgumentError, pattern)
      end

      it "is refused on a raw shape: member, which bypasses expects' option handling" do
        member = Axn::Core::Contract::ShapeConfig.new(field: :v, validations: { type: String, **spelling })

        expect do
          build_axn { expects :h, type: Hash, shape: { members: [member], container: Hash } }
        end.to raise_error(ArgumentError, /shape member `v`/)
      end

      it "is refused on an object-backed member, which only the declaration walk sees" do
        member = Class.new do
          define_method(:field) { :v }
          define_method(:validations) { { type: String }.merge(spelling) }
        end.new

        expect do
          build_axn { expects :h, type: Hash, shape: { members: [member], container: Hash } }
        end.to raise_error(ArgumentError, pattern)
      end

      it "is refused through Axn::Factory.build" do
        expect do
          Axn::Factory.build(expects: { v: { type: String, **spelling } }) { nil }
        end.to raise_error(ArgumentError, pattern)
      end

      # The declared type is irrelevant — the constant lookup fails before any value is judged — so the
      # refusal cannot be scoped to a position the way the container-position rule is.
      [String, Integer, Array, Hash, :boolean].each do |type|
        it "is refused on a type: #{type.inspect} field too" do
          expect { build_axn { expects :v, type:, **spelling } }.to raise_error(ArgumentError, pattern)
        end
      end
    end
  end

  # ActiveModel does its `const_get` BEFORE it skips a falsy entry (`next unless options` comes after), so the
  # disabled-validator no-op that saves `confirmation: false` does not save these — measured: `uniqueness:
  # false` raises exactly as `uniqueness: true` does. Hence key presence, not truthiness.
  [true, false, nil].each do |value|
    it "refuses uniqueness: #{value.inspect}, since a falsy entry raises just the same" do
      expect { build_axn { expects :v, type: String, uniqueness: value } }
        .to raise_error(ArgumentError, /uniqueness: on :v/)
    end
  end

  ["nope", nil, false].each do |value|
    it "refuses message: #{value.inspect} on the same rule" do
      expect { build_axn { expects :v, type: String, message: value } }
        .to raise_error(ArgumentError, /message: on :v/)
    end
  end

  it "names uniqueness: first when a declaration carries both, since the two need different fixes" do
    expect { build_axn { expects :v, type: String, uniqueness: true, message: "nope" } }
      .to raise_error(ArgumentError, /uniqueness:/)
  end

  # The controls: `message:` is legal and load-bearing INSIDE a validator's own bag, which is the whole point
  # of the fix the refusal points at. Only the field's (or member's) own top-level key is refused.
  describe "message: inside a validator's own bag stays legal" do
    it "overrides a type: mismatch's wording" do
      action = build_axn { expects :v, type: { klass: String, message: "must be a string" } }

      expect(action.call(v: 1).exception.message).to include("must be a string")
    end

    it "overrides an of: element mismatch's wording" do
      action = build_axn { expects :v, type: Array, of: { klass: String, message: "must be a string" } }

      expect(action.call(v: [1]).exception.message).to include("must be a string")
    end

    # An ActiveModel built-in's bag, which is the third spelling the refusal's message names.
    it "overrides a length: violation's wording" do
      action = build_axn { expects :v, type: String, length: { minimum: 3, message: "too short" } }

      expect(action.call(v: "a").exception.message).to include("too short")
    end

    # NOT a control for `validate:`, which admits `message:` in its bag and ignores it —
    # `ValidateValidator#validate_each` adds the callable's own return value and never reads
    # `options[:message]`. Pinned so the refusal's message is never "helpfully" extended to name it.
    it "is inert inside a validate: bag, which is why the refusal does not point there" do
      action = build_axn { expects :v, validate: { with: ->(value) { "boom" unless value == "a" }, message: "unused" } }

      expect(action.call(v: "b").exception.message).to include("boom")
      expect(action.call(v: "b").exception.message).not_to include("unused")
    end

    it "overrides a member's mismatch inside a shape block" do
      action = build_axn { expects(:h, type: Hash) { field :v, type: { klass: String, message: "must be a string" } } }

      expect(action.call(h: { v: 1 }).exception.message).to include("must be a string")
    end
  end

  # An `of:` bag already refused both, by its own whitelist, before this guard existed — and keeps doing so in
  # its own words. Pinned so the new refusal is not read as the only thing standing between an `of:` bag and
  # `uniqueness:`.
  it "leaves the of: bag's own refusal of uniqueness: alone" do
    expect { build_axn { expects :v, type: Array, of: { klass: String, uniqueness: true } } }
      .to raise_error(ArgumentError, /of: does not support uniqueness:/)
  end

  # The refusal reads the VALIDATIONS bag's keys, never a declared name — so a field or member the author
  # happens to call `message` (or `uniqueness`) is untouched. Worth pinning: `message` is an ordinary field
  # name in axn's own docs, and a guard that confused the two would refuse it everywhere.
  describe "a field or member NAMED message: or uniqueness:" do
    %i[message uniqueness].each do |name|
      it "declares and runs as any other field would (:#{name})" do
        action = build_axn { expects name, type: String }

        expect(action.call(name => "a")).to be_ok
      end

      it "declares as a shape member (:#{name})" do
        action = build_axn { expects(:h, type: Hash) { field name, type: String } }

        expect(action.call(h: { name => "a" })).to be_ok
      end

      it "declares as an on: subfield (:#{name})" do
        action = build_axn do
          expects :parent, type: Hash
          expects name, on: :parent, type: String
        end

        expect(action.call(parent: { name => "a" })).to be_ok
      end
    end
  end

  # `on:` is the neighbouring recognized-but-refused key, and a DECLARATION-level `on:` is axn's subfield
  # parent. Nothing here narrows either.
  it "leaves a subfield parent's on: working" do
    action = build_axn do
      expects :parent, type: Hash
      expects :v, on: :parent, type: String
    end

    expect(action.call(parent: { v: "a" })).to be_ok
  end
end
