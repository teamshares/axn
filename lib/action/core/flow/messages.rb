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
          end
        end

        module ClassMethods
          def success(message = nil, **, &) = _add_message(:success, message:, **, &)
          def error(message = nil, **, &) = _add_message(:error, message:, **, &)

          # Internal: resolve a message for the given event (conditional first, then static)
          def _custom_message_for(event_type, action:, exception: nil)
            _messages_registry.for(event_type).each do |handler|
              msg = handler.apply(action:, exception:)
              return msg if msg.present?
            end

            nil
          end

          private

          def _add_message(kind, message:, **kwargs, &block)
            raise ArgumentError, "#{kind} cannot be called with both :if and :unless" if kwargs.key?(:if) && kwargs.key?(:unless)
            raise ArgumentError, "Provide either a message or a block, not both" if message && block_given?
            raise ArgumentError, "Provide a message, block, or prefix" unless message || block_given? || kwargs[:prefix]
            raise ArgumentError, "from: only applies to error messages" if kwargs.key?(:from) && kind != :error

            handler = block_given? ? block : message
            rules = [
              kwargs.key?(:if) ? kwargs[:if] : kwargs[:unless],
              _build_from_rule(kwargs[:from]),
            ].compact

            matcher = Action::Core::Flow::Handlers::Matcher.new(rules, invert: kwargs.key?(:unless))
            entry = Action::Core::Flow::Handlers::MessageHandler.new(matcher:, handler:, prefix: kwargs[:prefix])
            self._messages_registry = _messages_registry.register(event_type: kind, entry:)
            true
          end

          def _build_from_rule(from_class)
            return nil unless from_class

            if from_class.is_a?(String)
              lambda { |exception:, **|
                exception.is_a?(Action::Failure) && exception.source&.class&.name == from_class
              }
            else
              ->(exception:, **) { exception.is_a?(Action::Failure) && exception.source&.is_a?(from_class) }
            end
          end
        end
      end
    end
  end
end
