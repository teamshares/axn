# frozen_string_literal: true

module Axn
  module Internal
    # Per-call-tree record of each failure's resolved presentation string, so an ancestor `call!`
    # that re-raises the SAME exception object can prefix its own base onto the child's already-
    # resolved message (header aggregation). Mirrors ExceptionClassification: scoped via
    # IsolatedExecutionState, identity-keyed (compare_by_identity), and cleared when the nesting
    # stack empties (see NestingTracking) so a later independent run starts fresh.
    module CarriedPresentation
      class << self
        def get(exception) = _store[exception]
        def set(exception, string) = (_store[exception] = string)

        def reset!
          ActiveSupport::IsolatedExecutionState[:_axn_carried_presentation] = nil
        end

        private

        def _store
          ActiveSupport::IsolatedExecutionState[:_axn_carried_presentation] ||= {}.compare_by_identity
        end
      end
    end
  end
end
