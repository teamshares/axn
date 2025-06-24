# frozen_string_literal: true

module Action
  class SubfieldValidator
    include ActiveModel::Validations

    # NOTE: defining classes where needed b/c we explicitly register it'll affect ALL the consuming apps' validators as well
    ModelValidator = Validators::ModelValidator
    TypeValidator = Validators::TypeValidator
    ValidateValidator = Validators::ValidateValidator

    def initialize(source)
      @source = source
    end

    def read_attribute_for_validation(attr)
      self.class.extract(attr, @source)
    end

    def self.extract(attr, source)
      # TODO: add fallbacks here + support digging
      # data.dig(*key.to_s.split("."))
      source.fetch(attr)
    end

    def self.validate!(field:, validations:, source:, exception_klass:)
      validator = Class.new(self) do
        def self.name = "Action::ContractValidator::Subfields::OneOff"

        validates field, **validations
      end.new(source)

      return if validator.valid?

      raise exception_klass, validator.errors
    end
  end
end
