# frozen_string_literal: true

require "axn/internal/subfield_tree"
require "axn/internal/reflection/schema"

module Axn
  module Core
    module Contract
      # Declaration-time rejection of subfield contracts that cannot mean one thing: a contradiction-only
      # contract, whose every judgment reuses the canonical derivation in satisfiability mode
      # (unknowable-at-declaration counts as satisfiable — never a parallel re-derivation, the failure mode
      # that sank PRO-2877's pulled detectors), and an ambiguous route reference, whose answer would
      # otherwise be settled by declaration order. Walks a CANDIDATE tree (prospective configs included;
      # nothing committed) and raises ArgumentError on the first one it can prove. Side-effect-free:
      # inspects declared configs only, never runs user code.
      module SubfieldContradictions
        module_function

        # All three checks re-scan the WHOLE candidate tree (prospective configs included), never just the new
        # batch: a NEW declaration can invalidate an OLD subfield regardless of order — a new required
        # descendant kills an old tolerance (dead-tolerance check), and a new type/shape declaration on a
        # parent kills an old subfield's answerability (e.g. `expects "bar.baz", on: :payload` accepted
        # while `bar` is unknown, then `expects :bar, ..., type: String` retro-strands `bar.baz`).
        def check!(field_configs, subfield_configs, crossings: true)
          tree = Axn::Internal::SubfieldTree.build(field_configs, subfield_configs)
          check_unanswerable_segments!(tree) # first: an unreachable path moots any ambiguity on it
          check_subfields_under_map!(tree)
          check_ambiguous_crossings!(tree) if crossings
          check_dead_nil_tolerance!(tree, field_configs)
        end

        # The MAP-PARENT check: a subfield read out of a Hash that declares `of:`. `of:` names what every key of
        # that hash maps to, and a subfield names one of those keys — so the two describe the same keys two ways,
        # and no reflected schema can state both. JSON Schema's `additionalProperties` applies only to keys
        # `properties` does not match, so emitting the pair says a key named by a subfield is exempt from the
        # `of:` the runtime enforces on it: a document the schema calls valid and the contract rejects.
        #
        # The `shape:` spelling of the same pairing IS permitted (PRO-3166's Hash exemption: a key the shape
        # names is emitted as a `properties` entry, which `additionalProperties` does not govern, so the
        # document and the runtime agree that the key is exempt). What separates the two is not the spelling
        # but whether the exempt set is KNOWABLE where it is derived. A shape's is: its member keys are final
        # at the node that carries it. A subfield's is not — the emitter puts more than subfield leaves in that
        # node's `properties` (the nested keys a dotted `on:` introduces, `model:`'s generated `<field>_id`),
        # and none of that is visible from the shape at declaration, where `_derive_shaped_keys!` runs. So the
        # refusal stays, and stays worded "not supported yet": relaxing it later — once the exempt set can be
        # derived from what the emitter actually emits at that node — must contradict nothing shipped.
        #
        # Judged over the whole candidate tree, like every check here, so neither declaration order gets through:
        # the map may be declared before the subfield or after it, and every ancestor of the subfield is asked,
        # so a dotted `on:` reading THROUGH a map is refused at any depth.
        def check_subfields_under_map!(tree)
          tree.index.each do |config, path|
            next unless config.subfield? # a top-level config is read from no parent

            path.ancestors.each do |(node, segment)|
              blocker = node.configs.find { |c| map_valued?(c) }
              raise_subfield_under_map!(config, blocker, segment) if blocker
            end
          end
        end

        # Whether a config declares a MAP, read through reflection's one derivation of an `of:` bag's container —
        # the same answer the emitter acts on, so what this refuses and what would have been emitted cannot drift.
        def map_valued?(config) = ::Hash.equal?(Axn::Internal::Reflection::Schema.of_container(config.validations))

        # `segment` is the key read out of the MAP itself, which at depth is an intermediate rather than the
        # subfield's own name — so the message names the key that actually collides with the `of:` as well as
        # the two declarations that produced it.
        def raise_subfield_under_map!(config, blocker, segment)
          raise ArgumentError,
                "subfield #{config.field.inspect} (on #{config.on.inspect}) names the key #{segment.inspect} of " \
                "#{blocker.field.inspect}, which declares `of:` on a Hash — of: beside a subfield on a Hash is " \
                "not supported yet: of: names what EVERY key of that hash maps to, while the subfield names one " \
                "key of its own, so the reflected schema would exempt #{segment.inspect} from the of: the " \
                "runtime enforces on it. Drop the `of:` on #{blocker.field.inspect}, or drop the subfield."
        end

        # The AMBIGUOUS-CROSSING check (PRO-3068): a config whose dotted `on:` tail resolves its parent
        # THROUGH a wire node that answers to more than one reader name. A dotted tail addresses that node
        # by WIRE KEY, and a wire key names a node rather than a route — so where two routes merged onto it
        # the reference names neither, and `_deepest_reader_name` falls back to the node's first config.
        # Swapping the two route declarations then changes the value every descendant reads (that route's
        # `preprocess:`/`default:`/`model:` included) with nothing raised and the emitted schema identical
        # either way.
        #
        # Rejected as an ambiguous REFERENCE, not on whether the routes currently differ: routes that agree
        # today diverge the moment one gains a transform, and two Procs can never be compared. This is the
        # same standard `_validate_subfield_reader_names!` applies to a duplicate reader, which raises even
        # when either would have worked.
        #
        # Keyed on distinct reader NAMES rather than config count, because that is what dispatch consumes.
        # Where every config at the node answers to one name, `public_send` resolves it through the
        # reader-owner rule, whose order-independence SubfieldTree.yields_reader_name? documents — so an
        # inferred `confirmation:` companion sharing a node with the author's own same-named declaration is
        # unambiguous and stays legal.
        def check_ambiguous_crossings!(tree)
          tree.index.each do |config, path|
            next unless config.subfield? # a top-level config reads no segment, so it crosses nothing

            # Walked once and threaded through: crossed_node consumes it to find the node, and
            # raise_ambiguous_crossing! (on the failing path) reuses it to render the crossed prefix,
            # rather than each re-deriving it from path.
            reader_index = Axn::Core::ContractForSubfields.deepest_reader_index(path)
            node = Axn::Core::ContractForSubfields.crossed_node(config, path, reader_index)
            next if node.nil?

            readers = node.configs.map(&:reader_as).uniq
            next if readers.size < 2

            raise_ambiguous_crossing!(config, path, reader_index, readers)
          end
        end

        def raise_ambiguous_crossing!(config, path, reader_index, readers)
          # The crossed node sits at the deepest reader-bearing chain index, and wire_path is indexed to
          # match (wire_path[i] is the wire key of ancestors[i]'s node), so its own path is that prefix.
          # Rendered segment by segment: a declared name may hold bytes with no UTF-8 rendering, and
          # joining one into this message raw would raise Encoding::CompatibilityError from the reporting.
          crossed = path.wire_path[0..reader_index].map { |s| Axn::Internal::Reflection::PropertyNames.renderable_label(s) }.join(".")
          raise ArgumentError,
                "subfield #{config.field.inspect} (on #{config.on.inspect}) reads through wire path " \
                "#{crossed.inspect}, which two routes declared — they answer to " \
                "#{readers.map(&:inspect).join(' and ')}, and a dotted path names the wire NODE rather than " \
                "either route, so only declaration order decides which route's value is read (its " \
                "`preprocess:`, `default:` and `model:` included). Declare that wire key once, split the " \
                "routes onto distinct wire keys, or anchor this subfield on the route you mean " \
                "(#{readers.map { |r| "`on: #{r.inspect}`" }.join(' or ')})."
        end

        # The UNANSWERABLE-SEGMENT check: a subfield whose resolution provably cannot traverse some
        # segment — for EVERY contract-valid input, the read settles absent (a failed dig/method read
        # is UnextractableError → nil, PRO-2886). Judged only along the hops the runtime actually digs
        # (after the deepest reader-bearing ancestor — the same recipe resolve_parent uses), against each
        # position's enforced declarations: its explicit configs plus the shape members an implicit
        # position stands in for (ALL colliding members, nestable or not — answerability is about
        # reading through the member's value, not nesting under it). Rejected regardless of the
        # subfield's own optional:/default: — an unreachable path is dead machinery, rejected like the
        # dotted-name model: spelling (PRO-2877), and with a default it degenerates to a constant field.
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
              carried = node.children[seg]&.implicit? ? Axn::Internal::Reflection::Schema.shape_members_at(node.configs + carried, seg) : []
            end
          end
        end

        # The first enforced declaration at this position that provably cannot answer `segment`
        # (nil when the position is answerable). A position with any model: route resolves to a
        # record — never refutable.
        def segment_blocker(node, carried, segment)
          return nil if node.configs.any? { |c| c.validations[:model] }

          (node.configs + carried).find { |c| !Axn::Internal::Reflection::Schema.config_answers_segment?(c, segment) }
        end

        def raise_unanswerable!(config, blocker, segment)
          types = Axn::Internal::Reflection::Schema.object_type_branches(blocker).map { |b| b.is_a?(Class) ? b.name : b.inspect }.join(", ")
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
          ann = Axn::Internal::Reflection::Schema.derive_annotations(tree.roots, satisfiability: true)

          field_configs.each do |config|
            next if Axn::Internal::Reflection::Schema::EXCLUDED_FROM_INPUT_SCHEMA.include?(config.field)
            next unless Axn::Internal::Reflection::Schema.nil_accepted?(config)

            # The config's own node (see Schema.build_input): a config that yields its reader name is
            # judged on the subtree IT declares, not on the one hanging off the name's owner.
            node = tree.index[config].node
            omittable = if config.validations[:model]
                          model_omittable?(config, node, field_configs, ann)
                        else
                          Axn::Internal::Reflection::Schema.field_optional?(config, node.children, ann, satisfiability: true)
                        end
            raise_dead_tolerance!(config, config.field, node, ann) unless omittable
          end

          each_explicit_node(tree.roots) do |parent, key, node|
            node.configs.each do |config|
              next unless Axn::Internal::Reflection::Schema.nil_accepted?(config)
              next if Axn::Internal::Reflection::Schema.node_optional?(node, ann, [config], satisfiability: true)
              # Skip ANY nil-accepted config at a sibling-id-rescued node, not only the model route: a
              # merged nil-tolerant non-model route (and a required grandchild the resolved record answers)
              # is exercisable via the same rescue the annotation credit grants — one shared predicate.
              next if Axn::Internal::Reflection::Schema.sibling_id_rescued?(parent, key, node)

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
          return true if explicit_id && Axn::Internal::Reflection::Schema.usable_id_token_default?(explicit_id)
          # The model's OWN usable default supplies a record on omission, so the tolerance is
          # exercisable regardless of a required descendant — mirrors field_optional?'s parent-default
          # short-circuit (checked BEFORE the child test, not gated behind it).
          return true if Axn::Internal::Reflection::Schema.usable_default?(config, subfield: false, satisfiability: true)

          Axn::Internal::Reflection::Schema.optional_for_schema?(config, satisfiability: true) &&
            !Axn::Internal::Reflection::Schema.children_require_presence?(node.children, ann)
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
          # Names are rendered rather than interpolated raw, and the stranded path is joined from rendered
          # SEGMENTS: a declared name may hold non-UTF-8 bytes (a valid Latin-1 Symbol), and joining one to a
          # non-ASCII UTF-8 name raises Encoding::CompatibilityError from the message itself — so the author gets
          # an encoding failure instead of the contradiction being reported. `Symbol#inspect` supplies the leading
          # colon these read with, and escapes bytes that have no UTF-8 rendering.
          name = owner.inspect
          segments = first_required_descendant(node, ann)&.map { |segment| Axn::Internal::Reflection::PropertyNames.renderable_label(segment) }
          stranded = segments && ":#{segments.join('.')}"
          model_hint = if config.validations[:model]
                         " For a model: field, a record-supplying default: on #{name} or a defaulted " \
                           "#{Axn::Internal::Reflection::PropertyNames.renderable_label(owner)}_id sibling (declared first) also rescues omission."
                       else
                         ""
                       end
          raise ArgumentError,
                "#{name} is declared nil-tolerant (allow_nil:/optional:/allow_blank:, or an untyped " \
                "presence: false), but " \
                "#{stranded || 'its subtree'} is required and nothing rescues an omitted #{name} — " \
                "the tolerance can never be exercised (every nil/omitted #{name} fails validation). " \
                "Drop the tolerance on #{name}, or mark #{stranded || 'the subtree'} optional: or give it a " \
                "default: (declare rescuing defaults BEFORE the dependent subfield). If it is only required when " \
                "#{name} is supplied, gate it conditionally: `expects ..., if: -> { " \
                "#{Axn::Internal::Reflection::PropertyNames.renderable_label(owner)}.present? }`.#{model_hint}"
        end
      end
    end
  end
end
