# frozen_string_literal: true

require "active_model"

module Axn
  module Validators
    class ModelValidator < ActiveModel::EachValidator
      def check_validity!
        return unless options[:with].nil?

        raise ArgumentError, "must supply :with"
      end

      def validate_each(record, attribute, value)
        # The value is already resolved by the facade, just validate the type
        type_validator = TypeValidator.new(attributes: [attribute], **options)
        type_validator.validate_each(record, attribute, value)
      end
    end
  end
end
