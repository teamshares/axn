# frozen_string_literal: true

require "active_model"

module Axn
  module Validators
    class TypeValidator < ActiveModel::EachValidator
      def validate_each(record, attribute, value)
        # NOTE: the last one (:value) might be my fault from the make-it-a-hash fallback in #parse_field_configs
        types = options[:in].presence || Array(options[:with]).presence || Array(options[:value]).presence

        return if value.blank? && !types.include?(:boolean) && !types.include?(:params) # Handled with a separate default presence validator

        msg = types.size == 1 ? "is not a #{types.first}" : "is not one of #{types.join(", ")}"
        record.errors.add attribute, (options[:message] || msg) unless types.any? do |type|
          valid_type?(type, value)
        end
      end

      private

      def valid_type?(type, value)
        # NOTE: allow mocks to pass type validation by default (much easier testing ergonomics)
        return true if Axn.config.env.test? && value.class.name&.start_with?("RSpec::Mocks::")

        case type
        when :boolean
          boolean_type?(value)
        when :uuid
          uuid_type?(value)
        when :params
          params_type?(value)
        else
          class_type?(type, value)
        end
      end

      def boolean_type?(value)
        [true, false].include?(value)
      end

      def uuid_type?(value)
        value.is_a?(String) && value.match?(/\A[0-9a-f]{8}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{12}\z/i)
      end

      def params_type?(value)
        value.is_a?(Hash) || (defined?(ActionController::Parameters) && value.is_a?(ActionController::Parameters))
      end

      def class_type?(type, value)
        value.is_a?(type)
      end
    end
  end
end
