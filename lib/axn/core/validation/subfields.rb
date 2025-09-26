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
        # For subfields, if we have an action context, use its reader methods
        # which may include model resolution for model fields
        @action ? @action.public_send(attr) : self.class.extract(attr, @source)
      end

      def self.extract(attr, source)
        return source.public_send(attr) if source.respond_to?(attr)
        raise "Unclear how to extract #{attr} from #{source.inspect}" unless source.respond_to?(:dig)

        base = source.respond_to?(:with_indifferent_access) ? source.with_indifferent_access : source
        base.dig(*attr.to_s.split("."))
      end

      def self.validate!(field:, validations:, source:, exception_klass:, action: nil)
        validator = Class.new(self) do
          def self.name = "Axn::Validation::Subfields::OneOff"

          validates field, **validations
        end.new(source)

        # Set the action context for model field resolution
        validator.instance_variable_set(:@action, action)

        return if validator.valid?

        raise exception_klass, validator.errors
      end
    end
  end
end
