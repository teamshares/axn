# frozen_string_literal: true

module Axn
  module Internal
    # Pure utility functions for inspecting field configuration objects.
    module FieldConfig
      module_function

      # Determines if a field is optional based on its validations.
      # A field is optional if:
      # 1. It doesn't have presence: true validation
      # 2. Any validator has allow_blank: true
      #
      # @param config [Object] A field configuration object with a `validations` method
      # @return [Boolean] true if the field is optional
      def optional?(config)
        validations = config.validations
        return true unless validations.key?(:presence) && validations[:presence] == true

        # Check if any validator has allow_blank: true
        validations.values.any? { |v| v.is_a?(Hash) && v[:allow_blank] == true }
      end

      # Determines if a field is declared as boolean type.
      #
      # @param config [Object] A field configuration object with a `validations` method
      # @return [Boolean] true if the field is typed :boolean
      def boolean?(config)
        Array(config.validations.dig(:type, :klass)) == [:boolean]
      end

      # The generated `<field>_id` key for a `model:` field — the lookup-token reader Axn derives from
      # the model field's name. Single source of the `_id` suffix convention (the model resolver, the
      # `<field>_id` reader, sensitive-key/ambient filtering, and schema reflection all key off it).
      #
      # @param field [Symbol, String] the model field's name (or its `as:` reader)
      # @return [Symbol] the `<field>_id` key
      def model_id_key(field)
        :"#{field}_id"
      end

      # Runtime materializes a SUBFIELD's default only when it is truthy — Executor#apply_defaults_for_
      # subfields! does `next unless config.default`, so a falsey subfield default (`false`/`nil`) is never
      # applied. Schema reflection keys off the same rule (a falsey subfield default neither relaxes
      # requiredness nor is emitted). Top-level defaults apply by key-presence and are out of scope here.
      #
      # @param config [Object] a subfield configuration object with a `default`
      # @return [Boolean] whether the subfield's default would be applied at runtime
      def subfield_default_applies?(config)
        !!config.default
      end
    end
  end
end
