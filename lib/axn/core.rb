# frozen_string_literal: true

require "axn/core/context"

require "axn/strategies"
require "axn/extras"
require "axn/core/hooks"
require "axn/core/method_shadowing"
require "axn/core/instance_deferral"
require "axn/core/naming"
require "axn/core/tool_declaration"
require "axn/core/logging"
require "axn/core/flow"
require "axn/core/automatic_logging"
require "axn/core/tagging"
require "axn/core/use_strategy"
require "axn/core/nesting_tracking"
require "axn/core/memoization"
require "axn/core/extension_metadata"
require "axn/core/semantic_hints"
require "axn/core/versioning"
require "axn/core/schema_reflection"

# CONSIDER: make class names match file paths?
require "axn/core/validation/validators/model_validator"
require "axn/core/validation/validators/type_validator"
require "axn/core/validation/validators/validate_validator"
require "axn/core/validation/validators/of_validator"
require "axn/core/validation/validators/shape_validator"
require "axn/core/validation/validators/non_emptiness_validator"
require "axn/core/validation/validators/whole_value_clusivity"
require "axn/core/validation/validators/inclusion_validator"
require "axn/core/validation/validators/exclusion_validator"

require "axn/core/field_resolvers"
require "axn/core/ambient_context"
require "axn/core/contract"
require "axn/core/contract_for_subfields"
require "axn/core/default_call"

module Axn
  module Core
    module ClassMethods
      def call(**)
        Core::InstanceDeferral.assert_dispatchable_names_free!(self)
        Core::InstanceDeferral.announce_deferrals!(self)
        Axn::Internal::ActionState.result(new(**).tap(&:_run))
      end

      def call!(**)
        Axn::Internal::TransparentBubbling.bubble!(call(**))
      end
    end

    def self.included(base)
      base.class_eval do
        extend ClassMethods

        # `prefer_inherited` / `prefer_axn`: the class body's say in which implementation is live for a name
        # both axn and the class's own hierarchy define (see Core::InstanceDeferral).
        extend Core::InstanceDeferral::ClassMethods

        # DSL modules that add class methods/attributes users interact with
        include Core::Hooks
        include Core::Naming
        include Core::ToolDeclaration
        include Core::Logging
        include Core::AutomaticLogging
        include Core::Tagging
        include Core::Flow
        include Core::AmbientContext
        include Core::Contract
        include Core::ContractForSubfields
        include Core::UseStrategy
        include Core::Memoization
        include Core::DefaultCall
        include Core::ExtensionMetadata
        include Core::SemanticHints
        include Core::Versioning
        include Core::SchemaReflection

        # Per-class config overrides: gives the action class-level accessors
        # (`<name>` setter/reader, `<name>?`, `<name>_override`) for every
        # `overridable: true` setting on Axn.config. See Axn::Configurable.
        include Axn::Configuration.overrides

        # Internal: tracks nesting depth for logging and duplicate-log suppression
        include Core::NestingTracking

        # Actions are run via the sanctioned entry points (.call / .call!), which build
        # the instance internally. Block direct instantiation so callers can't bypass
        # hooks, validation, and the other guarantees those entry points provide.
        private_class_method :new
      end
    end

    # Main entry point for action execution
    def _run
      Axn::Core::Executor.new(self).run
    end

    def fail!(message = nil, standalone: false, **exposures)
      Axn::Internal::ActionState.expose(self, **exposures) if exposures.any?
      raise Axn::Failure.new(message, standalone:, action: self)
    end

    def done!(message = nil, standalone: false, **exposures)
      Axn::Internal::ActionState.expose(self, **exposures) if exposures.any?
      raise Axn::Internal::EarlyCompletion.new(message, standalone:)
    end

    # Delegate to a sub-action, propagating both its exposures and its outcome. Sugar for the facade
    # idiom (`r = Child.call(**inputs); expose(r); raise r.exception unless r.ok?`), and the only way
    # to get that behaviour from the `call!` shape, where the raise leaves #call before any expose can
    # run.
    #
    # Non-terminal: on success it returns the sub-action's result and execution continues, exactly as
    # call! does. The bang marks the failure branch, which settles this action — through call!'s own
    # tail, so the outcome, the error string and the exception object are the ones the `call!` this
    # replaces would have produced. Exposure absorption tolerates an empty intersection
    # (`require_overlap: false`) rather than raising, so a side-effect-only child, or a child whose
    # exposures this action declines to re-declare, still forwards cleanly — forwarding here is a side
    # effect of running the sub-action, not the point of the call the way a direct `expose(result)` is.
    #
    # A Class is invoked with this action's resolved `inputs` — declared inbound fields only, not the
    # step chain's fuller passthrough. Pass a Result instead to control the arguments yourself.
    def forward!(target)
      result = target.is_a?(Class) ? _forward_to_class(target) : target

      raise ArgumentError, "forward!: expected an Axn class or an Axn::Result (got #{result.class})" unless Internal::Identity.kind?(result, Axn::Result)

      Internal::ActionState.expose_from_result(self, result, require_overlap: false)

      Internal::TransparentBubbling.bubble!(result)
    end

    private

    # Settle this action according to a step's outcome — the step orchestrator's helper, and only its.
    # Propagates the outcome *category*, not a flattened failure: a deliberate fail! (or a
    # fails_on-classified exception) settles this action as a failure with the resolved message,
    # prefixed by the step's own `error_prefix` (deliberate aggregation — the parent's error names
    # which step failed); an unclassified exception (a bug) re-raises the original object so this
    # action settles as an exception too. The global report already fired at the step and is deduped
    # per exception object, so re-raising never double-reports.
    #
    # Transparent bubbling — `call!` and `forward!` — uses Internal::TransparentBubbling instead, which
    # re-raises on every non-ok outcome and records a CarriedPresentation. Neither belongs here:
    # aggregation is the opposite of transparent, and a carried presentation on this plain-`.call`
    # path would leak into the parent (see TransparentBubbling).
    def _propagate_sub_result_outcome!(result, error_prefix: nil)
      return if result.ok?

      raise result.exception if result.outcome.exception?

      Internal::ActionState.fail!(self, "#{error_prefix}#{result.error}")
    end

    # Mirrors the `steps` DSL's membership check, one phase later: `step` can validate at declaration
    # because its target is fixed, while forward!'s target is chosen at run time — which is the point
    # of the affordance.
    def _forward_to_class(klass)
      raise ArgumentError, "forward!: #{klass} must include Axn" unless klass.included_modules.include?(::Axn) || klass < ::Axn

      klass.call(**Internal::ActionState.inputs(self))
    end

    def initialize(**)
      @__context = Axn::Core::Context.new(**)
    end

    # The keyword names `fail!`/`done!` bind BEFORE their `**exposures` splat. An action exposing one
    # of these cannot set it through either call — `fail!("boom", standalone: value)` binds the control
    # and the exposure silently stays nil — so `exposes` refuses the name (see
    # Contract::ClassMethods#_reject_shadowed_exposure_name!). Read off the signatures rather than
    # listed, so a control added to either later is covered without editing anything.
    SETTLEMENT_CONTROL_KWARGS = %i[fail! done!].flat_map do |name|
      instance_method(name).parameters.filter_map { |type, param| param if %i[key keyreq].include?(type) }
    end.uniq.freeze
  end
end
