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

        resolver_class.new(field:, options:, provided_data:).call
      end
    end
  end
end
