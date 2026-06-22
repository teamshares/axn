# frozen_string_literal: true

module Axn
  module Internal
    # Per-execution (per call-tree) record of how exceptions were handled, so a nested `call!` that
    # re-raises the SAME exception object up the stack doesn't (a) report it more than once, or
    # (b) lose a `fails_on` classification an inner action made.
    #
    # Scoped via IsolatedExecutionState and cleared when the nesting stack empties (see
    # NestingTracking) — so the same exception object re-raised by a LATER, independent run is
    # treated fresh, never silently suppressed. Keyed on object_id; the object is alive for the
    # whole tree, so ids are stable and collision-free within a run.
    module ExceptionClassification
      class << self
        # Global report de-duplication: report once per exception per call tree.
        def reported?(exception) = _reported.include?(exception.object_id)
        def mark_reported!(exception) = _reported.add(exception.object_id)

        # `fails_on` stickiness: a classified failure stays a failure (no report, failure outcome) as
        # it bubbles up — mirroring how Axn::Failure is sticky via its class.
        def failure?(exception) = !exception.nil? && _failures.include?(exception.object_id)
        def mark_failure!(exception) = _failures.add(exception.object_id)

        # Called by NestingTracking when the outermost action finishes.
        def reset!
          ActiveSupport::IsolatedExecutionState[:_axn_reported_exceptions] = nil
          ActiveSupport::IsolatedExecutionState[:_axn_failure_exceptions] = nil
        end

        private

        def _reported = (ActiveSupport::IsolatedExecutionState[:_axn_reported_exceptions] ||= Set.new)
        def _failures = (ActiveSupport::IsolatedExecutionState[:_axn_failure_exceptions] ||= Set.new)
      end
    end
  end
end
