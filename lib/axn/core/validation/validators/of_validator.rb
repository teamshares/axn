# frozen_string_literal: true

require "active_model"

require "axn/internal/rendering"
require "axn/internal/shape_graph"

module Axn
  module Validators
    class OfValidator < ActiveModel::EachValidator
      def self.apply_syntactic_sugar(value, _fields)
        return value if value.is_a?(Hash)

        { klass: value }
      end

      # A map names its axes with `keys:`/`values:`, either of which may be left off, so `klass:` is required
      # only of the element form.
      def check_validity!
        return if options[:container] == ::Hash

        raise ArgumentError, "must supply :klass" if options[:klass].nil?
      end

      def validate_each(record, attribute, value)
        return if value.nil? && (options[:allow_nil] || options[:allow_blank])

        options[:container] == ::Hash ? validate_entries(record, attribute, value) : validate_elements(record, attribute, value)
      end

      private

      # The declared container decides which branch runs; the value's own class only decides whether this
      # validator has anything to say about it. TypeValidator owns both mismatches.
      def validate_elements(record, attribute, value)
        return unless value.is_a?(::Array)

        klasses = Array(options[:klass])
        # A custom message: replaces the type description but the index is always reported —
        # element position is the locating info that makes a per-element error actionable.
        msg = options[:message] || describe_mismatch(klasses)

        value.each_with_index do |el, i|
          # allow_blank governs whether the whole field may be absent (handled above), not whether
          # individual elements may be blank — so it is intentionally not passed to the matcher.
          valid = klasses.any? { |k| TypeValidator.value_matches?(el, klass: k) }
          record.errors.add(attribute, "element at index #{i} #{msg}") unless valid
        end
      end

      # Both axes are reported independently: a map whose keys and values are both wrong has two things to fix,
      # and the key is what locates the value either way. An axis left undeclared constrains nothing.
      def validate_entries(record, attribute, value)
        return unless value.is_a?(::Hash)

        key_klasses = Array(options[:keys])
        value_klasses = Array(options[:values])

        # Traversed through a BOUND `Hash#each` so a subclass cannot decide which entries get validated.
        Axn::Internal::ShapeGraph.each_entry(value) do |key, entry|
          rendered = Axn::Internal::Rendering.hash_key(key)

          record.errors.add(attribute, "key #{rendered} #{describe_mismatch(key_klasses)}") unless matches_axis?(key, key_klasses)
          next if matches_axis?(entry, value_klasses)

          record.errors.add(attribute, "value at key #{rendered} #{describe_mismatch(value_klasses)}")
        end
      end

      def matches_axis?(value, klasses)
        klasses.empty? || klasses.any? { |k| TypeValidator.value_matches?(value, klass: k) }
      end

      def describe_mismatch(klasses)
        klasses.size == 1 ? "is not a #{klasses.first}" : "is not one of #{klasses.join(', ')}"
      end
    end
  end
end
