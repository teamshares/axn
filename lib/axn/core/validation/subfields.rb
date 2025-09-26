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

      def initialize(source)
        @source = source
      end

      def read_attribute_for_validation(attr)
        # Only use action's reader methods for model fields that need special resolution
        # For all other fields, use the unified FieldResolvers system
        if @action && @validations&.key?(:model) && @action.respond_to?(attr)
          @action.public_send(attr)
        else
          Axn::Core::FieldResolvers.resolve(type: :extract, field: attr, provided_data: @source)
        end
      end

      def self.validate!(field:, validations:, source:, exception_klass:, action: nil)
        validator = Class.new(self) do
          def self.name = "Axn::Validation::Subfields::OneOff"

          validates field, **validations
        end.new(source)

        # Set the action context for model field resolution
        validator.instance_variable_set(:@action, action)
        validator.instance_variable_set(:@validations, validations)

        return if validator.valid?

        raise exception_klass, validator.errors
      end
    end
  end
end
