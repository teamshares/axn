# frozen_string_literal: true

module Axn
  module Core
    # Default implementation of the call method that automatically exposes
    # all declared exposures by calling methods with matching names.
    module DefaultCall
      # User-defined action logic - override this method in your action classes
      # Default implementation automatically exposes all declared exposures by calling
      # methods with matching names. Raises if a method is missing and no default is provided.
      def call
        return if self.class.external_field_configs.empty?

        exposures = {}

        self.class.external_field_configs.each do |config|
          field = config.field
          # Check if field is optional (allow_blank or no presence validation)
          is_optional = _field_is_optional?(config)

          # If method exists, call it (user-defined methods override auto-generated ones)
          # The auto-generated method for exposed-only fields returns nil (field not in provided_data)
          next unless respond_to?(field, true)

          value = send(field)
          # If it returns nil and it's an exposed-only field with no default,
          # it's likely the auto-generated method (user methods can also return nil, but
          # we'll assume it's auto-generated in this case)
          is_exposed_only = !self.class.internal_field_configs.map(&:field).include?(field)
          is_not_in_provided = !@__context.provided_data.key?(field)

          # Only expose if we have a value, or if it's nil but there's a default
          # If it's nil and optional, don't expose - let validation handle it
          if value.nil? && is_exposed_only && is_not_in_provided && config.default.nil? && !is_optional
            # This is the auto-generated method returning nil for a required field
            # Don't expose it - let outbound validation catch the missing exposure
          else
            exposures[field] = value unless value.nil? && config.default.nil?
          end
          # If method doesn't exist:
          # - If optional, skip it - validation will handle it
          # - If not optional and no default, skip it - let outbound validation catch it
          # - If there's a default, skip it - the default will be applied later
        end

        expose(**exposures) if exposures.any?
      end

      private

      def _field_is_optional?(config)
        validations = config.validations
        # Field is optional if:
        # 1. It doesn't have presence: true validation (presence is the default for non-optional fields)
        # 2. Any validator has allow_blank: true
        return true unless validations.key?(:presence) && validations[:presence] == true

        # Check if any validator has allow_blank: true
        validations.values.any? { |v| v.is_a?(Hash) && v[:allow_blank] == true }
      end
    end
  end
end
