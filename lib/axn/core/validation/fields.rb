# frozen_string_literal: true

module Axn
  module Validation
    class Fields
      include ActiveModel::Validations

      # NOTE: defining classes where needed b/c we explicitly register it'll affect ALL the consuming apps' validators as well
      ModelValidator = Validators::ModelValidator
      TypeValidator = Validators::TypeValidator
      ValidateValidator = Validators::ValidateValidator

      def initialize(context)
        @context = context
      end

      def read_attribute_for_validation(attr)
        # The context here is actually a facade (InternalContext or Result)
        # which already handles reading from the correct data source
        @context.public_send(attr)
      end

      def method_missing(method_name, ...)
        # Delegate method calls to the action instance to support symbol-based validations
        # like inclusion: { in: :valid_channels_for_number }
        action = _action_for_validation
        return super unless action && action.respond_to?(method_name, true) # rubocop:disable Style/SafeNavigation

        action.send(method_name, ...)
      end

      def respond_to_missing?(method_name, include_private = false)
        action = _action_for_validation
        return super unless action

        action.respond_to?(method_name, include_private) || super
      end

      def self.validate!(validations:, context:, exception_klass:)
        validator = Class.new(self) do
          def self.name = "Axn::Validation::Fields::OneOff"

          validations.each do |field, field_validations|
            field_validations.each do |key, value|
              validates field, key => value
            end
          end
        end.new(context)

        return if validator.valid?

        raise exception_klass, validator.errors
      end

      private

      def _action_for_validation
        return unless @context.respond_to?(:action, true)

        @context.send(:action)
      end
    end
  end
end
