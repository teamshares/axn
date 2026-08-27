# frozen_string_literal: true

require "date"
require "time"

require "axn/internal/identity"
require "axn/internal/native_methods"
require "axn/internal/subfield_tree"
# A property name in an emitted schema is the canonicalization's answer, so the builder cannot load without it.
require "axn/internal/reflection/values"
# A `format:` field's `pattern` is this module's translation, so the builder cannot load without it either.
require "axn/internal/reflection/pattern"

# The `model:` id convention and the conditional-gate keys are both read on the build path, so the builder
# cannot load without their owner either.
require "axn/internal/field_config"
require "axn/internal/shape_graph"

# The graph this builder walks is one the class merely HOLDS, so the builder cannot load without the two
# bounds every such walk needs (see `guard_contents_descent`).
require "axn/internal/cycle_guard"

module Axn
  module Internal
    module Reflection
      # Builds JSON Schema (input/output) from an Axn's declared contract. Read-only, off the execution
      # path — it inspects declared field configs, never runs the action or its validators.
      #
      # REQUIREDNESS IS DERIVED FROM DECLARED SIGNALS, NOT BY VALIDATING.
      # A field is omittable (absent from `required`) when a declared signal says so — a usable default, or a
      # nil-tolerant validator set (`optional:`/`allow_nil:`/`allow_blank:`). A field that rejects nil by type
      # alone (`allow_empty: true`) stays required and non-nullable: emptiness is permitted, absence is not.
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
          # `null` is a first-class JSON type, so a declared `NilClass` has an exact spelling here. Without the
          # entry it reached single_type_for's unknown-class fallback and reflected as "string" — whose premise
          # ("a JSON client can't send a Ruby object anyway") is true of a PORO and false of nil.
          NilClass => "null",
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

        # Which JSON Schema keyword each ActiveModel comparison operator becomes. The exclusive pair is the
        # draft-06+ NUMERIC form (`exclusiveMinimum: 0`), not draft-04's boolean flag beside `minimum:`.
        NUMERIC_BOUND_KEYS = {
          greater_than: :exclusiveMinimum,
          greater_than_or_equal_to: :minimum,
          less_than: :exclusiveMaximum,
          less_than_or_equal_to: :maximum,
          equal_to: :const,
        }.freeze

        # The emitted types a numeric bound keyword applies to. A bound on any other type would be ignored by a
        # validator at best and invalid at worst, so it is not emitted there at all.
        NUMERIC_TYPES = %w[integer number].freeze

        # The two entries that compare a value against a bound, and whether ActiveModel reads an `in:` range for
        # each — `numericality:` does (`RANGE_CHECKS`), `comparison:` has no range check.
        NUMERIC_BOUND_ENTRIES = { numericality: true, comparison: false }.freeze

        # Satisfied by no value — what an unsatisfiable intersection projects to. See `apply_numeric_bounds!`.
        EMPTY_ENUM = [].freeze

        NULL_BRANCH = { type: "null" }.freeze

        FORMAT_MAP = {
          Date => "date",
          DateTime => "date-time",
          Time => "date-time",
        }.freeze

        # JSON Schema spells the emptiness floor differently per type. A type absent here (integer, boolean,
        # number) has no empty state, so no floor is expressible for it.
        SIZE_CONSTRAINT_KEYS = {
          "array" => :minItems,
          "object" => :minProperties,
          "string" => :minLength,
        }.freeze

        # The ceiling half of the same mapping. A type absent here has no size to bound.
        SIZE_CEILING_KEYS = {
          "array" => :maxItems,
          "object" => :maxProperties,
          "string" => :maxLength,
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

        # An attribute a config may or may not carry, read tolerantly: `#description` and `#default`, enumerated at
        # each call site. A `FieldConfig` answers both and a `ShapeConfig` answers `#description` only (a member is
        # reader-less, so `default:` is rejected on one), which is what this exists for — one emission path over two
        # config types, plus the configs a downstream caller builds itself and hands to the public `build_input`.
        #
        # `ShapeGraph.read` is the same tolerant read the declaration guards use, so both layers agree about what a
        # config has.
        def declared_attribute(config, name) = Axn::Internal::ShapeGraph.read(config, name)

        # A member's NAME, or nil when it has none. Even `#field` is read tolerantly, and skipped rather than
        # raised on: a DECLARED member always has one (the walk rejects a nameless member and stores a Symbol), so
        # what this tolerance is for is the configs a caller builds itself and hands to the public `build_input`.
        def member_name(member)
          name = Axn::Internal::ShapeGraph.fetch(member, :field)
          Axn::Internal::ShapeGraph.missing?(name) ? nil : name
        end

        # The `required` entry for a property keyed by `name`: a String holding the bytes that name is KEYED by.
        #
        # Rendered from a String's own bytes rather than by dispatching its `to_s`, for the same reason
        # `member_properties` renders a member's entry from the one Symbol it keyed the property by: `required` and
        # `properties` are two readers of one name, and a name that answers them differently lists a required
        # property this schema never emitted — a schema no input can satisfy. Ruby stores a plain String key as a
        # frozen copy of its bytes, so a SINGLETON `to_s` on such a name diverted the `required` entry alone, needing
        # no second declaration to go wrong.
        #
        # A Symbol keeps the rendering it always had, which is Ruby's own and cannot be overridden at all (a Symbol
        # takes no subclass instance and no singleton). So does anything else, because the property-name rules refuse
        # a name that renders through its own code (`NativeMethods.native_name_rendering?`) before any validated
        # projection returns — only the public `build_input`/`build_output` reach here with one.
        #
        # Every site that writes a `required` entry goes through this, not only the two a caller's own name can reach
        # (a top-level inbound field and an exposed one). At the others the name has already been interned to a Symbol
        # by the time it arrives — `SubfieldTree` interns a wire segment, `model_id_key` builds the generated id, and a
        # conditional-requiredness clause is emitted only for a framework-generated reader — so this is a no-op there.
        # They route through it anyway so that "what String does a `required` entry hold" has one answer rather than
        # one per site, which is how the top-level pair came to disagree with `properties` in the first place.
        def required_key(name)
          case name
          when ::String then ::String.new(name)
          else name.to_s
          end
        end

        # The members of a shape that actually name a property, paired with that name.
        # Captured through the shared seam rather than iterated directly: `Array(...)` preserves a caller's
        # Array SUBCLASS and then dispatches its `filter_map`, so a list answering that differently from `each`
        # made reflection disagree with the declaration guard and the runtime validator — which both capture with
        # `each` — about which members exist. One owned Array, three consumers.
        def named_members(members)
          Axn::Internal::ShapeGraph.capture(members).filter_map { |m| (name = member_name(m)) && [m, name] }
        end

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
        # The inbound projection OF A CLASS. The one place `build_input`'s argument list is assembled from a
        # class, so the reflected reader and the setup-time validator cannot drift into building two different
        # schemas from the same declaration.
        def build_input_for(klass)
          build_input(klass.internal_field_configs, klass.subfield_configs, resolved: klass._resolved_subfields, klass:)
        end

        def build_input(field_configs, subfield_configs = [], resolved: nil, klass: nil)
          tree = resolved&.tree || Axn::Internal::SubfieldTree.build(field_configs, Array(subfield_configs))
          ann = resolved&.annotations || derive_annotations(tree.roots)
          properties = {}
          required = []
          conditionals = []

          field_configs.each do |config|
            next if EXCLUDED_FROM_INPUT_SCHEMA.include?(config.field)

            # The config's OWN node, through the index rather than by reader name: a name can be claimed
            # by one declaration while another config yields it (SubfieldTree.build), and a config must
            # reflect its own contract — the children nested under it, the requiredness derived from them
            # — not the ones belonging to whoever holds the name.
            node = tree.index[config].node
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
                clause = conditional_requiredness_clause(config, tree, node, klass)
                clause ? conditionals << clause : required << required_key(config.field)
              end
            end
          end

          # Second pass (after all properties exist, so it's independent of declaration order): decide each
          # generated model `<field>_id`'s requiredness/nullability from the model field + its explicit sibling.
          field_configs.select { |config| config.validations[:model] }.each do |config|
            children = tree.index[config].node.children
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
        #
        # `resolved:` accepts the per-class ResolvedSubfields cache, whose `dropped` was already computed
        # from the same tree at build time (see ResolvedSubfields.build) — reading it here is a cheap
        # reader, not a recomputation. Without it, both the tree and the verdict are built fresh.
        def dropped_deep_subfields(field_configs, subfield_configs, resolved: nil)
          return resolved.dropped if resolved

          dropped_from_deep_paths(Axn::Internal::SubfieldTree.build(field_configs, Array(subfield_configs)).deep_paths)
        end

        # The judgment over a tree's deep candidates: which of the `[config, hops]` pairs SubfieldTree.build
        # collected (a config reached through more than one hop) have no JSON-object representation. Tree
        # construction only COLLECTS these — whether a chain can hold JSON object properties is a question
        # about what this layer can EMIT, so the two public entry points (this one, and dropped_deep_subfields
        # for a caller that has only configs, not a built tree) both funnel through the same private judgment.
        def dropped_from_deep_paths(deep_paths)
          compute_dropped(deep_paths)
        end

        # A deep config is dropped when a node it passes THROUGH (each hop's parent; never the leaf itself)
        # can't hold JSON object properties. Judged on the finished tree so declaration order doesn't matter.
        def compute_dropped(deep_paths)
          deep_paths.filter_map { |config, hops| config if path_blocked?(hops) }
        end

        # Walk a deep config's ancestor chain hop by hop, carrying the shape members an implicit hop merged
        # into so a deeper implicit hop can test their OWN nested shape members (a member-of-a-member).
        # `carried` is the object-shaped member configs the current node stands in for (empty for a real
        # node or a fresh implicit intermediate that claimed no shape member).
        #
        # Public: PropertyNames.emitted_configs asks this at EVERY depth (not just the deep configs
        # compute_dropped reports), because the emitter blocks a property at whichever ancestor blocks it —
        # so property attribution needs the same per-hop answer, not a second predicate that could drift.
        def path_blocked?(hops)
          carried = []
          hops.each do |node, key|
            return true if blocking_ancestor?(node, key, carried)

            carried = merged_shape_members(node, key, carried)
          end
          false
        end

        # An explicit ancestor blocks nesting when its configs forbid it (a `model:` route, or a non-object /
        # mixed-union type on any route) — node_configs_block_nesting? is the single source of truth emission's
        # apply_nested_subfields! gates on too, so the drop pass and the schema agree (they are the same method,
        # not two copies of one rule). An implicit ancestor never blocks on its own type — but descending into
        # an IMPLICIT child whose key collides with a non-object `shape:` member does: the member property
        # already claims that key with a non-object type, so the deep structure has nowhere to live. Those
        # members come from the node's own explicit configs AND every member this implicit node merged into
        # (`carried`), so a member of a member is tested at depth.
        def blocking_ancestor?(node, key, carried = [])
          return true if node_configs_block_nesting?(node.configs)
          return false unless node.children[key]&.implicit?

          colliding_shape_members(node, key, carried).any? { |m| !nestable_as_object?(m) }
        end

        # The object-shaped shape members a node (via its explicit configs or the `carried` members it merged
        # into) declares at `key`, when descending merges an implicit child there — carried into the next
        # hop. Empty when nothing merges. ALL nestable colliding members are carried (not just the first), so
        # a deeper hop tests every route's nested member; a non-nestable one would already have blocked. This
        # mirrors emission's apply_implicit_node!, which carries every colliding member.
        def merged_shape_members(node, key, carried)
          return [] unless node.children[key]&.implicit?

          colliding_shape_members(node, key, carried).select { |m| nestable_as_object?(m) }
        end

        # Every `shape:` member declared at `key` across the node's own configs AND the members carried from
        # a shallower hop — via shape_members_at, the same locator emission uses, so the two sides can't
        # disagree on which members collide with the implicit child at `key`.
        def colliding_shape_members(node, key, carried)
          shape_members_at(node.configs + carried, key)
        end

        private_class_method :compute_dropped, :blocking_ancestor?, :merged_shape_members, :colliding_shape_members

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
        # (blocking_ancestor?, via path_blocked?) and emission (apply_nested_subfields!), so the two never
        # disagree on which deep structure is representable — a node the tree drops from is never re-nested
        # in the schema. Every route is enforced at runtime, so any one non-nestable route defeats nesting.
        def node_configs_block_nesting?(configs)
          configs.any? { |c| c.validations[:model] || !nestable_as_object?(c) }
        end

        # The config a subfield node's own object property is BUILT from: the first route that is not a `model:`
        # one (a model route emits `<leaf>_id` in place of the object, so it shapes no object property). Nil at a
        # pure-model node, which emits no object property at all.
        #
        # One owner for three readers, because each of them has to name the SAME config: `apply_children!`, which
        # emits the property; `annotate_node!`, which decides its nullability; and the projection size cap, which
        # charges that config's shape and must charge no other — a second route to one wire path is enforced at
        # runtime but its `shape:`/`of:` is never emitted, so charging it rejected a contract over a schema it
        # does not have.
        def property_representative(configs) = configs.reject { |c| c.validations[:model] }.first

        def object_type_branches(config)
          type_opt = config.validations[:type]
          return [Hash] unless type_opt # untyped parent — object-shaped for both any?/all?

          declared_type_tokens(config.validations)
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
            next true unless Axn::Internal::Identity.kind?(k, ::Class)
            next true if k <= Hash

            # Read from the method table, on the same terms as `custom_serialization?` and
            # `framework_generated_reader?` — the three sites that ask this class of question now ask it one
            # way. (The `<=` comparisons around it stay dispatched: those are declared-type checks whose
            # failure mode is a self-correcting declaration error.)
            judged = SEGMENT_JUDGED_SCALARS.any? { |s| k <= s }
            !judged || Axn::Internal::NativeMethods.public_instance_method?(k, segment)
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
        #
        # Takes VALIDATIONS rather than a config because its one caller (shape_property_plan) has already
        # reduced the config to the validations the projection is built from — see effective_validations.
        def shape_serializes_to_object?(validations)
          type_klass = validations.dig(:type, :klass)
          return true if type_klass.nil?

          Axn::Internal::ShapeGraph.type_tokens(type_klass).all? { |k| member_keyed_object_type?(k) }
        end

        def member_keyed_object_type?(klass)
          return true if Axn::Internal::Identity.same?(klass, :params)
          return false unless class_token?(klass)
          return true if Axn::Internal::Identity.same?(klass, ::Hash)
          return false unless strict_descendant?(klass, ::Data) || strict_descendant?(klass, ::Struct)

          # A Data/Struct serializes member-keyed via its built-in to_h — unless it carries a CUSTOM as_json
          # OR a custom to_h, either of which serialize_value would follow instead (as_json first) and which
          # may emit a scalar/array/differently-keyed hash.
          !custom_serialization?(klass, :as_json, dispatchable_only: true) &&
            !custom_serialization?(klass, :to_h, dispatchable_only: false)
        end

        # active_support reopens Data/Struct/Hash (and Object) with member-keyed `as_json`/`to_h`; those
        # owners are safe. Any other owner means the value class (or an included module) overrides the
        # method, which serialize_value would follow — so the serialized shape is no longer provably an
        # object keyed by the declared members.
        FRAMEWORK_SERIALIZATION_OWNERS = [Data, Struct, Hash, Object].freeze
        # Read out of the method table (`NativeMethods`) rather than asked of the class: `klass` is the caller's
        # declared type, and `method_defined?`/`instance_method` are as overridable as anything else — one
        # answering wrongly inverts whether a shape is judged provable.
        #
        # `dispatchable_only:` is the visibility rule, and the two serializers need DIFFERENT ones because they
        # are reached differently. Verified by serializing each case in both environments (with and without
        # ActiveSupport's json core_ext), since the mechanism differs but the verdict does not:
        #
        #   `as_json` is reached by DISPATCH — `Values.projection_for` gates on `respond_to?` — so only a PUBLIC
        #     override displaces anything. A protected/private one cannot be called at all, the value falls
        #     through to the public built-in `to_h`, and what is emitted IS member-keyed (`{"name" => "x"}`).
        #     Counting one as custom drops `type: object` from a schema the serializer does honour.
        #
        #   `to_h` is the FALLBACK, and an override at ANY visibility shadows `Struct#to_h`, so the built-in is
        #     gone regardless: without the core_ext the value degrades to `to_s`, and with it `Struct#as_json`
        #     is `to_h.as_json` — an implicit-receiver call, which reaches a non-public override — so the
        #     override's own keys are emitted. Neither is keyed by the declared members.
        def custom_serialization?(klass, method, dispatchable_only:)
          return false unless Axn::Internal::Identity.kind?(klass, ::Module)
          return false if dispatchable_only && !Axn::Internal::NativeMethods.public_instance_method?(klass, method)

          owner = Axn::Internal::NativeMethods.declared_instance_method(klass, method)&.owner
          !owner.nil? && !FRAMEWORK_SERIALIZATION_OWNERS.include?(owner)
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
            # the node's non-model representative config — the same one apply_children! emits the property from,
            # read through the one owner of that rule (property_representative). A node with no non-model
            # config (a pure model: route) never nests, so its nullable is unused; false is an inert default.
            representative = property_representative(node.configs)
            nullable = representative ? nil_allowed?(representative) && !required_child?(representative, node.children, ann) : false
          end

          ann[node] = NodeAnnotation.new(required:, nullable:)
        end

        # Satisfiability-only post-adjustment (runs before this node's own requiredness is computed, so the
        # credit propagates up every ancestor): a model-routed child that a sibling `<key>_id` subfield can
        # rescue is re-annotated non-required. The sibling's value-level default supplies the lookup token at
        # read time (see ContractForSubfields.resolve_model_via_id), so omitting the record still
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
        #   * a sibling `<key>_id` route that this model's lookup would read the token from
        #     (FieldConfig.id_token_routes) carries a default usable as one (usable_id_token_default?
        #     rejects a blank literal — the model resolver blank-guards the id).
        # `parent` is the node whose children include both `node` (keyed by `key`) and the id sibling.
        def sibling_id_rescued?(parent, key, node)
          return false unless node.configs.any? { |c| c.validations[:model] }

          non_model = node.configs.reject { |c| c.validations[:model] }
          return false unless non_model.all? { |c| usable_default?(c, subfield: true, satisfiability: true) || nil_accepted?(c) }

          sibling = parent.children[Internal::FieldConfig.model_id_key(key)]
          return false if sibling.nil?

          # Credited only through the route the LOOKUP will actually read the token from, asked per model
          # route on the node via the one precedence both layers share — otherwise this credits a rescue
          # that never happens, and a nil-tolerant model whose subtree needs it would be accepted at
          # declaration and resolve nil at run time.
          node.configs.select { |c| c.validations[:model] }.any? do |model_config|
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
          return true if satisfiability && node.configs.any? { |c| usable_default?(c, subfield: true, satisfiability: true) }

          configs.all? do |c|
            usable_default?(c, subfield: true, satisfiability:) ||
              (nil_tolerance_rescues_absence?(c, satisfiability:) && !subtree_requires_presence?(node, ann))
          end
        end

        # Whether the parent's shape (`do…end`) block declares a member that isn't schema-optional.
        def required_shape_member?(config)
          named_members(config.validations.dig(:shape, :members)).any? { |m, _name| !optional_for_schema?(m) }
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
          # clause emits (also inexact). Either way fall back to unconditional required (the static-maximal
          # safe direction). Nil-TOLERANT entries never reject an omitted value, so a nested gate on them
          # can't affect requiredness — don't fall back on those.
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
        # then resolved through the same single method-table lookup `custom_serialization?` uses, so the two
        # sites no longer disagree about how this class of question is asked.
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
          return true if usable_default?(config, subfield:, satisfiability:)

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
        # declaration, so the two modes diverge on it (the ONLY semantic delta): strict (schema) mode
        # resolves toward required — the safe direction — while satisfiability mode (the declaration-rejection
        # detector) resolves toward satisfiable, since the Proc DOES apply at runtime and rejection is
        # reserved for provably dead declarations. For a subfield, only a truthy default is applied at runtime
        # (`next unless config.default`), so a falsey subfield default never counts.
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
        def usable_default?(config, subfield:, satisfiability: false)
          # `#default` is beyond the documented member contract, so absent and nil are one answer here — both
          # mean "no default to relax the field with", which is what the original respond_to? guard did.
          value = declared_attribute(config, :default)
          return false if value.nil?
          # The governing split (PRO-2889): a Proc default is unknowable at declaration. Strict (schema)
          # mode resolves toward required — the safe direction — while satisfiability mode (the
          # declaration-rejection detector) resolves toward satisfiable: the Proc DOES apply at runtime,
          # and rejection is reserved for provably dead declarations.
          return satisfiability if value.is_a?(Proc)
          return false if blank_default_rejected?(config)

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
        # non-applied subfield default supplies nothing to reject. Gates are deliberately not consulted, as
        # everywhere else on the input side: a gated check is counted as if it ran.
        def blank_default_rejected?(config)
          return false unless config.respond_to?(:default)

          value = config.default
          return false if value.nil? || value.is_a?(Proc)
          return true if presence_blank?(value) && presence_rejects_blank?(config.validations)

          empty_default?(value) && config.validations.key?(Axn::Internal::FieldConfig::NON_EMPTINESS_KEY)
        end

        # Whether an active `presence:` check here rejects every blank value: one is declared and it is not
        # blank-tolerant. THE single definition, read by the blank-default judgment and by the size-floor
        # emission. A truthy non-Hash entry carries no tolerance, so it rejects blank.
        def presence_rejects_blank?(validations)
          presence = validations[:presence]
          return false unless presence

          opts = effective_entry_options(presence, Axn::Validation::Base.shared_validation_options(validations))
          !opts[:allow_blank]
        end

        # Whether an empty value is rejected by something OTHER than the author's own `length:` — either
        # `allow_empty: false`'s own check or a live presence check (every empty value is blank, so a presence
        # check that rejects blank rejects every empty value). THE question "can an empty value get through
        # here", which decides both the fallback floor of 1 and whether a blank-tolerant `length:` still
        # contributes its floor.
        def empty_value_rejected?(validations)
          return true if validations.key?(Axn::Internal::FieldConfig::NON_EMPTINESS_KEY)

          presence_rejects_blank?(validations)
        end

        # Parameters is identified by rendered class NAME rather than by the constant: this file is one an adapter
        # gem loads directly, and naming a Rails constant here would put an unresolvable reference in its load graph
        # for every consumer running without Rails. It is the same identify-by-name form TypeValidator already uses
        # to recognize a test double, and the rendering is read natively (`Internal::ClassName.of_module`) so a class
        # cannot answer this question for itself.
        PARAMS_CLASS_NAME = "ActionController::Parameters"

        # The container classes whose `empty?` is RUBY'S OWN — the ones the emptiness axis is declared on. `Set` sits
        # behind `defined?` because `set` is not always loaded.
        EMPTY_CONTAINER_CLASSES = [::Hash, ::Array, ::String].freeze

        # Whether a default is an EMPTY container, decided by WHOSE `empty?` would answer it. Ownership is the whole
        # test, because it separates the two things a subclass can be: one that INHERITS the built-in's `empty?`
        # answers with Ruby's own code, so running it is safe and its empty instance is as empty as the built-in's;
        # one that OVERRIDES it (or carries a singleton) is caller code, which a reflection verdict must not run —
        # and not recognizing it is also what matches the runtime, since that same override is what the emptiness
        # check will ask. Anything else — a lazy collection, an arbitrary object — is unrecognized for the same
        # reason, so no `empty?` of a caller's writing is ever dispatched here.
        #
        # The owner read is bound (`NativeMethods.method_owner`); the call that follows it needs no guard, because
        # the implementation it dispatches is the one whose owner was just established.
        def empty_container?(value)
          owner = Axn::Internal::NativeMethods.method_owner(value, :empty?)
          return false unless owner && native_empty_owner?(owner)

          value.empty?
        end

        # How many elements a literal holds, or nil where a check could measure it differently. Read where a
        # declared literal has to be weighed against the sizes a contract admits (the empty-interval guard's
        # inclusion branch).
        #
        # FOUR checks can hold a size bound, and each asks the value by a different method — the complete list:
        #
        #   `length:`             `value.length`   (activemodel 8.1.3.1, length.rb:48)     floor and ceiling
        #   `presence:`           `value.blank?`   (presence.rb)                           floor
        #   the emptiness check   `value.empty?`   (NonEmptinessValidator)                 floor
        #   `absence:`            `value.present?` (absence.rb)                            ceiling
        #
        # Which check holds a given bound is not this method's to know — the floor of 1 is `presence:`'s on one
        # declaration and `length:`'s on the next — so a value is measured only where every one of them is
        # Ruby's own, and there they agree by construction. `size` is deliberately not among them: no check
        # asks it, and reading it is how an `Array` subclass overriding `length` was measured as empty here
        # while `length:` and `inclusion:` both accepted it at runtime.
        #
        # And a bound-holding check does not reach its measurement directly: it asks the value whether it CAN
        # answer first, and takes a different measurement when the answer is no. `length:` reads
        # `value.respond_to?(:length) ? value.length : value.to_s.length`, and ActiveSupport's `Object#blank?`
        # is `respond_to?(:empty?) ? !!empty? : false`. So the capability probe is part of the measurement, and
        # a value carrying its own `respond_to?` is measured by an answer IT wrote however native the method
        # that answer names: an exact `Array` answering `false` for `:length` is measured as `"[]"` — two
        # characters — and not as `Array#length`'s zero, so a floor of 2 it appears to fail is one it meets.
        # `respond_to?` is therefore on the list beside the four measurements it selects between.
        #
        # That override is not deception to be refused: answering for a method it forwards is the ordinary
        # shape of a proxy or delegator, which is why axn's own emptiness check asks the capability through a
        # BOUND `Object#respond_to?` (`NonEmptinessValidator::CAPABILITY_CHECK`) rather than trusting the
        # value's answer. ActiveModel dispatches it, so a declaration weighing what ActiveModel will measure
        # has to count the caller's answer as part of the measurement — reading the unforgeable one here would
        # measure something no check performs.
        #
        # The list grows with the bounds. `present?` belongs to it because PRO-3220 taught `absence:` to name a
        # ceiling; adding that bound without revisiting this list is what let a member answering
        # `present? => false` be weighed against a ceiling it does not obey.
        #
        # Ownership is the whole test, the same one `empty_container?` applies and for the same reason: a
        # measurement a caller wrote is caller code, which a declaration-time verdict must neither run nor
        # second-guess. Standing down leaves the declaration legal, the direction this guard must err in.
        #
        # The owner reads are bound (`NativeMethods.method_owner`); the call that follows needs no guard,
        # because the implementation it dispatches is the one whose owner was just established.
        def container_size(value)
          return nil unless ASKED_BY_A_BOUNDING_CHECK.all? { |method_name| natively_answered?(value, method_name) }

          value.length
        end

        # The methods the BLANK axis asks a value by: ActiveModel's presence/absence validators call `blank?`
        # and `present?`, and ActiveSupport's generic pair answers out of `empty?` behind a `respond_to?` probe.
        # `length` is deliberately absent — blankness is not size, which is the whole reason a `String` member
        # needs this at all.
        ASKED_BY_THE_BLANK_AXIS = %i[blank? present? empty? respond_to?].freeze

        # Whether this value's BLANKNESS is Ruby's own to answer, on exactly the terms `container_size` applies
        # to its measurement and for the same reason: a member whose `present?` or `blank?` is its own decides
        # for itself whether an `absence:` accepts it, and a declaration-time verdict may neither run that code
        # nor second-guess it. Answering false stands the judgment down, which leaves the declaration legal.
        def blankness_natively_answered?(value)
          ASKED_BY_THE_BLANK_AXIS.all? { |method_name| natively_answered?(value, method_name) }
        end

        # Every method a check that holds a size bound asks the value by — the four measurements plus the
        # `respond_to?` those checks select between them with. All must be Ruby's own, so the order is
        # immaterial.
        ASKED_BY_A_BOUNDING_CHECK = %i[length empty? blank? present? respond_to?].freeze

        # `Object` and `Kernel` are admitted as owners, and neither can end up owning a MEASUREMENT here:
        # `Object` only ever owns `blank?`/`present?` and `Kernel` only ever owns `respond_to?`, since none of
        # them defines `length` or `empty?`. ActiveSupport's `Object#blank?` is
        # `respond_to?(:empty?) ? !!empty? : false` and its `present?` is `!blank?`, so both answer out of the
        # very `empty?` this method has already required to be native: for a `Set`, whose blankness AS does not
        # specialize, that is the whole reason a member is measurable at all. `Kernel#respond_to?` is Ruby's
        # own capability probe, which every value answers with until one carries an override.
        def natively_answered?(value, method_name)
          owner = Axn::Internal::NativeMethods.method_owner(value, method_name)
          return false if owner.nil?

          native_empty_owner?(owner) || ::Object.equal?(owner) || ::Kernel.equal?(owner)
        end

        def native_empty_owner?(owner)
          return true if EMPTY_CONTAINER_CLASSES.any? { |klass| klass.equal?(owner) }
          return true if defined?(Set) && ::Set.equal?(owner)

          # The rendered name is a Ruby-made String (the bound `Module#to_s`), so comparing it dispatches String's
          # own `==` whatever the owner is.
          Axn::Internal::ClassName.of_module(owner) == PARAMS_CLASS_NAME
        end

        # A default value ActiveModel's presence validator treats as blank (and so rejects): `false`, a
        # whitespace-only String, or an empty container. (nil is handled by the caller.)
        def presence_blank?(value)
          return true if value.equal?(false)
          return value.strip.empty? if value.instance_of?(String)

          empty_container?(value)
        end

        # Whether a default is EMPTY — the question `allow_empty: false`'s own check asks of a value, which is
        # not blankness: a whitespace-only String is blank but not empty, and `false` has no empty state at all.
        def empty_default?(value) = empty_container?(value)

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

          value = declared_attribute(config, :default)
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
            # The object property is built from ONE of them; see property_representative, which every layer that
            # has to name that config reads (requiredness annotation, and the size cap's shape charge).

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

            representative = property_representative(node.configs)
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
            prop[:required] << required_key(key) unless node_optional?(node, ann, non_model_configs)
          end
          # A required nested model id can't be null (a null token resolves the model to nil at runtime).
          # Done after the loop so it survives an explicit id subfield declared after the model: subfield.
          required_model_ids.each { |id_field| reject_null!(prop[:properties][id_field]) if prop[:properties][id_field] }
        end

        # An implicit node (a dotted-path intermediate with no declaration of its own) emits a bare object
        # property whose only content is its children. When a `shape:` member of any `parent_configs`
        # claims the key, merge into it only if EVERY colliding member is `nestable_as_object?` — the SAME
        # predicate on the SAME member configs that blocking_ancestor? uses (it scans ALL of
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
              prop[:required] << required_key(key)
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
          prop[:required] << required_key(key) if ann[node].required
        end

        # Every `shape:` member declared at `key` across `parent_configs` (the implicit node collides with
        # them). Each config is a top-level field config OR a shape-member config carried through implicit
        # descent; both respond to `.validations` and expose nested members via `dig(:shape, :members)`.
        def shape_members_at(parent_configs, key)
          Array(parent_configs).flat_map do |config|
            named_members(config.validations.dig(:shape, :members)).filter_map { |m, name| m if name.to_sym == key }
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
            required << required_key(config.field)
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
            normalize_scalar_literal(value)
          else
            value
          end
        end

        # A literal the serializer refuses outright — a non-finite `default: Float::INFINITY`, which no JSON
        # `default` could carry — is reported exactly as declared. Reflection describes a declaration and must
        # never raise on user data, and a reflected literal makes no encodability promise; `serialize_exposed`'s
        # output, which does make one, is where that refusal belongs.
        def normalize_scalar_literal(value)
          Values.serialize_value(value)
        rescue Axn::Extensions::Serialization::UnserializableValue
          value
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

        # On OUTPUT an enum names what the action may PRODUCE, so it has to hold the wire form of every value the
        # runtime accepts — and the runtime accepts by Ruby `==`, which can identify values that SERIALIZE
        # differently. Two DateTimes for one instant in different offsets are `==` and render as different
        # ISO-8601 strings; a Date is `==` to a DateTime at midnight and renders shorter; `1 == 1.0` renders as
        # `1` and `1.0`. Each emits a set that rejects the action's own successful output.
        #
        # A member settles this for itself wherever its equality admits only its own type: a String, a Symbol,
        # `true`, `false` and `nil` can only be `==` to a value that serializes identically, whatever class the
        # position declares. A numeric member cannot, Ruby's tower crossing types, so it asks the position to pin
        # exactly one numeric class — which is what keeps `type: Integer, inclusion: { in: [200, 404] }`
        # reflecting. Anything else — a Time, a Date, an arbitrary object — stands the set down.
        #
        # INPUT needs no gate: there the emitted set is the values a client may SEND, and a set narrower than the
        # runtime's equality is stricter, which is the licensed direction.
        def output_enum_exact?(members, validations, declared_klass)
          members.all? do |member|
            case member
            when ::String, ::Symbol, ::TrueClass, ::FalseClass, ::NilClass then true
            when ::Numeric then numeric_enum_pinned?(member, validations, declared_klass)
            else false
            end
          end
        end

        # Whether the position admits exactly the numeric class this member already is, so that no OTHER numeric
        # type can be `==` to it and serialize differently. A position naming no class at all admits the whole
        # tower and cannot pin anything.
        def numeric_enum_pinned?(member, validations, declared_klass)
          tokens = declared_type_tokens(validations, declared_klass)
          return false if tokens.empty?

          tokens.all? { |token| Internal::Identity.same?(token, Internal::Identity.class_of(member)) }
        end

        # The classes a position declares: a `type:` bag's `klass:` where a bag was declared, the bare spelling
        # otherwise, and a `declared_klass` handed in directly by a CONTENTS position — a bag names its classes
        # under `klass:`, which `bag_value_constraints` deliberately drops from the validator set, so that
        # caller has them already and passes them through.
        #
        # Every branch classifies through `ShapeGraph.type_tokens` rather than `Kernel#Array`, which DISPATCHES
        # `to_ary`/`to_a` on whatever it is handed: a declared token is a caller's own Class or Module, and one
        # carrying a singleton `to_ary` would have that method RUN from here — at declaration, and again from
        # every reflection — which reflection may never do. Measured on a token whose `to_ary` returns
        # `[String]`: it ran, and the emitted node became `{type: ["string", "null"]}` for a field declared as
        # that token. The bag is unwrapped through `ShapeGraph.hash_or_nil` for the same reason, so a Hash
        # subclass denying its own class cannot pick how it is read.
        def declared_type_tokens(validations, declared_klass = nil)
          return Axn::Internal::ShapeGraph.type_tokens(declared_klass) unless nil.equal?(declared_klass)

          type_opt = validations[:type]
          bag = Axn::Internal::ShapeGraph.hash_or_nil(type_opt)

          Axn::Internal::ShapeGraph.type_tokens(nil.equal?(bag) ? type_opt : bag[:klass])
        end

        # The literal membership set of an `inclusion:` validator, whether declared as the hash long form
        # ({ in: [...] } / { within: [...] }) or the equivalent bare-Array shorthand (inclusion: %w[a b c]).
        # The two enforce the same set at runtime, so reflection treats them identically (PRO-2944). Exact
        # Array only (instance_of?, not is_a?): an Array subclass could override the map/each the enum and
        # type inference downstream depend on, and reflection must never run user code — a subclass set (or a
        # dynamic Symbol/Proc source) simply reflects no enum (returns nil).
        def inclusion_enum_values(inclusion)
          values = Axn::Validation::Base.declared_set_collection(inclusion)
          values if values.instance_of?(Array)
        end

        def build_property(config, for_output: false, subfield: false, ancestry: nil)
          prop = {}
          # `#description` is beyond the documented member contract (see declared_attribute).
          description = declared_attribute(config, :description)
          prop[:description] = description if description

          # OUTPUT safety runs the other direction from input: the property must admit a SUPERSET of
          # what the serializer can emit. A closed outbound gate skips EVERY validator (not just
          # presence), so the exposed value can be anything the action assigned — no type/format/enum/
          # default is assertable. Leave the property untyped (description only): untyped is the only
          # superset of an unconstrained value. Mirrors the module's output doctrine of leaving a value
          # untyped rather than asserting a type the serialized value could contradict.
          return prop if for_output && conditionally_gated?(config)

          # OUTPUT-EFFECTIVE validations (see effective_validations, the one derivation of them): everything
          # below reads the config through that subset, so a per-validator gate drops the same entry here as
          # in the plan every property-name rule is charged against. Rebuild the config only when an entry
          # actually drops, judged against the SAME read of `validations` the reduction was given — a
          # caller-supplied member's reader may mint a fresh Hash per read, so comparing against a second read
          # would rebuild every config (and a duck-typed member answers no `with` at all).
          declared = config.validations
          effective = effective_validations(declared, for_output:)
          config = config.with(validations: effective) unless effective.equal?(declared)

          type_info = json_type_for(config.validations, for_output:)
          nullable = nil_allowed?(config)
          apply_type_info!(prop, type_info, config, nullable:)

          declared_default = declared_attribute(config, :default)
          if !declared_default.nil? && !declared_default.is_a?(Proc)
            # Only a truthy subfield default is applied at runtime, so a falsey `default: false` subfield
            # must not advertise a default the runtime never applies. Top-level defaults apply by key-presence.
            emit_default = subfield ? config.applied_default? : true
            prop[:default] = normalize_schema_literal(declared_default) if emit_default
          end

          apply_structured_schema!(prop, config, for_output:, ancestry:)

          # LAST, because the floor's KEY is chosen from the property's type (`minItems`/`minProperties`/
          # `minLength`) and a shape block is what establishes that type: a custom class or module carrying one
          # holds the permissive fallback until `apply_structured_schema!` rewrites it to `object`. Deriving
          # the key any earlier reads an intermediate type and lands the floor under a key that cannot express
          # it. Nothing above depends on the constraint already being there.
          apply_value_constraints!(prop, config.validations, nullable:, for_output:)

          prop
        end

        # Writes the resolved JSON type (and nullability/format/singleton-enum) from json_type_for into prop.
        def apply_type_info!(prop, type_info, config, nullable:)
          if type_info[:anyOf]
            members = type_info[:anyOf]
            members = drop_uuid_format(members) if type_allows_blank?(config)
            members = union_with_nullability(members, nullable:)
            # Dropping a token-derived null branch can leave a single member, and a one-branch `anyOf` is a
            # gratuitous shape change for a declaration whose node was a plain `type:` before. Collapse it back
            # onto the single-type path, which is also what lets the emptiness floor land at the node rather than
            # inside a lone branch. Only reachable when NOT nullable — a nullable union always keeps two.
            if members.size == 1
              apply_single_type!(prop, members.first, config, nullable: false)
            else
              prop[:anyOf] = members
            end
          elsif type_info[:type]
            apply_single_type!(prop, type_info, config, nullable:)
          elsif type_info[:enum]
            # A type_info carrying only an enum names no type and still constrains the value — which is how a
            # contract nothing satisfies reaches the node, as `enum: []`. Nullability joins it exactly as it
            # joins a singleton's enum above: a narrowing that empties every TYPE branch has said nothing about
            # nil, which the validators SKIP wherever the field tolerates one. So `type: String, numericality:
            # { only_numeric: true }, optional: true` admits nil and nothing else — measured, it exposes nil
            # successfully — and the bare empty set rejected the very value it accepts.
            prop[:enum] = nullable ? type_info[:enum] + [nil] : type_info[:enum]
          end
        end

        def apply_single_type!(prop, type_info, config, nullable:)
          if unsatisfiable_type?(type_info[:type], nullable:)
            prop[:enum] = EMPTY_ENUM
            return
          end

          prop[:type] = type_with_nullability(type_info[:type], nullable:)
          # A `type: :uuid, allow_blank: true` field accepts "" at runtime (TypeValidator treats a blank
          # uuid as valid under allow_blank), but a strict `format: "uuid"` validator would reject "".
          # Drop the uuid format there so the schema doesn't reject a value the contract accepts.
          prop[:format] = type_info[:format] if type_info[:format] && !(type_info[:format] == "uuid" && type_allows_blank?(config))
          # A singleton type (TrueClass/FalseClass) constrains the value via enum; nil joins it when nullable.
          prop[:enum] = nullable ? type_info[:enum] + [nil] : type_info[:enum] if type_info[:enum]
          # A pattern the TYPE resolution put there (`only_integer:` on a string branch) travels with it. Without
          # this it survived a union and was dropped the moment the union collapsed to one branch — the same node,
          # reached by two paths, saying two different things. A declared `format:` still overwrites it later,
          # one schema object having only the one slot.
          prop[:pattern] = type_info[:pattern] if type_info[:pattern]
        end

        # Whether the emitted type admits `null` is the NULLABILITY question (`nil_allowed?`), never something a
        # type token decides. A declared `NilClass` contributes a branch like any other token; this is where that
        # branch is kept or dropped, so the two cannot disagree. Without it a REQUIRED `type: [String, NilClass]`
        # would advertise `null` while its own `presence:` entry rejects nil, and a nullable one would advertise
        # it twice.
        def union_with_nullability(members, nullable:)
          without_null = members.reject { |member| member[:type] == "null" }
          return without_null + [NULL_BRANCH] if nullable

          # A union of nothing BUT null cannot arise (`json_type_for` uniq's, so it would be a single type), but
          # stripping to an empty `anyOf` would emit a node no value satisfies, so the guard is kept rather than
          # left to an argument about reachability.
          without_null.empty? ? members : without_null
        end

        # A lone `NilClass` keeps its `"null"` only where nullability would have added it anyway. NOT nullable,
        # the contract admits nothing at all — nothing is a NilClass except nil, and the check that makes it
        # non-nullable rejects nil — and `"null"` then advertised the single value the contract rejects, which is
        # schema LOOSER than runtime, the one direction reflection may never err in. See `unsatisfiable_type?`.
        def type_with_nullability(type, nullable:)
          return type if type == "null"

          nullable ? [type, "null"] : type
        end

        # Whether the emitted type names a contract no value satisfies, which is true of exactly one pairing: a
        # lone `"null"` that is not nullable. `enum: []` is the faithful node for it — the spelling this emitter
        # already uses wherever a contract admits nothing (an `only_integer:` narrowing that empties a union,
        # two disagreeing `equal_to:` bounds) — and it is emitted INSTEAD of the type rather than beside it, so
        # none of the keyword passes that key off a type can land on a node nothing reaches. Refusing such a
        # declaration outright stays PRO-3220's, exactly as it does for the other two.
        def unsatisfiable_type?(type, nullable:) = type == "null" && !nullable

        # The emptiness axis, as JSON Schema sees it: `minItems`/`minProperties`/`minLength` keyed off the
        # emitted type. A field rejects empty when it carries an explicit length minimum, or when the default
        # presence check applies without blank-tolerance — `presence` is `!blank?`, so it forbids the empty value
        # too. Only `allow_blank` is consulted, never `allow_nil`: nil-tolerance is the other axis and says
        # nothing about whether an empty value is admissible. Emitting this is what keeps a required
        # collection's schema from advertising `[]` as acceptable when the runtime rejects it — which is why it
        # follows the emitted type into a union's `anyOf` branches as well as a single `type:`.
        # For a String under `presence:` the runtime also rejects whitespace-only values, which
        # `minLength` cannot express, so the emitted constraint stays a floor rather than an exact mirror.
        # Every validator-derived keyword for ONE position's node, in one place. `build_property` runs it for a
        # named position (a field, a subfield, a shape member) and `contents_node_schema` for an unnamed one (an
        # Array's element, a map's axis), so a keyword cannot land at one position and be forgotten at another —
        # which is what a mirrored copy would eventually become. The keyword each one lands on is decided by the
        # node's own emitted `type:`, so the same call does the right thing wherever the node sits.
        def apply_value_constraints!(node, validations, nullable:, for_output:, property_names: false, declared_klass: nil)
          apply_inclusion_enum!(node, validations, nullable:, for_output:, property_names:, declared_klass:)
          apply_size_constraints!(node, validations, for_output:, property_names:, declared_klass:)
          apply_numeric_bounds!(node, validations, nullable:, for_output:, declared_klass:)
          apply_pattern!(node, validations, for_output:, property_names:, declared_klass:)
        end

        # `enum` is INTERSECTED with whatever the node already carries, never assigned over it: a singleton type
        # constrains itself by enum too (`TrueClass` emits `enum: [true]`, because the runtime accepts only the
        # singleton), so overwriting it advertised `false` on a `klass: TrueClass` position the runtime rejects.
        # Both are enforced, so the emitted set is the values that satisfy both.
        #
        # On a `propertyNames` node the members must additionally be renderable AS a property name — every JSON
        # object key is a string. A Symbol has a faithful form; an Integer does not, and the runtime really does
        # accept `{ 1 => v }`, so a set with any unrenderable member stands the ENUM down (leaving the axis's
        # other, string-shaped constraints in place) rather than emit a set no key can satisfy.
        def apply_inclusion_enum!(node, validations, nullable:, for_output:, property_names:, declared_klass: nil)
          inclusion = validations[:inclusion]
          return unless inclusion

          values = inclusion_enum_values(inclusion)
          return unless values

          if property_names
            values = property_name_enum(values, for_output:)
            return if values.nil?
          else
            return if for_output && !output_enum_exact?(values, validations, declared_klass)

            values = enum_for_inclusion(values, nullable:)
          end

          existing = node[:enum]
          node[:enum] = existing ? existing & values : values
        end

        # Whether a JSON key — always a String — could satisfy this axis's declared class. An axis naming none
        # constrains no class and so admits one. `:uuid` is the one pseudo-type whose values ARE Strings;
        # `:boolean` and `:params` are not, and neither is any other class unless String descends from it.
        # The keys-axis validators whose subject is the key OBJECT rather than the property name it serializes
        # to. See `own_wire_form?` for why these three and not the rest.
        #
        # `presence:` belongs here for the same reason `length:` does, and it is easy to miss because what it
        # emits is a LENGTH keyword: ActiveModel asks the key object's own `blank?`, so an object that is present
        # can still render as the empty property name — measured, a key whose `to_s` is `""` satisfies
        # `presence: true`, serializes the map as `{"" => 1}`, and the emitted `propertyNames: { minLength: 1 }`
        # rejects it. `absence:` needs no entry: it emits nothing into a `propertyNames` node at all. `format:`
        # is deliberately absent, being the one validator whose subject IS the wire string — ActiveModel matches
        # `value.to_s`, which is what `canonical_wire_key` dispatches for a key.
        OBJECT_SUBJECT_KEY_VALIDATORS = %i[length inclusion presence].freeze
        private_constant :OBJECT_SUBJECT_KEY_VALIDATORS

        # `ShapeGraph.type_tokens`, not `Kernel#Array` — `klass` is a caller-declared axis token here, and
        # `Array()` would dispatch `to_ary`/`to_a` on it (see `declared_type_tokens` above).
        def axis_admits_string_key?(klass)
          tokens = Axn::Internal::ShapeGraph.type_tokens(klass)
          return true if tokens.empty?

          tokens.any? { |token| string_reachable_key_token?(token) }
        end

        # Whether a String key could satisfy this token — String itself, or any SUPERTYPE of it. A `klass: Object`
        # axis answers yes, correctly: a JSON client really can send a key that satisfies it.
        def string_reachable_key_token?(token)
          case token
          when ::Symbol then token == :uuid
          # `String <= token` asked the same question, but reversing it to satisfy the linter would dispatch
          # `>=` on a caller-supplied Module. This reads String's OWN ancestry natively instead, which is the
          # undispatched form and the seam the error-path rules already point at.
          else Internal::Identity.kind?(token, ::Module) && Internal::NativeMethods.includes_module?(::String, token)
          end
        end

        # Whether every value this token admits IS the string it serializes to — String itself, or a SUBTYPE of
        # it, plus Symbol, whose `#to_s`, `#length` and `==` are all its name's. The opposite ancestry direction
        # from the predicate above, and deliberately not shared with it: reachability asks "could a String
        # satisfy this position", and a broad token answers yes to that while admitting values that are not
        # Strings at all. `Object` is the case that separates them.
        def own_wire_string_token?(token)
          return token == :uuid if Internal::Identity.kind?(token, ::Symbol)
          return false unless Internal::Identity.kind?(token, ::Module)

          Internal::Identity.same?(token, ::Symbol) || Internal::NativeMethods.includes_module?(token, ::String)
        end

        # Whether the axis guarantees a key that IS the property name the serializer writes. Two of the projected
        # keywords ask about the key OBJECT rather than its wire form, and both are wrong when the two come apart:
        #
        #   `length:`    ActiveModel measures the object's `#length`, `minLength`/`maxLength` measure the property
        #                name. A path whose `#length` counts segments serializes to "a/b" — runtime 2, wire 3.
        #   `inclusion:` the runtime matches by Ruby `==`, which can identify values with DIFFERENT wire forms.
        #                `1 == 1.0`, so a `{ in: [1] }` axis accepts a `1.0` key that serializes to "1.0" while
        #                the emitted set holds only "1".
        #
        # Both reduce to one question — is the key its own wire form — so one gate answers both rather than a
        # keyword-by-keyword table that has to be re-argued for each new keyword. `format:` is exempt by
        # construction, not by omission: ActiveModel matches `value.to_s` and the serializer writes the same
        # `to_s`, so its subject is the wire form already.
        # `ShapeGraph.type_tokens`, not `Kernel#Array` — `klass` is sometimes a raw axis token here too (see
        # `axis_admits_string_key?`), and `type_tokens` is idempotent on the callers that already pass an Array.
        def own_wire_form?(klass)
          tokens = Axn::Internal::ShapeGraph.type_tokens(klass)
          return false if tokens.empty?

          tokens.all? { |token| own_wire_string_token?(token) }
        end

        # A property-name set, or nil to stand down — and the two directions are different questions.
        #
        # On OUTPUT the members are rendered by `Values.canonical_wire_key`, the SAME function the map's own
        # serializer uses for a key. Reading them through the VALUE serializer instead was wrong for any type
        # whose two renderings differ: a Time value serializes as `iso8601` and a Time KEY as `to_s`, so the
        # emitted set named a key the map never produces.
        #
        # On INPUT only a String member survives. A JSON client can send nothing but string keys, and a
        # non-String axis rejects one — measured, a `keys: Symbol` axis refuses `{ "a" => 1 }` while accepting
        # `{ a: 1 }` — so advertising the rendered form there would tell a client to send a key axn will refuse.
        # That is PRO-3165's "a `keys: Symbol` would be a lie on the wire", which holds for a SET exactly as it
        # held for a bare type.
        def property_name_enum(values, for_output:)
          return values.map { |value| Values.canonical_wire_key(value) } if for_output

          # Inbound, the REACHABLE subset rather than all-or-nothing. A JSON key is a String, so it can only
          # ever equal a String member — which makes `["a", 1]` project to exactly `["a"]`: not an
          # approximation, but the precise set of JSON-supplied keys the runtime accepts. Standing down from
          # the whole constraint instead admitted every key the document said nothing about.
          reachable = values.grep(::String)
          # Nothing reachable, and the axis's CLASS already admits a String key — the whole inbound projection
          # is gated on that before this runs — so the position is reachable from JSON while its set holds
          # nothing a JSON key could equal: no key satisfies it, and `enum: []` is what says so. Standing down
          # instead advertised every key the document was silent about, and `keys: { klass: [String, Integer],
          # inclusion: { in: [1] } }` accepted `{"x" => 1}` while the runtime rejected it.
          #
          # The axis whose class excludes String is a DIFFERENT case and keeps its stand-down: there the wire
          # cannot reach the position at all, a Ruby caller satisfies it perfectly well, and PRO-3165 already
          # turns that whole projection away above rather than emitting a set no client can satisfy.
          return EMPTY_ENUM if reachable.empty?

          # Detached, never the inclusion array's own Strings: reflection hands these to a consumer, and one
          # mutating a member in place would change which keys the DECLARED action accepts. The value-enum path
          # dups through the same normalizer.
          normalize_schema_literal(reachable)
        end

        # A declared `format:` reflects as `pattern` when the regex translates faithfully — `Reflection::Pattern`
        # owns that judgment and returns nil to stand down, which is what the emitter did for every regex
        # before this. Only `with:` is read: `without:`'s honest spelling is `not: { pattern: ... }`, and `not:`
        # is a single slot `reject_null!` already writes into, so a second writer would silently clobber the
        # first. Booked as unemitted alongside `exclusion:`, which has the same shape.
        def apply_pattern!(prop, validations, for_output:, property_names: false, declared_klass: nil)
          entry = Axn::Validation::Base.validator_entries(validations)[:format]
          return unless entry
          # ActiveModel matches `value.to_s`, and on OUTPUT that is not always the string the wire carries: the
          # VALUE serializer renders a Time as `iso8601` and a Date as its own ISO form, so a pattern the runtime
          # measured against `"2026-08-25 12:00:00 UTC"` is measured against `"2026-08-25T12:00:00Z"` instead and
          # rejects output the action produced. Emitted outbound only where the value IS the string it serializes
          # to. A KEY is exempt: `canonical_wire_key` dispatches `to_s`, the same subject the validator used.
          return if for_output && !property_names && !own_wire_form?(declared_type_tokens(validations, declared_klass))

          pattern = Pattern.ecma_source(Axn::Validation::Base.validator_entry_options(entry)[:with], for_output:)
          write_pattern_to_string_nodes!(prop, pattern) if pattern
        end

        # A union leaves the node's own `type:` unset and its branches under `anyOf`, so a pattern written at the
        # node would sit on nothing — the same shape `write_numeric_bound!` follows for a bound, and the reason a
        # union `format:` reflected nowhere at all while a single-type one reflected fine, leaving the string
        # branch of `type: [String, Integer], format: …` advertising values the validator rejects.
        def write_pattern_to_string_nodes!(node, pattern)
          return write_pattern!(node, pattern) if Array(node[:type]).include?("string")
          return unless node[:anyOf].is_a?(Array)

          node[:anyOf] = node[:anyOf].map do |branch|
            next branch unless Array(branch[:type]).include?("string")

            branch.dup.tap { |composed| write_pattern!(composed, pattern) }
          end
        end

        # Both patterns are enforced, so both are emitted. A node has one `pattern` slot, and a declared `format:`
        # landing beside the one `only_integer:` installs had been overwriting it — `type: String,
        # numericality: { only_integer: true }, format: { with: /\A[0-9a-z]+\z/ }` then advertised `"abc"`, which
        # the runtime rejects on the integer test. `allOf` is JSON Schema's spelling for the conjunction, and it
        # is free at a property: the conditional `allOf` this emitter writes is at the schema ROOT.
        def write_pattern!(node, source)
          existing = node[:pattern]
          return node[:pattern] = source if existing.nil? || existing == source

          node.delete(:pattern)
          node[:allOf] = [{ pattern: existing }, { pattern: source }]
        end

        # The bound twin of the emptiness floor/ceiling: a declared `numericality:`/`comparison:` bound reflects
        # as the JSON Schema keyword that means the same thing. Read through `Base.declared_numeric_bounds`, the
        # same reader the runtime bound comes from, so the two cannot disagree about one declaration.
        #
        # Emitting only ever shrinks the schema-valid set, so it preserves the documented direction (stricter
        # than the runtime, never looser) by construction — and every case a bound cannot be carried exactly
        # stands down to emitting nothing, which is where this started.
        # An `enum` is INTERSECTED with whatever the node already carries rather than assigned over it, the same
        # rule `apply_inclusion_enum!` follows and for the same reason: both sets are enforced.
        def merge_enum!(prop, values)
          existing = prop[:enum]
          prop[:enum] = existing ? existing & values : values
        end

        def apply_numeric_bounds!(prop, validations, nullable:, for_output:, declared_klass: nil)
          return unless numeric_node?(prop)
          return if for_output && !numeric_serialization_exact?(declared_type_tokens(validations, declared_klass))

          entries = Axn::Validation::Base.validator_entries(validations)
          # Both entries are enforced, so their bounds are INTERSECTED into one set before any keyword is
          # written — assigning per entry let whichever the iteration reached last win, and emitted the weaker
          # bound of the two (`numericality: { greater_than: 10 }, comparison: { greater_than: 0 }` advertised
          # `exclusiveMinimum: 0` while the runtime rejected 5).
          bounds = {}
          NUMERIC_BOUND_ENTRIES.each do |key, ranged|
            entry = entries[key]
            next unless entry

            Axn::Validation::Base.declared_numeric_bounds(entry, ranged:).each do |operator, bound|
              next unless Axn::Validation::Base.emittable_numeric_bound?(bound)

              Axn::Validation::Base.intersect_numeric_bound(bounds, operator, bound)
            end
          end

          # An intersection with no solution resolves to a sentinel rather than a bound
          # (`Base::CONTRADICTORY_BOUND`), and the node then says NOTHING SATISFIES THIS rather than saying less.
          #
          # That is the faithful projection, and standing down here would be the papering-over PRO-3220 warns
          # against: the corollary in guards-and-projections.md forbids an unsatisfiable node for a SATISFIABLE
          # contract, this contract admits nothing, and the emitter already projects that family unsatisfiably
          # elsewhere (`length: { maximum: 0 }` on a required Array emits `minItems: 1, maxItems: 0`). Refusing
          # the declaration outright stays PRO-3220's; being honest about it is this layer's job.
          #
          # `enum: []` is the spelling: it is satisfied by no value, and it composes rather than collides —
          # intersecting it with an enum the node already carries yields `[]` either way, where `not: {}` would
          # contend for a slot `reject_null!` already writes.
          wrote_bound = false
          bounds.each do |operator, bound|
            if Axn::Validation::Base.contradictory_bound?(bound)
              # Nullable, nil is still a passing value — the validators skip it — so the node that admits
              # nothing ELSE must say that rather than admit nothing at all.
              merge_enum!(prop, nullable ? [nil] : EMPTY_ENUM)
              next
            end
            next unless Axn::Validation::Base.emittable_numeric_bound?(bound)

            # `const` names exactly one value, so it cannot say "this number OR null", and a nullable position
            # really does admit nil: `type: Integer, comparison: { equal_to: 1 }, optional: true` exposes nil
            # successfully while `const: 1` rejected it, even beside a `"null"` in the node's own `type:`. The
            # enum spelling says both, and intersects with any set the node already carries.
            if operator == :equal_to && nullable
              merge_enum!(prop, [bound, nil])
              wrote_bound = true
              next
            end

            write_numeric_bound!(prop, NUMERIC_BOUND_KEYS.fetch(operator), bound)
            wrote_bound = true
          end

          # Only where a bound was actually written: a union merely CONTAINING a numeric branch is what
          # `numeric_node?` answers, and narrowing on that would drop the string branch of a plain
          # `type: [String, Integer]` that declares no bound at all.
          restrict_union_to_bounded_branches!(prop) if wrote_bound && !for_output
        end

        # A bound can only be written onto a branch that carries a numeric type, which leaves a union's other
        # branches advertising values the validator rejects: `type: [String, Integer], numericality: { greater_than: 0 }`
        # accepted `"abc"` through the string branch while ActiveModel rejected it on every call. Input reflection
        # may be STRICTER than the runtime but never looser (`docs/reference/class.md`), and a narrowing is the
        # licensed direction — so the branches that cannot carry the bound are dropped rather than left lying.
        # ActiveModel does accept a numeric STRING here (`"5"` passes), so this says less than the runtime allows;
        # it cannot say more, since no `minimum` applies to a JSON string and a pattern cannot carry the bound.
        #
        # Output is not narrowed: there the schema describes what the action produces, and dropping a branch
        # would reject a value axn serialized. It has no bound to drop anyway — `numericality_type_provable?`
        # already stands the whole projection down outbound unless the validator proves the value is numeric.
        def restrict_union_to_bounded_branches!(prop)
          return unless prop[:anyOf].is_a?(Array)

          kept = prop[:anyOf].select do |branch|
            types = Array(branch[:type])
            # The nullability branch stays: a nil is SKIPPED by the validator rather than bounded by it, so
            # dropping it would reject a value the contract admits.
            types.intersect?(NUMERIC_TYPES) || types.include?(NULL_BRANCH[:type])
          end
          return if kept.empty? || kept.size == prop[:anyOf].size

          return prop[:anyOf] = kept unless kept.size == 1

          # One survivor is no longer a union.
          prop.delete(:anyOf)
          prop.merge!(kept.first)
        end

        # Whether any part of this node carries a numeric type — the node's own, or a branch of a union.
        def numeric_node?(prop)
          return true if Array(prop[:type]).intersect?(NUMERIC_TYPES)

          prop[:anyOf].is_a?(Array) && prop[:anyOf].any? { |branch| Array(branch[:type]).intersect?(NUMERIC_TYPES) }
        end

        # A union leaves `prop[:type]` unset and its branches under `anyOf`, so a bound written at the node
        # would sit on nothing. It follows the emitted type into the branches instead — the same shape
        # `apply_member_size_constraints` already gives the size bounds, and the reason a union `length:`
        # reflected while a union `numericality:` silently did not.
        def write_numeric_bound!(prop, key, bound)
          return prop[key] = bound unless prop[:anyOf].is_a?(Array)

          prop[:anyOf] = prop[:anyOf].map do |branch|
            Array(branch[:type]).intersect?(NUMERIC_TYPES) ? branch.merge(key => bound) : branch
          end
        end

        def apply_size_constraints!(prop, validations, for_output: false, property_names: false, declared_klass: nil)
          minimum = declared_size_minimum(validations)
          maximum = declared_size_maximum(validations)
          return if minimum.nil? && maximum.nil?

          strings = emit_string_size?(validations, for_output:, property_names:, declared_klass:)

          if prop[:anyOf]
            prop[:anyOf] = apply_member_size_constraints(prop[:anyOf], minimum, maximum, strings:)
          else
            prop.merge!(size_bounds_for(prop[:type], minimum, maximum, strings:))
          end
        end

        # Whether a STRING size may be emitted at this position — the same question `apply_pattern!` asks, and
        # for the same reason. ActiveModel measures the value's own `#length`, and on OUTPUT that is not always
        # the string the wire carries: `Time.utc(2026, 8, 25, 12).to_s` is 23 characters and it serializes as the
        # 20-character `"2026-08-25T12:00:00Z"`, so `length: { is: 23 }` accepts the value at runtime while the
        # emitted `minLength: 23` rejects the action's own output.
        #
        # A COLLECTION size is exempt by construction: `minItems`/`maxItems`/`minProperties`/`maxProperties`
        # count the elements the serializer writes, so the runtime's measurement and the document's agree however
        # the elements themselves render. A `propertyNames` node is exempt too, exactly as it is for a pattern —
        # a KEY's wire form is the `to_s` the validator measured, and an axis whose key is not its own wire form
        # has already had `length:` removed by `key_axis_constraints`. Input needs no gate: the subject there is
        # the value that was sent.
        def emit_string_size?(validations, for_output:, property_names:, declared_klass:)
          return true unless for_output
          return true if property_names

          own_wire_form?(declared_type_tokens(validations, declared_klass))
        end

        # The size keywords whose subject is a STRING, and so the ones the wire-form gate above governs.
        STRING_SIZE_KEYS = %i[minLength maxLength].freeze
        private_constant :STRING_SIZE_KEYS

        # A union emits one branch per member type instead of a single `type:`, and the validators reject an
        # out-of-bounds value whichever branch it takes — so each bound belongs on every branch that can carry
        # it. A branch with no size (an `integer` member) and the nullability branch carry none, decided by the
        # same per-type key lookup the single-type path uses.
        def apply_member_size_constraints(members, minimum, maximum, strings: true)
          members.map do |member|
            bounds = size_bounds_for(member[:type], minimum, maximum, strings:)
            bounds.empty? ? member : member.merge(bounds)
          end
        end

        # The size keywords one emitted type can carry, for the bounds this field declares. Empty for a type
        # with no size, which is what keeps a bound off an `integer` branch and off `"null"`.
        def size_bounds_for(type, minimum, maximum, strings: true)
          bounds = {}
          if minimum && (floor_key = size_constraint_key_for(type)) && emittable_size_key?(floor_key, strings)
            bounds[floor_key] = minimum
          end
          if maximum && (ceiling_key = size_ceiling_key_for(type)) && emittable_size_key?(ceiling_key, strings)
            bounds[ceiling_key] = maximum
          end
          bounds
        end

        def emittable_size_key?(key, strings) = strings || !STRING_SIZE_KEYS.include?(key)

        # The JSON Schema floor key for an emitted type, or nil for a type with no empty state. Reads the
        # single-type String and the `[T, "null"]` nullable pair alike; `"null"` is never size-bearing.
        def size_constraint_key_for(type)
          Array(type).filter_map { |t| SIZE_CONSTRAINT_KEYS[t] }.first
        end

        # The JSON Schema ceiling key for an emitted type, or nil for a type with no size. Reads the single-type
        # String and the `[T, "null"]` nullable pair alike, exactly as the floor's own key lookup does.
        def size_ceiling_key_for(type)
          Array(type).filter_map { |t| SIZE_CEILING_KEYS[t] }.first
        end

        # The smallest size this field's validators admit, or nil when they admit an empty value. An explicit
        # `length:` floor wins over the implicit 1 that the emptiness check and the presence check each carry —
        # a caller needs the tightest of them, and all three forbid empty. The floor is read by
        # Validation::Base's shared definition, the same one the
        # emptiness reconciliation judges a declaration by, so what the runtime enforces and what the schema
        # advertises cannot drift; a per-call (Symbol/Proc) or infinite floor is unemittable and falls through
        # to the presence check.
        #
        # A blank-tolerant `length:` contributes its floor only when an empty value would be rejected ANYWAY.
        # Blank-tolerance on one entry says an empty value stands THAT entry aside, not that an empty value gets
        # through: with nothing else rejecting it the contract admits "empty or at least 3", which no floor
        # expresses, so emitting 3 would reject a value the contract accepts — but where a presence or emptiness
        # check rejects every empty value, 3 or more is all the contract admits and the floor is exact. Truthiness
        # decides the tolerance, not key presence: a nil-tolerance injects an explicit `allow_blank: false`.
        #
        # A GATED entry may be open on a given call, and is counted as if it were — static-maximal, which can
        # leave the input schema stricter than a closed-gate runtime but never looser, and is the policy for
        # every gated constraint here.
        #
        # Only `length:` is consulted, never a `size:`: `size` is absent from KNOWN_VALIDATION_KEYS, so a
        # declaration carrying it raises "Unknown key(s) :size" and can never reach reflection.
        def declared_size_minimum(validations)
          # Whether an empty value can get through at all decides BOTH branches below: it is the floor of 1 a
          # presence/emptiness check imposes on its own, and it is what tells a blank-tolerant `length:` apart
          # from one whose blank-tolerance is moot.
          rejects_empty = empty_value_rejected?(validations)

          length = effective_entry_options(validations[:length], shared_validation_options(validations))
          if rejects_empty || !length[:allow_blank]
            declared = Axn::Validation::Base.declared_length_floor(length)
            return declared if Axn::Validation::Base.emittable_length_floor?(declared)
          end

          rejects_empty ? 1 : nil
        end

        # The largest size this field's validators admit, or nil when they bound it nowhere. Two spellings name
        # one, and `absence:` is the tighter of them whenever it names one at all, so it answers first: it
        # rejects every non-blank value, so where a type's blank values are exactly its EMPTY ones it leaves
        # size 0 as the only admissible size — the exact statement `length: { maximum: 0 }` makes. Without it a
        # field carrying `absence:` beside a dropped floor emitted no ceiling at all, a node LOOSER than the
        # contract it projects.
        #
        # Blank-tolerance cannot loosen either one (an empty value measures 0, which every emittable ceiling
        # admits), and a GATED entry is counted as if its gate were open — the static-maximal policy every
        # constraint here follows.
        def declared_size_maximum(validations)
          return 0 if absence_bounds_size?(validations)

          length = effective_entry_options(validations[:length], shared_validation_options(validations))
          declared = Axn::Validation::Base.declared_length_ceiling(length)

          declared if Axn::Validation::Base.emittable_length_ceiling?(declared)
        end

        # JSON Schema's `propertyNames` applies to EVERY key of the object, `properties`-matched ones included.
        # The runtime does the opposite for a shaped map: a key the `shape:` names is EXEMPT from both axes
        # (Core::Contract#_derive_shaped_keys!), which is what `additionalProperties` already means and what
        # makes combining the two options coherent. So a bare keys-axis constraint beside a shape would publish
        # a document the runtime contradicts — and contradict it in the direction that matters, since a member
        # is `required` and a `propertyNames` it fails forbids that key, leaving a node NO value satisfies. That
        # is exactly the corollary PRO-3192 recorded in guards-and-projections.md.
        #
        # The union is the runtime rule verbatim — a key is one the shape names, or one the axis admits — so the
        # node stays satisfiable AND stays exact, rather than being loosened to nothing or dropped.
        # Reads the exempt set off the node's OWN emitted `properties` rather than taking a member list: the
        # runtime derives its exempt set from the emitter's key computation in the first place (PRO-3166), so
        # this is the same answer asked of the same source, and one helper then serves every site where the two
        # options meet — a field's own map node, and a NESTED bag composing a `shape:` with a map `of:`, which
        # is also where the distributing block form lands (PRO-3191 folds it into that bag).
        def exempt_shaped_keys_from_property_names(node)
          axis = node[:propertyNames]
          shaped = node[:properties]
          return node if axis.nil? || axis.empty? || shaped.nil? || shaped.empty?

          node.merge(propertyNames: { anyOf: [axis, { enum: shaped.keys.map(&:to_s) }] })
        end
        # The classes whose BLANK values are exactly their EMPTY ones, so "rejects every non-blank value" and
        # "admits size 0 only" say the same thing about them. `String` is deliberately absent and is the whole
        # reason this is a list rather than `EMPTY_CONTAINER_CLASSES`: ActiveSupport gives it a `blank?` of its
        # own (`BLANK_RE`), under which `"  "` is blank while `empty?` and `length` both say otherwise — so an
        # `absence:` on a String bounds WHITESPACE, which no size key expresses, rather than size.
        #
        # `ActionController::Parameters` is not here either: it is identified by rendered name rather than by
        # constant, and a list this one is read off must be comparable by identity.
        BLANK_IS_EMPTY_CLASSES = [::Hash, ::Array].freeze

        # Whether a live `absence:` bounds this declaration's SIZE — the question `declared_size_maximum` asks,
        # and the one a guard may lean on, as opposed to the looser "is an `absence:` present".
        #
        # Three conditions, each load-bearing:
        #
        #   * the entry is LIVE — a falsy one is the disabled validator ActiveModel skips, so it forbids
        #     nothing;
        #   * every declared type is one whose blank values are its empty ones, since only there does the blank
        #     axis land on the size axis at all;
        #   * the entry is UNGATED — by a gate of its own OR by one the whole declaration carries, since either
        #     stops it running. This is the one bound here not counted static-maximally, and the asymmetry is
        #     between an AUTHORED bound and an INFERRED one. A `length:` ceiling is a size constraint the author
        #     wrote, so it is emitted as written whatever gates it. A size meaning for `absence:` is one axn
        #     infers, and it may only infer it from a check that always runs: `presence: { unless: :archived },
        #     absence: { if: :archived }` is a working contract, and deriving a `maxItems: 0` from its
        #     conditional half would put a ceiling on the document that the contract does not carry on the
        #     calls where the gate is closed — most of them.
        def absence_bounds_size?(validations)
          return false unless absence_bounds_blankness?(validations)

          blank_values_are_empty?(validations)
        end

        # The first two of those conditions on their own: a LIVE, UNGATED `absence:`, which rejects every value
        # that is not blank whatever the declared type. Split out because the blank axis is a real constraint
        # even where it lands nowhere on the size axis — for a `String`, `absence:` rejects `"ab"` while no size
        # key expresses it — so the member scan asks this to know whether a non-blank member can be a witness at
        # all (`_member_survives_the_blank_axis?`), where the ceiling derivation above needs the size question.
        # One definition, so the two cannot disagree about which `absence:` entries count.
        def absence_bounds_blankness?(validations)
          entry = Axn::Validation::Base.validator_entries(validations)[:absence]
          return false unless entry

          !Axn::Validation::Base.entry_effectively_gated?(entry, Axn::Validation::Base.shared_validation_options(validations))
        end

        # Whether every value this declaration calls BLANK measures 0 — the question that decides whether the
        # blank axis can be read as a statement about size at all. Shared with the guard that asks whether a
        # blank value could slip past a blank-tolerant entry, so the two cannot disagree about one declaration.
        #
        # Only the SIZE-BEARING tokens are asked. A union emits one branch per token and `size_bounds_for` puts
        # no bound on a branch that carries no size keyword, so a `NilClass` (or an `Integer`, or `:boolean`)
        # can neither make an `absence:` ceiling wrong nor be constrained by one — and must not veto it either.
        # Judging every token alike is what left `type: [Array, NilClass], presence: false, absence: true`
        # without a ceiling on its ARRAY branch, so a non-empty array was schema-valid and runtime-invalid: the
        # looser direction, which the emitter may never take.
        #
        # A `String` among them still answers false, and that is the point of asking per token rather than
        # per branch: a String branch IS size-bearing, and `absence:` bounds whitespace there rather than size,
        # so no ceiling can be emitted for the union at all while one member reads that way.
        def blank_values_are_empty?(validations)
          sized = declared_type_tokens(validations).select { |token| token_carries_a_size?(token) }

          sized.any? && sized.all? { |token| blank_is_empty_class?(token) }
        end

        # Whether the branch a token emits can carry a size keyword at all, asked through the emitter's own
        # type mapping and its own key lookup rather than an enumeration beside them — so a token whose emitted
        # type changes cannot leave this answering the old one.
        #
        # A token the map does not know falls through to the permissive `"string"`, which IS size-bearing, so
        # it vetoes. That is the right answer for an unknown token and the wrong one for `NilClass`, whose only
        # value is `nil` — blank, and with no size to bound. `NilClass` is absent from `TYPE_MAP`, so a union
        # naming it emits a spurious string branch (measured: `type: [Array, NilClass], presence: false` emits
        # `anyOf: [array, string, null]` while the runtime rejects `"x"`), and this inherits that. Not corrected
        # here: the mapping is a pre-existing looseness with a blast radius of its own — the nullability pass
        # already contributes a `"null"` branch — and it is tracked in PRO-3233.
        def token_carries_a_size?(token)
          !size_ceiling_key_for(single_type_for(token, for_output: false)[:type]).nil?
        end

        def blank_is_empty_class?(token)
          BLANK_IS_EMPTY_CLASSES.any? { |klass| klass.equal?(token) } || (defined?(Set) && ::Set.equal?(token))
        end

        # The non-size tokens whose values an `absence:` check rejects OUTRIGHT: no `true`, no Integer and no
        # Float is blank, so a declaration bounding the blank axis to size 0 admits nothing of theirs at all —
        # which is what makes a refusal drawn from that ceiling sound even with one of them in the union.
        #
        # `:boolean` and `FalseClass` are the ones deliberately absent, and they are the whole reason this list
        # exists: `false` IS blank, so the `absence:` accepts it, and `LengthValidator` measures its rendering
        # (`"false"`, five characters) rather than a length it has none of. A union naming either has a branch
        # the ceiling does not bound, and the guard cannot conclude anything from it.
        ABSENCE_REJECTS_EVERY_VALUE = [::TrueClass, ::Integer, ::Float, ::Numeric].freeze

        # Whether an `absence:`-derived ceiling of 0 bounds EVERY branch this declaration names — the size
        # guard's question, and deliberately not `blank_values_are_empty?`, which filters the union down to its
        # size-bearing tokens.
        #
        # Both questions are right for their caller. The emitter needs to know what bound the ARRAY branch
        # carries, and `maxItems: 0` is the answer there whatever a sibling admits — dropping it would leave a
        # non-empty array schema-valid and runtime-invalid. This guard needs to know whether the DECLARATION
        # admits anything, and a single unbounded branch means it cannot say.
        #
        # Three cases per token, and the middle one is why this reads as a list rather than a measurement: a
        # token whose blank values are its empty ones is bounded (`blank_is_empty_class?`); a token no blank
        # value of which exists is bounded vacuously, since the `absence:` rejects everything it admits; and
        # anything else — `:boolean`, a `String`, an unrecognized class — is not bounded, so the ceiling proves
        # nothing about it. Unknown answers "not bounded", which stands the guard down: over-refusing a working
        # declaration is the one failure it cannot recover from.
        def absence_ceiling_bounds_every_token?(validations)
          declared_type_tokens(validations).all? do |token|
            next true if blank_is_empty_class?(token)
            next false if token_carries_a_size?(token)

            ABSENCE_REJECTS_EVERY_VALUE.any? { |known| Axn::Internal::Identity.same?(known, token) }
          end
        end

        # Emit what a container holds: the `of:` baseline — an Array's `items:`, a Hash map's
        # `additionalProperties:` — and a `shape:`'s typed member contracts as `properties:`.
        # Precedence: shape: enriches/overrides the of: baseline. On an ARRAY the two describe one node from two
        # angles, so the shape's members overwrite the element type's. On a MAP they describe different keys of
        # one object — `properties` beside `additionalProperties` — and neither displaces the other.
        def apply_structured_schema!(prop, config, for_output:, ancestry: nil)
          return unless config.validations[:of] || config.validations[:shape]

          plan = shape_property_plan(config, for_output:, ancestry:)
          # The shape the PLAN carries, never a second read of the config: one answer to which members are
          # emitted here, so a rule charged against the plan and this emission cannot walk different lists.
          shape = plan.shape

          if plan.map?
            # A map's contents land under `additionalProperties` at this very node, so the plan's type schema is
            # merged in whole. Empty for a keys-only map, which merges nothing — `keys:` has no JSON Schema
            # spelling worth emitting (see shape_property_plan).
            prop.merge!(plan.type_schema)
            return unless shape && plan.emitted

            # A shape beside a map names the SAME node's `properties`, which is the one place the two options
            # describe different things: `additionalProperties` governs only the keys `properties` does not
            # match, and the runtime mirrors that by exempting them (Core::Contract#_derive_shaped_keys!).
            # `prop[:type]` is left as `build_property` derived it from `type: Hash` — already `object`, and
            # already carrying the `null` branch where the field admits one.
            member_props, required = member_properties(shape[:members], for_output:, ancestry:)
            prop[:properties] = plan.base_properties.merge(member_props)
            prop[:required] = required unless required.empty?
            prop.replace(exempt_shaped_keys_from_property_names(prop))
          elsif plan.in_items?
            # The plan's own type schema, not a second `contents_schema_for` call: one build, and the plan is
            # then literally what gets emitted rather than a parallel derivation of it.
            items = plan.type_schema
            if shape && plan.emitted
              member_props, required = member_properties(shape[:members], for_output:, ancestry:)
              items = items.merge(type: "object", properties: plan.base_properties.merge(member_props))
              items[:required] = required unless required.empty?
            end
            prop[:items] = items unless items.empty?
          elsif shape
            return unless plan.emitted

            prop[:type] = nil_allowed?(config) ? %w[object null] : "object"
            prop.delete(:format)
            member_props, required = member_properties(shape[:members], for_output:, ancestry:)
            prop[:properties] = plan.base_properties.merge(member_props)
            prop[:required] = required unless required.empty?
          end
        end

        # Whether a config's `shape:` members become object PROPERTIES, at which node, and which property names
        # its declared TYPE contributes alongside them.
        #
        # Single source for the two layers that must agree exactly: `apply_structured_schema!` above, which
        # emits, and `Core::Contract`'s property-claim collector, which rejects a declaration whose emitted
        # property names would collapse onto one. The guard has to claim precisely what is emitted — a claim for
        # a property the schema omits rejects a declaration the author is entitled to write, and a missing claim
        # lets two names collapse silently. A guard that MIRRORED these rules did both at once, so they live
        # here, where the emission decision already lived, and are read rather than restated.
        #
        # `in_items?` distinguishes the two nodes a shape's members can land at: an ARRAY's element properties
        # are their own namespace (a non-object parent's subfields are not emitted there, so nothing else can
        # name a property alongside them), while everything else lands in the field's own `properties`.
        #
        # `emitted` false means the shape contributes no properties at all, for one of four reasons:
        #   - the config is wholly gated on output, so `build_property` leaves it untyped before reaching here;
        #   - the config is a `model:` route on INPUT, where the client sends `<field>_id` and the record's own
        #     structure is never emitted — `build_input` (and the nested analog) emit the id property INSTEAD of
        #     calling `build_property` at all, at top level and at any subfield depth alike;
        #   - a SCALAR `of:` (`of: String` + `field :length`) reads members off the element, which stays a
        #     string — so the members are validated but never become properties;
        #   - on OUTPUT, the value is not provably member-keyed (a custom `as_json`/`to_h` that
        #     `serialize_value` would follow instead), so the property is left untyped rather than promising an
        #     object shape the serializer will not produce.
        #
        # `type_schema` is what the declared TYPE contributes, as the emitter's own Hash: for an array, exactly
        # what `contents_schema_for` seeded from the `of:` element type; for a map, that same seed for the
        # `values:` axis, wrapped in the `additionalProperties` key it lands under; for anything else, a `Data`
        # field's own members. Carried whole rather than reduced to one property list, because the emitter does
        # not put all of it at one node — a multi-class `of:` becomes one `anyOf` BRANCH per element type, each
        # with its own `properties`. `base_properties` is the part that lands at the node itself, which is all the
        # emitter merges the shape's members into; a consumer that must account for EVERY name (the projection
        # size cap) walks the whole schema instead. Reducing this to `base_properties` alone is what let a
        # contract naming 26,000 properties across 26 branches charge zero.
        #
        # `container` is the container an `of:` bag names — `::Array`, `::Hash`, or nil where there is no `of:`
        # at all. It is what tells the two `of:` grammars apart AFTER canonicalization, since a map's bag names
        # its axes (`keys:`/`values:`) where an array's names one element type (`klass:`), and the two land at
        # different nodes. `in_items` is the neighbouring question and not the same one: it asks where a SHAPE's
        # members go, and is answered from the emitted JSON type, so an array with no `of:` still answers true.
        #
        # `shape` is the shape the plan was DERIVED from — the effective one (see effective_validations), which on
        # output is not always the declared one. Carried so that "which members does this emit" has a single
        # answer: `apply_structured_schema!` emits these members, and a rule charged against the plan walks the
        # same list rather than re-reading the config it came from. A plan whose `emitted` is false still carries
        # it (nothing about that decision changes which shape was consulted), so every consumer gates on `emitted`.
        ShapePropertyPlan = Data.define(:emitted, :in_items, :type_schema, :shape, :container) do
          def in_items? = in_items

          # A map puts its `of:` contents under `additionalProperties` at the field's own node. Asked of the
          # container the declaration named rather than of the schema that was built, so a values axis with
          # nothing to say is still recognizably a map.
          def map? = ::Hash.equal?(container)

          def base_properties = type_schema[:properties] || {}
        end

        def shape_property_plan(config, for_output:, ancestry: nil)
          # THE reason the charge and the emitter cannot start from different configs: the effective derivation
          # happens HERE, on the way in, so no caller can hand this a config the emitter would not have used.
          # `build_property` applies the same derivation before it emits, which makes the one here idempotent
          # (nothing left to drop) rather than a second opinion.
          validations = effective_validations(config.validations, for_output:)
          of = validations[:of]
          shape = validations[:shape]
          in_items = Array(json_type_for(validations, for_output:)[:type]).include?("array")
          container = of_container(validations)
          nothing = ShapePropertyPlan.new(emitted: false, in_items:, type_schema: {}, shape:, container:)

          # The same two gates `apply_structured_schema!` opens with, in the same order. A declaration with
          # neither `of:` nor `shape:` contributes no object properties AT ALL — not even its type's own members —
          # so a `Data` used purely as a `type:` names nothing, and a rule keyed on these names must not fire on
          # it. Likewise a wholly gated outbound config, which `build_property` leaves untyped before reaching
          # emission.
          return nothing unless of || shape
          return nothing if for_output && gated_validations?(validations)
          # An INPUT model route emits `<field>_id` in place of the field, so `apply_structured_schema!` is never
          # reached for one — stated here rather than only in the emitter's branch, so a consumer deriving from this
          # plan (the projection size cap; collision attribution) cannot charge or attribute a property the schema
          # names nowhere. On OUTPUT the field itself is emitted, so its shape is emitted with it.
          return nothing if !for_output && validations[:model]

          if in_items
            # Overlay the shape's object properties onto items only when the ELEMENTS are objects.
            emitted = shape_overlay_applies?(of, for_output:)
            # `contents_node_schema` seeds an element type's own members whenever there is an `of:`, shape or not —
            # and, where the element is itself a container, everything inside it too.
            return ShapePropertyPlan.new(emitted:, in_items:, shape:, container:,
                                         type_schema: of ? contents_node_schema(of, for_output:, ancestry:) : {})
          end

          # A map's `of:` names its VALUES, which every JSON object key maps to — so the axis reflects as
          # `additionalProperties` at the field's own node. The `keys:` axis contributes nothing: every JSON
          # object key is a string, so `keys: String` would say nothing a client can act on and `keys: Symbol`
          # would be a lie on the wire. The values schema is the declared TYPE's contribution, charged and
          # emitted regardless of any shape, exactly as an array's items are.
          #
          # `emitted` answers only whether a SHAPE's members become properties here, and beside a map they do:
          # the two options name different keys of one object, so both land at this node. Settled on the same
          # rule the non-array branch settles it on — a client is always expected to send the members, and on
          # OUTPUT they are promised only where the value provably serializes member-keyed.
          if ::Hash.equal?(container)
            return ShapePropertyPlan.new(emitted: !for_output || shape_serializes_to_object?(validations),
                                         in_items:, shape:, container:,
                                         type_schema: map_values_schema(of, for_output:, ancestry:))
          end

          # Only the `elsif shape` branch emits object properties for a non-array, non-map field: `of:` without a
          # shape on such a type reaches neither branch.
          return nothing unless shape

          # A shaped object field IS an object, even when its declared type: (e.g. a Data.define subclass) isn't
          # in TYPE_MAP — on input unconditionally, on output only when the value serializes member-keyed.
          emitted = !for_output || shape_serializes_to_object?(validations)
          type_klass = validations.dig(:type, :klass)
          base = emitted && strict_descendant?(type_klass, ::Data) ? type_klass.members.to_h { |m| [m, {}] } : {}
          # A non-array type contributes at ONE node (a multi-class `type:` reflects as `anyOf` branches of
          # scalar types, which name no properties), so its schema is just those properties.
          ShapePropertyPlan.new(emitted:, in_items:, shape:, container:, type_schema: { properties: base })
        end

        # THE ONE derivation of the validations a projection is BUILT from, and the reason it is a function rather
        # than a step inside `build_property`: a per-validator (nested) gate can skip an INDIVIDUAL check on a
        # given call (`type: { klass: Integer, if: :flag }` with `flag` falsey lets a nonblank wrong-typed value
        # through), so its constraint can't be promised outbound — and every rule DERIVED from what the projection
        # emits has to start from the same reduced view, or it describes a schema the emitter never emits. The
        # projection size cap charged 25,000 properties for a gated `type: SomeData` whose members `build_property`
        # drops before it emits anything, because "exact given the plan" says nothing when the plan's input differs.
        #
        # What survives with EVERY gate closed: entries carrying a gate of their own (entry_self_gated?) drop, ungated
        # entries stay (a gated `inclusion:` alongside an ungated `type:` still emits the type), and
        # declaration-level gate keys stay too (inert to this reduction — a wholly gated outbound config is
        # already left untyped by its own earlier return, in both `build_property` and `shape_property_plan`).
        # INPUT is untouched and returns the SAME Hash: static-maximal is the safe direction there (a gate can
        # only relax enforcement at runtime), and identity is what lets `build_property` skip rebuilding a config.
        def effective_validations(validations, for_output:)
          return validations unless for_output

          effective = validations.reject { |_key, opt| entry_self_gated?(opt) }
          effective.size == validations.size ? validations : effective
        end

        # Whether a shape block should overlay object properties onto an array's items. OUTPUT: each element
        # must provably serialize to a member-keyed object (a plain Data/Struct/Hash `of:`). INPUT: the
        # elements must be object-typed (Hash/`:params`/Data/Struct) or untyped (no `of:` — the client sends
        # objects). A scalar `of:` (String/Integer/…) reads members off the scalar, so it is NOT overlaid.
        # A bag that NAMES no class is the same case as no bag at all — untyped elements, which on input a client
        # sends as objects carrying the shape's members (`of: { shape: … }`, PRO-3166). On OUTPUT it stays
        # unproven, and so unemitted, for the reason any unnamed class does.
        #
        # `of_validations[:klass]` is the raw `of:` bag's own klass, so both this and its OUTPUT twin below read
        # it through `ShapeGraph.type_tokens` rather than `Kernel#Array`.
        def shape_overlay_applies?(of_validations, for_output:)
          return shaped_items_serialize_to_object?(of_validations) if for_output
          return true unless of_validations # untyped elements: client sends objects with the shape members

          klasses = Axn::Internal::ShapeGraph.type_tokens(of_validations[:klass])
          klasses.empty? || klasses.all? { |k| object_typed_element?(k) }
        end

        # Whether an `of:` element type provably serializes to a member-keyed object (output items). Needs `of:`.
        def shaped_items_serialize_to_object?(of_validations)
          return false unless of_validations

          klasses = Axn::Internal::ShapeGraph.type_tokens(of_validations[:klass])
          klasses.any? && klasses.all? { |k| member_keyed_object_type?(k) }
        end

        # The container an `of:` bag names — `::Array` for an element list, `::Hash` for a map, nil where there
        # is no `of:` at all. THE one read of it, so the emitter deciding which node an `of:` lands at and the
        # declaration guard deciding whether a map may carry subfields cannot disagree about what a map is.
        #
        # Read through the same tolerant Hash test the declaration guards use: `of:` is canonicalized into a bag
        # long before either caller, but a config ASSIGNED onto a class can still carry the bare spelling the
        # DSL would have expanded, and asking a String for `[:container]` raises where an honest answer of "no
        # container named" is what both callers want. A `::Hash` answer therefore also PROVES the bag is a Hash,
        # which is what lets the map branches read `[:values]` off it without asking again.
        def of_container(validations)
          bag = Axn::Internal::ShapeGraph.hash_or_nil(validations[:of])
          bag && bag[:container]
        end

        # Whether an element type is an OBJECT on the wire a client sends (input): Hash/`:params`/Data/Struct.
        def object_typed_element?(klass)
          return true if Axn::Internal::Identity.same?(klass, :params)
          return false unless class_token?(klass)

          Axn::Internal::NativeMethods.includes_module?(klass, ::Hash) ||
            strict_descendant?(klass, ::Data) || strict_descendant?(klass, ::Struct)
        end

        # The schema for what is INSIDE a container, from the classes an `of:` axis names — an Array's elements
        # (`klass:`) and a Hash's values (`values:`) alike. One builder for both, because the two describe the
        # same thing at different nodes: a union reflects as `anyOf` branches either way, and each branch
        # carries its own type's members. An axis naming NO class cannot reach here at all: a bag has to
        # constrain something, and `_of_axis_constrains?` asks that of `klass:` with the same emptiness test
        # `OfValidator#matches_axis?` uses, so `of: []` and `of: { values: { klass: [] } }` are refused at
        # declaration rather than arriving as a position that matches everything and emits `anyOf: []`.
        def contents_schema_for(klasses, for_output: false)
          # `ShapeGraph.type_tokens`, not `Kernel#Array`: a caller may hand this the raw `of:`/`values:` klass
          # directly (`contents_node_schema` below), not only an already-tokenized list.
          klasses = Axn::Internal::ShapeGraph.type_tokens(klasses)
          if klasses.size == 1
            single_contents_schema(klasses.first, for_output:)
          else
            { anyOf: klasses.map { |k| single_contents_schema(k, for_output:) } }
          end
        end

        # The schema for ONE unnamed position — an array element, a map value. The node an `of:` bag describes,
        # built from the same ingredients a FIELD's node is: the class the bag names (`contents_schema_for`), the
        # members named off it (the bag's own `shape:`), and what that class holds in turn (the bag's own `of:`).
        # A container sitting directly inside a container has no member name to hang the next level on, so this
        # is the only way down to it.
        #
        # Shared with `apply_structured_schema!` through `shape_property_plan`'s `type_schema`, which is the whole
        # reason the collision rules and the projection size cap follow a recursive `of:` down: both read what the
        # emitter emits (`each_emitted_node` walks `items`/`additionalProperties`/`anyOf` generically), so neither
        # needs a rung-by-rung rule of its own and neither can drift from what is emitted.
        #
        # Bounded on the same terms, with the same sentences, as the runtime walk of this very edge
        # (`OfValidator#guard_contents_descent`): the declaration walk refuses a cyclic or over-deep `of:` graph, so
        # a DECLARED contract can be neither — but a field config assigned onto a class (`internal_field_configs=`)
        # passed no declaration walk and carries whatever its author built, and descending one without a bound ends
        # in `SystemStackError`, outside `StandardError`, escaping every rescue meant to settle it.
        #
        # The bound is spent on ONE counter across BOTH edges of the graph — the `of:` rung below a bag, and the
        # shape-MEMBER rung `contents_member_schema` takes through `member_properties` — threaded as the
        # `CycleGuard::Ancestry` every other walk of a held graph threads. A per-chain counter is not a bound at
        # all here, because the two edges alternate: a member's own `of:` re-enters this builder through
        # `build_property` → `shape_property_plan`, which starts a chain of its own, so a graph looping
        # `of:` → shape member → `of:` spends no rung on any single counter and reaches the stack rather than the
        # cap. (Measured: a bag whose `shape:` member points its `of:` back at that bag raised `SystemStackError`
        # out of `input_schema`.) Sharing one counter across both edges is what the declaration walk, the runtime
        # pair and the ambient walk each do over this same graph, and the reason is the same in all four: a graph
        # 64 `of:` deep by 64 `shape:` deep is 128 levels of live recursion, which two counters would admit.
        #
        # The comparison is `>`, so a graph whose deepest rung sits exactly AT the cap still emits — and the
        # charge stays one rung LOOSER than the declaration walk's (which spends a rung entering a field's own
        # first bag, where this one does not). Looser is the only safe direction: reflection refusing what
        # `expects` accepted would leave a legal contract with no schema at all.
        #
        # A union `klass:` keeps the merge order `apply_structured_schema!` has always used — the structural keys
        # land beside the `anyOf` at this node rather than inside each branch. Existing behavior, preserved
        # deliberately rather than corrected here.
        def contents_node_schema(bag, for_output:, ancestry: nil)
          constraints = bag_value_constraints(bag, for_output:)
          # A declared `klass:` decides the type, exactly as `type:` does at a field. With none, the type is
          # INFERRED from the bag's own validators — through `json_type_for`, the function the field path
          # already uses for that, rather than a second inference beside it. Without this a validator-only bag
          # seeded an empty node, every keyword that keys off a type declined to emit, and the parent dropped
          # `items` altogether: `of: { numericality: { greater_than: 0 } }` rejected `-1` at runtime and
          # advertised nothing. (`format:`/`length:` alone still infer nothing, here and at a field alike —
          # neither a pattern nor a size names one JSON type.)
          node = if bag[:klass]
                   # `contents_schema_for` reads the class alone, so the `numericality:` narrowing that
                   # `json_type_for` applies on the other branch has to be applied here too — same helper, not a
                   # second reading of it.
                   narrow_node_under_numericality(contents_schema_for(bag[:klass], for_output:), constraints,
                                                  Axn::Internal::ShapeGraph.type_tokens(bag[:klass]), for_output:)
                 else
                   json_type_for(constraints, for_output:)
                 end
          # Whether the POSITION admits nil is the same question `nil_allowed?` answers for a field, asked of
          # the bag — a `klass:` naming NilClass admits it until another validator on the same bag rejects it.
          # Hard-coding it left `of: { klass: [String, NilClass], presence: true }` advertising a `null` branch
          # the runtime rejects, and stripped nil from an enum at a position that accepts it.
          nullable = bag_nullable?(bag, for_output:)
          node = reconcile_contents_nullability(node, nullable:, for_output:)
          # The bag's value validators (PRO-3193), through the same projector a named position uses. Applied
          # before the member/contents merges below so a `type:` those steps install cannot be read as the type
          # a keyword should key off — the node's type here is the bag's own `klass:`, which is what the
          # validators constrain.
          apply_value_constraints!(node, constraints, nullable:, for_output:, declared_klass: bag[:klass])
          node = contents_member_schema(node, bag, for_output:, ancestry:)
          inner = emitted_contents_edge(bag, :of, for_output:)
          return node if nil.equal?(inner)

          guard_contents_descent(inner, ancestry, edge: INNER_CONTRACT_EDGE) do |child|
            # Which grammar the inner bag was canonicalized under, asked through the one predicate every seam asks
            # it with: a map's bag names its axes and lands under `additionalProperties`, an array's names one
            # element type and lands under `items`.
            if Axn::Internal::ShapeGraph.map_bag?(inner)
              # The object type is the bag's OWN `klass:` (a map bag is only ever reached from `klass: Hash`), exactly
              # as a field's map node takes its type from `type:` and its `additionalProperties` from the axis.
              # The exemption runs here too, and has to: this is where a bag's `shape:` properties (merged above by
              # `contents_member_schema`) meet the axis's `propertyNames`, so without it a shaped nested map with a
              # constrained `keys:` axis emits a node its own required members cannot satisfy.
              exempt_shaped_keys_from_property_names(node.merge(map_values_schema(inner, for_output:, ancestry: child)))
            else
              contents = contents_node_schema(inner, for_output:, ancestry: child)
              contents.empty? ? node : node.merge(items: contents)
            end
          end
        end

        # Which edge a descent is taking, which decides only the SENTENCE a refusal carries: the fix for a cyclic
        # `of:` is to give the nested bag contents of its own, and for a cyclic `shape:` to give the nested shape
        # its own members, so a message naming the construct the author did not write prescribes a change their
        # declaration has nowhere to make. Same split, same reason, as the declaration walk's `SHAPE_EDGE` /
        # `INNER_CONTRACT_EDGE`.
        INNER_CONTRACT_EDGE = :of
        SHAPE_EDGE = :shape
        private_constant :INNER_CONTRACT_EDGE, :SHAPE_EDGE

        # A private object of this module's own, and always the RECEIVER of `equal?`, so nothing a declaration can
        # produce is mistaken for it.
        CYCLIC_CONTRACT = ::Object.new.freeze
        private_constant :CYCLIC_CONTRACT

        # ONE rung of the graph a class merely HOLDS, descended under the two bounds every such walk needs, and
        # the one seam both of this builder's edges take — so the counter cannot restart at a hop.
        #
        # `child` is what the descent is ABOUT to walk (the nested bag, or the members list a shape names), which
        # is the identity a cyclic graph brings back around; keying on the parent instead would let one turn of a
        # two-node cycle pass unseen. Ancestry-scoped, so a bag or a members list reused by SIBLING positions
        # still emits in full and only genuine self-containment is a cycle. `depth` catches the other half a
        # cycle guard cannot see: a GENERATIVE graph, minting a fresh bag or shape on every read, repeats no
        # object and is endless rather than cyclic.
        def guard_contents_descent(child, ancestry, edge:)
          depth = ancestry ? ancestry.depth : 0
          raise ArgumentError, contents_too_deep_message(edge) if depth > Axn::Internal::ShapeGraph::MAX_NESTING

          outcome = Axn::Internal::CycleGuard.guard(child, ancestry&.seen, on_cycle: CYCLIC_CONTRACT) do |seen|
            yield Axn::Internal::CycleGuard::Ancestry.new(seen:, depth: depth + 1)
          end
          raise ArgumentError, contents_self_containing_message(edge) if CYCLIC_CONTRACT.equal?(outcome)

          outcome
        end

        # Both texts come from `ShapeGraph`, which owns one sentence per defect per edge — the same four the
        # declaration walk, the runtime validators and the ambient walk report, so no two layers describe one
        # defect two ways. The shape pair names no member: a bag's `shape:` hangs off an UNNAMED position, and
        # what this walk holds at the point of refusing is the bag rather than anything that declared it.
        def contents_too_deep_message(edge)
          return Axn::Internal::ShapeGraph.inner_contract_too_deep_message if edge == INNER_CONTRACT_EDGE

          Axn::Internal::ShapeGraph.too_deep_message(nil)
        end

        def contents_self_containing_message(edge)
          return Axn::Internal::ShapeGraph.inner_contract_self_containing_message if edge == INNER_CONTRACT_EDGE

          Axn::Internal::ShapeGraph.self_containing_message(nil)
        end

        # The `shape:` an `of:` bag carries, overlaid onto the node built from that bag's `klass:`. A bag's shape
        # names the members of the value AT THAT POSITION, so its members are that node's `properties` — the same
        # merge `apply_structured_schema!` makes at a field's items node, written once here so a shape one rung
        # down emits exactly what a shape at the top emits. Its members are what the projection size cap and
        # collision attribution then charge, since both read `plan.type_schema` and this Hash IS that schema.
        #
        # Gated on the same rule the field-level overlay is gated on (`shape_overlay_applies?`), asked of the bag
        # itself because the bag's `klass:` is what its members are read off: a scalar element keeps its scalar
        # type and validates members against it without ever emitting them, and on OUTPUT a class that is not
        # provably member-keyed is left untyped rather than promising an object the serializer will not produce.
        def contents_member_schema(node, bag, for_output:, ancestry: nil)
          shape = emitted_contents_edge(bag, :shape, for_output:)
          return node if nil.equal?(shape)
          return node unless shape_overlay_applies?(bag, for_output:)

          member_props, required = member_properties(shape[:members], for_output:, ancestry:)
          # The object type is written back through the same nullability helper the node already carries its
          # `null` branch through (`reconcile_contents_nullability`, above this call in `contents_node_schema`),
          # rather than a bare "object" that would discard it: a tolerant position naming a `shape:` is where a
          # `NilClass` union could never reach before this position could be nullable at all
          # (`_shape_compatible_klass!` refuses one), so nothing forwarded that branch through this merge until now.
          merged = node.merge(type: type_with_nullability("object", nullable: Array(node[:type]).include?("null")),
                              properties: (node[:properties] || {}).merge(member_props))
          merged[:required] = required unless required.empty?
          merged
        end

        # One edge of a bag, reduced on OUTPUT exactly as a field's entries are (`effective_validations`): an
        # entry carrying a per-validator gate of its own can be skipped on any given call, so what it
        # constrains cannot be promised outbound and the schema must not describe it. A bag's `of:`/`shape:`
        # ARE the next level's ActiveModel entries — `OfValidator#inner_contract_validations` hands them over
        # verbatim — so a gate written on one gates it exactly as the same gate at a field does. Asked here
        # rather than only at the top level because a distributing `shape:` is canonicalized INTO a bag
        # (PRO-3166), so the gated node the field-level reduction used to drop now arrives one rung down.
        #
        # INPUT is untouched, for the reason `effective_validations` leaves it untouched: static-maximal is the
        # safe direction there, since a gate can only relax enforcement at runtime.
        def emitted_contents_edge(bag, key, for_output:)
          edge = Axn::Internal::ShapeGraph.hash_or_nil(bag[key])
          return nil if !nil.equal?(edge) && for_output && entry_self_gated?(edge)

          edge
        end

        # What a map's `values:` axis contributes to the node holding it, under the key it lands at — or `{}` where
        # the axis has nothing to state. ONE derivation, so a map at a FIELD (`shape_property_plan`) and a map
        # nested inside another container (`contents_node_schema`) cannot describe the same axis two ways.
        #
        # A values axis naming no class constrains nothing at runtime — `matches_axis?` waves every value through
        # — and emits nothing here, so the document and the runtime agree that the axis is unconstrained. An
        # array's element position cannot reach this state at all: a bag naming an empty class union is refused
        # at declaration (`_reject_unconstraining_of_bag!`), which is what keeps the emitted `items` from
        # claiming a constraint the runtime does not enforce. So the two containers settle emptiness themselves
        # rather than in the shared builder. A class whose schema is untyped (an unknown type
        # on output) has nothing to state either, and both cases emit no node at all rather than an empty
        # `additionalProperties` that would read as a constraint.
        #
        # An axis holding a BAG is one unnamed position exactly as an array's element is, so it is built by the
        # node builder rather than from a class list: everything a bag can declare — its own `klass:`, the members
        # named off it, and the container inside it — reflects at a map's value the way it reflects at an array's
        # element. Classified through `hash_or_nil`, the same read the declaration layer classifies the axis with,
        # so the emitter cannot read an axis under the other grammar from the one it was canonicalized under.
        #
        # `ancestry` is where the walk already is, threaded so a chain alternating map and array rungs is bounded
        # on the one counter `contents_node_schema` spends rather than restarting it at every map. The axis
        # itself spends no further rung: reaching the map bag was the rung, and the axis is where that rung lands.
        def map_values_schema(bag, for_output:, ancestry: nil)
          axis = Axn::Internal::ShapeGraph.hash_or_nil(bag[:values])
          values =
            if nil.equal?(axis)
              klasses = Axn::Internal::ShapeGraph.type_tokens(bag[:values])
              klasses.empty? ? {} : contents_schema_for(klasses, for_output:)
            else
              contents_node_schema(axis, for_output:, ancestry:)
            end
          node = values.empty? ? {} : { additionalProperties: values }
          keys = map_keys_schema(bag, for_output:)
          keys.empty? ? node : node.merge(propertyNames: keys)
        end

        # The `keys:` axis, as `propertyNames`. PRO-3165 emitted nothing here on the grounds that every JSON
        # object key is already a string, so `keys: String` says nothing a client can act on and `keys: Symbol`
        # would misdescribe the wire — and that reasoning still holds for an axis that only names a TYPE.
        # It stops holding once the axis carries a constraint, which is what `propertyNames` is for.
        #
        # Only the constraints that survive the string form of a JSON key are emitted, which the projector
        # decides for itself: it keys every keyword off the node's own emitted `type:`, and a key node's type is
        # `"string"` whatever Ruby class the axis names. So a `format:`/`length:`/`presence:` reflects and a
        # numeric bound does not — a Ruby Hash key may legitimately be an Integer, but no `propertyNames`
        # subschema says "parses to an integer greater than zero", so that stays enforced-in-Ruby-only, exactly
        # as a bare `keys: Symbol` already is.
        # `for_output:` is threaded rather than defaulted: a self-gated validator on this axis promises nothing
        # on output for the same reason it promises nothing at an element position, and forgetting it here is
        # how the element-position fix stayed half-applied — one call site swept, one missed.
        def map_keys_schema(bag, for_output:)
          axis = Axn::Internal::ShapeGraph.hash_or_nil(bag[:keys])
          return {} if nil.equal?(axis)
          # A JSON object key is a String, so an axis whose declared class EXCLUDES String cannot be satisfied
          # from JSON at all — and then every inbound keyword here is a lie, not just the set: a
          # `keys: { klass: Symbol, format: … }` told a client to send `{"a" => 1}`, which the axis rejects on
          # the class check before the pattern is ever consulted. Gated on the CLASS rather than per keyword,
          # which is what round 11 got wrong by fixing only the enum. On output the key has already been
          # serialized to a String, so the whole projection stands.
          return {} unless for_output || axis_admits_string_key?(axis[:klass])

          # The node is built with the type a JSON object key always has, so the projector keys each keyword off
          # `"string"` — which is what decides, on its own, that a `format:`/`length:` reflects here and a
          # numeric bound does not. The type is then dropped: `propertyNames` needs no `type: "string"` of its
          # own, and an axis that constrained nothing reduces to `{}` and emits no `propertyNames` at all.
          node = { type: "string" }
          apply_value_constraints!(node, key_axis_constraints(axis, for_output:), nullable: false, for_output:, property_names: true)
          node.except(:type)
        end

        # The axis's validators, less any whose subject does not survive serialization. Only the OUTPUT side can
        # reach that mismatch: an inbound key is the wire string itself, and the reachability gate above has
        # already turned the whole projection away for an axis that could not be satisfied from JSON at all.
        def key_axis_constraints(axis, for_output:)
          constraints = bag_value_constraints(axis, for_output:)
          return constraints unless for_output
          return constraints if own_wire_form?(axis[:klass])

          constraints.except(*OBJECT_SUBJECT_KEY_VALIDATORS)
        end

        # Whether the value at a bag's position may be nil — `Base.nil_accepted?`, the same seam a field's
        # `nil_allowed?` reads, asked of the bag's own `klass:` and validators. A bag that constrains nothing at
        # all admits nil, exactly as an empty validator set does at a field.
        def bag_nullable?(bag, for_output:)
          validations = bag_value_constraints(bag, for_output:)
          klass = bag[:klass]
          # Synthesized in the CANONICAL `type:` shape a field's stored validations carry. A bare token would be
          # normalized as a validator scalar and read under the wrong key entirely, so `type_admits_nil?` would
          # see no `klass:` and call a nil-admitting union nil-rejecting.
          validations = validations.merge(type: { klass: }) unless Axn::Internal::ShapeGraph.type_tokens(klass).empty?

          Axn::Validation::Base.nil_accepted?(validations)
        end

        # Bring the type a bag's `klass:` produced into line with the nullability derived above. A `NilClass`
        # token contributes a `null` branch like any other token, and so can a position's own tolerance
        # (PRO-3225) with no `NilClass` token in sight — `of: { klass: String, allow_nil: true }` admits nil at
        # runtime though nothing in `klass:` said so. So this ADDS the branch a nullable position is missing,
        # through the same two helpers `apply_type_info!` unions a field's type with (`type_with_nullability`,
        # `union_with_nullability`) — not a second reading of "what nullable adds to a type", the same one.
        def reconcile_contents_nullability(node, nullable:, for_output: false)
          if node[:anyOf].is_a?(Array)
            return node.merge(anyOf: union_with_nullability(node[:anyOf], nullable: true)) if nullable

            without_null = node[:anyOf].reject { |member| member[:type] == "null" }
            return { enum: EMPTY_ENUM } if without_null.empty?

            return without_null.size == 1 ? node.except(:anyOf).merge(without_null.first) : node.merge(anyOf: without_null)
          end

          return node.merge(type: type_with_nullability(node[:type], nullable: true)) if nullable && node.key?(:type)
          return node if nullable

          # The position's mirror of a field's lone required `NilClass`: nothing but nil is a NilClass, and the
          # validator that makes the position non-nullable rejects nil, so it admits nothing — and `{ type:
          # "null" }` advertised the one value it rejects, letting `[null]` through a schema whose runtime
          # refuses it. `enum: []` is the faithful node, the same spelling `unsatisfiable_type?` reaches at a
          # field. A union that reduces to no branch at all is the same contract and now says so too, where
          # returning the node restored the very `null` branches this just rejected.
          return { enum: EMPTY_ENUM } if unsatisfiable_type?(node[:type], nullable:)

          # A position that names no TYPE still rejects nil, and had no way of saying so: a classless bag is
          # newly legal (PRO-3193), so `of: { presence: true }` builds an empty node, the parent then omits
          # `items` altogether, and the document accepted `[null]` that the positional validator rejects on
          # every call. `not: { type: "null" }` is the spelling a named field's `reject_null!` already uses for
          # exactly this shape — an untyped node that excludes nil.
          #
          # Only nil. The other blanks `presence:` rejects (`""`, `[]`, `{}`, `false`) need to know that
          # presence is WHY the position is non-nullable — a `klass:` that simply excludes NilClass says nothing
          # about them — and that plumbing is PRO-3240's, alongside the rest of the blank axis.
          #
          # INBOUND only, and the asymmetry is the doctrine rather than an omission: outbound the schema may say
          # LESS than the contract and never more, and an untyped output position is untyped precisely because
          # the emitter could not prove what it serializes to — `of:` a Data with a custom `as_json` among them.
          # Writing a claim there would be inventing one in the direction reflection may not err.
          return node.merge(not: { type: "null" }) if !for_output && !node.key?(:type) && !node.key?(:anyOf) && !node.key?(:enum)

          node
        end

        # A bag's VALUE constraints as a validations hash the field-level emitters can read: its validator
        # entries, minus what describes the position rather than constrains it.
        #
        # The position's TOLERANCE is kept, and it is the reason this is a merge rather than a slice: it rides
        # in as the declaration tier every emitter already resolves against (`shared_validation_options`), so
        # nullability, the emptiness floor and the value keywords all read it here exactly as they read a
        # field's. That is what keeps `of: { klass: String, length: { minimum: 2 }, allow_blank: true }`
        # emitting the same shape as the field it mirrors — no floor, plus a null branch — without a second
        # implementation of the rule.
        #
        # The other shared options do NOT come through. A gate is reduced away by `effective_validations` on
        # output and means nothing to the document on input, and the context/strict options are refused at
        # declaration.
        def bag_value_constraints(bag, for_output:)
          constraints = Axn::Validation::Base.validator_entries(bag)
                                             .except(*Axn::Internal::ShapeGraph::POSITION_DESCRIPTION_KEYS,
                                                     *Axn::Internal::ShapeGraph::INNER_CONTRACT_EDGES)
          # On OUTPUT a self-gated entry promises nothing — the action may successfully expose a value the entry
          # would have rejected — so it is reduced away exactly as `effective_validations` reduces a named
          # field's, and for the same reason: an output schema that rejects what the action can serialize is
          # worse than one that says less. `emitted_contents_edge` already does this for the bag's `of:`/`shape:`
          # edges; this is the same reduction for its validators.
          #
          # The merge is applied AFTER `effective_validations` so the reduction cannot drop the tolerance tier
          # it needs to see.
          #
          # Only a TRUE tolerance rides in — `_canonicalize_bag_tolerance!` states `false` explicitly on every
          # bag, but that explicit `false` is a declaration-time fact about the POSITION (kept elsewhere so a
          # field's own tolerance can never leak into it), not a runtime fact about the VALIDATORS this hash
          # feeds. A field's `allow_blank: false` is real here because ActiveModel merges it into every entry
          # it builds (`declaration_defaults.merge(entry)`) and `LengthValidator#initialize` reacts to it by
          # adding an implicit `minimum: 1` — a bag's tolerance never reaches that merge at all
          # (`OfValidator#inner_contract_validations` excludes it from what it hands `validates`), so a bag
          # position with a bare `length: { maximum: 4 }` never rejects `""` the way a field declaring the same
          # `allow_blank: false` would. Forwarding the bag's `false` here fed that FIELD-only reading a fact
          # the bag's own runtime never acts on and put `minLength: 1` on a position that accepts `""`. Nothing
          # downstream distinguishes "false" from "absent" — every reader here asks a truthy question — so
          # dropping it costs no other case its answer.
          effective_validations(constraints, for_output:)
            .merge(Axn::Validation::Base.true_tolerance_options(bag))
        end

        def single_contents_schema(klass, for_output: false)
          # A Data value serializes member-keyed via to_h, so it reflects as an object — except on OUTPUT when
          # it isn't provably member-keyed (a custom as_json/to_h serialize_value would follow); leave those
          # untyped rather than promise an object.
          if strict_descendant?(klass, ::Data) && (!for_output || member_keyed_object_type?(klass))
            { type: "object", properties: klass.members.to_h { |m| [m, {}] } }
          else
            json_type_for({ type: klass }, for_output:)
          end
        end

        # A DECLARED member's `field` is already the Symbol the declaration walk judged it under (`ShapeConfig`
        # normalizes, and the walk canonicalizes a duck-typed member's name once, beside the duplicate check).
        # It is still symbolized here because `build_input` is public: a config a downstream caller built itself
        # may carry a raw name, and every other schema property key is a Symbol (top-level `config.field`,
        # symbolized wire keys) — so this keeps a string-named member colliding with a dotted/explicit subfield
        # (`bar.baz`) resolving to the one `:bar` property that every downstream lookup (apply_implicit_node!'s
        # `existing`, explicit-child overwrite) already keys by symbol, not a String duplicate alongside it.
        #
        # `required` renders the SAME Symbol rather than converting the name a second time: two conversions of
        # one caller object are two answers it can give, and a name that gave them differently would list a
        # required property this method never emitted.
        #
        # THE shape-member hop, and so the one place a shape rung is charged against the shared counter (see
        # `guard_contents_descent`). Every route into a shape's members runs through here — the field's own
        # `shape:`, a nested member's, and the `shape:` an `of:` bag carries — so a graph alternating the two
        # edges spends a rung on each turn wherever it entered. Guarded on the MEMBERS list rather than on the
        # shape node, because that is the object this hop descends and the identity a self-containing shape
        # brings back around.
        def member_properties(members, for_output:, ancestry: nil)
          guard_contents_descent(members, ancestry, edge: SHAPE_EDGE) do |child|
            build_member_properties(members, for_output:, ancestry: child)
          end
        end

        def build_member_properties(members, for_output:, ancestry:)
          props = {}
          required = []
          named_members(members).each do |m, name|
            key = name.to_sym
            props[key] = build_property(m, for_output:, ancestry:).compact
            # On OUTPUT, a member whose presence obligation can be gated off — either wholesale by a
            # declaration-level gate, or because every nil-rejecting entry is nil-tolerant or covered by a
            # per-validator (nested) gate — can legitimately be skipped or emitted without a value by a
            # closed gate (the serializer emits no key, or a nil/blank one, for it). requiredness_conditionally_relaxable?
            # (superset of conditionally_gated?) subsumes both cases, so requiredness is dropped along with
            # (already-handled) gated constraints. INPUT stays static-maximal (a client is still expected to
            # send the member) — stricter, and safe.
            required << key.to_s unless optional_for_schema?(m) || (for_output && requiredness_conditionally_relaxable?(m))
          end
          [props, required]
        end

        # Returns [id_field_symbol, prop_hash] for a model: config. No type constraint: `find`/custom
        # finders accept any nonblank PK token, and inferring the real PK type would require a DB load.
        def model_id_property(config)
          model_opts = config.validations[:model]
          klass = model_opts[:klass]
          # The declared class written into PROSE, which owes both halves of that obligation: the name is read
          # natively (`ClassName.of_module` binds `Module#to_s`, so a `name`/`to_s` of the class's own cannot
          # answer it — measured, one that raises took the whole reflection down), and its bytes are RENDERED,
          # because a constant may hold non-UTF-8 ones that cannot be joined to axn's prose at all. The
          # declaration guard has already refused a non-Module `model:` token, so the receiver is always a
          # Module here; `Module#to_s` also names an ANONYMOUS class, where the `name` this replaces answered
          # nil and left the description reading "ID of the  record".
          klass_name = Axn::Internal::Text.renderable(Axn::Internal::ClassName.of_module(klass))
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

        # Every question here is put to the token WITHOUT dispatching, and the reason is not only reflection's
        # own rule that a walk may run none of a caller's code: a declaration GUARD reads this — the blank axis
        # asks whether a declared type's branch can carry a size at all (`token_carries_a_size?`) — so a token
        # answering for itself would decide whether a contract is refused, and one whose method raises would
        # replace that verdict with its own exception, at class-definition time. Measured on an `Array` subclass
        # with a singleton `hash`: `TYPE_MAP.key?(token)` ran it.
        #
        # So the four spellings a token could otherwise answer are each replaced by a native one. Identity
        # (`Identity.same?`, a bound `equal?`) stands in for `==` against a known token; `Identity.kind?`
        # (`Module#===`, C-level) for `is_a?`; `NativeMethods.includes_module?` — which reads the ancestry out
        # of the method table — for `<`/`<=`/`>=`; and `map_type_for`/`map_format_for` scan the emitter's own
        # maps by identity rather than looking a token up by its `hash`/`eql?`. The answers are identical for
        # every token that does not define one of those methods, which is every token a declaration means.
        def single_type_for(klass, for_output:)
          return { type: "boolean" } if Axn::Internal::Identity.same?(klass, :boolean)
          # TypeValidator accepts only the singleton value for TrueClass/FalseClass, so constrain the schema
          # to it (a bare `type: "boolean"` would let a client send the other value and pass validation).
          return { type: "boolean", enum: [true] } if Axn::Internal::Identity.same?(klass, ::TrueClass)
          return { type: "boolean", enum: [false] } if Axn::Internal::Identity.same?(klass, ::FalseClass)
          return { type: "string", format: "uuid" } if Axn::Internal::Identity.same?(klass, :uuid)
          return { type: "object" } if Axn::Internal::Identity.same?(klass, :params)

          # A declared type that ADMITS a Complex value (`type: Numeric` or `type: Complex`, i.e. Complex is
          # the class or one of its ancestors) can serialize to a JSON number (real Numerics) OR a String
          # (Complex — Float() rejects it, so Values.serialize_value falls back to to_s). Its output wire
          # form isn't knowable from the declaration, so leave it UNTYPED on output rather than assert
          # "number" the serialized value could contradict. Input still resolves below: `Numeric` maps to
          # "number" (a JSON number is a real Numeric and validates), `Complex` to the permissive "string".
          return {} if for_output && class_token?(klass) && Axn::Internal::NativeMethods.includes_module?(::Complex, klass)

          mapped = map_type_for(klass)
          unless nil.equal?(mapped)
            result = { type: mapped }
            format = map_format_for(klass)
            result[:format] = format unless nil.equal?(format)
            return result
          end

          # A Numeric subclass not in TYPE_MAP (BigDecimal, Rational, …) serializes to a JSON number
          # (Values.serialize_value coerces it via Float()), so reflect it as "number" rather than the
          # object/string fallback. Complex is the exception: Float() rejects it, so on input it drops to
          # the permissive "string" below (a JSON client can't send a Complex anyway; output is handled
          # above).
          return { type: "number" } if numeric_but_not_complex?(klass)

          # Unknown class: the serialized shape is only knowable at runtime (Values.serialize_value emits
          # an object for an as_json/to_h value but a string for a to_s-only one), so on output leave it
          # UNTYPED rather than assert `object` the serialized value might contradict. On input, keep a
          # permissive `string` hint (a JSON client can't send a Ruby object anyway — see the reflection
          # docs on coercing Ruby-object input types).
          return {} if for_output

          { type: "string" }
        end

        # Whether the token is a Class at all, asked through `Module#===` rather than the token's own `is_a?`.
        # The Complex and Numeric branches both need it: `Complex`'s ancestry holds `Comparable`, a MODULE, and
        # the old `klass.is_a?(Class)` guard is what kept a declared `Comparable` out of the output-untyped
        # branch.
        def class_token?(klass) = Axn::Internal::Identity.kind?(klass, ::Class)

        # `klass < mod` — STRICT descent — read out of the token's ancestry rather than through its own `<`.
        # Strict matters at every call site: `Data` and `Struct` are not themselves member-keyed, only their
        # subclasses are, and `Hash` is tested by identity separately where it counts.
        #
        # Establishes Class-ness FIRST, which is the precondition every `NativeMethods` module reader states:
        # binding `ancestors` to a non-Module is a TypeError, and that would replace the verdict being decided
        # with an error from the reader meant to protect it. The `<` this replaces raised NoMethodError on a
        # non-Module for the same reason, so each caller guarded separately; holding the precondition here
        # keeps the three of them from having to remember it (measured — one forgot, and a nil `type:` bag's
        # `klass:` took the reflection down).
        def strict_descendant?(klass, mod)
          return false unless class_token?(klass)
          return false if Axn::Internal::Identity.same?(klass, mod)

          Axn::Internal::NativeMethods.includes_module?(klass, mod)
        end

        # A Numeric subclass other than Complex — `klass < Numeric && !(klass <= Complex)`, read out of the
        # token's ancestry rather than through its own `<`/`<=`. STRICT descent, so `Numeric` itself falls
        # through to `TYPE_MAP` (where it is "number" already) exactly as it did.
        def numeric_but_not_complex?(klass)
          return false unless class_token?(klass)
          return false if Axn::Internal::Identity.same?(klass, ::Numeric)
          return false unless Axn::Internal::NativeMethods.includes_module?(klass, ::Numeric)

          !Axn::Internal::NativeMethods.includes_module?(klass, ::Complex)
        end

        def map_type_for(klass) = identity_lookup(TYPE_MAP, klass)

        def map_format_for(klass) = identity_lookup(FORMAT_MAP, klass)

        # One of the emitter's own maps, looked up by IDENTITY: `Hash#[]`/`#key?` would hash the TOKEN and
        # compare it with `eql?`, both of which a caller's Class can define. The maps are axn's own frozen
        # Hashes keyed by ten core classes, so the scan is bounded and its receiver is never the token. `nil`
        # means "not in this map" — no value in either map is nil.
        def identity_lookup(map, klass)
          map.each { |key, value| return value if Axn::Internal::Identity.same?(key, klass) }

          nil
        end

        def json_type_for(validations, for_output: false)
          if validations[:type]
            tokens = declared_type_tokens(validations)
            type_hashes = tokens.map { |k| single_type_for(k, for_output:) }.uniq
            node = type_hashes.size == 1 ? type_hashes.first : { anyOf: type_hashes }
            return narrow_node_under_numericality(node, validations, tokens, for_output:)
          end

          # Outbound, the SET names a type only where it passes the same equality-safety test the `enum` itself
          # is gated on — one predicate for both emissions, since both turn on whether a member can be `==` to a
          # value that serializes differently. It can: `Integer#==` falls back to `other == self`, so a value
          # object comparing equal to `1` satisfies `inclusion: { in: [1] }` and serializes as its own string,
          # which an inferred `"integer"` then rejects. A String/Symbol/boolean/nil member settles it alone —
          # their `==` never matches a foreign class — while a numeric member asks the position to pin its class,
          # which nothing reaching here has declared (a `type:` returns above, and a bag with a `klass:` takes the
          # other branch), so a numeric set always stands down outbound. Input needs no gate: a set narrower than
          # the runtime's equality is the licensed direction there.
          if validations[:inclusion]
            enum_values = inclusion_enum_values(validations[:inclusion])
            if enum_values&.any? && (!for_output || output_enum_exact?(enum_values, validations, nil))
              types = enum_values.map { |v| enum_scalar_type(v) }.uniq
              return { type: types.first } if types.size == 1 && types.first

              # mixed (or unrecognized) value types → let `enum` constrain; emit no `type`
              return {}
            end
          end

          if (numericality = validations[:numericality]) && numericality_type_provable?(numericality, for_output:)
            return { type: "integer" } if Axn::Validation::Base.declared_only_integer?(numericality)

            return { type: "number" }
          end

          {}
        end

        # A `numericality:` entry reaches a node's branches four different ways, and each is decided from the
        # DECLARED token rather than from the emitted type alone — reading the type alone retagged branches no
        # value of the declared class can occupy.
        #
        #   a non-numeric type  drops, under EVERY spelling of the validator. `is_number?` runs before any
        #                       option is read, so no Array, Hash or boolean can satisfy it.
        #   a "number" branch   narrows to "integer" under `only_integer:`, and only where some declared token
        #                       ADMITS an Integer (`Numeric` does; `Float` does not). Retagging a Float branch
        #                       advertised the JSON integer `2`, which `is_a?(Float)` rejects — and no Float
        #                       satisfies `only_integer:` anyway (`2.0.to_s` is "2.0"), so the branch is
        #                       unreachable and drops out.
        #   a "string" branch   drops under `only_numeric:`, which demands a Numeric OBJECT. Otherwise it stays
        #                       — the validator parses a numeric STRING — and carries ActiveModel's own integer
        #                       test translated where `only_integer:` gives it one, so `"2"` passes where `"abc"`
        #                       does not and leaving the branch unconstrained advertised both.
        #   anything else       is left exactly as built.
        #
        # Narrowing both branches of `[Integer, Float]` converges them, so the node collapses; deduping is a
        # CONSEQUENCE of that convergence and never a tidy-up of its own, so a union that narrows nothing comes
        # back untouched, duplicate branches included.
        def narrow_node_under_numericality(node, validations, tokens, for_output:)
          entry = Axn::Validation::Base.validator_entries(validations)[:numericality]
          return node unless entry

          # The ENTRY's presence is the whole gate, and the two options below decide only what they alone can.
          # ActiveModel asks `is_number?` before it reads any option, and `only_numeric:` is one more restriction
          # INSIDE that check rather than the thing that establishes it — so no spelling of the validator can be
          # satisfied by a value that does not parse as a number, and a branch naming such values is unreachable
          # under all of them. Gating the pass on the options instead left the branch standing wherever neither
          # was given: `type: [TrueClass, Integer], numericality: true` accepts neither boolean and advertised
          # both. What the options still decide is the string branch (`only_numeric:` alone can drop it) and the
          # retag of a numeric branch to "integer" (`only_integer:`).
          # Resolved across BOTH tiers, the way `validates` builds a validator's options
          # (`defaults.merge(_parse_validates_options(options))`): a declaration-level `optional:`/`allow_blank:`
          # is recorded once on the declaration rather than copied into each entry, so an entry-only read answers
          # a field's tolerance wrongly. Every other tolerance judgment here goes through this same seam
          # (`presence_rejects_blank?`, `declared_size_minimum`), which is what keeps the branch and the size
          # floor from disagreeing about one declaration.
          options = Axn::Validation::Base.effective_entry_options(entry, Axn::Validation::Base.shared_validation_options(validations))
          only_integer = Axn::Validation::Base.declared_only_integer?(entry)
          numeric_only = options[:only_numeric] ? true : false
          # A tolerated BLANK never reaches the validator at all — ActiveModel skips a blank value before
          # `is_number?` runs — so a branch the numeric check excludes may still be occupied by its own blank,
          # and dropping it outright refused output the action produced (`type: :boolean, numericality:
          # { allow_blank: true }` exposes `false` successfully). Read off the options resolved above, so the
          # declaration-level `optional:` and an entry's own `allow_blank:` are covered by one read. Truthiness is
          # the whole test, exactly as it is for `only_numeric:` — ActiveModel reads `options[:allow_blank]` truthily
          # rather than resolving it per call, so a Proc tolerates a blank on every call.
          blank_tolerated = options[:allow_blank] ? true : false
          # Skipping the validator is only half of it: the value still has to get PAST the position. A required
          # position rejects an empty container on its own, so `type: [Array, Integer], numericality:
          # { allow_blank: true }` admits no `[]` however blank-tolerant the entry is, and treating the entry's
          # tolerance as the whole answer emitted a branch nothing satisfies (`enum: [[]]` beside the `minItems: 1`
          # the same declaration writes). This is the very predicate the size FLOOR is derived from, so the branch
          # and the floor cannot disagree about one declaration. It governs the EMPTY witnesses only — `false` is
          # blank without being empty, which is why a required `:boolean` really does expose it.
          empty_rejected = empty_value_rejected?(validations)

          union = node[:anyOf].is_a?(Array)
          admits = integer_admitted_by?(tokens)
          branches = union ? node[:anyOf] : [node]
          # A branch may only be DROPPED where the declared tokens prove no Numeric can occupy the position.
          # See `numeric_reachable_through_broad_token?` — the emitted type is not evidence on its own.
          drop = !numeric_reachable_through_broad_token?(tokens)
          mapped = branches.filter_map do |branch|
            numericality_branch(branch, admits, numeric_only:, only_integer:, for_output:, drop:, blank_tolerated:,
                                                empty_rejected:)
          end
          # Every branch dropping is the CONTRACT, not a case to fall back from: `type: Float, numericality:
          # { only_integer: true }` admits nothing at all — no Float's `to_s` is an integer literal, and a JSON
          # integer is not a Float — so restoring the node advertised `1.5` at a position that rejects it. A node
          # nothing satisfies is the faithful projection here, on the same terms two disagreeing `equal_to:`
          # bounds already emit `enum: []`. Refusing the declaration outright stays PRO-3220's.
          return { enum: EMPTY_ENUM } if mapped.empty?
          return node if mapped == branches

          deduped = mapped.uniq
          return deduped.first if deduped.size == 1

          union ? node.merge(anyOf: deduped) : node
        end

        # What each narrowing does to ONE branch. `only_numeric:` is the blunter of the two: it makes ActiveModel
        # demand a Numeric OBJECT rather than parse anything, so every branch naming values that are not Numerics
        # is unreachable — a string branch (the one that existed to carry `"2"`), and equally an array, object or
        # boolean branch, each measured as rejected. `only_integer:` is the finer one, retagging a numeric branch
        # and translating ActiveModel's integer test onto a string branch that survived.
        #
        # The `"null"` branch is exempt from both, and not by omission: NULLABILITY owns it. ActiveModel skips a
        # nil before any validator sees it wherever the field tolerates one, so neither option says anything
        # about nil — measured, `type: [String, Integer, NilClass], numericality: { only_numeric: true },
        # optional: true` accepts nil while rejecting every String.
        # Whether some declared token is a SUPERTYPE of Numeric — `Object`, `Comparable`, `Kernel`. Such a token
        # admits a Numeric value while `single_type_for` renders it APPROXIMATELY (`type: Object` emits a
        # `"string"` branch), so that branch's emitted type says nothing about what the position holds, and
        # dropping it as "names non-Numerics" emptied a contract `1` satisfies: `type: Object, numericality:
        # { only_numeric: true }` went to `enum: []` while accepting the Integer.
        #
        # The same lesson as the untyped branch above, one step further: an ABSENT type is not evidence, and
        # neither is an APPROXIMATE one. A token that is itself numeric is excluded — it emits a numeric branch,
        # which this pass narrows rather than drops.
        def numeric_reachable_through_broad_token?(tokens)
          tokens.any? do |token|
            next false unless Internal::Identity.kind?(token, ::Module)

            Internal::NativeMethods.includes_module?(::Numeric, token) &&
              !Internal::NativeMethods.includes_module?(token, ::Numeric)
          end
        end

        def numericality_branch(branch, admits_integer, numeric_only:, only_integer:, for_output:, drop: true, blank_tolerated: false,
                                empty_rejected: false)
          # A branch `only_numeric:` may drop is one whose emitted type NAMES values that are not Numerics.
          # Everything else is left exactly as built — including the `"null"` branch nullability owns, a branch
          # already tagged `"integer"`, and any branch whose type is ABSENT. That last is load-bearing: a missing
          # type is not evidence of anything. `type: Numeric` deliberately emits `{}` on output, its values
          # having more than one wire form, and reading that absence as proof emptied a position the action
          # satisfies with `1` — the schema rejecting output it had produced.
          # EVERY spelling of the validator drops it, which is why no option is consulted here: `is_number?` runs
          # before any of them, and no Array, Hash or boolean survives it — `[1].to_s` is `"[1]"` and `true.to_s`
          # is `"true"`, neither a numeric literal. Reading the options here left `of: { klass: :boolean,
          # numericality: true }` advertising an element the validator rejects on every call. The test stays on
          # types that NAME non-Numerics; an absent or unrecognized type still falls through to "keep".
          #
          # Exact for a boolean: `Class.new(TrueClass)` is legal and can never be instantiated (`new` AND
          # `allocate` both raise), so no value of a `"boolean"` branch is anything but `true`/`false`. For the
          # containers it rests on the same footing every spelling has always stood on — a subclass
          # reimplementing BOTH `to_s` and `to_i` to impersonate a number does satisfy the validator, and one
          # overriding `to_s` alone raises inside ActiveModel rather than passing.
          if NON_NUMERIC_BRANCH_TYPES.include?(branch[:type])
            return drop ? blank_witness_branch(branch, blank_tolerated, empty_rejected) : branch
          end

          case branch[:type]
          when "number" then only_integer ? number_branch_as_integer(branch, admits_integer) : branch
          when "string" then string_branch_under_numericality(branch, numeric_only:, only_integer:, for_output:, drop:)
          else branch
          end
        end

        # The emitted types that name values no Numeric can be, and so the only branches `only_numeric:` may
        # drop. Listed rather than derived by exclusion for exactly the reason above — an absent or unrecognized
        # type has to fall through to "keep", not to "drop".
        NON_NUMERIC_BRANCH_TYPES = %w[array object boolean].freeze
        private_constant :NON_NUMERIC_BRANCH_TYPES

        # The one blank each of those types can hold. Every branch the numeric check excludes has exactly one, so
        # a blank-tolerant position narrows the branch TO it rather than losing the branch: the result names the
        # only value that can occupy the position there, which is right in both directions at once — outbound it
        # accepts the blank the action can expose, inbound it accepts nothing else, and the runtime agrees on
        # both counts. `enum` is the spelling because a singleton boolean branch already uses it (`TrueClass`
        # emits `enum: [true]`) and because `merge_enum!` composes it by intersection.
        #
        # Each witness is FROZEN, on the same terms `EMPTY_ENUM` and `NULL_BRANCH` already are: this value is
        # handed to a consumer inside a schema, schemas are rebuilt per call and caller-mutable, and a shared
        # mutable `[]`/`{}` let one consumer's mutation reach every schema the process emitted afterwards —
        # measured, appending to one action's witness changed a DIFFERENT action class's `enum` to `[[99]]`.
        # Freezing rather than copying is what the neighbours do and buys the same property (AGENTS.md: an
        # already-frozen container needs no copy), with the difference that a mutating consumer now gets a
        # FrozenError instead of silently corrupting every later schema.
        BLANK_BRANCH_WITNESS = { "array" => [].freeze, "object" => {}.freeze, "boolean" => false }.freeze
        private_constant :BLANK_BRANCH_WITNESS

        # `nil` — drop the branch — wherever no tolerated blank can occupy it. Two ways that happens: the
        # position tolerates no blank at all, or the branch already names values that exclude this type's blank.
        # The second is the `TrueClass` case and it matters: its branch is `enum: [true]`, and `true` is not
        # blank, so nothing skips the validator there and the branch really is unreachable — while `FalseClass`
        # names `false`, which is, and survives.
        def blank_witness_branch(branch, blank_tolerated, empty_rejected)
          return nil unless blank_tolerated
          return nil unless BLANK_BRANCH_WITNESS.key?(branch[:type])

          witness = BLANK_BRANCH_WITNESS.fetch(branch[:type])
          # An EMPTY witness has to clear the position's own emptiness check, and so does an explicitly-named
          # `false`. The one exemption is the `:boolean` pseudo-type, whose blank a REQUIRED position really does
          # admit — measured, `expects :n, type: :boolean` accepts `false`, while `type: FalseClass` accepts
          # nothing at all — and its branch is the one carrying no `enum`, a `FalseClass` branch naming `[false]`
          # explicitly.
          return nil if empty_rejected && !(false.equal?(witness) && branch[:enum].nil?)

          existing = branch[:enum]
          return nil if existing && !existing.include?(witness)

          branch.merge(enum: [witness])
        end

        # A numeric branch under `only_integer:`: retagged where some declared token admits an Integer, and
        # dropped where none does — no Float satisfies the option (`2.0.to_s` is "2.0"), so the branch is
        # unreachable rather than merely narrower.
        def number_branch_as_integer(branch, admits_integer) = admits_integer ? branch.merge(type: "integer") : nil

        def string_branch_under_numericality(branch, numeric_only:, only_integer:, for_output:, drop: true)
          return nil if numeric_only && drop
          return branch unless only_integer

          merge_integer_literal_pattern(branch, for_output:)
        end

        def merge_integer_literal_pattern(branch, for_output:)
          source = Pattern.ecma_source(Axn::Validation::Base.integer_literal_regexp, for_output:)
          return branch unless source

          composed = branch.dup
          write_pattern!(composed, source)
          composed
        end

        # Whether the position's numbers reach the wire unchanged. A Ruby Integer and Float serialize exactly;
        # every other Numeric is rendered through `Float()`, which ROUNDS — `BigDecimal("0.099999999999999999")`
        # satisfies `less_than: 0.1` and then serializes AS `0.1`, which the emitted `exclusiveMaximum` rejects.
        # A bound is outbound-honest only where that rounding cannot happen.
        def numeric_serialization_exact?(tokens)
          return false if tokens.empty?

          tokens.all? do |token|
            Internal::Identity.same?(token, ::Integer) || Internal::Identity.same?(token, ::Float)
          end
        end

        # Whether a JSON integer could satisfy any of the declared tokens. Asked of Integer's OWN ancestry, the
        # undispatched form, for the reason the key-axis gates give. No declared token at all means the caller is
        # not describing a class union, and the narrowing behaves as it did before this distinction existed.
        def integer_admitted_by?(tokens)
          return true if tokens.empty?

          tokens.any? do |token|
            Internal::Identity.kind?(token, ::Module) && Internal::NativeMethods.includes_module?(::Integer, token)
          end
        end

        # Whether a `numericality:` entry proves the value will SERIALIZE as a JSON number. Two different
        # things can stop it, and it takes both options to exclude them.
        #
        # ActiveModel accepts a numeric STRING unless `only_numeric: true` is given — `"1"` passes
        # `greater_than: 0`, and passes `only_integer:` too, since that reads the string form — so an exposed
        # value may well be a String. And `only_numeric:` alone proves only that the value is a NUMERIC, which
        # is not the same as a JSON number: `Complex(1, 2)` is a Numeric and serializes as `"1+2i"`, so the
        # inferred `"number"` rejected output the action had produced successfully.
        #
        # `only_integer:` is what excludes it, and excludes it exactly: among Numerics only an Integer's `#to_s`
        # is an integer literal (a Float's carries `.`, a Rational's `/`, a BigDecimal's `e`, a Complex's `i`),
        # so the two options together pin the value to an Integer and the emitted type is "integer" rather than
        # "number". It has to be a STATIC `only_integer:`, which is exactly what `declared_only_integer?` asks;
        # `only_numeric:` needs no such test, being the one option here ActiveModel reads truthily instead of
        # resolving per call.
        #
        # On INPUT none of this applies: an inferred numeric type is merely STRICTER there, which is licensed —
        # a client is told to send `1` rather than `"1"`, and the runtime would have taken either. A declared
        # `type:` is unaffected in both directions, being read before this and proving the class itself.
        def numericality_type_provable?(numericality, for_output:)
          return true unless for_output
          return false unless Axn::Validation::Base.validator_entry_options(numericality)[:only_numeric]

          Axn::Validation::Base.declared_only_integer?(numericality)
        end

        def enum_scalar_type(value)
          return "string" if value.is_a?(String)
          return "integer" if value.is_a?(Integer)
          return "number" if value.is_a?(Float)

          nil
        end

        # Whether the field's validators, taken together, permit a nil/omitted value — the one question
        # requiredness and nullability turn on, owned by Validation::Base so a field config's own
        # `optional?` answers it identically.
        def nil_accepted?(config) = Axn::Validation::Base.nil_accepted?(config.validations)

        # Whether the config's declaration carries a declaration-level if:/unless: gate — the signal
        # that its enforcement (NOT its shape) is conditional at runtime. Asked of a config here and of
        # already-read validations in `shape_property_plan` (which holds nothing but the reduced Hash); one
        # predicate, so the two cannot answer differently. The reduction never removes a declaration-level gate
        # key, so both spellings see the same keys.
        def conditionally_gated?(config) = gated_validations?(config.validations)

        def gated_validations?(validations)
          Internal::FieldConfig::CONDITIONAL_GATE_KEYS.any? { |k| validations.key?(k) }
        end

        # Whether a single validator ENTRY carries a real per-validator (nested) if:/unless: gate — one that can
        # skip that entry alone (e.g. `presence: { if: -> { ... } }`, `type: { klass: Integer, if: :flag }`).
        # Owned by Validation::Base so the emptiness axis's deferral test and this reasoning judge one entry the
        # same way.
        def entry_self_gated?(opt) = Axn::Validation::Base.entry_self_gated?(opt)

        # Whether a single validator ENTRY's options MENTION a per-validator gate key at all — blank or
        # not (contrast entry_self_gated?, which requires a NON-blank value). A blank nested gate is not inert
        # for the declaration-level requiredness clause: per AM's measured per-key merge
        # (fields.rb#validator_gate_open?), a blank nested same-key value OVERRIDES and drops the shared
        # (declaration) gate for that key before AM ignores it — un-gating the entry. So an entry that
        # mentions ANY gate key no longer inherits the declaration gate verbatim. Owned by Validation::Base
        # so this reasoning and the declaration-time nil-skip push-down (contract.rb `_type_rejects_nil?`)
        # judge one entry the same way.
        def entry_mentions_gate_key?(opt) = Axn::Validation::Base.entry_mentions_gate_key?(opt)

        # Which gate keys EFFECTIVELY gate a single validator entry, given the declaration-level gates
        # (`decl_gates` = the sliced :if/:unless off the whole declaration, already blank-canonicalized).
        # Owned by Validation::Base so the declaration-time nil-skip push-down judges runtime skippability
        # identically; structural (never evaluates a condition), which is what keeps reflection
        # side-effect-free.
        def entry_effective_gate_keys(entry_opts, decl_gates) = Axn::Validation::Base.entry_effective_gate_keys(entry_opts, decl_gates)

        # Whether a config's requiredness can be RELAXED at runtime by a conditional GATE — the signal
        # that a required-looking route can't oblige an omitted/nil ancestor to be present, because a
        # closed gate skips the check that would otherwise reject the nil ancestor. Reasoned on EFFECTIVE
        # gates (entry_effective_gate_keys), which model AM's measured per-key merge of the declaration
        # gate with each entry's nested gate — so the two tiers combine exactly as at runtime without ever
        # evaluating a condition. Relaxable iff BOTH:
        #   * some gate exists anywhere — a declaration-level one (already blank-canonicalized) or a real
        #     (non-blank) nested one; AND
        #   * every NIL-REJECTING entry is effectively gated — the gate a closed runtime pass would skip is
        #     precisely the check that rejects the nil/absent ancestor, so nothing forces it. A nil-tolerant
        #     entry never rejects nil, so it imposes no ancestor obligation to relax.
        # The measured merge is what makes the corner cases correct: a declaration gate with a BLANK
        # same-key nested override on the lone presence check leaves it effectively UN-gated (the override
        # drops the shared gate, then AM ignores the blank), so an ungated nil-rejecting check still forces
        # the ancestor — NOT relaxable. A DISTINCT-key declaration gate (`unless:`) surviving alongside a
        # blank nested `if:` still gates the entry — relaxable.
        #
        # The "some gate exists" conjunct is load-bearing: a STATICALLY nil-tolerant config (`optional:`/
        # `allow_nil:`, no gate) must NOT be relaxed. Static tolerance does not skip a required child's
        # validators (a nil optional parent still strands a required descendant — PRO-2857), so such a
        # config stays in the subset for node_optional?'s subtree-stranding test to apply; dropping it would
        # vacuously (`[].all?`) mark the node omittable and lose that test. Only a GATE — which skips the
        # gated check entirely when closed — genuinely relaxes requiredness. Own-level emission is
        # unaffected (this governs ancestor propagation only; see annotate_node!).
        def requiredness_conditionally_relaxable?(config)
          gate_keys = Internal::FieldConfig::CONDITIONAL_GATE_KEYS
          decl_gates = config.validations.slice(*gate_keys)
          # `entries` are the real VALIDATORS — shared options (strict:, on:, …) aren't validators and
          # must not be mistaken for a nil-rejecting one (see nil_accepted?/validator_entries).
          entries = Axn::Validation::Base.validator_entries(config.validations)

          some_gate = decl_gates.any? || entries.any? { |_key, opt| entry_self_gated?(opt) }
          return false unless some_gate

          shared = shared_validation_options(config.validations)
          entries.all? do |key, opt|
            nil_tolerant_validation?(key, opt, shared) || entry_effective_gate_keys(opt, decl_gates).any?
          end
        end

        # The declaration-wide options every entry of a config rides alongside — the tier the per-entry
        # judgments resolve against. The slice itself is Validation::Base's one definition, so a judgment made
        # from a bare validations bag (the declaration guards, before any config exists) reads the same tier.
        def shared_validation_options(validations)
          Axn::Validation::Base.shared_validation_options(validations)
        end

        def nil_tolerant_validation?(key, opt, declaration_options) = Axn::Validation::Base.nil_tolerant_validation?(key, opt, declaration_options)
        def set_includes_nil?(opt) = Axn::Validation::Base.set_includes_nil?(opt)
        def validator_entry_options(entry) = Axn::Validation::Base.validator_entry_options(entry)

        # An entry's options as `validates` will hand them over — the declaration-wide shared options with the
        # entry's own merged on top, so a shared tolerance is judged here exactly as at runtime.
        def effective_entry_options(entry, declaration_options) = Axn::Validation::Base.effective_entry_options(entry, declaration_options)

        def nil_allowed?(config)
          nil_tolerance_rescues_absence?(config)
        end

        # Whether the TYPE validator itself tolerates a blank value (`type: :uuid, allow_blank: true`
        # folds `allow_blank` into the type validator's options). Only the type validator's own option
        # matters for dropping `format: "uuid"` — a blank-tolerant `length:`/other validator doesn't make
        # `TypeValidator` accept `""`, so the format must stay.
        def type_allows_blank?(config)
          effective_entry_options(config.validations[:type], shared_validation_options(config.validations))[:allow_blank] == true
        end

        # Strip `format: "uuid"` from anyOf members: a blank-tolerant uuid accepts "" at runtime, which a
        # strict `format: uuid` validator would reject (mirrors the scalar-type relaxation above).
        def drop_uuid_format(members)
          members.map { |m| m[:format] == "uuid" ? m.except(:format) : m }
        end
      end
    end
  end
end
