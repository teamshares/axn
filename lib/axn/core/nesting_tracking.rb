# frozen_string_literal: true

# `_current_axn_stack` reaches ActiveSupport::IsolatedExecutionState, which nothing here used to make a
# load-order requirement of: every existing caller was reached only after the umbrella `axn` entrypoint
# (which requires "active_support") had already loaded. `Axn::Extensions::Tracing`'s standalone-loadable
# facade (PRO-3278) is the first path that can reach this module without that entrypoint ever having
# run, so it is declared explicitly here rather than left implicit.
require "active_support"

# The fiber-isolation mismatch warning below goes through Extensions.best_effort, so this component
# needs it whether or not the umbrella entrypoint loaded it.
require "axn/extensions"

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
          Axn::Internal::FailsOnVerdicts.reset!
          _warn_if_fiber_isolation_mismatch
        end
        _current_axn_stack.push(axn)
        yield
      ensure
        stack = _current_axn_stack
        # Identity, not equality: two frames may track equal-but-distinct actions, and `equal?` keeps
        # this check allocation-free on the path every call takes.
        if stack.last.equal?(axn)
          stack.pop
        else
          _heal_interleaved_stack(stack, axn)
        end
        # Outermost action finished: clear per-execution exception bookkeeping so the same exception
        # object re-raised by a later, independent run starts fresh (report dedup, fails_on
        # stickiness, and a fails_on condition's cached verdict are all scoped to one call tree).
        if stack.empty?
          Axn::Internal::ExceptionClassification.reset!
          Axn::Internal::CarriedPresentation.reset!
          Axn::Internal::FailsOnVerdicts.reset!
        end
      end

      # The top of the stack is not this frame's own entry, so another execution sharing this stack
      # pushed after us and has not popped yet: two call trees interleaved on one stack. Under :thread
      # isolation that happens with manually resumed Fibers and no scheduler (a scheduler under :thread
      # is the case `_warn_if_fiber_isolation_mismatch` already announces, so it is not re-announced
      # here). Popping the top would remove the OTHER tree's entry and leave ours in its place, so the
      # other tree would read this finished action as its own; remove our own entry instead — the last
      # one, since an entry above it belongs to whoever pushed later.
      #
      # Known limit: an interleave whose pops happen to balance (B's call tree starts and finishes
      # entirely while A is suspended) always finds its own entry on top and is not detected, even
      # though B's frames read A's entry beneath their own and were attributed as nested inside A.
      def self._heal_interleaved_stack(stack, axn)
        index = stack.rindex { |entry| entry.equal?(axn) }
        return unless index # our entry is already gone (e.g. IsolatedExecutionState was cleared)

        stack.delete_at(index)
        _warn_interleaved_stack
      end

      INTERLEAVE_LOCK = Thread::Mutex.new
      private_constant :INTERLEAVE_LOCK

      # Same claim-before-log, log-outside-the-lock, never-raise-into-`.call` shape as
      # `_warn_if_fiber_isolation_mismatch` below, for the same reasons.
      def self._warn_interleaved_stack
        return if @_interleave_warned

        Axn::Extensions.best_effort("warning about an interleaved nesting stack") do
          next if Fiber.respond_to?(:scheduler) && Fiber.scheduler

          claimed = INTERLEAVE_LOCK.synchronize do
            @_interleave_warned ? false : (@_interleave_warned = true)
          end
          next unless claimed

          Axn.config.logger.warn(
            "[Axn] axn calls on one thread were interleaved without a Fiber scheduler (e.g. manually " \
            "resumed Fibers), so nesting-dependent state (log prefixes, exception attribution) was " \
            "misattributed while they overlapped. Manually driven fibers are not supported: run them under " \
            "a Fiber scheduler with `ActiveSupport::IsolatedExecutionState.isolation_level = :fiber`.",
          )
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
        return if @_isolation_mismatch_warned # a plain ivar read; cannot raise, and this is the hot path

        # The whole diagnostic is inside, probes/lock/claim/emit alike: this runs on EVERY fresh call
        # tree, outside any executor guard, so anything raising here would take `.call` down over a
        # courtesy. Same shape and same reason as InstanceDeferral._warn_once. The claim is still
        # committed before the line is written, so a logger that raises cannot leave the process
        # un-warned and re-announce the mismatch on the next call tree.
        Axn::Extensions.best_effort("warning about a fiber-isolation mismatch") do
          next unless Fiber.respond_to?(:scheduler) && Fiber.scheduler
          next unless ActiveSupport::IsolatedExecutionState.isolation_level == :thread

          claimed = ISOLATION_MISMATCH_LOCK.synchronize do
            @_isolation_mismatch_warned ? false : (@_isolation_mismatch_warned = true)
          end
          next unless claimed

          Axn.config.logger.warn(
            "[Axn] A Fiber scheduler is active but ActiveSupport::IsolatedExecutionState.isolation_level " \
            "is :thread. axn's per-execution state will leak across concurrent fibers. Set " \
            "`config.active_support.isolation_level = :fiber` (Rails) or " \
            "`ActiveSupport::IsolatedExecutionState.isolation_level = :fiber` to isolate it correctly.",
          )
        end
      end

      # Re-arms the once-per-process warnings above, for a spec suite that asserts on them. Named for
      # the caller it exists for: Axn::Testing.reset! is the supported entry point.
      def self._reset_isolation_warning!
        remove_instance_variable(:@_isolation_mismatch_warned) if instance_variable_defined?(:@_isolation_mismatch_warned)
        remove_instance_variable(:@_interleave_warned) if instance_variable_defined?(:@_interleave_warned)
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
      private_class_method :_warn_if_fiber_isolation_mismatch, :_heal_interleaved_stack, :_warn_interleaved_stack
    end
  end
end
