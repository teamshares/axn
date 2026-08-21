# frozen_string_literal: true

require "axn/testing/spec_helpers"

# One positional rule: a validator constrains the value AT THE POSITION IT IS DECLARED AT. `of:` is how a
# declaration descends a level. ActiveModel's Clusivity#include? special-cases an Array VALUE
# (activemodel 7.2.2.2, clusivity.rb:24) and distributes the set over its elements, which no rule states, which
# emits as `enum` on the array node, and which inverts to nonsense under exclusion's negating caller. See
# internal-docs/specs/2026-08-21-container-field-validators-design.md.
RSpec.describe "a validator at a container position" do
  describe "inclusion: constrains the value at its own position" do
    it "compares an Array-typed field's value as a whole" do
      action = build_axn { expects :tags, type: Array, of: String, inclusion: { in: [%w[a b], %w[c]] } }

      expect(action.call(tags: %w[a b]).ok?).to be(true)
      expect(action.call(tags: %w[c]).ok?).to be(true)
      expect(action.call(tags: %w[b a]).ok?).to be(false) # whole-value equality: order is part of the value
      expect(action.call(tags: %w[a]).ok?).to be(false)
    end

    it "does not distribute the set over an Array's elements" do
      action = build_axn { expects :tags, type: Array, inclusion: { in: %w[a b] } }

      expect(action.call(tags: %w[a b]).ok?).to be(false)
      expect(action.call(tags: %w[a]).ok?).to be(false)
    end

    it "agrees with the emitted enum on the same value" do
      action = build_axn { expects :tags, type: Array, of: String, inclusion: { in: [%w[a b]] } }

      expect(action.input_schema[:properties][:tags][:enum]).to eq([%w[a b]])
      expect(action.call(tags: %w[a b]).ok?).to be(true)
    end

    it "is unchanged at a scalar position" do
      action = build_axn { expects :status, type: String, inclusion: { in: %w[a b] } }

      expect(action.call(status: "a").ok?).to be(true)
      expect(action.call(status: "zzz").ok?).to be(false)
    end

    it "is unchanged on a Hash-typed field, where Clusivity never distributed" do
      action = build_axn { expects :meta, type: Hash, inclusion: { in: [{ "a" => 1 }] } }

      expect(action.call(meta: { "a" => 1 }).ok?).to be(true)
      expect(action.call(meta: { "a" => 2 }).ok?).to be(false)
    end
  end

  describe "exclusion: constrains the value at its own position" do
    it "rejects an Array value that IS a forbidden member, and nothing else" do
      action = build_axn { expects :tags, type: Array, of: String, exclusion: { in: [%w[bad]] } }

      expect(action.call(tags: %w[bad]).ok?).to be(false)
      expect(action.call(tags: %w[ok]).ok?).to be(true)
    end

    it "treats the array as the value, so an array of forbidden strings is not itself forbidden" do
      action = build_axn { expects :tags, type: Array, exclusion: { in: %w[bad] } }

      # THIS is the behavior change: element-wise, every element was forbidden, so the array was rejected.
      # Whole-value, the array is not the String "bad", so it passes.
      expect(action.call(tags: %w[bad]).ok?).to be(true)
      # Unchanged, and named so nobody mistakes it for evidence: the old `all?` reading passed this too.
      expect(action.call(tags: %w[ok bad]).ok?).to be(true)
    end

    it "is unchanged at a scalar position" do
      action = build_axn { expects :name, type: String, exclusion: { in: %w[bad] } }

      expect(action.call(name: "bad").ok?).to be(false)
      expect(action.call(name: "ok").ok?).to be(true)
    end
  end

  describe "the constant shadowing reaches every position a validator is built at" do
    it "reaches a subfield" do
      action = build_axn do
        expects :payload, type: Hash
        expects :tags, on: :payload, type: Array, inclusion: { in: [%w[a b]] }
      end

      expect(action.call(payload: { tags: %w[a b] }).ok?).to be(true)
      expect(action.call(payload: { tags: %w[a] }).ok?).to be(false)
    end

    it "reaches a shape member" do
      action = build_axn do
        expects :row, type: Hash do
          field :tags, type: Array, inclusion: { in: [%w[a b]] }
        end
      end

      expect(action.call(row: { tags: %w[a b] }).ok?).to be(true)
      expect(action.call(row: { tags: %w[a] }).ok?).to be(false)
    end

    it "resolves inclusion: to axn's own validator, not ActiveModel's" do
      expect(Axn::Validation::Base::InclusionValidator).to be(Axn::Validators::InclusionValidator)
      expect(Axn::Validation::Base::ExclusionValidator).to be(Axn::Validators::ExclusionValidator)
      expect(Axn::Validators::InclusionValidator.ancestors).to include(Axn::Validators::WholeValueClusivity)
    end

    it "leaves a plain ActiveModel model on ActiveModel's own validator" do
      plain = Class.new do
        include ActiveModel::Validations
        def self.name = "PlainModel"
        attr_accessor :tags

        validates :tags, inclusion: { in: %w[a b] }
      end

      expect(plain.validators_on(:tags).first.class).to be(ActiveModel::Validations::InclusionValidator)

      # Still element-wise there — a consuming app's own validators are untouched by axn's constants.
      model = plain.new
      model.tags = %w[a b]
      expect(model.valid?).to be(true)
    end
  end

  describe "nil membership is unaffected" do
    # A nil was never an Array, so it never took Clusivity's Array branch — the judgment that drives
    # requiredness and nullability read the whole value before this change and still does. Asserted on the
    # judgment itself, because a field's requiredness is decided by its OTHER validators too: `expects` applies
    # a default `presence: true`, which rejects nil whatever the inclusion set holds.
    it "still reads nil's membership in a literal set" do
      expect(Axn::Validation::Base.set_includes_nil?({ in: [nil, ["a"]] })).to be(true)
      expect(Axn::Validation::Base.set_includes_nil?({ in: [["a"]] })).to be(false)
      expect(Axn::Validation::Base.set_includes_nil?([nil, ["a"]])).to be(true)
    end

    it "admits nil under explicit tolerance while matching the rest of the set whole-value" do
      action = build_axn { expects :tags, type: Array, inclusion: { in: [nil, ["a"]] }, optional: true }

      expect(action.call.ok?).to be(true)
      expect(action.call(tags: ["a"]).ok?).to be(true)
      expect(action.call(tags: ["b"]).ok?).to be(false)
    end

    it "reflects the nullable pair and the nil-bearing enum together" do
      prop = build_axn do
        expects :tags, type: Array, inclusion: { in: [nil, ["a"]] }, optional: true
      end.input_schema[:properties][:tags]

      expect(prop[:type]).to eq(%w[array null])
      expect(prop[:enum]).to eq([nil, ["a"]])
    end
  end

  describe "validators that can only reach a container through its to_s are refused at declaration" do
    it "refuses format: on an Array-typed field" do
      expect { build_axn { expects :tags, type: Array, of: String, format: { with: /\A[A-Z]+\z/ } } }
        .to raise_error(ArgumentError, /format:.*:tags.*position/m)
    end

    it "refuses format: on a Hash-typed field" do
      expect { build_axn { expects :meta, type: Hash, format: { with: /k/ } } }
        .to raise_error(ArgumentError, /format:/)
    end

    it "refuses numericality:, comparison: and acceptance: on a container" do
      expect { build_axn { expects :tags, type: Array, numericality: true } }.to raise_error(ArgumentError, /numericality:/)
      expect { build_axn { expects :tags, type: Array, comparison: { greater_than: 1 } } }.to raise_error(ArgumentError, /comparison:/)
      expect { build_axn { expects :tags, type: Array, acceptance: true } }.to raise_error(ArgumentError, /acceptance:/)
    end

    it "names every offender at once, so one declaration is one fix" do
      expect { build_axn { expects :tags, type: Array, format: { with: /a/ }, numericality: true } }
        .to raise_error(ArgumentError, %r{format: / numericality:})
    end

    it "refuses a gated one too — a gate can skip a check, not give it a reading" do
      expect { build_axn { expects :tags, type: Array, format: { with: /a/, if: :never? } } }
        .to raise_error(ArgumentError, /format:/)
    end

    it "refuses on a Set, whose to_s is an inspect form like the other two" do
      expect { build_axn { expects :tags, type: Set, format: { with: /a/ } } }
        .to raise_error(ArgumentError, /format:/)
    end

    # The stand-downs. Each is a declaration the guard must NOT reject: over-restriction rejects legal work,
    # under-restriction only defers the diagnosis to the value that triggers it.
    it "admits a union type carrying a scalar, where the validator has something to constrain" do
      expect { build_axn { expects :f, type: [String, Array], format: { with: /a/ } } }.not_to raise_error
    end

    it "admits an undeclared type, which says nothing about what the value will be" do
      expect { build_axn { expects :f, format: { with: /a/ } } }.not_to raise_error
    end

    it "admits a pseudo-type token" do
      expect { build_axn { expects :f, type: :params, format: { with: /a/ } } }.not_to raise_error
    end

    it "admits a scalar container-ish type whose to_s is a real rendering" do
      expect { build_axn { expects :f, type: String, format: { with: /a/ } } }.not_to raise_error
    end

    it "admits a disabled entry, which ActiveModel skips outright" do
      expect { build_axn { expects :tags, type: Array, format: false } }.not_to raise_error
    end

    it "admits the validators that DO have a reading on a container" do
      expect { build_axn { expects :tags, type: Array, length: { maximum: 2 } } }.not_to raise_error
      expect { build_axn { expects :tags, type: Array, presence: true } }.not_to raise_error
      expect { build_axn { expects :tags, type: Array, of: String } }.not_to raise_error
    end
  end
end
