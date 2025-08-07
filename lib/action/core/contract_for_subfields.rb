# frozen_string_literal: true

require "action/core/validation/subfields"

module Action
  module Core
    module ContractForSubfields
      # TODO: add default, preprocess, sensitive options for subfields?
      # SubfieldConfig = Data.define(:field, :validations, :default, :preprocess, :sensitive)
      SubfieldConfig = Data.define(:field, :validations, :on)

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

          # TODO: add support for these three options for subfields
          default: nil,
          preprocess: nil,
          sensitive: false,

          **validations
        )
          # TODO: add support for these three options for subfields
          raise ArgumentError, "expects does not support :default key when also given :on" if default.present?
          raise ArgumentError, "expects does not support :preprocess key when also given :on" if preprocess.present?
          raise ArgumentError, "expects does not support :sensitive key when also given :on" if sensitive.present?

          unless internal_field_configs.map(&:field).include?(on) || subfield_configs.map(&:field).include?(on)
            raise ArgumentError,
                  "expects called with `on: #{on}`, but no such method exists (are you sure you've declared `expects :#{on}`?)"
          end

          raise ArgumentError, "expects does not support expecting fields on nested attributes (i.e. `on` cannot contain periods)" if on.to_s.include?(".")

          # TODO: consider adding support for default, preprocess, sensitive options for subfields?
          _parse_subfield_configs(*fields, on:, readers:, allow_blank:, allow_nil:, **validations).tap do |configs|
            duplicated = subfield_configs.map(&:field) & configs.map(&:field)
            raise Action::DuplicateFieldError, "Duplicate field(s) declared: #{duplicated.join(", ")}" if duplicated.any?

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
          # default: nil,
          # preprocess: nil,
          # sensitive: false,
          **validations
        )
          _parse_field_validations(*fields, allow_nil:, allow_blank:, **validations).map do |field, parsed_validations|
            _define_subfield_reader(field, on:, validations: parsed_validations) if readers
            SubfieldConfig.new(field:, validations: parsed_validations, on:)
          end
        end

        def _define_subfield_reader(field, on:, validations:)
          # Don't create top-level readers for nested fields
          return if field.to_s.include?(".")

          raise ArgumentError, "expects does not support duplicate sub-keys (i.e. `#{field}` is already defined)" if method_defined?(field)

          define_memoized_reader_method(field) do
            Action::Validation::Subfields.extract(field, public_send(on))
          end

          _define_model_reader(field, validations[:model]) if validations.key?(:model)
        end
      end

      module InstanceMethods
        def _validate_subfields_contract!
          return if subfield_configs.blank?

          subfield_configs.each do |config|
            Validation::Subfields.validate!(
              field: config.field,
              validations: config.validations,
              source: public_send(config.on),
              exception_klass: Action::InboundValidationError,
            )
          end
        end
      end
    end
  end
end
