# frozen_string_literal: true

require "action/core/flow/handlers/invoker"

module Action
  module Core
    module Flow
      module Handlers
        module Resolvers
          # Internal: resolves messages with different strategies
          class MessageResolver < BaseResolver
            # Resolves the message using the standard strategy (conditional first, then static)
            def resolve_message
              matching_entries.each do |descriptor|
                # Get the message from this descriptor
                msg = resolve_descriptor_message(descriptor)
                next unless msg.present?

                # Handle prefix-only descriptors by looking up the default message
                if msg == :prefix_only
                  default_msg = resolve_default_message
                  return nil unless default_msg.present?

                  # Extract the prefix from the current descriptor and apply it to the default message
                  prefix = descriptor.instance_variable_get(:@prefix)
                  return "#{prefix}#{default_msg}" if prefix
                end

                return msg
              end

              nil
            end

            # Returns the first available message handler that produces a non-blank message
            def resolve_default_handler
              candidate_entries.reverse.each do |handler|
                # Skip handlers without content (just prefixes)
                next unless handler.handler && (handler.handler.respond_to?(:call) || handler.handler.is_a?(String))

                # Test if this handler produces a non-blank message
                msg = if handler.handler.respond_to?(:call)
                        Invoker.call(action:, handler: handler.handler, exception:, operation: "determining message callable")
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
                Invoker.call(action:, handler: handler.handler, exception:, operation: "determining message callable")
              elsif handler.handler.is_a?(String)
                handler.handler
              end
            end

            private

            # Resolves the message from a specific descriptor
            def resolve_descriptor_message(descriptor)
              value =
                if descriptor.handler.is_a?(Symbol) || descriptor.handler.respond_to?(:call)
                  Invoker.call(action:, handler: descriptor.handler, exception:, operation: "determining message callable")
                elsif !descriptor.handler && descriptor.instance_variable_get(:@prefix)
                  # For error messages, use the exception message; for success messages, return a marker
                  if exception
                    exception.message
                  else
                    # This is a success message with only a prefix
                    :prefix_only
                  end
                else
                  descriptor.handler
                end

              # Don't apply prefix to the special marker
              return value if value == :prefix_only

              message = value.respond_to?(:presence) ? value.presence : value
              return message unless descriptor.instance_variable_get(:@prefix) && message.present?

              # Apply prefix to the custom message
              "#{descriptor.instance_variable_get(:@prefix)}#{message}"
            end
          end
        end
      end
    end
  end
end
