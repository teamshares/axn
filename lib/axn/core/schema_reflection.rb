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
          Axn::Reflection::Schema.build_input(internal_field_configs, subfield_configs).tap do
            _warn_dropped_deep_subfields
          end
        end

        def output_schema
          Axn::Reflection::Schema.build_output(external_field_configs)
        end

        private

        # Deep subfields (a dotted `on:` path, a subfield-of-a-subfield, or a dotted field name) validate
        # at runtime but are absent from the input schema (PRO-2872). Surface that once per class so an
        # adapter author building tooling on the schema isn't misled by a silent gap.
        def _warn_dropped_deep_subfields
          return if @_axn_deep_subfield_warning_emitted

          dropped = Axn::Reflection::Schema.dropped_deep_subfields(internal_field_configs, subfield_configs)
          return if dropped.empty?

          @_axn_deep_subfield_warning_emitted = true
          paths = dropped.map { |c| "#{c.field} (on: #{c.on})" }.join(", ")
          Axn.config.logger.warn(
            "[Axn] #{resolved_axn_name} input_schema omits deep subfield(s) not representable at a single " \
            "nesting level: #{paths}. They validate at runtime but are absent from the reflected input " \
            "schema; flatten them to single-level subfields, or handle them in the adapter (PRO-2872).",
          )
        end
      end
    end
  end
end
