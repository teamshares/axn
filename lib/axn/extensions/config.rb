# frozen_string_literal: true

module Axn
  module Extensions
    class Config
      def registered_field_metadata_keys
        @registered_field_metadata_keys ||= Set.new([:description])
      end

      def register_field_metadata_key(*keys)
        keys = keys.map(&:to_sym)
        _reject_reserved_field_metadata_keys!(keys)

        registered_field_metadata_keys.merge(keys)
      end

      def registered_semantic_hints
        @registered_semantic_hints ||= Set.new(%i[read_only idempotent destructive])
      end

      def register_semantic_hint(*hints)
        registered_semantic_hints.merge(hints.map(&:to_sym))
      end

      private

      # A registered key is routed OUT of a declaration's validations by `_partition_field_options`, so a
      # gem claiming a core option name silently changes what that option means — and which meaning applies
      # depends on which extensions happened to initialize. Refused here, where the mistake is made, rather
      # than at each declaration that trips over it (which could not name the gem responsible either).
      #
      # Checked across the whole call before the merge, not per key during it, so a call naming one good key
      # and one reserved one registers NEITHER — the validate-then-mutate ordering `expects` uses, so a
      # rescued registration leaves no half-applied bag behind.
      #
      # `Axn::Core::Contract` is named from inside the body rather than required at the top: `lib/axn.rb`
      # loads this file ahead of `axn/core`, and a require here would close the loop the other way. Every
      # caller registers at gem-load, long after `require "axn"` has returned.
      def _reject_reserved_field_metadata_keys!(keys)
        reserved = keys.uniq.select { |key| Axn::Core::Contract.reserved_field_option_names.include?(key) }
        return if reserved.empty?

        raise ArgumentError,
              "Cannot register #{reserved.map(&:inspect).join(', ')} as field metadata: " \
              "#{reserved.size == 1 ? 'it is a core field DSL option' : 'they are core field DSL options'}. " \
              "A registered key is routed out of a declaration's validations, so `expects :x, #{reserved.first}: ...` " \
              "would stop meaning what the DSL defines it to mean. Register a key the core DSL does not own, " \
              "conventionally namespaced to your gem (e.g. `:mcp_title`)."
      end
    end
  end
end
