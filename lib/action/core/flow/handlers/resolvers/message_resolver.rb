# frozen_string_literal: true

require "action/core/flow/handlers/invoker"

module Action
  module Core
    module Flow
      module Handlers
        module Resolvers
          # Internal: resolves messages with different strategies
          class MessageResolver < BaseResolver
            DEFAULT_ERROR = "Something went wrong"
            DEFAULT_SUCCESS = "Action completed successfully"

            def resolve_message
              descriptor = matching_entries.detect { |d| message_from(d) }
              message_from(descriptor) || fallback_message
            end

            def resolve_default_message
              descriptor = find_default_descriptor
              message_from(descriptor) || fallback_message
            end

            private

            # Returns the first available static message handler that produces a non-blank message
            def find_default_descriptor
              candidate_entries.detect do |descriptor|
                descriptor.static? && descriptor.handler && message_from(descriptor)
              end
            end

            # Extracts the actual message content from a descriptor
            def message_from(descriptor)
              return nil unless descriptor

              # If we have a handler, invoke it
              if descriptor.handler
                message = Invoker.call(operation: "determining message callable", action:, handler: descriptor.handler, exception:).presence
                return "#{descriptor.prefix}#{message}" if descriptor.prefix && message

                return message
              end

              # If we only have a prefix, handle based on context
              if descriptor.prefix
                return "#{descriptor.prefix}#{exception.message}" if exception

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
              candidate_entries.each do |candidate|
                next if candidate == current_descriptor
                next unless candidate.handler

                message = Invoker.call(operation: "determining message callable", action:, handler: candidate.handler, exception:).presence
                return message if message
              end
              nil
            end

            def fallback_message = event_type == :success ? DEFAULT_SUCCESS : DEFAULT_ERROR
          end
        end
      end
    end
  end
end
