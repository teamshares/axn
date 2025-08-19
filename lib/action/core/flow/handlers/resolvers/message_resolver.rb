# frozen_string_literal: true

require "action/core/flow/handlers/invoker"

module Action
  module Core
    module Flow
      module Handlers
        module Resolvers
          # Internal: resolves messages with different strategies
          class MessageResolver
            def initialize(registry, event_type, action:, exception:)
              @registry = registry
              @event_type = event_type
              @action = action
              @exception = exception
            end

            # Resolves the message using the standard strategy (conditional first, then static)
            def resolve_message
              @registry.for(@event_type).each do |handler|
                msg = handler.apply(action: @action, exception: @exception)

                # Handle prefix-only handlers by looking up the default message
                if msg == :prefix_only
                  default_msg = resolve_default_message
                  return nil unless default_msg.present?

                  # Extract the prefix from the current handler and apply it to the default message
                  prefix = handler.instance_variable_get(:@prefix)
                  return "#{prefix}#{default_msg}" if prefix
                end

                return msg if msg.present?
              end

              nil
            end

            # Returns the first available message handler that produces a non-blank message
            def resolve_default_handler
              @registry.for(@event_type).reverse.each do |handler|
                # Skip handlers without content (just prefixes)
                next unless handler.handler && (handler.handler.respond_to?(:call) || handler.handler.is_a?(String))

                # Test if this handler produces a non-blank message
                msg = if handler.handler.respond_to?(:call)
                        Invoker.call(action: @action, handler: handler.handler, exception: @exception, operation: "determining message callable")
                      elsif handler.handler.is_a?(String)
                        handler.handler
                      end

                # Return this handler if it produces a meaningful message
                return handler if msg.present?
              end
              nil
            end

            # Returns the raw message from the default handler (without prefix)
            def resolve_default_message
              handler = resolve_default_handler
              return nil unless handler

              # Get the message from this handler (we know it's non-blank because resolve_default_handler tested it)
              if handler.handler.respond_to?(:call)
                Invoker.call(action: @action, handler: handler.handler, exception: @exception, operation: "determining message callable")
              elsif handler.handler.is_a?(String)
                handler.handler
              end
            end
          end
        end
      end
    end
  end
end
