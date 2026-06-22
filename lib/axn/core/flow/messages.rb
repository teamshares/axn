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

          def _add_message(kind, message:, prefixed: nil, delimiter: nil, **kwargs, &block)
            raise Axn::UnsupportedArgument, "calling #{kind} with both :if and :unless" if kwargs.key?(:if) && kwargs.key?(:unless)
            raise Axn::UnsupportedArgument, "Combining from: with if: or unless:" if kwargs.key?(:from) && (kwargs.key?(:if) || kwargs.key?(:unless))
            raise ArgumentError, "Provide either a message or a block, not both" if message && block_given?
            raise ArgumentError, "Provide a message, block, or prefix" unless message || block_given? || kwargs[:prefix] || kwargs[:from]
            raise ArgumentError, "from: only applies to error messages" if kwargs.key?(:from) && kind != :error

            conditional = kwargs.key?(:if) || kwargs.key?(:unless) || kwargs.key?(:from)
            dynamic     = block_given? || message.is_a?(Symbol) || message.respond_to?(:call)
            reason      = conditional || dynamic # only "reasons" (not the base headline) may be prefixed
            effective_prefixed = _resolve_prefixed(prefixed, reason:, delimiter:)
            entry = _build_entry(message, prefixed:, delimiter:, effective_prefixed:, kwargs:, block:, block_given: block_given?)

            self._messages_registry = _messages_registry.register(event_type: kind, entry:)
            true
          end

          def _resolve_prefixed(prefixed, reason:, delimiter:)
            effective = prefixed.nil? ? reason : prefixed
            raise ArgumentError, "prefixed: true requires a condition (if:/unless:) or a dynamic message" if effective && !reason
            raise ArgumentError, "delimiter: only applies to a base error message" if delimiter && reason

            effective
          end

          def _build_entry(message, prefixed:, delimiter:, effective_prefixed:, kwargs:, block:, block_given:)
            if message.is_a?(Axn::Core::Flow::Handlers::Descriptors::MessageDescriptor)
              raise ArgumentError, "Cannot pass additional configuration with prebuilt descriptor" if kwargs.any? || block_given || !prefixed.nil? || delimiter

              return message
            end

            Axn::Core::Flow::Handlers::Descriptors::MessageDescriptor.build(
              handler: block_given ? block : message,
              prefixed: effective_prefixed,
              delimiter:,
              **kwargs,
            )
          end
        end
      end
    end
  end
end
