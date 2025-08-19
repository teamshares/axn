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

            # Extracts the actual message content from a handler with prefix handling
            def message_from(descriptor)
              case descriptor.message_type
              when :prefix_only
                resolve_prefix_only_message(descriptor)
              when :with_prefix
                resolve_prefixed_message(descriptor)
              when :core_default
                resolve_core_default_message(descriptor)
              else
                resolve_standard_message(descriptor)
              end
            end

            # Handles descriptors with only a prefix (no handler)
            def resolve_prefix_only_message(descriptor)
              if exception
                "#{descriptor.prefix}#{exception.message}"
              else
                default_message = resolve_default_message
                return nil unless default_message.present?

                "#{descriptor.prefix}#{default_message}"
              end
            end

            # Handles descriptors with both prefix and handler
            def resolve_prefixed_message(descriptor)
              message = invoke_handler(descriptor)
              return nil unless message

              "#{descriptor.prefix}#{message}"
            end

            # Handles core default descriptors (no prefix, no handler)
            def resolve_core_default_message(descriptor)
              exception&.message
            end

            # Handles standard descriptors (with handler, no prefix)
            def resolve_standard_message(descriptor)
              invoke_handler(descriptor)
            end

            # Invokes the handler to get the raw message content
            def invoke_handler(descriptor)
              handler = descriptor&.handler
              return if handler.nil?

              Invoker.call(operation: "determining message callable", action:, handler:, exception:).presence
            end
          end
        end
      end
    end
  end
end
