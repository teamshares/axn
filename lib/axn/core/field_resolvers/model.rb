# frozen_string_literal: true

module Axn
  module Core
    module FieldResolvers
      class Model
        def initialize(field:, options:, provided_data:)
          @field = field
          @options = options
          @provided_data = provided_data
        end

        def call
          provided_value.presence || derive_value
        end

        private

        attr_reader :field, :options, :provided_data

        def provided_value
          @provided_value ||= _read(field)
        end

        def derive_value
          return nil if id_value.blank?

          # Handle different finder types
          if finder.is_a?(Method)
            # Method object - call it directly
            finder.call(id_value)
          elsif klass.respond_to?(finder)
            # Symbol/string method name on the klass
            klass.public_send(finder, id_value)
          else
            raise "Unknown finder: #{finder}"
          end
        rescue StandardError => e
          # Log the exception but don't re-raise
          finder_name = finder.is_a?(Method) ? finder.name : finder
          Axn::Internal::PipingError.swallow("finding #{field} with #{finder_name}", exception: e)
          nil
        end

        def klass
          @klass ||= options[:klass]
        end

        def finder
          @finder ||= options[:finder]
        end

        def id_field
          @id_field ||= Axn::Internal::FieldConfig.model_id_key(field)
        end

        def id_value
          @id_value ||= _read(id_field)
        end

        # Reads a key through the canonical extraction path (segment-by-segment, key-or-method
        # dispatch, indifferent access) rather than a raw `[]`, so model reads behave identically to
        # every other reader: a dotted key (`items.widget`) digs the nested path, a record parent is
        # read by method, and a source that can't answer the key (e.g. a String where a Hash was
        # declared) reads as ABSENT — its own type validation classifies the malformed value
        # (PRO-2857) rather than a raw error pre-empting the contract.
        def _read(key)
          Axn::Core::FieldResolvers.extract_or_nil(field: key, provided_data:)
        end
      end
    end
  end
end
