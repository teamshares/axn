# frozen_string_literal: true

require "active_model"

module Axn
  module Validators
    class ModelValidator < ActiveModel::EachValidator
      # Syntactic sugar: model: User -> model: { klass: User }
      def self.apply_syntactic_sugar(value, fields)
        (value.is_a?(Hash) ? value.dup : { klass: value }).tap do |options|
          # Set default klass based on field name if not provided
          options[:klass] = nil if options[:klass] == true
          options[:klass] ||= fields.first.to_s.classify

          # Constantize string klass names
          options[:klass] = options[:klass].constantize if options[:klass].is_a?(String)

          # Set default finder if not provided
          options[:finder] ||= :find
        end
      end

      def check_validity!
        return unless options[:klass].nil?

        raise ArgumentError, "must supply :klass"
      end

      def validate_each(record, attribute, value)
        # The value is already resolved by the facade, just validate the type
        type_validator = TypeValidator.new(attributes: [attribute], **options)
        type_validator.validate_each(record, attribute, value)
      end
    end
  end
end
