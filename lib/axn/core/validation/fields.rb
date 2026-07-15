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
          # type/model), which `validates` rejects — an empty set means nothing to enforce. Gate
          # keys (if:/unless:) don't count toward the set: with every validator gated away there
          # is nothing to conditionally run either.
          validates field, **validations unless validations.except(*Axn::Internal::FieldConfig::CONDITIONAL_GATE_KEYS).empty?
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

      # Whether a declaration-level if:/unless: gate is OPEN for this call — i.e. whether
      # ActiveModel would run the declaration's validators this pass. Decided by ActiveModel
      # ITSELF, never by a hand-rolled mirror of its condition resolution: we build a probe
      # validator (subclassing this class, so it inherits the exact method_missing delegation to the
      # action the real validators use) carrying a single custom validator gated by the config's own
      # if:/unless: options, run `valid?`, and report whether that validator fired. AM applies the
      # shared if:/unless: options through the identical ActiveSupport callback machinery for the
      # probe and for the real validators, so the arity/String/callable resolution rules are AM's,
      # not ours — the gate decision cannot drift from what the real validators experience. This is
      # THE single gate oracle for the two axn-side checks that live OUTSIDE ActiveModel and must
      # waive themselves when a closed gate has already waived the real validators: the executor's
      # model-consistency pass and ShapeValidator's unreadable-member pre-check.
      #
      # An ungated declaration (no if:/unless: key) short-circuits to true and builds nothing —
      # blank gates are canonicalized away at declaration, so a present key is always a real gate
      # (and even were a blank value to reach here, AM's own check_conditionals treats it as no
      # gate, opening it). A condition that raises propagates exactly as it would during the real
      # valid?. The receiver context (@action/@reader/@config/@permit_method_call) is threaded onto
      # the probe so a Symbol/Proc condition resolves against the same `self` and action delegation
      # the real validators see.
      def self.declaration_gate_open?(validations:, action: nil, source: nil, reader: nil, config: nil, permit_method_call: false)
        gate_keys = Axn::Internal::FieldConfig::CONDITIONAL_GATE_KEYS
        return true unless gate_keys.any? { |key| validations.key?(key) }

        probe = gate_probe_class_for(validations.slice(*gate_keys)).new(source)
        probe.instance_variable_set(:@action, action)
        probe.instance_variable_set(:@validations, validations)
        probe.instance_variable_set(:@reader, reader)
        probe.instance_variable_set(:@config, config)
        probe.instance_variable_set(:@permit_method_call, permit_method_call)
        probe.valid?
        probe.gate_open?
      end

      # The probe validator class for a set of gate options (`{ if:, unless: }`), memoized by gate
      # content: a subclass whose sole custom validator flips a flag iff ActiveModel decides the
      # if:/unless: gate is open. Reusing the gate options verbatim on a real `validate` call is what
      # makes AM the evaluator. Keyed by content, which is stable across calls (Symbols compare by
      # value; the Procs off a frozen FieldConfig hash are the same object each call) — benign
      # duplicate builds under concurrency are harmless (the classes are behaviorally identical).
      # Building raises for a gate AM rejects (e.g. a non-blank String condition) exactly as the real
      # validator build does — loud, matching runtime.
      def self.gate_probe_class_for(gates)
        (@gate_probe_classes ||= {})[gates] ||= build_gate_probe_class(gates)
      end
      private_class_method :gate_probe_class_for

      def self.build_gate_probe_class(gates)
        Class.new(self) do
          def self.name = "Axn::Validation::Fields::GateProbe"

          def gate_open? = instance_variable_defined?(:@__axn_gate_open)
          def __axn_flip_gate! = @__axn_gate_open = true

          # The probe's ONLY validator flips the flag; it reads no attribute (so it never resolves a
          # model, trips the method_call gate, or touches the source), isolating the pure gate
          # decision. AM evaluates the shared if:/unless: options against this validator before
          # invoking it — the flag flips iff the gate is open.
          validate :__axn_flip_gate!, **gates
        end
      end
      private_class_method :build_gate_probe_class

      private

      def _action_for_validation = @action
    end
  end
end
