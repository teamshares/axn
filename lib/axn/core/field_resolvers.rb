# frozen_string_literal: true

require "axn/core/field_resolvers/model"

module Axn
  module Core
    module FieldResolvers
      # Registry for field resolvers
      # This allows us to easily add new field types in the future
      RESOLVERS = {
        model: FieldResolvers::Model,
      }.freeze

      def self.resolve(type:, field:, options:, provided_data:)
        resolver_class = RESOLVERS[type]
        raise ArgumentError, "Unknown field resolver type: #{type}" unless resolver_class

        resolver_class.new(field:, options:, provided_data:).call
      end
    end
  end
end
