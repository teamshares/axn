# frozen_string_literal: true

require "active_support/core_ext/hash/indifferent_access"

module Axn
  module Validation
    class Subfields
      include ActiveModel::Validations

      # NOTE: defining classes where needed b/c we explicitly register it'll affect ALL the consuming apps' validators as well
      ModelValidator = Validators::ModelValidator
      TypeValidator = Validators::TypeValidator
      ValidateValidator = Validators::ValidateValidator
      OfValidator = Validators::OfValidator
      ShapeValidator = Validators::ShapeValidator

      def initialize(source)
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

      def self.validate!(field:, validations:, source:, exception_klass:, action: nil, reader: nil)
        errors = collect_errors(field:, validations:, source:, action:, reader:)
        raise exception_klass, errors if errors.any?
      end

      # Non-raising variant: returns the ActiveModel::Errors (empty if valid).
      def self.collect_errors(field:, validations:, source:, action: nil, reader: nil)
        errors_for(validator_class_for(field:, validations:), source:, validations:, action:, reader:)
      end

      # Builds the one-off validator class for a (field, validations) pair. Callers that validate
      # the same contract repeatedly (e.g. ShapeValidator over array elements) can build this once
      # and reuse it across sources via .errors_for, avoiding per-call class compilation.
      def self.validator_class_for(field:, validations:)
        Class.new(self) do
          def self.name = "Axn::Validation::Subfields::OneOff"

          validates field, **validations
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
    end
  end
end
