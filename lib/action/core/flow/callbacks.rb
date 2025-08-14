# frozen_string_literal: true

require "action/core/flow/handlers"

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
            _callbacks_registry.for(event_type).each do |handler|
              handler.apply(action:, exception:)
            end
          end

          # ONLY raised exceptions (i.e. NOT fail!).
          def on_exception(matcher = nil, handler = nil, &block)
            _add_callback(:exception, matcher:, handler:, block:)
          end

          # ONLY raised on fail! (i.e. NOT unhandled exceptions).
          def on_failure(matcher = nil, handler = nil, &block)
            _add_callback(:failure, matcher:, handler:, block:)
          end

          # Handles both fail! and unhandled exceptions
          def on_error(matcher = nil, handler = nil, &block)
            _add_callback(:error, matcher:, handler:, block:)
          end

          # Executes when the action completes successfully (after all after hooks complete successfully)
          # Runs in child-first order (child handlers before parent handlers)
          def on_success(matcher = nil, handler = nil, &block)
            _add_callback(:success, matcher:, handler:, block:)
          end

          private

          def _add_callback(event_type, matcher:, handler:, block:)
            effective_handler = handler || block
            raise ArgumentError, "on_#{event_type} must be called with a block or symbol" unless effective_handler

            entry = Action::Core::Flow::Handlers::CallbackHandler.new(matcher:, handler: effective_handler)
            self._callbacks_registry = _callbacks_registry.register(event_type:, entry:, prepend: true)
          end
        end
      end
    end
  end
end
