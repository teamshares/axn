# frozen_string_literal: true

module Axn
  module Core
    module NestingTracking
      def self.included(base)
        base.class_eval do
          extend ClassMethods
        end
      end

      module ClassMethods
        def _nested_in_another_axn?
          NestingTracking._current_axn_stack.any?
        end
      end

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
