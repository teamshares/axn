# frozen_string_literal: true

# A gated side's projection reads the gate keys a conditional declaration is recognized by.
require "axn/internal/field_config"
# A map axis's own declared bag is read tolerantly, as every other config read on the build path is.
require "axn/internal/shape_graph"
require "axn/internal/reflection/schema/vocabulary"
# A type-agnostic projection enumerates the size keywords and type tokens those two own.
require "axn/internal/reflection/schema/sizing"
require "axn/internal/reflection/schema/type_tokens"

module Axn
  module Internal
    module Reflection
      module Schema
        # Two emitted properties at ONE wire position, both enforced at runtime, made into the one property the
        # document states: an ancestor's shape member beside a node's own declaration, a second route to the same
        # node, two map axes, a values axis beside the named keys it also governs. Every collision the builder
        # meets comes through `conjoin_shape_member_property`, `conjoined_route_property` or
        # `conjoin_map_value_axes`; what they emit is plain Hash to Hash, which is why it can be read apart from
        # the walk that finds the collisions.
        module Merge
          include Vocabulary

          # A `values:` axis schema carrying none of these is FLAT — a plain scalar leaf (`{type:
          # "integer"}`, `{type: "string", pattern: …}`), with no nested Hash or Array of its own to alias
          # and no member count of its own to multiply. Any of these means the axis is itself object- or
          # array-shaped (`values: SomeDataClass`, `values: { klass: Hash, shape: {…} }`) or a union that
          # might branch into one (`anyOf`/`oneOf`) — the two conditions PRO-3441's round 2 review (PR #285)
          # found `conjoin_map_value_axes` handling unsafely, addressed below by never duplicating one.
          NESTED_AXIS_SCHEMA_KEYS = %i[properties items additionalProperties propertyNames anyOf allOf oneOf not].freeze

          def flat_axis_schema?(schema) = !schema.keys.intersect?(NESTED_AXIS_SCHEMA_KEYS)

          # A complete, independent copy of a FLAT axis schema — never called on a nested one, which never
          # reaches this file's own `Hash`/`Array`/`String` at all (`flat_axis_schema?` gates that above),
          # so recursing is safe precisely because it is bounded: what is left once every SCHEMA-shaped
          # nesting is excluded is DATA an author wrote out by hand (an `enum` list, a nullable `type`
          # union, a `pattern`/`format`/`description` string) — literal, author-sized, never the arbitrarily
          # large member tree a `shape:` or `items` could hold. PRO-3441 round 3 (PR #285): a bare top-level
          # `.dup` only detaches the outer Hash, so `enum: [1, 2, 3]` (an `inclusion:` axis) or `type:
          # ["integer", "null"]` (a nullable one) stayed the SAME Array across every colliding property and
          # `additionalProperties` — mutating one's `enum` in place mutated every sibling's too.
          #
          # `instance_of?`, not `case`/`when` — round 7 (PR #285): `case value; when ::Hash` dispatches on
          # `Module#===`, which is `is_a?`-based and matches a SUBCLASS too, so a Hash/Array/String subclass
          # here reached its own overridden `#transform_values`/`#map`/`#initialize_copy` — reflection
          # executing caller code, confirmed directly (a `Hash` subclass's overridden `#transform_values`
          # ran). Mirrors `normalize_schema_literal`'s own EXACT-class check in `schema.rb`, for the
          # identical reason it already states: "an Array/Hash/String SUBCLASS could override map/each_with_
          # object/dup with user code, and reflection must stay side-effect-free." A subclass instance in an
          # otherwise-flat schema never actually reaches here: `axis_leaf_payload_size` (below) charges it
          # `Float::INFINITY` first, which `conjoin_map_value_axes` checks BEFORE calling this — but this
          # stays exact-class too, on its own terms, rather than depending on staying downstream of that.
          def detach_flat_axis_schema(schema)
            if schema.instance_of?(::Hash)
              schema.transform_values { |v| detach_flat_axis_schema(v) }
            elsif schema.instance_of?(::Array)
              schema.map { |v| detach_flat_axis_schema(v) }
            elsif schema.instance_of?(::String)
              schema.dup
            else
              schema
            end
          end

          # `String#bytesize`, UNDISPATCHED — a String subclass may override it (this codebase already
          # distrusts one elsewhere: "a String subclass whose `valid_encoding?` lies"), and reflection may
          # not run a caller's code (`docs/reference/class.md`'s own reflection contract, `AGENTS.md:L261-
          # L263`). Bound the same way `property_names.rb`'s `STRING_TO_SYM`/`wire_key_segment` already bind
          # `String`'s own methods for the identical reason.
          AXIS_STRING_BYTESIZE = ::String.instance_method(:bytesize)

          private_constant :AXIS_STRING_BYTESIZE

          # A fixed charge per `Hash`/`Array` NODE, in addition to what its own entries cost — round 7 (PR
          # #285): a huge COUNT of near-empty containers (`inclusion: { in: Array.new(500_000) { [] } } }`)
          # measured near zero bytes under the entry-only sum, since an empty Array sums to nothing, while
          # `detach_flat_axis_schema` still allocates one fresh Array PER CONTAINER, per colliding property —
          # measured directly: 100 colliding properties beside a 500,000-empty-Array `inclusion:` set took
          # ~7s to build ONE schema, entirely under the byte cap. What is actually being duplicated is
          # OBJECTS, not merely bytes, and a container is an object whether or not it holds any of its own.
          AXIS_CONTAINER_OVERHEAD = 8

          # The SAME idea one level down: a fixed MINIMUM charge per Array SLOT / Hash ENTRY, not only per
          # container — round 8 (PR #285) found the container charge closes a container COUNT but not a
          # SLOT count: `Array.new(500_000) { "" }` is still ONE container (charged once) holding 500,000
          # zero-byte Strings (charged nothing each), so the round-7 fix left this at ~8 bytes total while
          # `detach_flat_axis_schema` still `.dup`s 500,000 Strings and allocates a 500,000-slot Array PER
          # colliding property — measured directly: 100 colliding properties beside a 500,000-empty-string
          # `inclusion:` set took ~7.4s, the identical shape of gap the container charge closed one level up.
          # `[actual, AXIS_SLOT_OVERHEAD].max`, not a flat add, so a slot whose own content is already
          # correctly charged more than this floor (a real string, a nested container) is not double-counted
          # — only a slot cheaper than the floor is raised to it, which is exactly the case this closes.
          AXIS_SLOT_OVERHEAD = 8

          # The cost of duplicating a schema, estimated WITHOUT serializing it. PRO-3441 round 6 (PR #285):
          # `JSON.generate` is not safe here — it can RAISE on a legal Ruby literal JSON cannot encode
          # (`Float::INFINITY` in an `inclusion:` set, which `normalize_schema_literal` in `schema.rb`
          # deliberately PRESERVES rather than rejects, precisely so reflection doesn't fail on caller
          # data), and on an opaque literal with its own `#to_json` it EXECUTES caller code — the one thing
          # reflection may never do. `Integer`/`Float`/`Symbol`/`true`/`false`/`nil` cannot be subclassed at
          # all (Ruby raises TypeError attempting it) — so `#to_s` there always resolves to the CLASS's own,
          # never a caller override. `Hash`/`Array` are walked structurally rather than serialized, gated
          # `instance_of?` for the same reason `detach_flat_axis_schema` just above is: a subclass's own
          # overridden `#sum`/`#each` must not run either. Anything else — an opaque custom literal (the
          # reflection contract's own hard limit) OR a Hash/Array/String subclass, which `normalize_schema_
          # literal` already treats as opaque on the same grounds — is charged `Float::INFINITY`:
          # unmeasurable is not zero-cost, so it forces the SAME oversized stand-down a genuinely huge
          # literal would, rather than silently duplicating something reflection cannot safely look inside.
          def axis_leaf_payload_size(value)
            if value.instance_of?(::Hash)
              AXIS_CONTAINER_OVERHEAD + value.sum { |k, v| [axis_leaf_payload_size(k) + axis_leaf_payload_size(v), AXIS_SLOT_OVERHEAD].max }
            elsif value.instance_of?(::Array)
              AXIS_CONTAINER_OVERHEAD + value.sum { |v| [axis_leaf_payload_size(v), AXIS_SLOT_OVERHEAD].max }
            elsif value.instance_of?(::String)
              AXIS_STRING_BYTESIZE.bind_call(value)
            elsif value.instance_of?(::Symbol) || value.instance_of?(::Integer) || value.instance_of?(::Float) ||
                  value.instance_of?(::TrueClass) || value.instance_of?(::FalseClass) || value.instance_of?(::NilClass)
              value.to_s.bytesize
            else
              Float::INFINITY
            end
          end

          # Duplicating every FLAT axis at this node into N colliding properties costs N times their
          # COMBINED serialized size — not each axis's own size compared to the cap independently. PRO-3441
          # round 6 (PR #285): a merged node can carry more than one `values:` axis (`merge_shape_member_
          # property`'s own `additionalProperties` conjunction already handles two colliding `of:`s), and
          # each staying just under the cap on its own does not bound what happens as MORE declarations
          # collide at the same position — the aggregate is what actually gets duplicated into every
          # property. Computed ONCE per node, not once per property: the earlier round-6 draft called this
          # (transitively, `JSON.generate`) inside the property loop, so an oversized axis paid its own
          # full serialization cost once for EVERY property it was about to refuse to duplicate into —
          # exactly the unbounded work the guard exists to prevent, ahead of the guard itself running.
          #
          # `colliding_count` is `properties.size` at the call site — every property at this node, exempt
          # ones included, which over-counts rather than risks under-charging a genuinely expensive axis. A
          # flat MEMBER-LEVEL bound distinct from `MAX_EMITTED_PROPERTIES` (a document-wide, name-counting
          # budget in a different unit — bytes here, names there — so borrowing its number would compare two
          # different things) but the same order-of-magnitude reasoning: a schema the emitter would otherwise
          # happily emit whole should not become unreasonable once duplicated a handful of times.
          MAX_AXIS_CONJUNCTION_BYTES = 1_000_000

          def oversized_axis_conjunction?(axes, colliding_count)
            flat_payload = axes.sum { |axis| flat_axis_schema?(axis[:schema]) ? axis_leaf_payload_size(axis[:schema]) : 0 }
            (colliding_count * flat_payload) > MAX_AXIS_CONJUNCTION_BYTES
          end

          NESTED_AXIS_RESIDUE = "a nested (object- or array-shaped) values: axis also governs this key, " \
                                "enforced by the runtime, but is not repeated in the document here to avoid " \
                                "duplicating a whole subtree once per colliding property"

          OVERSIZED_AXIS_RESIDUE = "a values: axis with a large literal constraint also governs this key, " \
                                   "enforced by the runtime, but is not repeated in the document here to avoid " \
                                   "duplicating it once per colliding property"

          # PRO-3441. `properties`, with each of `axes`' schema conjoined into every entry its own `exempt`
          # set does not name — the fix `MAP_VALUE_EXEMPT_KEY` documents. Returns a FRESH Hash regardless of
          # `finalize_residues!`'s own `copy:` (a caller asking not to copy still may not mutate `properties`
          # in place here: the untouched entries alias the ORIGINAL schema's Hash, which is exactly what
          # `copy: false` promises stays untouched elsewhere), so every entry `finalize_residues!` goes on to
          # recurse into is safe to keep mutating regardless.
          #
          # `allOf`, not a keyword-by-keyword reconciliation: the axis schema and the named property's own
          # schema describe the same value two ways (this run through `conjoin_shape_member_property`'s own
          # collision logic would apply here too, but the keyword-agnostic sibling branch is the correct
          # spelling regardless of whether the two ever share `object_property?`), matching `combine_two`'s
          # own fallback for exactly this shape of "both of these apply."
          #
          # Two gates ahead of the conjunction, not one: `flat_axis_schema?` (SHAPE — no nested container to
          # duplicate) and `oversized_axis_conjunction?` (SIZE — no unbounded literal payload to duplicate
          # either, computed once for every axis at this node combined, never per property). Embedding a
          # nested axis whole into EVERY colliding property, or a flat one whose own (or combined) payload is
          # large, is what rounds 2, 4 and 6 of this review each named — every embedded copy's own descendant
          # containers alias each other and `additionalProperties`, or its literal arrays do, and
          # `PropertyNames.reject_oversized_schema!`'s declaration-time budget counts the axes' contribution
          # ONCE (beneath `additionalProperties`, from the configs that declared them) with no way to see it
          # multiplied by however many OTHER declarations collide with it. Standing either case down and
          # reporting a residue (the same "cannot state this here, name what's missing" trade every other
          # inexpressible case in the emitter already takes) closes both: nothing is ever duplicated past what
          # `MAX_AXIS_CONJUNCTION_BYTES` bounds, so nothing is ever uncounted — and what still gets embedded
          # is fully detached by `detach_flat_axis_schema`, not merely the outer Hash a bare `.dup` would
          # reach.
          def conjoin_map_value_axes(properties, axes)
            colliding_count = properties.size
            oversized = oversized_axis_conjunction?(axes, colliding_count)
            properties.to_h do |name, child|
              conjoined = axes.reduce(child) do |acc, axis|
                next acc if axis[:exempt].include?(name)
                next record_residue(acc, NESTED_AXIS_RESIDUE, kind: :unfixed) unless flat_axis_schema?(axis[:schema])
                next record_residue(acc, OVERSIZED_AXIS_RESIDUE, kind: :unfixed) if oversized

                acc.merge(allOf: Array(acc[:allOf]) + [detach_flat_axis_schema(axis[:schema])])
              end
              [name, conjoined]
            end
          end

          # The property of a node every non-model route declares. Each route's own check runs on every call, so
          # a second route's type, blank floor or bounds are conjoined with the representative's exactly as an
          # ancestor's shape member is (`conjoin_shape_member_property`, which also stands a transforming or gated
          # route down and names what it still enforces) — building from the representative alone let the
          # document admit what the other route rejects.
          def conjoined_route_property(representative, routes)
            prop = build_property(representative, subfield: true)
            own = [representative]
            routes.each do |route|
              next if route.equal?(representative)

              prop = conjoin_shape_member_property(build_property(route, subfield: true), prop, member_configs: [route], own_configs: own)
              own += [route]
            end
            prop
          end

          # An ancestor `shape:` member's already-emitted property, conjoined with the one this node's OWN
          # declaration built. Both are enforced at runtime and JSON Schema keywords at one node are conjoined
          # too, so keeping both sides' keywords IS the runtime conjunction — the node's own stand (it is the
          # more specific declaration at the position) and the member contributes everything the node does not
          # state: the object contents this branch used to drop, and with them a map's `additionalProperties`
          # and `propertyNames`, which a contents-only merge would still have lost.
          #
          # Taken from the emitted property rather than rebuilt from the member's declaration, which is what
          # makes "what the member contributes" one answer rather than two: a `Data` member's INFERRED
          # properties (shape_property_plan's base_properties) and a map's contents are not in its `members:`
          # list at all, and rebuilding would also restart guard_contents_descent's depth/cycle budget from
          # zero for a graph this walk has already descended.
          #
          # Three keys are not a plain overlay. `properties` and `required` are unioned, since each side names
          # contents the other does not — and a NAME both sides declare (PRO-3405) is not a collision to
          # resolve by precedence either: each of the two schemas at that child key is itself conjoined,
          # recursively, via merge_emitted_maps's own use of conjoin_shape_member_property, rather than one
          # replacing the other. And a size bound declared on BOTH sides takes the STRICTER of the two: a
          # value satisfying only the looser one is rejected at runtime by the other, and that is the one
          # direction a plain overlay emits too loosely.
          #
          # Taken from what is AT the key rather than from the member config, which is also why the caller guards
          # on its presence: a member whose property never reached the document is found by shape_members_at and
          # yet has nothing emitted to conjoin with. Such a member still caps nullability and still blocks at depth — it simply
          # contributes no contents here, exactly as at an implicit child (see apply_implicit_node!).
          #
          # `propertyNames` is deliberately NOT re-exempted (exempt_shaped_keys_from_property_names runs inside
          # `apply_structured_schema!`, before this): the runtime's own exemption is derived per declaration
          # from THAT declaration's `shape:` (Core::Contract#_derive_shaped_keys!), so a member carried from an
          # ancestor exempts no key at this node's map validator either. Re-running it would admit a key the
          # runtime rejects — measured, both spellings reject one.
          # Both sides' `enum`, kept as separate branches on a merged node. `:enum` is a VALUE constraint and
          # both sides are enforced, so both apply — the shallow merge leaves "second side wins", which
          # advertised the later `inclusion:` set alone and ACCEPTED a value the runtime rejects.
          #
          # BRANCHED rather than intersected, because the emitter may not decide which members the two sets
          # share: comparing an author's literals means running their `==`/`eql?`/`hash`, and reflection runs
          # none of a caller's code (`enum_for_inclusion` takes an identity check for this same reason).
          # `Array#&` does exactly that, and its `eql?` semantics are not even the runtime's — `[{a: 1}] &
          # [{a: 1.0}]` is empty while the runtime accepts `{a: 1}` against both sets, so the node came back
          # `enum: []`, satisfied by nothing, for a contract that IS satisfiable. Branching hands the question
          # to the consumer's own JSON Schema equality, which is value-based and numeric-aware (measured: an
          # `allOf` of those two sets accepts both spellings), and is what a scalar collision already does —
          # the object path merges rather than branches, which is the only reason it ever differed.
          def branch_both_enums!(merged, member_prop, own_prop)
            return unless member_prop[:enum] && own_prop[:enum]

            merged.delete(:enum)
            merged[:allOf] = Array(merged[:allOf]) + [{ enum: member_prop[:enum] }, { enum: own_prop[:enum] }]
          end

          def merge_shape_member_property(member_prop, own_prop, member_configs: [], own_configs: [])
            merged = member_prop.merge(own_prop)
            # `:type` is RECONCILED, not left to the shallow merge's "second side wins" default — a nullable
            # `["object", "null"]` on either side must not silently overwrite the OTHER side's non-nullable
            # `"object"`: an ancestor `deep` Hash member that REQUIRES `a` (non-nullable) beside a colliding
            # node's OWN `deep` declared `allow_nil: true` (nullable) let `own_prop[:type]` — merged in
            # SECOND — win outright, so the merged schema admitted `deep: null` even though the ancestor's
            # own (unconditional, raw-value) check rejects null there. Both routes are enforced, so null
            # survives only when BOTH tolerate it. This function also runs for a side that is simply EMPTY
            # (own_prop.empty?/member_prop.empty? in conjoin_shape_member_property), not only a genuine
            # object-vs-object merge, so the reconciliation must not hardcode "object" — it keeps whichever
            # REAL base type either side names.
            merged[:type] = merge_emitted_type(member_prop[:type], own_prop[:type]) if member_prop[:type] || own_prop[:type]
            # `:format` describes a SCALAR "string"-typed value — never an object — so it is dropped only
            # when the RECONCILED type above actually ended up "object" (where it would be a meaningless
            # keyword sitting beside `properties`), not unconditionally: this function also runs for a side
            # that is simply EMPTY (see the type comment above), not only a genuine object-vs-object merge,
            # and an unconditional delete here discarded a SCALAR member's own real format in that case too
            # — a `type: :uuid` shape member beside an Integer node with an opaque `preprocess: ->(_) { 1 }`
            # (stripped down to `{}` by pass 1) is satisfiable only for a valid UUID string at runtime, but
            # the merged property dropped `format: "uuid"` entirely, accepting any non-empty string. The
            # plain `merge` above already carries over whichever side's `:format` survives (at most one
            # non-empty side ever has one, since a `:format` and `:properties` are mutually exclusive on any
            # one side) — deleting it here just needs to be conditional, not removed.
            merged.delete(:format) if object_property?(merged)
            # Reassigned only when at least one side actually HAS the key — both sides bare (e.g. two
            # colliding `type: Hash` declarations with no children on either) means merge_emitted_maps/
            # merge_emitted_required return nil (nothing to merge), and writing that nil through would leave
            # an explicit `properties: nil`/`required: nil` in the document: JSON Schema requires `properties`
            # to be an object and `required` to be an array, so a null-valued keyword is an invalid document,
            # not merely a permissive one (the OUTER `.compact` calls this property eventually passes through
            # are all shallow, so a nil written INTO this property here survives every one of them).
            if member_prop[:properties] || own_prop[:properties]
              merged[:properties] = merge_emitted_maps(member_prop[:properties], own_prop[:properties], member_configs:, own_configs:)
            end
            merged[:required] = merge_emitted_required(member_prop[:required], own_prop[:required]) if member_prop[:required] || own_prop[:required]
            branch_both_enums!(merged, member_prop, own_prop)
            merged[:minProperties] = [member_prop[:minProperties], own_prop[:minProperties]].compact.max if merged[:minProperties]
            merged[:maxProperties] = [member_prop[:maxProperties], own_prop[:maxProperties]].compact.min if merged[:maxProperties]
            # A map's `values:`/`keys:` axes (`additionalProperties`/`propertyNames`) are their OWN nested
            # schema, both enforced when both sides declare one — the shallow `merge` above lets the SECOND
            # side simply overwrite the first, the same bug `:properties`/`:type` already needed reconciling:
            # an ancestor `deep` Hash member whose values axis requires `> 0` beside a colliding node's own
            # `deep` values axis requiring `< 10` emitted only the `< 10` constraint, so `deep: { x: -1 }`
            # passed the schema though the ancestor's own (unconditional) validator rejects it. Conjoined via
            # the SAME `conjoin_shape_member_property` recursion used everywhere else two schemas at one
            # position both apply — with the AXIS's own configs threaded through (not the outer field's), so a
            # gated axis entry is projected by what always runs exactly as a gated field is. An axis never
            # carries `coerce:`/`preprocess:` at all (refused at declaration — "of: does not support
            # coerce:"/"preprocess:"), so `axis_config_view` only ever needs to expose the axis's declared
            # validations, never a transform.
            if member_prop[:additionalProperties] || own_prop[:additionalProperties]
              merged[:additionalProperties] = merge_emitted_nested_schema(
                member_prop[:additionalProperties], own_prop[:additionalProperties],
                axis_configs_for(member_configs, :values), axis_configs_for(own_configs, :values)
              )
            end
            merge_map_value_exempt!(merged, member_prop, own_prop)
            if member_prop[:propertyNames] || own_prop[:propertyNames]
              merged[:propertyNames] = merge_emitted_nested_schema(
                member_prop[:propertyNames], own_prop[:propertyNames],
                axis_configs_for(member_configs, :keys), axis_configs_for(own_configs, :keys)
              )
            end
            merged
          end

          # `MAP_VALUE_EXEMPT_KEY` (PRO-3441): CONCATENATED into `merged`, not left to the shallow merge
          # `merge_shape_member_property` opens with — the "second side wins" default every OTHER keyword
          # there needed reconciling away from. A merged node can carry an axis from BOTH sides (the
          # `additionalProperties` merge just above it), and each keeps its own exempt set rather than one
          # replacing the other. Its actual conjunction into `properties` is deferred to `finalize_residues!`,
          # the one pass guaranteed to see every property this node will ever hold — including a subfield
          # `apply_nested_subfields!` has not added yet when this runs.
          def merge_map_value_exempt!(merged, member_prop, own_prop)
            return unless member_prop[MAP_VALUE_EXEMPT_KEY] || own_prop[MAP_VALUE_EXEMPT_KEY]

            merged[MAP_VALUE_EXEMPT_KEY] = Array(member_prop[MAP_VALUE_EXEMPT_KEY]) + Array(own_prop[MAP_VALUE_EXEMPT_KEY])
          end

          # A nested map axis schema present on only one side is carried through as-is; present on both, it
          # is conjoined the same way any other two-declarations-at-one-position collision is (see
          # conjoin_shape_member_property) rather than letting either side simply win.
          def merge_emitted_nested_schema(member_schema, own_schema, member_axis_configs = [], own_axis_configs = [])
            return own_schema if member_schema.nil?
            return member_schema if own_schema.nil?

            conjoin_shape_member_property(member_schema, own_schema, member_configs: member_axis_configs, own_configs: own_axis_configs)
          end

          # A minimal stand-in for a field config, exposing only `.validations` — enough to reuse the collision
          # machinery UNCHANGED for an axis bag, which is never itself an `Internal::FieldConfig`. Deliberately has NO `preprocess` method at all, so
          # `respond_to?(:preprocess)` reads false exactly as a shape member's does — `transforms_wire_
          # value?`'s own doc explains why that must be the answer here: an axis bag can NEVER declare
          # `coerce:`/`preprocess:` (both refused at declaration — "of: does not support coerce:"/
          # "preprocess:"), so unlike an ordinary field's bare-coercible-klass case (ambient
          # `coerce_input_types` MIGHT still coerce it, so reflection conservatively assumes it could), an
          # axis's klass being coercible IN PRINCIPLE is never evidence it actually transforms here — the
          # axis mechanism itself has no coercion seam at all, ambient setting or not. Defining `preprocess`
          # to return nil would have made `respond_to?(:preprocess)` true, wrongly reusing the
          # ambient-uncertainty conservatism a coercible axis klass (e.g. `values: Integer`) does not earn.
          AxisConfigView = Struct.new(:validations) do
            # So a view can be PROJECTED like any other config (`gate_resolved_sides`): an axis's own validators
            # carry nested gates, and reflecting those by what always runs needs the same re-emission.
            def with(validations:) = self.class.new(validations)
          end

          private_constant :AxisConfigView

          # The `axis_key` (`:values`/`:keys`) axis's own declared klass token(s), one view per outer config
          # that declares an `of:` bag at all — empty for a config with none, which `unknown_class_
          # approximate?`/`transforms_wire_value?` both already read as "nothing to distrust here."
          def axis_configs_for(configs, axis_key)
            configs.filter_map do |config|
              bag = Axn::Internal::ShapeGraph.hash_or_nil(config.validations[:of])
              next nil if bag.nil?

              raw = bag[axis_key]
              axis = Axn::Internal::ShapeGraph.hash_or_nil(raw)
              token = axis ? axis[:klass] : raw
              nested_of = axis && axis[:of]
              nested_shape = axis && axis[:shape]
              # A CLASSLESS axis (legally `klass:`-free — e.g. `values: { shape: { members: [...] } }`,
              # constraining only via its named members) still has a `:shape`/`:of` worth keeping even
              # though it names no token at all: skipping the whole view whenever `token.nil?` — that gate
              # — discarded that classless axis's `shape:` too, so when two colliding axes respectively
              # described a child `a` as `Object` and `Hash`, the recursive `shape_members_at` lookup
              # found NOTHING for either side, and the `Object` child's approximate hint was conjoined as
              # exact all over again. Only a TRULY empty axis (no token, no `:of`, no `:shape` — nothing
              # here distrusts or recurses into anything) is skipped now.
              next nil if token.nil? && nested_of.nil? && nested_shape.nil?

              # `:of` and `:shape` are carried forward alongside the synthesized `:type`, not just the axis's
              # own `:klass` — needed so a DEEPER collision inside the axis (another map bag nested in `:of`,
              # or named members declared via the axis's own `shape:`) can still be reconciled: outer
              # `klass: Hash` axes whose NESTED values are respectively `Object` and `Hash` lost that inner
              # structure here, since only the outer klass survived into the view — so
              # when `merge_shape_member_property` recursed one level deeper for the INNER axis,
              # `axis_configs_for` found no `:of` to read at all, and the inner `Object` axis's approximate
              # hint was conjoined as exact all over again. `shape_members_at` reads
              # `config.validations.dig(:shape, :members)` the same way for a NAMED child inside the axis's
              # own `shape:` block — two `values: { klass: Hash, shape: { … } }` axes colliding needs the
              # SAME per-child config lookup `merge_emitted_maps` already does for an ordinary object, and
              # without `:shape` on the view it found nothing, so a child typed `Object` in one axis's shape
              # collided with `Hash` in the other's as though BOTH were exact. Threading both through is what
              # lets every recursive lookup the emitter already has (`shape_members_at`, `axis_configs_for`
              # itself) keep working exactly as it does for an ordinary field's configs.
              # The axis's OWN validators come across too, derived by subtracting the three bag keys this
              # view maps itself rather than by naming Core's positional-validator list — a view that carried
              # only the klass hid an axis's `inclusion:`/bounds AND the nested gates on them, so a
              # conditional axis constraint was conjoined as though it always applied.
              validations = axis ? axis.except(:klass, :of, :shape) : {}
              validations[:type] = token if token
              validations[:of] = nested_of if nested_of
              validations[:shape] = nested_shape if nested_shape
              AxisConfigView.new(validations)
            end
          end

          # The reconciled `:type` for a merged property — nullable only when BOTH sides admit null, since
          # either side rejecting it (its own unconditional check, at runtime) forbids it here regardless of
          # what the other declares. `nil` on one side (that side is simply absent, not "typeless") returns
          # the OTHER side's type untouched, so this is safe to call whenever EITHER side has a `:type` at
          # all, not only when both are the SAME base type.
          def merge_emitted_type(member_type, own_type)
            return own_type if member_type.nil?
            return member_type if own_type.nil?

            base = (Array(member_type) + Array(own_type)).reject { |t| t == "null" }.uniq
            base = base.first if base.size == 1
            nullable = [member_type, own_type].all? { |type| Array(type).include?("null") }
            nullable ? Array(base) + ["null"] : base
          end

          # Two emitted properties at ONE wire position, both enforced at runtime (PRO-3405): a shape member's
          # own emission and the node's — or, recursively, two child properties a name collided on inside
          # merge_emitted_maps. Neither may simply win: a name both sides declare means the runtime enforces
          # both, so the document must say so too.
          #
          # Where both sides are already object-shaped, their keywords share a surface worth unioning
          # (`properties`/`required`/the size bounds) — that IS merge_shape_member_property, unchanged since
          # PRO-3399. Everywhere else — a scalar collides with a scalar, a union with an object, anything that
          # doesn't share that surface — there is no keyword-by-keyword reading that means the same thing for
          # every pair (the approach PRO-2877's pulled detectors already rejected: it invents an
          # intersection-semantics per keyword, and every keyword nobody thought of stays silently wrong). JSON
          # Schema already has the honest, keyword-agnostic spelling for "both of these apply" — `allOf`, free
          # at a property (the same trick write_pattern! uses to compose two patterns) — so the member rides
          # alongside as a sibling branch instead.
          #
          # `own_prop` being genuinely EMPTY (an explicit node with no type or shape of its own — the member is
          # then the whole story) also routes through merge_shape_member_property rather than a bare `.dup`: a
          # shallow dup would share `member_prop[:properties]` — the SAME nested Hash `apply_nested_subfields!`
          # is about to add the node's own children into — mutating the ancestor's already-emitted property in
          # place. merge_shape_member_property never has that problem (merge_emitted_maps dups the properties
          # map whenever one side is absent), so routing every combination through the one function is what
          # keeps this conjoin from being the aliasing bug AGENTS.md already names.
          #
          # `member_configs`/`own_configs` are the declarations each emitted property came from — a LIST,
          # mirroring `shape_members_at`'s own return shape, since a merged node can carry more than one route
          # to the same name. Empty (or omitted) on a side whose config is unknown at the call site, which
          # reads as "trustworthy" (the conservative, pre-existing answer) rather than crashing.
          #
          # A side is CONJOINABLE only where its emitted keywords describe the same value everything else at
          # this position reads, and two separate things can make them not — kept apart because the honest
          # response differs:
          #
          # TRANSFORM (`transforms_wire_value?`: `preprocess:`, or a coercible declared type with no explicit
          # `coerce: false`). EVERY keyword on that side judges the transform's output, while the wire carries
          # its input. `allOf` asserts every branch of ONE instance, so conjoining such a side states a
          # contract that never runs — and translating it back means inverting an arbitrary Proc, which
          # reflection cannot do and must not try. So the side stands down whole: the other one is emitted
          # alone and what this one still enforces is reported as a residue, in the property's `description`
          # and `input_schema_residues`. That is looser than the runtime here, and reported: a named, bounded
          # gap in place of an unbounded approximation no guard could trust anyway.
          def conjoin_shape_member_property(member_prop, own_prop, member_configs: [], own_configs: [], &complete_own)
            sides, gated = gate_resolved_sides([[member_prop, member_configs], [own_prop, own_configs, complete_own]])
            combined, origins = sides.reduce { |left, right| combine_two(left, right) }
            combined = project_collision_checks(combined, origins)
            prop, carried = left_of([combined, origins])
            (carried + gating_residues(gated, enforced: prop)).reduce(prop) { |acc, r| record_residue(acc, r.summary, kind: r.kind) }
          end

          # Every side to be combined, with each CONDITIONAL one replaced by the always-run property of each
          # config that contributed to it — and those configs, whose residues are named once the combined
          # node shows what it already enforces.
          #
          # A conditional side expands to one side PER config rather than being collapsed here, which is the
          # whole point of the shape: the combination then runs through `combine_two` exactly as any other
          # pair does, so an empty side is merged rather than branched, and a
          # transform stands down — none of it reimplemented. Combining projections with bespoke logic beside
          # the real conjunction is what diverged from it three times.
          def gate_resolved_sides(sides)
            gated = []
            expanded = sides.flat_map do |prop, configs, complete|
              projections = if configs.none? { |config| conditional_checks?(config) || branch_projection_required?(config) }
                              [[prop, configs]]
                            else
                              gated.concat(configs)
                              configs.map do |config|
                                full = build_property(gates_stripped(config), subfield: true)
                                [carry_metadata(projected_property(config, full), without_gating_residues(prop)), [config]]
                              end
                            end
              # Gating and transformation are independent axes. Complete a post-transform subtree
              # after projecting its own gates, but before deciding which value a collision describes.
              projections.each { |side| complete.call(side.first) } if complete
              projections
            end
            [expanded, gated]
          end

          # Two sides combined: the one place that decides what "both of these apply" emits, whatever the
          # sides came from.
          def combine_two((left_prop, left_configs), (right_prop, right_configs))
            left_transforms = transforms_wire_value?(left_configs)
            right_transforms = transforms_wire_value?(right_configs)

            if left_transforms ^ right_transforms
              left_prop = project_collision_checks(left_prop, left_configs) if left_transforms
              right_prop = project_collision_checks(right_prop, right_configs) if right_transforms
              kept, dropped = left_transforms ? [right_prop, left_prop] : [left_prop, right_prop]
              # Only retained origins may classify the next collision in this fold.
              return [stand_down_from(kept, dropped, TRANSFORM_RESIDUE), left_transforms ? right_configs : left_configs]
            end

            # Residues belong to the POSITION, not to whichever branch happened to raise them: a reader looks
            # at the property, and a sentence buried in one `allOf` entry reads as a note about that entry.
            # So they come off both sides here and are re-recorded on the finished node.
            carried = carried_residues(left_prop) + carried_residues(right_prop)
            left_prop = left_prop.except(RESIDUE_KEY)
            right_prop = right_prop.except(RESIDUE_KEY)

            # A side stripped down to nothing is not a branch either — an `allOf` entry asserting no keyword
            # constrains nothing — so it routes through the merge, which already handles an absent side.
            combined =
              if asserts_nothing?(left_prop) || asserts_nothing?(right_prop) ||
                 (object_property?(left_prop) && object_property?(right_prop))
                merge_shape_member_property(left_prop, right_prop, member_configs: left_configs, own_configs: right_configs)
              else
                right_prop.merge(allOf: Array(right_prop[:allOf]) + [left_prop])
              end

            [carried.reduce(combined) { |acc, r| record_residue(acc, r.summary, kind: r.kind) }, left_configs + right_configs]
          end

          # The finished property and the residues still riding on it.
          def left_of((prop, _configs))
            [prop.except(RESIDUE_KEY), residues_on(prop)]
          end

          # Remove conditional entries before emission. A type supplies both a claim and the context
          # in which other validators acquire their JSON keywords; when its claim disappears, those
          # validators must still describe every applicable wire type.
          def projected_property(config, full)
            ungated = ungated_validations(config)
            projected = if config.validations[:type] && !ungated.key?(:type)
                          type_agnostic_property(config, ungated)
                        elsif branch_projection_required?(config)
                          property_for_type_branches(config, ungated, declared_type_tokens(ungated))
                        else
                          build_property(config.with(validations: ungated), subfield: true)
                        end
            restore_blank_floor(projected, ungated, full)
          end

          # Re-emit against the complete JSON domain when the authored type supplies no unconditional
          # wire constraint. Keep type-dependent validator semantics in the normal property builder.

          def type_agnostic_property(config, validations)
            validations = validations.except(:type)
            return build_property(config.with(validations:), subfield: true) if Axn::Validation::Base.validator_entries(validations).empty?

            prop = property_for_type_branches(config, validations, WIRE_TYPE_CONTEXTS)
            Sizing::SIZE_CONSTRAINT_KEYS.each_key do |type|
              context = { type: }
              token = TypeTokens::TYPE_MAP.find { |_token, json_type| json_type == type }.first
              apply_size_constraints!(context, validations.merge(type: token))
              context.delete(:type)
              prop.merge!(context)
            end
            presence_rejects_blank?(validations) ? prop.merge(not: blank_refusal(nullable: nil_allowed?(config))) : prop
          end

          def branch_projection_required?(config)
            declared_type_tokens(config.validations).size > 1 &&
              NUMERIC_BOUND_ENTRIES.keys.any? { |key| config.validations[key] }
          end

          # A standalone numeric union may narrow to numbers. At a collision that can erase the
          # other declaration's only satisfiable branch. Emit branches independently instead,
          # preserving type options and keeping unexpressible bounds in the reporting path.
          def property_for_type_branches(config, validations, types)
            branches = types.map do |type|
              type = validations[:type].merge(klass: type) if validations[:type].is_a?(Hash)
              build_property(config.with(validations: validations.merge(type:)), subfield: true)
            end
            metadata = branches.first.slice(:description, :default)
            # A branch's per-type reports describe one assumed type; the projection's own are recomputed on the node
            # it lands in. Anything else a branch had to say belongs to the position, not to one branch of it.
            lifted = branches.flat_map { |branch| carried_residues(branch) }
            metadata = lifted.reduce(metadata) { |acc, r| record_residue(acc, r.summary, kind: r.kind) }
            metadata.merge(anyOf: branches.map { |branch| branch.except(:description, :default, RESIDUE_KEY) })
          end

          # Blankness is a value constraint, not just a container size. On the JSON domain every
          # non-string blank is in BLANK_WIRE_VALUES; strings retain Ruby's whitespace semantics,
          # which we report rather than replace with a different regular-expression dialect.
          def project_collision_checks(prop, configs)
            if configs.any? { |config| absence_bounds_blankness?(config.validations) }
              blank = { anyOf: [{ type: "string" }, { enum: BLANK_WIRE_VALUES }] }
              prop = prop.merge(allOf: Array(prop[:allOf]) + [blank])
            end
            report_unexpressed_checks(prop, configs)
          end

          # The config as though no gate were written anywhere in it — declaration-level or per entry — which is
          # the reading a residue renders and a projection compares its type against. `build_property` reflects a
          # gated check with its gate closed, so anything that must see what the open gate enforces builds from this.
          def gates_stripped(config)
            validations = config.validations.except(*Internal::FieldConfig::CONDITIONAL_GATE_KEYS)
                                .transform_values { |opt| ungated_options(opt) }
            config.with(validations:)
          end

          # A side's residues minus the conditional ones its own build recorded: the collision re-derives those
          # against the combined node (`gating_residues(gated, enforced:)`), which is the only place that knows
          # what the node already enforces on every call.
          def without_gating_residues(prop)
            kept = carried_residues(prop).reject { |r| r.kind == :conditional }
            kept.empty? ? prop.except(RESIDUE_KEY) : prop.merge(RESIDUE_KEY => kept)
          end

          # A projection keeps the `description` and pending residues of the property it replaces: those
          # describe the POSITION, and nothing about them is conditional.
          def carry_metadata(projected, original)
            projected = projected.merge(RESIDUE_KEY => residues_on(original)) if residues_on(original).any?
            description = original[:description]
            Axn::Internal::Identity.nil_value?(description) ? projected : projected.merge(description:)
          end

          # The one thing a projection can lose that is NOT conditional. `minLength`/`minItems`/`minProperties`
          # are derived from the TYPE, so when the gated entry is the `type:` itself, stripping it also strips
          # the JSON spelling of an UNGATED `presence:` — the node comes back admitting `""`/`[]`/`{}` on every
          # call, which the runtime rejects on every call. That is the emitter's own rule that a missing bound is
          # a missing EMISSION first, so the floor is restated as a value-level one, the only spelling left
          # once no type survives to hang a size keyword on.
          def restore_blank_floor(projected, ungated, original)
            return projected unless projected[:type].nil? && projected[:anyOf].nil?
            return projected if original[:type].nil? && original[:anyOf].nil?
            return projected unless presence_rejects_blank?(ungated)

            projected.merge(not: { enum: BLANK_WIRE_VALUES })
          end

          # "object", nullable or not, at the TOP of a property — the one shape merge_shape_member_property's
          # keyword union actually reads (`properties`/`required`/the size bounds). Anything else — a scalar
          # `type:`, a bare `anyOf`/`enum` with no top-level `type` — has no such surface, so conjoin_shape_
          # member_property falls back to allOf rather than guessing at a per-keyword meaning.
          def object_property?(prop)
            type = prop[:type]
            type == "object" || (type.is_a?(::Array) && type.include?("object"))
          end

          # Duped when only one side has them: `apply_nested_subfields!` mutates the map it is handed as it adds
          # children, and the member's own emission must not be written through. A name BOTH sides declare is
          # conjoined rather than let the second (`own_props`, the node's own child) win outright — PRO-3405;
          # `apply_structured_schema!`'s own `base_properties.merge(member_props)` is a different question (an
          # INFERRED property deferring to a DECLARED one), not two declarations colliding, and is unchanged.
          #
          # `member_configs`/`own_configs` — the routes each side's PARENT config came from — are re-resolved
          # PER COLLIDING KEY via `shape_members_at`, the same locator emission and the drop pass already share:
          # a name colliding one level down was declared by a DIFFERENT (nested) config than the one that
          # produced `member_props`/`own_props` themselves, so the parent's approximateness says nothing about
          # the child's (a real `type: String` and the `Object` fallback emit the byte-identical property, so
          # only the declaration distinguishes them).
          def merge_emitted_maps(member_props, own_props, member_configs: [], own_configs: [])
            return own_props if member_props.nil?
            return member_props.dup if own_props.nil?

            member_props.merge(own_props) do |key, member_prop, own_prop|
              conjoin_shape_member_property(
                member_prop, own_prop,
                member_configs: shape_members_at(member_configs, key),
                own_configs: shape_members_at(own_configs, key)
              )
            end
          end

          def merge_emitted_required(member_required, own_required)
            return own_required if member_required.nil?
            return member_required.dup if own_required.nil?

            member_required | own_required
          end
        end
      end
    end
  end
end
