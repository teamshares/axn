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
        # An exception axn must pass through completely untouched — no recorded outcome, no callbacks,
        # no report, no log line. Two kinds qualify, and neither describes a fault in the action:
        #
        #   * Process lifecycle. SignalException (so Interrupt, and Sidekiq::Shutdown, which subclasses
        #     it) and SystemExit mean the process is going away. Reporting a job killed at deploy is
        #     noise, and running the action's callbacks during shutdown invites user code that opens a
        #     transaction or makes an HTTP call to block it.
        #   * A foreign library's control flow. Timeout::ExitException is Timeout's own private signal,
        #     caught and converted to Timeout::Error by the enclosing Timeout.timeout — via an IDENTITY
        #     check on the object it raised. Touching or (worse) wrapping it makes the timeout silently
        #     not fire. Only the known stdlib case can be named; a gem inventing its own such signal
        #     would need adding here.
        #
        # Ruby's `fatal` needs no entry: it is unrescuable, so `rescue Exception` never sees it.
        #
        # Deliberately a DENYLIST, the opposite of Extensions::SWALLOWABLE_BEYOND_STANDARD_ERROR's
        # allowlist. That one asks "is this safe to swallow?", where the conservative answer is no; this
        # asks "is this worth reporting?", where the conservative answer is yes — a spurious report
        # costs far less than a silently unreported bug, so anything unrecognized reports.
        def pass_through?(exception)
          return true if exception.is_a?(SignalException) || exception.is_a?(SystemExit)

          defined?(::Timeout::ExitException) && exception.is_a?(::Timeout::ExitException)
        end

        # Global report de-duplication: report once per exception per call tree.
        def reported?(exception) = _reported.include?(exception)
        def mark_reported!(exception) = _reported.add(exception)

        # `fails_on` stickiness: a classified failure stays a failure (no report, failure outcome) as
        # it bubbles up — mirroring how Axn::Failure is sticky via its class.
        def failure?(exception) = _failures.include?(exception)
        def mark_failure!(exception) = _failures.add(exception)

        # Called by NestingTracking when the outermost action finishes.
        def reset!
          ActiveSupport::IsolatedExecutionState[:_axn_reported_exceptions] = nil
          ActiveSupport::IsolatedExecutionState[:_axn_failure_exceptions] = nil
        end

        private

        def _reported = (ActiveSupport::IsolatedExecutionState[:_axn_reported_exceptions] ||= Set.new.compare_by_identity)
        def _failures = (ActiveSupport::IsolatedExecutionState[:_axn_failure_exceptions] ||= Set.new.compare_by_identity)
      end
    end
  end
end
