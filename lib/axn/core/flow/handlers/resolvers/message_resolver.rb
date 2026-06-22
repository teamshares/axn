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

              # The base headline is a static (unconditional), non-prefixed entry with a LITERAL
              # handler. A dynamic handler (block/symbol) is always a reason — even unconditional
              # and even with prefixed: false — so it must not be mistaken for the base.
              # Applies to both :error and :success events.
              @base_descriptor = candidate_entries.detect { |d| d.static? && !d.prefixed? && d.handler && !d.dynamic_handler? }
            end

            def base?(descriptor) = base_descriptor && descriptor.equal?(base_descriptor)

            # A "reason" is a non-base entry eligible to be selected as the displayed message.
            # When a base exists: only prefixed? or conditional (non-static) entries qualify —
            # additional plain-static non-prefixed entries are "secondary bases" and excluded.
            # When no base exists: all non-base entries qualify (standard fallback behavior).
            def reason?(descriptor)
              return false if base?(descriptor)
              return true unless base_descriptor

              # With a base declared, a reason is any prefixed, conditional, or dynamic entry.
              # Only secondary plain-static *literal* non-prefixed entries (extra headlines) are excluded.
              descriptor.prefixed? || !descriptor.static? || descriptor.dynamic_handler?
            end

            # NOTE: no `.presence` — an explicit `delimiter: ""` is honored (join with no separator);
            # only an unset (nil) delimiter falls back to the default.
            def delimiter = base_descriptor&.delimiter || ": "

            def body_for(descriptor)
              return nil unless descriptor

              if descriptor.handler
                Invoker.call(operation: "determining message callable", action:, handler: descriptor.handler, exception:).presence
              elsif exception
                exception.message.presence
              end
            end

            def fallback_message = event_type == :success ? DEFAULT_SUCCESS : DEFAULT_ERROR
          end
        end
      end
    end
  end
end
