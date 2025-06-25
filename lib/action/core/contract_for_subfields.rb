# frozen_string_literal: true

require "action/core/subfield_validator"

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
        if readers
          _define_subfield_readers(fields, on:)
          # TODO: model readers?
        end

        _parse_field_validations(*fields, allow_nil:, allow_blank:, **validations).map do |field, parsed_validations|
          SubfieldConfig.new(field:, validations: parsed_validations, on:)
        end
      end

      def _define_subfield_readers(fields, on:)
        fields.each do |field|
          # Don't create top-level readers for nested fields
          next if field.to_s.include?(".")

          define_method(field) do
            ivar = :"@_memoized_reader_#{field}"
            cached_val = instance_variable_get(ivar)
            return cached_val if cached_val.present?

            value = public_send(on).fetch(field)
            instance_variable_set(ivar, value)
          end
        end
      end

      def create_model_data_reader(field, validations)
        name = field.to_s.delete_suffix("_id")
        raise ArgumentError, "#{name}: model validation expects to be given a field ending in _id" unless field.to_s.end_with?("_id")

        create_data_reader(name) do
          klass = DataShapeValidator::ModelValidator.model_for(attribute: field, klass: validations[:model])
          klass.find_by(id: public_send(field))
        end
      end
    end

    module InstanceMethods
      def _validate_subfields_contract!
        return if subfield_configs.blank?

        subfield_configs.each do |config|
          SubfieldValidator.validate!(
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
