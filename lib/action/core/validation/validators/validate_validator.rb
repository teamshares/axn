# frozen_string_literal: true

require "active_model"

module Action
  module Validators
    class ValidateValidator < ActiveModel::EachValidator
      def validate_each(record, attribute, value)
        msg = begin
          options[:with].call(value)
        rescue StandardError => e
          Action.config.logger.warn("Custom validation on field '#{attribute}' raised #{e.class.name}: #{e.message}")

          "failed validation: #{e.message}"
        end

        record.errors.add(attribute, msg) if msg.present?
      end
    end
  end
end
