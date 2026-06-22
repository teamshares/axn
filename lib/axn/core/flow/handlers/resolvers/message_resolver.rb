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
              # Candidates are non-base entries that are either prefixed (conditional/dynamic reasons)
              # or conditional (prefixed: false opt-out). Plain static non-prefixed entries are treated
              # as additional bases and excluded here; the declared base wins via base_message.
              descriptor = matching_entries.detect { |d| reason?(d) && body_for(d).present? }
              return base_message || fallback_message unless descriptor

              reason = body_for(descriptor)
              descriptor.prefixed? ? with_base_prefix(reason) : reason
            end

            def resolve_default_message = base_message || fallback_message

            # Prefix an externally-supplied reason (e.g. a fail!/done! message) with the base.
            def with_base_prefix(reason)
              return reason unless base_message.present?

              "#{base_message}#{delimiter}#{reason}"
            end

            def base_message
              return @base_message if defined?(@base_message)

              @base_message = base_descriptor ? body_for(base_descriptor) : nil
            end

            private

            def base_descriptor
              return @base_descriptor if defined?(@base_descriptor)

              # Base-prefix only applies to error messages; success messages have no base concept.
              @base_descriptor =
                (candidate_entries.detect { |d| d.static? && !d.prefixed? && d.handler } if event_type == :error)
            end

            def base?(descriptor) = base_descriptor && descriptor.equal?(base_descriptor)

            # A "reason" is a non-base entry eligible to be selected as the displayed message.
            # When a base exists: only prefixed? or conditional (non-static) entries qualify —
            # additional plain-static non-prefixed entries are "secondary bases" and excluded.
            # When no base exists: all non-base entries qualify (standard fallback behavior).
            def reason?(descriptor)
              return false if base?(descriptor)
              return true unless base_descriptor

              # With a base declared, exclude secondary plain-static non-prefixed entries.
              descriptor.prefixed? || !descriptor.static?
            end

            def delimiter = base_descriptor&.delimiter.presence || ": "

            def body_for(descriptor)
              return nil unless descriptor

              raw =
                if descriptor.handler
                  Invoker.call(operation: "determining message callable", action:, handler: descriptor.handler, exception:).presence
                elsif exception
                  exception.message
                elsif descriptor.prefix
                  # For prefix-only messages without an exception, fall back to the default static handler.
                  # Retained for Phase A/B coexistence; removed in Phase C.
                  if default_static_handler
                    Invoker.call(operation: "determining message callable", action:, handler: default_static_handler,
                                 exception:).presence
                  end
                end
              return nil unless raw.present?

              # Per-message prefix:, retained for Phase A coexistence; removed in Phase C.
              "#{resolved_prefix(descriptor)}#{raw}"
            end

            def default_static_handler
              return @default_static_handler if defined?(@default_static_handler)

              @default_static_handler = candidate_entries.detect { |d| d.static? && d.handler && !d.equal?(base_descriptor) }&.handler
            end

            def resolved_prefix(descriptor)
              return nil unless descriptor.prefix
              return descriptor.prefix if descriptor.prefix.is_a?(String)

              Invoker.call(action:, handler: descriptor.prefix, exception:, operation: "determining prefix callable")
            rescue StandardError
              nil
            end

            def fallback_message = event_type == :success ? DEFAULT_SUCCESS : DEFAULT_ERROR
          end
        end
      end
    end
  end
end
