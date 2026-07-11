# frozen_string_literal: true

module Axn
  module Reflection
    # Groups an Axn's subfield configs into per-root trees keyed by WIRE KEY (the JSON property name
    # a client sends), resolving each config's `on:` chain once. Emission, requiredness derivation,
    # and the dropped-subfield query all read the same finished tree, so they cannot drift.
    #
    # `on:` names a READER (`reader_as` — the `as:`/`prefix:` alias when present); schema properties
    # are keyed by wire key (`field`). This builder is the single place that translation happens: the
    # root `on:` segment is looked up among top-level readers first, then subfield readers (a subfield
    # anchor attaches the config beneath that subfield's own resolved node). Remaining dotted `on:`
    # segments and any dotted prefix of the field name become IMPLICIT nodes — intermediate keys with
    # no declaration of their own.
    #
    # Side-effect-free: inspects declared configs only; never runs user code.
    module SubfieldTree
      # `configs` is empty for an implicit node. Multiple configs on one node means the same wire
      # path was declared via two routes (e.g. `expects "bar.baz", on: :foo` and `expects :baz,
      # on: :bar`); runtime validates each independently, so consumers must honor all of them.
      Node = Data.define(:configs, :children) do
        def config = configs.first
        def implicit? = configs.empty?
      end

      Result = Data.define(:roots, :dropped)

      module_function

      def build(field_configs, subfield_configs)
        roots = field_configs.to_h { |c| [c.reader_as, Node.new(configs: [c], children: {})] }
        by_reader = {} # subfield reader_as => {node:, hops:} — anchor targets for a subfield-of-a-subfield
        deep_paths = [] # [config, hops] judged only once the tree is COMPLETE (an ancestor's type may be declared after the deep config)

        Array(subfield_configs).each do |config|
          root_key, *on_rest = config.on.to_s.split(".").map(&:to_sym)
          anchor_hops = []
          anchor = roots[root_key]
          if anchor.nil? && (entry = by_reader[root_key])
            anchor_hops = entry[:hops]
            anchor = entry[:node]
          end
          # Only a bare `on: :ambient_context` with no declared ambient field lands here — deliberately
          # excluded from the schema (EXCLUDED_FROM_INPUT_SCHEMA), so it is neither attached nor dropped.
          next if anchor.nil?

          segments = on_rest + config.field.to_s.split(".").map(&:to_sym)
          hops = anchor_hops.dup
          node = anchor
          segments[0..-2].each do |seg|
            hops << [node, seg]
            node = (node.children[seg] ||= Node.new(configs: [], children: {}))
          end
          leaf_key = segments.last
          hops << [node, leaf_key]
          leaf = (node.children[leaf_key] ||= Node.new(configs: [], children: {}))
          leaf.configs << config

          # Only a non-dotted field name gets a real reader method, so only it can anchor a later
          # `on:` (see ContractForSubfields#_define_subfield_reader).
          by_reader[config.reader_as.to_sym] = { node: leaf, hops: } unless config.field.to_s.include?(".")
          # Shallow (single hop off a top-level root) configs are always representable; only deeper
          # paths are candidates for dropping.
          deep_paths << [config, hops] if hops.size > 1
        end

        Result.new(roots:, dropped: compute_dropped(deep_paths))
      end

      # A deep config is dropped when any node it passes THROUGH (each hop's parent; never the leaf
      # itself) can't hold JSON object properties. Judged on the finished tree so declaration order
      # doesn't matter.
      def compute_dropped(deep_paths)
        deep_paths.filter_map do |config, hops|
          config if path_blocked?(hops)
        end
      end

      # Walk a deep config's ancestor chain hop by hop, carrying the shape member an implicit hop merged
      # into so a deeper implicit hop can test that member's OWN nested shape members (a
      # member-of-a-member). `carried` is the object-shaped member config the current node stands in for
      # (nil for a real node or a fresh implicit intermediate that claimed no shape member).
      def path_blocked?(hops)
        carried = nil
        hops.each do |node, key|
          return true if blocking_ancestor?(node, key, carried)

          carried = merged_shape_member(node, key, carried)
        end
        false
      end

      # An explicit ancestor blocks nesting when it has `model:` (the client sends `<field>_id`, not
      # the object) or isn't nestable as an object (non-object type, or a mixed union). An implicit
      # ancestor never blocks on its own type — but descending into an IMPLICIT child whose key collides
      # with a non-object `shape:` member does: the member property already claims that key with a
      # non-object type, so the deep structure has nowhere to live. Those members come from the node's
      # own explicit configs OR the member this implicit node merged into (`carried`), so a member of a
      # member is tested at depth.
      def blocking_ancestor?(node, key, carried = nil)
        return true if node.configs.any? { |c| c.validations[:model] || !Schema.nestable_as_object?(c) }
        return false unless node.children[key]&.implicit?

        shape_member_configs(node, carried).any? do |c|
          member = shape_member_at(c, key)
          member && !Schema.nestable_as_object?(member)
        end
      end

      # The object-shaped shape member a node (via an explicit config or the `carried` member it merged
      # into) declares at `key`, when descending merges an implicit child there — carried into the next
      # hop. nil when nothing merges (no such member; a non-nestable member would already have blocked).
      def merged_shape_member(node, key, carried)
        return nil unless node.children[key]&.implicit?

        shape_member_configs(node, carried).filter_map { |c| shape_member_at(c, key) }
                                           .find { |m| Schema.nestable_as_object?(m) }
      end

      def shape_member_configs(node, carried)
        carried ? node.configs + [carried] : node.configs
      end

      def shape_member_at(config, key)
        Array(config.validations.dig(:shape, :members)).find { |m| m.field.to_sym == key }
      end
    end
  end
end
