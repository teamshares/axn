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

      # The types with a strict, unambiguous `String → T` parse. `:boolean` (lenient/ambiguous) and
      # BigDecimal (String→decimal) are deferred to their own tickets — a coerce: target outside this
      # set raises not-yet-supported at declaration (see Contract#_validate_coercion!).
      SUPPORTED = [Date, DateTime, Time, Symbol, Integer, Float].freeze

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

      # Each coercer is the inverse of the corresponding Values.serialize_value branch (iso8601 for
      # Date/Time/DateTime, to_s for Symbol). The date/time coercers gate `.parse` behind ISO_DATE_TIME
      # (raising on a mismatch, which coerce_value treats as "leave it"). Integer uses base 10
      # explicitly — bare `Integer("08")` raises on the octal ambiguity a zero-padded form field trips.
      COERCERS = {
        Date => ->(s) { ISO_DATE_TIME.match?(s) ? Date.parse(s) : raise(ArgumentError, "not an ISO-8601 date") },
        DateTime => ->(s) { ISO_DATE_TIME.match?(s) ? DateTime.parse(s) : raise(ArgumentError, "not an ISO-8601 date-time") },
        Time => ->(s) { ISO_DATE_TIME.match?(s) ? Time.parse(s) : raise(ArgumentError, "not an ISO-8601 date-time") },
        Symbol => lambda(&:to_sym),
        Integer => ->(s) { Integer(s, 10) },
        Float => ->(s) { Float(s) },
      }.freeze
      private_constant :COERCERS

      # Coerce-or-leave: only a String is a coercion candidate (a direct Ruby caller passing a real
      # Date, or a JSON-native number, is returned untouched). Union targets are tried in declaration
      # order; the first that parses wins; a parse that raises falls through to the next, and if none
      # parse the ORIGINAL value is returned so it hits the normal TypeValidator error. A non-coercible
      # target (e.g. String) is skipped — it never coerces, it's only a validation branch.
      #
      # A blank string is never coerced: coercion must not change validation strictness, and Symbol's
      # `to_sym` would otherwise turn a blank required input ("" / "  ") into a non-blank Symbol that
      # slips past the presence validator. Leaving it a String means presence/type validation rejects
      # it exactly as it would an uncoerced field. (The parse-based coercers already leave blanks —
      # `Date.parse("")` raises — so this only changes the Symbol path, and unifies all of them.)
      def coerce_value(value, klass_or_klasses)
        return value unless value.is_a?(String)
        return value if value.strip.empty?

        Array(klass_or_klasses).each do |klass|
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

      # The coercible subset of a type: option's klass(es) — the single source of truth for "what does
      # this field coerce to", consulted by both the declaration-time guard and the runtime step.
      def coercible_klasses(type_opt)
        klass = type_opt.is_a?(Hash) ? type_opt[:klass] : type_opt
        Array(klass).select { |k| SUPPORTED.include?(k) }
      end
    end
  end
end
