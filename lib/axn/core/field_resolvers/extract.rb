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
          # Handle method calls if the source responds to the field
          return provided_data.public_send(field) if provided_data.respond_to?(field)

          # For hash-like objects, use digging with indifferent access
          raise "Unclear how to extract #{field} from #{provided_data.inspect}" unless provided_data.respond_to?(:dig)

          base = provided_data.respond_to?(:with_indifferent_access) ? provided_data.with_indifferent_access : provided_data
          base.dig(*field.to_s.split("."))
        end

        private

        attr_reader :field, :options, :provided_data
      end
    end
  end
end
