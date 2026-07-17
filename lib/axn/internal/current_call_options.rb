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
      end
    end
  end
end
