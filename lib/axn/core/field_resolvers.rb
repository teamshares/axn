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

      # THE tolerant read for the subfield contract machinery: a source that can't answer the named
      # path (a malformed value where an object was declared — Extract's UnextractableError) reads
      # as ABSENT, the same way a nil source does above. The field's own validators then report
      # against nil while the malformed ancestor's own type validation classifies the bad value —
      # one doctrine, applied by every reader, validation source, and pre-validation pass, so
      # malformed caller input always settles as a contract error rather than a raw exception.
      # (Consumers that want the loud typed error call .resolve directly.)
      def self.extract_or_nil(field:, provided_data:)
        resolve(type: :extract, field:, provided_data:)
      rescue Axn::ContractViolation::UnextractableError
        nil
      end
    end
  end
end
