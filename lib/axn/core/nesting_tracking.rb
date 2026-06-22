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
      end
    end
  end
end
