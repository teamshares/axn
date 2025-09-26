# frozen_string_literal: true

require "axn/core/validation/subfields"

module Axn
  module Core
    module ContractForSubfields
      SubfieldConfig = Data.define(:field, :validations, :on, :sensitive, :preprocess, :default)

      def self.included(base)
        base.class_eval do
          class_attribute :subfield_configs, default: []

          extend ClassMethods
        end
      end

      module ClassMethods
        def _expects_subfields(
          *fields,
          on:,
          readers: true,
          allow_blank: false,
          allow_nil: false,
          optional: false,
          default: nil,
          preprocess: nil,
          sensitive: false,

          **validations
        )
          unless internal_field_configs.map(&:field).include?(on) || subfield_configs.map(&:field).include?(on)
            raise ArgumentError,
                  "expects called with `on: #{on}`, but no such method exists (are you sure you've declared `expects :#{on}`?)"
          end

          raise ArgumentError, "expects does not support expecting fields on nested attributes (i.e. `on` cannot contain periods)" if on.to_s.include?(".")

          _parse_subfield_configs(*fields, on:, readers:, allow_blank:, allow_nil:, optional:, preprocess:, sensitive:, default:,
                                           **validations).tap do |configs|
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
          optional: false,
          preprocess: nil,
          sensitive: false,
          default: nil,
          **validations
        )
          # Handle optional: true by setting allow_blank: true
          allow_blank ||= optional

          _parse_field_validations(*fields, allow_nil:, allow_blank:, **validations).map do |field, parsed_validations|
            _define_subfield_reader(field, on:, validations: parsed_validations) if readers
            SubfieldConfig.new(field:, validations: parsed_validations, on:, sensitive:, preprocess:, default:)
          end
        end

        def _define_subfield_reader(field, on:, validations:)
          # Don't create top-level readers for nested fields
          return if field.to_s.include?(".")

          raise ArgumentError, "expects does not support duplicate sub-keys (i.e. `#{field}` is already defined)" if method_defined?(field)

          Axn::Util::Memoization.define_memoized_reader_method(self, field) do
            Axn::Core::FieldResolvers.resolve(type: :extract, field:, provided_data: public_send(on))
          end

          _define_subfield_model_reader(field, validations[:model], on:) if validations.key?(:model)
        end

        def _define_subfield_model_reader(field, options, on:)
          # Apply the same syntactic sugar processing as the main contract system
          processed_options = Axn::Validators::ModelValidator.apply_syntactic_sugar(options, [field])

          Axn::Util::Memoization.define_memoized_reader_method(self, field) do
            # Create a data source that contains the subfield data for the resolver
            subfield_data = public_send(on)

            Axn::Core::FieldResolvers.resolve(
              type: :model,
              field:,
              options: processed_options,
              provided_data: subfield_data,
            )
          end
        end
      end
    end
  end
end
