# frozen_string_literal: true

require "active_support/core_ext/hash/indifferent_access"
require "axn/core/validation/base"

module Axn
  module Validation
    # THE one-off validator collector, for every declared config at every level: a top-level field
    # validates against the context facade (which resolves model records and reads by wire key), a
    # subfield against its canonically-resolved parent value. One (field, validations) pair per
    # one-off class; raising/settling is the caller's concern (see Executor#_validate_inbound!).
    class Fields < Base
      def initialize(source)
        super()
        @source = source
      end

      def read_attribute_for_validation(attr)
        # A subfield reads through the action's generated reader when one exists — the reader IS the
        # field's value (memoized, model-resolving, value-level-default-applying, PRO-2889), so
        # validation sees exactly what user code sees. The reader's memo can't be stale here: the
        # executor clears every subfield reader memo at the inbound-pipeline boundary
        # (_clear_pre_pipeline_memos!), so a value cached by an early pre-settlement read is discarded
        # and this read resolves against the settled wire values. A dotted-name subfield has no reader
        # and resolves through the same shared helper. Top-level fields keep reading their source facade.
        if @action && @reader && @action.respond_to?(@reader)
          @action.public_send(@reader)
        elsif @action && @config&.subfield?
          Axn::Core::ContractForSubfields.resolve_value(@action, @config)
        else
          # Two occupants reach here. A top-level/outbound FACADE read: its source is the framework's
          # own context/result facade, whose per-field reader is a safe generated accessor — method
          # dispatch is always permitted (it's not the caller-object dispatch the method_call gate
          # targets), so the facade call site (collect_errors) passes `permit_method_call: true`. A
          # SHAPE MEMBER read (ShapeValidator): its source is a caller-supplied element, so it honors
          # the member's own `method_call:` opt-in — the same gate as a subfield (PRO-2907). The
          # permission is carried explicitly by each call site (NOT inferred from @action presence):
          # threading the action into shape-member validation — e.g. to resolve a Symbol validation
          # arg or if:/unless: condition against the action — must not silently re-permit dispatch.
          # Malformed sources still read as absent (one doctrine — see FieldResolvers.extract_or_nil):
          # this field's own validators report against nil while the source's own type validation
          # classifies the bad value.
          Axn::Core::FieldResolvers.extract_or_nil(field: attr, provided_data: @source, permit_method_call: @permit_method_call)
        end
      end

      # Returns the ActiveModel::Errors for one (field, validations) pair against a source (empty if
      # valid). This is THE facade call site (top-level inbound + outbound): its source is the
      # framework's context/result facade, whose generated reader is safe, so it permits method
      # dispatch unconditionally. (A subfield reaches read_attribute_for_validation via the reader/
      # resolve_value branches, never the dispatch-gated else, so the flag is a no-op for it here.)
      def self.collect_errors(field:, validations:, source:, action: nil, reader: nil, config: nil)
        errors_for(validator_class_for(field:, validations:), source:, validations:, action:, reader:, config:, permit_method_call: true)
      end

      # Builds the one-off validator class for a (field, validations) pair. Callers that validate
      # the same contract repeatedly (e.g. ShapeValidator over array elements) can build this once
      # and reuse it across sources via .errors_for, avoiding per-call class compilation.
      def self.validator_class_for(field:, validations:)
        Class.new(self) do
          def self.name = "Axn::Validation::Fields::OneOff"

          # A field may legitimately carry no validators at all (e.g. `optional: true` with no
          # type/model, or an `optional:` field carrying only ActiveModel shared options like
          # `strict:`), which `validates` rejects with "You need to supply at least one validation" —
          # an empty set means nothing to enforce. Shared options (gates, strict:, …) aren't
          # validators, so they don't count toward the set.
          validates field, **validations unless Axn::Validation::Base.validator_entries(validations).empty?
        end
      end

      # Runs a validator class against a source and returns its ActiveModel::Errors (empty if valid).
      # `permit_method_call:` governs the dispatch gate in the else branch of
      # read_attribute_for_validation: the facade call site (collect_errors) passes `true`; a shape
      # member passes its own `method_call:` opt-in (PRO-2907). It is deliberately independent of
      # `action:` so the two can be threaded separately.
      def self.errors_for(validator_class, source:, validations:, action: nil, reader: nil, config: nil, permit_method_call: false)
        validator = validator_class.new(source)

        # Set the action context for model field resolution + symbol-argument delegation
        validator.instance_variable_set(:@action, action)
        validator.instance_variable_set(:@validations, validations)
        validator.instance_variable_set(:@reader, reader)
        validator.instance_variable_set(:@config, config)
        validator.instance_variable_set(:@permit_method_call, permit_method_call)

        validator.valid?
        validator.errors
      end

      # Whether the gate for ONE validator ENTRY is OPEN for this call — i.e. whether ActiveModel
      # would run that entry's validator this pass. Two gate tiers apply, and AM merges them inside
      # `validates`: the declaration-level SHARED if:/unless: (`validations`'s own gate keys) and the
      # ENTRY's OWN nested if:/unless: (the `if:` inside e.g. a `model: { ..., if: }` or
      # `presence: { if: }` hash). Decided by ActiveModel ITSELF, never by a hand-rolled mirror of its
      # merge/evaluation: we build a probe validator (subclassing this class, so it inherits the exact
      # method_missing delegation to the action the real validators use) carrying a single custom
      # validator whose NESTED options are the entry's own gates and whose SHARED options are the
      # declaration-level gates — the identical `validates :attr, <gated validator>, **shared` shape
      # the real declaration takes. AM applies its real `defaults.merge(per_validator_options)`
      # precedence (measured against activemodel 7.2.2.2: the entry's OWN if:/unless: OVERRIDES the
      # shared one PER KEY; distinct keys AND together) and the identical ActiveSupport callback
      # machinery for the probe and the real validators, so the arity/String/callable resolution AND
      # the tier precedence are AM's, not ours — the gate decision cannot drift. This is THE single
      # gate oracle for the two axn-side checks that live OUTSIDE ActiveModel and must waive themselves
      # exactly when AM would waive the real validator: the executor's model-consistency pass and
      # ShapeValidator's unreadable-member pre-check.
      #
      # Zero-cost short-circuit: no gate key on EITHER tier → true, building nothing. Declaration-level
      # blank gates are canonicalized away at declaration, so a present shared key is always a real
      # gate. A blank NESTED gate needs no special handling — it is passed to the probe verbatim and
      # AM's own check_conditionals treats it as no gate (and, per the measured merge, a blank nested
      # same-key value still overrides/drops the shared gate before being ignored) — the probe reflects
      # that automatically. A non-Hash entry value (`presence: true`) carries no nested gates. A
      # condition that raises propagates exactly as during the real valid?. The receiver context
      # (@action/@reader/@config/@permit_method_call) is threaded onto the probe so a Symbol/Proc
      # condition resolves against the same `self` and action delegation the real validators see.
      def self.validator_gate_open?(validations:, entry_options:, action: nil, source: nil, reader: nil, config: nil, permit_method_call: false)
        gate_keys = Axn::Internal::FieldConfig::CONDITIONAL_GATE_KEYS
        shared_gates = validations.slice(*gate_keys)
        nested_gates = entry_options.is_a?(Hash) ? entry_options.slice(*gate_keys) : {}
        return true if shared_gates.empty? && nested_gates.empty?

        probe = gate_probe_class_for(shared: shared_gates, nested: nested_gates).new(source)
        probe.instance_variable_set(:@action, action)
        probe.instance_variable_set(:@validations, validations)
        probe.instance_variable_set(:@reader, reader)
        probe.instance_variable_set(:@config, config)
        probe.instance_variable_set(:@permit_method_call, permit_method_call)
        probe.valid?
        probe.gate_open?
      end

      # Whether the DECLARATION-level shared gate alone is OPEN — the special case of
      # validator_gate_open? with no per-validator entry in view (nested gates empty). Asks "would ANY
      # validator on this declaration run this pass", the right question when there is no single entry
      # to isolate (e.g. the drift-proof matrix spec, which pins the shared-tier decision directly).
      def self.declaration_gate_open?(validations:, action: nil, source: nil, reader: nil, config: nil, permit_method_call: false)
        validator_gate_open?(validations:, entry_options: nil, action:, source:, reader:, config:, permit_method_call:)
      end

      # The custom validator the gate probe declares: it flips the flag and reads NO attribute (so it
      # never resolves a model, trips the method_call gate, or touches the source), isolating the pure
      # gate decision. A plain ActiveModel::Validator (NOT an EachValidator) so AM invokes `validate`
      # once per record with no per-attribute read. Reachable from the probe subclass via const_get
      # ancestor lookup, exactly like Base's other one-off validator constants.
      class GateFlipValidator < ActiveModel::Validator
        def validate(record) = record.__axn_flip_gate!
      end

      # The probe validator class for a (shared, nested) gate pair, memoized by gate content: a
      # subclass whose sole custom validator (GateFlipValidator) flips a flag iff ActiveModel decides
      # the merged gate is open. Declaring `validates :attr, gate_flip: nested, **shared` is what makes
      # AM the evaluator — it runs its own `defaults.merge(per_validator_options)` tier precedence and
      # the ActiveSupport callback conditionals. Keyed by content, which is stable across calls
      # (Symbols compare by value; the Procs off a frozen FieldConfig hash are the same object each
      # call) — benign duplicate builds under concurrency are harmless (the classes are behaviorally
      # identical). Building raises for a gate AM rejects (e.g. a non-blank String condition) exactly
      # as the real validator build does — loud, matching runtime.
      def self.gate_probe_class_for(shared:, nested:)
        (@gate_probe_classes ||= {})[[shared, nested]] ||= build_gate_probe_class(shared:, nested:)
      end
      private_class_method :gate_probe_class_for

      def self.build_gate_probe_class(shared:, nested:)
        Class.new(self) do
          def self.name = "Axn::Validation::Fields::GateProbe"

          def gate_open? = instance_variable_defined?(:@__axn_gate_open)
          def __axn_flip_gate! = @__axn_gate_open = true

          # AM merges the shared (declaration-level) options into the nested (per-validator) options
          # for the callback conditions, so the flag flips iff the merged gate is open. GateFlipValidator
          # reads no attribute — the flip is the pure gate decision, isolated from any source read.
          validates :__axn_gate_probe, gate_flip: nested, **shared
        end
      end
      private_class_method :build_gate_probe_class

      private

      def _action_for_validation = @action
    end
  end
end
