# frozen_string_literal: true

require "axn/internal/identity"

module Axn
  module Internal
    # How axn's own machinery reads an action's state.
    #
    # `include Axn` puts helpers on the user's class, and a user may take any of those names — with a
    # `def`, or with a field declaration whose generated reader lands on the same class. A name is
    # therefore not a reliable way to reach an implementation: dispatching `action.result` reaches
    # whatever currently answers to `result`, which is how a user's declaration used to corrupt the
    # framework instead of merely costing them a helper.
    #
    # So internals never dispatch. Each implementation is held as an UnboundMethod and `bind_call`ed,
    # naming the method object directly — the same technique, and the same reason, as
    # `Internal::Identity` (for collaborators axn has no cause to trust) and the executor's
    # `FAILURE_PRESENT_AS`. Shadowing then costs the user their own convenience and nothing else.
    module ActionState
      RESULT = Axn::Core::Contract::InstanceMethods.instance_method(:result)
      INTERNAL_CONTEXT = Axn::Core::Contract::InstanceMethods.instance_method(:internal_context)
      INPUTS = Axn::Core::Contract::InstanceMethods.instance_method(:inputs)
      EXPOSE = Axn::Core::Contract::InstanceMethods.instance_method(:expose)
      EXPOSE_FROM_RESULT = Axn::Core::Contract::InstanceMethods.instance_method(:_expose_from_result)
      EXECUTION_CONTEXT = Axn::Core::Contract::InstanceMethods.instance_method(:execution_context)
      SET_EXECUTION_CONTEXT = Axn::Core::Contract::InstanceMethods.instance_method(:set_execution_context)
      INPUTS_FOR_LOGGING = Axn::Core::Contract::InstanceMethods.instance_method(:inputs_for_logging)
      OUTPUTS_FOR_LOGGING = Axn::Core::Contract::InstanceMethods.instance_method(:outputs_for_logging)
      AMBIENT_CONTEXT = Axn::Core::AmbientContext.instance_method(:ambient_context)
      LOG = Axn::Core::Logging::InstanceMethods.instance_method(:log)
      FAIL = Axn::Core.instance_method(:fail!)
      private_constant :RESULT, :INTERNAL_CONTEXT, :INPUTS, :EXPOSE, :EXPOSE_FROM_RESULT, :EXECUTION_CONTEXT,
                       :SET_EXECUTION_CONTEXT, :INPUTS_FOR_LOGGING, :OUTPUTS_FOR_LOGGING, :AMBIENT_CONTEXT,
                       :LOG, :FAIL

      # Marks a stand-in axn builds itself when a report has no action instance to read from — the
      # discarded/dead-job proxy is the only one today. A MODULE rather than a duck-type probe on
      # purpose: axn owns every includer, so a user's field declaration can never claim it, which is
      # exactly what `respond_to?(:result)` could not promise.
      module ReportProxy; end

      module_function

      def result(action) = RESULT.bind_call(action)

      def internal_context(action) = INTERNAL_CONTEXT.bind_call(action)

      def inputs(action) = INPUTS.bind_call(action)

      def expose(action, *, **) = EXPOSE.bind_call(action, *, **)

      def expose_from_result(action, source_result, **) = EXPOSE_FROM_RESULT.bind_call(action, source_result, **)

      def execution_context(action) = EXECUTION_CONTEXT.bind_call(action)

      def set_execution_context(action, **) = SET_EXECUTION_CONTEXT.bind_call(action, **)

      def inputs_for_logging(action) = INPUTS_FOR_LOGGING.bind_call(action)

      def outputs_for_logging(action) = OUTPUTS_FOR_LOGGING.bind_call(action)

      def ambient_context(action) = AMBIENT_CONTEXT.bind_call(action)

      # Settling an action as a failure is CONTROL FLOW, not a convenience: a shadow intercepting it
      # does not cost the user a helper, it makes the failure never happen and the action report the
      # success it did not have. So the internals that settle an action — the step orchestrator's
      # outcome propagation, the form strategy's validity gate — raise through this, never by name.
      def fail!(action, *, **) = FAIL.bind_call(action, *, **)

      # Three shapes reach here and all three are legitimate: an action INSTANCE (bound, so a shadowed
      # `log` cannot intercept), an action CLASS at a guard that fires before the instance exists (its
      # class-level `log` is the right target), and nil at a guard with no action at all. Anything else
      # reaches the configured logger directly rather than being asked whether it answers to a level
      # name — a duck-type probe here would be the very thing this module exists to replace, since an
      # action whose author declared a field named `warn` answers it and returns their input value.
      #
      # The kwargs are forwarded rather than re-declared, so the level/before/after/prefix defaults stay
      # owned by `Logging::ClassMethods#log` and cannot drift out of step with it. Only the last resort
      # names a level itself, because there is no `log` left to apply the default.
      def log(target, message, **kwargs)
        return LOG.bind_call(target, message, **kwargs) if instance?(target)
        return target.log(message, **kwargs) if report_proxy?(target)
        return target.log(message, **kwargs) if Identity.kind?(target, ::Module) && target < ::Axn

        Axn.config.logger.send(kwargs.fetch(:level) { Axn.config.log_level }, message)
      end

      # True only for an action INSTANCE. Several callers legitimately hold nil or an action CLASS
      # instead (a guard firing before the instance exists), and `respond_to?(:result)` cannot tell
      # them apart from an instance whose `result` a user has taken — it answers true and then hands
      # back a String.
      def instance?(obj) = Identity.kind?(obj, ::Axn)

      # True for a proxy axn built in place of an instance. Undispatched, like every other question
      # here: the discarded-job proxy answers `class` with the action's class, so anything that
      # consulted the object would get the wrong answer.
      def report_proxy?(obj) = Identity.kind?(obj, ReportProxy)

      # The result when there is one, nil for every shape that cannot have one — a degraded report
      # naming the exception beats no report at all.
      def result_or_nil(obj)
        return result(obj) if instance?(obj)
        return obj.result if report_proxy?(obj)

        nil
      end
    end
  end
end
