# frozen_string_literal: true

require "action/core/flow/handlers"
require "action/core/flow/handlers/resolvers/callback_resolver"

module Action
  module Core
    module Flow
      module Callbacks
        def self.included(base)
          base.class_eval do
            class_attribute :_callbacks_registry, default: Action::Core::Flow::Handlers::Registry.empty

            extend ClassMethods
          end
        end

        module ClassMethods
          # Internal dispatcher
          def _dispatch_callbacks(event_type, action:, exception: nil)
            resolver = Action::Core::Flow::Handlers::Resolvers::CallbackResolver.new(
              _callbacks_registry,
              event_type,
              action:,
              exception:,
            )
            resolver.execute_callbacks
          end

          # ONLY raised exceptions (i.e. NOT fail!).
          def on_exception(handler = nil, **, &block) = _add_callback(:exception, handler:, **, block:)

          # ONLY raised on fail! (i.e. NOT unhandled exceptions).
          def on_failure(handler = nil, **, &block) = _add_callback(:failure, handler:, **, block:)

          # Handles both fail! and unhandled exceptions
          def on_error(handler = nil, **, &block) = _add_callback(:error, handler:, **, block:)

          # Executes when the action completes successfully (after all after hooks complete successfully)
          # Runs in child-first order (child handlers before parent handlers)
          def on_success(handler = nil, **, &block) = _add_callback(:success, handler:, **, block:)

          private

          def _add_callback(event_type, handler: nil, block: nil, **kwargs)
            raise ArgumentError, "on_#{event_type} cannot be called with both :if and :unless" if kwargs.key?(:if) && kwargs.key?(:unless)
            raise ArgumentError, "on_#{event_type} cannot be called with both a block and a handler" if block && handler
            raise ArgumentError, "on_#{event_type} must be called with a block or symbol" unless block || handler

            # If handler is already a descriptor, use it directly
            entry = if handler.is_a?(Action::Core::Flow::Handlers::Descriptors::CallbackDescriptor)
                      raise ArgumentError, "Cannot pass additional configuration with prebuilt descriptor" if kwargs.any? || block

                      handler
                    else
                      Action::Core::Flow::Handlers::Descriptors::CallbackDescriptor.build(
                        handler: handler || block,
                        **kwargs,
                      )
                    end

            self._callbacks_registry = _callbacks_registry.register(event_type:, entry:)
            true
          end
        end
      end
    end
  end
end
