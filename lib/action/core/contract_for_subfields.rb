# frozen_string_literal: true

require "action/core/validation/subfields"

module Action
  module ContractForSubfields
    # TODO: add default, preprocess, sensitive options for subfields?
    # SubfieldConfig = Data.define(:field, :validations, :default, :preprocess, :sensitive)
    SubfieldConfig = Data.define(:field, :validations, :on)

    def self.included(base)
      base.class_eval do
        class_attribute :subfield_configs, default: []

        extend ClassMethods
        include InstanceMethods

        # TODO: compare before vs around hook
        # around do |hooked|
        #   _validate_subfield_contract!
        #   hooked.call
        # end

        before { _validate_subfields_contract! }
      end
    end

    module ClassMethods
      def expects_fields(
        *fields,
        on:,
        readers: true,
        allow_blank: false,
        allow_nil: false,
        # default: nil,
        # preprocess: nil,
        # sensitive: false,
        **validations
      )
        unless internal_field_configs.map(&:field).include?(on) || subfield_configs.map(&:field).include?(on)
          raise ArgumentError,
                "expects_fields called with `on: #{on}`, but no such method exists (are you sure you've declared `expects :#{on}`?)"
        end

        raise ArgumentError, "expects_fields does not support expecting fields on nested attributes (i.e. `on` cannot contain periods)" if on.to_s.include?(".")

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

        raise ArgumentError, "expects_fields does not support duplicate sub-keys (i.e. `#{field}` is already defined)" if method_defined?(field)

        # TODO:
        # define_memoized_reader_method(field) do
        define_method(field) do
          public_send(on).fetch(field)
        end

        _define_model_reader(field, validations[:model]) if validations.key?(:model)
      end

      def define_memoized_reader_method(field)
        define_method(field) do
          ivar = :"@_memoized_reader_#{field}"
          cached_val = instance_variable_get(ivar)
          return cached_val if cached_val.present?

          instance_variable_set(ivar, yield)
        end
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
