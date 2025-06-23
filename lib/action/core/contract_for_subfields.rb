# frozen_string_literal: true

module Action
  module ContractForSubfields
    def self.included(base)
      base.class_eval do
        class_attribute :subfield_configs, default: {}

        extend ClassMethods
        include InstanceMethods

        # TODO: compare before vs around hook
        # around do |hooked|
        #   _validate_subfield_contract!
        #   hooked.call
        # end

        before { _validate_subfield_contract! }
      end
    end

    module ClassMethods
      def expects_subfields(*fields, on:, **validations)
        unless method?(on)
          raise ArgumentError,
                "expects_subfields called with on: #{on}, but no such method exists (are you sure you've declared 'expects #{on}'?)"
        end

        # TODO: check for class_attribute usage (modifying vs resetting)
        subfield_configs[on] = { fields:, validations: }
      end

      def _parse_field_configs(*fields, allow_nil: false, allow_blank: false, default: nil, preprocess: nil, sensitive: false,
                               **validations)
        # Allow local access to explicitly-expected fields -- even externally-expected needs to be available locally
        # (e.g. to allow success message callable to reference exposed fields)
        fields.each do |field|
          define_method(field) { internal_context.public_send(field) }
        end

        if allow_blank
          validations.transform_values! do |v|
            v = { value: v } unless v.is_a?(Hash)
            { allow_blank: true }.merge(v)
          end
        elsif allow_nil
          validations.transform_values! do |v|
            v = { value: v } unless v.is_a?(Hash)
            { allow_nil: true }.merge(v)
          end
        else
          validations[:presence] = true unless validations.key?(:presence) || Array(validations[:type]).include?(:boolean)
        end

        fields.map { |field| FieldConfig.new(field:, validations:, default:, preprocess:, sensitive:) }
      end
    end

    module InstanceMethods
      def _validate_subfield_contract!
        raise ArgumentError, "Invalid direction: #{direction}" unless %i[inbound outbound].include?(direction)

        configs = direction == :inbound ? internal_field_configs : external_field_configs
        validations = configs.each_with_object({}) do |config, hash|
          hash[config.field] = config.validations
        end
        context = direction == :inbound ? internal_context : external_context
        exception_klass = direction == :inbound ? Action::InboundValidationError : Action::OutboundValidationError

        ContractValidator.validate!(validations:, context:, exception_klass:)
      end
    end
  end
end

__END__

module TS
  module Concerns
    module ExpectsDataShape
      extend ActiveSupport::Concern

      included do
        class_attribute :_data_shape_validations, default: {}

        before :validate_data_shape
      end

      class_methods do
        def expects_data_shape(*args, **kwargs)
          args.each do |key|
            kwargs[key] = (kwargs[key] || {}).merge({ presence: true })
          end

          self._data_shape_validations = _data_shape_validations.merge(kwargs)

          kwargs.each do |field, validations|
            # Don't create top-level readers for nested fields
            next if field.to_s.include?(".")

            create_data_reader(field) { DataShapeValidator.extract(field, data) }
            create_model_data_reader(field, validations) if validations.key?(:model)
          end.keys
        end

        private

        def create_data_reader(field, &block)
          define_method(field) do
            ivar = "@_memoized_reader_#{field}".to_sym
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

      def data = raise NotImplementedError, "expects_data_shape: data must be implemented by subclass"

      class DataShapeValidator
        include ActiveModel::Validations
        include DeclarativeInitialization
        initialize_with data: {}

        def self.extract(key, data) = data.dig(*key.to_s.split("."))
        def read_attribute_for_validation(key) = self.class.extract(key, @data)

        def self.validate!(validations:, data:)
          validator = Class.new(self) do
            def self.name = "TS::DataShapeValidator"

            validations.each do |field, field_validations|
              validates field, **field_validations
            end
          end.new(data:)

          return if validator.valid?

          raise Action::InboundValidationError, validator.errors
        end
      end

      def validate_data_shape
        return if _data_shape_validations.blank?

        DataShapeValidator.validate!(
          validations: _data_shape_validations,
          data:,
        )
      end
    end
  end
end
