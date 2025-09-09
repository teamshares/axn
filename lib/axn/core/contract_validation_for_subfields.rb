# frozen_string_literal: true

module Axn
  module Core
    module ContractValidationForSubfields
      private

      def _apply_inbound_preprocessing_for_subfields!
        subfield_configs.each do |config|
          next unless config.preprocess

          parent_field = config.on
          subfield = config.field
          parent_value = @__context.provided_data[parent_field]

          # Extract the current subfield value
          current_subfield_value = Axn::Validation::Subfields.extract(subfield, parent_value)

          # Apply preprocessing
          preprocessed_value = config.preprocess.call(current_subfield_value)

          # Update the parent field with the preprocessed subfield value
          _update_subfield_value(parent_field, subfield, preprocessed_value)
        rescue StandardError => e
          raise Axn::ContractViolation::PreprocessingError, "Error preprocessing subfield '#{config.field}' on '#{config.on}': #{e.message}", cause: e
        end
      end

      def _apply_defaults_for_subfields!
        subfield_configs.each do |config|
          next unless config.default

          parent_field = config.on
          subfield = config.field
          parent_value = @__context.provided_data[parent_field]

          # Check if the subfield already exists (key check to avoid applying defaults when nil was explicitly given)
          next if parent_value && _subfield_exists?(parent_value, subfield)

          # Ensure parent field exists if it's nil
          @__context.provided_data[parent_field] = {} if parent_value.nil?

          # Apply default value
          default_value = config.default.respond_to?(:call) ? instance_exec(&config.default) : config.default

          # Update the parent field with the default subfield value
          _update_subfield_value(parent_field, subfield, default_value)
        rescue StandardError => e
          raise Axn::ContractViolation::DefaultError, "Error applying default for subfield '#{config.field}' on '#{config.on}': #{e.message}", cause: e
        end
      end

      def _validate_subfields_contract!
        subfield_configs.each do |config|
          Validation::Subfields.validate!(
            field: config.field,
            validations: config.validations,
            source: public_send(config.on),
            exception_klass: Axn::InboundValidationError,
          )
        end
      end

      def _update_subfield_value(parent_field, subfield, new_value)
        parent_value = @__context.provided_data[parent_field]

        if _is_nested_subfield?(subfield)
          _update_nested_subfield_value(parent_field, subfield, new_value)
        elsif parent_value.is_a?(Hash)
          _update_simple_hash_subfield(parent_field, subfield, new_value)
        elsif parent_value.respond_to?("#{subfield}=")
          _update_object_subfield(parent_value, subfield, new_value)
        end
      end

      def _is_nested_subfield?(subfield)
        subfield.to_s.include?(".")
      end

      def _update_simple_hash_subfield(parent_field, subfield, new_value)
        parent_value = @__context.provided_data[parent_field].dup
        parent_value[subfield] = new_value
        @__context.provided_data[parent_field] = parent_value
      end

      def _update_object_subfield(parent_value, subfield, new_value)
        parent_value.public_send("#{subfield}=", new_value)
      end

      def _update_nested_subfield_value(parent_field, subfield, new_value)
        parent_value = @__context.provided_data[parent_field]
        path_parts = subfield.to_s.split(".")

        # Navigate to the parent of the target field
        target_parent = path_parts[0..-2].reduce(parent_value) do |current, part|
          current[part.to_sym] || current[part] || (current[part.to_sym] = {})
        end

        # Set the final field value
        target_parent[path_parts.last.to_sym] = new_value
      end

      def _subfield_exists?(parent_value, subfield)
        if parent_value.is_a?(Hash)
          _hash_subfield_exists?(parent_value, subfield)
        elsif parent_value.respond_to?(subfield)
          _object_subfield_exists?(parent_value, subfield)
        else
          false
        end
      end

      def _hash_subfield_exists?(parent_value, subfield)
        if _is_nested_subfield?(subfield)
          _nested_hash_subfield_exists?(parent_value, subfield)
        else
          _simple_hash_subfield_exists?(parent_value, subfield)
        end
      end

      def _simple_hash_subfield_exists?(parent_value, subfield)
        parent_value.key?(subfield.to_sym) || parent_value.key?(subfield)
      end

      def _nested_hash_subfield_exists?(parent_value, subfield)
        path_parts = subfield.to_s.split(".")
        current = parent_value

        path_parts.each do |part|
          return false unless current.is_a?(Hash)
          return false unless current.key?(part.to_sym) || current.key?(part)

          current = current[part.to_sym] || current[part]
        end

        true
      end

      def _object_subfield_exists?(parent_value, subfield)
        # This ensures we apply defaults for nil values on objects
        !parent_value.public_send(subfield).nil?
      end
    end
  end
end
