# frozen_string_literal: true

require "axn/reflection"

module Axn
  module Core
    # Public, transport-free schema export. Speaks input/output (the lingua franca of
    # JSON Schema / OpenAPI / MCP / LLM function calling); the internal builder speaks
    # inbound/outbound. Adapters wrap these Hashes into their transport objects.
    module SchemaReflection
      def self.included(base)
        base.extend ClassMethods
      end

      module ClassMethods
        def input_schema
          Axn::Reflection::Schema.build_input(internal_field_configs, subfield_configs)
        end

        def output_schema
          Axn::Reflection::Schema.build_output(external_field_configs)
        end
      end
    end
  end
end
