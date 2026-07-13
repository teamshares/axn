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
          members = Schema.shape_members_at(node.configs + carried_members, key)

          # Family 2: a non-object shape member at `key` can't hold nested structure. Fires for any child
          # that NESTS (has children) — an implicit dotted intermediate OR an explicit object subfield with
          # its own subfields (e.g. `field :bar, type: String` + `expects :bar, on:, type: Hash` +
          # `expects :baz, on: :bar`): either way the deep structure has nowhere to live in the scalar member.
          if child.children.any? && (blocker = members.find { |m| !Schema.nestable_as_object?(m) })
            carrier = shape_carrier_config(node.configs + carried_members, blocker)
            return family_2(carrier&.field, blocker, first_leaf_config(child))
          end

          # Only an implicit node stands in for the object-shaped members it merged into — carry them so a
          # deeper member-of-a-member collision is caught. An explicit child brings its own configs' members.
          child_carried = child.implicit? ? members.select { |m| Schema.nestable_as_object?(m) } : []
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
      # lives in their explicit descendants, caught on their own hop). "A default the runtime would apply"
      # means `rescuing_default?` — see it for why Procs count but a blank-rejected literal does not.
      def stranded_by?(node, ancestor)
        return false if node.implicit?

        # A default on ANY config at this node materializes the SHARED node value at runtime, satisfying
        # every co-located config (a merged wire path declared via two routes — e.g. `expects "bar.baz",
        # on: :payload, default: "x"` plus `expects :baz, on: :bar, type: String` — is validated against
        # one materialized value). So a materializable default rescues the whole node, not just its own
        # config; it applies only when the ancestor is object-shaped (see below). Judged across all configs
        # rather than per-config, so a required sibling isn't falsely flagged.
        return false if Schema.object_shaped?(ancestor) && node.configs.any? { |c| rescuing_default?(c) }

        # No materializable default: the node is stranded if any config requires presence (rejects nil) —
        # a nil/omitted ancestor leaves the node absent (PRO-2857) and that config can't be satisfied.
        node.configs.any? { |c| !Schema.nil_accepted?(c) }
      end

      # A node whose default (the runtime applies it — Procs included, see stranded_by?) materializes it
      # wholesale, rescuing its SUBTREE from omission/nil regardless of the node's own nil-tolerance. Judged
      # across configs collectively (like stranded_by?): a default on ANY config materializes the one SHARED
      # node value, so a merged wire path where only one route carries the default still shields its
      # descendants. A MODEL route is special: it reads the shared value as a record, so it shields only via
      # its OWN default that may supply a record (Proc / model-instance literal); a model relying on a
      # synthesized `{}`, or whose own default is a non-record (Hash/id/scalar), is rejected by
      # ModelValidator, so it does NOT shield — the node stays a nil-tolerant ancestor and a stranded
      # descendant still raises (family 1/3) rather than slipping through.
      def shielded?(node)
        return false if node.implicit?
        # Some config supplies a default that materializes the shared node value.
        return false unless node.configs.any? { |c| rescuing_default?(c) }

        # Every MODEL route must be satisfied by that materialization: a model reads the shared value as a
        # record, so it shields only via its OWN default that may supply a record (a Proc, or a literal
        # model instance). A model relying on a synthesized `{}` — or whose own default is a non-record
        # (a Hash/id/scalar) — is rejected by ModelValidator, so it does NOT shield (family 3).
        node.configs.all? { |c| !c.validations[:model] || model_own_default_may_supply_record?(c) }
      end

      # Whether a `model:` config's OWN default may resolve to a record (so omission is genuinely rescued):
      # a Proc (uninspectable — the detector must not reject a contract it might satisfy) or a literal
      # instance of the model class. A Hash/id/scalar literal is NOT a record (ModelValidator rejects it),
      # so it does not rescue. Side-effect-free (never calls the Proc; `is_a?` only).
      def model_own_default_may_supply_record?(config)
        return false unless config.respond_to?(:default)

        default = config.default
        return false if default.nil?
        return true if default.is_a?(Proc)

        model_opts = config.validations[:model]
        klass = model_opts.is_a?(Hash) ? model_opts[:klass] : model_opts
        klass.is_a?(Class) && default.is_a?(klass)
      end

      # Whether a config carries a default that could actually RESCUE the node from a nil ancestor. Reuses
      # reflection's `usable_default?` for literals — which already excludes a blank default that presence
      # would reject (`default: ""` on a String field materializes but then fails presence, so it rescues
      # nothing and the ancestor's nil-tolerance stays a dead flag) — but ADDS Procs, which usable_default?
      # excludes as uninspectable: the detector rejects only impossible contracts, and a Proc default might
      # return a satisfying value, so it must not drive a rejection. (Family 3 stays on
      # subfield_default_applies? — its hazard is that runtime materializes `{}` at all, blank or not.)
      def rescuing_default?(config)
        Schema.usable_default?(config, subfield: true) ||
          (config.respond_to?(:default) && config.default.is_a?(Proc))
      end

      def nil_tolerant?(node)
        !node.implicit? && node.configs.any? { |c| Schema.nil_accepted?(c) }
      end

      def nil_tolerant_config(node)
        node.configs.find { |c| Schema.nil_accepted?(c) }
      end

      # A nil-tolerant model is a family-3 hazard ancestor only when its OWN default can't supply a record:
      # then omission relies on a synthesized `{}` (rejected by ModelValidator). A model whose own default
      # may supply a record (Proc / model-instance literal) resolves to that record on omission — no `{}`
      # hazard — so it is not tracked (and is shielded, see shielded?).
      def nil_tolerant_model?(node)
        !node.implicit? && !nil_tolerant_model_config(node).nil?
      end

      def nil_tolerant_model_config(node)
        node.configs.find { |c| c.validations[:model] && Schema.nil_accepted?(c) && !model_own_default_may_supply_record?(c) }
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
