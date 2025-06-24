# frozen_string_literal: true

module Action
  class FieldValidator
    include ActiveModel::Validations

    # NOTE: defining classes where needed b/c we explicitly register it'll affect ALL the consuming apps' validators as well
    ModelValidator = Validators::ModelValidator
    TypeValidator = Validators::TypeValidator
    ValidateValidator = Validators::ValidateValidator

    def initialize(context)
      @context = context
    end

    def read_attribute_for_validation(attr)
      @context.public_send(attr)
    end

    def self.validate!(validations:, context:, exception_klass:)
      validator = Class.new(self) do
        def self.name = "Action::FieldValidator::OneOff"

        validations.each do |field, field_validations|
          field_validations.each do |key, value|
            validates field, key => value
          end
        end
      end.new(context)

      return if validator.valid?

      raise exception_klass, validator.errors
    end
  end
end
