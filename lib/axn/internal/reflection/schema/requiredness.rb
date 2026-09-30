# frozen_string_literal: true

# A Symbol condition is resolved to the reader it names by method-table lookup, never by dispatch.
require "axn/internal/identity"
require "axn/internal/native_methods"
# The `model:` id convention and the conditional-gate keys are both read here.
require "axn/internal/field_config"
# A referenced field's declared type bag is read tolerantly, as every other config read on the build path is.
require "axn/internal/shape_graph"
require "axn/internal/reflection/schema/vocabulary"

module Axn
  module Internal
    module Reflection
      module Schema
        # Whether a position may be omitted from its parent object, and whether it may be null there. The config-level
        # signals (`usable_default?`, `nil_tolerance_rescues_absence?`, `optional_for_schema?`) answer it for one
        # declaration; `derive_annotations` answers it once per subfield-tree node, bottom-up, into the map every
        # emission site reads (`ann`), which nothing outside this module writes. `SubfieldContradictions` asks the same
        # questions in satisfiability mode, so a declaration guard and the emitted `required` list cannot disagree
        # about what may be omitted. A top-level field that only a gate makes required gets its exact `if`/`then`
        # clause here, or its conditional requirement named when no exact clause exists.
        module Requiredness
          include Vocabulary

          # Per-node result of the single bottom-up derivation pass (derive_annotations): `required` means
          # the node must appear in its PARENT's `required` array (mirrors node_optional?'s own-level rule,
          # using the node's FULL config set — the same default `children_require_presence?` always used);
          # `nullable` means `null` is admissible on the node's OWN emitted property, decided from the
          # node's non-model representative config (the same one apply_nested_subfields!'s callers already
          # select) and its children (mirrors required_child?, hazard disjunct included). Only meaningful
          # for a node that HAS children to nest (a leaf's own nullability is decided by build_property,
          # never read from here).
          NodeAnnotation = Data.define(:required, :nullable)

          # One bottom-up pass over the whole subfield tree, computed once from build_input and threaded
          # through every emission site below (apply_nested_subfields!/apply_children!/apply_implicit_node!/
          # apply_model_id_requiredness!) instead of each of them independently re-walking the subtree via
          # subtree_requires_presence?/required_child? — the repeated-recomputation pattern that let a
          # dropped/blocked deep shape agree at some sites but not others.
          # `compare_by_identity`: SubfieldTree::Node is a plain Data value, so identity (not #==/#hash on its
          # contents) is what distinguishes one tree position from another.
          def derive_annotations(roots, satisfiability: false)
            ann = {}.compare_by_identity
            roots.each_value { |node| annotate_node!(node, ann, satisfiability:) }
            ann
          end

          # Post-order: a node's annotation only depends on its (already-annotated) children.
          def annotate_node!(node, ann, satisfiability: false)
            node.children.each_value { |child| annotate_node!(child, ann, satisfiability:) }
            credit_sibling_id_defaults!(node, ann)

            # ANCESTOR-FORCING is derived from the RELAXABLE-filtered subset of the node's configs: a route
            # whose requiredness a conditional gate can relax at runtime can't oblige an omitted/nil
            # ancestor to be present — only a route with an UNGATED nil-rejecting check can. That covers
            # both a declaration-level gate (`if:`/`unless:` on the whole declaration) AND a per-validator
            # nested gate on every check that could reject nil (e.g. `presence: { if: -> { data.present? } }`
            # — the presence is gated off when the ancestor is absent, so the omitted ancestor validates).
            # Passing the filtered subset to node_optional? (rather than the full set, then subtracting a
            # fully-gated node afterward) is what makes a MIXED node correct: a node merged from an
            # ungated-but-omittable route (e.g. `optional: true`) and a gated-required route forces nothing,
            # because its only ancestor-relevant obligation — the ungated route — is itself omittable. The
            # prior two-step form (full-set node_optional? then relax only when EVERY config is gated)
            # over-forced exactly that shape, wrongly rejecting a runtime-valid contract in satisfiability mode.
            #
            # This is the ancestor-propagation signal. Own-level emission reads the same relaxation where it
            # lists a child (`apply_child_requiredness!`), naming a requirement only a gate imposes rather than
            # listing it. Edge cases preserved: an implicit node ignores the `configs` param inside
            # node_optional? (a pure subtree test), so its ancestor-forcing is untouched; a fully-relaxable
            # node yields an empty subset, and `[].all?` is vacuously true → node_optional? true → not
            # required; an all-ungated node passes its full set (unchanged).
            # The satisfiability short-circuit inside node_optional? (the usable_default? line) still reads
            # the FULL node.configs regardless of the param, so a node-level default keeps rescuing every
            # route. Mode-independent: satisfiability mode needs it so a declared tolerance above a gated
            # child is exercisable (not dead), and strict mode honors the ancestor's own declared optionality
            # instead of inventing strictness the declaration disavowed (the design doc's "one deliberate
            # exception").
            required = !node_optional?(node, ann, node.configs.reject { |c| requiredness_conditionally_relaxable?(c) }, satisfiability:)

            if node.implicit?
              # An implicit node's nullability has no config of its own to consult (required IS the transitive
              # presence test here), so it's simply the inverse.
              nullable = !required
            else
              # required_child? (and apply_nested_subfields!'s nullability line it feeds) always reasons about
              # the node's non-model representative config — the same one apply_children! emits the property from,
              # read through the one owner of that rule (property_representative). A node with no non-model
              # config (a pure model: route) never nests, so its nullable is unused; false is an inert default.
              representative = property_representative(node.configs)
              # Read with gates closed, like every nullability the input schema emits: a gated nil-rejecting check
              # is skipped on the calls its gate closes, so a nil reaches the node then.
              nullable = representative ? nil_admitted_with_gates_closed?(representative) && !required_child?(representative, node.children, ann) : false
            end

            ann[node] = NodeAnnotation.new(required:, nullable:)
          end

          # A post-adjustment in both modes (it runs before this node's own requiredness is computed, so the
          # credit propagates up every ancestor): a model-routed child that a sibling `<key>_id` subfield can
          # rescue is re-annotated non-required. The sibling's value-level default supplies the lookup token at
          # read time (see ContractForSubfields.resolve_model_via_id), so omitting the record still resolves it,
          # and the schema requiring an ancestor the runtime lets be omitted would be stricter than the runtime.
          # What the record then answers is read off it rather than off the wire, so no wire obligation is lost.
          def credit_sibling_id_defaults!(node, ann)
            node.children.each do |key, child|
              next if child.implicit? || !ann[child].required
              next unless sibling_id_rescued?(node.children, key, child)

              ann[child] = NodeAnnotation.new(required: false, nullable: ann[child].nullable)
            end
          end

          # Whether a node's model route is rescued by a sibling `<key>_id` default — the SINGLE source of
          # truth for both the satisfiability annotation credit (credit_sibling_id_defaults!) and
          # SubfieldContradictions' per-config tolerance loop, so the two can't drift on which nodes the
          # id rescues. Three conjuncts:
          #   * the node carries a `model:` route (the record it resolves answers the subtree at runtime);
          #   * every NON-model route merged onto the node is own-level satisfiability-tolerant (a usable
          #     default or nil-accepting) — own-level only, because the model subtree is satisfied via the
          #     resolved record; it's the non-model route's OWN wire value the id can't supply (a pure-model
          #     node has no non-model route, so the empty set trivially satisfies this); AND
          #   * for EVERY model route, a sibling `<key>_id` route that its lookup would read the token from
          #     (FieldConfig.id_token_routes) carries a default usable as one (usable_id_token_default?
          #     rejects a blank literal — the model resolver blank-guards the id).
          # `siblings` is the children map holding both `node` (keyed by `key`) and the id sibling.
          def sibling_id_rescued?(siblings, key, node)
            return false unless node.configs.any? { |c| c.validations[:model] }

            non_model = node.configs.reject { |c| c.validations[:model] }
            return false unless non_model.all? { |c| usable_default?(c, subfield: true) || nil_accepted?(c) }

            sibling = siblings[Internal::FieldConfig.model_id_key(key)]
            return false if sibling.nil?

            # Credited only through the route the LOOKUP will actually read the token from, asked per model
            # route on the node via the one precedence both layers share — otherwise this credits a rescue
            # that never happens, and a nil-tolerant model whose subtree needs it would be accepted at
            # declaration and resolve nil at run time. EVERY model route must be rescued: the runtime enforces
            # each, so one route the id does not reach (another `on:` spelling, an `as:` reader) still resolves
            # nil and strands what reads through it.
            node.configs.select { |c| c.validations[:model] }.all? do |model_config|
              Internal::FieldConfig.id_token_routes(model_config, sibling.configs).any? { |c| usable_id_token_default?(c) }
            end
          end

          # Whether a nil/absent parent leaves a required nested obligation unmet — so it can't validate and
          # the parent is neither omittable nor nullable. Single source of truth for both the parent's
          # requiredness (field_optional?) and nullability (apply_nested_subfields!), so the two never disagree.
          # Two sources:
          #   * a required subfield ANYWHERE in the subtree — a nil parent yields every descendant absent
          #     (PRO-2857), so a required grandchild is stranded exactly like a required child; OR
          #   * a required shape (`do…end`) member WHEN the parent has its OWN applied default that
          #     materializes it: a top-level parent's default still resolves to its materialized value (e.g.
          #     `{}`) through the read-path reader ShapeValidator's `source:` reads, so ShapeValidator runs
          #     against the materialized value and enforces the member — omission can't be rescued by the
          #     parent's nil-tolerance. Counts a Proc default (materialization fires before
          #     the Proc's value matters — the applicability hazard). A SUBFIELD default no longer triggers
          #     this: it resolves the child's value on the read path and never synthesizes the parent, so a
          #     nil parent short-circuits ShapeValidator regardless of any descendant default.
          def required_child?(config, children, ann)
            return true if children_require_presence?(children, ann)

            config.applied_default? && synthesizable?(config) && required_shape_member?(config)
          end

          # Whether any direct child node may NOT be omitted from the parent object — a read of each child's
          # own precomputed annotation, never a fresh descent into its subtree.
          def children_require_presence?(children, ann)
            children.values.any? { |node| ann[node].required }
          end

          # Whether omitting/nil-ing this node's value strands a required descendant — the transitive
          # extension of the one-level required-child test.
          def subtree_requires_presence?(node, ann)
            children_require_presence?(node.children, ann)
          end

          # Whether a node may be absent from its parent object. An implicit node (a dotted-path
          # intermediate with no declaration of its own) is omittable exactly when nothing beneath it
          # requires presence. An explicit node follows the single-level rule at every depth: a usable
          # default always rescues omission (declaration allows a default only when `on:` names a top-level
          # reader, but a dotted field NAME can land that defaulted config on a deeper node — honored here
          # either way; a default whose contents fail a child's validators is the same accepted divergence
          # as at the top level); otherwise it must tolerate nil AND strand no required descendant — a nil
          # node yields every descendant absent (PRO-2857), so a nil-tolerant node with a required subtree is
          # NOT omittable (reflected required/non-nullable, matching runtime). With multiple configs at one node
          # (the same wire path declared via two routes) runtime enforces all of them, so the node is
          # omittable only if every config is. `configs` defaults to the whole node but may be a subset: a
          # merged node's model and non-model routes emit separate properties (`<leaf>_id` vs the object),
          # each required per its own routes' configs, not the node as a whole.
          def node_optional?(node, ann, configs = node.configs, satisfiability: false)
            return !subtree_requires_presence?(node, ann) if node.implicit?

            # Satisfiability doctrine: a default on ANY of the node's OWN configs (node.configs — the FULL
            # set, not the possibly-subset `configs` param) resolves the SHARED value at this node on the
            # read path, so it rescues omission for every route reading it. Each sibling route then validates
            # against that resolved value — being optimistic that the default satisfies each sibling's
            # validator is the satisfiability doctrine (rejection is reserved for provably dead declarations).
            # Gated on satisfiability so strict schema mode stays byte-identical to the per-config rule below.
            return true if satisfiability && node.configs.any? { |c| usable_default?(c, subfield: true) }

            configs.all? do |c|
              usable_default?(c, subfield: true) ||
                (nil_tolerance_rescues_absence?(c, satisfiability:) && !subtree_requires_presence?(node, ann))
            end
          end

          # Whether the parent's shape (`do…end`) block declares a member that isn't schema-optional.
          # A member whose every nil-rejecting check is gated is not required with its gates closed, the verdict the
          # shape's own `required` list is emitted from (`build_member_properties`).
          def required_shape_member?(config)
            named_members(config.validations.dig(:shape, :members)).any? do |m, _name|
              !optional_for_schema?(m) && !requiredness_conditionally_relaxable?(m)
            end
          end

          # Where a field its own signals do not make omittable lands: the exact clause when its gate can be
          # stated, otherwise `required` — unless only a gate imposes the requirement, which is then named on the
          # property rather than listed. Returns the property, which the first and last of those annotate.
          def apply_field_requiredness!(prop, config, tree, node, ann, klass, required:, conditionals:)
            clause = conditional_requiredness_clause(config, tree, node, klass)
            if clause
              conditionals << clause
              return state_gate_open_contract!(clause, prop, config)
            end
            return with_gated_requirement(prop, [config]) if gate_relaxes_requiredness?(config, node.children, ann)

            required << required_key(config.field)
            prop
          end

          # The exact clause names the calls the declaration gate opens, so what the field enforces on them can be
          # stated there too, beside the requirement: the property built with the declaration gate removed (its
          # own per-entry gates still close, and are still reported). The field's own property keeps only what
          # holds on every call, and its residues narrow to what the clause still cannot say. Every one of those
          # applies only on the calls the gate opens, so each is named as conditional; an `:unfixed` one keeps its
          # kind, since axn could still close it.
          def state_gate_open_contract!(clause, prop, config)
            open_config = config.with(validations: config.validations.except(*Internal::FieldConfig::CONDITIONAL_GATE_KEYS))
            open = emitted_input_property(build_property(open_config), config)
            branch = clause.key?(:then) ? :then : :else
            stated = open.except(:description, :default, RESIDUE_KEY)
            clause[branch] = clause[branch].merge(properties: { config.field => stated }) unless stated.empty?
            kept = prop.except(RESIDUE_KEY)
            residues_on(open).reduce(kept) do |acc, r|
              next record_residue(acc, r.summary, kind: r.kind, per_type: r.per_type) if r.kind == :conditional

              record_residue(acc, "#{GATED_RESIDUE}; #{r.summary}", kind: r.kind == :unfixed ? :unfixed : :conditional, per_type: r.per_type)
            end
          end

          # Whether a nil reaches this config's position unrejected on SOME call: it tolerates nil outright, or
          # every check that would reject one is gated, and so skipped on the calls the gate closes. The nullability
          # a colliding route caps a merged node by, read with gates closed like everything else emitted.
          def nil_admitted_with_gates_closed?(config)
            nil_allowed?(config) || requiredness_conditionally_relaxable?(config)
          end

          # Whether a gate is the only thing that would make this config required: every check that rejects an
          # omitted value is skipped on the calls its gate closes, and no required child forces the value to be
          # sent anyway. The schema then leaves it out of `required` and names the conditional requirement
          # instead — listing it would reject the calls whose gate is closed.
          def gate_relaxes_requiredness?(config, children, ann)
            requiredness_conditionally_relaxable?(config) && !required_child?(config, children, ann)
          end

          # A field is absent from `required` when a declared signal makes it omittable.
          def field_optional?(config, children, ann, satisfiability: false)
            has_required_child = required_child?(config, children, ann)

            # A usable default on the PARENT materializes it (with its declared contents) before validation,
            # so it may always be omitted — its own default, not its subfields, decides. (A default whose
            # contents fail a child's validators is a separate, narrow divergence handled by usable_default?.)
            return true if usable_default?(config, subfield: false)

            # The parent's own nil-tolerance (optional:/allow_nil:) only makes it omittable when no required
            # child would be stranded — so it must be checked AFTER the required-child test, not ahead of it.
            return true if nil_tolerance_rescues_absence?(config, satisfiability:) && !has_required_child

            # No parent-level omission signal remains. A subfield default resolves only the CHILD's value on
            # the read path (ContractForSubfields.resolve_value) — it never synthesizes the parent — so a
            # descendant default cannot rescue the parent's own omission. The parent's requiredness is decided
            # by its OWN signals (own default / own nil-tolerance, above) plus required-child stranding; a
            # child default fixes the child's nil, not the parent's own presence/blank obligation.
            false
          end

          # An exact JSON Schema conditional for a gated-but-otherwise-required top-level field whose
          # single Symbol condition references a declared sibling field. Ruby truthiness on a JSON value
          # is precisely "present, and neither false nor null", so the emitted clause matches the runtime
          # gate exactly. Returns nil — the field is then left out of `required` and its conditional
          # requirement named as a residue (`gate_relaxes_requiredness?`) — unless EVERY guard holds:
          #   * exactly one gate (if: XOR unless:), and its rule is a Symbol;
          #   * the Symbol resolves to a declared top-level inbound field's reader (condition_reference);
          #   * the referenced field carries no default: and no preprocess: (either can make the settled
          #     runtime value diverge from what the caller sent, flipping the gate relative to the wire)
          #     and is not model:-routed (lookup success isn't wire-expressible) nor schema-excluded;
          #   * the referenced field's type can't admit boolean coercion of a schema-admissible wire value
          #     coerce_boolean maps to false — a falsy STRING or the integer 0
          #     (boolean_coercion_can_flip_truthiness?). The flip makes the clause inexact for either gate;
          #   * (a subfield default BENEATH the referenced field needs no guard: value-level defaults
          #     resolve the child's value on the read path and never synthesize the parent — PRO-2903 —
          #     so a wire-omitted referenced field settles nil/falsey exactly as the clause reads it;
          #     a subfield preprocess likewise never materializes an absent root);
          #   * the referenced reader is the FRAMEWORK-GENERATED one — a Symbol condition names a reader
          #     method, but a user can suppress predicate generation (a pre-existing `?` method) or
          #     redefine a plain reader after `expects`, and runtime would then evaluate the USER method
          #     against the settled value while the clause conditions on the wire value. Verified via
          #     source_location against the generation site (framework_generated_reader?), pure
          #     introspection. `klass` is nil for direct build_input callers → fall back (safe direction);
          #   * the gated field is not model:-routed and has no subfields of its own (a required
          #     descendant unconditionally forces the field, contradicting a conditional requirement);
          #   * no NIL-REJECTING validator entry carries a per-validator (nested) gate key — blank or not.
          #     The clause models the DECLARATION gate; a nested gate on a nil-rejecting entry un-ties that
          #     entry from it (AM's measured per-key merge): a blank same-key override un-gates the entry
          #     (unconditionally required — clause looser than runtime), and a non-blank nested gate ties it
          #     to a different condition (also inexact). Nil-TOLERANT nested-gated entries are harmless.
          def conditional_requiredness_clause(config, tree, node, klass)
            return nil if config.validations[:model] || node.children.any?

            gates = config.validations.slice(*Internal::FieldConfig::CONDITIONAL_GATE_KEYS)
            return nil unless gates.size == 1

            # The emitted clause conditions requiredness on exactly this DECLARATION gate — exact only if
            # every nil-rejecting validator entry inherits that gate unmodified. A nested gate KEY on such an
            # entry breaks that (AM's measured per-key merge, fields.rb#validator_gate_open?): a BLANK
            # same-key nested override un-gates the entry, making it unconditionally required (clause looser
            # than runtime), while a NON-blank nested gate ties the entry to a DIFFERENT condition than the
            # clause emits (also inexact). Either way fall back (see `build_input`). Nil-TOLERANT entries never
            # reject an omitted value, so a nested gate on them can't affect requiredness — don't fall back on
            # those.
            entries = Axn::Validation::Base.validator_entries(config.validations)
            shared = shared_validation_options(config.validations)
            return nil if entries.any? { |key, opt| !nil_tolerant_validation?(key, opt, shared) && entry_mentions_gate_key?(opt) }

            rule = gates.values.first
            return nil unless rule.is_a?(Symbol)

            ref = condition_reference(rule, tree)
            return nil unless ref
            return nil if ref.validations[:model] || !ref.default.nil? || ref.preprocess
            return nil if EXCLUDED_FROM_INPUT_SCHEMA.include?(ref.field)
            return nil unless framework_generated_reader?(klass, rule)

            # Inbound boolean coercion can flip a schema-admissible truthy wire value ("false"/"f"/"0" as a
            # String, or the JSON number 0) to a falsey settled value, so the runtime gate and the emitted
            # `if` read that value differently. For an unless: gate the clause would then not require a
            # field the runtime does; for an if: gate it would keep requiring one the runtime has let go —
            # stricter, which a requirement may no more be than a bound. Either way the clause is inexact.
            return nil if boolean_coercion_can_flip_truthiness?(ref)

            condition = {
              required: [required_key(ref.field)],
              properties: { ref.field => { not: { enum: [false, nil] } } },
            }
            branch = gates.key?(:if) ? :then : :else
            { if: condition, branch => { required: [required_key(config.field)] } }
          end

          # The declared top-level inbound field a Symbol condition reads: an exact reader-name match,
          # or — for a `?`-suffixed Symbol — the boolean field whose generated predicate alias it names.
          # The condition reads the READER; the emitted schema keys by the field's WIRE key.
          def condition_reference(rule, tree)
            exact = top_level_reader_owner(tree, rule)
            return exact if exact

            name = rule.to_s
            return nil unless name.end_with?("?")

            base = top_level_reader_owner(tree, name.delete_suffix("?"))
            base if base&.boolean?
          end

          # The top-level config whose reader ANSWERS to `name`, via the tree's reader-owner index rather
          # than a scan for a config that merely spells the name: a name can be claimed by one declaration
          # while an inferred confirmation companion yields it (SubfieldTree.reader_owners), and the runtime
          # gate dispatches to the method — so the clause must key on the owner's wire key. A subfield owner
          # is no reference at all: its wire key is a nested property, and the clause names top-level ones.
          def top_level_reader_owner(tree, name)
            owner = tree.reader_owners[name.to_sym]
            owner unless owner.nil? || owner.subfield?
          end

          # Whether inbound coercion could flip the Ruby truthiness of the referenced field between its
          # wire value and its settled value — the ONLY way coercion changes a truthiness judgment, and
          # the reason an unless: gate can't be emitted declaratively for such a field. Coerce-or-leave
          # (Coercion.coerce_value) transforms String wire values through the parse-based COERCERS, and —
          # for a `:boolean` target specifically — a non-String value too (Coercion#coerce_boolean also
          # accepts an Integer, per its acceptance table: idempotent true/false, integer 0/1, and
          # FALSY_STRINGS/TRUTHY_STRINGS). Among the coercible targets (Coercion::SUPPORTED) only
          # `:boolean` maps a truthy wire value to a falsey Ruby value — Date/Time/Integer/Float/Symbol all
          # yield a truthy value from a truthy String, and a schema-valid boolean is already true/false
          # (idempotent, no flip). A flip is therefore possible only when the ref's declared type BOTH
          # (a) admits the `:boolean` coercion branch AND (b) admits some OTHER branch whose schema-valid
          # wire values include one coerce_boolean maps to false — i.e. a branch admitting a FALSY_STRINGS
          # member (a JSON `string` branch) or admitting integer `0` (a JSON `integer`/`number` branch,
          # since coerce_boolean checks `value.zero?` before any type-specific parse). A `string`+format
          # branch (Date/Time) still counts: JSON Schema treats `format` as annotation-only by default, so
          # the schema still admits an arbitrary String wire value the coercer can reach. A plain
          # `:boolean`-only property emits no other branch, so no schema-valid input can reach the falsey
          # path — no flip. AND (c) coercion isn't explicitly disabled: explicit `coerce: false` can't
          # flip; an explicit `coerce: true` can; an ABSENT flag with a coercible branch is treated as
          # flippable (the class-level `coerce_input_types` override may enable coercion, and reflection
          # must not resolve per-class config — conservative toward the safe fallback). Declared-config
          # inspection only, side-effect-free (single_type_for is pure).
          FLIPPABLE_JSON_TYPES = %w[string integer number].freeze

          def boolean_coercion_can_flip_truthiness?(ref)
            type_opt = ref.validations[:type]
            return false unless type_opt

            bag = Axn::Internal::ShapeGraph.hash_or_nil(type_opt)
            if nil.equal?(bag)
              klasses = Axn::Internal::ShapeGraph.type_tokens(type_opt)
            else
              klasses = Axn::Internal::ShapeGraph.type_tokens(bag[:klass])
              return false if bag[:coerce] == false
            end

            klasses.include?(:boolean) && klasses.any? { |k| FLIPPABLE_JSON_TYPES.include?(single_type_for(k, for_output: false)[:type]) }
          end

          # Whether the method a Symbol condition names still resolves to the reader Axn generated (not a
          # user method that would evaluate against the settled value instead of the wire value). The
          # generation site is recorded on Contract::GENERATED_READER_SOURCE_PATH; a generated reader —
          # and a boolean predicate alias, which shares the aliased definition's source_location — reports
          # that file, while a user `def` reports the declaring file. Pure introspection, side-effect-free.
          # `respond_to?(:method_defined?)` was standing in for "is this a Module" — a dispatched proxy for a
          # question `Module#===` answers directly, and one the class itself got to answer. Asked properly here,
          # then resolved through the same single method-table lookup `Values.displacing_projection` uses, so
          # the two sites no longer disagree about how this class of question is asked.
          def framework_generated_reader?(klass, rule_name)
            return false unless Axn::Internal::Identity.kind?(klass, ::Module)

            reader = Axn::Internal::NativeMethods.declared_instance_method(klass, rule_name)
            reader&.source_location&.first == Axn::Core::Contract::GENERATED_READER_SOURCE_PATH
          end

          # Optional (client may omit) iff a usable default exists, or — with no usable default — the
          # validators tolerate a nil/omitted value. Top-level `exposes` requiredness is NOT decided here:
          # `build_output` marks every top-level exposed key required directly (the serializer always emits
          # them). This method reaches a `for_output` config only for a nested shape member, which is
          # serialized from the actual value and so honors its own `optional:`/`allow_nil:`/`default:`.
          def optional_for_schema?(config, subfield: false, satisfiability: false)
            return true if usable_default?(config, subfield:)

            nil_tolerance_rescues_absence?(config, satisfiability:)
          end

          # Whether this config's nil-tolerance actually rescues an ABSENT value. It does not when the field
          # declares a literal default its own blankness checks reject: axn resolves a declared default for a nil
          # value however it arrived — an omitted key or an explicit null — so the validators see that default,
          # never nil, and the tolerance is never what decides the call. THE single definition, so requiredness
          # and nullability (which the same resolution governs) cannot disagree.
          #
          # Satisfiability mode resolves toward satisfiable and ignores the veto, matching the Proc-default rule:
          # a caller who SUPPLIES a value still has a working contract, so a dead default is no reason to reject
          # the declaration.
          def nil_tolerance_rescues_absence?(config, satisfiability: false)
            return false unless nil_accepted?(config)

            satisfiability || !blank_default_rejected?(config)
          end

          # A default lets the client omit the field (Axn applies it before validation). We judge usability
          # by declared SHAPE only — never by running the field's validators. A Proc default is unknowable at
          # declaration and counts as usable: it runs on the omitted call. For a subfield, only a truthy default
          # is applied at runtime (`next unless config.default`), so a falsey subfield default never counts.
          #
          # An empty literal default (`{}`/`""`/`[]`) makes the field omittable only when nothing here would
          # reject the synthesized blank — asked of every check that governs blankness/emptiness
          # (`blank_default_rejected?`), since either can be the one standing between the field and an empty
          # value. (A blank rejected by an author's OWN size constraint — a `length:` floor — is a
          # self-contradictory contract: the same accepted divergence as a non-blank invalid default, where
          # the schema reflects optional though the omitted call fails at runtime.)
          #
          # The emptiness check is limited to literal containers (Hash/Array/String): reflection must stay
          # side-effect-free, and calling `empty?` on an arbitrary default (e.g. an ActiveRecord::Relation or
          # other lazy collection) could issue a query or run user code. A non-literal default is present.
          def usable_default?(config, subfield:)
            # `#default` is beyond the documented member contract, so absent and nil are one answer here — both
            # mean "no default to relax the field with", which is what the original respond_to? guard did.
            value = declared_attribute(config, :default)
            return false if value.nil?
            # A Proc default is unknowable at declaration, but it DOES apply at runtime, so an omitted call
            # reaches validation with a value — requiredness is tier 1, and listing the field in `required`
            # would reject that call. Both modes resolve toward omittable. A Proc whose value then fails the
            # field's own checks is the same accepted divergence as a non-blank invalid literal default.
            return true if computed_default?(value)
            return false if broken_default?(value) || blank_default_rejected?(config)

            subfield ? config.applied_default? : true
          end

          # Whether this field's own checks would reject the blank/empty literal value its default supplies —
          # THE single definition of "can this default relax the field", read both when judging the default's
          # usability and when deciding requiredness (an omitted call resolves the default, so a rejected one
          # cannot be omitted). Two checks govern blankness and either can be the only one present, so both are
          # asked, each against the value IT rejects:
          #
          #   * a presence validator rejects a BLANK value (`presence_blank?`) — `presence: true` does,
          #     absent/`presence: false` does not, `presence: { allow_blank: true }` accepts it (`allow_nil`
          #     alone doesn't help a non-nil blank like ""/{}/[]);
          #   * `allow_empty: false`'s own check rejects an EMPTY one (`empty_default?`), which is a different
          #     value set: a whitespace-only String default is blank but not empty, and passes.
          #
          # A Proc default is unknowable at declaration (usable_default? settles it before reaching here) and a
          # non-applied subfield default supplies nothing to reject. Both checks are read with their gates closed,
          # as everything emitted is: a gated one rejects the default only on the calls its gate opens, which its
          # own gating residue names, so it does not keep the field required. A declaration guard asking this
          # only stands down more often for it, the direction a guard may always err in.
          def blank_default_rejected?(config)
            return false unless config.respond_to?(:default)

            value = config.default
            return false if value.nil? || default_invocation(value) != :literal

            validations = gate_closed_validations(config, config.validations)
            return true if presence_blank?(value) && presence_rejects_blank?(validations)

            empty_default?(value) && validations.key?(Axn::Internal::FieldConfig::NON_EMPTINESS_KEY)
          end
        end
      end
    end
  end
end
