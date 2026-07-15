# frozen_string_literal: true

require "axn/core/flow/handlers"

module Axn
  module Core
    module Flow
      module Messages
        def self.included(base)
          base.class_eval do
            class_attribute :_messages_registry, default: Axn::Core::Flow::Handlers::Registry.empty

            extend ClassMethods
          end
        end

        module ClassMethods
          def success(message = nil, **, &) = _add_message(:success, message:, **, &)
          def error(message = nil, **, &) = _add_message(:error, message:, **, &)

          private

          def _add_message(kind, message:, standalone: nil, join: nil, **kwargs, &block)
            Axn::Core::Flow::Handlers::Descriptors::MessageDescriptor.reject_unsupported_options!(kwargs.slice(:from, :prefix))
            raise ArgumentError, "Provide either a message or a block, not both" if message && block_given?
            raise ArgumentError, "Provide a message or a block" unless message || block_given?

            entry = _build_entry(message, standalone:, join:, kwargs:, block:, block_given: block_given?)

            self._messages_registry = _messages_registry.register(event_type: kind, entry:)
            true
          end

          def _build_entry(message, standalone:, join:, kwargs:, block:, block_given:)
            if message.is_a?(Axn::Core::Flow::Handlers::Descriptors::MessageDescriptor)
              if kwargs.any? || block_given || !standalone.nil? || !join.nil?
                raise ArgumentError, "Cannot pass additional configuration with prebuilt descriptor"
              end

              return message
            end

            Axn::Core::Flow::Handlers::Descriptors::MessageDescriptor.build(
              handler: block_given ? block : message,
              standalone:,
              join:,
              **kwargs,
            )
          end
        end
      end
    end
  end
end
