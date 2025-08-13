# frozen_string_literal: true

require "action/core/event_handlers"

module Action
  module Core
    module Flow
      module Callbacks
        def self.included(base)
          base.class_eval do
            class_attribute :_callbacks_registry, default: Action::EventHandlers::Registry.empty

            extend ClassMethods
          end
        end

        module ClassMethods
          # Internal introspection helper
          def _callbacks_for(event_type)
            Array(_callbacks_registry.for(event_type))
          end

          # Internal dispatcher
          def _dispatch_callbacks(event_type, action:, exception: nil)
            _callbacks_registry.for(event_type).each do |handler|
              handler.execute_if_matches(action:, exception:)
            end
          end

          # ONLY raised exceptions (i.e. NOT fail!).
          def on_exception(matcher = nil, &handler)
            raise ArgumentError, "on_exception must be called with a block" unless block_given?

            entry = Action::EventHandlers::CallbackHandler.new(matcher:, handler:)
            self._callbacks_registry = _callbacks_registry.register(event_type: :exception, entry:, prepend: true)
          end

          # ONLY raised on fail! (i.e. NOT unhandled exceptions).
          def on_failure(matcher = nil, &handler)
            raise ArgumentError, "on_failure must be called with a block" unless block_given?

            entry = Action::EventHandlers::CallbackHandler.new(matcher:, handler:)
            self._callbacks_registry = _callbacks_registry.register(event_type: :failure, entry:, prepend: true)
          end

          # Handles both fail! and unhandled exceptions
          def on_error(matcher = nil, &handler)
            raise ArgumentError, "on_error must be called with a block" unless block_given?

            entry = Action::EventHandlers::CallbackHandler.new(matcher:, handler:)
            self._callbacks_registry = _callbacks_registry.register(event_type: :error, entry:, prepend: true)
          end

          # Executes when the action completes successfully (after all after hooks complete successfully)
          # Runs in child-first order (child handlers before parent handlers)
          def on_success(matcher = nil, &handler)
            raise ArgumentError, "on_success must be called with a block" unless block_given?

            entry = Action::EventHandlers::CallbackHandler.new(matcher:, handler:)
            self._callbacks_registry = _callbacks_registry.register(event_type: :success, entry:, prepend: true)
          end
        end
      end
    end
  end
end
