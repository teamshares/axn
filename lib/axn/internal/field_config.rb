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
    end
  end
end
