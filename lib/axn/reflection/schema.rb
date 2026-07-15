# frozen_string_literal: true

require "date"
require "time"

require "axn/reflection/subfield_tree"

module Axn
  module Reflection
    # Builds JSON Schema (input/output) from an Axn's declared contract. Read-only, off the execution
    # path — it inspects declared field configs, never runs the action or its validators.
    #
    # REQUIREDNESS IS DERIVED FROM DECLARED SIGNALS, NOT BY VALIDATING.
    # A field is omittable (absent from `required`) when a declared signal says so — a usable default,
    # or a nil/blank-tolerant validator set (`optional:`/`allow_nil:`/`allow_blank:`/`presence: false`).
    # We deliberately do NOT run the field's validators against its default to confirm the omitted call
    # would actually pass; that duplicate-validation pass was expensive and fragile. The tradeoff is a
    # documented divergence, narrow: a non-blank but otherwise-invalid default (`type: String,
    # default: 123`; `type: :uuid, default: "nope"`) is reflected as optional though the omitted call
    # fails at runtime. The safe direction (schema stricter than runtime) never causes failed calls; the
    # unsafe case above only arises from a self-contradictory contract and surfaces as a normal,
    # recoverable validation error. A required subfield at ANY depth forces its whole ancestor chain
    # required and non-nullable (a nil/omitted ancestor yields every descendant absent, PRO-2857).
    module Schema
      TYPE_MAP = {
        String => "string",
        Symbol => "string",
        Integer => "integer",
        Float => "number",
        Numeric => "number",
        Hash => "object",
        Array => "array",
        # NOTE: TrueClass/FalseClass are intentionally absent — TypeValidator accepts only the singleton
        # value, so single_type_for reflects them as boolean + a single-member enum, not the full domain.
        Date => "string",
        DateTime => "string",
        Time => "string",
      }.freeze

      FORMAT_MAP = {
        Date => "date",
        DateTime => "date-time",
        Time => "date-time",
      }.freeze

      EXCLUDED_FROM_INPUT_SCHEMA = %i[ambient_context].freeze

      # Per-node result of the single bottom-up derivation pass (derive_annotations): `required` means
      # the node must appear in its PARENT's `required` array (mirrors node_optional?'s own-level rule,
      # using the node's FULL config set — the same default `children_require_presence?` always used);
      # `nullable` means `null` is admissible on the node's OWN emitted property, decided from the
      # node's non-model representative config (the same one apply_nested_subfields!'s callers already
      # select) and its children (mirrors required_child?, hazard disjunct included). Only meaningful
      # for a node that HAS children to nest (a leaf's own nullability is decided by build_property,
      # never read from here).
      NodeAnnotation = Data.define(:required, :nullable)

      module_function

      # Subfields nest recursively: a dotted `on:` path, a subfield of a subfield, and a dotted field
      # name all become nested object properties keyed by wire key (SubfieldTree resolves reader
      # aliases and dotted segments once, up front). A STRUCTURAL EXCLUSION remains: a deep subfield
      # whose chain passes through a `model:` parent (the client sends `<field>_id`, not the object) or
      # a non-object parent (`type: Array`, a mixed union) has no JSON-object representation, so it's
      # omitted — surfaced via dropped_deep_subfields / the input_schema warning. A depth-1 subfield
      # under such a parent is silently omitted (the parent keeps its declared type), as ever.
      #
      # `resolved:` accepts a prebuilt ResolvedSubfields artifact (the per-class cache) so callers on
      # a repeated path skip the tree build + annotation derivation; it must have been built from the
      # same configs. Without it, both are computed fresh — the standalone entry point is unchanged.
      def build_input(field_configs, subfield_configs = [], resolved: nil, klass: nil)
        tree = resolved&.tree || SubfieldTree.build(field_configs, Array(subfield_configs))
        ann = resolved&.annotations || derive_annotations(tree.roots)
        properties = {}
        required = []
        conditionals = []

        field_configs.each do |config|
          next if EXCLUDED_FROM_INPUT_SCHEMA.include?(config.field)

          node = tree.roots[config.reader_as]
          if config.validations[:model]
            # Emit the generated `<field>_id` property (don't clobber an explicitly-declared one).
            # Its requiredness/nullability is decided in the post-pass below so it can account for an
            # explicit `<field>_id` sibling regardless of declaration order.
            id_field, id_prop = model_id_property(config)
            properties[id_field] ||= id_prop
          else
            prop = build_property(config)
            apply_nested_subfields!(prop, node, ann)

            properties[config.field] = prop.compact
            unless field_optional?(config, node.children, ann)
              clause = conditional_requiredness_clause(config, field_configs, node, klass)
              clause ? conditionals << clause : required << config.field.to_s
            end
          end
        end

        # Second pass (after all properties exist, so it's independent of declaration order): decide each
        # generated model `<field>_id`'s requiredness/nullability from the model field + its explicit sibling.
        field_configs.select { |config| config.validations[:model] }.each do |config|
          children = tree.roots[config.reader_as].children
          apply_model_id_requiredness!(config, children, field_configs, properties, required, ann)
        end

        schema = { type: "object", properties: }
        schema[:allOf] = conditionals unless conditionals.empty?
        schema[:required] = required.uniq unless required.empty?
        schema
      end

      # The subfield configs build_input omits from the input schema: deep configs (a dotted `on:`
      # path, a subfield of a subfield, or a dotted field name) whose chain passes through a `model:`
      # or non-object parent, so they have no JSON-object representation. They validate at runtime but
      # are absent from the schema; a caller can surface this otherwise-silent gap. A representable deep
      # chain (every explicit ancestor object-shaped) is NOT dropped — it nests in the schema.
      # Subfields rooted at a deliberately-excluded parent (EXCLUDED_FROM_INPUT_SCHEMA, e.g.
      # ambient_context) are skipped: their absence is intentional. Side-effect-free (SubfieldTree
      # inspects declared configs only).
      def dropped_deep_subfields(field_configs, subfield_configs, resolved: nil)
        (resolved || SubfieldTree.build(field_configs, Array(subfield_configs))).dropped
      end

      # Whether a field's declared type can be represented as a JSON object (so its subfields can nest
      # as object properties): Hash, `:params`, or untyped. A `type: Array` (or other non-object) parent
      # is not — its subfields are extracted differently at runtime and have no object-property shape.
      # ANY admissible branch is object-shaped (Hash/`:params`/untyped) — so runtime's `{}` synthesis from
      # subfield defaults can satisfy the parent type (`{}` is a Hash, matching an object branch).
      def object_shaped?(config)
        object_type_branches(config).any? { |k| [Hash, :params].include?(k) }
      end

      # Whether an object (`{}`) could stand in for this config's value: its declared type must admit an
      # object AND it must not be a `model:` route (a `{}` there is rejected by ModelValidator and would
      # be preferred by the model resolver over a caller-supplied `<field>_id`). `required_child?` uses
      # this to decide whether the parent's OWN applied default materializes an object that would then
      # enforce its required shape members.
      def synthesizable?(config)
        object_shaped?(config) && !config.validations[:model]
      end

      # ALL admissible branches are object-shaped — so the subfields may nest as `properties` without
      # rejecting a valid non-object branch. A mixed union (`type: [Hash, Array]`) is NOT nestable: at
      # runtime the subfield can be read from the Array branch too (e.g. `Array#length`), so forcing
      # `type: object` would disallow a valid array input.
      def nestable_as_object?(config)
        object_type_branches(config).all? { |k| [Hash, :params].include?(k) }
      end

      # Whether the configs declared at a subfield node forbid nesting its children as object properties:
      # a `model:` route (the client sends `<field>_id`, not the object) or a non-nestable type (a
      # non-object type or a mixed union) on ANY config. Single source of truth for the drop pass
      # (SubfieldTree.path_blocked?) and emission (apply_nested_subfields!), so the two never disagree
      # on which deep structure is representable — a node the tree drops from is never re-nested in the
      # schema. Every route is enforced at runtime, so any one non-nestable route defeats nesting.
      def node_configs_block_nesting?(configs)
        configs.any? { |c| c.validations[:model] || !nestable_as_object?(c) }
      end

      def object_type_branches(config)
        type_opt = config.validations[:type]
        return [Hash] unless type_opt # untyped parent — object-shaped for both any?/all?

        Array(type_opt.is_a?(Hash) ? type_opt[:klass] : type_opt)
      end

      # The builtin scalars whose reader-method surface we judge as the class's own public methods:
      # an instance answers a segment read iff the declared class publicly defines the method
      # (post-PRO-2886 extraction: a Hash-like source reads any key; everything else is a
      # public_send). Anything outside this list — Data/Struct/custom classes, model records —
      # may answer dynamically, so it is never judged (optimistic: rejection needs proof).
      #
      # ACCEPTED DIVERGENCE from the strict no-false-rejection doctrine. TypeValidator is `is_a?`, so
      # a `type: String` value can be a String SUBCLASS that adds methods, or a plain String carrying a
      # singleton method — either is contract-valid yet answers a segment this judgment refutes. We
      # judge anyway, deliberately: the approved design takes the DECLARED class's method surface as the
      # contract (`type: String` promises the String surface, not whatever an exotic subclass bolts on),
      # so a subclass adding readers doesn't hold the declaration hostage. The conventional instance of
      # each listed class IS exactly that class, so the judgment matches real inputs; the subclass/
      # singleton case is the narrow, documented exception. The membership test below is `k <= s`, so a
      # declared class equal to (or a subclass of) a judged entry is judged on that entry's surface.
      #
      # `Numeric` and `Date` are excluded — the boundary is drawn narrower there for a different reason:
      # every contract-valid `type: Numeric` value is a STRICT subclass (Integer/Float/Rational/
      # BigDecimal/…) whose surface is wider than `Numeric` itself (`Integer#bit_length` exists but
      # `Numeric.public_method_defined?(:bit_length)` is false), and `type: Date` admits `DateTime`
      # (adding `hour`/`minute`/…). There the subclass IS the conventional instance, so judging on the
      # abstract class would refute a segment ordinary valid input answers — a real false positive — so
      # both stay optimistic, same as Data/Struct/unknown classes.
      SEGMENT_JUDGED_SCALARS = [String, Symbol, Integer, Float, Array, DateTime, Time, TrueClass, FalseClass].freeze

      # Whether ONE admissible declared branch can answer reading `segment` off its value.
      def branch_answers_segment?(branch, segment)
        return true if branch == :params

        klasses = case branch
                  when :uuid then [String]
                  when :boolean then [TrueClass, FalseClass]
                  else [branch]
                  end
        klasses.any? do |k|
          next true unless k.is_a?(Class)
          next true if k <= Hash

          judged = SEGMENT_JUDGED_SCALARS.any? { |s| k <= s }
          !judged || k.public_method_defined?(segment)
        end
      end

      # Whether a config's declared type admits SOME branch that can answer `segment`. A `model:`
      # route resolves to a record, whose method surface is never statically refutable.
      def config_answers_segment?(config, segment)
        return true if config.validations[:model]

        object_type_branches(config).any? { |branch| branch_answers_segment?(branch, segment) }
      end

      # Whether a shaped field's value serializes to a member-keyed JSON object (so advertising `object` +
      # the shape's properties on OUTPUT matches serialize_exposed). Only asserted for types with a
      # language-guaranteed member-keyed serialization: `:params`, an untyped shape (caller supplies a
      # Hash), Hash, or a Data/Struct that does NOT define its OWN `as_json`. Values.serialize_value
      # follows a value's own `as_json` before `to_h`, so a Data/Struct that overrides `as_json` may emit
      # a scalar/array/differently-keyed hash — treat it (like any reader-only or custom-`to_h` class) as
      # statically unknowable and leave it untyped on output.
      def shape_serializes_to_object?(config)
        type_klass = config.validations.dig(:type, :klass)
        return true if type_klass.nil?

        Array(type_klass).all? { |k| member_keyed_object_type?(k) }
      end

      def member_keyed_object_type?(klass)
        return true if klass == :params
        return false unless klass.is_a?(Class)
        return true if klass == Hash
        return false unless klass < Data || klass < Struct

        # A Data/Struct serializes member-keyed via its built-in to_h — unless it carries a CUSTOM as_json
        # OR a custom to_h, either of which serialize_value would follow instead (as_json first) and which
        # may emit a scalar/array/differently-keyed hash.
        !custom_serialization?(klass, :as_json) && !custom_serialization?(klass, :to_h)
      end

      # active_support reopens Data/Struct/Hash (and Object) with member-keyed `as_json`/`to_h`; those
      # owners are safe. Any other owner means the value class (or an included module) overrides the
      # method, which serialize_value would follow — so the serialized shape is no longer provably an
      # object keyed by the declared members.
      FRAMEWORK_SERIALIZATION_OWNERS = [Data, Struct, Hash, Object].freeze
      def custom_serialization?(klass, method)
        klass.method_defined?(method) && !FRAMEWORK_SERIALIZATION_OWNERS.include?(klass.instance_method(method).owner)
      end

      # One bottom-up pass over the whole subfield tree, computed once from build_input and threaded
      # through every emission site below (apply_nested_subfields!/apply_children!/apply_implicit_node!/
      # apply_model_id_requiredness!) instead of each of them independently re-walking the subtree via
      # subtree_requires_presence?/required_child? — the repeated-recomputation pattern behind PR #149's
      # rounds-5/8/9 findings (a dropped/blocked deep shape agreeing at some sites but not others).
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
        credit_sibling_id_defaults!(node, ann) if satisfiability

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
        # This is ONLY the ancestor-propagation signal. Own-level emission stays static-maximal: the
        # emission sites (apply_children!/field_optional?) call node_optional? with the full or
        # per-route config set directly, so a gated route's own nested `required` obligation is
        # unchanged. Edge cases preserved: an implicit node ignores the `configs` param inside
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
          # the node's non-model representative config — the same one apply_children! selects
          # (non_model_configs.first) before calling apply_nested_subfields!. A node with no non-model
          # config (a pure model: route) never nests, so its nullable is unused; false is an inert default.
          representative = node.configs.reject { |c| c.validations[:model] }.first
          nullable = representative ? nil_allowed?(representative) && !required_child?(representative, node.children, ann) : false
        end

        ann[node] = NodeAnnotation.new(required:, nullable:)
      end

      # Satisfiability-only post-adjustment (runs before this node's own requiredness is computed, so the
      # credit propagates up every ancestor): a model-routed child that a sibling `<key>_id` subfield can
      # rescue is re-annotated non-required. The sibling's value-level default supplies the lookup token at
      # read time (see ContractForSubfields.resolve_model_via_sibling_id), so omitting the record still
      # resolves it and the record answers the subtree; the record's attributes are unknowable at
      # declaration, so crediting the rescue is the satisfiability doctrine. STRICT (schema) mode is
      # untouched — it keeps its documented stricter-than-runtime divergence for self-referential id/model
      # subfield pairs (apply_model_id_requiredness!'s KNOWN LIMITATION).
      def credit_sibling_id_defaults!(node, ann)
        node.children.each do |key, child|
          next if child.implicit? || !ann[child].required
          next unless sibling_id_rescued?(node, key, child)

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
      #   * a sibling `<key>_id` child carries a default usable as a lookup token (usable_id_token_default?
      #     rejects a blank literal — the model resolver blank-guards the id).
      # `parent` is the node whose children include both `node` (keyed by `key`) and the id sibling.
      def sibling_id_rescued?(parent, key, node)
        return false unless node.configs.any? { |c| c.validations[:model] }

        non_model = node.configs.reject { |c| c.validations[:model] }
        return false unless non_model.all? { |c| usable_default?(c, subfield: true, satisfiability: true) || nil_accepted?(c) }

        sibling = parent.children[Internal::FieldConfig.model_id_key(key)]
        !!sibling&.configs&.any? { |c| usable_id_token_default?(c) }
      end

      # Whether a nil/absent parent leaves a required nested obligation unmet — so it can't validate and
      # the parent is neither omittable nor nullable. Single source of truth for both the parent's
      # requiredness (field_optional?) and nullability (apply_nested_subfields!), so the two never disagree.
      # Two sources:
      #   * a required subfield ANYWHERE in the subtree — a nil parent yields every descendant absent
      #     (PRO-2857), so a required grandchild is stranded exactly like a required child; OR
      #   * a required shape (`do…end`) member WHEN the parent has its OWN applied default that
      #     materializes it: a top-level parent default still writes `{}` (that write-back is unchanged),
      #     so ShapeValidator runs against the materialized value and enforces the member — omission can't
      #     be rescued by the parent's nil-tolerance. Counts a Proc default (materialization fires before
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
        # set, not the possibly-subset `configs` param) writes the SHARED wire value at this node, so it
        # rescues omission for every route reading it. The defaults write pass materializes the wire node
        # from that default, and each sibling route then validates against the written value — being
        # optimistic that the default satisfies each sibling's validator is the satisfiability doctrine
        # (rejection is reserved for provably dead declarations). Gated on satisfiability so strict schema
        # mode stays byte-identical to the per-config rule below.
        return true if satisfiability && node.configs.any? { |c| usable_default?(c, subfield: true, satisfiability: true) }

        configs.all? { |c| usable_default?(c, subfield: true, satisfiability:) || (nil_accepted?(c) && !subtree_requires_presence?(node, ann)) }
      end

      # Whether the parent's shape (`do…end`) block declares a member that isn't schema-optional.
      def required_shape_member?(config)
        Array(config.validations.dig(:shape, :members)).any? { |m| !optional_for_schema?(m) }
      end

      # A field is absent from `required` when a declared signal makes it omittable.
      def field_optional?(config, children, ann, satisfiability: false)
        has_required_child = required_child?(config, children, ann)

        # A usable default on the PARENT materializes it (with its declared contents) before validation,
        # so it may always be omitted — its own default, not its subfields, decides. (A default whose
        # contents fail a child's validators is a separate, narrow divergence handled by usable_default?.)
        return true if usable_default?(config, subfield: false, satisfiability:)

        # The parent's own nil-tolerance (optional:/allow_nil:) only makes it omittable when no required
        # child would be stranded — so it must be checked AFTER the required-child test, not ahead of it.
        return true if nil_accepted?(config) && !has_required_child

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
      # gate exactly. Returns nil — fall back to unconditional `required`, the static-maximal safe
      # direction — unless EVERY guard holds:
      #   * exactly one gate (if: XOR unless:), and its rule is a Symbol;
      #   * the Symbol resolves to a declared top-level inbound field's reader (condition_reference);
      #   * the referenced field carries no default: and no preprocess: (either can make the settled
      #     runtime value diverge from what the caller sent, flipping the gate relative to the wire)
      #     and is not model:-routed (lookup success isn't wire-expressible) nor schema-excluded;
      #   * for an unless: gate, the referenced field's type can't admit boolean coercion of a
      #     schema-admissible wire value coerce_boolean maps to false — a falsy STRING or the integer 0
      #     (boolean_coercion_can_flip_truthiness?). Coercion only flips a truthy wire value to falsey:
      #     for an if: gate that direction keeps the emitted `then`
      #     stricter than runtime (safe — still emitted), but for an unless: gate it opens the runtime
      #     `else` gate the emitted clause left closed (looser than runtime — fall back);
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
      #     descendant unconditionally forces the field, contradicting a conditional requirement).
      def conditional_requiredness_clause(config, field_configs, node, klass)
        return nil if config.validations[:model] || node.children.any?

        gates = config.validations.slice(*Internal::FieldConfig::CONDITIONAL_GATE_KEYS)
        return nil unless gates.size == 1

        rule = gates.values.first
        return nil unless rule.is_a?(Symbol)

        ref = condition_reference(rule, field_configs)
        return nil unless ref
        return nil if ref.validations[:model] || !ref.default.nil? || ref.preprocess
        return nil if EXCLUDED_FROM_INPUT_SCHEMA.include?(ref.field)
        return nil unless framework_generated_reader?(klass, rule)

        # An unless: gate treated static-maximally emits `else: required`, firing only when the
        # referenced wire value is FALSEY. But inbound boolean coercion can flip a schema-admissible
        # truthy wire value ("false"/"f"/"0" as a String, or the JSON number 0) to a falsey settled
        # value, opening the runtime gate while the emitted `if` still reads the wire value as truthy —
        # so the schema would NOT require the gated field though the runtime does (looser than
        # runtime). For an if: gate the same flip makes the schema stricter (the emitted `then` keeps
        # requiring while the runtime gate closes), so only unless: must fall back to unconditional
        # required.
        return nil if gates.key?(:unless) && boolean_coercion_can_flip_truthiness?(ref)

        condition = {
          required: [ref.field.to_s],
          properties: { ref.field => { not: { enum: [false, nil] } } },
        }
        branch = gates.key?(:if) ? :then : :else
        { if: condition, branch => { required: [config.field.to_s] } }
      end

      # The declared top-level inbound field a Symbol condition reads: an exact reader-name match,
      # or — for a `?`-suffixed Symbol — the boolean field whose generated predicate alias it names.
      # The condition reads the READER; the emitted schema keys by the field's WIRE key.
      def condition_reference(rule, field_configs)
        name = rule.to_s
        exact = field_configs.find { |c| c.reader_as.to_s == name }
        return exact if exact
        return nil unless name.end_with?("?")

        base = name.delete_suffix("?")
        field_configs.find { |c| c.reader_as.to_s == base && c.boolean? }
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

        if type_opt.is_a?(Hash)
          klasses = Array(type_opt[:klass])
          return false if type_opt[:coerce] == false
        else
          klasses = Array(type_opt)
        end

        klasses.include?(:boolean) && klasses.any? { |k| FLIPPABLE_JSON_TYPES.include?(single_type_for(k, for_output: false)[:type]) }
      end

      # Whether the method a Symbol condition names still resolves to the reader Axn generated (not a
      # user method that would evaluate against the settled value instead of the wire value). The
      # generation site is recorded on Contract::GENERATED_READER_SOURCE_PATH; a generated reader —
      # and a boolean predicate alias, which shares the aliased definition's source_location — reports
      # that file, while a user `def` reports the declaring file. Pure introspection, side-effect-free.
      def framework_generated_reader?(klass, rule_name)
        return false unless klass.respond_to?(:method_defined?) && klass.method_defined?(rule_name)

        klass.instance_method(rule_name).source_location&.first == Axn::Core::Contract::GENERATED_READER_SOURCE_PATH
      end

      # Optional (client may omit) iff a usable default exists, or — with no usable default — the
      # validators tolerate a nil/omitted value. Top-level `exposes` requiredness is NOT decided here:
      # `build_output` marks every top-level exposed key required directly (the serializer always emits
      # them). This method reaches a `for_output` config only for a nested shape member, which is
      # serialized from the actual value and so honors its own `optional:`/`allow_nil:`/`default:`.
      def optional_for_schema?(config, subfield: false, satisfiability: false)
        return true if usable_default?(config, subfield:, satisfiability:)

        nil_accepted?(config)
      end

      # A default lets the client omit the field (Axn applies it before validation). We judge usability
      # by declared SHAPE only — never by running the field's validators. A Proc default is unknowable at
      # declaration, so the two modes diverge on it (the ONLY semantic delta): strict (schema) mode
      # resolves toward required — the safe direction — while satisfiability mode (the declaration-rejection
      # detector) resolves toward satisfiable, since the Proc DOES apply at runtime and rejection is
      # reserved for provably dead declarations. For a subfield, only a truthy default is applied at runtime
      # (`next unless config.default`), so a falsey subfield default never counts.
      #
      # An empty literal default (`{}`/`""`/`[]`) makes the field omittable only when no active presence
      # validator would reject the synthesized blank: a non-optional field carries `presence: true` and so
      # stays required, but a `presence: false` field (or a type like `:params` that carries no presence)
      # accepts the blank and is optional. (A blank rejected by some OTHER validator — e.g. length — is a
      # self-contradictory contract: the same accepted divergence as a non-blank invalid default, where
      # the schema reflects optional though the omitted call fails at runtime.)
      #
      # The emptiness check is limited to literal containers (Hash/Array/String): reflection must stay
      # side-effect-free, and calling `empty?` on an arbitrary default (e.g. an ActiveRecord::Relation or
      # other lazy collection) could issue a query or run user code. A non-literal default is present.
      def usable_default?(config, subfield:, satisfiability: false)
        return false unless config.respond_to?(:default)

        value = config.default
        return false if value.nil?
        # The governing split (PRO-2889): a Proc default is unknowable at declaration. Strict (schema)
        # mode resolves toward required — the safe direction — while satisfiability mode (the
        # declaration-rejection detector) resolves toward satisfiable: the Proc DOES apply at runtime,
        # and rejection is reserved for provably dead declarations.
        return satisfiability if value.is_a?(Proc)
        return false if presence_blank?(value) && presence_rejects_blank?(config)

        subfield ? config.applied_default? : true
      end

      # Whether an active presence validator would reject a blank value, so a blank default can't relax
      # the field. `presence: true` rejects blank; absent/`presence: false` doesn't; and
      # `presence: { allow_blank: true }` skips (accepts) blank. (`allow_nil` alone doesn't help a
      # non-nil blank like ""/{}/[].)
      def presence_rejects_blank?(config)
        presence = config.validations[:presence]
        return false unless presence

        !(presence.is_a?(Hash) && presence[:allow_blank])
      end

      # A default value ActiveModel's presence validator treats as blank (and so rejects): an empty or
      # whitespace-only String, an empty Hash/Array, or `false`. Detected WITHOUT dispatching methods on
      # an arbitrary object (reflection stays side-effect-free): identity for `false`, and exact-class
      # (instance_of?) built-in containers/strings whose emptiness is a pure in-memory check — a subclass
      # could override empty?/strip. (nil is handled by the caller.)
      def presence_blank?(value)
        return true if value.equal?(false)
        return value.strip.empty? if value.instance_of?(String)
        return value.empty? if value.instance_of?(Hash) || value.instance_of?(Array)

        false
      end

      # Whether an `<field>_id` default can actually serve as a model LOOKUP token — the shared test
      # for every id-rescue site (sibling_id_rescued?, which serves both the annotation credit and the
      # contradictions loop, and SubfieldContradictions' model_omittable?). usable_default? judges a default for the FIELD's OWN
      # omission, where a blank literal ("" / {}) is usable when no presence validator rejects it — but
      # the model resolver blank-guards the id (Model#derive_value: `return nil if id_value.blank?`), so
      # a blank id default can never resolve a record and never rescues an omitted model. It must
      # therefore be satisfiability-usable AND not a blank literal. A Proc default stays optimistic
      # (unknowable at declaration), matching usable_default?'s satisfiability doctrine.
      def usable_id_token_default?(config)
        return false unless usable_default?(config, subfield: true, satisfiability: true)

        value = config.respond_to?(:default) ? config.default : nil
        return true if value.is_a?(Proc)

        !presence_blank?(value)
      end

      # Mutates `prop` to nest the node's children as `prop[:properties]`/`prop[:required]`, recursing
      # through the whole subtree. Forces the parent to `type: object` (it now has structure). The parent
      # is nullable only when it tolerates nil AND strands no required descendant: runtime treats a nil
      # parent as "subfields absent" (PRO-2857), so a nil-accepting parent with an all-optional subtree
      # accepts `null`, while a required descendant (which a nil parent can't yield) keeps it object-only.
      # Only applies when EVERY admissible parent type is object-shaped (Hash/`:params`/untyped) — a
      # non-object parent (`type: Array`) or a mixed union (`type: [Hash, Array]`) keeps its declared
      # type(s) and its subfields' shape is omitted, since object properties can't represent a non-object
      # branch (deep descendants there are in dropped_deep_subfields; its children still shape
      # requiredness via required_child?, matching runtime).
      # `node`'s own representative config (the FIRST non-model config at a merged node) shapes the
      # property itself (type, nullability) — see NodeAnnotation. `node.configs` is EVERY config at the
      # node: it decides both whether to nest at all (node_configs_block_nesting?, the same predicate the
      # drop pass uses, so a route the tree drops from is never re-nested) and, threaded on as parent
      # configs, which `shape:` members might collide with an implicit child.
      def apply_nested_subfields!(prop, node, ann)
        children = node.children
        return if children.empty?

        node_configs = node.configs
        if node_configs_block_nesting?(node_configs)
          # A non-nestable parent (non-object type, mixed union, or model route) omits its children's
          # SHAPE but NOT their OBLIGATION: field_optional? still forces the parent required when a child
          # requires presence, so its nullability must agree. A nil parent yields every descendant absent
          # (PRO-2857), stranding the required descendant, so strip the parent's `null` admission
          # (reject_null! handles both a type array and an anyOf union) — mirroring the nested-child guard
          # in apply_children!. Predicate: children_require_presence?(children), the same transitive
          # presence test as the nested analog's subtree_requires_presence?(node); required_child?'s
          # shape-synthesis clause is inert for a non-object parent, so the plain presence test is exact
          # and keeps the two sites' reasoning identical.
          reject_null!(prop) if children_require_presence?(children, ann)
          return
        end

        prop.delete(:format)
        prop[:properties] ||= {}
        prop[:required] ||= []

        apply_children!(prop, children, node_configs, ann)

        prop[:required] = prop[:required].uniq
        # A nil parent yields its subfields as absent, so `null` is admissible exactly when the parent
        # accepts nil and no required nested obligation is stranded (required_child? — which counts a
        # required shape member only when the parent's OWN default materializes it). Read from the
        # precomputed annotation (derive_annotations already applied this same rule to `node`), NOT
        # `prop[:required]`, which also carries shape members that a bare nil parent never triggers.
        prop[:type] = ann[node].nullable ? %w[object null] : "object"
        prop[:required] = nil if prop[:required].empty?
      end

      # Emits one level of children into `prop` (which must already have :properties/:required arrays),
      # recursing into each child's own subtree. `parent_configs` are the configs whose subfields these
      # children are — used to decide, by the same predicate as the drop pass, whether an implicit child
      # may merge into a colliding shape member. They are the top-level/subfield configs at an explicit
      # parent (ALL of them at a merged node, mirroring SubfieldTree), or the shape members an implicit
      # intermediate merged into (so nested members block at depth), or empty for a fresh implicit
      # intermediate that claimed no shape member.
      #
      # A single wire path can be declared via two routes (Node#configs size > 1), and the routes can
      # disagree on kind: a `model:` route emits the generated `<leaf>_id` while a plain route emits the
      # object property. Both are enforced at runtime, so both are emitted, each required per its OWN
      # route's configs — not the node as a whole.
      #
      # ACCEPTED DIVERGENCE (looser-than-runtime, the only such case here): at a merged model+non-model
      # node the non-model route's raw-key object property admits an object value that runtime ALWAYS
      # rejects — the model resolver reads the raw key as the record, and a JSON object is never a model
      # instance, so only absent/null are JSON-satisfiable. Left as-is: sending the object yields a normal,
      # recoverable validation error, and the generated `<leaf>_id` already advertises the working path.
      def apply_children!(prop, children, parent_configs, ann)
        required_model_ids = []
        children.each do |key, node|
          if node.implicit?
            apply_implicit_node!(prop, key, node, parent_configs, ann)
            next
          end

          model_configs = node.configs.select { |c| c.validations[:model] }
          non_model_configs = node.configs.reject { |c| c.validations[:model] }

          unless model_configs.empty?
            # The id key derives from the LEAF wire segment (a dotted model name digs `<leaf>_id` off
            # the same nested parent at runtime). A user may declare an explicit nested `<field>_id`
            # subfield; don't clobber it with the generic model-generated one.
            id_field = Internal::FieldConfig.model_id_key(key)
            _, subprop = model_id_property(model_configs.first)
            prop[:properties][id_field] ||= subprop
            unless node_optional?(node, ann, model_configs)
              prop[:required] << id_field.to_s
              required_model_ids << id_field
            end
          end

          representative = non_model_configs.first
          next unless representative

          child_prop = build_property(representative, subfield: true)
          apply_nested_subfields!(child_prop, node, ann)
          # `null` survives only when every non-model route tolerates nil (runtime enforces all of them;
          # the property itself is built from the first non-model config) AND no required descendant is
          # stranded — a nil node yields every descendant absent (PRO-2857), so a required one below it
          # forbids nil even for a non-object node whose subfield shape isn't nested here.
          null_ok = non_model_configs.all? { |c| nil_allowed?(c) } && !subtree_requires_presence?(node, ann)
          reject_null!(child_prop) unless null_ok
          prop[:properties][key] = child_prop.compact
          prop[:required] << key.to_s unless node_optional?(node, ann, non_model_configs)
        end
        # A required nested model id can't be null (a null token resolves the model to nil at runtime).
        # Done after the loop so it survives an explicit id subfield declared after the model: subfield.
        required_model_ids.each { |id_field| reject_null!(prop[:properties][id_field]) if prop[:properties][id_field] }
      end

      # An implicit node (a dotted-path intermediate with no declaration of its own) emits a bare object
      # property whose only content is its children. When a `shape:` member of any `parent_configs`
      # claims the key, merge into it only if EVERY colliding member is `nestable_as_object?` — the SAME
      # predicate on the SAME member configs that SubfieldTree.blocking_ancestor? uses (it scans ALL of
      # the node's configs), so emission and the drop pass agree: a non-nestable member (a scalar, or a
      # mixed union like `type: [Hash, Array]`) on ANY route blocks and its deep configs stay in
      # dropped_deep_subfields rather than forcing a self-contradictory property. The block is judged from
      # the member configs directly, NOT from a pre-seeded property: at a merged node the object property
      # is built from the first non-model config, so a scalar member declared on a LATER config seeds
      # nothing to collide with, yet must still block (matching SubfieldTree, which scans every config).
      #
      # A blocked merge omits the deep SHAPE but not the deep OBLIGATION: runtime validates the dropped
      # subfields regardless of representability, so when the dropped subtree requires presence
      # (subtree_requires_presence? — the same predicate used everywhere) the colliding member's own
      # property still inherits that obligation. The member is forced required and its `null` admission
      # stripped (reject_null! handles both `type:` arrays and `anyOf` unions) — because a nil/absent
      # member strands the required descendant (PRO-2857). Nothing else about the member is touched (no
      # forced object type, no properties — its shape stays dropped). An all-optional dropped subtree
      # strands nothing, so the member keeps its declared flags (runtime accepts omission/nil there).
      def apply_implicit_node!(prop, key, node, parent_configs, ann)
        members = shape_members_at(parent_configs, key)
        if members.any? { |member| !nestable_as_object?(member) }
          if subtree_requires_presence?(node, ann)
            prop[:required] << key.to_s
            reject_null!(prop[:properties][key]) if prop[:properties][key]
          end
          return
        end

        # Carry the (all-nestable) colliding members as the parent configs for this node's own children,
        # so a deeper implicit hop tests their NESTED shape members (a member-of-a-member). Same members
        # the drop pass carries, so the two agree at depth.
        existing = prop[:properties][key]
        target = existing || {}
        target.delete(:format)
        target[:properties] ||= {}
        target[:required] ||= []
        apply_children!(target, node.children, members, ann)
        target[:required] = target[:required].uniq
        # A fresh implicit intermediate is nullable exactly when nothing beneath requires presence (a nil
        # parent digs every descendant to nil, PRO-2857) — the precomputed annotation's bare nullable (an
        # implicit node has no config of its own to collide against). A shape-member collision additionally
        # caps it by the members' OWN nil-tolerance — nullable only when EVERY colliding member tolerates
        # nil (runtime enforces all routes), read from each config via nil_allowed? (the same predicate the
        # parent nesting uses) never sniffed off the emitted property: an untyped nil-tolerant member emits
        # no `type`, so a null branch is invisible there and property-sniffing would force it non-nullable
        # though runtime accepts a nil member. With no colliding member, an existing merge target (e.g. a
        # Data placeholder property with no shape member) falls back to non-nullable (stricter than
        # runtime), while a genuinely fresh node (no property, no member) follows its subtree.
        nullable = ann[node].nullable &&
                   (members.any? ? members.all? { |m| nil_allowed?(m) } : existing.nil?)
        target[:type] = nullable ? %w[object null] : "object"
        target[:required] = nil if target[:required].empty?
        prop[:properties][key] = target.compact
        prop[:required] << key.to_s if ann[node].required
      end

      # Every `shape:` member declared at `key` across `parent_configs` (the implicit node collides with
      # them). Each config is a top-level field config OR a shape-member config carried through implicit
      # descent; both respond to `.validations` and expose nested members via `dig(:shape, :members)`.
      def shape_members_at(parent_configs, key)
        Array(parent_configs).flat_map do |config|
          Array(config.validations.dig(:shape, :members)).select { |m| m.field.to_sym == key }
        end
      end

      # Every exposed field is always present in the serialized output: Values.serialize_exposed iterates
      # every outbound config and emits its key (value nil when unset). JSON Schema `required` means
      # property PRESENCE, not non-nullness, so every exposed field is `required`; nullability is carried
      # by the property `type` ("null").
      def build_output(field_configs)
        properties = {}
        required = []

        field_configs.each do |config|
          properties[config.field] = build_property(config, for_output: true).compact
          required << config.field.to_s
        end

        schema = { type: "object", properties: }
        schema[:required] = required.uniq unless required.empty?
        schema
      end

      # Deep-copy a reflected literal (a `default:` value or an inclusion enum member) and normalize any
      # leaf whose JSON wire form differs from its Ruby form — Time/DateTime/Date → iso8601 String,
      # Symbol → String, non-Integer/Float Numeric (BigDecimal/Rational) → Float — so the emitted
      # `default`/`enum` matches the property's advertised type. Scalar wire coercion is delegated to
      # Values.serialize_value (the single source of truth for it), so the two never drift. Mutable
      # String leaves are duped so a consumer mutating the returned schema can't reach the stored
      # contract; an unrecognized object is left as-is (schema literals are already simple values,
      # so this deliberately does NOT follow Values.serialize_value's as_json/to_h coercion).
      def normalize_schema_literal(value)
        # Only EXACT built-in containers are traversed/duped (instance_of?, not is_a?): an Array/Hash/
        # String SUBCLASS could override map/each_with_object/dup with user code, and reflection must stay
        # side-effect-free — so a subclass (like any other unrecognized object) is left opaque.
        if value.instance_of?(Hash)
          # Dup mutable String keys too (leaving them shared would let a consumer mutating a returned key
          # in place corrupt FieldConfig#default).
          value.each_with_object({}) { |(k, v), h| h[k.instance_of?(String) ? k.dup : k] = normalize_schema_literal(v) }
        elsif value.instance_of?(Array)
          value.map { |v| normalize_schema_literal(v) }
        elsif value.instance_of?(String)
          value.dup
        elsif value.is_a?(Symbol) || value.is_a?(Time) || value.is_a?(Date) || value.is_a?(Numeric)
          Values.serialize_value(value)
        else
          value
        end
      end

      # The `enum:` member list for an inclusion set. `nullable` (nil_allowed?) is the runtime truth: when
      # false, a literal `nil` member is dropped (an explicit nil is rejected there); when true, `nil` is
      # added if not already present.
      def enum_for_inclusion(enum_values, nullable:)
        members = normalize_schema_literal(enum_values)
        return members.compact unless nullable

        # Identity check, not include?/==: an enum member with a custom `==` must not run during reflection.
        members.any? { |m| m.equal?(nil) } ? members : members + [nil]
      end

      def build_property(config, for_output: false, subfield: false)
        prop = {}
        prop[:description] = config.description if config.description

        # OUTPUT safety runs the other direction from input: the property must admit a SUPERSET of
        # what the serializer can emit. A closed outbound gate skips EVERY validator (not just
        # presence), so the exposed value can be anything the action assigned — no type/format/enum/
        # default is assertable. Leave the property untyped (description only): untyped is the only
        # superset of an unconstrained value. Mirrors the module's output doctrine of leaving a value
        # untyped rather than asserting a type the serialized value could contradict.
        return prop if for_output && conditionally_gated?(config)

        # OUTPUT-EFFECTIVE validations: a per-validator (nested) gate can skip an INDIVIDUAL check on a
        # given call (`type: { klass: Integer, if: :flag }` with `flag` falsey lets a nonblank
        # wrong-typed value through), so its constraint can't be promised outbound. View the config
        # through the subset of validations that survive with EVERY gate closed — drop each entry that
        # carries a nested gate (nested_gated?), keeping ungated entries (their contributions stay —
        # a gated `inclusion:` alongside an ungated `type:` still emits the type) and any declaration-
        # level gate keys (inert here). Composes with the whole-config early return above (a fully
        # declaration-gated field is already untyped). INPUT is untouched (static-maximal). Rebuild only
        # when for_output AND an entry would actually drop, to keep config identity/perf everywhere else.
        if for_output
          effective = config.validations.reject { |_key, opt| nested_gated?(opt) }
          config = config.with(validations: effective) if effective.size != config.validations.size
        end

        type_info = json_type_for(config.validations, for_output:)
        nullable = nil_allowed?(config)
        apply_type_info!(prop, type_info, config, nullable:)

        if config.respond_to?(:default) && !config.default.nil? && !config.default.is_a?(Proc)
          # Only a truthy subfield default is applied at runtime, so a falsey `default: false` subfield
          # must not advertise a default the runtime never applies. Top-level defaults apply by key-presence.
          emit_default = subfield ? config.applied_default? : true
          prop[:default] = normalize_schema_literal(config.default) if emit_default
        end

        if (inclusion = config.validations[:inclusion])
          enum_values = inclusion[:in] || inclusion[:within] if inclusion.is_a?(Hash)
          # Exact Array only: an Array subclass could override the traversal used to build the enum, and
          # reflection must not run user code. A subclass set simply reflects no enum.
          prop[:enum] = enum_for_inclusion(enum_values, nullable:) if enum_values.instance_of?(Array)
        end

        apply_structured_schema!(prop, config, for_output:)

        prop
      end

      # Writes the resolved JSON type (and nullability/format/singleton-enum) from json_type_for into prop.
      def apply_type_info!(prop, type_info, config, nullable:)
        if type_info[:anyOf]
          members = type_info[:anyOf]
          members = drop_uuid_format(members) if type_allows_blank?(config)
          prop[:anyOf] = nullable ? members + [{ type: "null" }] : members
        elsif type_info[:type]
          prop[:type] = nullable ? [type_info[:type], "null"] : type_info[:type]
          # A `type: :uuid, allow_blank: true` field accepts "" at runtime (TypeValidator treats a blank
          # uuid as valid under allow_blank), but a strict `format: "uuid"` validator would reject "".
          # Drop the uuid format there so the schema doesn't reject a value the contract accepts.
          prop[:format] = type_info[:format] if type_info[:format] && !(type_info[:format] == "uuid" && type_allows_blank?(config))
          # A singleton type (TrueClass/FalseClass) constrains the value via enum; nil joins it when nullable.
          prop[:enum] = nullable ? type_info[:enum] + [nil] : type_info[:enum] if type_info[:enum]
        end
      end

      # Combine of: (bare element baseline) and shape: (typed member contracts) into items:/properties:.
      # Precedence: shape: enriches/overrides of: baseline.
      def apply_structured_schema!(prop, config, for_output:)
        of    = config.validations[:of]
        shape = config.validations[:shape]
        return unless of || shape

        if Array(prop[:type]).include?("array")
          items = of ? items_schema_for(of, for_output:) : {}
          # Overlay the shape's object properties onto items only when the ELEMENTS are objects. A scalar
          # `of:` (e.g. `of: String` + `field :length`) reads members off the scalar element (String#length)
          # — the elements stay strings, so forcing `type: object` would reject a valid string array. On
          # OUTPUT the element must additionally serialize member-keyed (a custom-serialization or missing
          # `of:` isn't provably an object). Input keeps object items for object-typed / untyped elements.
          if shape && shape_overlay_applies?(of, for_output:)
            member_props, required = member_properties(shape[:members], for_output:)
            base_props = items[:properties] || {}
            items = items.merge(type: "object", properties: base_props.merge(member_props))
            items[:required] = required unless required.empty?
          end
          prop[:items] = items unless items.empty?
        elsif shape
          # Hash / class field — shape: members are the object's own properties. A shaped object field IS
          # an object, even when the field's declared type: (e.g. a Data.define subclass) isn't in TYPE_MAP.
          #
          # On OUTPUT this holds only when the value serializes to a member-keyed object (its type defines
          # `to_h`). A reader-only object with no `to_h` serializes to a String (to_s) — so leave that
          # output field untyped rather than promise an `object` serialize_exposed won't produce. Input is
          # unaffected: the shape describes the JSON object a client is expected to send.
          return if for_output && !shape_serializes_to_object?(config)

          prop[:type] = nil_allowed?(config) ? %w[object null] : "object"
          prop.delete(:format)
          member_props, required = member_properties(shape[:members], for_output:)
          type_klass = config.validations.dig(:type, :klass)
          base_props = type_klass.is_a?(Class) && type_klass < Data ? type_klass.members.to_h { |m| [m, {}] } : {}
          prop[:properties] = base_props.merge(member_props)
          prop[:required] = required unless required.empty?
        end
      end

      # Whether a shape block should overlay object properties onto an array's items. OUTPUT: each element
      # must provably serialize to a member-keyed object (a plain Data/Struct/Hash `of:`). INPUT: the
      # elements must be object-typed (Hash/`:params`/Data/Struct) or untyped (no `of:` — the client sends
      # objects). A scalar `of:` (String/Integer/…) reads members off the scalar, so it is NOT overlaid.
      def shape_overlay_applies?(of_validations, for_output:)
        return shaped_items_serialize_to_object?(of_validations) if for_output
        return true unless of_validations # untyped elements: client sends objects with the shape members

        klasses = Array(of_validations[:klass])
        klasses.any? && klasses.all? { |k| object_typed_element?(k) }
      end

      # Whether an `of:` element type provably serializes to a member-keyed object (output items). Needs `of:`.
      def shaped_items_serialize_to_object?(of_validations)
        return false unless of_validations

        klasses = Array(of_validations[:klass])
        klasses.any? && klasses.all? { |k| member_keyed_object_type?(k) }
      end

      # Whether an element type is an OBJECT on the wire a client sends (input): Hash/`:params`/Data/Struct.
      def object_typed_element?(klass)
        return true if klass == :params
        return false unless klass.is_a?(Class)

        klass <= Hash || klass < Data || klass < Struct
      end

      def items_schema_for(of_validations, for_output: false)
        klasses = Array(of_validations[:klass])
        if klasses.size == 1
          single_items_schema(klasses.first, for_output:)
        else
          { anyOf: klasses.map { |k| single_items_schema(k, for_output:) } }
        end
      end

      def single_items_schema(klass, for_output: false)
        # A Data element serializes member-keyed via to_h, so its array items reflect as objects — except
        # on OUTPUT when the element isn't provably member-keyed (a custom as_json/to_h serialize_value
        # would follow); leave those items untyped rather than promise an object.
        if klass.is_a?(Class) && klass < Data && (!for_output || member_keyed_object_type?(klass))
          { type: "object", properties: klass.members.to_h { |m| [m, {}] } }
        else
          json_type_for({ type: klass }, for_output:)
        end
      end

      # A shape member's `field` is a raw declared name (`field "bar"`) that isn't symbolized at
      # declaration, so key the emitted property by its symbol — every other schema property key is a
      # Symbol (top-level `config.field`, symbolized wire keys), so this keeps a string-named member
      # (`field "bar"`) colliding with a dotted/explicit subfield (`bar.baz`) resolving to the one `:bar`
      # property that every downstream lookup (apply_implicit_node!'s `existing`, explicit-child overwrite)
      # already keys by symbol — not a String duplicate alongside it. `required` already uses `.to_s`.
      def member_properties(members, for_output:)
        props = {}
        required = []
        members.each do |m|
          props[m.field.to_sym] = build_property(m, for_output:).compact
          # On OUTPUT, a member whose presence obligation can be gated off — either wholesale by a
          # declaration-level gate, or because every nil-rejecting entry is nil-tolerant or covered by a
          # per-validator (nested) gate — can legitimately be skipped or emitted without a value by a
          # closed gate (the serializer emits no key, or a nil/blank one, for it). requiredness_conditionally_relaxable?
          # (superset of conditionally_gated?) subsumes both cases, so requiredness is dropped along with
          # (already-handled) gated constraints. INPUT stays static-maximal (a client is still expected to
          # send the member) — stricter, and safe.
          required << m.field.to_s unless optional_for_schema?(m) || (for_output && requiredness_conditionally_relaxable?(m))
        end
        [props, required]
      end

      # Returns [id_field_symbol, prop_hash] for a model: config. No type constraint: `find`/custom
      # finders accept any nonblank PK token, and inferring the real PK type would require a DB load.
      def model_id_property(config)
        model_opts = config.validations[:model]
        klass = model_opts[:klass]
        klass_name = klass.is_a?(Class) ? klass.name : klass.to_s
        id_field = Axn::Internal::FieldConfig.model_id_key(config.field)
        prop = { description: config.description || "ID of the #{klass_name} record" }
        [id_field, prop.compact]
      end

      # A model lookup needs a non-nil token. Single source of truth for the generated `<field>_id`'s
      # requiredness AND nullability, considering the model field plus any explicit `<field>_id` sibling
      # (order-independent — runs after all properties are built).
      #
      # The id is OMITTABLE only when the model field itself is omittable (a nil-tolerant model, or one
      # with its own usable default) AND no descendant requires presence per its own annotation (a
      # defaulted descendant is self-rescuing at read time). A subfield default now applies at read time
      # at any depth under a model — value-level defaults, PRO-2889, no synthesis involved — so a
      # defaulted descendant resolves to its own value and never forces the id; only a descendant with no
      # rescuing signal (no usable default, not nil-tolerant) strands an omitted record and keeps the id
      # required. OR an explicit `<field>_id` sibling carries a usable DEFAULT (inbound defaults supply
      # the token before the lookup). A merely nullable/optional explicit id with no default doesn't help.
      # When the id IS required it also can't be null, so any `null` branch is stripped.
      #
      # KNOWN LIMITATION (accepted divergence): this covers a shallow model field and its explicit shallow
      # id sibling. Self-referential id/model contracts nested under a parent (a `model:` subfield with a
      # sibling defaulted `<field>_id` subfield) are not reconciled here — the parent may reflect as
      # required though runtime synthesizes it. That is the safe direction (stricter than runtime).
      def apply_model_id_requiredness!(config, children, field_configs, properties, required, ann)
        id_field, = model_id_property(config)
        explicit_id = field_configs.find { |c| c.field == id_field }
        # A default at ANY depth under the model applies at read time (value-level defaults,
        # PRO-2889) — no synthesis is involved — so descendant omittability is the ordinary
        # annotation-derived rule, same as every other parent.
        model_omittable = optional_for_schema?(config) && !children_require_presence?(children, ann)
        return if model_omittable || (explicit_id && usable_default?(explicit_id, subfield: false))

        key = id_field.to_s
        required << key unless required.include?(key)
        reject_null!(properties[id_field]) if properties[id_field]
      end

      # Forbid `null` on a property (a required model-id token can't be null). Strips the null branch from
      # an explicit type/anyOf; for the generated id property (untyped — a model PK has no fixed JSON type)
      # there's no branch to strip, so add an explicit `not: { type: "null" }` constraint.
      def reject_null!(prop)
        if prop[:type].is_a?(Array)
          non_null = prop[:type] - ["null"]
          prop[:type] = non_null.size == 1 ? non_null.first : non_null
        elsif prop[:anyOf].is_a?(Array)
          prop[:anyOf] = prop[:anyOf].reject { |member| member[:type] == "null" }
        elsif !prop.key?(:type)
          prop[:not] = { type: "null" }
        end
      end

      def single_type_for(klass, for_output:)
        return { type: "boolean" } if klass == :boolean
        # TypeValidator accepts only the singleton value for TrueClass/FalseClass, so constrain the schema
        # to it (a bare `type: "boolean"` would let a client send the other value and pass validation).
        return { type: "boolean", enum: [true] } if klass == TrueClass
        return { type: "boolean", enum: [false] } if klass == FalseClass
        return { type: "string", format: "uuid" } if klass == :uuid
        return { type: "object" } if klass == :params

        # A declared type that ADMITS a Complex value (`type: Numeric` or `type: Complex`, i.e. Complex is
        # the class or one of its ancestors) can serialize to a JSON number (real Numerics) OR a String
        # (Complex — Float() rejects it, so Values.serialize_value falls back to to_s). Its output wire
        # form isn't knowable from the declaration, so leave it UNTYPED on output rather than assert
        # "number" the serialized value could contradict. Input still resolves below: `Numeric` maps to
        # "number" (a JSON number is a real Numeric and validates), `Complex` to the permissive "string".
        return {} if for_output && klass.is_a?(Class) && klass >= Complex

        if TYPE_MAP.key?(klass)
          result = { type: TYPE_MAP[klass] }
          result[:format] = FORMAT_MAP[klass] if FORMAT_MAP.key?(klass)
          return result
        end

        # A Numeric subclass not in TYPE_MAP (BigDecimal, Rational, …) serializes to a JSON number
        # (Values.serialize_value coerces it via Float()), so reflect it as "number" rather than the
        # object/string fallback. Complex is the exception: Float() rejects it, so on input it drops to
        # the permissive "string" below (a JSON client can't send a Complex anyway; output is handled
        # above).
        return { type: "number" } if klass.is_a?(Class) && klass < Numeric && !(klass <= Complex)

        # Unknown class: the serialized shape is only knowable at runtime (Values.serialize_value emits
        # an object for an as_json/to_h value but a string for a to_s-only one), so on output leave it
        # UNTYPED rather than assert `object` the serialized value might contradict. On input, keep a
        # permissive `string` hint (a JSON client can't send a Ruby object anyway — see the reflection
        # docs on coercing Ruby-object input types).
        return {} if for_output

        { type: "string" }
      end

      def json_type_for(validations, for_output: false)
        if validations[:type]
          type_opt = validations[:type]
          klass = type_opt.is_a?(Hash) ? type_opt[:klass] : type_opt
          type_hashes = Array(klass).map { |k| single_type_for(k, for_output:) }.uniq
          return type_hashes.first if type_hashes.size == 1

          return { anyOf: type_hashes }
        end

        if validations[:inclusion]
          inclusion = validations[:inclusion]
          enum_values = inclusion[:in] || inclusion[:within] if inclusion.is_a?(Hash)
          # Exact Array only (see build_property): don't traverse an Array subclass to infer the type.
          if enum_values.instance_of?(Array) && enum_values.any?
            types = enum_values.map { |v| enum_scalar_type(v) }.uniq
            return { type: types.first } if types.size == 1 && types.first

            # mixed (or unrecognized) value types → let `enum` constrain; emit no `type`
            return {}
          end
        end

        if validations[:numericality]
          numericality = validations[:numericality]
          return { type: "integer" } if numericality.is_a?(Hash) && numericality[:only_integer]

          return { type: "number" }
        end

        {}
      end

      def enum_scalar_type(value)
        return "string" if value.is_a?(String)
        return "integer" if value.is_a?(Integer)
        return "number" if value.is_a?(Float)

        nil
      end

      # Whether the field's validators, taken together, permit a nil/omitted value. Drives both
      # input optionality and nullability (adding "null" to the emitted type). A lone validator's
      # allow_nil: doesn't count if another (presence, type, …) still rejects nil.
      #
      # An entry is nil-tolerant if it's a disabled validator (`opt == false`), `absence` (nil is always
      # "absent"), `acceptance` unless explicitly `allow_nil: false` (ActiveModel's acceptance is allow_nil
      # by default), a Hash allowing nil/blank, an `exclusion` set not containing nil, or an `inclusion`
      # set that explicitly contains nil. Any other active validator — including a bare `true` (e.g.
      # `numericality: true`) — rejects nil.
      def nil_accepted?(config)
        # Gate keys (if:/unless:) are shared options, not validators — neutral here. The judgment is
        # static-maximal: the gated validators are counted as if their gates were open (a condition
        # can only relax enforcement at runtime, never tighten it).
        v = config.validations.except(*Internal::FieldConfig::CONDITIONAL_GATE_KEYS)
        return true if v.empty?

        v.all? { |key, opt| nil_tolerant_validation?(key, opt) }
      end

      # Whether the config's declaration carries a declaration-level if:/unless: gate — the signal
      # that its enforcement (NOT its shape) is conditional at runtime.
      def conditionally_gated?(config)
        Internal::FieldConfig::CONDITIONAL_GATE_KEYS.any? { |k| config.validations.key?(k) }
      end

      # Whether a single validator ENTRY's options carry a real per-validator (nested) if:/unless:
      # gate — `opt` is a Hash AND some CONDITIONAL_GATE_KEYS key is present with a non-blank value
      # (e.g. `presence: { if: -> { ... } }`, `type: { klass: Integer, if: :flag }`). A blank nested
      # gate (`if: nil`/`false`/`""`/`[]`) is an ActiveModel no-op (its shared condition list is empty),
      # so it does not count; a Symbol/Proc is never blank. Declaration-LEVEL blank gates are
      # canonicalized away at declaration (_canonicalize_blank_gates!), but NESTED ones are not, so
      # blankness is measured here — the same `value.blank?` rule AM applies.
      def nested_gated?(opt)
        return false unless opt.is_a?(Hash)

        Internal::FieldConfig::CONDITIONAL_GATE_KEYS.any? { |k| opt.key?(k) && !opt[k].blank? }
      end

      # Whether a config's requiredness can be RELAXED at runtime by a conditional GATE — the signal
      # that a required-looking route can't oblige an omitted/nil ancestor to be present, because a
      # closed gate skips the check that would otherwise reject the nil ancestor. True when:
      #   * the declaration carries a declaration-level gate (conditionally_gated?) — the WHOLE
      #     declaration (every validator) is gated off together; OR
      #   * a per-validator (nested) gate covers every nil-rejecting check: at least one entry is
      #     nested_gated? AND every non-gate entry is either already nil-tolerant (nil_tolerant_validation?
      #     — never rejects nil anyway) or itself nested_gated? (the check that COULD reject nil is gated
      #     off). E.g. `presence: { if: -> { data.present? } }` — the lone nil-rejecting check is gated.
      # A config with an UNGATED nil-rejecting entry (e.g. a bare `type:`) still forces its ancestors.
      #
      # The `any?(nested_gated?)` conjunct is load-bearing: a STATICALLY nil-tolerant config (`optional:`/
      # `allow_nil:`, no gate) must NOT be relaxed. Static tolerance does not skip a required child's
      # validators (a nil optional parent still strands a required descendant — PRO-2857), so such a
      # config stays in the subset for node_optional?'s subtree-stranding test to apply; dropping it would
      # vacuously (`[].all?`) mark the node omittable and lose that test. Only a GATE — which skips the
      # gated check entirely when closed — genuinely relaxes requiredness. Own-level emission is
      # unaffected (this governs ancestor propagation only; see annotate_node!).
      def requiredness_conditionally_relaxable?(config)
        return true if conditionally_gated?(config)

        entries = config.validations.except(*Internal::FieldConfig::CONDITIONAL_GATE_KEYS)
        entries.any? { |_key, opt| nested_gated?(opt) } &&
          entries.all? { |key, opt| nil_tolerant_validation?(key, opt) || nested_gated?(opt) }
      end

      def nil_tolerant_validation?(key, opt)
        return true if opt == false
        return true if opt.is_a?(Hash) && (opt[:allow_nil] || opt[:allow_blank])
        return true if key == :absence
        return true if key == :acceptance && !(opt.is_a?(Hash) && opt[:allow_nil] == false)
        return true if key == :exclusion && set_includes_nil?(opt) == false
        return true if key == :inclusion && set_includes_nil?(opt) == true

        false
      end

      # Tri-state: nil = can't tell; true/false = nil's membership in the set. Only inspected for in-memory
      # literal collections: reflection must stay side-effect-free, so a dynamic collection (e.g. an
      # ActiveRecord::Relation, whose `include?` would query the database) is treated as unknown (nil).
      # Detection is identity-based (`equal?(nil)`), never `include?`/`==`: an element with a custom `==`
      # could itself run user code. A Range's bounds are Comparable, so nil is never a member.
      # rubocop:disable Style/ReturnNilInPredicateMethodDefinition
      def set_includes_nil?(opt)
        return nil unless opt.is_a?(Hash)

        collection = opt[:in] || opt[:within]
        return false if collection.is_a?(Range)
        return nil unless collection.instance_of?(Array) || (defined?(Set) && collection.instance_of?(Set))

        collection.any? { |element| element.equal?(nil) }
      rescue StandardError
        nil
      end
      # rubocop:enable Style/ReturnNilInPredicateMethodDefinition

      def nil_allowed?(config)
        nil_accepted?(config)
      end

      # Whether the TYPE validator itself tolerates a blank value (`type: :uuid, allow_blank: true`
      # folds `allow_blank` into the type validator's options). Only the type validator's own option
      # matters for dropping `format: "uuid"` — a blank-tolerant `length:`/other validator doesn't make
      # `TypeValidator` accept `""`, so the format must stay.
      def type_allows_blank?(config)
        type = config.validations[:type]
        type.is_a?(Hash) && type[:allow_blank] == true
      end

      # Strip `format: "uuid"` from anyOf members: a blank-tolerant uuid accepts "" at runtime, which a
      # strict `format: uuid` validator would reject (mirrors the scalar-type relaxation above).
      def drop_uuid_format(members)
        members.map { |m| m[:format] == "uuid" ? m.except(:format) : m }
      end
    end
  end
end
