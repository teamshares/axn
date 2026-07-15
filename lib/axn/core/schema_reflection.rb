# frozen_string_literal: true

require "axn/reflection"

module Axn
  module Core
    # Public, transport-free schema export. Speaks input/output (the lingua franca of
    # JSON Schema / OpenAPI / MCP / LLM function calling); the internal builder speaks
    # inbound/outbound. Adapters wrap these Hashes into their transport objects.
    module SchemaReflection
      # `input_schema`/`output_schema` are generic enough that an adapter base class (e.g. ::MCP::Tool)
      # is likely to already define its own, transport-shaped versions. Layer axn's reflection reader on
      # only when the name is free — otherwise `extend` would sit above that base class and silently
      # shadow it (PRO-2875). Each name is guarded independently so a base class that owns only one still
      # gets axn's reflection for the other.
      def self.included(base)
        _extend_reflection(base, :input_schema, InputSchemaMethod)
        _extend_reflection(base, :output_schema, OutputSchemaMethod)
      end

      def self._extend_reflection(base, name, mod)
        if Axn::Core::MethodShadowing.externally_defined?(base, name)
          Axn.config.logger.debug do
            "[Axn] #{base.name || 'Action'}: skipping axn's reflected `#{name}` (already defined by a non-Axn ancestor)"
          end
        else
          base.extend(mod)
        end
      end

      module InputSchemaMethod
        def input_schema
          Axn::Reflection::Schema.build_input(internal_field_configs, subfield_configs, resolved: _resolved_subfields, klass: self).tap do
            _warn_dropped_deep_subfields
          end
        end

        private

        # A deep subfield whose chain passes through a `model:` or non-object parent has no JSON-object
        # representation, so it validates at runtime but is absent from the input schema. Surface that
        # once per class so an adapter author building tooling on the schema isn't misled by a silent gap.
        def _warn_dropped_deep_subfields
          return if @_axn_deep_subfield_warning_emitted

          dropped = _resolved_subfields.dropped
          return if dropped.empty?

          @_axn_deep_subfield_warning_emitted = true
          paths = dropped.map { |c| "#{c.field} (on: #{c.on})" }.join(", ")
          Axn.config.logger.warn(
            "[Axn] #{resolved_axn_name} input_schema omits deep subfield(s) with no JSON representation — " \
            "nested under a model: or non-object parent: #{paths}. They validate at runtime but are absent " \
            "from the reflected input schema; restructure the parent as a Hash/:params field, or handle " \
            "them in the adapter.",
          )
        end
      end

      module OutputSchemaMethod
        def output_schema
          Axn::Reflection::Schema.build_output(external_field_configs)
        end
      end
    end
  end
end
