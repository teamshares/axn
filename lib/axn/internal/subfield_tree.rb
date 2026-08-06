# frozen_string_literal: true

module Axn
  module Internal
    # Groups an Axn's subfield configs into per-root trees keyed by WIRE KEY (the JSON property name
    # a client sends), resolving each config's `on:` chain once. Emission, requiredness derivation,
    # and the dropped-subfield query all read the same finished tree, so they cannot drift.
    #
    # `on:` names a READER (`reader_as` — the `as:`/`prefix:` alias when present); schema properties
    # are keyed by wire key (`field`). This builder is the single place that translation happens: the
    # root `on:` segment is looked up among top-level readers first, then subfield readers (a subfield
    # anchor attaches the config beneath that subfield's own resolved node). Remaining dotted `on:`
    # segments become IMPLICIT nodes — intermediate keys with no declaration of their own.
    #
    # Side-effect-free: inspects declared configs only; never runs user code.
    module SubfieldTree
      # `configs` is empty for an implicit node. Multiple configs on one node means the same wire
      # path was declared via two routes (e.g. `expects :baz, on: "foo.bar"` and `expects :baz,
      # on: :bar` where `bar` is itself a subfield of `foo`); runtime validates each independently, so
      # consumers must honor all of them.
      Node = Data.define(:configs, :children) do
        def config = configs.first
        def implicit? = configs.empty?
      end

      # A config's resolved position in the tree, recorded once at build so runtime consumers never
      # re-split `on:` strings or re-resolve reader aliases. `node` is the config's leaf Node;
      # `wire_path` is the full provided_data lookup path ([top-level wire key, *wire segments]);
      # `ancestors` is the hop chain ([Node, wire segment] pairs, outermost first — each hop's node is
      # the parent the segment is read from), so canonical parent resolution (resolve_parent) can walk
      # each hop through its own reader and reflection can reason about each intermediate node's
      # declared type. `parent_index` is the chain index of the `on:` TARGET node (the value the
      # config's own `field` is extracted from), which canonical parent resolution resolves through the
      # deepest reader-bearing ancestor. A top-level config is the depth-0 case: wire_path is just
      # [field], ancestors are empty, parent_index 0.
      ResolvedPath = Data.define(:node, :wire_path, :ancestors, :parent_index) do
        # The `on:`-target Node (the config's immediate parent in contract terms). A field name is a
        # single wire key, so the leaf sits DIRECTLY under this node — it is also the leaf's wire parent,
        # and its wire key is `config.field`.
        def parent_node = ancestors[parent_index].first
      end

      # The finished build: per-root node trees, the deep `[config, hops]` pairs whose representability is
      # the reflection layer's to judge, and the per-config ResolvedPath index. (Named to be unmistakable
      # next to the public Axn::Result.)
      ResolutionResult = Data.define(:roots, :deep_paths, :index)

      module_function

      def build(field_configs, subfield_configs)
        roots = {}
        field_configs.each do |config|
          next if yields_reader_name?(config, roots.key?(config.reader_as))

          roots[config.reader_as] = Node.new(configs: [config], children: {})
        end
        # config => ResolvedPath, identity-keyed: distinct declarations are distinct entries even if
        # they compare equal as Data values.
        index = {}.compare_by_identity
        field_configs.each { |c| index[c] = ResolvedPath.new(node: roots[c.reader_as], wire_path: [c.field], ancestors: [], parent_index: 0) }
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
          # rooted there), so the first hop's node carries the root's wire key. The `on:` target sits
          # after the anchor chain plus any dotted-`on:` segments (the config's own field segments
          # descend BELOW it).
          index[config] = ResolvedPath.new(node: leaf, wire_path: [hops.first.first.config.field, *hops.map(&:last)],
                                           ancestors: hops, parent_index: anchor_hops.size + on_rest.size)

          # Every declared config bears a reader, so any subfield can anchor a later `on:` — except an
          # inferred companion that yields the name to a declaration (see yields_reader_name?).
          reader = config.reader_as.to_sym
          by_reader[reader] = { node: leaf, hops: } unless yields_reader_name?(config, by_reader.key?(reader))
          # Shallow (single hop off a top-level root) configs are always representable; only deeper
          # paths are candidates for dropping.
          deep_paths << [config, hops] if hops.size > 1
        end

        ResolutionResult.new(roots:, deep_paths:, index:)
      end

      # Whether `config` leaves an already-claimed reader name (`taken`) to the config holding it. `on:`
      # names a READER, so the node registered under a name must be the config whose reader ANSWERS to it.
      # Only one pairing can put two configs on one name: an INFERRED confirmation companion beside a
      # declaration of the same name (two declarations collide at declaration time instead). Such a
      # companion's own reader defers to the declaration's — the declaration's is generated first and the
      # companion's is then skipped (Contract#_define_field_readers!) — so the declaration owns the name and
      # is the anchor for it. Registering the companion instead would resolve `on: :<name>` through a config
      # whose reader nothing dispatches to, and which of the two landed under the name would come down to
      # declaration order. Structural rather than a method-table lookup (Contract#_reader_deferred?, the same
      # rule asked of a LIVE class): the tree is built during declaration, before the batch's readers exist,
      # and is cached against the config arrays alone, so it must answer identically on both sides of reader
      # generation.
      def yields_reader_name?(config, taken) = taken && !config.confirmation_for.nil?

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
    end
  end
end
