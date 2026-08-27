# frozen_string_literal: true

require "active_model"

require "axn/internal/rendering"
require "axn/internal/shape_graph"

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

        record.errors.add attribute, (options[:message] || failure_message(value)) unless valid
      end

      # A test double stands in for a value of any declared type: type validation waves them through so a
      # spec need not build a real instance. Named so every check that would otherwise report a double as a
      # contract violation can waive itself on the same terms.
      #
      # The class is NAMED rather than asked: `value.class` is the value's own reader, and what this decides
      # is whether type validation is waived entirely — so a value answering for itself waives its own
      # contract check, and one that raises replaces the validation verdict with its exception. Reading it
      # through the shared renderer (bound `Object#class` plus `Module#to_s`) also drops the `&.`, since it
      # always answers a String — an anonymous class's `#<Class:0x…>` takes the same branch `nil` did.
      def self.mock_value?(value)
        Axn.config.env.test? && Axn::Internal::Rendering.class_name(value).start_with?("RSpec::Mocks::")
      end

      # Shared matcher used by OfValidator for per-element type checking.
      def self.value_matches?(value, klass:, allow_blank: false)
        return true if mock_value?(value)

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

      # `ShapeGraph.type_tokens`, not `Kernel#Array`: `options[:klass]` is the caller's own declared token, read
      # fresh on every `validate_each` — a hostile `to_ary` would run on every call rather than once (PRO-3233).
      def types = Axn::Internal::ShapeGraph.type_tokens(options[:klass])

      # Named through the shared seam for the reason `OfValidator#describe_mismatch` is: interpolating a
      # declared class runs its own `to_s`, and one that raises replaces the validation failure with its
      # exception.
      def msg
        labels = types.map { |type| Axn::Internal::Rendering.type_label(type) }
        labels.size == 1 ? "is not a #{labels.first}" : "is not one of #{labels.join(', ')}"
      end

      # A field that opted into coercion but is still holding a coercion-candidate value means the
      # value couldn't be parsed into any target type -- distinguish that from a plain wrong-type
      # value that was never a candidate. Value-free, like `msg`, so no sensitive input leaks.
      def failure_message(value)
        return coercion_msg if options[:coerce] && coercion_candidate?(value)

        msg
      end

      # What coerce_value would have attempted: a String for any target, plus an Integer for a
      # `:boolean` target (the one coercer that accepts a non-String wire form). A leftover value of
      # either kind is uncoerceable data; anything else is a genuine wrong-type value.
      def coercion_candidate?(value)
        return true if value.is_a?(String)

        value.is_a?(Integer) && types.include?(:boolean)
      end

      def coercion_msg
        types.size == 1 ? "could not be coerced to a #{types.first}" : "could not be coerced to one of #{types.join(', ')}"
      end
    end
  end
end
