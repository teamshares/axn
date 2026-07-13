# frozen_string_literal: true

require "active_support/core_ext/hash/indifferent_access"

module Axn
  module Core
    module FieldResolvers
      # Raised when a source can hold neither the named key nor answer it as a method — a typed
      # signal (not a bare RuntimeError) so the subfield contract machinery can treat "unextractable"
      # as "absent" (PRO-2857) and let the parent's own validation classify the malformed value,
      # while other Extract consumers still fail loudly.
      UnextractableError = Class.new(StandardError)

      class Extract
        def initialize(field:, provided_data:, options: {})
          @field = field
          @options = options
          @provided_data = provided_data
        end

        def call
          # Hash-like (named-key) sources: read the key. Checked BEFORE the method branch so a key
          # whose name collides with a Hash/Enumerable method (e.g. `zip`, `count`, `first`) is read
          # as a key rather than dispatched as a method call. Arrays respond to #dig too, but only
          # with integer indices, so they stay on the reader path (e.g. `items.count`).
          if provided_data.respond_to?(:dig) && !provided_data.is_a?(Array)
            base = provided_data.respond_to?(:with_indifferent_access) ? provided_data.with_indifferent_access : provided_data
            return base.dig(*field.to_s.split("."))
          end

          # Object/Array sources: use the reader method.
          return provided_data.public_send(field) if provided_data.respond_to?(field)

          raise UnextractableError, "Unclear how to extract #{field} from #{provided_data.inspect}"
        end

        private

        attr_reader :field, :options, :provided_data
      end
    end
  end
end
