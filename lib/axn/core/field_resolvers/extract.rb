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
          # with integer indices, so they stay on the reader path (e.g. `items.count`).
          if source.respond_to?(:dig) && !source.is_a?(Array)
            base = source.respond_to?(:with_indifferent_access) ? source.with_indifferent_access : source
            return base[segment]
          end

          # Object/Array sources: use the reader method.
          return source.public_send(segment) if source.respond_to?(segment)

          raise Axn::ContractViolation::UnextractableError, "Unclear how to extract #{field} from #{provided_data.inspect}"
        end
      end
    end
  end
end
