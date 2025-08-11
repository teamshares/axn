# frozen_string_literal: true

require "action/core/event_handlers"

module Action
  module Core
    module Flow
      module Callbacks
        def self.included(base)
          base.class_eval do
            class_attribute :_error_handlers, default: []
            class_attribute :_exception_handlers, default: []
            class_attribute :_failure_handlers, default: []
            class_attribute :_success_handlers, default: []

            extend ClassMethods
          end
        end

        module ClassMethods
          # ONLY raised exceptions (i.e. NOT fail!). Skipped if exception is rescued via .rescues.
          def on_exception(matcher = -> { true }, &handler)
            raise ArgumentError, "on_exception must be called with a block" unless block_given?

            self._exception_handlers += [Action::EventHandlers::ConditionalHandler.new(matcher:, handler:)]
          end

          # ONLY raised on fail! (i.e. NOT unhandled exceptions).
          def on_failure(matcher = -> { true }, &handler)
            raise ArgumentError, "on_failure must be called with a block" unless block_given?

            self._failure_handlers += [Action::EventHandlers::ConditionalHandler.new(matcher:, handler:)]
          end

          # Handles both fail! and unhandled exceptions... but is NOT affected by .rescues
          def on_error(matcher = -> { true }, &handler)
            raise ArgumentError, "on_error must be called with a block" unless block_given?

            self._error_handlers += [Action::EventHandlers::ConditionalHandler.new(matcher:, handler:)]
          end

          # Executes when the action completes successfully (after all after hooks complete successfully)
          # Runs in child-first order (child handlers before parent handlers)
          def on_success(&handler)
            raise ArgumentError, "on_success must be called with a block" unless block_given?

            # Prepend like after hooks - child handlers run before parent handlers
            self._success_handlers = [handler] + _success_handlers
          end
        end
      end
    end
  end
end
