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
        shielded = shielded?(node)
        # An OUTER nil-tolerant ancestor is rescued by this node's default only if it can be materialized
        # while nil — i.e. it is object-shaped (Executor#_materialize_object_parent!'s gate). A non-object
        # ancestor (type: Array) can't be, so it still strands and must keep being tracked.
        shield_ancestor = shielded && nil_tolerant_ancestor && Schema.object_shaped?(nil_tolerant_ancestor)
        # A shielded node's default materializes its whole subtree, so it neither strands its own children
        # (it does NOT register itself as a nil-tolerant ancestor below) nor lets an object-shaped outer
        # ancestor strand them. When it is NOT shielded, it tracks the outer ancestor and — if itself
        # nil-tolerant — registers itself.
        child_nil_tolerant =
          if shielded
            shield_ancestor ? nil : nil_tolerant_ancestor
          else
            nil_tolerant_ancestor || outermost_nil_tolerant(node)
          end
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

      # --- family predicates (leaf; reuse Schema) ---

      # Whether a nil/omitted `ancestor` (already confirmed nil-tolerant by the caller) strands this node's
      # own obligation. A config is stranded unless it tolerates nil OR carries a default the runtime would
      # actually apply here — and a default applies only when the ancestor is object-shaped, because
      # Executor#_materialize_object_parent! refuses to synthesize `{}` under a non-object parent
      # (type: Array, a mixed union); under one the default never runs and the leaf is left absent, so the
      # nil-tolerant ancestor genuinely strands it. Implicit nodes carry no validators, so they are never
      # stranded themselves (their obligation lives in their explicit descendants, caught on their own hop).
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

        default_can_rescue = Schema.object_shaped?(ancestor)
        node.configs.any? do |c|
          next false if Schema.nil_accepted?(c)
          next false if default_can_rescue && Axn::Internal::FieldConfig.subfield_default_applies?(c)

          true
        end
      end

      # A node whose OWN configs materialize it wholesale from a default the runtime applies (Procs
      # included — see stranded_by?), rescuing its subtree from omission/nil regardless of its own
      # nil-tolerance. Only a NON-model node qualifies: a model node's materialized default is a non-record
      # value ModelValidator rejects (family 3), so it rescues nothing — leaving it un-shielded keeps it
      # tracked as a nil-tolerant ancestor, so a required descendant of a defaulted nil-tolerant model still
      # raises (a broken contract) rather than slipping through.
      def shielded?(node)
        !node.implicit? &&
          node.configs.none? { |c| c.validations[:model] } &&
          node.configs.all? { |c| Axn::Internal::FieldConfig.subfield_default_applies?(c) }
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
