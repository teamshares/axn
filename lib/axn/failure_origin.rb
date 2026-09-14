# frozen_string_literal: true

require "axn/exceptions"
require "axn/internal/action_state"
require "axn/internal/identity"

module Axn
  # Reopens Axn::Failure to add the two readers naming WHICH axn decided a failure.
  #
  # They live apart from the class itself because they need the contract layer and the exception does
  # not. `Internal::ActionState` binds its `result` from `Core::Contract::InstanceMethods`, so loading
  # it loads the contract -- which needs ActiveModel, required well after `axn/exceptions` is. Naming
  # ActionState from the exception's own file therefore cannot be made to work in either direction:
  # requiring it there fails on the contract, and having ActionState require the contract itself fails
  # on ActiveModel. This file is required after both, so it can name everything it uses.
  class Failure
    # The axn that decided this failure, and the result it had built by the time it did.
    #
    # These are what a consumer reads, not `__originating_action`: handing back the action INSTANCE
    # forces an `action.result` dispatch BY NAME, and a user's `expects :result` -- or a plain
    # `def result` -- answers that name instead of the outbound facade, so the consumer silently
    # reads the user's own value and never learns it missed. `ActionState` binds the real method
    # rather than naming it, the same reason axn's own internals never dispatch `result` either.
    #
    # Both are nil when no action decided the failure (`action:` defaults to nil), which is the only
    # answer available for an exception raised outside `fail!`.
    def originating_axn_class
      return nil if Axn::Internal::Identity.nil_value?(@__originating_action)

      Axn::Internal::Identity.class_of(@__originating_action)
    end

    def originating_result
      return nil if Axn::Internal::Identity.nil_value?(@__originating_action)

      Axn::Internal::ActionState.result(@__originating_action)
    end
  end
end
