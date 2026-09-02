# frozen_string_literal: true

require "axn/testing/spec_helpers"
require "bigdecimal"

# A clusivity set names WHICH VALUES pass, and the container it is written in must not decide which equality
# answers that. It used to: `Clusivity` calls the collection's own `include?`, so an Array compared with `==`
# while a `Set` (and a Hash, whose members are its keys) looked the value up by `hash`+`eql?`. The two answer
# differently across a type boundary — `[1].include?(BigDecimal("1"))` is true, `Set[1].include?(...)` is not —
# so the same literal enforced two different contracts depending on how it was spelled.
#
# Worse, the Set reading was not even STABLE. A Ruby Hash of eight or fewer entries stores only an 8-bit hint
# of each key's hash (`ar_table`) and falls through to `eql?` when the hint matches, and `BigDecimal#eql?` is
# aliased to `#==`, which crosses the Numeric family. So `Set[1].include?(BigDecimal("1"))` was true in ~1/256
# of processes, decided by the per-process hash seed — and false again once the set grew past eight members.
# The declaration guards reason statically and cannot see a coin flip, so they refused declarations that the
# runtime, in those processes, enforced perfectly well (PRO-3319).
#
# The fix is one reading rather than an agreement between two: a readable Set (or a Hash set, whose members are
# its keys) is canonicalized to its members at declaration, so the runtime, the guards and the emitted `enum`
# all read the same Array.
RSpec.describe "a clusivity set is canonicalized to its members, whatever container it was written in" do
  # Every position a clusivity entry can be declared at. The canonicalization lives on two seams — the field
  # path's and the `of:` bag's — so the audit walks all of them rather than the one the bug was reported at.
  # Each builds an action whose `:v` position carries `inclusion:` spelled as `entry`, and calls it with `value`.
  member_struct = Struct.new(:field, :validations)

  positions = {
    "top-level field" => lambda { |entry, value|
      build_axn { expects :v, inclusion: entry }.call(v: value)
    },
    "subfield" => lambda { |entry, value|
      build_axn do
        expects :par, type: Hash
        expects :v, on: "par", inclusion: entry
      end.call(par: { v: value })
    },
    "shape member (block form)" => lambda { |entry, value|
      build_axn { expects(:par, type: Hash) { field :v, inclusion: entry } }.call(par: { v: value })
    },
    "shape member (raw bag)" => lambda { |entry, value|
      members = [member_struct.new(:v, { inclusion: entry })]
      build_axn { expects :par, type: Hash, shape: { members: } }.call(par: { v: value })
    },
    "of: element bag" => lambda { |entry, value|
      build_axn { expects :par, type: Array, of: { klass: Numeric, inclusion: entry } }.call(par: [value])
    },
    "of: values: axis" => lambda { |entry, value|
      build_axn { expects :par, type: Hash, of: { values: { klass: Numeric, inclusion: entry } } }.call(par: { a: value })
    },
    "of: keys: axis" => lambda { |entry, value|
      build_axn do
        expects :par, type: Hash, of: { keys: { klass: Numeric, inclusion: entry }, values: { klass: Numeric } }
      end.call(par: { value => 9 })
    },
  }

  # A raise is not a rejection: the defect the bare spelling had was that it DECLARED and then blew up on every
  # call, which reads as neither. Kept distinct so a test cannot pass by swapping one failure for the other.
  def outcome(result)
    return :pass if result.ok?

    exception = result.exception
    exception.nil? || exception.is_a?(Axn::InboundValidationError) ? :reject : :raise
  end

  positions.each do |position, invoke|
    describe "at a #{position}" do
      it "reads a Set set by `==`, exactly as the Array spelling does" do
        expect(outcome(instance_exec({ in: Set[1] }, 1.0, &invoke))).to eq(:pass)
        expect(outcome(instance_exec({ in: [1] }, 1.0, &invoke))).to eq(:pass)
      end

      it "still rejects a value no member equals" do
        expect(outcome(instance_exec({ in: Set[1] }, 2.0, &invoke))).to eq(:reject)
      end

      it "accepts the bare Set spelling instead of raising on every call" do
        expect(outcome(instance_exec(Set[1], 1, &invoke))).to eq(:pass)
      end

      it "reads a Hash set by its keys, under the same equality" do
        expect(outcome(instance_exec({ in: { 1 => :anything } }, 1.0, &invoke))).to eq(:pass)
      end
    end
  end

  # The membership that used to be decided by the per-process hash seed. `BigDecimal#eql?` is aliased to `#==`,
  # so this pair is exactly the one the `ar_table` hint could leak through; it must now answer the same way in
  # every process, and the same way the Array spelling always did.
  describe "cross-type numeric membership" do
    it "admits a BigDecimal against an Integer literal, deterministically" do
      %i[in within].each do |key|
        action = build_axn { expects :v, type: BigDecimal, inclusion: { key => Set[1] } }
        expect(action.call(v: BigDecimal("1"))).to be_ok
        expect(action.call(v: BigDecimal("0"))).not_to be_ok
      end
    end

    # The size boundary the leak turned on: at eight members or fewer a Ruby Hash compares an 8-bit hint, past
    # that a full 64-bit hash. A canonicalized set cannot notice the difference.
    it "answers the same either side of the ar_table/st_table boundary" do
      [1, 8, 9, 40].each do |size|
        set = Set.new((1..size).to_a)
        action = build_axn { expects :v, type: BigDecimal, inclusion: { in: set } }
        expect(action.call(v: BigDecimal("1"))).to be_ok, "membership differed at #{size} members"
      end
    end
  end

  describe "the exclusion mirror" do
    it "forbids a cross-type numeric its set names" do
      action = build_axn { expects :v, type: BigDecimal, exclusion: { in: Set[1] } }
      expect(action.call(v: BigDecimal("1"))).not_to be_ok
      expect(action.call(v: BigDecimal("0"))).to be_ok
    end
  end

  # The declaration guards judged a Set set under `eql?` semantics, which is what made them refuse a
  # declaration the runtime enforced. With one reading there is nothing left for them to disagree with: a
  # cross-family literal is reachable, so neither guard fires.
  describe "the declaration guards" do
    it "no longer refuses a cross-family literal in a Set set" do
      expect { build_axn { expects :v, type: Float, inclusion: { in: Set[1] } } }.not_to raise_error
      expect { build_axn { expects :v, type: BigDecimal, exclusion: { in: Set[1] } } }.not_to raise_error
    end

    it "still refuses one whose literals no value of the type could match" do
      expect { build_axn { expects :v, type: Float, inclusion: { in: Set["a"] } } }
        .to raise_error(ArgumentError, /inclusion: on :v can never match/)
      expect { build_axn { expects :v, type: Float, exclusion: { in: Set["a"] } } }
        .to raise_error(ArgumentError, /exclusion: on :v enforces nothing/)
    end
  end

  # An `inclusion:` set IS the emitted `enum`, and it was silently dropped for a Set — the reader admitted only
  # an exact Array — so the document advertised no constraint where the runtime enforced one.
  describe "schema reflection" do
    def input_schema_for(action)
      Axn::Internal::Reflection::Schema.build_input(action.internal_field_configs, action.subfield_configs)
    end

    it "emits the enum for a Set set, as it does for the Array spelling" do
      set_spelling = build_axn { expects :v, type: Integer, inclusion: { in: Set[1, 2] } }
      array_spelling = build_axn { expects :v, type: Integer, inclusion: { in: [1, 2] } }

      expect(input_schema_for(set_spelling)).to eq(input_schema_for(array_spelling))
      expect(input_schema_for(set_spelling).dig(:properties, :v, :enum)).to eq([1, 2])
    end

    it "emits a Hash set as its keys" do
      action = build_axn { expects :v, type: Integer, inclusion: { in: { 1 => :a, 2 => :b } } }
      expect(input_schema_for(action).dig(:properties, :v, :enum)).to eq([1, 2])
    end
  end

  # What lets the cross-product audit walk one spelling per container instead of two: the bare shorthand and the
  # long form canonicalize to the SAME stored entry, so no product over them could tell the two apart.
  describe "the bare shorthand and the long form" do
    # The entry as stored, less the tolerance keys the declaration push-down merges into every entry — those
    # are the same for both spellings and say nothing about the set.
    def stored_set(entry)
      build_axn { expects :v, type: Integer, inclusion: entry }
        .internal_field_configs.first.validations.dig(:inclusion, :in)
    end

    it "canonicalize to the same set" do
      expect(stored_set(Set[1, 2])).to eq(stored_set({ in: Set[1, 2] }))
      expect(stored_set(Set[1, 2])).to eq([1, 2])
    end

    it "leaves the Array and Range spellings ActiveModel already understood untouched" do
      expect(stored_set([1, 2])).to eq([1, 2])
      expect(stored_set(1..2)).to eq(1..2)
    end
  end

  # A Set SUBCLASS is deliberately left alone: its traversal is its own, so axn cannot read its members without
  # running the subclass's code, and the closed-world rule everywhere else in the guards applies here too.
  # It keeps ActiveModel's own behaviour, which is what it had before.
  it "stands down on a Set subclass rather than reading members it does not own" do
    subclass = Class.new(Set)
    action = build_axn { expects :v, type: Integer, inclusion: { in: subclass[1] } }
    expect(action.call(v: 1)).to be_ok
  end

  # The caller's own collection must not become the declaration's storage: canonicalizing reads members OUT of
  # it, and a set that keeps growing after the contract is declared is the aliasing defect the option-bag
  # detachment exists to prevent.
  it "does not alias the caller's Set" do
    set = Set[1]
    action = build_axn { expects :v, type: Integer, inclusion: { in: set } }
    set << 2

    expect(action.call(v: 1)).to be_ok
    expect(action.call(v: 2)).not_to be_ok
  end
end
