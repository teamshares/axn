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
      private_class_method :_extend_reflection

      module InputSchemaMethod
        # The property-name rules run here rather than at declaration: a projection is the only thing a
        # colliding or unrenderable name can harm, and this is where one is first demanded. Validated once per
        # class, over the schema being returned rather than a second build of it.
        def input_schema
          Axn::Reflection::PropertyNames.validated_input(self) { Axn::Reflection::Schema.build_input_for(self) }
                                        .tap { _warn_dropped_deep_subfields }
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
          # Names are rendered as the JSON property they canonicalize to, never interpolated raw: a declared
          # name may hold bytes that are not UTF-8 (a valid ISO-8859-1 Symbol), and joining those into this
          # UTF-8 message raised Encoding::CompatibilityError from the warning itself — so reflecting a schema
          # blew up over a subfield the warning exists to mention in passing.
          paths = dropped.map { |c| "#{_schema_name_label(c.field)} (on: #{_schema_name_label(c.on)})" }.join(", ")
          Axn.config.logger.warn(
            "[Axn] #{resolved_axn_name} input_schema omits deep subfield(s) with no JSON representation — " \
            "nested under a model: or non-object parent: #{paths}. They validate at runtime but are absent " \
            "from the reflected input schema; restructure the parent as a Hash/:params field, or handle " \
            "them in the adapter.",
          )
        end

        # The UTF-8 property a declared name renders as, falling back to the escaped `inspect` when its bytes
        # have no UTF-8 rendering at all. Same rule the declaration errors use, for the same reason.
        def _schema_name_label(name) = Axn::Reflection::PropertyNames.renderable_label(name)
      end

      module OutputSchemaMethod
        # See input_schema: validated once per class, over the schema being returned.
        def output_schema
          Axn::Reflection::PropertyNames.validated_output(self) { Axn::Reflection::Schema.build_output(external_field_configs) }
        end
      end
    end
  end
end
