# frozen_string_literal: true

require "axn/internal/reflection/schema/vocabulary"
require "axn/internal/cycle_guard"
require "axn/internal/shape_graph"

module Axn
  module Internal
    module Reflection
      module Schema
        # What is INSIDE a container: an Array's elements and a Hash's values and keys, from the classes an
        # `of:` axis names, plus the named members a `shape:` declares. One recursive descent, cycle-guarded
        # by the `ancestry` chain it threads (`guard_contents_descent`), since an inner contract can name a
        # container whose own contract names it back.
        module Contents
          include Vocabulary

          # The key-axis validators whose SUBJECT is the object rather than each key, so they never
          # reach a `propertyNames` node.
          OBJECT_SUBJECT_KEY_VALIDATORS = %i[length inclusion presence].freeze
          private_constant :OBJECT_SUBJECT_KEY_VALIDATORS

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
            constraints = bag_value_constraints(bag)
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
            nullable = bag_nullable?(bag)
            node = reconcile_contents_nullability(node, nullable:, for_output:)
            # A `klass:` JSON has no type for leaves the node untyped, and a presence check still rejects every
            # blank there — spelled as a value set, as a field's untyped floor is (`apply_type_info!`).
            if !for_output && untyped_node?(node) && !Axn::Internal::ShapeGraph.type_tokens(bag[:klass]).empty? &&
               presence_rejects_blank?(constraints)
              node = node.merge(not: { enum: BLANK_WIRE_VALUES })
            end
            # The bag's value validators (PRO-3193), through the same projector a named position uses. Applied
            # before the member/contents merges below so a `type:` those steps install cannot be read as the type
            # a keyword should key off — the node's type here is the bag's own `klass:`, which is what the
            # validators constrain.
            apply_value_constraints!(node, constraints, nullable:, for_output:, declared_klass: bag[:klass])
            node = with_bag_residues(node, bag, constraints) unless for_output
            node = contents_member_schema(node, bag, for_output:, ancestry:)
            inner = emitted_contents_edge(bag, :of)
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

          # Everything a bag position's node leaves out, named on that node — the same promise a field's property
          # keeps, through the same reporter (`report_unstated_checks`), read off a view of the bag as the config
          # it would be: its validators (gated ones included, for the per-type report), its tolerance, and its
          # `klass:` as the declared type. Then each self-gated entry the reporter did not already name, rendered
          # as written; a gated `of:`/`shape:` edge by name, since its value is a nested contract rather than a
          # constraint a reader can act on.
          def with_bag_residues(node, bag, closed_constraints)
            declared = bag_config_view(bag, bag_value_constraints(bag, closed: false))
            node = report_unstated_checks(node, bag_config_view(bag, closed_constraints), declared)
            Axn::Internal::ShapeGraph::INNER_CONTRACT_EDGES.each do |edge|
              entry = Axn::Internal::ShapeGraph.hash_or_nil(bag[edge])
              next if nil.equal?(entry) || !entry_self_gated?(entry)

              node = record_residue(node, "#{GATED_RESIDUE} (its `#{edge}:` contract)", kind: :conditional)
            end
            gated = declared.validations.select { |key, opt| !TOLERANCE_KEYS.include?(key) && entry_self_gated?(opt) }
            gated.sort_by { |key, _opt| key.to_s }.reduce(node) do |acc, (key, opt)|
              rendered = render_constraint({ key => reported_options(opt) })
              next acc if residues_on(acc).any? { |r| r.summary.include?(rendered) }

              record_residue(acc, "#{GATED_RESIDUE} (#{rendered})", kind: :conditional)
            end
          end

          # Untyped, or carrying only the null rejection nullability added — which the blank value set subsumes,
          # since `nil` is one of the blanks it names.
          def untyped_node?(node)
            return false if node.key?(:type) || node.key?(:anyOf) || node.key?(:enum)

            !node.key?(:not) || node[:not] == { type: "null" }
          end

          TOLERANCE_KEYS = %i[allow_nil allow_blank].freeze
          private_constant :TOLERANCE_KEYS

          # A bag read as the config it would be at a field — enough of one for the reporters, which ask only for
          # `validations` (and project it with `with`).
          BagConfigView = Struct.new(:validations) do
            def with(validations:) = self.class.new(validations)
          end
          private_constant :BagConfigView

          def bag_config_view(bag, constraints)
            tokens = Axn::Internal::ShapeGraph.type_tokens(bag[:klass])
            BagConfigView.new(tokens.empty? ? constraints : constraints.merge(type: { klass: bag[:klass] }))
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
            shape = emitted_contents_edge(bag, :shape)
            return node if nil.equal?(shape)
            return node unless shape_overlay_applies?(bag, for_output:)

            member_props, required = member_properties(shape[:members], for_output:, ancestry:)
            # The object type is written back with the position's nullability rather than a bare "object" that would
            # discard it, and the question is asked in TWO parts because neither alone is the answer.
            #
            # The node's own `null` branch is what `reconcile_contents_nullability` recorded a few lines up, and
            # preserving it is the whole point. But it is not sufficient: a bag naming no class at all
            # (`of: { shape: … }` — "these members, class unconstrained") starts from an untyped `{}` node, so a
            # declared tolerance had nowhere to be recorded and the overlay wrote a bare "object" over a position
            # the runtime stands down for. So an explicitly DECLARED tolerance counts on its own.
            #
            # `bag_nullable?` is deliberately NOT the question, though it looks like the tidier one. It reads the
            # bag's VALUE constraints and a classless bag has none, so it calls every classless shaped position
            # nullable — while the shape's own required members still reject a nil there. Measured: `expects :items,
            # type: Array do field :status, type: String end` rejects `[nil]` at runtime, and answering from
            # `bag_nullable?` emitted a document LOOSER than the contract, which is the one direction this layer
            # must never err in.
            # A nil reaches this position's members only if BOTH gates let it, so nullability is their CONJUNCTION.
            # Either alone advertises a null the runtime refuses:
            #
            #   * `bag_nullable?` is the POSITION's gate — the bag's own `klass:` and tolerance, i.e. whether
            #     `validate_position` stands its type check down. A tolerant shape entry cannot widen it:
            #     `of: { klass: Hash, shape: { …, allow_nil: true } }` still reports the `klass:` mismatch for a nil
            #     element, however willingly the shape skips itself. Asked of the BAG rather than read back off
            #     `node[:type]`, because a bag naming no class starts from an untyped node that has no branch to
            #     read — the reconciler had nowhere to record one.
            #   * the SHAPE entry's own gate is the second, because the shape is an entry like any other and
            #     ActiveModel lets it override the position per key: `of: { allow_nil: true, shape: { …,
            #     allow_nil: false } }` runs `ShapeValidator` on the nil and rejects it as unreadable.
            shape_tolerance = Axn::Validation::Base.effective_entry_options(shape, Axn::Validation::Base.tolerance_options(bag))
            nullable = bag_nullable?(bag) &&
                       !!(shape_tolerance[:allow_nil] || shape_tolerance[:allow_blank])
            merged = node.merge(type: type_with_nullability("object", nullable:),
                                properties: (node[:properties] || {}).merge(member_props))
            merged[:required] = required unless required.empty?
            merged
          end

          # One edge of a bag, reduced exactly as a field's entries are (`effective_validations`): an entry
          # carrying a per-validator gate of its own can be skipped on any given call, so what it constrains
          # cannot be promised in either direction and the schema must not describe it. A bag's `of:`/`shape:`
          # ARE the next level's ActiveModel entries — `OfValidator#inner_contract_validations` hands them over
          # verbatim — so a gate written on one gates it exactly as the same gate at a field does. Asked here
          # rather than only at the top level because a distributing `shape:` is canonicalized INTO a bag
          # (PRO-3166), so the gated node the field-level reduction used to drop now arrives one rung down.
          #
          # Inbound, the edge left out is named on the node (`with_bag_gating_residues`).
          def emitted_contents_edge(bag, key)
            edge = Axn::Internal::ShapeGraph.hash_or_nil(bag[key])
            return nil if !nil.equal?(edge) && entry_self_gated?(edge)

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
            # PRO-3441. Recorded alongside `additionalProperties`, not folded into it: this bag's OWN
            # `shaped_keys` (`_derive_shaped_keys!`, read from THIS declaration's `shape:` — never a
            # colliding declaration's) is the exempt set the runtime actually applies, and it can only be
            # known here, where the bag that produced it is still in hand. `finalize_residues!` conjoins
            # this into every OTHER named property once the tree is final — see `MAP_VALUE_EXEMPT_KEY`.
            #
            # `for_output:` gated (round 9, PR #285): `Schema.build_output` never calls
            # `finalize_residues!` at all — `exposes` has no subfield/`on:` mechanism to collide a second
            # declaration onto this key with (`_reject_duplicate_fields!` already refuses two `exposes`
            # naming the same field, the only other way a wire key could see two routes), so nothing on
            # the output side is ever left to conjoin this INTO. Attaching it unconditionally leaked a
            # private `__axn_map_value_exempt` key (a Hash carrying a Ruby `Set`) straight into
            # `output_schema` for ANY exposed map with a `values:` axis, collision or not — reproduced
            # directly: `exposes :counts, type: Hash, of: { values: Integer }` alone, no collision at all,
            # returned it in `output_schema` and corrupted `JSON.generate`'s rendering of the Set.
            unless node.empty? || for_output
              exempt = Set.new(Array(bag[:shaped_keys]))
              node = node.merge(MAP_VALUE_EXEMPT_KEY => [{ schema: values, exempt: }])
            end
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
            # from JSON at all — and then every inbound keyword here is a lie, not just the set: a `keys: {
            # klass: Symbol, format: … }` told a client to send `{"a" => 1}`, which the axis rejects on the
            # class check before the pattern is ever consulted. Gated on the CLASS rather than per keyword,
            # which is what fixing only the enum missed. On output the key has already been
            # serialized to a String, so the whole projection stands.
            return {} unless for_output || axis_admits_string_key?(axis[:klass])

            # The node is built with the type a JSON object key always has, so the projector keys each keyword off
            # `"string"` — which is what decides, on its own, that a `format:`/`length:` reflects here and a
            # numeric bound does not. The type is then dropped: `propertyNames` needs no `type: "string"` of its
            # own, and an axis that constrained nothing reduces to `{}` and emits no `propertyNames` at all.
            node = { type: "string" }
            closed = key_axis_constraints(axis, for_output:)
            apply_value_constraints!(node, closed, nullable: false, for_output:, property_names: true)
            admit_empty_wire_key!(node) if for_output && bag_nullable?(axis)
            node = with_bag_residues(node, axis, closed) unless for_output
            node.except(:type)
          end

          # A tolerated nil KEY has no null branch to travel in. Every other position expresses "and also nil" by
          # widening its `type:`, but a JSON object's property name is always a string, so a nil key that the axis
          # admits reaches the wire as `""` (`Values` renders it, measured: `{ nil => 1 }` serializes to
          # `{"": 1}`). Outbound the document must therefore admit the empty name, or it rejects a result the
          # action produced.
          #
          # OUTPUT only, and that asymmetry is the point: inbound, a JSON caller cannot send a nil key at all, and
          # the `""` it CAN send is a genuine blank string the axis's own `format:`/`length:` really do reject —
          # so widening there would advertise a key the runtime refuses.
          #
          # `pattern` and `minLength` are dropped rather than widened because JSON Schema cannot say "empty or
          # matching" in one keyword — only as an `anyOf` composition, which is the shape change PRO-3244 carries
          # for the whole blank-tolerance class. `maxLength` needs nothing: an empty name satisfies every emittable
          # ceiling. An `enum` is WIDENED instead of dropped, since naming one more member says exactly what is
          # true and loses nothing.
          EMPTY_WIRE_KEY_INCOMPATIBLE = %i[pattern minLength].freeze
          private_constant :EMPTY_WIRE_KEY_INCOMPATIBLE

          def admit_empty_wire_key!(node)
            EMPTY_WIRE_KEY_INCOMPATIBLE.each { |keyword| node.delete(keyword) }
            node[:enum] |= [""] if node[:enum].is_a?(Array)
            node
          end

          # The axis's validators, less any whose subject does not survive serialization. Only the OUTPUT side can
          # reach that mismatch: an inbound key is the wire string itself, and the reachability gate above has
          # already turned the whole projection away for an axis that could not be satisfied from JSON at all.
          def key_axis_constraints(axis, for_output:)
            constraints = bag_value_constraints(axis)
            return constraints unless for_output
            return constraints if own_wire_form?(axis[:klass])

            constraints.except(*OBJECT_SUBJECT_KEY_VALIDATORS)
          end

          # Whether the value at a bag's position may be nil — `Base.nil_accepted?`, the same seam a field's
          # `nil_allowed?` reads, asked of the bag's own `klass:` and validators. A bag that constrains nothing at
          # all admits nil, exactly as an empty validator set does at a field.
          def bag_nullable?(bag)
            validations = bag_value_constraints(bag)
            klass = bag[:klass]
            # Synthesized in the CANONICAL `type:` shape a field's stored validations carry. A bare token would be
            # normalized as a validator scalar and read under the wrong key entirely, so `type_admits_nil?` would
            # see no `klass:` and call a nil-admitting union nil-rejecting.
            validations = validations.merge(type: { klass: }) unless Axn::Internal::ShapeGraph.type_tokens(klass).empty?

            Axn::Validation::Base.nil_accepted?(nil_judgeable_validations(validations))
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
            # about them — and that plumbing is PRO-3244's, alongside the rest of the blank axis.
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
          def bag_value_constraints(bag, closed: true)
            constraints = Axn::Validation::Base.validator_entries(bag)
                                               .except(*Axn::Internal::ShapeGraph::POSITION_DESCRIPTION_KEYS,
                                                       *Axn::Internal::ShapeGraph::INNER_CONTRACT_EDGES)
            return constraints.merge(Axn::Validation::Base.true_tolerance_options(bag)) unless closed

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
            effective_validations(constraints)
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
              if !for_output && !optional_for_schema?(m) && requiredness_conditionally_relaxable?(m)
                props[key] = record_residue(props[key], GATED_REQUIRED_RESIDUE, kind: :conditional)
              end
              # A member whose presence obligation can be gated off — either wholesale by a declaration-level
              # gate, or because every nil-rejecting entry is nil-tolerant or covered by a per-validator (nested)
              # gate — can legitimately be omitted on a call whose gate is closed (outbound, the serializer emits
              # no key, or a nil/blank one, for it). requiredness_conditionally_relaxable? (superset of
              # conditionally_gated?) subsumes both cases, so requiredness is dropped in both directions along with
              # the gated constraints; inbound, the conditional requirement is named on the member above.
              required << key.to_s unless optional_for_schema?(m) || requiredness_conditionally_relaxable?(m)
            end
            [props, required]
          end
        end
      end
    end
  end
end
