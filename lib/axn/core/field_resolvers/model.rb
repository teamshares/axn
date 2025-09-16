# frozen_string_literal: true

module Axn
  module Core
    module FieldResolvers
      class Model
        class << self
          def resolve(field:, options:, provided_data:)
            klass = options.is_a?(Hash) ? options[:with] : options

            # Check if we have the object directly
            provided_value = provided_data[field]
            return provided_value if provided_value.present?

            find_by_id(klass:, field:, provided_data:)
          end

          private

          def find_by_id(klass:, field:, provided_data:)
            return nil unless klass.respond_to?(:find_by)

            id_field = :"#{field}_id"
            id_value = provided_data[id_field]
            return nil if id_value.blank?

            klass.find_by(id: id_value)
          end
        end
      end
    end
  end
end
