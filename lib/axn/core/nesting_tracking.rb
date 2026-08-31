# frozen_string_literal: true

# `_current_axn_stack` reaches ActiveSupport::IsolatedExecutionState, which nothing here used to make a
# load-order requirement of: every existing caller was reached only after the umbrella `axn` entrypoint
# (which requires "active_support") had already loaded. `Axn::Extensions::Tracing`'s standalone-loadable
# facade (PRO-3278) is the first path that can reach this module without that entrypoint ever having
# run, so it is declared explicitly here rather than left implicit.
require "active_support"

module Axn
  module Core
    module NestingTracking
      # Shared method for both class and instance access
      def self._current_axn_stack
        ActiveSupport::IsolatedExecutionState[:_axn_stack] ||= []
      end

      # The action instance whose call is innermost right now, or nil outside any action — read by
      # `Internal::Tracing.current_span` (PRO-3278) so a consumer can identify its own axn.call span
      # without a `.last` spelled at each call site.
      def self.current_axn = _current_axn_stack.last

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

      # Whether the CURRENT thread's execution context has the fiber-scheduler/isolation_level mismatch
      # `_warn_if_fiber_isolation_mismatch` warns about — re-derived live from the same two conditions
      # that warning checks, not read off `@_isolation_mismatch_warned`. That ivar is process-wide and
      # sticky (set once, on whichever thread first tripped it, and never cleared), while `Fiber.scheduler`
      # is per-thread: a hybrid process running some threads under a scheduler and others without one
      # would have this answer PERMANENTLY true for every thread for the rest of the process the moment
      # any ONE scheduler-bearing thread tripped it once — including the ordinary threads `IsolatedExecutionState`
      # isolates correctly, where nothing is actually unsafe. Re-checking live scopes the answer to the
      # thread actually asking.
      #
      # Under the true mismatch, `_current_axn_stack` — and so `current_axn` — is unreliable: it is
      # shared, unlocked, across concurrent fibers on one thread, and `.last` can already answer with a
      # different fiber's action. `Internal::Tracing.current_span` (PRO-3278) gates on this rather than
      # trust `current_axn` blindly, because handing a consumer a span under this condition risks
      # something worse than the wrong log prefix the mismatch already costs elsewhere — a live span
      # belonging to an unrelated, concurrently-running action. Nothing here REPAIRS the underlying shared
      # state (nothing safely can, see `_warn_if_fiber_isolation_mismatch`'s own comment); this only stops a
      # consumer from trusting an answer axn already knows may not be its own.
      def self.isolation_unsafe?
        return false unless Fiber.respond_to?(:scheduler) && Fiber.scheduler

        ActiveSupport::IsolatedExecutionState.isolation_level == :thread
      end

      # Reached only from `tracking` above. `_current_axn_stack` stays public: the executor, the call
      # logger and the exception-context builder all read it as `NestingTracking._current_axn_stack`.
      private_class_method :_warn_if_fiber_isolation_mismatch
    end
  end
end
