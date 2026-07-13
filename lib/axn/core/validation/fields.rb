# frozen_string_literal: true

require "axn/core/validation/base"

module Axn
  module Validation
    class Fields < Base
      def initialize(context)
        super()
        @context = context
      end

      def read_attribute_for_validation(attr)
        # The context here is actually a facade (InternalContext or Result)
        # which already handles reading from the correct data source
        @context.public_send(attr)
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
