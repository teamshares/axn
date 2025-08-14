# frozen_string_literal: true

require "action/core/flow/handlers"

module Action
  module Core
    module Flow
      module Messages
        def self.included(base)
          base.class_eval do
            class_attribute :_messages_registry, default: Action::Core::Flow::Handlers::Registry.empty

            extend ClassMethods
            include InstanceMethods
          end
        end

        module ClassMethods
          # Internal: resolve a message for the given event (conditional first, then static)
          def _message_for(event_type, action:, exception: nil)
            _conditional_message_for(event_type, action:, exception:) ||
              _static_message_for(event_type, action:, exception:)
          end

          def _conditional_message_for(event_type, action:, exception: nil)
            _messages_registry.for(event_type).each do |handler|
              next if handler.respond_to?(:static?) && handler.static?

              msg = handler.apply(action:, exception:)
              return msg if msg.present?
            end
            nil
          end

          def _static_message_for(event_type, action:, exception: nil)
            _messages_registry.for(event_type).each do |handler|
              next unless handler.respond_to?(:static?) && handler.static?

              msg = handler.apply(action:, exception:)
              return msg if msg.present?
            end
            nil
          end

          def success(message = nil, **kwargs, &block)
            matcher = kwargs.key?(:if) ? kwargs[:if] : nil
            raise ArgumentError, "Provide either a message or a block, not both" if message && block_given?
            raise ArgumentError, "Provide a message or a block" unless message || block_given?

            msg = block_given? ? block : message

            _add_message(:success, msg, matcher:, static: matcher ? false : true)
            true
          end

          def error(message = nil, **kwargs, &block)
            matcher = kwargs.key?(:if) ? kwargs[:if] : nil
            raise ArgumentError, "Provide either a message or a block, not both" if message && block_given?
            raise ArgumentError, "Provide a message or a block" unless message || block_given?

            msg = block_given? ? block : message

            _add_message(:error, msg, matcher:, static: matcher ? false : true)
            true
          end

          def default_error = new.internal_context.default_error
          def default_success = new.internal_context.default_success

          # Private helpers
          def _add_message(kind, msg, matcher:, static:)
            entry = Action::Core::Flow::Handlers::MessageHandler.new(matcher:, message: msg, static:)
            self._messages_registry = _messages_registry.register(event_type: kind, entry:, prepend: true)
          end
          private :_add_message
        end

        module InstanceMethods
          delegate :default_error, :default_success, to: :internal_context
        end
      end
    end
  end
end
