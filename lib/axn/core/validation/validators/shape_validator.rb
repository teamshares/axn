# frozen_string_literal: true

require "active_model"

module Axn
  module Validators
    # Validates the per-member shape of a structured field declared via a block:
    #
    #   expects :items, type: Array do
    #     field :status, type: String, inclusion: { in: %w[a b] }
    #   end
    #
    # options[:members] is an array of ShapeConfig-like objects (responding to #field and
    # #validations); options[:container] is the declared structured type (Array, Hash, or a class).
    # For an Array container each element is validated with its index in the message; for any other
    # container the single value's members are validated directly. A value that doesn't match the
    # declared container is left to TypeValidator (we don't try to extract members from it). Nesting
    # falls out for free: a member whose validations include a :shape key recurses through the same
    # machinery.
    class ShapeValidator < ActiveModel::EachValidator
      def check_validity!
        raise ArgumentError, "must supply :members" if options[:members].nil?
      end

      def validate_each(record, attribute, value)
        return if value.nil? && (options[:allow_nil] || options[:allow_blank])

        if options[:container] == Array
          return unless value.is_a?(Array) # TypeValidator owns the non-Array error

          value.each_with_index do |element, index|
            validate_members(record, attribute, element, prefix: "element at index #{index}: ")
          end
        else
          return unless value.is_a?(options[:container]) # TypeValidator owns the type mismatch

          validate_members(record, attribute, value, prefix: "")
        end
      end

      private

      def validate_members(record, attribute, source, prefix:)
        members.each do |member|
          unless extractable?(source, member.field)
            record.errors.add(attribute, "#{prefix}#{member.field} could not be read (got #{source.class})")
            next
          end

          errors = Axn::Validation::Subfields.errors_for(member_validator_classes[member.field], source:, validations: member.validations)
          errors.each { |error| record.errors.add(attribute, "#{prefix}#{member.field} #{error.message}") }
        end
      end

      def members = options[:members] || []

      # Mirrors FieldResolvers::Extract's own logic: a value yields a member only if it responds to
      # the reader (objects/Data) or to #dig (Hash-like). Guarding here keeps the element index in
      # the error instead of letting the resolver raise and lose it.
      def extractable?(source, field)
        source.respond_to?(field) || source.respond_to?(:dig)
      end

      # One validator class per member, built once and reused across every element/value.
      def member_validator_classes
        @member_validator_classes ||= members.to_h do |member|
          [member.field, Axn::Validation::Subfields.validator_class_for(field: member.field, validations: member.validations)]
        end
      end
    end
  end
end
