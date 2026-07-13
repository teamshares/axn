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
      Contradiction = Data.define(:message)

      module_function

      def detect(tree)
        # Top-level fields carrying a usable default — used to spot a `model:` field rescued by an explicit
        # defaulted `<field>_id` sibling (the id is applied before the model reader, so the record resolves
        # even on omission; mirrors apply_model_id_requiredness!'s explicit-id-default path), which is
        # therefore not a nil-tolerant-model-plus-default hazard.
        defaulted_id_fields = tree.roots.values.flat_map(&:configs)
                                  .select { |c| Schema.usable_default?(c, subfield: false) }
                                  .to_set(&:field)
        tree.roots.each_value do |root|
          found = walk(root, nil_tolerant_model_ancestor: nil, carried_members: [], defaulted_id_fields:)
          return found if found
        end
        nil
      end

      # `nil_tolerant_model_ancestor` is the OUTERMOST such ancestor config above this node (nil when none).
      # `carried_members` are the object-shaped shape members an implicit ancestor merged into (for a
      # member-of-a-member non-object-shape-member collision at depth). `defaulted_id_fields` — see detect.
      #
      # NOTE: a nil-tolerant ancestor + a required descendant with no rescue is deliberately NOT detected
      # here — pulled from PRO-2877 to PRO-2889, because telling the genuine dead-flag case apart from the
      # many rescued look-alikes needs the full omittability analysis reflection already does, on the
      # canonical SubfieldTree from PRO-2883. Only the structural contradictions (non-object shape member
      # collision, nil-tolerant model + defaulted subfield) live in this walk; the dotted-name model:
      # rejection is a local check in ContractForSubfields.
      def walk(node, nil_tolerant_model_ancestor:, carried_members:, defaulted_id_fields:)
        # A nil-tolerant model ancestor with an applied default anywhere in its subtree: the default
        # materializes `{}` under the model's wire key BEFORE the default runs, which ModelValidator rejects
        # — so the model can never be omitted and its allow_nil: is dead weight producing a confusing failure.
        if nil_tolerant_model_ancestor && (defaulted = applied_default_config(node))
          return defaulted_subfield_under_nil_tolerant_model(nil_tolerant_model_ancestor, defaulted)
        end

        child_model = nil_tolerant_model_ancestor || outermost_nil_tolerant_model(node, defaulted_id_fields)

        node.children.each do |key, child|
          members = Schema.shape_members_at(node.configs + carried_members, key)

          # A non-object shape member at `key` can't hold nested structure. Fires for any child that NESTS
          # (has children) — an implicit dotted intermediate OR an explicit object subfield with its own
          # subfields (e.g. `field :bar, type: String` + `expects :bar, on:, type: Hash` +
          # `expects :baz, on: :bar`): either way the deep structure has nowhere to live in the scalar member.
          if child.children.any? && (blocker = members.find { |m| !Schema.nestable_as_object?(m) })
            carrier = shape_carrier_config(node.configs + carried_members, blocker)
            return nonobject_shape_member_collision(carrier&.field, blocker, first_leaf_config(child))
          end

          # Only an implicit node stands in for the object-shaped members it merged into — carry them so a
          # deeper member-of-a-member collision is caught. An explicit child brings its own configs' members.
          child_carried = child.implicit? ? members.select { |m| Schema.nestable_as_object?(m) } : []
          found = walk(child, nil_tolerant_model_ancestor: child_model, carried_members: child_carried, defaulted_id_fields:)
          return found if found
        end
        nil
      end

      # --- contradiction predicates (leaf; reuse Schema) ---

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

      # This node's own nil-tolerant MODEL config that is a defaulted-subfield hazard ancestor (nil if
      # none). A model is a hazard only when NOT rescued: then omission relies on a synthesized `{}`
      # (rejected by ModelValidator). A rescued model resolves to a record on omission — no `{}` hazard —
      # so it is not tracked.
      def outermost_nil_tolerant_model(node, defaulted_id_fields)
        return nil if node.implicit?

        node.configs.find { |c| c.validations[:model] && Schema.nil_accepted?(c) && !model_rescued?(c, defaulted_id_fields) }
      end

      # Whether a nil-tolerant `model:` config still resolves to a record on omission — so it does not hit
      # the defaulted-subfield `{}` hazard. Two runtime-satisfying paths (mirroring
      # apply_model_id_requiredness!): its OWN default may supply a record (model_own_default_may_supply_record?),
      # OR an explicit `<field>_id` sibling carries a usable default (applied before the model reader, so the
      # record resolves from the id).
      def model_rescued?(config, defaulted_id_fields)
        return false unless config.validations[:model]

        model_own_default_may_supply_record?(config) ||
          defaulted_id_fields.include?(Axn::Internal::FieldConfig.model_id_key(config.field))
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

      # `parent_field` is the `.field` of whichever config in `(node.configs + carried_members)` declared
      # `member`'s shape — resolved by identity at the collision site in `walk`, so it is unambiguous even
      # when a shape member name repeats at two nesting depths (the true immediate carrier, not merely the
      # first chain segment matching `member.field`).
      def nonobject_shape_member_collision(parent_field, member, deep_config)
        Contradiction.new(
          message: "#{label(deep_config)} nests beneath shape member :#{member.field} on :#{parent_field}, " \
                   "which is declared a non-object type (#{member_type_desc(member)}) — a nested subfield has " \
                   "nowhere to live. Make :#{member.field} an object-shaped member (Hash/:params), " \
                   "or drop the nested subfield.",
        )
      end

      def defaulted_subfield_under_nil_tolerant_model(model_ancestor, defaulted)
        Contradiction.new(
          message: "expects :#{model_ancestor.field} is a nil-tolerant model: (allow_nil:) but " \
                   "#{label(defaulted)} carries a default — the default materializes an empty object under " \
                   ":#{model_ancestor.field}, which the model validator rejects as not a record, so " \
                   ":#{model_ancestor.field} can never be omitted. Drop allow_nil: on :#{model_ancestor.field}, " \
                   "or drop the subfield default.",
        )
      end

      # A short human name for the shape member's declared type, for the error message.
      def member_type_desc(member)
        klass = member.validations.dig(:type, :klass) || member.validations[:type]
        Array(klass).map { |k| k.is_a?(Class) ? k.name : k.to_s }.join(" | ")
      end
    end
  end
end
