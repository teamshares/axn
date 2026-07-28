# frozen_string_literal: true

require "date"
require "time"

# Declared rather than inherited from the top-level `axn` entrypoint's require order: `axn/reflection`
# is loadable on its own (it composes only its own reflection files) and adapters are pointed at it,
# while serializing ANY Hash/Array reaches CycleGuard and raising needs UnserializableValue. Both are
# runtime references, so without these a standalone load NameErrors on ordinary output.
require "axn/internal/cycle_guard"
require "axn/exceptions"

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

      # Kernel is where #to_s actually lives (Object.new.method(:to_s).owner == Kernel), so it's the
      # owner that makes the predicate fire. Object is also included defensively — some values may report
      # it in their ancestry — so dropping Kernel would silently break the check.
      DEFAULT_TO_S_OWNERS = [::Object, ::Kernel].freeze
      private_constant :DEFAULT_TO_S_OWNERS

      OPAQUE_VALUE_REASON = "it serializes only via the default Object#to_s (it would render as garbage " \
                            'like "#<User:0x…>") — declare it `type: String` and format it, or give the ' \
                            "value an `as_json`/`to_h`."
      private_constant :OPAQUE_VALUE_REASON

      OPAQUE_KEY_REASON = "a Hash key is rendered via #to_s and this one has only the default " \
                          'Object#to_s (it would stringify to garbage like "#<…>").'
      private_constant :OPAQUE_KEY_REASON

      module_function

      # Result → JSON-safe Hash keyed by wire key (string), over declared outbound configs.
      def serialize_exposed(result, field_configs, reject_opaque: false)
        field_configs.each_with_object({}) do |config, hash|
          hash[config.field.to_s] = serialize_value(result.public_send(config.field), path: config.field.to_s, reject_opaque:)
        end
      end

      # `path` names the value being serialized, so a failure says WHICH exposure is at fault
      # (`items[1].parent`, not just "something"). `seen` carries the containers open on the current
      # path — see within_container. `reject_opaque` additionally rejects a value (or Hash key) that would
      # render only as an object address: honest output, but not presentable output, so it is the
      # caller's call rather than a universal one.
      def serialize_value(value, path: "(exposed value)", seen: nil, reject_opaque: false)
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
            rendered = value.each_with_object({}) do |(key, element), acc|
              check_opaque_key!(key, path) if reject_opaque
              wire_key = key.to_s
              acc[wire_key] = serialize_value(element, path: "#{path}.#{wire_key}", seen: nested, reject_opaque:)
            end

            # Built from the SOURCE keys rather than via transform_keys so a collapse is observable:
            # two keys with the same #to_s (`:id` and `"id"`) render as one JSON property, dropping a
            # value. Same allocations and the same one #to_s per key either way, and the size
            # comparison is O(1) — so the check costs nothing when there is nothing wrong.
            raise_colliding_keys!(value, path) unless rendered.size == value.size

            rendered
          end
        when Array
          within_container(value, path, seen) do |nested|
            value.each_with_index.map { |v, index| serialize_value(v, path: "#{path}[#{index}]", seen: nested, reject_opaque:) }
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
            within_container(value, path, seen) { |nested| serialize_value(value.as_json, path:, seen: nested, reject_opaque:) }
          elsif value.respond_to?(:to_h)
            within_container(value, path, seen) { |nested| serialize_value(value.to_h, path:, seen: nested, reject_opaque:) }
          else
            raise Axn::Reflection::UnserializableValue.new(path:, value:, reason: OPAQUE_VALUE_REASON) if reject_opaque && default_to_s?(value)

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

      # A collapse is detected by size, which doesn't say WHICH keys collided — so re-walk the source
      # here, on the error path only, and name the first colliding pair. Insertion order makes the
      # reported pair deterministic.
      def raise_colliding_keys!(hash, path)
        wire_key, colliding = hash.each_key.group_by(&:to_s).find { |_, group| group.size > 1 }
        first, second = colliding

        raise Axn::Reflection::UnserializableValue.new(
          path: "#{path} (hash key #{second.inspect})",
          value: second,
          reason: "two keys stringify to the same JSON property #{wire_key.inspect} " \
                  "(#{first.inspect} and #{second.inspect}), which would silently collapse and drop a value.",
        )
      end

      # Names the key in the path (`data (hash key #<K:0x…>)`) rather than the Hash alone, so the
      # message points at which of several keys is at fault.
      def check_opaque_key!(key, path)
        return unless default_to_s?(key)

        raise Axn::Reflection::UnserializableValue.new(
          path: "#{path} (hash key #{key.inspect})", value: key, reason: OPAQUE_KEY_REASON,
        )
      end

      # Whether to serialize via `as_json` rather than `to_h`. Follow `as_json` when the object defines
      # its OWN — on its class or an included module (e.g. an ActiveRecord model) — or when there's no
      # `to_h` to prefer. ActiveSupport's generic Object#as_json (added on Object in a Rails app) just
      # dumps instance_values, so a value object with a meaningful `to_h` should use that instead.
      def follow_as_json?(value)
        return false unless value.respond_to?(:as_json)

        value.method(:as_json).owner != Object || !value.respond_to?(:to_h)
      end

      # Whether `value.to_s` would render an object address rather than anything meaningful — i.e. the
      # value inherits #to_s instead of defining one. Keying on the OWNER rather than respond_to? is
      # what lets a real `def to_s = "$#{cents / 100.0}"` through. Reached only from the `to_s`
      # fallback and from a Hash key, so the earlier branches have already routed away everything
      # that stringifies meaningfully.
      def default_to_s?(value)
        DEFAULT_TO_S_OWNERS.include?(value.method(:to_s).owner)
      end
    end
  end
end
