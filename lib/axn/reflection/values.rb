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
# — which adds a generic Object#as_json (`to_hash.as_json` when the value has a `to_hash`, an
# instance-variable dump otherwise). To avoid that bypassing a value object's declared `to_h` shape,
# `serialize_value` prefers `to_h` whenever the only `as_json` in reach is that generic one (see
# projection_for), so a plain object with a meaningful `to_h` serializes via `to_h` in Rails and non-Rails
# alike. A value with none of the three declares no shape at all, so `reject_opaque` rejects it there just
# as it rejects the object address it renders as outside Rails.

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

      # The inherited #to_s, bound rather than called, so a wire key can always be rendered as SOME String
      # even when a key's own #to_s breaks its contract and returns something else.
      DEFAULT_TO_S = ::Kernel.instance_method(:to_s)
      private_constant :DEFAULT_TO_S

      # The projections `projection_for` names that serialize_value renders through `as_json`. Shared by the
      # `as_json` case arm and follow_as_json? so the branch taken and the answer reported cannot disagree.
      AS_JSON_PROJECTIONS = %i[own_as_json delegated_as_json generic_as_json].freeze
      private_constant :AS_JSON_PROJECTIONS

      OPAQUE_VALUE_REASON = "it serializes only via the default Object#to_s (it would render as garbage " \
                            'like "#<User:0x…>") — declare it `type: String` and format it, or give the ' \
                            "value an `as_json`/`to_h`."
      private_constant :OPAQUE_VALUE_REASON

      OPAQUE_KEY_REASON = "a Hash key is rendered via #to_s and this one has only the default " \
                          'Object#to_s (it would stringify to garbage like "#<…>") — give the key a ' \
                          "meaningful #to_s, or key the Hash by a Symbol, String, or Integer."
      private_constant :OPAQUE_KEY_REASON

      OPAQUE_AS_JSON_REASON = "it declares no JSON projection of its own: outside Rails it renders as an " \
                              "object address, and in a Rails app ActiveSupport's generic Object#as_json " \
                              "dumps its instance variables — neither is a shape its author chose, and the " \
                              "dump leaks internals and won't match the declared schema. Declare it " \
                              "`type: String` and format it, or give the value its own `as_json`/`to_h`."
      private_constant :OPAQUE_AS_JSON_REASON

      module_function

      # Result → JSON-safe Hash keyed by wire key (string), over declared outbound configs.
      def serialize_exposed(result, field_configs, reject_opaque: false)
        field_configs.each_with_object({}) do |config, hash|
          hash[config.field.to_s] = serialize_value(result.public_send(config.field), path: config.field.to_s, reject_opaque:)
        end
      end

      # `path` names the value being serialized, so a failure says WHICH exposure is at fault
      # (`items[1].parent`, not just "something"). `seen` carries the containers open on the current
      # path — see within_container. `reject_opaque` additionally rejects a value (or Hash key) that declares
      # no rendering of its own — one whose `to_s` is the inherited Object#to_s, or whose only `as_json` is
      # the generic one a Rails app adds: honest output, but not presentable output, so it is the caller's
      # call rather than a universal one.
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
            # Every key check and every key's #to_s already happened in the capture, so this loop only
            # renders elements under wire keys it is handed — it never touches `value` or a key again.
            capture_hash_entries(value, path, reject_opaque:).each_with_object({}) do |(wire_key, _key, element), acc|
              acc[wire_key] = serialize_value(element, path: "#{path}.#{wire_key}", seen: nested, reject_opaque:)
            end
          end
        when Array
          within_container(value, path, seen) do |nested|
            capture_elements(value).each_with_index.map do |element, index|
              serialize_value(element, path: "#{path}[#{index}]", seen: nested, reject_opaque:)
            end
          end
        when Time, DateTime, Date
          # Rendered as RFC3339/ISO-8601 regardless of Rails, matching the schema's
          # `date`/`date-time` `format:` (see Reflection::Schema::FORMAT_MAP) — both inside and
          # outside Rails, so `serialize_exposed` output validates against the reflected schema.
          value.iso8601
        else
          projection = projection_for(value)

          # Guarded on the SOURCE object, not the Hash it yields: #as_json/#to_h build a fresh Hash on
          # every call, so an object whose projection points back at it (`to_h => { child: self }`)
          # would recurse forever with a different Hash identity each time.
          case projection
          when *AS_JSON_PROJECTIONS
            # A :generic_as_json route means the value declares no projection at all — no `as_json`, no
            # `to_h`, and no `to_hash` for ActiveSupport's generic Object#as_json to delegate to — so what
            # would render is its instance-variable dump. A :delegated_as_json value does declare one (its
            # `to_hash`), which that same generic `as_json` renders faithfully, so it is not opaque.
            raise Axn::Reflection::UnserializableValue.new(path:, value:, reason: OPAQUE_AS_JSON_REASON) if reject_opaque && projection == :generic_as_json

            within_container(value, path, seen) { |nested| serialize_value(value.as_json, path:, seen: nested, reject_opaque:) }
          when :to_h
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
      #
      # The sentinel is the RECEIVER of `equal?`: `result` is whatever the block rendered, which can be a
      # caller-supplied object (a `to_s` fallback returning a String subclass), and asking IT would dispatch
      # an `equal?` that could raise or claim a cycle that never happened. Nothing can redefine `equal?` on
      # this module's own frozen sentinel.
      def within_container(container, path, seen, &)
        result = Axn::Internal::CycleGuard.guard(container, seen, on_cycle: CYCLE_DETECTED, &)
        raise Axn::Reflection::UnserializableValue.new(path:, value: container) if CYCLE_DETECTED.equal?(result)

        result
      end

      # A container is walked ONCE, up front, and rendered from what that walk captured. Serializing an
      # element runs user code (`as_json`/`to_h`) that can reach back into the container being serialized,
      # and a live iteration would then skip whatever that code removed — an output missing entries with
      # nothing to signal it, the one failure mode this module exists to prevent. Capturing first makes
      # "every entry present when serialization began appears in the output" hold unconditionally.
      #
      # The capture reads the original's own entries rather than calling `container.dup`: `dup` dispatches
      # caller code, and a Hash/Array SUBCLASS can override `dup`/`initialize_copy` to return different
      # contents or to refuse outright (a Singleton-including Hash raises TypeError), which would turn a
      # container that was perfectly traversable into wrong output or a crash. Same reasoning as
      # Schema.normalize_schema_literal's `instance_of?` checks. The walk does dispatch the original's
      # `each`, so a subclass overriding THAT still decides what the capture sees — inherent to walking a
      # container at all, not something a copy could avoid.
      #
      # A Hash entry is captured as the triple (wire key, original key, element), and the wire key is
      # computed here and nowhere else, so every key's #to_s runs exactly ONCE per serialization. That is
      # what makes a collapse — two keys with the same #to_s (`:id` and `"id"`) rendering as one JSON
      # property, dropping a value — reportable: it is caught below at the moment a wire key repeats, while
      # both original keys are still in hand. Naming the pair by projecting keys a second time would be
      # unsound, since a second #to_s may disagree with the first or raise something that isn't even a
      # StandardError, replacing the diagnosis with the very escape this module exists to prevent.
      #
      # The capture is a LIST rather than a Hash keyed by the caller's keys: a Hash would re-run each key's
      # `hash`/`eql?` and merge two entries the source holds separately — two mutable keys mutated to agree
      # after insertion (Ruby does not rehash on mutation), or the `==`-equal-but-distinct keys a
      # `compare_by_identity` Hash holds legitimately — and a merge here would drop a value before the
      # collapse check could ever see the pair.
      #
      # It is not free, and it is not meant to be optimized away: one extra object per container, plus a
      # per-entry triple and index for a Hash. Serializing 5k deeply-nested container-dense rows measured
      # ~25% slower than iterating those containers live. That 25% IS the guarantee.
      def capture_hash_entries(hash, path, reject_opaque:)
        entries = []
        positions = {}

        hash.each do |key, element|
          check_opaque_key!(key, path) if reject_opaque

          wire_key = own_wire_key(key)

          claimed = positions[wire_key]
          raise_colliding_keys!(path:, wire_key:, first_key: entries[claimed].fetch(1), second_key: key) if claimed

          positions[wire_key] = entries.size
          entries << [wire_key, key, element]
        end

        entries
      end

      # The JSON property `key` renders as: a frozen, plain String this module owns, holding the bytes
      # whatever `key.to_s` returned. Owning it is what makes every later read of it safe — the property is
      # a Hash key in the output, part of a nested `path`, and quoted in a collision message, and a String a
      # caller still holds could change or dispatch under all three. Ruby only half-covers this on its own:
      # it freezes a copy of a String key inserted into a Hash, but not of a String SUBCLASS, and `entries`
      # holds the wire key by reference either way. So a #to_s handing out the same mutable String on every
      # call, or a later key mutating one already captured, would collapse two captured entries into one
      # property at render time — the silent dropped value this module exists to prevent.
      #
      # `String.new` rather than `-@`/`dup`, because the copy must not dispatch the returned String's own
      # code: `-@` and `initialize_copy` are both overridable on a String subclass, and one that raises
      # (a SystemStackError escapes `rescue StandardError`) or returns different bytes would hijack a
      # serialization the key had no say in. The type test is `case`/`when` rather than `is_a?` for the same
      # reason: `Module#===` is a C-level check, while `is_a?` is overridable, and a value lying about being
      # a String would send `String.new` off to dispatch its `to_str`.
      #
      # A #to_s that breaks its contract by returning a non-String leaves no property name to copy, so the
      # inherited #to_s renders one: the same object address an opaque key renders as, and a String, which
      # a JSON property name has to be.
      def own_wire_key(key)
        case (rendered = key.to_s)
        when ::String then ::String.new(rendered).freeze
        else DEFAULT_TO_S.bind_call(key).freeze
        end
      end

      # An Array's elements, captured before the first one is projected — same guarantee, same refusal to
      # dispatch `dup`. Indices are positions rather than projections of caller objects, so unlike Hash keys
      # they cannot collide and there is nothing to check.
      def capture_elements(array)
        array.each_with_object([]) { |element, captured| captured << element }
      end

      # Always raises, at every strictness: a collapsed property drops a value, and unlike an ugly rendering
      # the caller cannot tell from the output that anything went missing. Both keys are the ones the capture
      # itself paired up, so the message names the real pair without projecting either key again. The pair
      # reported is the first collapse in insertion order, which makes it deterministic.
      def raise_colliding_keys!(path:, wire_key:, first_key:, second_key:)
        raise Axn::Reflection::UnserializableValue.new(
          path: "#{path} (hash key)",
          value: second_key,
          reason: "two keys stringify to the same JSON property #{wire_key.inspect} " \
                  "(#{describe_key_classes(first_key, second_key)}), which would silently collapse and drop a value. " \
                  "Key the Hash by one of them, not both, or give the keys distinct #to_s values.",
        )
      end

      # Identifies the colliding pair by CLASS rather than by `inspect`. `inspect` is the key's own code, and
      # running it to build this message hands the key the chance to raise in place of the failure being
      # reported — a SystemStackError there is outside StandardError and escapes the `rescue StandardError`
      # an adapter maps this error with, which is precisely what raising a StandardError here is for.
      #
      # A class name still identifies both keys, because the property they collapsed to is already in the
      # message and every pair that can actually collide differs in class: `:id`/`"id"`, `1`/`"1"`,
      # `nil`/`""`, `false`/`"false"`. When both keys DO share a class — two instances rendering a shared
      # label — saying so is itself the fact the caller needs.
      def describe_key_classes(first_key, second_key)
        first = Axn::Internal::ClassName.of(first_key)
        second = Axn::Internal::ClassName.of(second_key)
        return "both of class #{first}" if first == second

        "one of class #{first}, one of class #{second}"
      end

      # Names a key in the path (`data (hash key)`) rather than the Hash alone, so the message points at a
      # key rather than the container; WHICH key comes from the class the message already reports for the
      # `value:` it is given, so no key's `inspect` runs while the error is built.
      def check_opaque_key!(key, path)
        # Symbol#to_s and String#to_s are defined on those classes, so neither a Symbol nor a String (nor a
        # String subclass, which either inherits String's or defines its own) can ever own the inherited
        # Object#to_s — exact, not a heuristic. Skipping them skips a Method allocation per key on the
        # shape almost every Hash has.
        return if key.is_a?(Symbol) || key.is_a?(String)
        return unless default_to_s?(key)

        raise Axn::Reflection::UnserializableValue.new(path: "#{path} (hash key)", value: key, reason: OPAQUE_KEY_REASON)
      end

      # The projection serialize_value follows for a non-leaf object: its own `as_json` (defined on its
      # class or an included module, e.g. an ActiveRecord model), ActiveSupport's generic Object#as_json
      # (which a Rails app adds to every object, followed only when there is no `to_h` to prefer), `to_h`,
      # or the `to_s` fallback. One method, so the route and the "does this value declare a JSON projection
      # of its own" verdict — which is what `reject_opaque` rejects — are the same computation rather than
      # two that could disagree, and `as_json`'s owner is looked up once.
      #
      # The generic route splits in two because ActiveSupport's Object#as_json does: it delegates to
      # `to_hash` when the value has one and dumps `instance_values` only when it doesn't. A `to_hash` is
      # therefore the author's own projection rendered faithfully (:delegated_as_json), while its absence
      # means what renders is a peek at internals (:generic_as_json). Both go through `as_json` — only the
      # opaqueness verdict differs.
      def projection_for(value)
        if value.respond_to?(:as_json)
          generic = value.method(:as_json).owner == ::Object
          return :own_as_json unless generic
          return value.respond_to?(:to_hash) ? :delegated_as_json : :generic_as_json unless value.respond_to?(:to_h)
        end

        value.respond_to?(:to_h) ? :to_h : :to_s
      end

      # Whether serialize_value renders `value` via `as_json` rather than `to_h`/`to_s`. Retained for
      # adapters that route on the same question (axn-openapi); the answer comes from projection_for so
      # there is one source of truth.
      def follow_as_json?(value) = AS_JSON_PROJECTIONS.include?(projection_for(value))

      # Whether `value.to_s` would render an object address rather than anything meaningful — i.e. the
      # value inherits #to_s instead of defining one. Keying on the OWNER rather than respond_to? is
      # what lets a real `def to_s = "$#{cents / 100.0}"` through. Reached only from the `to_s`
      # fallback and from a Hash key, so the earlier branches have already routed away everything
      # that stringifies meaningfully.
      def default_to_s?(value)
        DEFAULT_TO_S_OWNERS.include?(value.method(:to_s).owner)
      rescue NameError
        # `method(:to_s)` can't resolve a #to_s that was undef'd and is served by method_missing without a
        # matching respond_to_missing?. That #to_s is emphatically not the inherited default, and the value
        # renders through it fine, so fall through to normal rendering rather than inventing a third defect.
        false
      end
    end
  end
end
