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
      # Sentinel for "this container was already open on the path" — a private object rather than a
      # string, so it can never collide with a value a caller actually exposed.
      CYCLE_DETECTED = Object.new.freeze
      private_constant :CYCLE_DETECTED

      module_function

      # Result → JSON-safe Hash keyed by wire key (string), over declared outbound configs.
      def serialize_exposed(result, field_configs)
        field_configs.each_with_object({}) do |config, hash|
          hash[config.field.to_s] = serialize_value(result.public_send(config.field), path: config.field.to_s)
        end
      end

      # `path` names the value being serialized, so a failure says WHICH exposure is at fault
      # (`items[1].parent`, not just "something"). `seen` carries the containers open on the current
      # path — see within_container.
      def serialize_value(value, path: "(exposed value)", seen: nil)
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
          within_container(value, path, seen) do |nested|
            value.transform_keys(&:to_s).each_with_object({}) do |(key, v), acc|
              acc[key] = serialize_value(v, path: "#{path}.#{key}", seen: nested)
            end
          end
        when Array
          within_container(value, path, seen) do |nested|
            value.each_with_index.map { |v, index| serialize_value(v, path: "#{path}[#{index}]", seen: nested) }
          end
        when Time, DateTime, Date
          # Rendered as RFC3339/ISO-8601 regardless of Rails, matching the schema's
          # `date`/`date-time` `format:` (see Reflection::Schema::FORMAT_MAP) — both inside and
          # outside Rails, so `serialize_exposed` output validates against the reflected schema.
          value.iso8601
        else
          # Guarded on the SOURCE object, not the Hash it yields: #as_json/#to_h build a fresh Hash on
          # every call, so an object whose projection points back at it (`to_h => { child: self }`)
          # would recurse forever with a different Hash identity each time.
          if follow_as_json?(value)
            within_container(value, path, seen) { |nested| serialize_value(value.as_json, path:, seen: nested) }
          elsif value.respond_to?(:to_h)
            within_container(value, path, seen) { |nested| serialize_value(value.to_h, path:, seen: nested) }
          else
            value.to_s
          end
        end
      end

      # A self-referential container has no JSON representation at all, so this is a serialization
      # FAILURE rather than something to paper over with a placeholder: `serialize_exposed` renders a
      # response body, and a caller cannot tell an elided-cycle marker from a real value. Raising also
      # lets an adapter's existing `rescue StandardError` map it to an error response — which a
      # SystemStackError, outside StandardError, could not do.
      #
      # Tracks the ancestor chain (CycleGuard pushes before descending and pops after), so a container
      # merely referenced twice as SIBLINGS — a diamond — is not a false positive.
      def within_container(container, path, seen, &)
        result = Axn::Internal::CycleGuard.guard(container, seen, on_cycle: CYCLE_DETECTED, &)
        raise Axn::Reflection::UnserializableValue.new(path:, value: container) if result.equal?(CYCLE_DETECTED)

        result
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
