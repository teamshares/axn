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
        tree.roots.each_value do |root|
          found = walk(root, nil_tolerant_model_ancestor: nil)
          return found if found
        end
        nil
      end

      # `nil_tolerant_model_ancestor` is the OUTERMOST such model config at or above this node (nil when none).
      #
      # This walk detects only the nil-tolerant model + applied-default contradiction. Two sibling families
      # live elsewhere or were deferred: the dotted-name model: rejection is a local check in
      # ContractForSubfields; a nil-tolerant ancestor + required descendant (PRO-2889) and the non-object
      # shape-member collision (also PRO-2889) were pulled because both re-derive runtime resolution
      # semantics the current SubfieldTree can't reproduce without false positives — they need the canonical
      # tree's omittability derivation and per-edge provenance (PRO-2883).
      def walk(node, nil_tolerant_model_ancestor:)
        # The outermost nil-tolerant model at or above this node — an ancestor if one is carried, else one
        # declared on THIS node (a same-wire-key sibling can merge a `model:` config and a defaulted config
        # onto one node, so the model may first appear here alongside the default it conflicts with).
        model = nil_tolerant_model_ancestor || outermost_nil_tolerant_model(node)

        # A nil-tolerant model with an applied default at or below it: on omission the default materializes a
        # non-record value under the model's wire key BEFORE the model resolves, which ModelValidator rejects
        # — so the model can never be omitted and its allow_nil: is dead weight producing a confusing failure.
        if model && (defaulted = applied_default_config(node))
          return defaulted_under_nil_tolerant_model(model, defaulted)
        end

        node.children.each_value do |child|
          found = walk(child, nil_tolerant_model_ancestor: model)
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
      # none). A model is a hazard unless its OWN default may supply a record: a defaulted subfield
      # materializes `{}` under the model's wire key, which ModelValidator rejects (not a record) — so the
      # model can never be omitted. A defaulted `<field>_id` sibling does NOT rescue this: the subfield
      # default populates `:model`'s wire key directly, and FieldResolvers::Model prefers that non-blank
      # hash over deriving from the id, so the id never gets a chance. Only an own default that may itself
      # be a record (model_own_default_may_supply_record?) leaves a satisfiable contract, so it is skipped.
      def outermost_nil_tolerant_model(node)
        return nil if node.implicit?

        node.configs.find { |c| c.validations[:model] && Schema.nil_accepted?(c) && !model_own_default_may_supply_record?(c) }
      end

      def applied_default_config(node)
        return nil if node.implicit?

        node.configs.find { |c| Axn::Internal::FieldConfig.subfield_default_applies?(c) }
      end

      # A top-level field config has no `on:`; a subfield config does. Render each as declared.
      def label(config)
        on = config.respond_to?(:on) ? config.on : nil
        on ? ":#{config.field} (on: #{on})" : ":#{config.field}"
      end

      # --- messages ---

      def defaulted_under_nil_tolerant_model(model, defaulted)
        Contradiction.new(
          message: "expects :#{model.field} is a nil-tolerant model: (allow_nil:) but " \
                   "#{label(defaulted)} carries a default — on omission the default materializes a non-record " \
                   "value under :#{model.field}, which the model validator rejects as not a record, so " \
                   ":#{model.field} can never be omitted. Drop allow_nil: on :#{model.field}, " \
                   "or drop the default.",
        )
      end
    end
  end
end
