# frozen_string_literal: true

module Axn
  module Core
    # `ambient_context` is a reserved, always-present parent on every Axn. Its reader returns a Hash
    # ({} by default) that subfields extract from via `expects :x, on: :ambient_context`. Reads are
    # declaration-gated (a reader exists only for declared subfields), and the hash is filtered to the
    # declared ambient keys (Task 9) so it never carries a merged dump of process-wide Current state.
    module AmbientContext
      PARENT = :ambient_context

      # Instance reader used by ContractForSubfields.resolve_parent (public_send(:ambient_context)).
      def ambient_context
        return @__ambient_context if defined?(@__ambient_context)

        @__ambient_context = _resolve_ambient_context
      end

      private

      # Overridden in Task 9 with the full explicit → provider → {} resolution + declared-only filter.
      def _resolve_ambient_context
        _explicit_ambient_context || {}
      end

      def _explicit_ambient_context
        raw = @__context.provided_data
        key = raw.respond_to?(:with_indifferent_access) ? raw.with_indifferent_access : raw
        key[PARENT]
      end
    end
  end
end
