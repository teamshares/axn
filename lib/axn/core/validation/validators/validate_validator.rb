# frozen_string_literal: true

require "active_model"

module Axn
  module Validators
    class ValidateValidator < ActiveModel::EachValidator
      def self.apply_syntactic_sugar(value, _fields)
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
                  "allowed-value set, declare it directly (e.g. `inclusion: { in: [...] }`), not under `validate:`."
          end

          return value
        end

        { with: value }
      end

      # Runtime backstop for a `:with`-less options Hash that bypassed the declaration guard above
      # (e.g. validations assembled directly). Mirrors the guard's guidance.
      def check_validity!
        return unless options[:with].nil?

        raise ArgumentError,
              "`validate:` requires a callable under `:with` (`validate: { with: <callable> }`) or the bare form " \
              "`validate: ->(value) { ... }`. For a standard validation such as an allowed-value set, use the " \
              "validator directly (e.g. `inclusion: { in: [...] }`), not `validate:`."
      end

      def validate_each(record, attribute, value)
        msg = begin
          options[:with].call(value)
        rescue StandardError => e
          Axn::Internal::PipingError.swallow("applying custom validation on field '#{attribute}'", exception: e)

          "failed validation: #{e.message}"
        end

        record.errors.add(attribute, msg) if msg.present?
      end
    end
  end
end
