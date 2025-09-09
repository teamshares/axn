# frozen_string_literal: true

require "axn/core/validation/subfields"

module Axn
  module Core
    module ContractForSubfields
      SubfieldConfig = Data.define(:field, :validations, :on, :sensitive, :preprocess)

      def self.included(base)
        base.class_eval do
          class_attribute :subfield_configs, default: []

          extend ClassMethods
          include InstanceMethods

          before { _validate_subfields_contract! }
        end
      end

      module ClassMethods
        def _expects_subfields(
          *fields,
          on:,
          readers: true,
          allow_blank: false,
          allow_nil: false,

          default: nil,
          preprocess: nil,
          sensitive: false,

          **validations
        )
          raise ArgumentError, "expects does not support :default key when also given :on" if default.present?

          unless internal_field_configs.map(&:field).include?(on) || subfield_configs.map(&:field).include?(on)
            raise ArgumentError,
                  "expects called with `on: #{on}`, but no such method exists (are you sure you've declared `expects :#{on}`?)"
          end

          raise ArgumentError, "expects does not support expecting fields on nested attributes (i.e. `on` cannot contain periods)" if on.to_s.include?(".")

          _parse_subfield_configs(*fields, on:, readers:, allow_blank:, allow_nil:, preprocess:, sensitive:, **validations).tap do |configs|
            duplicated = subfield_configs.map(&:field) & configs.map(&:field)
            raise Axn::DuplicateFieldError, "Duplicate field(s) declared: #{duplicated.join(", ")}" if duplicated.any?

            # NOTE: avoid <<, which would update value for parents and children
            self.subfield_configs += configs
          end
        end

        private

        def _parse_subfield_configs(
          *fields,
          on:,
          readers:,
          allow_blank: false,
          allow_nil: false,
          preprocess: nil,
          sensitive: false,
          **validations
        )
          _parse_field_validations(*fields, allow_nil:, allow_blank:, **validations).map do |field, parsed_validations|
            _define_subfield_reader(field, on:, validations: parsed_validations) if readers
            SubfieldConfig.new(field:, validations: parsed_validations, on:, sensitive:, preprocess:)
          end
        end

        def _define_subfield_reader(field, on:, validations:)
          # Don't create top-level readers for nested fields
          return if field.to_s.include?(".")

          raise ArgumentError, "expects does not support duplicate sub-keys (i.e. `#{field}` is already defined)" if method_defined?(field)

          define_memoized_reader_method(field) do
            Axn::Validation::Subfields.extract(field, public_send(on))
          end

          _define_model_reader(field, validations[:model]) { Axn::Validation::Subfields.extract(field, public_send(on)) } if validations.key?(:model)
        end
      end

      module InstanceMethods
        def _apply_inbound_preprocessing_for_subfields!
          return if subfield_configs.blank?

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

        def _validate_subfields_contract!
          return if subfield_configs.blank?

          subfield_configs.each do |config|
            Validation::Subfields.validate!(
              field: config.field,
              validations: config.validations,
              source: public_send(config.on),
              exception_klass: Axn::InboundValidationError,
            )
          end
        end

        private

        def _update_subfield_value(parent_field, subfield, new_value)
          parent_value = @__context.provided_data[parent_field]

          if parent_value.is_a?(Hash) && !subfield.to_s.include?(".")
            # Handle simple hash-based parent fields - update the actual nested structure
            parent_value = parent_value.dup
            parent_value[subfield] = new_value
            @__context.provided_data[parent_field] = parent_value
          elsif parent_value.respond_to?("#{subfield}=")
            # Handle object-based parent fields with setter methods
            parent_value.public_send("#{subfield}=", new_value)
          else
            # For nested paths (e.g., "profile.bio"), update the actual nested structure
            _update_nested_subfield_value(parent_field, subfield, new_value)
          end
        end

        def _update_nested_subfield_value(parent_field, subfield, new_value)
          parent_value = @__context.provided_data[parent_field]

          # Split the subfield path (e.g., "profile.bio" -> ["profile", "bio"])
          path_parts = subfield.to_s.split(".")

          # Navigate to the parent of the target field
          target_parent = path_parts[0..-2].reduce(parent_value) do |current, part|
            # Try both symbol and string keys
            current[part.to_sym] || current[part] || (current[part.to_sym] = {})
          end

          # Set the final field value
          target_parent[path_parts.last.to_sym] = new_value
        end
      end
    end
  end
end
