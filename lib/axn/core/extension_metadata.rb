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
          (_axn_extension_metadata[adapter.to_sym] || {}).dup
        end

        # Copy-on-write: never mutate the inherited Hash in place (class_attribute shares the
        # object reference with the parent until reassigned) — merge into a fresh Hash and reassign.
        def set_extension_metadata(adapter, **kwargs)
          adapter = adapter.to_sym
          merged = (_axn_extension_metadata[adapter] || {}).merge(kwargs)
          self._axn_extension_metadata = _axn_extension_metadata.merge(adapter => merged)
        end
      end
    end
  end
end
