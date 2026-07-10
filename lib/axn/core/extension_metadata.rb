# frozen_string_literal: true

module Axn
  module Core
    # A per-adapter, inherited, copy-on-write metadata bag. Adapters register transport-specific
    # DSL (via Axn::Configurable#overrides) and stash resolved config here for `wrap` to read.
    module ExtensionMetadata
      def self.included(base)
        base.class_eval do
          class_attribute :_axn_extension_metadata, instance_accessor: false, default: {}
          extend ClassMethods
        end
      end

      module ClassMethods
        def extension_metadata(adapter)
          _deep_dup_containers(_axn_extension_metadata[adapter.to_sym] || {})
        end

        # Copy-on-write: never mutate the inherited Hash in place (class_attribute shares the
        # object reference with the parent until reassigned) — merge into a fresh Hash and reassign.
        def set_extension_metadata(adapter, **kwargs)
          adapter = adapter.to_sym
          merged = (_axn_extension_metadata[adapter] || {}).merge(kwargs)
          self._axn_extension_metadata = _axn_extension_metadata.merge(adapter => merged)
        end

        # Deep-copies Hash/Array container structure, plus mutable String leaf VALUES, so a caller
        # mutating the returned metadata (or a nested Hash/Array/String value within it) can't leak into
        # the stored copy or into subclasses. Hash KEYS need no copying: Ruby dups-and-freezes a String
        # key on insertion, so the shared key can't be mutated in place (and re-inserting a dup would just
        # freeze it again). Deliberately NOT Marshal/ActiveSupport#deep_dup: metadata values can be Class
        # references or Procs, which must stay shared by identity, not be cloned.
        def _deep_dup_containers(obj)
          case obj
          when Hash then obj.transform_values { |v| _deep_dup_containers(v) }
          when Array then obj.map { |v| _deep_dup_containers(v) }
          when String then obj.dup
          else obj
          end
        end
      end
    end
  end
end
