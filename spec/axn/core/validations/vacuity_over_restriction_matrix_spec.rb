# frozen_string_literal: true

require "axn/testing/spec_helpers"
require "active_model"
require "active_support/core_ext/object/blank"
require "bigdecimal"
require "date"

# The ONE unforgivable failure of either guard is refusing a declaration that enforces something. Every other
# error they can make — admitting a broken contract — is the direction their doctrine deliberately prefers.
#
# So this walks the product of {declared type} x {literal} x {tolerance} x {validator spelling} and, for every
# declaration a guard refuses, asks the REAL consumer whether the refusal was earned:
#
#   * VACUITY ("enforces nothing") is wrong if the check DISCRIMINATES — some value of the declared type fails
#     it while another passes. A check that rejects every value is the mirror defect, not a working contract.
#   * SATISFIABILITY ("can never match") is wrong if some value still PASSES the whole contract.
#
# Both oracles are the machinery axn actually installs, not a re-derivation of it and not bare ActiveModel —
# whose `Clusivity` still distributes a set over an Array value, the reading PRO-3192 removed, and which would
# therefore answer for a runtime axn does not have. The satisfiability oracle is deliberately in two halves,
# because that verdict is about the whole contract rather than one entry: the entry must admit the value AND the
# rest of the declaration must admit it too, and the second half is asked by declaring the same field without
# the constrained entry and calling it.
#
# Written after the vacuity guard's fourth round of review findings all landed in one area: the answer was to
# probe the whole product at once rather than fix another instance. It found a real one that four rounds had
# not — `ComparisonValidator` rejects a blank value ahead of any bound, so `type: Array, comparison:
# { other_than: 1 }` really does reject `[]` and must not be refused. Extended for PRO-3228 with Range
# spellings and the satisfiability direction, which found a second: the satisfiability guard ignored
# `allow_blank`, so it refused `type: Array, presence: false, inclusion: { in: [1], allow_blank: true }`, which
# accepts `[]` and rejects `["a"]`.
RSpec.describe "the vacuity and satisfiability guards never refuse a declaration that enforces something", :slow do
  # Ordinary values only. A subclass that lies about its own blankness or equality can defeat any static
  # judgment, and axn does not hold itself responsible for one — see the guards' own stand-down rules.
  let(:candidates_by_type) do
    {
      Array => [[], [1], %w[a]],
      Hash => [{}, { a: 1 }],
      Set => [Set[], Set[1]],
      String => ["", "  ", "x", "admin", "a", "b"],
      Integer => [0, 1, 2],
      Float => [0.0, 1.0, 2.5, Float::NAN],
      BigDecimal => [BigDecimal("0"), BigDecimal("1"), BigDecimal::NAN],
      Date => [Date.new(2020, 1, 1), Date.new(2020, 1, 2)],
      NilClass => [nil],
    }
  end

  let(:literals) do
    {
      "[]" => [], "[1]" => [1], '""' => "", '"  "' => "  ", '"admin"' => "admin",
      "nil" => nil, "false" => false, "1" => 1, "1.0" => 1.0, "NAN" => Float::NAN,
      "BigDecimal::NAN" => BigDecimal::NAN, "BigDecimal(1)" => BigDecimal("1"),
      "Set[]" => Set[], "{}" => {}
    }
  end

  # Range set spellings, kept separate from the scalar literals because a Range is not a literal a set can
  # CONTAIN — it IS the set. Each degenerate shape (exclusive-endpoints-meet, reversed) is paired with an
  # ordinary one of the same bound type, so the audit covers the refusals and the stand-downs together.
  let(:range_sets) do
    day = Date.new(2020, 1, 1)
    {
      "(1...1)" => (1...1), "(2..1)" => (2..1), "(1..2)" => (1..2), "(1..1)" => (1..1),
      "(1.0...1.0)" => (1.0...1.0), "(2.0..1.0)" => (2.0..1.0), "(1.0..2.0)" => (1.0..2.0),
      "(1..)" => (1..), "(..1)" => (..1),
      '("a"..."a")' => ("a"..."a"), '("b".."a")' => ("b".."a"), '("a".."b")' => ("a".."b"),
      "(day...day)" => (day...day), "(day..day)" => (day..day),
      "([\"a\"]...[\"a\"])" => (["a"]...["a"])
    }
  end

  let(:tolerances) { { "none" => {}, "allow_nil" => { allow_nil: true }, "allow_blank" => { allow_blank: true } } }

  # The rest of the declaration, varied because both verdicts depend on it: `presence: false` admits a blank
  # value, which is what makes a blank-tolerant entry satisfiable — and a SIBLING validator can then reject that
  # blank right back, which decides whether the blank is really a witness. Both polarities of the sibling are
  # walked (one forbidding the blank, one forbidding something else), since a sibling may neither veto the
  # stand-down outright nor be ignored.
  let(:contexts) do
    {
      "default" => {},
      "presence: false" => { presence: false },
      "sibling forbids blank" => { presence: false, exclusion: { in: [[], "", :"", {}] } },
      "sibling forbids other" => { presence: false, exclusion: { in: [%w[zzz], "zzz"] } },
      "sibling unreadable" => { presence: false, validate: ->(value) { "bad" if value.nil? } },
      "acceptance sibling" => { presence: false, acceptance: { accept: [%w[ok], "ok"] } },
    }
  end

  # A bare ActiveModel model carrying the entry as axn really installs it — axn's own Clusivity validators for
  # inclusion/exclusion, ActiveModel's own for everything else.
  def probe_model(entry)
    model = Class.new do
      include ActiveModel::Validations
      attr_accessor :v

      def self.name = "GuardProbe"
    end

    %i[exclusion inclusion].each do |key|
      next unless (opts = entry[key])

      opts = { in: opts } unless opts.is_a?(Hash)
      validator = key == :exclusion ? Axn::Validators::ExclusionValidator : Axn::Validators::InclusionValidator
      model.validates_with validator, attributes: [:v], **opts
      return model
    end

    model.validates :v, **entry
    model
  end

  # What the ENTRY does with this candidate. The three outcomes are kept distinct because the two directions
  # read a RAISE oppositely: a check that blows up has not rejected the value (so it is no evidence the check
  # can fail) and it certainly has not admitted it either (so it is no evidence anything passes). Collapsing
  # the two into a boolean is what made the first draft of this audit report false positives on
  # `(["a"]...["a"])`, whose `include?` raises `TypeError: can't iterate from Array` on every call.
  def entry_outcome(entry, candidate)
    record = probe_model(entry).new
    record.v = candidate
    record.valid? && record.errors[:v].empty? ? :accept : :reject
  rescue StandardError
    :raise
  end

  # Whether the check DISCRIMINATES: some value of the declared type fails it while some other value passes.
  # That, rather than "some value fails", is what "enforces something" means — and the difference matters for a
  # check that rejects EVERY value, which is the mirror defect (unsatisfiable) rather than a working contract.
  # Such a declaration is refusable in either wording, so it is no counterexample to a vacuity refusal.
  # Measured instance: `type: Date, comparison: { other_than: Float::NAN }`, where `Date <=> NaN` raises
  # ArgumentError (Date reads a Numeric bound as an Astronomical Julian Day Number and cannot convert a NaN),
  # ActiveModel turns the raise into an error, and every Date is rejected.
  def can_fail?(entry, validator_key, candidates)
    audited = entry.slice(validator_key)
    outcomes = candidates.map { |candidate| entry_outcome(audited, candidate) }

    outcomes.include?(:reject) && outcomes.include?(:accept)
  end

  # Whether some candidate passes BOTH halves of the contract: the constrained entry, and everything else the
  # declaration installs. The second half is axn's own — the same field, declared without the entry under
  # audit, and actually called.
  # Returns nil when the question cannot be put: the REST of the declaration may itself be a contract a guard
  # refuses (a sibling set that is vacuous for this type), and there is then no contract to ask about the
  # candidate. Counted rather than folded into either answer, so a growing pile of undecidables cannot quietly
  # hollow the audit out.
  # The candidates that pass BOTH halves, or nil when the question cannot be put.
  def satisfiability_passers(type, entry, validator_key, candidates)
    audited = entry.slice(validator_key)
    others = declare_or_nil(type, entry.except(validator_key))
    return nil if others.nil?

    candidates.select do |candidate|
      next false unless entry_outcome(audited, candidate) == :accept

      others.call(v: candidate).ok?
    rescue StandardError
      false
    end
  end

  # The OTHER half of the invariant: "the projection of a satisfiable contract must itself be satisfiable"
  # (AGENTS.md). An `inclusion:` set IS the emitted `enum`, and a blank that passes only by being SKIPPED is
  # never a member of it — so where the survivors are all blanks the node admits nothing at all
  # (`{type: "array", enum: [1]}` takes neither `1` nor `[]`), and the refusal is earned even though the runtime
  # accepts a value. Restricted to the enum-emitting validators because that is measured: `comparison:` and
  # `acceptance:` carry none of their literals into the schema, so their nodes stay satisfiable and a blank
  # really does rescue them.
  def enum_emitting_keys = %i[inclusion]

  def projection_unsatisfiable?(validator_key, passers)
    enum_emitting_keys.include?(validator_key) && passers.all?(&:blank?)
  end

  # The rest of the declaration as an action, or nil when that half is itself a contract a guard refuses.
  def declare_or_nil(type, rest)
    build_axn { expects :v, type:, **rest }
  rescue StandardError
    nil
  end

  # Which guard refused the entry UNDER AUDIT, if either. Scoped by the key the message names, because a
  # surrounding sibling can be refused by the same guards for its own reasons — a `sibling forbids blank`
  # exclusion set is vacuous on a type whose blank it cannot be — and attributing that to the audited entry
  # reports a finding against a verdict nobody made about it. Only these two guards are under audit; the
  # container-position and hostile-container ones have their own coverage.
  def refusal(type, entry, validator_key)
    build_axn { expects :v, type:, **entry }
    nil
  rescue ArgumentError => e
    return nil unless e.message.start_with?("#{validator_key}:")
    return :vacuous if e.message.include?("enforces nothing")

    :unsatisfiable if e.message.include?("can never match")
  end

  # {spelling => [entry, validator_key]} for one literal/tolerance/context combination. The inverted spellings
  # are audited for vacuity, the non-inverted ones for satisfiability, which is exactly how the guards split.
  def spellings_for(literal, tolerance, context)
    {
      "exclusion (Array set)" => [{ exclusion: { in: [literal] }.merge(tolerance) }, :exclusion],
      "exclusion (Set set)" => [{ exclusion: { in: Set[literal] }.merge(tolerance) }, :exclusion],
      "comparison other_than" => [{ comparison: { other_than: literal }.merge(tolerance) }, :comparison],
      "inclusion (Array set)" => [{ inclusion: { in: [literal] }.merge(tolerance) }, :inclusion],
      "inclusion (Set set)" => [{ inclusion: { in: Set[literal] }.merge(tolerance) }, :inclusion],
      "comparison equal_to" => [{ comparison: { equal_to: literal }.merge(tolerance) }, :comparison],
      "comparison greater_than" => [{ comparison: { greater_than: literal }.merge(tolerance) }, :comparison],
    }.transform_values { |entry, key| [context.merge(entry), key] }
  end

  def range_spellings_for(range, tolerance, context)
    {
      "exclusion (Range)" => [{ exclusion: { in: range }.merge(tolerance) }, :exclusion],
      "inclusion (Range)" => [{ inclusion: { in: range }.merge(tolerance) }, :inclusion],
    }.transform_values { |entry, key| [context.merge(entry), key] }
  end

  # The audit itself, shared by both products below: for every refusal, ask the runtime whether it was earned.
  # Returns the unearned refusals alongside a tally, because a green audit proves nothing unless the product
  # actually reached both verdicts — an audit that refuses nothing agrees with the runtime trivially.
  def audit(sets)
    wrong = []
    tally = { examined: 0, vacuous: 0, unsatisfiable: 0, undecidable: 0 }

    candidates_by_type.each do |type, candidates|
      sets.each do |literal_name, literal|
        tolerances.each do |tolerance_name, tolerance|
          contexts.each do |context_name, context|
            yield(literal, tolerance, context).each do |spelling, (entry, validator_key)|
              tally[:examined] += 1
              verdict = begin
                refusal(type, entry, validator_key)
              rescue StandardError
                nil # refused for an unrelated reason, or could not be declared at all
              end
              next if verdict.nil?

              tally[verdict] += 1
              if verdict == :vacuous
                earned = !can_fail?(entry, validator_key, candidates)
              else
                passers = satisfiability_passers(type, entry, validator_key, candidates)
                if passers.nil?
                  tally[:undecidable] += 1
                  next
                end
                earned = passers.empty? || projection_unsatisfiable?(validator_key, passers)
              end
              next if earned

              wrong << "#{verdict}: #{type}/#{literal_name}/#{tolerance_name}/#{context_name}/#{spelling}"
            end
          end
        end
      end
    end

    [wrong, tally]
  end

  def expect_audit_clean(wrong, tally, examined:)
    aggregate_failures do
      expect(tally[:examined]).to be > examined # the product has not silently shrunk to nothing
      expect(tally[:vacuous]).to be > 0, "no vacuity refusal was exercised at all"
      expect(tally[:unsatisfiable]).to be > 0, "no satisfiability refusal was exercised at all"
      # An undecidable combination is one whose non-audited half is itself refused, so there is no contract to
      # ask about. Bounded rather than merely counted: if this ever dominates, the audit is checking far less
      # than its size suggests.
      expect(tally[:undecidable]).to be < (tally[:vacuous] + tally[:unsatisfiable]) / 2
      expect(wrong).to be_empty, "these refusals are not earned — the runtime disagrees:\n  #{wrong.join("\n  ")}"
    end
  end

  it "agrees with the runtime on every refusal across the scalar-literal product" do
    wrong, tally = audit(literals) { |literal, tolerance, context| spellings_for(literal, tolerance, context) }

    expect_audit_clean(wrong, tally, examined: 2000)
  end

  it "agrees with the runtime on every refusal across the Range-set product" do
    wrong, tally = audit(range_sets) { |range, tolerance, context| range_spellings_for(range, tolerance, context) }

    expect_audit_clean(wrong, tally, examined: 500)
  end
end
