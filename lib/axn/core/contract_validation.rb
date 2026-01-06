# frozen_string_literal: true

module Axn
  module Core
    module ContractValidation
      private

      def _apply_inbound_preprocessing!
        internal_field_configs.each do |config|
          next unless config.preprocess

          initial_value = @__context.provided_data[config.field]
          @__context.provided_data[config.field] = Axn::Util::ContractErrorHandling.with_contract_error_handling(
            exception_class: Axn::ContractViolation::PreprocessingError,
            message: ->(field, error) { "Error preprocessing field '#{field}': #{error.message}" },
            field_identifier: config.field,
          ) do
            instance_exec(initial_value, &config.preprocess)
          end
        end

        _apply_inbound_preprocessing_for_subfields!
      end

      def _validate_contract!(direction)
        raise ArgumentError, "Invalid direction: #{direction}" unless %i[inbound outbound].include?(direction)

        configs = direction == :inbound ? internal_field_configs : external_field_configs
        validations = configs.each_with_object({}) do |config, hash|
          hash[config.field] = config.validations
        end
        context = direction == :inbound ? internal_context : result
        exception_klass = direction == :inbound ? Axn::InboundValidationError : Axn::OutboundValidationError

        Validation::Fields.validate!(validations:, context:, exception_klass:)

        # Validate subfields for inbound direction
        _validate_subfields_contract! if direction == :inbound
      end

      def _apply_defaults!(direction)
        raise ArgumentError, "Invalid direction: #{direction}" unless %i[inbound outbound].include?(direction)

        if direction == :outbound
          # For outbound defaults, first copy values from provided_data for fields that are both expected and exposed
          external_field_configs.each do |config|
            field = config.field
            next if @__context.exposed_data.key?(field) # Already has a value

            @__context.exposed_data[field] = @__context.provided_data[field] if @__context.provided_data.key?(field)
          end
        end

        configs = direction == :inbound ? internal_field_configs : external_field_configs
        defaults_mapping = configs.each_with_object({}) do |config, hash|
          hash[config.field] = config.default
        end.compact

        defaults_mapping.each do |field, default_value_getter|
          data_hash = direction == :inbound ? @__context.provided_data : @__context.exposed_data
          next if data_hash.key?(field) && !data_hash[field].nil?

          data_hash[field] = Axn::Util::ContractErrorHandling.with_contract_error_handling(
            exception_class: Axn::ContractViolation::DefaultAssignmentError,
            message: ->(field_name, error) { "Error applying default for field '#{field_name}': #{error.message}" },
            field_identifier: field,
          ) do
            default_value_getter.respond_to?(:call) ? instance_exec(&default_value_getter) : default_value_getter
          end
        end

        # Apply subfield defaults for inbound direction
        _apply_defaults_for_subfields! if direction == :inbound
      end
    end
  end
end
