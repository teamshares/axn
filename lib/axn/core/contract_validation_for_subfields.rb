# frozen_string_literal: true

module Axn
  module Core
    module ContractValidationForSubfields
      private

      # Applies preprocessing to all subfield configurations
      def _apply_inbound_preprocessing_for_subfields!
        _for_each_relevant_subfield_config(:preprocess) do |config, parent_field, subfield, parent_value|
          current_subfield_value = Axn::Validation::Subfields.extract(subfield, parent_value)
          preprocessed_value = config.preprocess.call(current_subfield_value)
          _update_subfield_value(parent_field, subfield, preprocessed_value)
        rescue StandardError => e
          raise Axn::ContractViolation::PreprocessingError, "Error preprocessing subfield '#{config.field}' on '#{config.on}': #{e.message}", cause: e
        end
      end

      # Applies default values to all subfield configurations
      def _apply_defaults_for_subfields!
        _for_each_relevant_subfield_config(:default) do |config, parent_field, subfield, parent_value|
          next if parent_value && _subfield_exists?(parent_value, subfield)

          @__context.provided_data[parent_field] = {} if parent_value.nil?

          default_value = config.default.respond_to?(:call) ? instance_exec(&config.default) : config.default
          _update_subfield_value(parent_field, subfield, default_value)
        rescue StandardError => e
          raise Axn::ContractViolation::DefaultAssignmentError, "Error applying default for subfield '#{config.field}' on '#{config.on}': #{e.message}",
                cause: e
        end
      end

      # Validates all subfield configurations against their defined validations
      def _validate_subfields_contract!
        _for_each_relevant_subfield_config do |config, parent_field, subfield, _parent_value|
          Validation::Subfields.validate!(
            field: subfield,
            validations: config.validations,
            source: public_send(parent_field),
            exception_klass: Axn::InboundValidationError,
          )
        end
      end

      #
      # Here down - helpers for the above methods
      #

      # Iterates over subfield configurations, optionally filtered by attribute, yielding to a block
      def _for_each_relevant_subfield_config(attribute = nil)
        subfield_configs.each do |config|
          next if attribute && !config.public_send(attribute)

          parent_field = config.on
          subfield = config.field
          parent_value = @__context.provided_data[parent_field]

          yield(config, parent_field, subfield, parent_value)
        end
      end

      # Updates a subfield value, handling nested paths, hash objects, and method-based setters
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

      # Checks if a subfield path contains nested access (e.g., "user.profile.name")
      def _is_nested_subfield?(subfield) = subfield.to_s.include?(".")

      # Parses a subfield path into an array of parts
      def _parse_subfield_path(subfield) = subfield.to_s.split(".")

      # Updates a simple hash subfield value
      def _update_simple_hash_subfield(parent_field, subfield, new_value)
        parent_value = @__context.provided_data[parent_field].dup
        parent_value[subfield] = new_value
        @__context.provided_data[parent_field] = parent_value
      end

      # Updates an object subfield using method assignment
      def _update_object_subfield(parent_value, subfield, new_value)
        parent_value.public_send("#{subfield}=", new_value)
      end

      # Updates a nested subfield value by navigating the path and creating intermediate hashes
      def _update_nested_subfield_value(parent_field, subfield, new_value)
        parent_value = @__context.provided_data[parent_field]
        path_parts = _parse_subfield_path(subfield)

        target_parent = _navigate_to_parent(parent_value, path_parts)
        target_parent[path_parts.last.to_sym] = new_value
      end

      # Navigates to the parent of the target field, creating intermediate hashes as needed
      def _navigate_to_parent(parent_value, path_parts)
        path_parts[0..-2].reduce(parent_value) do |current, part|
          current[part.to_sym] || current[part] || (current[part.to_sym] = {})
        end
      end

      # Checks if a subfield exists in the parent value, handling both hash and object types
      def _subfield_exists?(parent_value, subfield)
        if parent_value.is_a?(Hash)
          _hash_subfield_exists?(parent_value, subfield)
        elsif parent_value.respond_to?(subfield)
          _object_subfield_exists?(parent_value, subfield)
        else
          false
        end
      end

      # Checks if a subfield exists in a hash, handling both simple and nested paths
      def _hash_subfield_exists?(parent_value, subfield)
        if _is_nested_subfield?(subfield)
          _nested_hash_subfield_exists?(parent_value, subfield)
        else
          _simple_hash_subfield_exists?(parent_value, subfield)
        end
      end

      # Checks if a simple (non-nested) hash subfield exists
      def _simple_hash_subfield_exists?(parent_value, subfield)
        parent_value.key?(subfield.to_sym) || parent_value.key?(subfield)
      end

      # Checks if a nested hash subfield exists by navigating the path
      def _nested_hash_subfield_exists?(parent_value, subfield)
        path_parts = _parse_subfield_path(subfield)
        current = parent_value

        path_parts.each do |part|
          return false unless current.is_a?(Hash)
          return false unless current.key?(part.to_sym) || current.key?(part)

          current = current[part.to_sym] || current[part]
        end

        true
      end

      # Checks if an object subfield exists (not nil)
      # This ensures we apply defaults for nil values on objects
      def _object_subfield_exists?(parent_value, subfield)
        !parent_value.public_send(subfield).nil?
      end
    end
  end
end
