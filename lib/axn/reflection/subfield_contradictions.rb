# frozen_string_literal: true

require "axn/reflection/subfield_tree"
require "axn/reflection/schema"

module Axn
  module Reflection
    # Declaration-time rejection of contradiction-only subfield contracts (PRO-2889). Walks a
    # CANDIDATE tree (prospective configs included; nothing committed) and raises ArgumentError on
    # the first provable contradiction. Every judgment reuses the canonical derivation in
    # satisfiability mode (unknowable-at-declaration counts as satisfiable) — never a parallel
    # re-derivation, the failure mode that sank PRO-2877's pulled detectors. Side-effect-free:
    # inspects declared configs only, never runs user code.
    module SubfieldContradictions
      module_function

      # Both checks re-scan the WHOLE candidate tree (prospective configs included), never just the new
      # batch: a NEW declaration can invalidate an OLD subfield regardless of order. For family 1 a new
      # required descendant kills an old tolerance; for family 2 a new type/shape declaration on a parent
      # kills an old subfield's answerability (e.g. `expects "bar.baz", on: :payload` accepted while `bar`
      # is unknown, then `expects :bar, ..., type: String` retro-strands `bar.baz`).
      def check!(field_configs, subfield_configs)
        tree = SubfieldTree.build(field_configs, subfield_configs)
        check_unanswerable_segments!(tree) # first: its message is the more specific when both fire
        check_dead_nil_tolerance!(tree, field_configs)
      end

      # Family 2: a subfield whose resolution provably cannot traverse some segment — for EVERY
      # contract-valid input, the read settles absent (post-PRO-2886: a failed dig/method read is
      # UnextractableError → nil). Judged only along the hops the runtime actually digs (after the
      # deepest reader-bearing ancestor — the same recipe resolve_parent uses), against each
      # position's enforced declarations: its explicit configs plus the shape members an implicit
      # position stands in for (ALL colliding members, nestable or not — answerability is about
      # reading through the member's value, not nesting under it). Rejected regardless of the
      # subfield's own optional:/default: — an unreachable path is dead machinery (the shipped
      # family-4 precedent), and with a default it degenerates to a constant field.
      def check_unanswerable_segments!(tree)
        tree.index.each do |config, path|
          next unless config.subfield? # skip top-level depth-0 configs; they read no segment

          reader_index = Axn::Core::ContractForSubfields.deepest_reader_index(path)
          next if reader_index.nil?

          carried = []
          path.ancestors.each_with_index do |(node, seg), i|
            if i >= reader_index && (blocker = segment_blocker(node, carried, seg))
              raise_unanswerable!(config, blocker, seg)
            end
            carried = node.children[seg]&.implicit? ? Schema.shape_members_at(node.configs + carried, seg) : []
          end
        end
      end

      # The first enforced declaration at this position that provably cannot answer `segment`
      # (nil when the position is answerable). A position with any model: route resolves to a
      # record — never refutable.
      def segment_blocker(node, carried, segment)
        return nil if node.configs.any? { |c| c.validations[:model] }

        (node.configs + carried).find { |c| !Schema.config_answers_segment?(c, segment) }
      end

      def raise_unanswerable!(config, blocker, segment)
        types = Schema.object_type_branches(blocker).map { |b| b.is_a?(Class) ? b.name : b.inspect }.join(", ")
        raise ArgumentError,
              "subfield #{config.field.inspect} (on #{config.on.inspect}) can never resolve: segment #{segment.inspect} " \
              "is read from #{blocker.field.inspect}, declared #{types}, which cannot answer it (no key access, no such " \
              "method) — no contract-valid input ever reaches this subfield. Make #{blocker.field.inspect} object-shaped, " \
              "or drop the subfield."
      end

      # Families 1+3: a statically-declared nil-tolerance (allow_nil:/optional:/allow_blank:/
      # presence: false) whose omission unconditionally fails — the flag advertises an omission
      # the contract can never accept. Keyed on STATIC declarations only, so a future dynamic/
      # conditional requiredness signal (PRO-2881) is outside the reject set by construction.
      def check_dead_nil_tolerance!(tree, field_configs)
        ann = Schema.derive_annotations(tree.roots, satisfiability: true)

        field_configs.each do |config|
          next if Schema::EXCLUDED_FROM_INPUT_SCHEMA.include?(config.field)
          next unless Schema.nil_accepted?(config)

          node = tree.roots[config.reader_as]
          omittable = if config.validations[:model]
                        model_omittable?(config, node, field_configs, ann)
                      else
                        Schema.field_optional?(config, node.children, ann, satisfiability: true)
                      end
          raise_dead_tolerance!(config, config.field, node, ann) unless omittable
        end

        each_explicit_node(tree.roots) do |parent, key, node|
          node.configs.each do |config|
            next unless Schema.nil_accepted?(config)
            next if Schema.node_optional?(node, ann, [config], satisfiability: true)
            next if config.validations[:model] && defaulted_id_sibling?(parent, key)

            # Name the declaration by the field the user wrote (config.field) — symmetric with the
            # top-level loop above; the `on:` parent is implied and the stranded descendant is named.
            raise_dead_tolerance!(config, config.field, node, ann)
          end
        end
      end

      # Depth-first over every explicit subfield node, yielding (parent_node, key, node).
      def each_explicit_node(roots, &block)
        roots.each_value { |root| walk_children(root, &block) }
      end

      def walk_children(parent, &block)
        parent.children.each do |key, node|
          yield(parent, key, node) unless node.implicit?
          walk_children(node, &block)
        end
      end

      # Mirrors apply_model_id_requiredness!'s omittability (satisfiability flavor): the model may
      # be omitted when it is itself optional-for-schema AND no child subtree requires presence —
      # OR a defaulted explicit `<field>_id` sibling supplies the lookup token on omission.
      def model_omittable?(config, node, field_configs, ann)
        explicit_id = field_configs.find { |c| c.field == Internal::FieldConfig.model_id_key(config.field) }
        return true if explicit_id && Schema.usable_default?(explicit_id, subfield: false, satisfiability: true)
        # The model's OWN usable default supplies a record on omission, so the tolerance is
        # exercisable regardless of a required descendant — mirrors field_optional?'s parent-default
        # short-circuit (checked BEFORE the child test, not gated behind it).
        return true if Schema.usable_default?(config, subfield: false, satisfiability: true)

        Schema.optional_for_schema?(config, satisfiability: true) && !Schema.children_require_presence?(node.children, ann)
      end

      # A model SUBFIELD's analog of the explicit-id-sibling rescue: a sibling `<field>_id` subfield
      # with a satisfiability-usable default supplies the token when the model key is omitted. Judged
      # by the SAME condition Schema.credit_sibling_id_defaults! uses for the annotation credit, so the
      # per-config tolerance loop and the ancestor-propagating derivation agree on which siblings rescue.
      # This declaration-side judgment (usable_default? satisfiability) diverges deliberately from the
      # runtime's applied_default? (ContractForSubfields.resolve_model_via_sibling_id): a blank default a
      # presence validator rejects is APPLIED at runtime but FAILS validation, so usable_default?'s
      # blank-handling is the correct declaration-time answer — a blank-rescued tolerance is still dead.
      def defaulted_id_sibling?(parent, key)
        sibling = parent.children[Internal::FieldConfig.model_id_key(key)]
        return false unless sibling

        sibling.configs.any? { |c| Schema.usable_default?(c, subfield: true, satisfiability: true) }
      end

      # The shallowest explicit required descendant's dotted path (for the message) — descends
      # through implicit intermediates that are required only transitively.
      def first_required_descendant(node, ann, prefix = [])
        node.children.each do |key, child|
          path = prefix + [key]
          return path if ann[child].required && !child.implicit?

          deeper = first_required_descendant(child, ann, path)
          return deeper if deeper
        end
        nil
      end

      def raise_dead_tolerance!(config, owner, node, ann)
        stranded = first_required_descendant(node, ann)&.join(".")
        model_hint = if config.validations[:model]
                       " For a model: field, a record-supplying default: on :#{owner} or a defaulted " \
                         "#{owner}_id sibling (declared first) also rescues omission."
                     else
                       ""
                     end
        raise ArgumentError,
              ":#{owner} is declared nil-tolerant (allow_nil:/optional:/allow_blank:/presence: false), but " \
              "#{stranded ? ":#{stranded}" : 'its subtree'} is required and nothing rescues an omitted :#{owner} — " \
              "the tolerance can never be exercised (every nil/omitted :#{owner} fails validation). " \
              "Drop the tolerance on :#{owner}, or mark #{stranded ? ":#{stranded}" : 'the subtree'} optional: or give it a " \
              "default: (declare rescuing defaults BEFORE the dependent subfield).#{model_hint}"
      end
    end
  end
end
