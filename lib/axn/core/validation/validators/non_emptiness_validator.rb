# frozen_string_literal: true

require "active_model"

module Axn
  module Validators
    # The check `allow_empty: false` installs when nothing else in the declaration already forbids an empty
    # value. It asks the value itself — `empty?` — which is the question the flag is about: a whitespace-only
    # String is blank but not empty, and so admissible, while an empty collection is rejected however its
    # size reads.
    #
    # ActiveModel's `length: { minimum: 1 }` cannot ask it. LengthValidator measures
    # `value.respond_to?(:length) ? value.length : value.to_s.length` (activemodel 7.2.2.2), so a value that
    # reports no size is measured by its rendering: an empty `ActionController::Parameters` renders as "{}"
    # and clears a floor of 1 — while the emitted schema, which reads the declared floor, says
    # `minProperties: 1`.
    #
    # A value that does not answer `empty?` splits in two, and the declared klasses the entry carries are what
    # tell them apart. A value the declared type does NOT match is simply the wrong type: its single error
    # belongs to TypeValidator, and this check stands aside rather than reporting the same defect twice. A
    # value the type DOES match cannot be judged at all — the declaration guard proved the TYPE has an empty
    # state (Contract `_emptiable_type?`), not that every instance keeps the method — so the contract is
    # unverifiable, and saying so is the only honest outcome: silently accepting would let an explicit
    # `allow_empty: false` go unenforced.
    class NonEmptinessValidator < ActiveModel::EachValidator
      # Whether the value HAS a public `empty?`, asked through `Object`'s own implementation bound to the
      # value. A caller's `respond_to?` is the caller's to define — a proxy or delegator routinely answers
      # for methods it forwards, and one that answers `false` for `empty?` would otherwise disable a
      # contract the declaration made — so the capability is asked of the object, not of its answer about
      # itself.
      #
      # This is the same question the declaration guard asks of the declared type
      # (`Contract._emptiable_type?`), in the one form that is both unforgeable and total: asking the value's
      # CLASS misses an `empty?` the value carries on its singleton (a value that `extend`s the declared
      # module) and raises on a `BasicObject`, and asking its `singleton_class` raises a TypeError for a
      # frozen or immediate value. A hardening that raises on a weird-but-legal value would be worse than
      # the hole it closes.
      CAPABILITY_CHECK = ::Object.instance_method(:respond_to?)

      # EachValidator applies allow_nil:/allow_blank: before this runs, so the entry's nil-tolerance has
      # already skipped a nil (the nil axis is `optional:`/`allow_nil:` and the type check's business).
      def validate_each(record, attribute, value)
        unless CAPABILITY_CHECK.bind_call(value, :empty?)
          record.errors.add(attribute, "cannot be checked for emptiness: it has no empty? method") if unanswerable?(value)
          return
        end

        record.errors.add(attribute, options[:message] || "can't be empty") if value.empty?
      end

      private

      # Whether a value that cannot answer `empty?` is nonetheless one this contract is responsible for —
      # it satisfies the declared type, so no other check will report it and its emptiness simply cannot be
      # established. Asked through TypeValidator's own matcher, so "matches the declared type" has one
      # definition. A test double is waived on the same terms type validation waives it: it stands in for a
      # value of the declared type rather than being one, and reporting it here would fail a spec that
      # deliberately supplied a stand-in.
      def unanswerable?(value)
        return false if Axn::Validators::TypeValidator.mock_value?(value)

        Array(options[:klass]).any? { |klass| Axn::Validators::TypeValidator.value_matches?(value, klass:) }
      rescue TypeError
        # A `type:` that is neither a Class/Module nor a known pseudo-type is a broken declaration whose
        # TypeError belongs to the type check, where it already surfaces. Stand down rather than preempting it.
        false
      end
    end
  end
end
