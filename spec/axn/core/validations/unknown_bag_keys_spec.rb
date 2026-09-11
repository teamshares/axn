# frozen_string_literal: true

require "axn/testing/spec_helpers"

# `model:`, `type:`, `validate:` and `shape:` are axn's own grammar, exactly as `of:` is — each bag reaches
# its validator as an `EachValidator` options hash, which reads the keys it knows and drops the rest, so an
# unrecognized key declared cleanly, constrained nothing, and let every value through (PRO-3387):
#
#   k = Class.new { include Axn; expects :lead, model: { bogus: 1 }; def call; end }
#   k.internal_field_configs.first.validations[:model]  # => {:bogus=>1, :klass=>Lead, :finder=>:find}
#   k.call(lead_id: 3).ok?                               # => true
#
# `of:` already refused this (`_reject_unknown_bag_keys!`); this closes the identical hole in its three
# siblings and in the `shape:` node itself. ActiveModel's OWN bags (`length:`, `numericality:`, `format:`,
# `inclusion:`, …) are deliberately NOT covered here — that vocabulary belongs to ActiveModel, is read ad hoc
# per validator, and moves between the two ActiveModel lines the gemspec supports, so closing it is a
# separate ticket.
RSpec.describe "an unknown key in an axn-owned validator bag" do
  def lead_class
    Struct.new(:id) { def self.find(id) = new(id) }
  end

  describe "model:" do
    it "is refused on a top-level expects" do
      klass = lead_class

      expect { build_axn { expects :lead, model: { klass:, bogus: 1 } } }
        .to raise_error(ArgumentError,
                        "model: does not support bogus: (supported: klass:, finder:, not_found_on:, id_type:, " \
                        "message:, if:, unless:, allow_blank:, allow_nil:)")
    end

    it "is refused on an exposes" do
      klass = lead_class

      expect { build_axn { exposes :lead, model: { klass:, bogus: 1 } } }
        .to raise_error(ArgumentError, /model: does not support bogus:/)
    end

    it "is refused on an on: subfield" do
      klass = lead_class

      expect do
        build_axn do
          expects :params, type: Hash
          expects :lead, on: :params, model: { klass:, bogus: 1 }
        end
      end.to raise_error(ArgumentError, /model: does not support bogus:/)
    end

    it "is refused through Axn::Factory.build" do
      klass = lead_class

      expect { Axn::Factory.build(expects: { lead: { model: { klass:, bogus: 1 } } }) { nil } }
        .to raise_error(ArgumentError, /model: does not support bogus:/)
    end

    # The two spellings the ticket measured: a typo'd finder that silently kept the default, and a typo'd
    # klass that silently fell back to field-name inference.
    it "refuses the ticket's exact typo: fnder:" do
      klass = lead_class

      expect { build_axn { expects :lead, model: { klass:, fnder: :find_by_slug } } }
        .to raise_error(ArgumentError, /model: does not support fnder:/)
    end

    it "refuses the ticket's exact typo: class: instead of klass:" do
      klass = lead_class
      stub_const("Lead", klass)

      expect { build_axn { expects :lead, model: { class: klass } } }
        .to raise_error(ArgumentError, /model: does not support class:/)
    end

    it "names every offender at once" do
      klass = lead_class

      expect { build_axn { expects :lead, model: { klass:, fnder: :x, bogus: 1 } } }
        .to raise_error(ArgumentError, /model: does not support fnder:, bogus:/)
    end

    # ActiveModel's own const_get-before-truthiness-check discipline is not in play here — this is axn's own
    # Hash#key? check — but the rule is the same one PRO-3219 states: a key that is PRESENT is an offender
    # whatever it is present WITH.
    [1, nil, false].each do |value|
      it "refuses key presence regardless of the value (#{value.inspect})" do
        klass = lead_class

        expect { build_axn { expects :lead, model: { klass:, bogus: value } } }
          .to raise_error(ArgumentError, /model: does not support bogus:/)
      end
    end

    describe "positive controls" do
      it "declares with every advertised key" do
        klass = lead_class

        expect do
          build_axn { expects :lead, model: { klass:, finder: :find, not_found_on: [StandardError], id_type: :uuid, message: "nope" } }
        end.not_to raise_error
      end

      # A documented, spec-covered spelling (`type_token_spec.rb`) this whitelist must not treat as unknown:
      # an ABSENT klass: infers the class from the field name, only overriding the finder.
      it "leaves a klass:-less bag alone" do
        stub_const("V", lead_class)

        expect { build_axn { expects :v, model: { finder: :find } } }.not_to raise_error
      end

      it "leaves the bare form alone" do
        stub_const("V", lead_class)

        expect { build_axn { expects :v, model: true } }.not_to raise_error
      end
    end

    describe "does not preempt the dedicated guards" do
      it "still raises the on: context-scope message rather than 'unknown key'" do
        klass = lead_class

        expect { build_axn { expects :lead, model: { klass:, on: :create } } }
          .to raise_error(ArgumentError, /`on:` inside model:/)
      end

      it "still raises the except_on: message rather than 'unknown key'" do
        klass = lead_class

        expect { build_axn { expects :lead, model: { klass:, except_on: :create } } }
          .to raise_error(ArgumentError, /`except_on:` inside model:/)
      end

      it "still raises the strict: message rather than 'unknown key'" do
        klass = lead_class

        expect { build_axn { expects :lead, model: { klass:, strict: true } } }
          .to raise_error(ArgumentError, /`strict:` inside model:/)
      end

      it "declares clean with if:/unless:/allow_nil:/allow_blank:" do
        klass = lead_class

        expect do
          build_axn { expects :lead, model: { klass:, if: -> { true }, unless: -> { false }, allow_nil: true, allow_blank: true } }
        end.not_to raise_error
      end

      it "does not advertise on:/except_on:/strict: as supported" do
        klass = lead_class

        expect { build_axn { expects :lead, model: { klass:, bogus: 1 } } }
          .to raise_error(ArgumentError) { |e| expect(e.message).not_to match(/\bon:|except_on:|strict:/) }
      end
    end
  end

  describe "type:" do
    it "is refused on a top-level expects" do
      expect { build_axn { expects :v, type: { klass: String, bogus: 1 } } }
        .to raise_error(ArgumentError, "type: does not support bogus: (supported: klass:, coerce:, message:, if:, unless:, allow_blank:, allow_nil:)")
    end

    it "is refused on an exposes" do
      expect { build_axn { exposes :v, type: { klass: String, bogus: 1 } } }
        .to raise_error(ArgumentError, /type: does not support bogus:/)
    end

    it "is refused on an on: subfield" do
      expect do
        build_axn do
          expects :parent, type: Hash
          expects :v, on: :parent, type: { klass: String, bogus: 1 }
        end
      end.to raise_error(ArgumentError, /type: does not support bogus:/)
    end

    it "is refused on a block-form shape member" do
      expect { build_axn { expects(:h, type: Hash) { field :v, type: { klass: String, bogus: 1 } } } }
        .to raise_error(ArgumentError, /type: does not support bogus:/)
    end

    it "is refused on a raw shape: member" do
      member = Axn::Core::Contract::ShapeConfig.new(field: :v, validations: { type: { klass: String, bogus: 1 } })

      expect { build_axn { expects :h, type: Hash, shape: { members: [member], container: Hash } } }
        .to raise_error(ArgumentError, /type: does not support bogus:/)
    end

    it "is refused through Axn::Factory.build" do
      expect { Axn::Factory.build(expects: { v: { type: { klass: String, bogus: 1 } } }) { nil } }
        .to raise_error(ArgumentError, /type: does not support bogus:/)
    end

    it "names every offender at once" do
      expect { build_axn { expects :v, type: { klass: String, foo: 1, bar: 2 } } }
        .to raise_error(ArgumentError, /type: does not support foo:, bar:/)
    end

    describe "positive controls" do
      it "declares with every advertised key" do
        expect { build_axn { expects :v, type: { klass: Integer, coerce: true, message: "nope" } } }.not_to raise_error
      end

      it "leaves the bare form alone" do
        expect { build_axn { expects :v, type: String } }.not_to raise_error
      end
    end

    describe "does not preempt the dedicated guards" do
      it "still raises the on: context-scope message rather than 'unknown key'" do
        expect { build_axn { expects :v, type: { klass: String, on: :create } } }
          .to raise_error(ArgumentError, /`on:` inside type:/)
      end

      it "declares clean with if:/unless:/allow_nil:/allow_blank:" do
        expect do
          build_axn { expects :v, type: { klass: String, if: -> { true }, allow_nil: true, allow_blank: true } }
        end.not_to raise_error
      end
    end
  end

  describe "validate:" do
    # `message:` is admitted (see the positive control below) but never ADVERTISED as a fix — it is inert
    # inside a `validate:` bag, so recommending it would trade one silently-ignored option for another.
    it "is refused on a top-level expects, without advertising the inert message:" do
      expect { build_axn { expects :v, validate: { with: ->(value) { value }, bogus: 1 } } }
        .to raise_error(ArgumentError, "validate: does not support bogus: (supported: with:, if:, unless:, allow_blank:, allow_nil:)")
    end

    it "is refused on an exposes" do
      expect { build_axn { exposes :v, validate: { with: ->(value) { value }, bogus: 1 } } }
        .to raise_error(ArgumentError, /validate: does not support bogus:/)
    end

    it "is refused on an on: subfield" do
      expect do
        build_axn do
          expects :parent, type: Hash
          expects :v, on: :parent, validate: { with: ->(value) { value }, bogus: 1 }
        end
      end.to raise_error(ArgumentError, /validate: does not support bogus:/)
    end

    it "is refused inside an of: element bag, where validate: is positional" do
      expect { build_axn { expects :list, type: Array, of: { klass: String, validate: { with: ->(value) { value }, bogus: 1 } } } }
        .to raise_error(ArgumentError, /validate: does not support bogus:/)
    end

    it "is refused through Axn::Factory.build" do
      expect { Axn::Factory.build(expects: { v: { validate: { with: ->(value) { value }, bogus: 1 } } }) { nil } }
        .to raise_error(ArgumentError, /validate: does not support bogus:/)
    end

    # The bag's own misuse guard (a Hash with no `:with` at all is almost always a standard validator nested
    # by mistake) is the more useful diagnosis, and must not be preempted by this one.
    it "does not preempt the with:-less misuse message" do
      expect { build_axn { expects :v, validate: { inclusion: { in: %w[a b] } } } }
        .to raise_error(ArgumentError, /`validate:` expects a callable/)
    end

    describe "positive controls" do
      it "declares with every advertised key" do
        expect { build_axn { expects :v, validate: { with: ->(value) { value }, message: "unused" } } }.not_to raise_error
      end

      it "leaves the bare callable form alone" do
        expect { build_axn { expects :v, validate: ->(value) { value } } }.not_to raise_error
      end
    end

    describe "does not preempt the dedicated guards" do
      it "still raises the on: context-scope message rather than 'unknown key'" do
        expect { build_axn { expects :v, validate: { with: ->(value) { value }, on: :create } } }
          .to raise_error(ArgumentError, /`on:` inside validate:/)
      end
    end
  end

  describe "shape:" do
    def shape_member(validations) = Axn::Core::Contract::ShapeConfig.new(field: :a, validations:)

    it "is refused on a field's own shape:" do
      member = shape_member(type: String)

      expect { build_axn { expects :h, type: Hash, shape: { members: [member], container: Hash, bogus: 1 } } }
        .to raise_error(ArgumentError, "shape: does not support bogus: (supported: members:, container:, if:, unless:, allow_blank:, allow_nil:)")
    end

    it "is refused on a shape MEMBER's own nested shape:" do
      expect do
        build_axn do
          expects(:h, type: Hash) do
            field :a, type: Hash, shape: { members: { b: { type: String } }, bogus: 1 }
          end
        end
      end.to raise_error(ArgumentError, /shape: does not support bogus:/)
    end

    it "is refused on an of: element bag's nested shape:" do
      member = shape_member(type: String)

      expect { build_axn { expects :list, type: Array, of: { klass: Hash, shape: { members: [member], container: Hash, bogus: 1 } } } }
        .to raise_error(ArgumentError, /shape: does not support bogus:/)
    end

    it "is refused on a map's values: axis nested shape:" do
      member = shape_member(type: String)

      expect { build_axn { expects :m, type: Hash, of: { values: { klass: Hash, shape: { members: [member], container: Hash, bogus: 1 } } } } }
        .to raise_error(ArgumentError, /shape: does not support bogus:/)
    end

    it "is refused through Axn::Factory.build" do
      member = shape_member(type: String)

      expect { Axn::Factory.build(expects: { h: { type: Hash, shape: { members: [member], container: Hash, bogus: 1 } } }) { nil } }
        .to raise_error(ArgumentError, /shape: does not support bogus:/)
    end

    describe "positive controls" do
      it "declares with every advertised key" do
        member = shape_member(type: String)

        expect { build_axn { expects :h, type: Hash, shape: { members: [member], container: Hash } } }.not_to raise_error
      end

      it "leaves the block form's own container: Array distributing marker alone" do
        expect { build_axn { expects(:list, type: Array) { field :el, type: String } } }.not_to raise_error
      end
    end

    describe "does not preempt the non-Hash refusal" do
      # A non-Hash `shape:` is `_reject_unshaped_shape!`'s defect, not this one's — firing here too would
      # report a bare `must supply :members` graph as also missing keys it never had a chance to name.
      it "leaves _reject_unshaped_shape!'s own message alone for a non-Hash shape:" do
        expect { build_axn { expects :h, type: Hash, shape: [] } }
          .to raise_error(ArgumentError, /must be a Hash naming the members it describes/)
      end
    end
  end

  # The drift guard: an ActiveModel version bump that adds/removes a shared option must not silently turn a
  # legal `if:`/`unless:`/`allow_nil:`/`allow_blank:`/`except_on:` into an unknown key in any of the four
  # bags, and the `(supported: …)` list must never recommend a key a dedicated guard refuses on sight.
  describe "the four vocabularies" do
    {
      model: Axn::Core::Contract::ClassMethods::MODEL_OPTION_KEYS,
      type: Axn::Core::Contract::ClassMethods::TYPE_OPTION_KEYS,
      validate: Axn::Core::Contract::ClassMethods::VALIDATE_OPTION_KEYS,
      shape: Axn::Core::Contract::ClassMethods::SHAPE_OPTION_KEYS,
    }.each do |option, keys|
      it "#{option}: stays a superset of ActiveModel's shared validation options" do
        expect(Axn::Validation::Base.shared_validation_option_keys.to_a - keys.to_a).to eq([])
      end
    end

    # `validate:`'s `message:` is admitted (an author who writes it must not be refused) but deliberately
    # never advertised — `ValidateValidator#validate_each` never reads it, so recommending it would trade one
    # silently-ignored option for another.
    it "never advertises validate:'s message: as a fix" do
      expect { build_axn { expects :v, validate: { with: ->(value) { value }, bogus: 1 } } }
        .to raise_error(ArgumentError) { |e| expect(e.message).not_to include("message:") }
    end
  end
end
