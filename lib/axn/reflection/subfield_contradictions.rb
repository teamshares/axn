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
        return family_1(nil_tolerant_ancestor, node.config) if nil_tolerant_ancestor && stranded_by?(node, nil_tolerant_ancestor)

        # Family 3 (Task 4 fills this in): applied default under a nil-tolerant model ancestor.
        if nil_tolerant_model_ancestor && (defaulted = applied_default_config(node))
          return family_3(nil_tolerant_model_ancestor, defaulted)
        end

        child_nil_tolerant = child_nil_tolerant_ancestor(node, nil_tolerant_ancestor, carried_members)
        child_model = nil_tolerant_model_ancestor || outermost_nil_tolerant_model(node)

        node.children.each do |key, child|
          child_carried = []
          if child.implicit?
            # Family 2 (Task 3 fills this in): collision with a non-object shape member.
            members = Schema.shape_members_at(node.configs + carried_members, key)
            if (blocker = members.find { |m| !Schema.nestable_as_object?(m) })
              carrier = shape_carrier_config(node.configs + carried_members, blocker)
              return family_2(carrier&.field, blocker, first_leaf_config(child))
            end

            child_carried = members.select { |m| Schema.nestable_as_object?(m) }
          end

          found = walk(child, nil_tolerant_ancestor: child_nil_tolerant, nil_tolerant_model_ancestor: child_model, carried_members: child_carried)
          return found if found
        end
        nil
      end

      # The nil-tolerant ancestor to carry into `node`'s children (nil if none). Governs family 1.
      #
      # A SHIELDED node (every-config-defaulted, non-model — shielded?) materializes its whole subtree from
      # its default, so it never strands its own children: it does NOT register itself, and it clears an
      # OUTER nil-tolerant ancestor too — but only an object-shaped one, since Executor#_materialize_object_
      # parent! refuses to synthesize `{}` under a non-object parent (type: Array, a mixed union), where the
      # default never applies and a required descendant below IS still stranded. (A nil-tolerant MODEL
      # ancestor is never cleared here — its materialized `{}` is rejected by ModelValidator — but that's
      # family 3, caught at the defaulted node itself.)
      #
      # A NON-shielded node keeps the outer ancestor, or — if none — registers its own nil-tolerance: its
      # own config (outermost_nil_tolerant), or a nil-tolerant object-shaped `shape:` member it stands in
      # for (an implicit node's carried_members; e.g. `field :bar, type: Hash, allow_nil: true` with a
      # required deep subfield nesting into `bar`).
      def child_nil_tolerant_ancestor(node, nil_tolerant_ancestor, carried_members)
        unless shielded?(node)
          own_nil_tolerance = outermost_nil_tolerant(node) || carried_members.find { |m| Schema.nil_accepted?(m) }
          return nil_tolerant_ancestor || own_nil_tolerance
        end

        # shielded: clear an object-shaped outer ancestor (materializable), keep a non-object one, never self.
        return nil if nil_tolerant_ancestor && Schema.object_shaped?(nil_tolerant_ancestor)

        nil_tolerant_ancestor
      end

      # --- family predicates (leaf; reuse Schema) ---

      # Whether a nil/omitted `ancestor` (already confirmed nil-tolerant by the caller) strands this node's
      # obligation. The node is rescued (NOT stranded) when a default the runtime would apply exists on ANY
      # of its configs — that default materializes the one SHARED node value every co-located config then
      # validates against — but a default applies only when the ancestor is object-shaped, because
      # Executor#_materialize_object_parent! refuses to synthesize `{}` under a non-object parent
      # (type: Array, a mixed union); under one the default never runs and the node is left absent. With no
      # such default, the node is stranded if ANY config requires presence (rejects nil). Judged across all
      # configs collectively, so a required config sharing a wire path with a defaulted one isn't falsely
      # flagged. Implicit nodes carry no validators, so they are never stranded themselves (their obligation
      # lives in their explicit descendants, caught on their own hop).
      #
      # Default detection uses `subfield_default_applies?` (the runtime's own test — any truthy default,
      # Procs INCLUDED), NOT reflection's `usable_default?` (which excludes Procs). The two answer different
      # questions: reflection asks "is this provably omittable?" (a Proc's success is unknowable, so it
      # stays required — the safe, stricter direction), while the DETECTOR asks "is this contract
      # impossible?" — and a Proc/defaulted node under an object-shaped ancestor is NOT impossible (the
      # executor applies the default and materializes the parent before validation), so it must not drive a
      # contradiction rejection.
      def stranded_by?(node, ancestor)
        return false if node.implicit?

        # A default on ANY config at this node materializes the SHARED node value at runtime, satisfying
        # every co-located config (a merged wire path declared via two routes — e.g. `expects "bar.baz",
        # on: :payload, default: "x"` plus `expects :baz, on: :bar, type: String` — is validated against
        # one materialized value). So a materializable default rescues the whole node, not just its own
        # config; it applies only when the ancestor is object-shaped (see below). Judged across all configs
        # rather than per-config, so a required sibling isn't falsely flagged.
        return false if Schema.object_shaped?(ancestor) && node.configs.any? { |c| Axn::Internal::FieldConfig.subfield_default_applies?(c) }

        # No materializable default: the node is stranded if any config requires presence (rejects nil) —
        # a nil/omitted ancestor leaves the node absent (PRO-2857) and that config can't be satisfied.
        node.configs.any? { |c| !Schema.nil_accepted?(c) }
      end

      # A node whose default (the runtime applies it — Procs included, see stranded_by?) materializes it
      # wholesale, rescuing its SUBTREE from omission/nil regardless of the node's own nil-tolerance. Judged
      # across configs collectively (like stranded_by?): a default on ANY config materializes the one SHARED
      # node value, so a merged wire path where only one route carries the default still shields its
      # descendants. NO config may be a model, though: a model route reads the shared value as a record and
      # ModelValidator rejects the materialized non-record (family 3), so the default rescues nothing —
      # leaving such a node un-shielded keeps it tracked as a nil-tolerant ancestor so a stranded descendant
      # still raises rather than slipping through.
      def shielded?(node)
        !node.implicit? &&
          node.configs.none? { |c| c.validations[:model] } &&
          node.configs.any? { |c| Axn::Internal::FieldConfig.subfield_default_applies?(c) }
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

      # The config (among `configs`) whose declared shape members include `blocker`, by identity — the
      # true immediate carrier of the colliding shape member, unambiguous even when a shape member name
      # repeats at two nesting depths.
      def shape_carrier_config(configs, blocker)
        configs.find { |c| Array(c.validations.dig(:shape, :members)).any? { |m| m.equal?(blocker) } }
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

      # `parent_field` is the `.field` of whichever config in `(node.configs + carried_members)` declared
      # `member`'s shape — resolved by identity at the collision site in `walk`, so it is unambiguous even
      # when a shape member name repeats at two nesting depths (the true immediate carrier, not merely the
      # first chain segment matching `member.field`).
      def family_2(parent_field, member, deep_config)
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
    end
  end
end
