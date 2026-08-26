# frozen_string_literal: true

require "active_model"

require "axn/internal/rendering"

module Axn
  module Validators
    class ValidateValidator < ActiveModel::EachValidator
      # `nested:` is required rather than defaulted: it decides which REMEDY the misuse message offers, and the
      # two are different advice. Both call sites name it, and a third that forgot would otherwise send the
      # author to the wrong position.
      def self.apply_syntactic_sugar(value, _fields, nested:)
        if value.is_a?(Hash)
          # `validate:` is the CUSTOM-callable validator; a Hash form must carry the callable under
          # `:with` (`validate: { with: <callable>, message: "…" }`). A Hash without `:with` is a
          # misuse — most often ActiveModel validator keys mistakenly nested under `validate:`
          # (`validate: { inclusion: { in: [...] } }`), which enforces nothing and would otherwise
          # raise a bare `must supply :with` at CALL time. Fail loudly here (declaration time) with the
          # fix, since this runs during `expects`/`exposes`.
          unless value.key?(:with)
            raise ArgumentError,
                  "`validate:` expects a callable — `validate: ->(value) { ... }` or " \
                  "`validate: { with: <callable>, message: \"...\" }` — but got a Hash with no `:with` key " \
                  "(keys: #{value.keys.inspect}). If you meant a standard validation such as an " \
                  "allowed-value set, declare it directly (e.g. `inclusion: { in: [...] }`), which constrains " \
                  "the value at that position — #{misuse_remedy(nested)}"
          end

          return value
        end

        { with: value }
      end

      # Where "declare it directly" puts the validator, worded for the position the misuse was written at. In a
      # BAG the position is already the contents, so the validator belongs in that same bag; at a FIELD the
      # position is the container, and a constraint on its contents belongs one rung down in `of:`.
      def self.misuse_remedy(nested)
        if nested
          "in a bag that is the contents, so it belongs in the same bag beside `klass:`."
        else
          "on a container-typed field that is the container itself, not its contents — a constraint on those " \
            "belongs in `of:`."
        end
      end
      private_class_method :misuse_remedy

      # Runtime backstop for a `:with`-less options Hash that bypassed the declaration guard above
      # (e.g. validations assembled directly). Mirrors the guard's guidance.
      def check_validity!
        return unless options[:with].nil?

        raise ArgumentError,
              "`validate:` requires a callable under `:with` (`validate: { with: <callable> }`) or the bare form " \
              "`validate: ->(value) { ... }`. For a standard validation such as an allowed-value set, use the " \
              "validator directly (e.g. `inclusion: { in: [...] }`), which constrains the value at that " \
              "position — on a container-typed field that is the container itself, not its contents."
      end

      def validate_each(record, attribute, value)
        msg = begin
          options[:with].call(value)
        # Catches what axn absorbs, not just StandardError: the fallback message names the real error
        # ("failed validation: stack level too deep"), so failing the field stays both accurate and
        # uniform — a validator that blows the stack takes the same path as one raising ArgumentError.
        rescue StandardError, *Axn::Extensions::SWALLOWABLE_BEYOND_STANDARD_ERROR => e
          # Log the raised error best-effort, then surface it as this field's validation message — a
          # crashing custom validator fails the field rather than silently passing.
          # The subject is named by the validator collector rather than interpolated from the attribute: an
          # unnamed position's attribute is a synthetic axn owns (see Validation::ContainerContents).
          Axn::Extensions.best_effort("applying custom validation on #{record.send(:_validation_subject, attribute)}") { raise e }

          "failed validation: #{Axn::Internal::Rendering.exception_message(e)}"
        end

        record.errors.add(attribute, msg) if msg.present?
      end
    end
  end
end
