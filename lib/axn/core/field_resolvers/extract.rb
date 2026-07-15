# frozen_string_literal: true

require "active_support/core_ext/hash/indifferent_access"

module Axn
  module Core
    module FieldResolvers
      class Extract
        def initialize(field:, provided_data:, options: {}, permit_method_call: false)
          @field = field
          @options = options
          @provided_data = provided_data
          @permit_method_call = permit_method_call
        end

        def call
          # A dotted path is resolved one segment at a time, re-dispatching on the type reached at
          # each step, so "items.count" behaves identically to `:count on :items`: the Hash segment
          # is read by key, the nested Array segment via its reader method. Digging the whole path off
          # the top-level source instead would push a String key into a nested Array and blow up.
          field.to_s.split(".").reduce(provided_data) { |current, segment| resolve_segment(current, segment) }
        end

        private

        attr_reader :field, :options, :provided_data, :permit_method_call

        def resolve_segment(source, segment)
          # A nil intermediate means the path fell off a missing/omitted parent: read as absent
          # rather than raising, matching the top-level nil-source handling (PRO-2857).
          return nil if source.nil?

          # Hash-like (named-key) sources: read the key. Checked BEFORE the method branch so a key
          # whose name collides with a Hash/Enumerable method (e.g. `zip`, `count`, `first`) is read
          # as a key rather than dispatched as a method call. Arrays respond to #dig too, but only
          # with integer indices, so they stay on the reader path (e.g. `items.count`).
          if source.respond_to?(:dig) && !source.is_a?(Array)
            # A Hash (incl. HashWithIndifferentAccess) is read by a direct dual-key lookup rather than
            # `#with_indifferent_access.dig`, which deep-copies the WHOLE source on every segment (a
            # per-read cost on the hot path). Neither key form allocates a heap string: `segment` is
            # already a String (from the dotted split), and `#to_sym` is a symbol-table intern of an
            # already-declared field name (contract paths are developer-declared, never arbitrary
            # input, so there's no symbol-table-bloat risk). SYMBOL is tried first because internal
            # contexts come from kwargs and are predominantly symbol-keyed, saving the redundant
            # `key?` probe on that common path. (A hash carrying BOTH a symbol and a string form of
            # the same name — pathological — resolves to the symbol value.)
            if source.is_a?(Hash)
              sym = segment.to_sym
              return source[sym] if source.key?(sym)

              return source.key?(segment) ? source[segment] : nil
            end

            # Other diggable sources (Struct, ActionController::Parameters, …): fall back to the
            # indifferent copy. Read via single-key `#dig` (not `#[]`) so an absent member reads as
            # nil — notably `Struct#["missing"]` raises `NameError` while `Struct#dig` returns nil.
            base = source.respond_to?(:with_indifferent_access) ? source.with_indifferent_access : source
            return base.dig(segment) # rubocop:disable Style/SingleArgumentDig -- #[] raises NameError on an absent Struct member; #dig reads it as nil
          end

          # Data isn't diggable, but its declared members are DATA, not behavior — read them from the
          # member hash so no member reader is ever invoked. A *behavioral* method (`d.computed`) is not
          # a declared member, so it misses here and correctly falls to the gated method branch below.
          # This keeps the safe/sharp axis honest at the mechanism level: the safe path never
          # `public_send`s the segment. The built-in `Data#to_h` is invoked via `bind_call` so a
          # subclass that overrides `to_h` (returning a scalar, or a re-keyed hash) can't break or
          # misresolve a declared member read.
          return Data.instance_method(:to_h).bind_call(source)[segment.to_sym] if source.is_a?(Data) && source.class.members.include?(segment.to_sym)

          # Object/Array sources: the segment can only be reached by INVOKING it as a method. That's
          # the sharp path — it runs ONLY when the declaration opted in with `method_call: true`.
          # Reached without that opt-in, it's a contract-configuration bug, raised loudly (a distinct
          # error `extract_or_nil` does not swallow) rather than silently method-dispatching.
          if source.respond_to?(segment)
            raise_method_call_not_permitted(source, segment) unless permit_method_call

            # A reader that needs arguments can't answer the path as a bare read — that's "unclear how
            # to extract" (typed UnextractableError, read as absent), not a raw ArgumentError leaking
            # past the malformed-input doctrine.
            reader = source.method(segment)

            # A Ruby-defined reader advertises its required params (`:req`/`:keyreq`) accurately, so
            # gate on them before dispatching (covers e.g. a `lookup(id:)` required-keyword reader) —
            # and once past that gate, ANY ArgumentError it raises is from inside its body (a
            # programmer bug), so it re-raises untouched rather than being hidden as absence.
            raise_unextractable if reader_requires_arguments?(reader)

            begin
              return source.public_send(segment)
            rescue ArgumentError => e
              # Only a core (C) reader can still be a bare-call arity failure here: its params can't be
              # trusted (`Array#fetch` shows `[[:rest]]` yet needs an index) so the gate above couldn't
              # catch it. Ruby-defined readers (`source_location` present) have no such excuse — surface
              # their error. Classify the C-reader arity failure by its stable, non-localized message.
              raise if reader.source_location
              raise unless arity_error?(e)

              raise_unextractable
            end
          end

          raise_unextractable
        end

        def reader_requires_arguments?(reader)
          reader.parameters.any? { |type, _| %i[req keyreq].include?(type) }
        end

        def arity_error?(error)
          error.message.start_with?("wrong number of arguments")
        end

        # The actionable text rides on this exception's own #message (see MethodCallNotPermittedError):
        # it names the field, the parent's runtime class, and the fix, so it reaches developers via
        # on_exception/logs while the end user sees only the generic result.error headline.
        def raise_method_call_not_permitted(source, segment)
          raise Axn::ContractViolation::MethodCallNotPermittedError,
                "Refusing to resolve `#{field}` by calling `##{segment}` on #{source.class}: resolving a field by " \
                "invoking a method is opt-in. Add `method_call: true` to the declaration if that is intended " \
                "(`expects ..., method_call: true` for a subfield, or `field ..., method_call: true` inside a shape " \
                "block); otherwise the safe default reads declared data only (Hash keys, Struct/OpenStruct/Data members)."
        end

        def raise_unextractable
          raise Axn::ContractViolation::UnextractableError, "Unclear how to extract #{field} from #{provided_data.inspect}"
        end
      end
    end
  end
end
