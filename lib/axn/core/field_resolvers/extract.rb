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
          # Hash-like sources: read the key. Checked BEFORE the method branch so a key whose name
          # collides with a Hash/Enumerable method (e.g. `zip`, `count`, `first`) is read as a key
          # rather than dispatched as a method call.
          if provided_data.respond_to?(:dig)
            base = provided_data.respond_to?(:with_indifferent_access) ? provided_data.with_indifferent_access : provided_data
            return base.dig(*field.to_s.split("."))
          end

          # Object sources (e.g. Data/PORO instances): use the reader method.
          return provided_data.public_send(field) if provided_data.respond_to?(field)

          raise "Unclear how to extract #{field} from #{provided_data.inspect}"
        end

        private

        attr_reader :field, :options, :provided_data
      end
    end
  end
end
