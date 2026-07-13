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

      # A config's resolved position in the tree, recorded once at build so runtime consumers never
      # re-split `on:` strings or re-resolve reader aliases. `node` is the config's leaf Node;
      # `wire_path` is the full provided_data write path ([top-level wire key, *wire segments]);
      # `ancestors` is the hop chain ([Node, wire segment] pairs, outermost first — each hop's node is
      # the parent the segment is read from), so chain-aware write-backs can gate materialization on
      # every intermediate node's own declared type. A top-level config is the depth-0 case: its
      # wire_path is just [field] and its ancestors are empty.
      ResolvedPath = Data.define(:node, :wire_path, :ancestors)

      Result = Data.define(:roots, :dropped, :index)

      module_function

      def build(field_configs, subfield_configs)
        roots = field_configs.to_h { |c| [c.reader_as, Node.new(configs: [c], children: {})] }
        # config => ResolvedPath, identity-keyed: distinct declarations are distinct entries even if
        # they compare equal as Data values.
        index = {}.compare_by_identity
        field_configs.each { |c| index[c] = ResolvedPath.new(node: roots[c.reader_as], wire_path: [c.field], ancestors: []) }
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
          leaf, hops = attach_config!(config, anchor, anchor_hops, segments)

          # The chain always starts at a top-level root (an anchored subfield's hops were themselves
          # rooted there), so the first hop's node carries the root's wire key.
          index[config] = ResolvedPath.new(node: leaf, wire_path: [hops.first.first.config.field, *hops.map(&:last)], ancestors: hops)

          # Only a non-dotted field name gets a real reader method, so only it can anchor a later
          # `on:` (see ContractForSubfields#_define_subfield_reader).
          by_reader[config.reader_as.to_sym] = { node: leaf, hops: } unless config.field.to_s.include?(".")
          # Shallow (single hop off a top-level root) configs are always representable; only deeper
          # paths are candidates for dropping.
          deep_paths << [config, hops] if hops.size > 1
        end

        Result.new(roots:, dropped: compute_dropped(deep_paths), index:)
      end

      # Walk (creating implicit intermediates as needed) from `anchor` down `segments`, attach the
      # config at the leaf, and return [leaf, hops].
      def attach_config!(config, anchor, anchor_hops, segments)
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
        [leaf, hops]
      end

      # A deep config is dropped when a node it passes THROUGH (each hop's parent; never the leaf itself)
      # can't hold JSON object properties. Judged on the finished tree so declaration order doesn't matter.
      def compute_dropped(deep_paths)
        deep_paths.filter_map { |config, hops| config if path_blocked?(hops) }
      end

      # Walk a deep config's ancestor chain hop by hop, carrying the shape members an implicit hop merged
      # into so a deeper implicit hop can test their OWN nested shape members (a member-of-a-member).
      # `carried` is the object-shaped member configs the current node stands in for (empty for a real
      # node or a fresh implicit intermediate that claimed no shape member).
      def path_blocked?(hops)
        carried = []
        hops.each do |node, key|
          return true if blocking_ancestor?(node, key, carried)

          carried = merged_shape_members(node, key, carried)
        end
        false
      end

      # An explicit ancestor blocks nesting when its configs forbid it (a `model:` route, or a non-object /
      # mixed-union type on any route) — the SAME predicate emission gates on (Schema.node_configs_block_nesting?),
      # so the drop pass and the schema agree. An implicit ancestor never blocks on its own type — but
      # descending into an IMPLICIT child whose key collides with a non-object `shape:` member does: the
      # member property already claims that key with a non-object type, so the deep structure has nowhere to
      # live. Those members come from the node's own explicit configs AND every member this implicit node
      # merged into (`carried`), so a member of a member is tested at depth.
      def blocking_ancestor?(node, key, carried = [])
        return true if Schema.node_configs_block_nesting?(node.configs)
        return false unless node.children[key]&.implicit?

        colliding_shape_members(node, key, carried).any? { |m| !Schema.nestable_as_object?(m) }
      end

      # The object-shaped shape members a node (via its explicit configs or the `carried` members it merged
      # into) declares at `key`, when descending merges an implicit child there — carried into the next
      # hop. Empty when nothing merges. ALL nestable colliding members are carried (not just the first), so
      # a deeper hop tests every route's nested member; a non-nestable one would already have blocked. This
      # mirrors emission's apply_implicit_node!, which carries every colliding member.
      def merged_shape_members(node, key, carried)
        return [] unless node.children[key]&.implicit?

        colliding_shape_members(node, key, carried).select { |m| Schema.nestable_as_object?(m) }
      end

      # Every `shape:` member declared at `key` across the node's own configs AND the members carried from
      # a shallower hop — via Schema.shape_members_at, the same locator emission uses, so the two sides
      # can't disagree on which members collide with the implicit child at `key`.
      def colliding_shape_members(node, key, carried)
        Schema.shape_members_at(node.configs + carried, key)
      end
    end
  end
end
