# frozen_string_literal: true

require "axn/reflection/subfield_tree"

module Axn
  module Reflection
    # Declaration-time detector for contradiction-only subfield contracts (PRO-2877). Walks the
    # resolved SubfieldTree once, top-down, carrying ancestor context, and returns the first
    # contradiction found (or nil). Reuses Schema's leaf predicates so declaration (which raises here)
    # and reflection (which emits) share one notion of "contradictory". Side-effect-free: inspects
    # declared configs only, never runs user code.
    module SubfieldContradictions
      Contradiction = Data.define(:family, :message)

      module_function

      def detect(tree)
        tree.roots.each_value do |root|
          found = walk(root, nil_tolerant_ancestor: nil, nil_tolerant_model_ancestor: nil, carried_members: [])
          return found if found
        end
        nil
      end

      # `nil_tolerant_ancestor` / `nil_tolerant_model_ancestor` are the OUTERMOST such ancestor configs
      # above this node (nil when none). `carried_members` are the object-shaped shape members an
      # implicit ancestor merged into (for a member-of-a-member family-2 collision at depth).
      def walk(node, nil_tolerant_ancestor:, nil_tolerant_model_ancestor:, carried_members:)
        # Family 1: this node must be present, but a nil-tolerant ancestor can strand it.
        return family_1(nil_tolerant_ancestor, node.config) if nil_tolerant_ancestor && self_required?(node)

        # Family 3 (Task 4 fills this in): applied default under a nil-tolerant model ancestor.
        if nil_tolerant_model_ancestor && (defaulted = applied_default_config(node))
          return family_3(nil_tolerant_model_ancestor, defaulted)
        end

        # A node whose EVERY config carries a usable default is unconditionally omittable regardless of
        # what's below it (Schema.node_optional?'s first disjunct — the same "trust the default's
        # contents" divergence emission already relies on): omitting THIS node means runtime materializes
        # it wholesale from the default, so nothing beneath it is ever stranded by an ancestor's
        # nil-tolerance — PROVIDED that materialization can actually happen. A defaulted node shields its
        # subtree from a nil-tolerant ancestor only when that ancestor is object-shaped
        # (Schema.object_shaped?), mirroring Executor#_materialize_object_parent!'s own gate: runtime
        # refuses to inject `{}` for a non-object parent (`type: Array`, a mixed union), so under a
        # non-object nil-tolerant ancestor the default never applies and a required descendant below IS
        # stranded — that contradiction must still raise. The MODEL ancestor is never shielded away here:
        # a default under a nil-tolerant model ancestor doesn't rescue anything either (materialized `{}`
        # is rejected by ModelValidator), but that is family 3, caught at the defaulted node itself, so
        # there is nothing for this shield to suppress.
        shielded = !node.implicit? && node.configs.all? { |c| Schema.usable_default?(c, subfield: true) }
        shield_ancestor = shielded && nil_tolerant_ancestor && Schema.object_shaped?(nil_tolerant_ancestor)
        child_nil_tolerant = shield_ancestor ? nil : (nil_tolerant_ancestor || outermost_nil_tolerant(node))
        child_model = nil_tolerant_model_ancestor || outermost_nil_tolerant_model(node)

        node.children.each do |key, child|
          child_carried = []
          if child.implicit?
            # Family 2 (Task 3 fills this in): collision with a non-object shape member.
            members = Schema.shape_members_at(node.configs + carried_members, key)
            if (blocker = members.find { |m| !Schema.nestable_as_object?(m) })
              return family_2(node, blocker, first_leaf_config(child))
            end

            child_carried = members.select { |m| Schema.nestable_as_object?(m) }
          end

          found = walk(child, nil_tolerant_ancestor: child_nil_tolerant, nil_tolerant_model_ancestor: child_model, carried_members: child_carried)
          return found if found
        end
        nil
      end

      # --- family predicates (leaf; reuse Schema) ---

      # A node whose OWN declared signals force it to be present: some config neither carries a usable
      # subfield default nor tolerates nil. Implicit nodes carry no validators, so they are never
      # self-required (their obligation lives in their explicit descendants, caught on their own hop).
      def self_required?(node)
        return false if node.implicit?

        node.configs.any? { |c| !(Schema.usable_default?(c, subfield: true) || Schema.nil_accepted?(c)) }
      end

      def nil_tolerant?(node)
        !node.implicit? && node.configs.any? { |c| Schema.nil_accepted?(c) }
      end

      def nil_tolerant_config(node)
        node.configs.find { |c| Schema.nil_accepted?(c) }
      end

      def nil_tolerant_model?(node)
        !node.implicit? && node.configs.any? { |c| c.validations[:model] && Schema.nil_accepted?(c) }
      end

      def nil_tolerant_model_config(node)
        node.configs.find { |c| c.validations[:model] && Schema.nil_accepted?(c) }
      end

      # This node's own nil-tolerant config, when it is itself nil-tolerant — nil otherwise (no ancestor
      # concern originates here). Named for what `walk` uses it for: becoming the new outermost
      # nil-tolerant ancestor for this node's children when none was already carried from above.
      def outermost_nil_tolerant(node)
        nil_tolerant?(node) ? nil_tolerant_config(node) : nil
      end

      def outermost_nil_tolerant_model(node)
        nil_tolerant_model?(node) ? nil_tolerant_model_config(node) : nil
      end

      def applied_default_config(node)
        return nil if node.implicit?

        node.configs.find { |c| Axn::Internal::FieldConfig.subfield_default_applies?(c) }
      end

      def first_leaf_config(node)
        return node.config unless node.implicit?

        node.children.each_value do |child|
          found = first_leaf_config(child)
          return found if found
        end
        nil
      end

      # A top-level field config has no `on:`; a subfield config does. Render each as declared.
      def label(config)
        on = config.respond_to?(:on) ? config.on : nil
        on ? ":#{config.field} (on: #{on})" : ":#{config.field}"
      end

      # --- messages ---

      # rubocop:disable Naming/VariableNumber -- family_1/family_2/family_3 name the PRO-2877
      # contradiction families; renaming them loses that link.
      def family_1(ancestor, descendant)
        Contradiction.new(
          family: 1,
          message: "expects #{label(ancestor)} is declared nil-tolerant (allow_nil:/optional:) but " \
                   "#{label(descendant)} is required — a nil or omitted :#{ancestor.field} can never " \
                   "satisfy it. Drop allow_nil:/optional: on :#{ancestor.field}, or make :#{descendant.field} " \
                   "optional on every declaration that reaches it.",
        )
      end

      # `parent_node` is unused: it may itself be IMPLICIT (nil `.config`) when the collision is a member
      # of a member reached through `carried_members` — the naive `parent_node.config.field` crashes
      # there, and even when `parent_node` is explicit-but-merged, `configs.first` isn't necessarily the
      # config that declared `member`'s shape. `shape_parent_field` derives the true immediate carrier
      # from `deep_config`'s own dotted on:/field chain instead, which is robust to both.
      def family_2(_parent_node, member, deep_config)
        parent_field = shape_parent_field(member, deep_config)
        Contradiction.new(
          family: 2,
          message: "#{label(deep_config)} nests beneath shape member :#{member.field} on :#{parent_field}, " \
                   "which is declared a non-object type (#{member_type_desc(member)}) — a nested subfield has " \
                   "nowhere to live. Make :#{member.field} an object-shaped member (Hash/:params), " \
                   "or drop the nested subfield.",
        )
      end

      def family_3(model_ancestor, defaulted)
        Contradiction.new(
          family: 3,
          message: "expects :#{model_ancestor.field} is a nil-tolerant model: (allow_nil:) but " \
                   "#{label(defaulted)} carries a default — the default materializes an empty object under " \
                   ":#{model_ancestor.field}, which the model validator rejects as not a record, so " \
                   ":#{model_ancestor.field} can never be omitted. Drop allow_nil: on :#{model_ancestor.field}, " \
                   "or drop the subfield default.",
        )
      end
      # rubocop:enable Naming/VariableNumber

      # A short human name for the shape member's declared type, for the error message.
      def member_type_desc(member)
        klass = member.validations.dig(:type, :klass) || member.validations[:type]
        Array(klass).map { |k| k.is_a?(Class) ? k.name : k.to_s }.join(" | ")
      end

      # The field that immediately carries `member`'s shape — reconstructed from `deep_config`'s own
      # dotted `on:`/`field` chain (the same segments SubfieldTree splits into hops) rather than from a
      # `parent_node` reference, because that node may be implicit (member-of-a-member, reached only
      # through `carried_members`) or an explicit-but-merged node whose FIRST config isn't necessarily the
      # one that declared `member`'s shape. `member.field` always equals the exact hop key at the
      # collision point, so its position in the reconstructed chain recovers its true immediate parent —
      # the chain's own root (deep_config's `on:`) when `member` collides at the first hop.
      def shape_parent_field(member, deep_config)
        root, *on_rest = deep_config.on.to_s.split(".").map(&:to_sym)
        chain = on_rest + deep_config.field.to_s.split(".").map(&:to_sym)
        idx = chain.index(member.field.to_sym) || 0
        idx.positive? ? chain[idx - 1] : root
      end
    end
  end
end
