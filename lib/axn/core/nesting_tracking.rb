# frozen_string_literal: true

module Axn
  module Core
    module NestingTracking
      # Shared method for both class and instance access
      def self._current_axn_stack
        ActiveSupport::IsolatedExecutionState[:_axn_stack] ||= []
      end

      # Tracks nesting of axn calls for logging/debugging purposes
      def self.tracking(axn)
        # Opening a fresh call tree (empty stack): clear any per-execution exception bookkeeping that
        # a prior run might have left behind without draining the stack (e.g. an executor invoked
        # outside this wrapper, or an aborted teardown). Defends against a stale "already reported"
        # mark on a reused thread/fiber silently suppressing a real report.
        if _current_axn_stack.empty?
          Axn::Internal::ExceptionClassification.reset!
          _warn_if_fiber_isolation_mismatch
        end
        _current_axn_stack.push(axn)
        yield
      ensure
        _current_axn_stack.pop
        # Outermost action finished: clear per-execution exception bookkeeping so the same exception
        # object re-raised by a later, independent run starts fresh (report dedup + fails_on
        # stickiness are scoped to one call tree).
        Axn::Internal::ExceptionClassification.reset! if _current_axn_stack.empty?
      end

      # axn's per-execution state lives in ActiveSupport::IsolatedExecutionState, which is scoped by
      # `isolation_level`. A fiber-based host (async/Falcon) running under the default :thread isolation
      # would share that state across concurrent fibers on one thread — silently corrupting the nesting
      # stack and exception-classification sets. We can't safely fix it for them (assigning
      # isolation_level= at runtime calls IsolatedExecutionState.clear, nuking AR/CurrentAttributes), so
      # we warn once and point at the fix. A scheduler being installed is the intent-to-run-fibers signal.
      def self._warn_if_fiber_isolation_mismatch
        return if @_isolation_mismatch_warned
        return unless Fiber.respond_to?(:scheduler) && Fiber.scheduler
        return unless ActiveSupport::IsolatedExecutionState.isolation_level == :thread

        @_isolation_mismatch_warned = true
        Axn.config.logger.warn(
          "[Axn] A Fiber scheduler is active but ActiveSupport::IsolatedExecutionState.isolation_level " \
          "is :thread. axn's per-execution state will leak across concurrent fibers. Set " \
          "`config.active_support.isolation_level = :fiber` (Rails) or " \
          "`ActiveSupport::IsolatedExecutionState.isolation_level = :fiber` to isolate it correctly.",
        )
      end
    end
  end
end
