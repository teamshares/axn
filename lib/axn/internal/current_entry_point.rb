# frozen_string_literal: true

module Axn
  module Internal
    # Ambient "why is this call tree running" stamp. Set by a caller BEFORE opening a call tree —
    # Axn::Tools::Invoker for every registered tool adapter, or a non-tool gem via the public
    # Axn::Extensions::InvokedVia.with — and read by the executor to merge into resolved_input_dimensions
    # as DIMENSION_NAME. Scoped via IsolatedExecutionState, the same pattern as Async::CurrentRetryContext.
    #
    # Deliberately NEVER consumed, unlike Internal::CurrentCallOptions: the whole point is that a nested
    # sub-axn started from inside the wrapped block is stamped identically to its root (subtree
    # semantics), so nothing here clears the holder except `with`'s own `ensure` on the way out.
    module CurrentEntryPoint
      # The dimension name this stamp resolves into. Single-sourced here so Core::Tagging's
      # reserved-name check and the executor's merge point can't drift apart on what name they mean.
      DIMENSION_NAME = :invoked_via

      class << self
        def current = ActiveSupport::IsolatedExecutionState[:_axn_entry_point]

        def current=(value)
          ActiveSupport::IsolatedExecutionState[:_axn_entry_point] = value
        end

        def with(value)
          previous = current
          self.current = value
          yield
        ensure
          self.current = previous
        end
      end
    end
  end
end
