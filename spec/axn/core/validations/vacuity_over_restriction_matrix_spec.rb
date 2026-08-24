# frozen_string_literal: true

require "axn/testing/spec_helpers"
require "active_model"

# The vacuity guard's ONE unforgivable failure is refusing a declaration that enforces something. Every other
# error it can make — admitting a vacuous contract — is the direction its doctrine deliberately prefers.
#
# So this walks the product of {declared type} x {forbidden literal} x {tolerance} x {validator spelling} and,
# for every declaration the guard refuses, asks the REAL consumer whether some value of that type still fails
# the check. A single such value proves the refusal wrong. The oracle is the validator axn actually installs,
# not a re-derivation of it and not bare ActiveModel — whose `Clusivity` still distributes a set over an Array
# value, the reading PRO-3192 removed, and which would therefore answer for a runtime axn does not have.
#
# Written after the guard's fourth round of review findings all landed in one area: the answer was to probe
# the whole product at once rather than fix another instance. It found a real one that four rounds had not —
# `ComparisonValidator` rejects a blank value ahead of any bound, so `type: Array, comparison:
# { other_than: 1 }` really does reject `[]` and must not be refused.
RSpec.describe "the vacuity guard never refuses a declaration that enforces something" do
  # Ordinary values only. A subclass that lies about its own blankness or equality can defeat any static
  # judgment, and axn does not hold itself responsible for one — see the guard's own stand-down rules.
  let(:candidates_by_type) do
    {
      Array => [[], [1], %w[a]],
      Hash => [{}, { a: 1 }],
      Set => [Set[], Set[1]],
      String => ["", "  ", "x", "admin"],
      Integer => [0, 1, 2],
      Float => [0.0, 1.0, 2.5, Float::NAN],
      NilClass => [nil],
    }
  end

  let(:literals) do
    {
      "[]" => [], "[1]" => [1], '""' => "", '"  "' => "  ", '"admin"' => "admin",
      "nil" => nil, "false" => false, "1" => 1, "1.0" => 1.0, "NAN" => Float::NAN,
      "Set[]" => Set[], "{}" => {}
    }
  end

  let(:tolerances) { { "none" => {}, "allow_nil" => { allow_nil: true }, "allow_blank" => { allow_blank: true } } }

  # Whether some candidate makes this entry record an error — i.e. the check CAN fail, so it enforces.
  def can_fail?(entry, candidates)
    model = Class.new do
      include ActiveModel::Validations
      attr_accessor :v

      def self.name = "VacuityProbe"
    end

    if (opts = entry[:exclusion])
      opts = { in: opts } unless opts.is_a?(Hash)
      model.validates_with Axn::Validators::ExclusionValidator, attributes: [:v], **opts
    else
      model.validates :v, **entry
    end

    candidates.any? do |candidate|
      record = model.new
      record.v = candidate
      begin
        !record.valid? && record.errors[:v].any?
      rescue StandardError
        false # the check could not run at all; that is not a verdict about failing
      end
    end
  end

  # Only THIS guard's refusal is under audit. The container-position, hostile-container and satisfiability
  # guards refuse for their own reasons and have their own coverage.
  def vacuity_refusal?(type, entry)
    build_axn { expects :v, type:, **entry }
    false
  rescue ArgumentError => e
    e.message.include?("enforces nothing")
  end

  it "agrees with the runtime on every refusal across the product" do
    wrong = []
    exercised = 0

    candidates_by_type.each do |type, candidates|
      literals.each do |literal_name, literal|
        tolerances.each do |tolerance_name, tolerance|
          {
            "exclusion (Array set)" => { exclusion: { in: [literal] }.merge(tolerance) },
            "exclusion (Set set)" => { exclusion: { in: Set[literal] }.merge(tolerance) },
            "comparison other_than" => { comparison: { other_than: literal }.merge(tolerance) },
          }.each do |spelling, entry|
            exercised += 1
            next unless begin
              vacuity_refusal?(type, entry)
            rescue StandardError
              false # refused for an unrelated reason, or could not be declared at all
            end

            wrong << "#{type}/#{literal_name}/#{tolerance_name}/#{spelling}" if can_fail?(entry, candidates)
          end
        end
      end
    end

    expect(exercised).to be > 500 # a guard against the product silently shrinking to nothing
    expect(wrong).to be_empty, "the guard refused these, but a value of the declared type really fails the " \
                               "check:\n  #{wrong.join("\n  ")}"
  end
end
