# frozen_string_literal: true

module Action
  module Core
    module ContractValidation
      private

      def _apply_inbound_preprocessing!
        internal_field_configs.each do |config|
          next unless config.preprocess

          initial_value = @context.public_send(config.field)
          new_value = config.preprocess.call(initial_value)
          @context.public_send("#{config.field}=", new_value)
        rescue StandardError => e
          raise Action::ContractViolation::PreprocessingError, "Error preprocessing field '#{config.field}': #{e.message}"
        end
      end

      def _validate_contract!(direction)
        raise ArgumentError, "Invalid direction: #{direction}" unless %i[inbound outbound].include?(direction)

        configs = direction == :inbound ? internal_field_configs : external_field_configs
        validations = configs.each_with_object({}) do |config, hash|
          hash[config.field] = config.validations
        end
        context = direction == :inbound ? internal_context : external_context
        exception_klass = direction == :inbound ? Action::InboundValidationError : Action::OutboundValidationError

        Validation::Fields.validate!(validations:, context:, exception_klass:)
      end

      def _apply_defaults!(direction)
        raise ArgumentError, "Invalid direction: #{direction}" unless %i[inbound outbound].include?(direction)

        configs = direction == :inbound ? internal_field_configs : external_field_configs
        defaults_mapping = configs.each_with_object({}) do |config, hash|
          hash[config.field] = config.default
        end.compact

        defaults_mapping.each do |field, default_value_getter|
          next if @context.public_send(field).present?

          default_value = default_value_getter.respond_to?(:call) ? instance_exec(&default_value_getter) : default_value_getter

          @context.public_send("#{field}=", default_value)
        end
      end
    end
  end
end
