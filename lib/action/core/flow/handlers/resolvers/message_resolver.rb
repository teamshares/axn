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
              message_from(default_descriptor) || fallback_message
            end

            private

            def default_descriptor
              # NOTE: descriptor.handler check avoids returning a prefix-only descriptor (which
              # needs to look up a default handler via this method to return a message)
              static_entries.detect { |descriptor| descriptor.handler && message_from(descriptor) }
            end

            # Extracts the actual message content from a descriptor
            def message_from(descriptor)
              return nil unless descriptor

              # If we have a handler, invoke it
              if descriptor.handler
                message = invoke_handler(descriptor.handler)
                return "#{descriptor.prefix}#{message}" if descriptor.prefix && message

                return message
              end

              # If we only have a prefix, handle based on context
              if descriptor.prefix
                return "#{descriptor.prefix}#{exception.message}" if exception

                # For success messages, find a default message from other descriptors
                default_descriptor_obj = default_descriptor
                return nil unless default_descriptor_obj

                default_message = invoke_handler(default_descriptor_obj.handler)
                return nil unless default_message.present?

                return "#{descriptor.prefix}#{default_message}"
              end

              # If no handler and no prefix, use exception message
              exception&.message
            end

            def invoke_handler(handler) = Invoker.call(operation: "determining message callable", action:, handler:, exception:).presence
            def fallback_message = event_type == :success ? DEFAULT_SUCCESS : DEFAULT_ERROR
          end
        end
      end
    end
  end
end
