# frozen_string_literal: true

# NOTE: do NOT require "active_support/core_ext/object/json" here. Doing so makes EVERY object
# respond_to?(:as_json), which would short-circuit the to_h/to_s fallbacks below and change
# serialization behavior versus the axn-mcp original. Rely on objects that define as_json themselves
# (ActiveRecord models, etc.), exactly as the original did.

module Axn
  module Reflection
    module Values
      module_function

      # Result → JSON-safe Hash keyed by wire key (string), over declared outbound configs.
      def serialize_exposed(result, field_configs)
        field_configs.each_with_object({}) do |config, hash|
          hash[config.field.to_s] = serialize_value(result.public_send(config.field))
        end
      end

      def serialize_value(value)
        case value
        when nil, String, Integer, Float, TrueClass, FalseClass
          value
        when Hash
          value.transform_keys(&:to_s).transform_values { |v| serialize_value(v) }
        when Array
          value.map { |v| serialize_value(v) }
        else
          if value.respond_to?(:as_json)
            value.as_json
          elsif value.respond_to?(:to_h)
            serialize_value(value.to_h)
          else
            value.to_s
          end
        end
      end
    end
  end
end
