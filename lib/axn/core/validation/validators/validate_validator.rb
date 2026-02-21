# frozen_string_literal: true

require "active_model"

module Axn
  module Validators
    class ValidateValidator < ActiveModel::EachValidator
      def self.apply_syntactic_sugar(value, _fields)
        return value if value.is_a?(Hash)

        { with: value }
      end

      def check_validity!
        raise ArgumentError, "must supply :with" if options[:with].nil?
      end

      def validate_each(record, attribute, value)
        msg = begin
          options[:with].call(value)
        rescue StandardError => e
          Axn::Internal::PipingError.swallow("applying custom validation on field '#{attribute}'", exception: e)

          "failed validation: #{e.message}"
        end

        record.errors.add(attribute, msg) if msg.present?
      end
    end
  end
end
