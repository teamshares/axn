# frozen_string_literal: true

require "active_support/core_ext/hash/indifferent_access"

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
      return source.public_send(attr) if source.respond_to?(attr)
      raise "Unclear how to extract #{attr} from #{source.inspect}" unless source.respond_to?(:dig)

      source.with_indifferent_access.dig(*attr.to_s.split("."))
    end

    def self.validate!(field:, validations:, source:, exception_klass:)
      validator = Class.new(self) do
        def self.name = "Action::SubfieldValidator::OneOff"

        validates field, **validations
      end.new(source)

      return if validator.valid?

      raise exception_klass, validator.errors
    end
  end
end
