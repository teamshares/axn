# frozen_string_literal: true

# Every warning below goes through Extensions.best_effort, so this component needs it whether or not
# the umbrella entrypoint loaded it.
require "axn/extensions"
require "axn/internal/native_methods"
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
        _extend_reflection(base, :input_schema_residues, InputSchemaResiduesMethod)
      end

      # One constraint the contract enforces that `input_schema` does not state. `path` is the property
      # keys from the root to the property it qualifies, exactly as the schema spells them (empty for the
      # root); `summary` is the clause that property's `description` also carries; `kind` is `:conditional`
      # (applies only when an `if:`/`unless:` gate opens), `:inherent` (JSON Schema has no faithful keyword
      # for it) or `:unfixed` (axn could state it and does not yet).
      #
      # The schema is exact for its core vocabulary — types, requiredness, nullability, nesting, literal
      # enums and literal bounds — and never stricter than the runtime for everything else. What it leaves
      # out is listed here, so a caller obeying the schema can still be rejected, but never silently.
      Residue = Data.define(:path, :summary, :kind)

      def self._extend_reflection(base, name, mod)
        if Axn::Core::MethodShadowing.externally_defined?(base, name)
          # The breadcrumb is a side channel; whether axn extends `mod` is not. This runs from
          # `included`, so a raising logger would otherwise break `include Axn` at class-definition
          # time over a courtesy notice.
          Axn::Extensions.best_effort("logging a deferred schema reflection reader", action: base) do
            Axn.config.logger.debug do
              "[Axn] #{base.name || 'Action'}: skipping axn's reflected `#{name}` (already defined by a non-Axn ancestor)"
            end
          end
        else
          base.extend(mod)
        end
      end
      private_class_method :_extend_reflection

      # Frozen classes cannot accept memo ivars. Weak keys avoid retaining reloaded actions,
      # and immediate true values survive GC even on Ruby versions with weak WeakMap values.
      FROZEN_RESIDUE_WARNINGS = ObjectSpace::WeakMap.new
      FROZEN_DEEP_WARNINGS = ObjectSpace::WeakMap.new
      private_constant :FROZEN_RESIDUE_WARNINGS, :FROZEN_DEEP_WARNINGS

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
      # memo lives on a mutable class, with a weak-key fallback for a frozen class; both callers
      # reach the same state.
      #
      # Keyed on WHAT was warned, not a boolean. A boolean silenced the class permanently, so an action
      # reopened to add another collision — the ordinary shape of a reload, and of a concern included after
      # the first reflection — got the new residue in its schema and no warning about it ever. Keying on the
      # rendered gaps keeps repeated reads quiet while a genuinely new one still speaks.
      #
      # Only an `:unfixed` residue is warned about. A conditional or inherent one is the schema keeping its
      # promise — it leaves out what it cannot state faithfully — and is ordinary for any action with a gate
      # or a pattern JSON Schema cannot spell; warning on each would teach authors to ignore the channel. They
      # are still in the property's `description` and in `input_schema_residues`.
      def self.warn_inexpressible_constraints(klass, residues)
        residues = residues.select { |_path, residue| residue.kind == :unfixed }
        return if residues.empty?

        # Preparation and bookkeeping are part of the side channel too. Neither a frozen class,
        # a failing name renderer nor a logger failure may replace an already-built schema.
        Axn::Extensions.best_effort("warning about inexpressible input_schema constraints", action: klass) do
          all_gaps = residues.map do |path, residue|
            rendered = path.map { |segment| Axn::Internal::Reflection::PropertyNames.renderable_label(segment) }.join(".")
            "#{rendered}: #{residue.summary}"
          end
          gaps = _unwarned_gaps(klass, all_gaps)
          next if gaps.empty?

          label = axn_name_label(klass)
          Axn.config.logger.warn(
            "[Axn] #{label} input_schema cannot state every constraint the contract enforces — " \
            "#{gaps.join('; ')}. Each is reported in that property's `description`; a caller obeying the " \
            "schema may still be rejected at runtime.",
          )
        end
      end

      def self._unwarned_gaps(klass, all_gaps)
        if Axn::Internal::NativeMethods.frozen?(klass)
          return [] if FROZEN_RESIDUE_WARNINGS.key?(klass)

          FROZEN_RESIDUE_WARNINGS[klass] = true
        end
        warned = Axn::Internal::NativeMethods.ivar_get(klass, :@__axn_residue_warnings) || []
        gaps = all_gaps - warned
        # Record the attempt before logging so a broken logger is not retried on every read.
        Axn::Internal::NativeMethods.ivar_set(klass, :@__axn_residue_warnings, warned + gaps) unless Axn::Internal::NativeMethods.frozen?(klass)
        gaps
      end
      private_class_method :_unwarned_gaps

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

        # A collision constraint the document cannot state: a conditional check, a check on a transformed
        # value or its descendants, or a check with no keyword for the surviving JSON types. The schema
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
          Axn::Extensions.best_effort("warning that input_schema omits deep subfield(s)", action: self) do
            frozen = Axn::Internal::NativeMethods.frozen?(self)
            next if @__axn_deep_subfield_warning_emitted || (frozen && FROZEN_DEEP_WARNINGS.key?(self))

            dropped = _resolved_subfields.dropped
            next if dropped.empty?

            if frozen
              FROZEN_DEEP_WARNINGS[self] = true
            else
              @__axn_deep_subfield_warning_emitted = true
            end
            paths = dropped.map { |c| "#{_schema_name_label(c.field)} (on: #{_schema_name_label(c.on)})" }.join(", ")
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

      # Guarded separately from `input_schema`: an adapter base that owns `input_schema` still leaves this
      # name free, and it is exactly those classes whose adapter most needs to know what the schema omits.
      # Built through `PropertyNames.validate_inbound!`, the same build the reader performs, for the same
      # reason setup uses it — the class's own `input_schema` may not be axn's.
      module InputSchemaResiduesMethod
        def input_schema_residues
          Axn::Internal::Reflection::PropertyNames.validate_inbound!(self).map do |path, residue|
            Residue.new(path: path.freeze, summary: residue.summary, kind: residue.kind)
          end.freeze
        end
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
