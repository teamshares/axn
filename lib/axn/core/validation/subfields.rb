# frozen_string_literal: true

require "active_support/core_ext/hash/indifferent_access"
require "axn/core/validation/base"

module Axn
  module Validation
    class Subfields < Base
      def initialize(source)
        super()
        @source = source
      end

      def read_attribute_for_validation(attr)
        # Only use action's reader methods for model fields that need special resolution
        # For all other fields, use the unified FieldResolvers system.
        # The model reader may be aliased (as:/prefix:), so resolve it under `@reader` (the accessor
        # name) rather than `attr` (the wire key) — the reader itself still digs the wire key (and
        # its `_id`) out of the parent.
        reader = @reader || attr
        if @action && @validations&.key?(:model) && @action.respond_to?(reader)
          @action.public_send(reader)
        else
          Axn::Core::FieldResolvers.resolve(type: :extract, field: attr, provided_data: @source)
        end
      end

      # Returns the ActiveModel::Errors for one (field, validations) pair against a source (empty if
      # valid) — raising/settling is the caller's concern (see Executor#_validate_subfields_settling!).
      def self.collect_errors(field:, validations:, source:, action: nil, reader: nil)
        errors_for(validator_class_for(field:, validations:), source:, validations:, action:, reader:)
      end

      # Builds the one-off validator class for a (field, validations) pair. Callers that validate
      # the same contract repeatedly (e.g. ShapeValidator over array elements) can build this once
      # and reuse it across sources via .errors_for, avoiding per-call class compilation.
      def self.validator_class_for(field:, validations:)
        Class.new(self) do
          def self.name = "Axn::Validation::Subfields::OneOff"

          # A field may legitimately carry no validators at all (e.g. `optional: true` with no
          # type/model), which `validates` rejects — an empty set means nothing to enforce, exactly
          # like a top-level field with no validators.
          validates field, **validations unless validations.empty?
        end
      end

      # Runs a validator class against a source and returns its ActiveModel::Errors (empty if valid).
      def self.errors_for(validator_class, source:, validations:, action: nil, reader: nil)
        validator = validator_class.new(source)

        # Set the action context for model field resolution
        validator.instance_variable_set(:@action, action)
        validator.instance_variable_set(:@validations, validations)
        validator.instance_variable_set(:@reader, reader)

        validator.valid?
        validator.errors
      end

      private

      def _action_for_validation = @action
    end
  end
end
