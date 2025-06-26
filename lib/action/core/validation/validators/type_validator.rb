# frozen_string_literal: true

require "active_model"

module Action
  module Validators
    class TypeValidator < ActiveModel::EachValidator
      def validate_each(record, attribute, value)
        # NOTE: the last one (:value) might be my fault from the make-it-a-hash fallback in #parse_field_configs
        types = options[:in].presence || Array(options[:with]).presence || Array(options[:value]).presence

        return if value.blank? && !types.include?(:boolean) # Handled with a separate default presence validator

        msg = types.size == 1 ? "is not a #{types.first}" : "is not one of #{types.join(", ")}"
        record.errors.add attribute, (options[:message] || msg) unless types.any? do |type|
          if type == :boolean
            [true, false].include?(value)
          elsif type == :uuid
            value.is_a?(String) && value.match?(/\A[0-9a-f]{8}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{12}\z/i)
          else
            # NOTE: allow mocks to pass type validation by default (much easier testing ergonomics)
            next true if Action.config.env.test? && value.class.name&.start_with?("RSpec::Mocks::")

            value.is_a?(type)
          end
        end
      end
    end
  end
end
