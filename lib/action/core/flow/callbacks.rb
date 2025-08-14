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
          def on_exception(**, &block) = _add_callback(:exception, **, block:)

          # ONLY raised on fail! (i.e. NOT unhandled exceptions).
          def on_failure(**, &block) = _add_callback(:failure, **, block:)

          # Handles both fail! and unhandled exceptions
          def on_error(**, &block) = _add_callback(:error, **, block:)

          # Executes when the action completes successfully (after all after hooks complete successfully)
          # Runs in child-first order (child handlers before parent handlers)
          def on_success(**, &block) = _add_callback(:success, **, block:)

          private

          def _add_callback(event_type, block:, **kwargs)
            raise ArgumentError, "on_#{event_type} cannot be called with both :if and :unless" if kwargs.key?(:if) && kwargs.key?(:unless)

            condition = kwargs.key?(:if) ? kwargs[:if] : kwargs[:unless]
            raise ArgumentError, "on_#{event_type} must be called with a block" unless block

            matcher = condition.nil? ? nil : Action::Core::Flow::Handlers::Matcher.new(condition, invert: kwargs.key?(:unless))
            entry = Action::Core::Flow::Handlers::CallbackHandler.new(matcher:, handler: block)
            self._callbacks_registry = _callbacks_registry.register(event_type:, entry:, prepend: true)
          end
        end
      end
    end
  end
end
