# frozen_string_literal: true

module Axn
  module Core
    # `ambient_context` is a reserved, always-present parent on every Axn. Its reader returns a Hash
    # ({} by default) that subfields extract from via `expects :x, on: :ambient_context`. Reads are
    # declaration-gated (a reader exists only for declared subfields), and the hash is filtered to the
    # declared ambient keys (Task 9) so it never carries a merged dump of process-wide Current state.
    module AmbientContext
      PARENT = :ambient_context

      # Default ambient-context source: a live view over every registered `ActiveSupport::
      # CurrentAttributes`. Core filters the result down to each Axn's declared ambient keys
      # (see `_filter_to_declared`), so returning everything here is safe — undeclared keys are
      # never readable and never injected.
      def self.default_source
        return {} unless defined?(ActiveSupport::CurrentAttributes)

        ActiveSupport::CurrentAttributes.descendants.each_with_object({}) do |klass, acc|
          # When two CurrentAttributes classes declare the same attribute, last-descendant-wins
          # silently (by design per spec — core filters to declared keys downstream, so undeclared
          # collisions never surface).
          acc.merge!(klass.instance.attributes)
        end
      end

      # Instance reader used by ContractForSubfields.resolve_parent (public_send(:ambient_context)).
      def ambient_context
        return @__ambient_context if defined?(@__ambient_context)

        @__ambient_context = _resolve_ambient_context
      end

      private

      # Resolution chain: explicit `ambient_context:` kwarg, else the configured provider (or
      # `default_source` when no provider is configured), else {}. Explicit REPLACES the provider
      # entirely — no merge. The result is filtered to declared ambient subfield keys.
      def _resolve_ambient_context
        source = _explicit_ambient_context
        source = _provider_source if source.nil?
        source ||= {}
        _filter_to_declared(source)
      end

      def _provider_source
        provider = Axn.config.ambient_context_provider
        provider ? provider.call : Axn::Core::AmbientContext.default_source
      end

      def _explicit_ambient_context
        raw = @__context.provided_data
        key = raw.respond_to?(:with_indifferent_access) ? raw.with_indifferent_access : raw
        key[PARENT]
      end

      # Only the declared ambient subfield keys survive — the hash never carries a process-wide dump.
      # A `model:` subfield may be supplied either as a record (under `c.field`) or as an id (under
      # `<c.field>_id`, which Axn's model subfield reader resolves from) — preserve whichever key(s)
      # the source actually supplies.
      def _filter_to_declared(source)
        indifferent = source.respond_to?(:with_indifferent_access) ? source.with_indifferent_access : source
        self.class.subfield_configs
            .select { |c| c.on.to_sym == PARENT }
            .each_with_object({}) do |c, acc|
              keys = [c.field]
              keys << :"#{c.field}_id" if c.validations[:model]
              keys.each { |k| acc[k] = indifferent[k] if indifferent.key?(k) }
            end
      end
    end
  end
end
