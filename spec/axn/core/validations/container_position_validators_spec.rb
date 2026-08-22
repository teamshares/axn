# frozen_string_literal: true

require "axn/testing/spec_helpers"
require "bigdecimal" # non-Rails specs don't autoload it

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
      # A mixed set: one member is the array that should match whole-value, one is the String an element-wise
      # reading would have matched. The second assertion is what fails under a distributing reading.
      action = build_axn { expects :tags, type: Array, inclusion: { in: [%w[a b], "a"] } }

      expect(action.call(tags: %w[a b]).ok?).to be(true)
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

    it "refuses numericality: on a container" do
      expect { build_axn { expects :tags, type: Array, numericality: true } }.to raise_error(ArgumentError, /numericality:/)
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

    it "refuses regardless of tolerance — a tolerated nil does not give the check a reading" do
      expect { build_axn { expects :tags, type: Array, format: { with: /a/ }, optional: true } }
        .to raise_error(ArgumentError, /format:/)
    end

    it "refuses under a declaration-level gate as well as an entry-level one" do
      expect { build_axn { expects :tags, type: Array, format: { with: /a/ }, if: :flag? } }
        .to raise_error(ArgumentError, /format:/)
    end

    it "names the field labels of a multi-field declaration" do
      expect { build_axn { expects :tags, :labels, type: Array, format: { with: /a/ } } }
        .to raise_error(ArgumentError, /:tags, :labels/)
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

  describe "an inclusion: set no value of the declared type can satisfy is refused" do
    it "refuses the element-wise spelling on an Array field, naming the position" do
      expect { build_axn { expects :tags, type: Array, of: String, inclusion: { in: %w[a b] } } }
        .to raise_error(ArgumentError, /inclusion: on :tags can never match.*of:/m)
    end

    it "names the declared type in the message, not the field name" do
      expect { build_axn { expects :tags, type: Array, inclusion: { in: %w[a b] } } }
        .to raise_error(ArgumentError,
                        /inclusion: on :tags can never match — nothing it compares against is of type Array/)
    end

    it "refuses the bare-Array shorthand identically" do
      expect { build_axn { expects :tags, type: Array, inclusion: %w[a b] } }
        .to raise_error(ArgumentError, /inclusion:/)
    end

    it "refuses an empty literal set, which nothing can satisfy at any type" do
      expect { build_axn { expects :tags, type: Array, inclusion: { in: [] } } }
        .to raise_error(ArgumentError, /inclusion:/)
    end

    it "refuses on a Hash field too" do
      expect { build_axn { expects :meta, type: Hash, inclusion: { in: %w[a b] } } }
        .to raise_error(ArgumentError, /inclusion:/)
    end

    # NOT container-only: the defect is the same shape on every type, and scoping to containers would leave a
    # structurally identical hole open everywhere else.
    it "refuses a scalar declaration whose set matches no value of the declared type" do
      expect { build_axn { expects :n, type: Integer, inclusion: { in: %w[1 2] } } }
        .to raise_error(ArgumentError, /inclusion:/)
    end

    it "admits a set whose members ARE of the declared type" do
      expect { build_axn { expects :tags, type: Array, inclusion: { in: [%w[a b]] } } }.not_to raise_error
      expect { build_axn { expects :n, type: Integer, inclusion: { in: [1, 2] } } }.not_to raise_error
    end

    it "admits a set where only one member matches — one passing value is enough" do
      expect { build_axn { expects :n, type: Integer, inclusion: { in: ["1", 2] } } }.not_to raise_error
    end

    it "admits a union type any member of which matches" do
      expect { build_axn { expects :f, type: [String, Array], inclusion: { in: %w[a b] } } }.not_to raise_error
    end

    it "stands down on a dynamically-sourced set, which reflection may not read" do
      expect { build_axn { expects :tags, type: Array, inclusion: { in: :allowed_tags } } }.not_to raise_error
      expect { build_axn { expects :tags, type: Array, inclusion: { in: -> { [] } } } }.not_to raise_error
    end

    it "stands down on an Array-subclass set, judged by the same exact-class rule reflection uses" do
      subclass = Class.new(Array)
      set = subclass.new
      set << "a"

      expect { build_axn { expects :tags, type: Array, inclusion: { in: set } } }.not_to raise_error
    end

    it "stands down on a Range set at a scalar position, where cross-type comparison really works" do
      # `(1.0..5.0).cover?(3)` is true, so judging a Range's bounds against a scalar type would falsely refuse.
      expect { build_axn { expects :n, type: Integer, inclusion: { in: 1..5 } } }.not_to raise_error
      expect { build_axn { expects :n, type: Integer, inclusion: { in: 1.0..5.0 } } }.not_to raise_error
    end

    it "refuses a Range set at a container position, where nothing can be a member" do
      # `<=>` is nil across unrelated classes, so `(1..5).cover?([1, 2])` is false however the array is spelled.
      # Before the positional rule this declaration accepted `[1, 2]` element-wise while emitting no constraint
      # at all — the schema said nothing and the runtime rejected everything.
      expect { build_axn { expects :nums, type: Array, of: Integer, inclusion: { in: 1..5 } } }
        .to raise_error(ArgumentError, /inclusion:/)
      expect { build_axn { expects :m, type: Hash, inclusion: { in: 1..5 } } }
        .to raise_error(ArgumentError, /inclusion:/)
    end

    it "stands down on a Range whose bounds are the declared container, rather than certifying it" do
      # Clusivity picks `include?` for a Range whose begin is not Numeric/Time, and
      # `(["a"]..["z"]).include?(["b"])` raises TypeError — so this fails every call. Standing down leaves that
      # ActiveModel behavior exactly as it is; refusing would be this guard claiming knowledge it does not have.
      expect { build_axn { expects :tags, type: Array, inclusion: { in: ["a"]..["z"] } } }.not_to raise_error
    end

    it "stands down on an undeclared type and on a pseudo-type token" do
      expect { build_axn { expects :f, inclusion: { in: %w[a b] } } }.not_to raise_error
      expect { build_axn { expects :f, type: :params, inclusion: { in: %w[a b] } } }.not_to raise_error
    end

    it "stands down under tolerance, where nil is a passing value" do
      action = build_axn { expects :tags, type: Array, inclusion: { in: %w[a b] }, optional: true }
      expect(action.call.ok?).to be(true)

      expect { build_axn { expects :tags, type: Array, inclusion: { in: %w[a b] }, allow_nil: true } }.not_to raise_error
    end

    it "stands down on a comparison bound in the same numeric family as the declared type" do
      # `1.5 > 0`, `3 > 1.5`, and BigDecimal compares with either — none of these bounds is the declared
      # type, but every one of them really does compare, so refusing them would be over-restriction.
      expect { build_axn { expects :n, type: Float, comparison: { greater_than: 0 } } }.not_to raise_error
      expect { build_axn { expects :n, type: Integer, comparison: { greater_than: 1.5 } } }.not_to raise_error
      expect { build_axn { expects :n, type: BigDecimal, comparison: { greater_than: 0 } } }.not_to raise_error
    end

    it "admits a passing value at runtime under that cross-family comparison bound" do
      action = build_axn { expects :n, type: Float, comparison: { greater_than: 0 } }
      expect(action.call(n: 1.5).ok?).to be(true)
    end

    it "stands down on a date/time bound against a declared type from the same family" do
      expect { build_axn { expects :d, type: Date, comparison: { greater_than: Time.now } } }.not_to raise_error
    end

    it "stands down on an inclusion set whose numeric literal matches across the family" do
      # `[0].include?(0.0)` is true, so an Integer literal in the set is a real match for a Float field.
      expect { build_axn { expects :n, type: Float, inclusion: { in: [0, 1] } } }.not_to raise_error
    end

    it "admits the cross-family numeric member at runtime, not just at declaration" do
      action = build_axn { expects :n, type: Float, inclusion: { in: [0, 1] } }
      expect(action.call(n: 0.0).ok?).to be(true)
    end

    it "stands down when the declared type descends from the literal's class" do
      # `Array#==` compares contents, so an instance of an Array subclass can equal a plain-Array literal.
      subclass = Class.new(Array)
      expect { build_axn { expects :tags, type: subclass, inclusion: { in: [%w[a b]] } } }.not_to raise_error
    end

    it "admits a content-comparing subclass against a literal of its root" do
      subclass = Class.new(Array)
      action = build_axn { expects :tags, type: subclass, inclusion: { in: [[1]] } }

      expect(action.call(tags: subclass.new([1])).ok?).to be(true)
    end

    it "refuses a literal whose class is merely an ancestor, where == is identity" do
      base = Class.new
      sub = Class.new(base)
      literal = base.new

      expect { build_axn { expects :f, type: sub, inclusion: { in: [literal] } } }
        .to raise_error(ArgumentError, /inclusion:/)
    end

    it "refuses a bare Object literal, which is an ancestor-instance of every declared type" do
      literal = Object.new

      expect { build_axn { expects :tags, type: Array, inclusion: { in: [literal] } } }
        .to raise_error(ArgumentError, /inclusion:/)
      expect { build_axn { expects :name, type: String, comparison: { equal_to: literal } } }
        .to raise_error(ArgumentError, /comparison:/)
    end

    it "refuses a gated entry too — a gate removes the check, it does not give the set a reading" do
      # Reflection is static-maximal (it treats every gate as open), so a gated can-never-match set still
      # emits `{type: "array", enum: ["a","b"]}` — the unsatisfiable node the corollary forbids. Closed the
      # check enforces nothing; open it rejects everything. Incoherent either way.
      expect { build_axn { expects :tags, type: Array, inclusion: { in: %w[a b], if: :flag? } } }
        .to raise_error(ArgumentError, /inclusion:/)
      expect { build_axn { expects :tags, type: Array, inclusion: { in: %w[a b] }, if: :flag? } }
        .to raise_error(ArgumentError, /inclusion:/)
    end

    it "leaves the tolerance case satisfiable on both sides, which is why tolerance stands the guard down" do
      action = build_axn { expects :tags, type: Array, inclusion: { in: %w[a b] }, optional: true }
      prop = action.input_schema[:properties][:tags]

      # The emitted node admits exactly `null`; the runtime admits exactly nil. Both sides agree, and the node
      # is satisfiable — the contract is pointless, not broken, so it is not this guard's business.
      expect(prop[:type]).to eq(%w[array null])
      expect(prop[:enum]).to include(nil)
      expect(action.call.ok?).to be(true)
      expect(action.call(tags: %w[a b]).ok?).to be(false)
    end
  end

  describe "comparison: and acceptance: are judged by their literals, not refused by key" do
    it "refuses a comparison bound of the wrong type" do
      # `["a"] > 1` raises NoMethodError on every call today, so refusing it at declaration is a strict
      # improvement over the status quo.
      expect { build_axn { expects :tags, type: Array, comparison: { greater_than: 1 } } }
        .to raise_error(ArgumentError, /comparison:/)
    end

    it "admits a comparison bound that IS the declared container, which really works" do
      action = build_axn { expects :tags, type: Array, comparison: { equal_to: ["a"] } }

      expect(action.call(tags: ["a"]).ok?).to be(true)
      expect(action.call(tags: ["b"]).ok?).to be(false)
    end

    it "admits a Hash bound, which compares by subset" do
      action = build_axn { expects :meta, type: Hash, comparison: { greater_than_or_equal_to: { "read" => true } } }

      expect(action.call(meta: { "read" => true, "w" => 1 }).ok?).to be(true)
    end

    it "stands down on a Symbol or Proc bound, which ActiveModel resolves per call" do
      expect { build_axn { expects :tags, type: Array, comparison: { equal_to: :allowed } } }.not_to raise_error
      expect { build_axn { expects :tags, type: Array, comparison: { equal_to: ->(_r) { ["a"] } } } }.not_to raise_error
    end

    it "admits a value the resolved Symbol/Proc bound really accepts at call time" do
      action = build_axn do
        expects :tags, type: Array, comparison: { equal_to: :allowed }
        def allowed = ["a"]
      end
      expect(action.call(tags: ["a"]).ok?).to be(true)
    end

    it "declares other_than: with a wrong-type bound, because an inverted operator is vacuous, not unsatisfiable" do
      # A wrong-type `other_than:` bound makes the check always PASS (`["a"] != 1` is true), the opposite of
      # unsatisfiable, so this must NOT be refused.
      action = build_axn { expects :tags, type: Array, comparison: { other_than: 1 } }
      expect(action.call(tags: ["a"]).ok?).to be(true)
    end

    it "refuses acceptance: whose effective set holds nothing of the declared type" do
      # `acceptance: true` compares against ActiveModel's own ["1", true].
      expect { build_axn { expects :tags, type: Array, acceptance: true } }
        .to raise_error(ArgumentError, /acceptance:/)
      expect { build_axn { expects :n, type: Integer, acceptance: true } }
        .to raise_error(ArgumentError, /acceptance:/)
    end

    it "admits acceptance: whose accept set names the declared container" do
      action = build_axn { expects :tags, type: Array, acceptance: { accept: [["a"]] } }

      expect(action.call(tags: ["a"]).ok?).to be(true)
    end

    it "admits acceptance: true on a String, where \"1\" is a member of the default set" do
      expect { build_axn { expects :flag, type: String, acceptance: true } }.not_to raise_error
    end

    it "stands down on a Hash accept set, which AcceptanceValidator reads as pairs, not keys" do
      # `Array({"a" => 1})` is `[["a", 1]]` — pairs, not keys — so the shared set reader's "a Hash's members
      # are its keys" rule (right for `inclusion:`) would misjudge this. Measured: `accept: { "a" => 1 }`
      # accepts `["a", 1]` and rejects `"a"`.
      action = build_axn { expects :tags, type: Array, acceptance: { accept: { "a" => 1 } } }
      expect(action.call(tags: ["a", 1]).ok?).to be(true)
    end
  end

  describe "Validation::Base.literal_set_members" do
    it "reads the hash long form, both keys, and the bare shorthand" do
      expect(Axn::Validation::Base.literal_set_members({ in: %w[a b] })).to eq(%w[a b])
      expect(Axn::Validation::Base.literal_set_members({ within: %w[a b] })).to eq(%w[a b])
      expect(Axn::Validation::Base.literal_set_members(%w[a b])).to eq(%w[a b])
    end

    it "reads a Set, and a Hash's keys" do
      expect(Axn::Validation::Base.literal_set_members({ in: Set.new(%w[a]) })).to eq(Set.new(%w[a]))
      expect(Axn::Validation::Base.literal_set_members({ in: { "a" => 1 } })).to eq(%w[a])
    end

    it "answers nil for a set it may not read" do
      expect(Axn::Validation::Base.literal_set_members({ in: :dynamic })).to be_nil
      expect(Axn::Validation::Base.literal_set_members({ in: -> { [] } })).to be_nil
      expect(Axn::Validation::Base.literal_set_members({ in: 1..5 })).to be_nil
      expect(Axn::Validation::Base.literal_set_members({ in: Class.new(Array).new })).to be_nil
    end
  end

  describe "validate:'s misuse guard does not advise a fix that is itself refused" do
    it "does not promise a bare inclusion: as the fix for a container" do
      # `validate: { inclusion: ... }` enforces nothing, so it is refused, and the fix it advises —
      # declaring `inclusion:` directly — must not be one that itself raises at a container position.
      expect { build_axn { expects :tags, type: Array, validate: { inclusion: { in: %w[a b] } } } }
        .to raise_error(ArgumentError, /constrains the value at that position/)
    end
  end

  # A RAW `shape:` member — a bag handed straight to the declaration walk — never reaches
  # `_parse_field_validations`, so both positional guards are mirrored onto the member walk. Without the
  # mirror the block form raised while the identical raw member declared cleanly and emitted the very
  # unsatisfiable node the rule exists to eliminate.
  describe "both positional guards reach a raw shape: member" do
    let(:member_struct) { Struct.new(:field, :validations) }

    def raw_shape(validations)
      members = [member_struct.new(:x, validations)]
      build_axn { expects :row, type: Hash, shape: { members: } }
    end

    it "refuses an unsatisfiable inclusion: set on a member, as the block form does" do
      expect { raw_shape({ type: Array, inclusion: { in: %w[a] } }) }
        .to raise_error(ArgumentError, /inclusion: on shape member `x` can never match/)
    end

    it "refuses format: at a member's container position" do
      expect { raw_shape({ type: Array, format: { with: /a/ } }) }
        .to raise_error(ArgumentError, /format: on shape member `x` cannot constrain a container/)
    end

    it "refuses numericality: at a member's container position" do
      expect { raw_shape({ type: Hash, numericality: true }) }
        .to raise_error(ArgumentError, /numericality: on shape member `x` cannot constrain a container/)
    end

    it "refuses an unsatisfiable acceptance: and comparison: on a member too" do
      expect { raw_shape({ type: Array, acceptance: true }) }
        .to raise_error(ArgumentError, /acceptance: on shape member `x` can never match/)
      expect { raw_shape({ type: Array, comparison: { greater_than: 1 } }) }
        .to raise_error(ArgumentError, /comparison: on shape member `x` can never match/)
    end

    it "still declares a member whose set IS of the declared type" do
      expect { raw_shape({ type: String, inclusion: { in: %w[a] } }) }.not_to raise_error
      expect { raw_shape({ type: Array, inclusion: { in: [%w[a]] } }) }.not_to raise_error
    end

    it "still declares a member carrying format: at a scalar position" do
      expect { raw_shape({ type: String, format: { with: /a/ } }) }.not_to raise_error
    end

    it "validates the member the legal declaration describes" do
      action = raw_shape({ type: Array, inclusion: { in: [%w[a]] } })

      expect(action.call(row: { x: %w[a] }).ok?).to be(true)
      expect(action.call(row: { x: %w[b] }).ok?).to be(false)
    end

    # The member's own bag carries the tolerance on this route (nothing pushes a field's kwargs down into
    # it), so it is read from there — an intolerant reading would refuse a declaration under which nil
    # passes and the emitted node stays satisfiable.
    it "stands the satisfiability guard down under a member's own tolerance" do
      expect { raw_shape({ type: Array, inclusion: { in: %w[a] }, allow_nil: true }) }.not_to raise_error
      expect { raw_shape({ type: Array, inclusion: { in: %w[a] }, allow_blank: true }) }.not_to raise_error
    end

    it "refuses regardless of tolerance for the container-position guard, which tolerance cannot rescue" do
      expect { raw_shape({ type: Array, format: { with: /a/ }, allow_nil: true }) }
        .to raise_error(ArgumentError, /format: on shape member `x`/)
    end

    # `of: { values: { klass: Hash, shape: { members: [...] } } }` is the only spelling a map's shaped values
    # have, and it descends through the same member walk — so the mirror covers it with no second call site.
    it "reaches the shaped values of a map declared with of:" do
      members = [member_struct.new(:x, { type: Array, inclusion: { in: %w[a] } })]
      expect { build_axn { expects :m, type: Hash, of: { values: { klass: Hash, shape: { members: } } } } }
        .to raise_error(ArgumentError, /inclusion: on shape member `x` can never match/)
    end

    it "leaves a legal member inside a map's shaped values declaring" do
      members = [member_struct.new(:x, { type: Array, inclusion: { in: [%w[a]] } })]
      expect { build_axn { expects :m, type: Hash, of: { values: { klass: Hash, shape: { members: } } } } }
        .not_to raise_error
    end
  end

  # A hand-copied ActiveModel default is only correct until the gem moves. Pinned here so a bump that changes
  # it fails loudly rather than silently misjudging every `acceptance: true` declaration.
  describe "DEFAULT_ACCEPTANCE_SET tracks ActiveModel's own default" do
    it "matches what AcceptanceValidator defaults `accept:` to" do
      model = Class.new { include ActiveModel::Validations }
      validator = ActiveModel::Validations::AcceptanceValidator.new(attributes: [:terms], class: model)

      expect(Axn::Core::Contract::ClassMethods::DEFAULT_ACCEPTANCE_SET).to eq(validator.options[:accept])
    end
  end
end
