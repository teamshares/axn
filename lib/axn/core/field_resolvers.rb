# frozen_string_literal: true

require "axn/core/field_resolvers/model"
require "axn/core/field_resolvers/extract"

module Axn
  module Core
    module FieldResolvers
      # Raised by Extract when a source's shape gives no way to read the named field (not a
      # named-key container and no matching reader) — i.e. a missing/wrong-shape extraction, as
      # distinct from a reader that exists but raises a genuine bug. Callers that want to treat
      # "can't extract" specially (e.g. the user-facing derived-skip) rescue this rather than a
      # blanket StandardError, so real reader bugs still propagate. Subclasses RuntimeError to
      # preserve the prior behavior (it was a bare `raise "..."`).
      UnextractableError = Class.new(RuntimeError)

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
