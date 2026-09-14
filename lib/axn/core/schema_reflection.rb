# frozen_string_literal: true

# Both warnings below go through Extensions.best_effort, so this component needs it whether or not the
# umbrella entrypoint loaded it.
require "axn/extensions"
require "axn/internal/reflection"
require "axn/internal/rendering"

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

      # An action's name rendered for a message axn is building: its BYTES through the same encoding seam the
      # path segments take, with nothing of the name's own dispatched. Both halves matter and each was a
      # separate failure. A valid non-UTF-8 `axn_name` (an ISO-8859-1 String holding é) interpolated into
      # this UTF-8 message raised Encoding::CompatibilityError before the logger was reached, so reflecting a
      # schema blew up over the name of the very action whose gap the warning exists to mention. And a name
      # is caller-supplied text, which the reporting path may no more RUN than it may run a description:
      # `resolved_axn_name` is a String by construction (`axn_name` refuses anything else at declaration,
      # `Module#name` answers a String or nil, and the fallback is a literal), and `value_rendering` reads a
      # String through bound methods — so a String SUBCLASS whose `to_s` raises still renders as its text
      # rather than replacing the schema with the caller's exception. The class name is the fallback for an
      # override answering something that is not a String at all.
      def self.axn_name_label(klass)
        name = klass.resolved_axn_name
        Axn::Internal::Rendering.value_rendering(name) || Axn::Internal::Rendering.class_name(name)
      end

      # Report the constraints an inbound projection could not state. Module-level because it has TWO
      # callers and one message: the reader below, and `Axn::Tools.validate_contracts!`, which builds a
      # tool's projection through `PropertyNames` precisely BECAUSE the reader may not be axn's — an
      # adapter base owning `input_schema` means `InputSchemaMethod` was never installed, so a warning
      # living only there reaches nobody for exactly the classes most likely to be read by a model.
      #
      # Path segments arrive RAW — the emitter may not dispatch on a caller-supplied name — so they are
      # rendered here through PropertyNames' own escaping labeler, the same rule the declaration errors
      # use: a declared name may hold bytes with no UTF-8 rendering, and interpolating those raw once
      # raised `Encoding::CompatibilityError` from inside the warning itself.
      #
      # Deduplicated ONCE PER CLASS here rather than at either call site: `validate_contracts!` runs from an
      # engine's `after_initialize` AND every `to_prepare`, and an adapter may later reach the reader too,
      # so a guard held by one caller lets the other repeat the same warning on every boot and reload. The
      # memo lives on the class, which is what both callers share.
      #
      # Keyed on WHAT was warned, not a boolean. A boolean silenced the class permanently, so an action
      # reopened to add another collision — the ordinary shape of a reload, and of a concern included after
      # the first reflection — got the new residue in its schema and no warning about it ever. Keying on the
      # rendered gaps keeps repeated reads quiet while a genuinely new one still speaks.
      def self.warn_inexpressible_constraints(klass, residues)
        return if residues.empty?

        label = axn_name_label(klass)
        all_gaps = residues.map do |path, residue|
          rendered = path.map { |segment| Axn::Internal::Reflection::PropertyNames.renderable_label(segment) }.join(".")
          "#{rendered}: #{residue.summary}"
        end
        warned = klass.instance_variable_get(:@_axn_residue_warnings) || []
        gaps = all_gaps - warned
        return if gaps.empty?

        klass.instance_variable_set(:@_axn_residue_warnings, warned + gaps)
        # A diagnostic may not decide whether reflection SUCCEEDS. A configured logger that raises — a closed
        # stream, a backend that is gone — otherwise propagates out of `input_schema` and out of
        # `Axn::Tools.validate_contracts!`, failing a projection that was built correctly, over the reporting
        # of a gap rather than the gap itself. The memo above is deliberately set BEFORE this: the attempt is
        # what it records, so a broken logger cannot turn one warning into one per reflection.
        Axn::Extensions.best_effort("warning that #{label} input_schema cannot state every constraint", action: klass) do
          Axn.config.logger.warn(
            "[Axn] #{label} input_schema cannot state every constraint the contract enforces — " \
            "#{gaps.join('; ')}. Each is reported in that property's `description`; a caller obeying the " \
            "schema may still be rejected at runtime.",
          )
        end
      end

      module InputSchemaMethod
        # The property-name rules run here rather than at declaration: a projection is the only thing a
        # colliding or unrenderable name can harm, and this is where one is first demanded. Validated once per
        # class, over the schema being returned rather than a second build of it.
        def input_schema
          residues = []
          Axn::Internal::Reflection::PropertyNames.validated_input(self) { Axn::Internal::Reflection::Schema.build_input_for(self, residues:) }
                                                  .tap { _warn_dropped_deep_subfields }
                                                  .tap { _warn_inexpressible_constraints(residues) }
        end

        private

        # A constraint the runtime enforces that this document cannot state — a position whose value is
        # transformed before its own checks run, or one whose declared type JSON has no form for. The schema
        # itself says so in the relevant `description` (which is what an adapter passes on to its caller);
        # this is the same gap said once, to the author, for the same reason the deep-subfield warning
        # above exists: a silent narrowing of the document is what PRO-3405 set out to stop.
        def _warn_inexpressible_constraints(residues)
          SchemaReflection.warn_inexpressible_constraints(self, residues)
        end

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
          # Guarded for the same reason its sibling above is, and at the same time: these two are the only
          # log lines `input_schema` emits, so a raising logger reaching either one is the same failure.
          Axn::Extensions.best_effort("warning that input_schema omits deep subfield(s)", action: self) do
            Axn.config.logger.warn(
              "[Axn] #{SchemaReflection.axn_name_label(self)} input_schema omits deep subfield(s) with no JSON representation — " \
              "nested under a model: or non-object parent: #{paths}. They validate at runtime but are absent " \
              "from the reflected input schema; restructure the parent as a Hash/:params field, or handle " \
              "them in the adapter.",
            )
          end
        end

        # The UTF-8 property a declared name renders as, falling back to the escaped `inspect` when its bytes
        # have no UTF-8 rendering at all. Same rule the declaration errors use, for the same reason.
        def _schema_name_label(name) = Axn::Internal::Reflection::PropertyNames.renderable_label(name)
      end

      module OutputSchemaMethod
        # See input_schema: validated once per class, over the schema being returned.
        def output_schema
          Axn::Internal::Reflection::PropertyNames.validated_output(self) { Axn::Internal::Reflection::Schema.build_output(external_field_configs) }
        end
      end
    end
  end
end
