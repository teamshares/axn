# frozen_string_literal: true

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

        # fields.each do |field, validations|
        #   # Don't create top-level readers for nested fields
        #   next if field.to_s.include?(".")

        #   create_data_reader(field) { DataShapeValidator.extract(field, data) }
        #   create_model_data_reader(field, validations) if validations.key?(:model)
        # end.keys

        # TODO: consider adding support for default, preprocess, sensitive options for subfields?
        _parse_subfield_configs(*fields, on:, allow_blank:, allow_nil:, **validations).tap do |configs|
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
        allow_blank: false,
        allow_nil: false,
        # default: nil,
        # preprocess: nil,
        # sensitive: false,
        **validations
      )
        # _define_field_readers(fields)
        # TODO: model readers?
        _parse_field_validations(*fields, allow_nil:, allow_blank:, **validations).map do |field, parsed_validations|
          SubfieldConfig.new(field:, validations: parsed_validations, on:)
        end
      end

      def create_subfield_reader(field, &block)
        define_method(field) do
          ivar = :"@_memoized_reader_#{field}"
          cached_val = instance_variable_get(ivar)
          return cached_val if cached_val.present?

          value = instance_exec(&block)
          instance_variable_set(ivar, value)
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

        # subfield_configs

        DataShapeValidator.validate!(
          validations: _data_shape_validations,
          data:,
        )
        # puts "VALIDATING SUBFIELDS CONTRACT"
        # raise ArgumentError, "Invalid direction: #{direction}" unless %i[inbound outbound].include?(direction)

        # configs = direction == :inbound ? internal_field_configs : external_field_configs
        # validations = configs.each_with_object({}) do |config, hash|
        #   hash[config.field] = config.validations
        # end
        # context = direction == :inbound ? internal_context : external_context
        # exception_klass = direction == :inbound ? Action::InboundValidationError : Action::OutboundValidationError

        # ContractValidator.validate!(validations:, context:, exception_klass:)
      end
    end
  end
end

# TODO: ??
# class DataShapeValidator
#   include ActiveModel::Validations
#   include DeclarativeInitialization
#   initialize_with data: {}

#   def self.extract(key, data) = data.dig(*key.to_s.split("."))
#   def read_attribute_for_validation(key) = self.class.extract(key, @data)

#   def self.validate!(validations:, data:)
#     validator = Class.new(self) do
#       def self.name = "TS::DataShapeValidator"

#       validations.each do |field, field_validations|
#         validates field, **field_validations
#       end
#     end.new(data:)

#     return if validator.valid?

#     raise Action::InboundValidationError, validator.errors
#   end
# end
