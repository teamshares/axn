# frozen_string_literal: true

# FORMAT_MAP names Date/DateTime/Time, so the vocabulary cannot load without them.
require "date"
require "time"

require "axn/internal/identity"
require "axn/internal/native_methods"

module Axn
  module Internal
    module Reflection
      module Schema
        # One declared type TOKEN to one JSON type — the leaf of every typing decision in the emitter, and the
        # one place that decides what an UNKNOWN class becomes. Reads `TYPE_MAP`/`FORMAT_MAP` from the
        # enclosing module, which owns the vocabulary.
        #
        # Every question here is put to the token WITHOUT dispatching on it: a declaration GUARD reads this, so
        # a token answering for itself would decide whether a contract is refused, and one whose method raises
        # would replace that verdict with its own exception at class-definition time.
        module TypeTokens
          TYPE_MAP = {
            String => "string",
            Symbol => "string",
            # `null` is a first-class JSON type, so a declared `NilClass` has an exact spelling here. Without the
            # entry it reached single_type_for's unknown-class fallback and reflected as "string" — whose premise
            # ("a JSON client can't send a Ruby object anyway") is true of a PORO and false of nil.
            NilClass => "null",
            Integer => "integer",
            Float => "number",
            Numeric => "number",
            Hash => "object",
            Array => "array",
            # NOTE: TrueClass/FalseClass are intentionally absent — TypeValidator accepts only the singleton
            # value, so single_type_for reflects them as boolean + a single-member enum, not the full domain.
            Date => "string",
            DateTime => "string",
            Time => "string",
          }.freeze

          FORMAT_MAP = {
            Date => "date",
            DateTime => "date-time",
            Time => "date-time",
          }.freeze

          # Forbid `null` on a property (a required model-id token can't be null). Strips the null branch from
          # an explicit type/anyOf; for the generated id property (untyped — a model PK has no fixed JSON type)
          # there's no branch to strip, so add an explicit `not: { type: "null" }` constraint.
          def reject_null!(prop)
            if prop[:type].is_a?(Array)
              non_null = prop[:type] - ["null"]
              prop[:type] = non_null.size == 1 ? non_null.first : non_null
            elsif prop[:anyOf].is_a?(Array)
              prop[:anyOf] = prop[:anyOf].reject { |member| member[:type] == "null" }
            elsif !prop.key?(:type)
              prop[:not] = { type: "null" }
            end
          end

          # Every question here is put to the token WITHOUT dispatching, and the reason is not only reflection's
          # own rule that a walk may run none of a caller's code: a declaration GUARD reads this — the blank axis
          # asks whether a declared type's branch can carry a size at all (`token_carries_a_size?`) — so a token
          # answering for itself would decide whether a contract is refused, and one whose method raises would
          # replace that verdict with its own exception, at class-definition time. Measured on an `Array` subclass
          # with a singleton `hash`: `TYPE_MAP.key?(token)` ran it.
          #
          # So the four spellings a token could otherwise answer are each replaced by a native one. Identity
          # (`Identity.same?`, a bound `equal?`) stands in for `==` against a known token; `Identity.kind?`
          # (`Module#===`, C-level) for `is_a?`; `NativeMethods.includes_module?` — which reads the ancestry out
          # of the method table — for `<`/`<=`/`>=`; and `map_type_for`/`map_format_for` scan the emitter's own
          # maps by identity rather than looking a token up by its `hash`/`eql?`. The answers are identical for
          # every token that does not define one of those methods, which is every token a declaration means.
          def single_type_for(klass, for_output:)
            return { type: "boolean" } if Axn::Internal::Identity.same?(klass, :boolean)
            # TypeValidator accepts only the singleton value for TrueClass/FalseClass, so constrain the schema
            # to it (a bare `type: "boolean"` would let a client send the other value and pass validation).
            return { type: "boolean", enum: [true] } if Axn::Internal::Identity.same?(klass, ::TrueClass)
            return { type: "boolean", enum: [false] } if Axn::Internal::Identity.same?(klass, ::FalseClass)
            return { type: "string", format: "uuid" } if Axn::Internal::Identity.same?(klass, :uuid)
            return { type: "object" } if Axn::Internal::Identity.same?(klass, :params)

            # A declared type that ADMITS a Complex value (`type: Numeric` or `type: Complex`, i.e. Complex is
            # the class or one of its ancestors) can serialize to a JSON number (real Numerics) OR a String
            # (Complex — Float() rejects it, so Values.serialize_value falls back to to_s). Its output wire
            # form isn't knowable from the declaration, so leave it UNTYPED on output rather than assert
            # "number" the serialized value could contradict. Input still resolves below: `Numeric` maps to
            # "number" (a JSON number is a real Numeric and validates), `Complex` to the permissive "string".
            return {} if for_output && class_token?(klass) && Axn::Internal::NativeMethods.includes_module?(::Complex, klass)

            mapped = map_type_for(klass)
            unless nil.equal?(mapped)
              result = { type: mapped }
              format = map_format_for(klass)
              result[:format] = format unless nil.equal?(format)
              return result
            end

            # A Numeric subclass not in TYPE_MAP (BigDecimal, Rational, …) serializes to a JSON number
            # (Values.serialize_value coerces it via Float()), so reflect it as "number" rather than the
            # object/string fallback. Complex is the exception: Float() rejects it, so on input it drops to
            # the permissive "string" below (a JSON client can't send a Complex anyway; output is handled
            # above).
            return { type: "number" } if numeric_but_not_complex?(klass)

            # Unknown class: the serialized shape is only knowable at runtime (Values.serialize_value emits
            # an object for an as_json/to_h value but a string for a to_s-only one), so on output leave it
            # UNTYPED rather than assert `object` the serialized value might contradict. On input, keep a
            # permissive `string` hint (a JSON client can't send a Ruby object anyway — see the reflection
            # docs on coercing Ruby-object input types).
            return {} if for_output

            { type: "string" }
          end

          # Whether the token is a Class at all, asked through `Module#===` rather than the token's own `is_a?`.
          # The Complex and Numeric branches both need it: `Complex`'s ancestry holds `Comparable`, a MODULE, and
          # the old `klass.is_a?(Class)` guard is what kept a declared `Comparable` out of the output-untyped
          # branch.
          def class_token?(klass) = Axn::Internal::Identity.kind?(klass, ::Class)

          # `klass < mod` — STRICT descent — read out of the token's ancestry rather than through its own `<`.
          # Strict matters at every call site: `Data` and `Struct` are not themselves member-keyed, only their
          # subclasses are, and `Hash` is tested by identity separately where it counts.
          #
          # Establishes Class-ness FIRST, which is the precondition every `NativeMethods` module reader states:
          # binding `ancestors` to a non-Module is a TypeError, and that would replace the verdict being decided
          # with an error from the reader meant to protect it. The `<` this replaces raised NoMethodError on a
          # non-Module for the same reason, so each caller guarded separately; holding the precondition here
          # keeps the three of them from having to remember it (measured — one forgot, and a nil `type:` bag's
          # `klass:` took the reflection down).
          def strict_descendant?(klass, mod)
            return false unless class_token?(klass)
            return false if Axn::Internal::Identity.same?(klass, mod)

            Axn::Internal::NativeMethods.includes_module?(klass, mod)
          end

          # A Numeric subclass other than Complex — `klass < Numeric && !(klass <= Complex)`, read out of the
          # token's ancestry rather than through its own `<`/`<=`. STRICT descent, so `Numeric` itself falls
          # through to `TYPE_MAP` (where it is "number" already) exactly as it did.
          def numeric_but_not_complex?(klass)
            return false unless class_token?(klass)
            return false if Axn::Internal::Identity.same?(klass, ::Numeric)
            return false unless Axn::Internal::NativeMethods.includes_module?(klass, ::Numeric)

            !Axn::Internal::NativeMethods.includes_module?(klass, ::Complex)
          end

          def map_type_for(klass) = identity_lookup(TYPE_MAP, klass)

          def map_format_for(klass) = identity_lookup(FORMAT_MAP, klass)

          # One of the emitter's own maps, looked up by IDENTITY: `Hash#[]`/`#key?` would hash the TOKEN and
          # compare it with `eql?`, both of which a caller's Class can define. The maps are axn's own frozen
          # Hashes keyed by ten core classes, so the scan is bounded and its receiver is never the token. `nil`
          # means "not in this map" — no value in either map is nil.
          def identity_lookup(map, klass)
            map.each { |key, value| return value if Axn::Internal::Identity.same?(key, klass) }

            nil
          end
        end
      end
    end
  end
end
