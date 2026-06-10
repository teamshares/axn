# frozen_string_literal: true

require "active_model"

module Axn
  module Validators
    class OfValidator < ActiveModel::EachValidator
      def self.apply_syntactic_sugar(value, _fields)
        return value if value.is_a?(Hash)

        { klass: value }
      end

      def check_validity!
        raise ArgumentError, "must supply :klass" if options[:klass].nil?
      end

      def validate_each(record, attribute, value)
        return if value.nil? && (options[:allow_nil] || options[:allow_blank])
        return unless value.is_a?(Array)  # TypeValidator owns the non-Array error

        klasses = Array(options[:klass])
        msg = klasses.size == 1 ? "is not a #{klasses.first}" : "is not one of #{klasses.join(", ")}"

        value.each_with_index do |el, i|
          valid = klasses.any? { |k| TypeValidator.value_matches?(el, klass: k, allow_blank: options[:allow_blank]) }
          record.errors.add(attribute, "element at index #{i} #{msg}") unless valid
        end
      end
    end
  end
end
