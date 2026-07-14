# frozen_string_literal: true

require "active_support/core_ext/hash/indifferent_access"

module Axn
  module Core
    module FieldResolvers
      class Extract
        def initialize(field:, provided_data:, options: {})
          @field = field
          @options = options
          @provided_data = provided_data
        end

        def call
          # A dotted path is resolved one segment at a time, re-dispatching on the type reached at
          # each step, so "items.count" behaves identically to `:count on :items`: the Hash segment
          # is read by key, the nested Array segment via its reader method. Digging the whole path off
          # the top-level source instead would push a String key into a nested Array and blow up.
          field.to_s.split(".").reduce(provided_data) { |current, segment| resolve_segment(current, segment) }
        end

        private

        attr_reader :field, :options, :provided_data

        def resolve_segment(source, segment)
          # A nil intermediate means the path fell off a missing/omitted parent: read as absent
          # rather than raising, matching the top-level nil-source handling (PRO-2857).
          return nil if source.nil?

          # Hash-like (named-key) sources: read the key. Checked BEFORE the method branch so a key
          # whose name collides with a Hash/Enumerable method (e.g. `zip`, `count`, `first`) is read
          # as a key rather than dispatched as a method call. Arrays respond to #dig too, but only
          # with integer indices, so they stay on the reader path (e.g. `items.count`). Read via
          # single-key `#dig` (not `#[]`) so an absent member reads as nil across diggable types —
          # notably `Struct#["missing"]` raises `NameError` while `Struct#dig` returns nil.
          if source.respond_to?(:dig) && !source.is_a?(Array)
            base = source.respond_to?(:with_indifferent_access) ? source.with_indifferent_access : source
            return base.dig(segment) # rubocop:disable Style/SingleArgumentDig -- #[] raises NameError on an absent Struct member; #dig reads it as nil
          end

          # Object/Array sources: use the reader method. A reader that needs arguments can't answer
          # the path as a bare read — that's "unclear how to extract" (typed UnextractableError, read
          # as absent), not a raw ArgumentError leaking past the malformed-input doctrine.
          if source.respond_to?(segment)
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
          error.message.start_with?("wrong number of arguments", "missing keyword")
        end

        def raise_unextractable
          raise Axn::ContractViolation::UnextractableError, "Unclear how to extract #{field} from #{provided_data.inspect}"
        end
      end
    end
  end
end
