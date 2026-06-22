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
