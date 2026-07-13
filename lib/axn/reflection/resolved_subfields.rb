# frozen_string_literal: true

require "axn/reflection/subfield_tree"
require "axn/reflection/schema"

module Axn
  module Reflection
    # The canonical resolved-subfield artifact (PRO-2883): the SubfieldTree plus its derived
    # `{required, nullable}` annotations, built once from a class's declared configs and cached per
    # class (see ContractForSubfields::ClassMethods#_resolved_subfields). Deep-frozen before it is
    # published, so the runtime hot path can never mutate it — and a benign first-call build race
    # between threads just produces two identical values.
    ResolvedSubfields = Data.define(:tree, :annotations) do
      def self.build(field_configs, subfield_configs)
        tree = SubfieldTree.build(field_configs, Array(subfield_configs))
        annotations = Schema.derive_annotations(tree.roots)
        _deep_freeze!(tree)
        new(tree:, annotations: annotations.freeze)
      end

      def self._deep_freeze!(tree)
        tree.roots.each_value { |node| _freeze_node!(node) }
        tree.roots.freeze
        tree.dropped.freeze
        tree.index.each_value do |path|
          path.wire_path.freeze
          path.ancestors.each(&:freeze)
          path.ancestors.freeze
        end
        tree.index.freeze
      end

      def self._freeze_node!(node)
        node.configs.freeze
        node.children.each_value { |child| _freeze_node!(child) }
        node.children.freeze
      end

      # Convenience delegators for the tree's members.
      def roots = tree.roots
      def dropped = tree.dropped
      def index = tree.index
    end
  end
end
