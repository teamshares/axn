# frozen_string_literal: true

module Action
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

      def _tracking_nesting(axn)
        NestingTracking._current_axn_stack.push(axn)
        yield
      ensure
        NestingTracking._current_axn_stack.pop
      end

      # Shared method for both class and instance access
      def self._current_axn_stack
        ActiveSupport::IsolatedExecutionState[:_axn_stack] ||= []
      end
    end
  end
end
