# frozen_string_literal: true

require "axn/core/field_resolvers/model"
require "axn/core/field_resolvers/extract"

module Axn
  module Core
    module FieldResolvers
      # Registry for field resolvers
      # This allows us to easily add new field types in the future
      RESOLVERS = {
        model: FieldResolvers::Model,
        extract: FieldResolvers::Extract,
      }.freeze

      def self.resolve(type:, field:, provided_data:, options: {})
        resolver_class = RESOLVERS[type]
        raise ArgumentError, "Unknown field resolver type: #{type}" unless resolver_class

        # A nil source means "absent": there's nothing to extract or look up, so every resolver yields
        # nil rather than reaching into it. This is what lets a subfield hang off a nil/omitted parent —
        # its own optional/required rules then apply against nil (optional passes, required fails with a
        # clean validation error) instead of the resolver blowing up mid-resolution (PRO-2857).
        return nil if provided_data.nil?

        resolver_class.new(field:, options:, provided_data:).call
      end
    end
  end
end
