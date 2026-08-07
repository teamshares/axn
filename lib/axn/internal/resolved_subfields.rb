# frozen_string_literal: true

require "axn/internal/subfield_tree"
require "axn/internal/reflection/schema"

module Axn
  module Internal
    # The canonical resolved-subfield artifact (PRO-2883): the SubfieldTree plus its derived
    # `{required, nullable}` annotations and its dropped-deep-config verdict, built once from a class's
    # declared configs and cached per class (see ContractForSubfields::ClassMethods#_resolved_subfields).
    # Both annotations and dropped are Reflection::Schema's judgment over the tree, composed in here so
    # `Core::` reads either as a cheap reader on the runtime path rather than recomputing it. Deep-frozen
    # before it is published, so the runtime hot path can never mutate it — and a benign first-call build
    # race between threads just produces two identical values.
    ResolvedSubfields = Data.define(:tree, :annotations, :dropped) do
      def self.build(field_configs, subfield_configs)
        tree = SubfieldTree.build(field_configs, Array(subfield_configs))
        annotations = Reflection::Schema.derive_annotations(tree.roots)
        dropped = Reflection::Schema.dropped_from_deep_paths(tree.deep_paths)
        _deep_freeze!(tree)
        new(tree:, annotations: annotations.freeze, dropped: dropped.freeze)
      end

      def self._deep_freeze!(tree)
        tree.roots.each_value { |node| _freeze_node!(node) }
        tree.roots.freeze
        tree.deep_paths.freeze
        tree.index.each_value do |path|
          # A top-level config that yields its reader name holds a node of its own, off the roots map
          # (SubfieldTree.build) — the index is the only route to it, so freezing walks from here too.
          _freeze_node!(path.node)
          path.wire_path.freeze
          path.ancestors.each(&:freeze)
          path.ancestors.freeze
        end
        tree.index.freeze
        tree.reader_owners.freeze
      end

      def self._freeze_node!(node)
        node.configs.freeze
        node.children.each_value { |child| _freeze_node!(child) }
        node.children.freeze
      end

      # Both are reached only from `build` above — freezing a tree that is already published would be a
      # bug, not an entry point.
      private_class_method :_deep_freeze!, :_freeze_node!

      # Convenience delegators for the tree's members. `dropped` is its own Data member (above), not a
      # delegator: the tree only collects the deep candidate pairs (`deep_paths`), and the drop verdict
      # is what this artifact composes in on top, once, at build time.
      def roots = tree.roots
      def index = tree.index
    end
  end
end
