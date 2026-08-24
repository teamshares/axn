# frozen_string_literal: true

require "spec_helper"

# A validator option axn admits should either pass a value it accepts or report a validation FAILURE for one
# it rejects. The third outcome — a declaration that is accepted and then raises on every call — is the shape
# this suite exists to catch, because nothing else does: the key is on the known-keys list, so no declaration
# guard fires, and the raise settles as an exception outcome reading "Something went wrong", naming neither the
# field nor the option, and reports through `Axn.config.on_exception` as an internal error.
#
# The specific hazard is a dependency axn never declared. ActiveModel reaches several of these options through
# ActiveSupport CORE EXTENSIONS, and `lib/axn.rb` requires `active_support` rather than `active_support/all` —
# which loads the lazy-load hooks and a handful of core_ext files, not the rest. A missing one is invisible
# inside Rails (which loads the full set) and fatal outside it, so it is precisely the "works outside Rails"
# non-negotiable, and `spec/` is the suite that runs without Rails.
#
# Scoped to the bound- and range-taking options, which is where that hazard lives — `numericality: { in: }`
# reaches `Object#in?`, while `length:`/`inclusion:` reach a Range through `cover?`/`include?` and are the
# controls that prove the suite is not vacuous. `uniqueness:` is deliberately absent: it raises for a
# different reason (no ActiveRecord validator class, no relation to query) and its disposal is PRO-3219's.
RSpec.describe "runtime reachability of a validator option" do
  # A value the option should ACCEPT, so a validation failure is as much a finding as a raise.
  accepted_values = {
    "numericality: { in: range }" => [{ numericality: { in: 1..10 } }, 5],
    "numericality: { greater_than: }" => [{ numericality: { greater_than: 1 } }, 5],
    "numericality: { greater_than_or_equal_to: }" => [{ numericality: { greater_than_or_equal_to: 5 } }, 5],
    "numericality: { less_than: }" => [{ numericality: { less_than: 10 } }, 5],
    "numericality: { less_than_or_equal_to: }" => [{ numericality: { less_than_or_equal_to: 5 } }, 5],
    "numericality: { equal_to: }" => [{ numericality: { equal_to: 5 } }, 5],
    "numericality: { other_than: }" => [{ numericality: { other_than: 1 } }, 5],
    "numericality: { odd: }" => [{ numericality: { odd: true } }, 5],
    "numericality: { even: }" => [{ numericality: { even: true } }, 4],
    "numericality: { only_integer: }" => [{ numericality: { only_integer: true } }, 5],
    "numericality: { only_numeric: }" => [{ numericality: { only_numeric: true } }, 5],
    "comparison: { greater_than: }" => [{ comparison: { greater_than: 1 } }, 5],
    "comparison: { other_than: }" => [{ comparison: { other_than: 1 } }, 5],
    "length: { in: range }" => [{ length: { in: 1..10 } }, "abc"],
    "length: { within: range }" => [{ length: { within: 1..10 } }, "abc"],
    "length: { is: }" => [{ length: { is: 3 } }, "abc"],
    "inclusion: { in: range }" => [{ inclusion: { in: 1..10 } }, 5],
    "inclusion: { in: array }" => [{ inclusion: { in: %w[a b] } }, "a"],
    "inclusion: { within: array }" => [{ inclusion: { within: %w[a b] } }, "a"],
    "exclusion: { in: range }" => [{ exclusion: { in: 100..200 } }, 5],
    "exclusion: { in: array }" => [{ exclusion: { in: %w[x] } }, "a"],
    "format: { with: }" => [{ format: { with: /\Aa/ } }, "abc"],
    "format: { without: }" => [{ format: { without: /\Az/ } }, "abc"],
  }.freeze

  accepted_values.each do |label, (validations, accepted)|
    it "accepts a conforming value under #{label}" do
      action = build_axn { expects :f, **validations, optional: true }

      result = action.call(f: accepted)

      # Named separately so the failure message says WHICH of the two findings this is: a raise means the
      # option is unreachable, a validation failure means it is reachable but this suite's fixture is wrong.
      expect(result.exception).to be_nil
      expect(result).to be_ok
    end
  end

  # The discriminating case, and the reason the suite exists. `RANGE_CHECKS` is `{ in: :in? }`, and
  # `Object#in?` lives in `active_support/core_ext/object/inclusion` — which `require "active_support"` does
  # not load. Every call raised `NoMethodError: undefined method 'in?'`, for a value inside the range.
  it "reaches Object#in?, which ActiveModel's numericality RANGE_CHECKS validates through" do
    expect(5).to respond_to(:in?)
    expect(5.in?(1..10)).to be(true)
  end

  it "still reports a validation failure for a value outside a numericality range" do
    action = build_axn { expects :f, numericality: { in: 1..10 }, optional: true }

    result = action.call(f: 0)

    expect(result).not_to be_ok
    expect(result.exception).to be_a(Axn::InboundValidationError)
  end
end
