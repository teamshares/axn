# frozen_string_literal: true

require "axn/internal/subfield_tree"
require "axn/internal/reflection/schema/vocabulary"

module Axn
  module Internal
    module Reflection
      module Schema
        # The drop pass: which deep subfield configs have no JSON-object representation because a node their path
        # passes through cannot hold object properties. It asks `Nestability` and `shape_members_at` the same
        # questions emission asks, so a config the document leaves out is exactly one the emitter blocks.
        module DroppedSubfields
          include Vocabulary

          # The subfield configs build_input omits from the input schema: deep configs (a dotted `on:`
          # path, a subfield of a subfield, or a dotted field name) whose chain passes through a `model:`
          # or non-object parent, so they have no JSON-object representation. They validate at runtime but
          # are absent from the schema; a caller can surface this otherwise-silent gap. A representable deep
          # chain (every explicit ancestor object-shaped) is NOT dropped — it nests in the schema.
          # Subfields rooted at a deliberately-excluded parent (EXCLUDED_FROM_INPUT_SCHEMA, e.g.
          # ambient_context) are skipped: their absence is intentional. Side-effect-free (SubfieldTree
          # inspects declared configs only).
          #
          # `resolved:` accepts the per-class ResolvedSubfields cache, whose `dropped` was already computed
          # from the same tree at build time (see ResolvedSubfields.build) — reading it here is a cheap
          # reader, not a recomputation. Without it, both the tree and the verdict are built fresh.
          def dropped_deep_subfields(field_configs, subfield_configs, resolved: nil)
            return resolved.dropped if resolved

            dropped_from_deep_paths(Axn::Internal::SubfieldTree.build(field_configs, Array(subfield_configs)).deep_paths)
          end

          # The judgment over a tree's deep candidates: which of the `[config, hops]` pairs SubfieldTree.build
          # collected (a config reached through more than one hop) have no JSON-object representation. Tree
          # construction only COLLECTS these — whether a chain can hold JSON object properties is a question
          # about what this layer can EMIT, so the two public entry points (this one, and dropped_deep_subfields
          # for a caller that has only configs, not a built tree) both funnel through the same private judgment.
          def dropped_from_deep_paths(deep_paths)
            compute_dropped(deep_paths)
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
          #
          # Public: PropertyNames.emitted_configs asks this at EVERY depth (not just the deep configs
          # compute_dropped reports), because the emitter blocks a property at whichever ancestor blocks it —
          # so property attribution needs the same per-hop answer, not a second predicate that could drift.
          def path_blocked?(hops)
            carried = []
            hops.each do |node, key|
              return true if blocking_ancestor?(node, key, carried)

              carried = merged_shape_members(node, key, carried)
            end
            false
          end

          # An explicit ancestor blocks nesting when its configs forbid it (a `model:` route, or a non-object /
          # mixed-union type on any route) — node_configs_block_nesting? is the single source of truth emission's
          # apply_nested_subfields! gates on too, so the drop pass and the schema agree (they are the same method,
          # not two copies of one rule). An implicit ancestor never blocks on its own type — but descending into
          # an IMPLICIT child whose key collides with a non-object `shape:` member does: the member property
          # already claims that key with a non-object type, so the deep structure has nowhere to live. Those
          # members come from the node's own explicit configs AND every member this implicit node merged into
          # (`carried`), so a member of a member is tested at depth.
          def blocking_ancestor?(node, key, carried = [])
            return true if node_configs_block_nesting?(node.configs)
            return false unless node.children[key]&.implicit?

            colliding_shape_members(node, key, carried).any? { |m| !nestable_as_object?(m) }
          end

          # The shape members a node (via its explicit configs or the `carried` members it merged into) declares
          # at `key` AND the descent merges there — carried into the next hop. Empty when nothing merges.
          #
          # Both kinds of child merge, because emission merges at both: an IMPLICIT child carries every nestable
          # colliding member (a non-nestable one would already have blocked in blocking_ancestor?, so the select
          # is the same all-or-nothing answer stated defensively), and an EXPLICIT child carries whatever
          # merged_explicit_members says it merges — the one predicate apply_children! asks too, so the drop pass
          # and the schema cannot disagree about which members a descent represents.
          # Every route contributes, because every route is ENFORCED and a non-nestable member on any of them must
          # block whether or not it is emitted.
          def merged_shape_members(node, key, carried)
            child = node.children[key]
            return NO_SHAPE_MEMBERS unless child

            members = shape_members_at(carried.empty? ? node.configs : node.configs + carried, key)
            return members.select { |m| nestable_as_object?(m) } if child.implicit?

            merged_explicit_members(child, members)
          end

          # The colliding `shape:` members an EXPLICIT child merges into its own property, or none.
          #
          # THE owner of that question, for emission (apply_children!) and the drop pass (merged_shape_members)
          # alike. Two gates, each the one its own layer already applies elsewhere: the child must nest at all
          # (node_configs_block_nesting?, the same predicate apply_nested_subfields! gates on), and EVERY
          # colliding member must be object-shaped (nestable_as_object?, the same predicate apply_implicit_node!
          # gates on). All-or-nothing on the second, so a member whose contents have no object representation
          # never contributes half of itself.
          #
          # A non-nestable member does NOT block the child the way it blocks an implicit one: the child's own
          # declared type governs what it emits, and a `type: Hash` node under a `type: [Hash, Array]` member
          # still nests its subfields as properties — runtime narrows to the Hash branch there, and a contract
          # written that way resolves for real (measured). It only means the member's own contents are not
          # merged in, because they describe branches this node does not admit.
          def merged_explicit_members(child, members)
            return NO_SHAPE_MEMBERS if members.empty?
            return NO_SHAPE_MEMBERS if node_configs_block_nesting?(child.configs)

            members.all? { |m| nestable_as_object?(m) } ? members : NO_SHAPE_MEMBERS
          end

          # Every `shape:` member declared at `key` across the node's own configs AND the members carried from
          # a shallower hop — via shape_members_at, the same locator emission uses, so the two sides can't
          # disagree on which members collide with the implicit child at `key`.
          def colliding_shape_members(node, key, carried)
            return shape_members_at(node.configs, key) if carried.empty?

            shape_members_at(node.configs + carried, key)
          end

          private :compute_dropped, :blocking_ancestor?, :merged_shape_members, :colliding_shape_members, :merged_explicit_members
        end
      end
    end
  end
end
