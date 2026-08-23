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
          Axn::Internal::CarriedPresentation.reset!
          _warn_if_fiber_isolation_mismatch
        end
        _current_axn_stack.push(axn)
        yield
      ensure
        _current_axn_stack.pop
        # Outermost action finished: clear per-execution exception bookkeeping so the same exception
        # object re-raised by a later, independent run starts fresh (report dedup + fails_on
        # stickiness are scoped to one call tree).
        if _current_axn_stack.empty?
          Axn::Internal::ExceptionClassification.reset!
          Axn::Internal::CarriedPresentation.reset!
        end
      end

      # Two threads reaching a fresh call tree concurrently could both read the ivar as unset and both
      # warn — the same check-then-set race `InstanceDeferral::WARNED_LOCK` guards against, fixed here
      # the identical way: a lock-free fast path once the flag is set, the check-and-set inside the
      # lock, and the log emission OUTSIDE it (a logger that itself runs an axn action must not
      # deadlock on this non-reentrant mutex re-entering from the same thread).
      ISOLATION_MISMATCH_LOCK = Thread::Mutex.new
      private_constant :ISOLATION_MISMATCH_LOCK

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

        claimed = ISOLATION_MISMATCH_LOCK.synchronize do
          @_isolation_mismatch_warned ? false : (@_isolation_mismatch_warned = true)
        end
        return unless claimed

        Axn.config.logger.warn(
          "[Axn] A Fiber scheduler is active but ActiveSupport::IsolatedExecutionState.isolation_level " \
          "is :thread. axn's per-execution state will leak across concurrent fibers. Set " \
          "`config.active_support.isolation_level = :fiber` (Rails) or " \
          "`ActiveSupport::IsolatedExecutionState.isolation_level = :fiber` to isolate it correctly.",
        )
      end

      # Re-arms the once-per-process warning above, for a spec suite that asserts on it. Named for
      # the caller it exists for: Axn::Testing.reset! is the supported entry point.
      def self._reset_isolation_warning!
        remove_instance_variable(:@_isolation_mismatch_warned) if instance_variable_defined?(:@_isolation_mismatch_warned)
      end

      # Reached only from `tracking` above. `_current_axn_stack` stays public: the executor, the call
      # logger and the exception-context builder all read it as `NestingTracking._current_axn_stack`.
      private_class_method :_warn_if_fiber_isolation_mismatch
    end
  end
end
