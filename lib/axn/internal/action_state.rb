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
      private_constant :RESULT, :INTERNAL_CONTEXT

      module_function

      def result(action) = RESULT.bind_call(action)

      def internal_context(action) = INTERNAL_CONTEXT.bind_call(action)

      # True only for an action INSTANCE. Several callers legitimately hold nil or an action CLASS
      # instead (a guard firing before the instance exists), and `respond_to?(:result)` cannot tell
      # them apart from an instance whose `result` a user has taken — it answers true and then hands
      # back a String.
      def instance?(obj) = Identity.kind?(obj, ::Axn)

      # The result when there is one, nil for every shape that cannot have one — a degraded report
      # naming the exception beats no report at all.
      def result_or_nil(obj) = instance?(obj) ? result(obj) : nil
    end
  end
end
