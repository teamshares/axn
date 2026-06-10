# frozen_string_literal: true

require "active_model"

module Axn
  module Validators
    class TypeValidator < ActiveModel::EachValidator
      def self.apply_syntactic_sugar(value, _fields)
        return value if value.is_a?(Hash)

        { klass: value }
      end

      def check_validity!
        raise ArgumentError, "must supply :klass" if options[:klass].nil?
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
          self.class.value_matches?(value, klass: type, allow_blank: options[:allow_blank])
        end

        record.errors.add attribute, (options[:message] || msg) unless valid
      end

      # Shared matcher used by OfValidator for per-element type checking.
      def self.value_matches?(value, klass:, allow_blank: false)
        # NOTE: allow mocks to pass type validation by default (much easier testing ergonomics)
        return true if Axn.config.env.test? && value.class.name&.start_with?("RSpec::Mocks::")

        case klass
        when :boolean
          [true, false].include?(value)
        when :uuid
          value.is_a?(String) && (value.blank? ? allow_blank : value.match?(/\A[0-9a-f]{8}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{12}\z/i))
        when :params
          value.is_a?(Hash) || (defined?(ActionController::Parameters) && value.is_a?(ActionController::Parameters))
        else
          value.is_a?(klass)
        end
      end

      private

      def types = Array(options[:klass])
      def msg = types.size == 1 ? "is not a #{types.first}" : "is not one of #{types.join(', ')}"
    end
  end
end
