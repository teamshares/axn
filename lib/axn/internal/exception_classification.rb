# frozen_string_literal: true

module Axn
  module Internal
    # Per-execution (per call-tree) record of how exceptions were handled, so a nested `call!` that
    # re-raises the SAME exception object up the stack doesn't (a) report it more than once, or
    # (b) lose a `fails_on` classification an inner action made.
    #
    # Scoped via IsolatedExecutionState and cleared when the nesting stack empties (see
    # NestingTracking) — so the same exception object re-raised by a LATER, independent run is
    # treated fresh, never silently suppressed.
    #
    # The sets key on the exception OBJECT (identity), not its object_id: holding the object keeps it
    # reachable for the call tree's lifetime, so there is no freed-then-reused object_id to collide.
    # `compare_by_identity` also makes this immune to exceptions that override ==/eql?/hash. Bounded
    # by the number of exceptions actually raised in one tree, and dropped wholesale on `reset!`.
    module ExceptionClassification
      class << self
        # Global report de-duplication: report once per exception per call tree.
        def reported?(exception) = _reported.include?(exception)
        def mark_reported!(exception) = _reported.add(exception)

        # `fails_on` stickiness: a classified failure stays a failure (no report, failure outcome) as
        # it bubbles up — mirroring how Axn::Failure is sticky via its class.
        def failure?(exception) = _failures.include?(exception)
        def mark_failure!(exception) = _failures.add(exception)

        # The reporting payload — `[action, context]` — captured the FIRST time an exception is about
        # to be reported, i.e. at the innermost executor where the failing action and full nesting
        # stack are still present. A report retried from an ancestor (because an inner `on_exception`
        # attempt raised and so was never marked reported) runs after the inner frames have popped, so
        # rebuilding from the ancestor then would describe the wrong action (its inputs/outputs and a
        # truncated path) in the one report that lands. Reusing the captured snapshot keeps the landed
        # report describing the action where the bug actually occurred. Block evaluated only on first capture.
        def captured_report(exception) = (_reports[exception] ||= yield)

        # Called by NestingTracking when the outermost action finishes.
        def reset!
          ActiveSupport::IsolatedExecutionState[:_axn_reported_exceptions] = nil
          ActiveSupport::IsolatedExecutionState[:_axn_failure_exceptions] = nil
          ActiveSupport::IsolatedExecutionState[:_axn_exception_reports] = nil
        end

        private

        def _reported = (ActiveSupport::IsolatedExecutionState[:_axn_reported_exceptions] ||= Set.new.compare_by_identity)
        def _failures = (ActiveSupport::IsolatedExecutionState[:_axn_failure_exceptions] ||= Set.new.compare_by_identity)
        def _reports = (ActiveSupport::IsolatedExecutionState[:_axn_exception_reports] ||= {}.compare_by_identity)
      end
    end
  end
end
