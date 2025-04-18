# frozen_string_literal: true

module Action
  class ContractValidator
    include ActiveModel::Validations

    def initialize(context)
      @context = context
    end

    def read_attribute_for_validation(attr)
      @context.public_send(attr)
    end

    def self.validate!(validations:, context:, exception_klass:)
      validator = Class.new(self) do
        def self.name = "Action::ContractValidator::OneOff"

        validations.each do |field, field_validations|
          field_validations.each do |key, value|
            validates field, key => value
          end
        end
      end.new(context)

      return if validator.valid?

      raise exception_klass, validator.errors
    end

    # Allow for custom validators to be defined in the context of the action
    class ValidateValidator < ActiveModel::EachValidator
      def validate_each(record, attribute, value)
        msg = begin
          options[:with].call(value)
        rescue StandardError => e
          warn("Custom validation on field '#{attribute}' raised #{e.class.name}: #{e.message}")

          "failed validation: #{e.message}"
        end

        record.errors.add(attribute, msg) if msg.present?
      end
    end

    class BooleanValidator < ActiveModel::EachValidator
      def validate_each(record, attribute, value)
        return if [true, false].include?(value)

        record.errors.add(attribute, "must be true or false")
      end
    end

    class TypeValidator < ActiveModel::EachValidator
      def validate_each(record, attribute, value)
        return if value.blank? # Handled with a separate default presence validator

        # TODO: the last one (:value) might be my fault from the make-it-a-hash fallback in #parse_field_configs
        types = options[:in].presence || Array(options[:with]).presence || Array(options[:value]).presence

        msg = types.size == 1 ? "is not a #{types.first}" : "is not one of #{types.join(", ")}"
        record.errors.add attribute, (options[:message] || msg) unless types.any? { |type| value.is_a?(type) }
      end
    end
  end
end
