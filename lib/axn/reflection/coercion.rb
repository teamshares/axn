# frozen_string_literal: true

require "date"
require "time"

module Axn
  module Reflection
    # Inbound wire DECODER — the parse-based inverse of Values.serialize_value, keyed off the same
    # class set so encoder and decoder can't drift. The single home for the wire→Ruby mapping: the
    # `coerce:` DSL (per-field, at runtime via Executor#apply_inbound_coercion!) and adapters (bulk,
    # by walking configs) both call this rather than reinventing it. Read-only, off the execution path.
    module Coercion
      module_function

      # The coercible target set. Date/DateTime/Time/Symbol/Integer/Float each have a strict,
      # unambiguous `String → T` parse and are the inverse of a Values.serialize_value branch.
      # `:boolean` is the one member with no encoder counterpart (a boolean serializes as itself,
      # not a string) — it's a purely inbound tolerance for the string/integer forms a JSON client
      # or Rails form sends. BigDecimal (String→decimal) is still deferred to its own ticket; a
      # coerce: target outside this set raises not-yet-supported at declaration (see
      # Contract#_validate_coercion!).
      SUPPORTED = [Date, DateTime, Time, Symbol, Integer, Float, :boolean].freeze

      # The canonical string forms `:boolean` accepts, matched case-insensitively after stripping.
      # Both sides are explicit (unlike Rails' "everything not falsy is true"), so an unrecognized
      # string is left uncoerced and fails validation rather than silently becoming `true`.
      TRUTHY_STRINGS = %w[1 true t yes y on].freeze
      FALSY_STRINGS = %w[0 false f no n off].freeze
      private_constant :TRUTHY_STRINGS, :FALSY_STRINGS

      # A coercible date/time wire string must be ISO-8601-SHAPED: a `YYYY-MM-DD` date, optionally
      # followed by a time (`T` or space separator, optional `:seconds`, optional `.fraction`, optional
      # `Z`/`±HH:MM` offset). This gates the heuristic `Date.parse`/`Time.parse` below, which would
      # otherwise turn ambiguous or partial input into a silently-wrong value against TODAY's date
      # (`"12"` → the 12th of the current month, `"01/02/2026"` → a locale-guessed order, `"14:30"` →
      # today at 14:30). It deliberately still accepts every real client format: JSON/RFC3339 (with a
      # `Z`/offset), a Rails `date_field` (`2026-07-08`), a `datetime-local` (`2026-07-08T14:30`, no
      # seconds or offset — parsed in the local zone, per the design), and Rails' `Time#to_s`
      # (`2026-07-08 14:30:00 +0000`). A bare time / month / week field has no date and is left for
      # normal validation. A shape mismatch raises so coerce_value leaves the value untouched.
      ISO_DATE_TIME = /\A\d{4}-\d{2}-\d{2}([T ]\d{2}:\d{2}(:\d{2}(\.\d+)?)?\s?(Z|[+-]\d{2}:?\d{2})?)?\z/
      private_constant :ISO_DATE_TIME

      # Each coercer parses a wire string into the target type; a parse that raises means "leave it"
      # (coerce_value returns the original). The date/time coercers are the inverse of iso8601, gated
      # behind ISO_DATE_TIME so ambiguous input isn't guessed against today; Symbol is the inverse of
      # to_s; Integer uses base 10 explicitly (bare `Integer("08")` raises on the octal ambiguity a
      # zero-padded form field trips). `:boolean` is the one coercer that also accepts a non-String
      # form (an Integer 0/1, or an already-boolean value) — see #coerce_boolean.
      COERCERS = {
        Date => ->(s) { ISO_DATE_TIME.match?(s) ? Date.parse(s) : raise(ArgumentError, "not an ISO-8601 date") },
        DateTime => ->(s) { ISO_DATE_TIME.match?(s) ? DateTime.parse(s) : raise(ArgumentError, "not an ISO-8601 date-time") },
        Time => ->(s) { ISO_DATE_TIME.match?(s) ? Time.parse(s) : raise(ArgumentError, "not an ISO-8601 date-time") },
        Symbol => lambda(&:to_sym),
        Integer => ->(s) { Integer(s, 10) },
        Float => ->(s) { Float(s) },
        :boolean => ->(v) { coerce_boolean(v) },
      }.freeze
      private_constant :COERCERS

      # Coerce-or-leave: a String is a coercion candidate for every target (a direct Ruby caller
      # passing a real Date, or a JSON-native number, is returned untouched); an Integer or an
      # already-boolean value is additionally a candidate for a `:boolean` target only. Union targets
      # are tried in declaration order; the first that parses wins; a parse that raises falls through
      # to the next, and if none parse the ORIGINAL value is returned so it hits the normal
      # TypeValidator error. A non-coercible target (e.g. String) is skipped — it never coerces, it's
      # only a validation branch.
      #
      # A blank string is never coerced: coercion must not change validation strictness, and Symbol's
      # `to_sym` would otherwise turn a blank required input ("" / "  ") into a non-blank Symbol that
      # slips past the presence validator. Leaving it a String means presence/type validation rejects
      # it exactly as it would an uncoerced field. (The parse-based coercers already leave blanks —
      # `Date.parse("")` raises — so this only changes the Symbol path, and unifies all of them.)
      def coerce_value(value, klass_or_klasses)
        targets = Array(klass_or_klasses)

        # A non-String value only ever coerces to `:boolean` (the integers 0/1, or an already-boolean
        # value idempotently). Handle it here so a bare Integer never reaches the String-only parse
        # coercers below; a String — including "0"/"1" — flows through the ordered loop so union
        # declaration order still decides which target wins. Coerce-or-leave still holds: a value
        # already valid under another declared target (e.g. a real Integer in a `[Integer, :boolean]`
        # union) is left untouched rather than rewritten to a boolean.
        if !value.is_a?(String) && targets.include?(:boolean) && !already_valid_for_target?(value, targets)
          begin
            return coerce_boolean(value)
          rescue ArgumentError, TypeError
            return value
          end
        end

        return value unless value.is_a?(String)
        return value if value.strip.empty?

        targets.each do |klass|
          coercer = COERCERS[klass]
          next unless coercer

          begin
            return coercer.call(value)
          rescue ArgumentError, TypeError
            next
          end
        end

        value
      end

      # Coerce a wire boolean into `true`/`false`, or raise ArgumentError (meaning "leave it") for any
      # value that isn't a recognized boolean form. Accepts an already-boolean value (idempotent), the
      # integers 0/1 (a JSON/loosely-typed client sending a flag as a number), and the canonical string
      # forms. Everything else — Integer 2, a Float, a blank/unrecognized string — is declined, so it
      # flows to TypeValidator exactly as an uncoerced value would (never silently becoming `true`).
      def coerce_boolean(value)
        return value if [true, false].include?(value)

        if value.is_a?(Integer)
          return true if value == 1
          return false if value.zero?
        elsif value.is_a?(String)
          normalized = value.strip.downcase
          return true if TRUTHY_STRINGS.include?(normalized)
          return false if FALSY_STRINGS.include?(normalized)
        end

        raise ArgumentError, "#{value.inspect} is not a recognized boolean form"
      end

      # Whether a non-String value is already a valid instance of some declared coercion target other
      # than `:boolean` — in which case boolean coercion must not fire (coerce-or-leave). Only the
      # class targets are checked; `:boolean` is a Symbol, and a real true/false is handled idempotently
      # by coerce_boolean itself, so it's fine to leave it out of this "leave it as-is" guard.
      def already_valid_for_target?(value, targets)
        targets.any? { |t| t.is_a?(Class) && value.is_a?(t) }
      end

      # The coercible subset of a type: option's klass(es) — the single source of truth for "what does
      # this field coerce to", consulted by both the declaration-time guard and the runtime step.
      def coercible_klasses(type_opt)
        klass = type_opt.is_a?(Hash) ? type_opt[:klass] : type_opt
        Array(klass).select { |k| SUPPORTED.include?(k) }
      end
    end
  end
end
