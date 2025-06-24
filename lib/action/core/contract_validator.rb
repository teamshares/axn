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
          Action.config.logger.warn("Custom validation on field '#{attribute}' raised #{e.class.name}: #{e.message}")

          "failed validation: #{e.message}"
        end

        record.errors.add(attribute, msg) if msg.present?
      end
    end

    class TypeValidator < ActiveModel::EachValidator
      def validate_each(record, attribute, value)
        # NOTE: the last one (:value) might be my fault from the make-it-a-hash fallback in #parse_field_configs
        types = options[:in].presence || Array(options[:with]).presence || Array(options[:value]).presence

        return if value.blank? && !types.include?(:boolean) # Handled with a separate default presence validator

        msg = types.size == 1 ? "is not a #{types.first}" : "is not one of #{types.join(", ")}"
        record.errors.add attribute, (options[:message] || msg) unless types.any? do |type|
          if type == :boolean
            [true, false].include?(value)
          elsif type == :uuid
            value.is_a?(String) && value.match?(/\A[0-9a-f]{8}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{12}\z/i)
          else
            # NOTE: allow mocks to pass type validation by default (much easier testing ergonomics)
            next true if Action.config.env.test? && value.class.name.start_with?("RSpec::Mocks::")

            value.is_a?(type)
          end
        end
      end
    end

    class ModelValidator < ActiveModel::EachValidator
      def self.model_for(attribute:, klass: nil)
        return klass if defined?(ActiveRecord::Base) && klass.is_a?(ActiveRecord::Base)

        attribute.to_s.delete_suffix("_id").classify.constantize
      end

      def validate_each(record, attribute, value)
        klass = self.class.model_for(attribute:, klass: options[:with])
        instance = klass.find_by(id: value)
        return if instance.present?

        record.errors.add(attribute, "not found for class #{klass.name} and ID #{value}")
      rescue StandardError => e
        warn("Model validation on field '#{attribute}' raised #{e.class.name}: #{e.message}")

        record.errors.add(attribute, "error raised while trying to find a valid #{klass.name}")
      end
    end
  end
end
