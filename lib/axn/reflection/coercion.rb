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

      # Each coercer is the inverse of the corresponding Values.serialize_value branch (iso8601 for
      # Date/Time/DateTime, to_s for Symbol). Integer uses base 10 explicitly — bare `Integer("08")`
      # raises on the octal ambiguity a zero-padded form field would trip.
      COERCERS = {
        Date => ->(s) { Date.parse(s) },
        DateTime => ->(s) { DateTime.parse(s) },
        Time => ->(s) { Time.parse(s) },
        Symbol => lambda(&:to_sym),
        Integer => ->(s) { Integer(s, 10) },
        Float => ->(s) { Float(s) },
      }.freeze

      # Coerce-or-leave: only a String is a coercion candidate (a direct Ruby caller passing a real
      # Date, or a JSON-native number, is returned untouched). Union targets are tried in declaration
      # order; the first that parses wins; a parse that raises falls through to the next, and if none
      # parse the ORIGINAL value is returned so it hits the normal TypeValidator error. A non-coercible
      # target (e.g. String) is skipped — it never coerces, it's only a validation branch.
      def coerce_value(value, klass_or_klasses)
        return value unless value.is_a?(String)

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
