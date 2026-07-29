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

      # Bound rather than called, for the reason own_wire_key gives about `-@`/`initialize_copy`: a String
      # SUBCLASS can override `encoding`/`valid_encoding?`/`ascii_only?`/`encode`, and one whose
      # `valid_encoding?` returns true over bytes that aren't valid would defeat this guard on precisely the
      # value it exists to catch (verified: a lying override is believed, and JSON::GeneratorError follows).
      # Reached only from a `when ::String` match, so String's own methods are the right ones to bind.
      STRING_ENCODING = ::String.instance_method(:encoding)
      STRING_VALID_ENCODING = ::String.instance_method(:valid_encoding?)
      STRING_ASCII_ONLY = ::String.instance_method(:ascii_only?)
      STRING_ENCODE = ::String.instance_method(:encode)
      private_constant :STRING_ENCODING, :STRING_VALID_ENCODING, :STRING_ASCII_ONLY, :STRING_ENCODE

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

      UNRENDERABLE_BYTES_REASON = "it renders as a String holding bytes that have no UTF-8 rendering, and " \
                                  "JSON is a UTF-8 format — `JSON.generate` refuses it outright. Scrub the " \
                                  "bytes (`String#scrub`) or re-encode them (`encode`/`force_encoding`) " \
                                  "before exposing the value."
      private_constant :UNRENDERABLE_BYTES_REASON

      UNRENDERABLE_KEY_BYTES_REASON = "a Hash key is rendered via #to_s and this one's String form holds " \
                                      "bytes that have no UTF-8 rendering, and JSON is a UTF-8 format — " \
                                      "`JSON.generate` refuses such a property name outright. Scrub or " \
                                      "re-encode the key's bytes, or key the Hash by a UTF-8 String or Symbol."
      private_constant :UNRENDERABLE_KEY_BYTES_REASON

      # `#method` is itself overridable, so the owner lookups below go through Object's implementation. A value
      # whose own `#method` raises would otherwise replace a serialization decision with its exception — and
      # escape the adapter when that exception is outside StandardError. `respond_to?` is deliberately NOT
      # treated this way: "do you claim to respond to this?" is genuinely the value's own answer to give, and
      # overriding it is a supported idiom that a method_missing-backed proxy depends on.
      UNBOUND_METHOD = ::Object.instance_method(:method)
      private_constant :UNBOUND_METHOD

      UNRENDERABLE_FIELD_BYTES_REASON = "an exposed field's name becomes a JSON property name, and this one " \
                                        "holds bytes that have no UTF-8 rendering, and JSON is a UTF-8 " \
                                        "format — `JSON.generate` refuses such a property name outright. " \
                                        "Declare the field under a UTF-8 name."
      private_constant :UNRENDERABLE_FIELD_BYTES_REASON

      module_function

      # Result → JSON-safe Hash keyed by wire key (string), over declared outbound configs.
      #
      # A field name goes through own_wire_key on the same terms as a nested Hash key: it is a property name
      # in the output either way, so it carries the same UTF-8 promise. Declaration accepts any symbol, so a
      # name whose bytes have no UTF-8 rendering is reachable here and would otherwise reach an encoder as a
      # property nothing had checked.
      # Canonicalizing a field name means two names that differ as Symbols can converge on one property, so
      # the same collapse a Hash's keys can suffer is reachable here — and an assignment into the accumulator
      # would silently overwrite. Claimed names are tracked for the same reason the Hash branch tracks them.
      def serialize_exposed(result, field_configs, reject_opaque: false)
        claimed = {}

        field_configs.each_with_object({}) do |config, hash|
          # The error path is the field's `inspect`, not its `to_s`: a name with no UTF-8 rendering is exactly
          # what fails here, and interpolating those bytes into the message would raise
          # Encoding::CompatibilityError from the reporting itself. Symbol#inspect escapes them to ASCII and
          # cannot be overridden (Symbol takes neither a subclass nor a singleton). On success the path is the
          # canonical wire key, so nested paths read `owner.name` as before.
          wire_key = canonical_wire_key(config.field) ||
                     raise(Axn::Reflection::UnserializableValue.new(
                             path: config.field.inspect, value: config.field, reason: UNRENDERABLE_FIELD_BYTES_REASON,
                           ))
          raise_colliding_fields!(wire_key, claimed.fetch(wire_key), config.field) if claimed.key?(wire_key)

          claimed[wire_key] = config.field
          hash[wire_key] = serialize_value(result.public_send(config.field), path: wire_key, reject_opaque:)
        end
      end

      # `path` names the value being serialized, so a failure says WHICH exposure is at fault
      # (`items[1].parent`, not just "something"). `seen` carries the containers open on the current
      # path — see within_container. `reject_opaque` additionally rejects a value (or Hash key) that declares
      # no rendering of its own — one whose `to_s` is the inherited Object#to_s, or whose only `as_json` is
      # the generic one a Rails app adds: honest output, but not presentable output, so it is the caller's
      # call rather than a universal one.
      #
      # Two leaves are rejected unconditionally, alongside a cycle and a key collision, because what they
      # render is not JSON at all: a String whose bytes have no UTF-8 rendering, and a non-finite Float. No
      # adapter can want a body `JSON.generate` refuses, and core is the only layer that still knows the
      # value was at `records[3].price` — by the time an encoder refuses it, that is gone.
      def serialize_value(value, path: "(exposed value)", seen: nil, reject_opaque: false)
        case value
        when nil, Integer, TrueClass, FalseClass
          value
        when String
          encodable_string!(value, source: value, path:)
        when Float
          finite_number!(value, source: value, path:)
        when Symbol
          # JSON has no symbol type — render deterministically as its String form, matching
          # the schema's `type: Symbol` => "string" mapping (Axn::Reflection::Schema::TYPE_MAP),
          # rather than relying on the generic `to_s` fallback below (which happens to agree).
          encodable_string!(value.to_s, source: value, path:)
        when Numeric
          # BigDecimal / Rational etc. — emit a JSON number so output matches the schema's "number" type.
          # JSON has no decimal type (any JSON number is a double), so a Float representation is the correct
          # wire form; a caller needing exact decimals should expose type: String. Integer/Float are already
          # handled above. A non-real Numeric (Complex) can't become a Float — fall back to its string form.
          #
          # The finiteness check sits OUTSIDE the coercion's rescue: BigDecimal("Infinity") and a Rational
          # too large for a double both coerce to a non-finite Float, and UnserializableValue is an
          # ArgumentError, so raising inside that rescue would be swallowed into the string fallback.
          coerced = coerce_to_float(value)
          coerced.nil? ? encodable_string!(value.to_s, source: value, path:) : finite_number!(coerced, source: value, path:)
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
          encodable_string!(value.iso8601, source: value, path:)
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

            encodable_string!(value.to_s, source: value, path:)
          end
        end
      end

      # EVERY String serialize_value hands back passes through here, so "what serialize_exposed returns is
      # something JSON.generate accepts" holds by construction rather than one branch at a time: the bytes
      # can arrive from an exposed String, from a Symbol, or from any `#to_s`/`#iso8601` a caller wrote.
      # `source` is what the error names, so a Symbol is reported as the Symbol it was rather than as the
      # String its `#to_s` built, and the message never inspects the offending bytes.
      #
      # A `#to_s` that breaks its contract and returns a non-String has no bytes to check and passes through
      # as it always has — the type test is `case`/`when` rather than `is_a?` for the reason own_wire_key
      # gives, and String's unbound methods would be meaningless bound to a non-String regardless.
      #
      # A value keeps the encoding it was exposed in: its rendering is only CHECKED here, never substituted,
      # since bytes an encoder transcodes losslessly are no integrity risk. A Hash key is different and is
      # rendered through the transcode — see own_wire_key.
      def encodable_string!(rendered, source:, path:)
        case rendered
        when ::String
          return rendered if utf8_rendering(rendered)

          raise Axn::Reflection::UnserializableValue.new(path:, value: source, reason: UNRENDERABLE_BYTES_REASON)
        else
          rendered
        end
      end

      # The UTF-8 rendering of these bytes — the ones an encoder actually emits — or nil when they have none.
      # "Can an encoder render this as JSON text at all" and "what will it emit" are one question, since JSON
      # is UTF-8, so one method answers both: a value's caller discards the rendering and keeps its own bytes,
      # while a key's caller keeps the rendering, because two encodings of one property name have to compare
      # as one property.
      #
      # The test is NOT `valid_encoding?`, which asks whether the bytes are valid in their OWN encoding and
      # answers true for "\xFF" in BINARY, which JSON::GeneratorError refuses. It is equally not "are the
      # bytes literally valid UTF-8": a valid ISO-8859-1 or Shift_JIS String transcodes cleanly and encodes
      # fine, so demanding UTF-8 bytes would reject real data.
      #
      # ASCII-only bytes are already their own UTF-8 rendering in any ASCII-compatible encoding, and that
      # covers most of what a response body holds (identifiers, enum values, keys), so it is the single-check
      # fast path — and it is cheap twice over, since Ruby caches a String's coderange. Non-ASCII UTF-8 needs
      # one more check and still no allocation. Only bytes outside both pay for the transcode an encoder would
      # attempt, which is the sole exact answer for them. `US-ASCII` needs no arm of its own: a US-ASCII String
      # is either ASCII-only (already returned) or holds a byte no transcode accepts.
      def utf8_rendering(string)
        return string if STRING_ASCII_ONLY.bind_call(string)

        case STRING_ENCODING.bind_call(string)
        when ::Encoding::UTF_8 then STRING_VALID_ENCODING.bind_call(string) ? string : nil
        else transcode_to_utf8(string)
        end
      end

      # EncodingError is exactly the three refusals a transcode can raise (no converter for the pair, an
      # undefined mapping, an invalid byte sequence) and nothing else. The transcoded String is the answer
      # rather than a boolean because performing the transcode IS the check — there is nothing to save by
      # throwing the result away.
      def transcode_to_utf8(string)
        STRING_ENCODE.bind_call(string, ::Encoding::UTF_8)
      rescue ::EncodingError
        nil
      end

      # A non-finite Float has no JSON literal, so a body containing one is not JSON — the same category as
      # a cycle, and unconditional for the same reason. An encoder's `allow_nan:` would emit a bare
      # `Infinity`, which is not standard JSON and consumers reject, so it is no honest rendering either.
      #
      # `finite?` and the interpolated `to_s` dispatch directly: this is reached with a genuine Float — from
      # a `when Float` match (a Float subclass has no allocator, so no instance of one can exist) or from
      # `Kernel#Float`, which returns a Float or raises — so neither call can reach caller code. `source` is
      # what the error names, so a `BigDecimal("Infinity")` is reported as the BigDecimal it was exposed as.
      def finite_number!(float, source:, path:)
        return float if float.finite?

        raise Axn::Reflection::UnserializableValue.new(
          path:,
          value: source,
          reason: "it renders as #{float}, and JSON has no literal for a non-finite number — `JSON.generate` " \
                  "refuses it outright. Expose a finite number instead, or a String if the sentinel itself carries meaning.",
        )
      end

      # nil means "no Float representation exists" (a non-real Numeric such as Complex), which the caller
      # renders as a string form instead.
      def coerce_to_float(value)
        Float(value)
      rescue ArgumentError, TypeError, RangeError
        nil
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
      # what makes a collapse — two keys rendering as one JSON property (`:id` and `"id"`), dropping a value —
      # reportable: it is caught below at the moment a wire key repeats, while both original keys are still in
      # hand. Naming the pair by projecting keys a second time would be unsound, since a second #to_s may
      # disagree with the first or raise something that isn't even a StandardError, replacing the diagnosis
      # with the very escape this module exists to prevent.
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

          wire_key = own_wire_key(key, path)

          claimed = positions[wire_key]
          raise_colliding_keys!(path:, wire_key:, first_key: entries[claimed].fetch(1), second_key: key) if claimed

          positions[wire_key] = entries.size
          entries << [wire_key, key, element]
        end

        entries
      end

      # The JSON property `key` renders as: a frozen, plain, UTF-8 String this module owns, holding the UTF-8
      # rendering of whatever `key.to_s` returned — the bytes an encoder emits for that property name.
      #
      # Rendered rather than merely checked, because a property name is UTF-8 text while a Ruby String is
      # bytes PLUS an encoding: an ISO-8859-1 "\xE9" and a UTF-8 "é" are distinct, non-`eql?` Strings that a
      # Hash holds as two entries, and one single JSON property. Compared as they came, the pair passes the
      # collapse check below, an encoder emits the property twice, and a parser keeps one — the silently
      # dropped value this module exists to prevent. Canonicalizing here is what makes the check exact, and
      # what makes the returned Hash's keys the bytes that get emitted.
      #
      # Owning the String is what makes every later read of it safe — the property is a Hash key in the
      # output, part of a nested `path`, and quoted in a collision message, and a String a caller still holds
      # could change or dispatch under all three. Ruby only half-covers this on its own: it freezes a copy of
      # a String key inserted into a Hash, but not of a String SUBCLASS, and `entries` holds the wire key by
      # reference either way. So a #to_s handing out the same mutable String on every call, or a later key
      # mutating one already captured, would collapse two captured entries into one property at render time.
      #
      # `String.new` rather than `-@`/`dup`/the transcode's own result, because the copy must be neither the
      # returned String's code nor its CLASS: `-@` and `initialize_copy` are overridable, and `String#encode`
      # hands back an instance of the receiver's class, so a subclass's `hash`/`eql?` would then decide what
      # counts as one property. Code that raises (a SystemStackError escapes `rescue StandardError`) or answers
      # differently would hijack a serialization the key had no say in. The type test is `case`/`when` rather
      # than `is_a?` for the same reason: `Module#===` is a C-level check, while `is_a?` is overridable, and a
      # value lying about being a String would send `String.new` off to dispatch its `to_str`. `force_encoding`
      # then labels that copy rather than converting it — every arm of `utf8_rendering` yields bytes that are
      # already a UTF-8 rendering (ASCII bytes, valid UTF-8, or a transcode's output), and the copy is this
      # module's own plain String, so the label is asserted only where the bytes satisfy it.
      #
      # A #to_s that breaks its contract by returning a non-String leaves no property name to render, so the
      # inherited #to_s renders one: the same object address an opaque key renders as, and a String, which
      # a JSON property name has to be.
      #
      # Bytes with no UTF-8 rendering raise here, unconditionally and at every strictness: a property name is
      # a String in the output just as a leaf is, and `JSON.generate` refuses such a name outright. The key
      # itself is what the message names the class of, so no key's `inspect` runs while the error is built.
      def own_wire_key(key, path)
        canonical_wire_key(key) ||
          raise(Axn::Reflection::UnserializableValue.new(path: "#{path} (hash key)", value: key, reason: UNRENDERABLE_KEY_BYTES_REASON))
      end

      # Two field names that converged on one property. Both names are safe to interpolate — Symbol#inspect
      # escapes any bytes and cannot be overridden — so unlike a Hash key's, the message can name each.
      def raise_colliding_fields!(wire_key, first, second)
        raise Axn::Reflection::UnserializableValue.new(
          path: second.inspect,
          value: second,
          reason: "two exposed fields render as the same JSON property #{wire_key.inspect} " \
                  "(#{first.inspect} and #{second.inspect}), so one would silently overwrite the other. " \
                  "Declare them under names that stay distinct once converted to UTF-8.",
        )
      end

      # The canonical UTF-8 property name `key` renders as, or nil when its bytes have no UTF-8 rendering.
      # Separate from the raise so a field name and a Hash key can share one canonicalization while each
      # reports the defect in its own terms — the two are the same mechanism but not the same fix.
      # The module that actually defines `name` on `value`, asked without dispatching the value's own
      # `#method`. Raises NameError when nothing defines it, exactly as `#method` would.
      def owner_of(value, name) = UNBOUND_METHOD.bind_call(value, name).owner

      def canonical_wire_key(key)
        rendered = case (candidate = key.to_s)
                   when ::String then candidate
                   else DEFAULT_TO_S.bind_call(key)
                   end

        utf8 = utf8_rendering(rendered)
        ::String.new(utf8).force_encoding(::Encoding::UTF_8).freeze if utf8
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
        #
        # `case`/`when` rather than `is_a?`, for the reason own_wire_key gives: Module#=== is a C-level
        # check, while `is_a?` is overridable — a key claiming to be a Symbol would otherwise route around
        # this gate and render as the object address the gate exists to reject. A skipped Method allocation
        # is not worth a dispatch the work does not require.
        case key
        when Symbol, String then return
        end

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
          generic = owner_of(value, :as_json) == ::Object
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
        DEFAULT_TO_S_OWNERS.include?(owner_of(value, :to_s))
      rescue NameError
        # `method(:to_s)` can't resolve a #to_s that was undef'd and is served by method_missing without a
        # matching respond_to_missing?. That #to_s is emphatically not the inherited default, and the value
        # renders through it fine, so fall through to normal rendering rather than inventing a third defect.
        false
      end
    end
  end
end
