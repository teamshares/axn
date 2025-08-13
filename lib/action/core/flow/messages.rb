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

          def success(message)
            return true unless message.present?

            entry = Action::EventHandlers::MessageHandler.new(matcher: -> { true }, message:, static: true)
            # Prepend so child statics override parent statics; non-statics are resolved earlier anyway
            self._messages_registry = _messages_registry.register(event_type: :success, entry:, prepend: true)
            true
          end

          def error(message)
            return true unless message.present?

            entry = Action::EventHandlers::MessageHandler.new(matcher: -> { true }, message:, static: true)
            # Prepend so child statics override parent statics; non-statics are resolved earlier anyway
            self._messages_registry = _messages_registry.register(event_type: :error, entry:, prepend: true)
            true
          end

          def error_from(matcher = nil, message = nil, **match_and_messages)
            _register_message_interceptor(:error, matcher, message, **match_and_messages)
          end

          def success_from(matcher = nil, message = nil, **match_and_messages)
            _register_success_interceptor(matcher, message, **match_and_messages)
          end

          def default_error = new.internal_context.default_error

          # Private helpers

          def _register_message_interceptor(kind, matcher, message, **match_and_messages)
            pairs = { matcher => message }.compact.merge(match_and_messages)
            raise ArgumentError, "#{kind}_from must be called with a key/value pair, or else keyword args" if pairs.empty? && [matcher,
                                                                                                                               message].compact.size == 1

            pairs.each do |(m, msg_callable)|
              entry = Action::EventHandlers::MessageHandler.new(matcher: m, message: msg_callable, static: false)
              self._messages_registry = _messages_registry.register(event_type: kind, entry:, prepend: true)
            end
          end

          def _register_success_interceptor(matcher, message, **match_and_messages)
            _register_message_interceptor(:success, matcher, message, **match_and_messages)
          end
        end

        module InstanceMethods
          delegate :default_error, to: :internal_context
        end
      end
    end
  end
end
