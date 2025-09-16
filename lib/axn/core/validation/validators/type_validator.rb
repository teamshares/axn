# frozen_string_literal: true

require "active_model"

module Axn
  module Validators
    class TypeValidator < ActiveModel::EachValidator
      def check_validity!
        raise ArgumentError, "must supply :with" if options[:with].nil?
      end

      # NOTE: we override the default validate method to allow for custom allow_blank logic
      # (e.g. type: Hash should fail if given false or "", but by default EachValidator would skip)
      def validate(record)
        attributes.each do |attribute|
          value = record.read_attribute_for_validation(attribute)
          validate_each(record, attribute, value)
        end
      end

      def validate_each(record, attribute, value)
        # Custom allow_blank logic: only skip validation for nil, not other blank values
        return if value.nil? && (options[:allow_nil] || options[:allow_blank])

        # Check if any of the types are valid
        valid = types.any? do |type|
          valid_type?(type:, value:, allow_blank: options[:allow_blank])
        end

        record.errors.add attribute, (options[:message] || msg) unless valid
      end

      private

      def types = Array(options[:with])
      def msg = types.size == 1 ? "is not a #{types.first}" : "is not one of #{types.join(", ")}"

      def valid_type?(type:, value:, allow_blank:)
        # NOTE: allow mocks to pass type validation by default (much easier testing ergonomics)
        return true if Axn.config.env.test? && value.class.name&.start_with?("RSpec::Mocks::")

        case type
        when :boolean
          boolean_type?(value)
        when :uuid
          uuid_type?(value, allow_blank:)
        when :params
          params_type?(value)
        else
          class_type?(type, value)
        end
      end

      def boolean_type?(value)
        [true, false].include?(value)
      end

      def uuid_type?(value, allow_blank: false)
        return false unless value.is_a?(String)
        return true if value.blank? && allow_blank

        value.match?(/\A[0-9a-f]{8}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{12}\z/i)
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
