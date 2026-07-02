# frozen_string_literal: true

module Axn
  class ExtensionConfig
    def registered_field_metadata_keys
      @registered_field_metadata_keys ||= Set.new([:description])
    end

    def register_field_metadata_key(*keys)
      registered_field_metadata_keys.merge(keys.map(&:to_sym))
    end

    def registered_semantic_hints
      @registered_semantic_hints ||= Set.new(%i[read_only idempotent destructive])
    end

    def register_semantic_hint(*hints)
      registered_semantic_hints.merge(hints.map(&:to_sym))
    end
  end
end
