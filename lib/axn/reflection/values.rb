# frozen_string_literal: true

require "date"
require "time"

# NOTE: we don't require "active_support/core_ext/object/json" here, but a Rails app loads it globally
# — which adds a generic Object#as_json (an instance-variable dump). To avoid that bypassing a value
# object's declared `to_h` shape, `serialize_value` only follows `as_json` when the object defines its
# OWN (see custom_as_json?); a plain object with a meaningful `to_h` serializes via `to_h` in Rails and
# non-Rails alike.

module Axn
  module Reflection
    module Values
      module_function

      # Result → JSON-safe Hash keyed by wire key (string), over declared outbound configs.
      def serialize_exposed(result, field_configs)
        field_configs.each_with_object({}) do |config, hash|
          hash[config.field.to_s] = serialize_value(result.public_send(config.field))
        end
      end

      def serialize_value(value)
        case value
        when nil, String, Integer, Float, TrueClass, FalseClass
          value
        when Symbol
          # JSON has no symbol type — render deterministically as its String form, matching
          # the schema's `type: Symbol` => "string" mapping (Axn::Reflection::Schema::TYPE_MAP),
          # rather than relying on the generic `to_s` fallback below (which happens to agree).
          value.to_s
        when Numeric
          # BigDecimal / Rational etc. — emit a JSON number so output matches the schema's "number" type.
          # JSON has no decimal type (any JSON number is a double), so a Float representation is the correct
          # wire form; a caller needing exact decimals should expose type: String. Integer/Float are already
          # handled above. A non-real Numeric (Complex) can't become a Float — fall back to its string form.
          begin
            Float(value)
          rescue ArgumentError, TypeError, RangeError
            value.to_s
          end
        when Hash
          value.transform_keys(&:to_s).transform_values { |v| serialize_value(v) }
        when Array
          value.map { |v| serialize_value(v) }
        when Time, DateTime, Date
          # Rendered as RFC3339/ISO-8601 regardless of Rails, matching the schema's
          # `date`/`date-time` `format:` (see Reflection::Schema::FORMAT_MAP) — both inside and
          # outside Rails, so `serialize_exposed` output validates against the reflected schema.
          value.iso8601
        else
          if follow_as_json?(value)
            serialize_value(value.as_json)
          elsif value.respond_to?(:to_h)
            serialize_value(value.to_h)
          else
            value.to_s
          end
        end
      end

      # Whether to serialize via `as_json` rather than `to_h`. Follow `as_json` when the object defines
      # its OWN — on its class or an included module (e.g. an ActiveRecord model) — or when there's no
      # `to_h` to prefer. ActiveSupport's generic Object#as_json (added on Object in a Rails app) just
      # dumps instance_values, so a value object with a meaningful `to_h` should use that instead.
      def follow_as_json?(value)
        return false unless value.respond_to?(:as_json)

        value.method(:as_json).owner != Object || !value.respond_to?(:to_h)
      end
    end
  end
end
