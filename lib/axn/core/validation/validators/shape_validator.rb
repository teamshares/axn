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
    # #validations, and optionally #method_call — a member that doesn't implement it defaults to no
    # method dispatch); options[:container] is the declared structured type (Array, Hash, or a class).
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
        # `record` is the parent field's one-off validator, which carries the action (threaded by
        # errors_for at every level) — pass it down so a member's Symbol/Proc arguments and
        # if:/unless: conditions resolve against the ACTION, exactly as at the top level (a member
        # condition is action-scoped, never element-scoped). Orthogonal to the dispatch gate:
        # permission stays the member's own method_call: opt-in, never inferred from the action.
        action = record.send(:_action_for_validation)

        members.each do |member|
          unless extractable?(source, member.field)
            # A closed declaration-level gate waives the member entirely — every validator, and so
            # this pre-check too. For an extractable source AM skips the gated validators itself
            # (below); a non-extractable source never reaches AM, so mirror that waiver here.
            next if member_gate_closed?(member, source, action)

            record.errors.add(attribute, "#{prefix}#{member.field} could not be read (got #{source.class})")
            next
          end

          errors = Axn::Validation::Fields.errors_for(
            member_validator_classes[member.field],
            source:, validations: member.validations,
            action:, permit_method_call: member_method_call?(member)
          )
          errors.each { |error| record.errors.add(attribute, "#{prefix}#{member.field} #{error.message}") }
        end
      end

      # Whether a non-extractable member's declaration-level if:/unless: gate is CLOSED — in which
      # case the unreadable-member error is suppressed, mirroring how AM skips a gated validator on
      # an extractable source. Key-presence first so an ungated member constructs nothing and stays
      # byte-identical. The receiver is the member's own one-off validator (built once, reused) with
      # the action threaded — the same `self` its real validation would use — via the shared mirror
      # of AM's condition resolution.
      def member_gate_closed?(member, source, action)
        return false unless Axn::Internal::FieldConfig::CONDITIONAL_GATE_KEYS.any? { |key| member.validations.key?(key) }

        validator = member_validator_classes[member.field].new(source)
        validator.instance_variable_set(:@action, action)
        validator.instance_variable_set(:@validations, member.validations)
        validator.instance_variable_set(:@permit_method_call, member_method_call?(member))
        !Axn::Validation::Fields.declaration_gate_open?(validator)
      end

      def members = options[:members] || []

      # A member's `method_call:` opt-in, honored when present. The documented member contract is
      # duck-typed (`#field` + `#validations`) — a raw `shape:` supplied with a member object that
      # doesn't implement `#method_call` is treated as not opted in (the safe default: no dispatch),
      # rather than raising. Declared shapes always yield ShapeConfig, which carries the reader.
      def member_method_call?(member) = member.respond_to?(:method_call) && member.method_call

      # A value can yield a named member only if it responds to the reader (objects/Data) or
      # supports named-key access (Hash-like). Arrays respond to #dig but only by integer index,
      # so `Array#dig("status")` would raise a TypeError; excluding them keeps the element index in
      # the error (e.g. "element at index 0: status could not be read") instead of letting the
      # resolver raise and lose it. Guarding here mirrors FieldResolvers::Extract's own dispatch.
      # Being extractable is necessary but not sufficient to READ a member by method dispatch: a
      # non-`Data` object reader / Array method is resolved only when the member opted in with
      # `method_call: true`, otherwise the read raises MethodCallNotPermittedError (PRO-2907). The
      # safe branches (Hash keys, Struct/OpenStruct/Data members) never dispatch and need no flag.
      def extractable?(source, field)
        return true if source.respond_to?(field)

        source.respond_to?(:dig) && !source.is_a?(Array)
      end

      # One validator class per member, built once and reused across every element/value.
      def member_validator_classes
        @member_validator_classes ||= members.to_h do |member|
          [member.field, Axn::Validation::Fields.validator_class_for(field: member.field, validations: member.validations)]
        end
      end
    end
  end
end
