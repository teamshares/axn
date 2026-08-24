# frozen_string_literal: true

require "axn/testing/spec_helpers"

# The SOUNDNESS invariant for the empty-interval guard, checked mechanically rather than case by case: if it
# refuses a declaration, then no value satisfies that declaration. Over-restriction is the one direction a
# declaration-time guard must never err in — a rejected contract cannot be recovered from at runtime — while
# under-restriction merely leaves a broken contract declaring, which every stand-down here deliberately does.
#
# Written after four review rounds whose findings were one class: the guard read a declaration's SHAPE where
# its EFFECT was the question (`size` for `length`, "a presence entry exists" for "a presence entry rejects
# something", an entry's own gate for "does this run at all"). Enumerating the product and measuring against
# the real runtime is what closes that class; a hand-written example per case is what kept re-opening it.
#
# The measurement builds each contract with the guard STUBBED OFF on that one class, then runs axn's own
# validation over a candidate spread — so "does anything pass" is answered by the runtime rather than by a
# second model of it.
module SizeSoundness
  CANDIDATES = [
    nil, [], ["a"], %w[a b], %w[a b c], "", " ", "  ", "a", "abc", "abcd",
    {}, { a: 1 }, { a: 1, b: 2 }, 0, 5, false, true
  ].freeze

  FLOORS = {
    "-" => {},
    "presence: true" => { presence: true },
    "presence: blank-tolerant" => { presence: { allow_blank: true } },
    "presence: false" => { presence: false },
    "allow_empty: false" => { allow_empty: false },
    "allow_empty: true" => { allow_empty: true },
    "presence gated" => { presence: { if: -> { false } } },
    "length minimum 1" => { length: { minimum: 1 } },
    "length minimum 2" => { length: { minimum: 2 } },
    "length minimum 2 gated" => { length: { minimum: 2, if: -> { false } } },
  }.freeze

  CEILINGS = {
    "-" => {},
    "absence" => { absence: true },
    "absence gated" => { absence: { if: -> { false } } },
    "absence blank-tolerant" => { absence: { allow_blank: true } },
    "absence: false" => { absence: false },
    "length maximum 0" => { length: { maximum: 0 } },
    "length maximum 0 gated" => { length: { maximum: 0, unless: -> { true } } },
    "length maximum 1" => { length: { maximum: 1 } },
  }.freeze

  # Members whose own code decides what they match or how they measure — the axes the member scan consults
  # beyond the declared type, each built fresh so a singleton definition belongs to this object alone.
  #
  # Both are wired to a value that is IN the candidate spread, without which the product would contain the
  # cell and still prove nothing: an over-restriction is only observable when some candidate actually passes.
  def self.singleton_equality_member
    member = []
    member.define_singleton_method(:==) { |other| other == ["a"] }
    member
  end

  def self.singleton_length_member
    member = ["a"]
    member.define_singleton_method(:length) { 0 }
    member
  end

  SETS = {
    "-" => {},
    "inclusion [[]]" => { inclusion: { in: [[]] } },
    "inclusion [[]] gated" => { inclusion: { in: [[]], if: -> { false } } },
    "inclusion [[], [1]]" => { inclusion: { in: [[], [1]] } },
    "inclusion blank-tolerant" => { inclusion: { in: [%w[a b c]], allow_blank: true } },
    "inclusion [\"ab\"]" => { inclusion: { in: %w[ab] } },
    "inclusion [member with singleton ==]" => { inclusion: { in: [singleton_equality_member] } },
    "inclusion [member with singleton length]" => { inclusion: { in: [singleton_length_member] } },
  }.freeze

  MODIFIERS = {
    "-" => {},
    "declaration if:" => { if: -> { false } },
    "declaration if: with blank nested overrides" =>
      { if: -> { false }, presence: { if: nil }, absence: { if: nil }, length: { if: nil }, inclusion: { if: nil } },
    "declaration unless:" => { unless: -> { true } },
    "optional" => { optional: true },
  }.freeze

  REFUSAL = /admits? no value at all|can never match — every value/

  TYPES = {
    "Array" => Array, "Hash" => Hash, "String" => String, "Integer" => Integer, "an undeclared type" => nil
  }.freeze

  # `length:` appears in both the floor and the ceiling axis, so the two bags are merged one level deeper
  # rather than clobbering each other — which is what puts `minimum: 2, maximum: 1` in the product at all.
  def self.merge_options(*bags)
    bags.reduce({}) do |acc, bag|
      lengths = [acc[:length], bag[:length]].compact
      merged = acc.merge(bag)
      lengths.size < 2 ? merged : merged.merge(length: lengths.reduce(:merge))
    end
  end
end

RSpec.describe "the empty-interval guard's soundness" do
  # The same declaration, with this one class's guard replaced by a no-op. Defined on the action's own
  # singleton, so nothing leaks to any other example.
  def build_unguarded(**opts)
    klass = Class.new { include Axn }
    klass.singleton_class.send(:define_method, :_reject_unsatisfiable_size_interval!) { |_validations, where:| nil } # rubocop:disable Lint/UnusedBlockArgument
    klass.expects(:f, **opts)
    klass
  end

  def values_passing(action)
    SizeSoundness::CANDIDATES.select do |value|
      action.call(f: value).ok?
    rescue StandardError
      false
    end
  end

  SizeSoundness::TYPES.each do |type_label, type_klass|
    it "refuses nothing satisfiable on #{type_label}" do
      offenders = []

      SizeSoundness::FLOORS.each do |floor_label, floor|
        SizeSoundness::CEILINGS.each do |ceiling_label, ceiling|
          SizeSoundness::SETS.each do |set_label, set|
            SizeSoundness::MODIFIERS.each do |modifier_label, modifier|
              opts = SizeSoundness.merge_options(floor, ceiling, set, modifier)
              opts = opts.merge(type: type_klass) if type_klass

              begin
                build_axn { expects :f, **opts }
                next # declared: nothing to check
              rescue ArgumentError => e
                next unless e.message.match?(SizeSoundness::REFUSAL)
              rescue StandardError
                next # refused by some other rule, which this spec does not speak for
              end

              passing = begin
                values_passing(build_unguarded(**opts))
              rescue StandardError
                [] # undeclarable even unguarded
              end
              next if passing.empty?

              offenders << "#{floor_label} | #{ceiling_label} | #{set_label} | #{modifier_label} " \
                           "=> accepts #{passing.inspect}"
            end
          end
        end
      end

      expect(offenders).to eq([])
    end
  end
end
