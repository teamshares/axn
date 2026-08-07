# frozen_string_literal: true

module Axn
  module Internal
    # Groups an Axn's subfield configs into per-root trees keyed by WIRE KEY (the JSON property name
    # a client sends), resolving each config's `on:` chain once. Emission, requiredness derivation,
    # and the dropped-subfield query all read the same finished tree, so they cannot drift.
    #
    # `on:` names a READER (`reader_as` — the `as:`/`prefix:` alias when present); schema properties
    # are keyed by wire key (`field`). This builder is the single place that translation happens: the
    # root `on:` segment resolves through the reader-owner index (reader_owners) to the config that
    # answers to that name — whichever tier declared it, and wherever in the file — and the config
    # attaches beneath that config's own resolved node. Remaining dotted `on:` segments become IMPLICIT
    # nodes — intermediate keys with no declaration of their own.
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
      # [field], ancestors are empty, parent_index 0, and `node` is its own root node — the one the
      # `roots` map holds under its reader name unless it yields that name (see build).
      ResolvedPath = Data.define(:node, :wire_path, :ancestors, :parent_index) do
        # The `on:`-target Node (the config's immediate parent in contract terms). A field name is a
        # single wire key, so the leaf sits DIRECTLY under this node — it is also the leaf's wire parent,
        # and its wire key is `config.field`.
        def parent_node = ancestors[parent_index].first
      end

      # The finished build: per-root node trees, the deep `[config, hops]` pairs whose representability is
      # the reflection layer's to judge, the per-config ResolvedPath index, and the reader-owner index.
      # (Named to be unmistakable next to the public Axn::Result.)
      ResolutionResult = Data.define(:roots, :deep_paths, :index, :reader_owners)

      module_function

      def build(field_configs, subfield_configs)
        roots = {}
        # reader name => the config whose generated reader ANSWERS to it (see reader_owners).
        owners = {}
        # config => ResolvedPath, identity-keyed: distinct declarations are distinct entries even if
        # they compare equal as Data values.
        index = {}.compare_by_identity
        field_configs.each do |config|
          node = Node.new(configs: [config], children: {})
          # `roots` is the TOP-LEVEL node forest — what the annotation and contradiction walks iterate — so a
          # config that yields its name to another TOP-LEVEL one is absent (that name's forest entry is the
          # owner's). It still has a position of its own — this node — and it is the one the index records: a
          # consumer resolving THIS config (the property it emits, the nil-tolerance asked of it) must see its
          # own children, none of which the yielded name's declaration can supply, since a subfield `on:` that
          # name anchors on the owner instead. A name a SUBFIELD takes over keeps its node here: the forest
          # is every top-level node, and `on:` resolution reads the owner index rather than this map.
          roots[config.reader_as.to_sym] = node if claim_reader!(owners, config)
          index[config] = ResolvedPath.new(node:, wire_path: [config.field], ancestors: [], parent_index: 0)
        end

        subfields = Array(subfield_configs)
        # Every name is claimed before ANY anchor is resolved, so an anchor reads the same FINISHED map
        # declaration-time consumers get from `reader_owners` — which this is, claim for claim, in the same
        # order over the same configs. Resolving each anchor as the walk reaches it would instead anchor on
        # whoever holds the name at that point in the file, so a name an inferred companion holds until a
        # later declaration takes it over would put one contract on a different wire path in each order.
        subfields.each { |config| claim_reader!(owners, config) }

        deep_paths = [] # [config, hops] judged only once the tree is COMPLETE (an ancestor's type may be declared after the deep config)
        # Attaching under an anchor needs the anchor's own position, so an anchor that is itself a subfield
        # is attached first — on demand, since the config that owns a name may be declared after the config
        # anchoring on it. `chain` is the anchor chain currently being resolved, reused across the walk.
        chain = []
        subfields.each { |config| attach_subfield!(config, owners:, index:, deep_paths:, chain:) }

        ResolutionResult.new(roots:, deep_paths:, index:, reader_owners: owners)
      end

      # Resolves one subfield's anchor and attaches it beneath the anchor's node, attaching an anchor whose
      # own position isn't resolved yet first. Records the result in `index`, which is also the
      # already-placed check: a config reached twice (as its own anchor's anchor, or as two configs' anchor)
      # is placed once.
      def attach_subfield!(config, owners:, index:, deep_paths:, chain:)
        return if index.key?(config)

        # Re-entered while its own anchor is still resolving: the `on:` chain leads back here, so no config on
        # it names a wire path to read from. Identity, not `==`: two declarations can compare equal as Data
        # values without being the same declaration.
        raise_circular_anchor!(chain, config) if chain.any? { |c| c.equal?(config) }

        chain.push(config)
        begin
          root_key, *on_rest = config.on.to_s.split(".").map(&:to_sym)
          # `on:` names a READER, so the anchor is the config that OWNS the name and the position is that
          # config's own — the two questions the owner index and the ResolvedPath index answer, asked once
          # each rather than re-derived per tier.
          owner = owners[root_key]
          attach_subfield!(owner, owners:, index:, deep_paths:, chain:) if owner&.subfield?
          anchor = index[owner]
          # Only a bare `on: :ambient_context` with no declared ambient field lands here — deliberately
          # excluded from the schema (EXCLUDED_FROM_INPUT_SCHEMA), so it is neither attached nor dropped.
          # Anything anchored ON such a config inherits the exclusion the same way.
          return if anchor.nil?

          segments = on_rest + config.field.to_s.split(".").map(&:to_sym)
          leaf, hops = attach_config!(config, anchor.node, anchor.ancestors, segments)

          # The chain always starts at a top-level root (an anchored subfield's hops were themselves
          # rooted there), so the first hop's node carries the root's wire key. The `on:` target sits
          # after the anchor chain plus any dotted-`on:` segments (the config's own field segments
          # descend BELOW it).
          index[config] = ResolvedPath.new(node: leaf, wire_path: [hops.first.first.config.field, *hops.map(&:last)],
                                           ancestors: hops, parent_index: anchor.ancestors.size + on_rest.size)

          # Shallow (single hop off a top-level root) configs are always representable; only deeper
          # paths are candidates for dropping.
          deep_paths << [config, hops] if hops.size > 1
        ensure
          chain.pop
        end
      end

      # A loop of `on:` anchors, reported at the declaration that closes it (the tree is built by the
      # declaration-time contradiction check). Building one takes a name an inferred confirmation companion
      # holds and a later subfield declaration takes over: without a name changing hands, an `on:` root must
      # already be declared to pass the missing-reader check and can never be re-pointed, so every chain ends
      # at a top-level field. Rejected rather than left out of the tree, because a config with no resolved
      # position falls back to resolving `on:` by reader dispatch at runtime — which around a loop is each
      # member calling the next until the stack runs out.
      def raise_circular_anchor!(chain, config)
        loop_start = chain.index { |c| c.equal?(config) }
        route = chain[loop_start..].map { |c| "#{c.field.inspect} (on: #{c.on.inspect})" }.join(" -> ")
        raise ArgumentError,
              "circular on: chain: #{route} -> #{config.field.inspect}. Each of these is declared on a reader the " \
              "next one owns, so the chain never reaches a top-level field and none of them names a value to read " \
              "from. Anchor one of them on a field declared outside the loop."
      end

      # THE index of "which config answers to this reader NAME" — reader name (Symbol) => that config.
      # A reader name is one namespace across both tiers (Contract#_validate_reader_names! enforces
      # uniqueness over top-level and subfield configs together), so one map covers both: `on:` anchors,
      # Symbol gate references in schema reflection, ambient rooting and the collision check all ask the
      # same question and must get the same answer.
      #
      # Distinct from "which node/method belongs to THIS config" — that is identity, answered by the
      # ResolvedPath index (a config that yields its name still holds a node) and, against a live class,
      # by Contract#_reader_deferred?. Conflating the two is what lets a name claimed by one declaration
      # and yielded by another resolve to whichever config happens to be found first.
      #
      # Declaration order cannot change the result: the only pairing that puts two configs on one name is
      # an inferred confirmation companion beside a declaration of that name, and the companion always
      # yields (yields_reader_name?) — so the declaration wins whichever side of it the companion sits on.
      def reader_owners(field_configs, subfield_configs)
        owners = {}
        Array(field_configs).each { |config| claim_reader!(owners, config) }
        Array(subfield_configs).each { |config| claim_reader!(owners, config) }
        owners
      end

      # Records `config` as the owner of its reader name unless it yields that name to the config already
      # holding it; answers whether it claimed the name. The one place the rule is applied, so the map the
      # tree builds as it walks and the map `reader_owners` folds are the same map.
      def claim_reader!(owners, config)
        name = config.reader_as.to_sym
        return false if yields_reader_name?(config, owners.key?(name))

        owners[name] = config
        true
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
