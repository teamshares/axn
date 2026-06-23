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
        Axn::Internal::ExceptionClassification.reset! if _current_axn_stack.empty?
        _current_axn_stack.push(axn)
        yield
      ensure
        _current_axn_stack.pop
        # Outermost action finished: clear per-execution exception bookkeeping so the same exception
        # object re-raised by a later, independent run starts fresh (report dedup + fails_on
        # stickiness are scoped to one call tree).
        Axn::Internal::ExceptionClassification.reset! if _current_axn_stack.empty?
      end
    end
  end
end
