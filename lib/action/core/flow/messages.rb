# frozen_string_literal: true

require "action/core/event_handlers"

module Action
  module Core
    module Flow
      module Messages
        def self.included(base)
          base.class_eval do
            class_attribute :_messages_registry, default: Action::EventHandlers::Registry.empty

            extend ClassMethods
            include InstanceMethods
          end
        end

        module ClassMethods
          # Internal introspection helper
          def _messages_for(event_type)
            Array(_messages_registry.for(event_type))
          end

          def success(message, if: nil)
            return true unless message.present?

            if binding.local_variable_get(:if)
              matcher = binding.local_variable_get(:if)
              entry = Action::EventHandlers::MessageHandler.new(matcher:, message:, static: false)
              self._messages_registry = _messages_registry.register(event_type: :success, entry:, prepend: true)
            else
              entry = Action::EventHandlers::MessageHandler.new(matcher: -> { true }, message:, static: true)
              # Prepend so child statics override parent statics; non-statics are resolved earlier anyway
              self._messages_registry = _messages_registry.register(event_type: :success, entry:, prepend: true)
            end
            true
          end

          def error(message, if: nil)
            return true unless message.present?

            if binding.local_variable_get(:if)
              matcher = binding.local_variable_get(:if)
              entry = Action::EventHandlers::MessageHandler.new(matcher:, message:, static: false)
              self._messages_registry = _messages_registry.register(event_type: :error, entry:, prepend: true)
            else
              entry = Action::EventHandlers::MessageHandler.new(matcher: -> { true }, message:, static: true)
              # Prepend so child statics override parent statics; non-statics are resolved earlier anyway
              self._messages_registry = _messages_registry.register(event_type: :error, entry:, prepend: true)
            end
            true
          end

          def default_error = new.internal_context.default_error

          # Private helpers
        end

        module InstanceMethods
          delegate :default_error, to: :internal_context
        end
      end
    end
  end
end
