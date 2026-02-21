# frozen_string_literal: true

module Axn
  module Internal
    # Utilities for serializing/deserializing objects with GlobalID support.
    # Used by async adapters to convert ActiveRecord objects to GlobalID strings
    # for job serialization, and back to objects when the job runs.
    module GlobalIdSerialization
      GLOBAL_ID_SUFFIX = "_as_global_id"

      class << self
        # Serialize a hash for background job processing:
        # - Convert GlobalID-able objects (e.g., ActiveRecord models) to GlobalID strings
        # - Stringify keys for JSON compatibility
        #
        # @param params [Hash] The parameters to serialize
        # @return [Hash] Serialized hash with string keys and GlobalID strings
        def serialize(params)
          return {} if params.nil? || params.empty?

          params.each_with_object({}) do |(key, value), hash|
            string_key = key.to_s
            if value.respond_to?(:to_global_id)
              hash["#{string_key}#{GLOBAL_ID_SUFFIX}"] = value.to_global_id.to_s
            else
              hash[string_key] = value
            end
          end
        end

        # Deserialize a hash from background job processing:
        # - Convert GlobalID strings back to objects
        # - Symbolize keys for use with kwargs
        #
        # @param params [Hash] The serialized parameters
        # @return [Hash] Deserialized hash with symbol keys and resolved objects
        def deserialize(params)
          return {} if params.nil? || params.empty?

          params.each_with_object({}) do |(key, value), hash|
            if key.end_with?(GLOBAL_ID_SUFFIX)
              original_key = key.delete_suffix(GLOBAL_ID_SUFFIX).to_sym
              hash[original_key] = GlobalID::Locator.locate(value)
            else
              hash[key.to_sym] = value
            end
          end
        end
      end
    end
  end
end
