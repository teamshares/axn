# frozen_string_literal: true

require "axn/core/flow/handlers/invoker"

module Axn
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

            def message_from(descriptor)
              message = resolved_message_body(descriptor)
              return nil unless message.present?

              descriptor.prefix ? "#{descriptor.prefix}#{message}" : message
            end

            def resolved_message_body(descriptor)
              return nil unless descriptor

              if descriptor.handler
                invoke_handler(descriptor.handler)
              elsif exception
                exception.message
              elsif descriptor.prefix
                # For prefix-only success messages, find a default message from other descriptors
                invoke_handler(default_descriptor&.handler)
              end
            end

            def invoke_handler(handler) = handler ? Invoker.call(operation: "determining message callable", action:, handler:, exception:).presence : nil
            def fallback_message = event_type == :success ? DEFAULT_SUCCESS : DEFAULT_ERROR
          end
        end
      end
    end
  end
end
