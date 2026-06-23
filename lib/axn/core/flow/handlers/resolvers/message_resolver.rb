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
              # Pick the winning reason (a conditional or explicitly-prefixed entry); unconditional
              # non-prefixed entries are headlines, excluded here and surfaced via base_message.
              # filter_map captures each body once (body_for invokes the handler block), so the winning
              # entry's message block runs a single time rather than twice.
              descriptor, reason = matching_entries.lazy.filter_map do |d|
                next unless reason?(d)

                body = body_for(d)
                [d, body] if body.present?
              end.first
              return base_message || fallback_message unless descriptor

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

              # Headlines form a fallback chain (most-recent first — see Registry): use the first whose
              # body resolves to something present, so a headline whose block raises or returns blank
              # falls back to an earlier one rather than to the generic default.
              @base_message = base_candidates.lazy.filter_map { |d| body_for(d) }.first
            end

            private

            # Unconditional, non-prefixed entries with a handler — the headline candidates. The handler
            # kind (literal/block/symbol) is irrelevant; only conditionality + prefixed: decide the role.
            # Applies to both :error and :success events.
            def base_candidates = candidate_entries.select { |d| d.static? && !d.prefixed? && d.handler }

            # The base headline for delimiter + identity purposes: the most-recently declared one.
            def base_descriptor
              return @base_descriptor if defined?(@base_descriptor)

              @base_descriptor = base_candidates.first
            end

            # A "reason" is an entry eligible to be selected as the displayed message: a conditional
            # entry (if:/unless:) or one explicitly `prefixed:`. Unconditional non-prefixed entries are
            # headlines (the base + any secondary headlines) — surfaced via base_message, never selected
            # here. When no base exists, every entry is conditional/prefixed, so all qualify.
            def reason?(descriptor)
              return true unless base_descriptor

              descriptor.prefixed? || !descriptor.static?
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
