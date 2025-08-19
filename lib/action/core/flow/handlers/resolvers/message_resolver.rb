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
                message = message_from(descriptor)
                next unless message.present?

                return message
              end

              nil
            end

            # Returns the raw message from the default handler (without prefix)
            def resolve_default_message
              descriptor = find_default_descriptor
              return nil unless descriptor

              message_from(descriptor)
            end

            private

            # Returns the first available message handler that produces a non-blank message
            def find_default_descriptor
              candidate_entries.reverse.each do |descriptor|
                next unless descriptor.handler && (descriptor.handler.respond_to?(:call) || descriptor.handler.is_a?(String))

                message = message_from(descriptor)
                return descriptor if message
              end
              nil
            end

            # Extracts the actual message content from a descriptor
            def message_from(descriptor)
              # If we have a handler, invoke it
              if descriptor.handler
                message = Invoker.call(operation: "determining message callable", action:, handler: descriptor.handler, exception:).presence
                return "#{descriptor.prefix}#{message}" if descriptor.prefix && message

                return message
              end

              # If we only have a prefix, handle based on context
              if descriptor.prefix
                return "#{descriptor.prefix}#{exception.message}" if exception

                # For error messages, use exception message with prefix

                # For success messages, find a default message from other descriptors
                default_message = find_default_message_content(descriptor)
                return nil unless default_message.present?

                return "#{descriptor.prefix}#{default_message}"

              end

              # If no handler and no prefix, use exception message
              exception&.message
            end

            # Finds a default message content from other descriptors (avoiding infinite loops)
            def find_default_message_content(current_descriptor)
              candidate_entries.reverse.each do |candidate|
                next if candidate == current_descriptor # Skip current descriptor to avoid loops
                next unless candidate.handler && (candidate.handler.respond_to?(:call) || candidate.handler.is_a?(String))

                message = Invoker.call(operation: "determining message callable", action:, handler: candidate.handler, exception:).presence
                return message if message
              end
              nil
            end
          end
        end
      end
    end
  end
end
