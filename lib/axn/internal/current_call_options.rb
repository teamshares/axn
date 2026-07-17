# frozen_string_literal: true

module Axn
  module Internal
    # Per-call tuning gates set by a caller (today only Axn::Tools::Invoker) and read once by the
    # executor. Scoped via IsolatedExecutionState (same pattern as Async::CurrentRetryContext) so
    # nothing rides on `.call`'s kwargs. The executor `consume`s (reads + clears) at the top of its
    # contract phase, so the gates apply to exactly the wrapped action and a nested `.call` in its
    # body sees a cleared holder and runs with default semantics.
    module CurrentCallOptions
      Options = Data.define(:coerce_input_types, :user_facing_input_errors, :reject_undeclared_inputs)

      class << self
        def current = ActiveSupport::IsolatedExecutionState[:_axn_call_options]

        def current=(value)
          ActiveSupport::IsolatedExecutionState[:_axn_call_options] = value
        end

        def with(coerce_input_types: nil, user_facing_input_errors: false, reject_undeclared_inputs: false)
          previous = current
          self.current = Options.new(coerce_input_types:, user_facing_input_errors:, reject_undeclared_inputs:)
          yield
        ensure
          self.current = previous
        end

        # Read the current options and clear the holder, so the reading action takes sole ownership
        # and nested sub-actions do not inherit the gates.
        def consume = current.tap { self.current = nil }

        # The Options in force for `action`'s current call, or nil for a normal call. The executor
        # stashes the consumed Options on the action at the top of its contract phase (per-call state
        # lives on the action instance), so the read-path coercion can reach the same gate the
        # executor's validation-message path reads.
        def for_action(action)
          return nil unless action.instance_variable_defined?(:@__call_options)

          action.instance_variable_get(:@__call_options)
        end

        # The effective coerce_input_types for `action`'s current call: a non-nil per-call gate wins,
        # else the class/global setting — so a normal call resolves exactly as before. Single-sourced
        # so the executor's validation-message path and the read-path value coercion
        # (ContractForSubfields) decide identically.
        def coerce_input_types_for(action)
          per_call = for_action(action)&.coerce_input_types
          per_call.nil? ? Axn::Configuration.resolve_override_for(action.class, :coerce_input_types) : per_call
        end
      end
    end
  end
end
