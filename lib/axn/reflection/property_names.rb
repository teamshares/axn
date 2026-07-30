# frozen_string_literal: true

require "axn/internal/shape_graph"
require "axn/internal/cycle_guard"

module Axn
  module Reflection
    # The two rules a declared name must satisfy to be a JSON property: it must have a UTF-8 rendering, and it
    # must not collapse onto a property another declared name already renders as.
    #
    # These live with reflection because they are judged on what reflection EMITS — the walk reads the property
    # names out of a built schema rather than predicting them from the declarations. Six mechanisms contribute
    # names at a node (a top-level field, a subfield leaf at its resolved parent, a shape member at any depth,
    # a `model:`-generated `<field>_id`, a nested key a dotted `on:` introduces, and a structured type's own
    # members), and any check that predicted their combined output had to re-derive, per mechanism, both
    # "does this emit here" and "under what name" — a second copy of a rule that must agree with the emitter,
    # and every copy that drifted produced either a missed collapse or a rejected legal declaration.
    #
    # Internal, not an adapter surface (see AGENTS.md's namespace policy): `Core::Contract` is the only caller.
    # One rule deliberately does NOT live here — the renderability of an `exposes` field name, which reaches
    # the serialized body through `Values.serialize_exposed` regardless of what any schema emits, so it is not
    # projection-gated and stays eager in the contract.
    #
    # A module of functions rather than a class: every entry point is one-shot over a schema or a config list,
    # and the only state any of them carries (a path, a size budget) lives for the length of one call.
    module PropertyNames
      module_function

      # THE TRIGGER SET, and the guarantee: the rules run before any of the three public paths that expose a
      # JSON projection can return one — `input_schema`, `output_schema`, and
      # `Axn::Extensions::Serialization.render`. That set is exhaustive as audited: those are the only public
      # methods that build or emit property names (`Axn::Result` defines no `to_h`/`as_json`/`to_json`, and
      # `Schema.build_input`/`build_output` are reached only through them). Adding a fourth projection path
      # means adding it here, or the guarantee narrows silently.
      #
      # For a TOOL axn, "first demanded" is made to happen at app setup: `Axn.validate_tool_contracts!` projects
      # every registered tool once, driven under Rails by `config.after_initialize` and `config.to_prepare` (see
      # Axn::RailsIntegration::Engine), and called directly by a non-Rails app. That entry point documents
      # exactly how wide its coverage is — it depends on an adapter being registered and on the tool being
      # loaded — rather than implying it is total. Everything it does not reach falls back to first projection,
      # which is where every non-tool axn is validated anyway. It projects through `validate_inbound!`/
      # `validate_outbound!` rather than through the two readers, because those NAMES may not be axn's: see
      # validate_inbound!.
      #
      # Nothing but a projection can be harmed by a colliding or unrenderable name: for an axn that never
      # projects, two names that canonicalize alike stay two distinct fields with their own readers and
      # validations, and the contract works. So validating on demand is not a weaker promise for those
      # actions — it is the promise stated where it is true.
      #
      # `render` is a trigger even though it builds no schema — the alternative is that a render-only adapter
      # learns about a collision from the runtime `serialize_exposed` defense on a live call instead of at
      # setup, and that defense is a last line rather than a substitute for telling the author. It is the ONE
      # path whose verdict is memoized; see validate_outbound!.
      #
      # A projection that is BUILT is validated, every time — the verdict is not memoized here. The schema is
      # rebuilt on every call anyway (a caller may mutate the Hash it is handed, so it cannot be shared), and
      # validating what was just built is what makes the guarantee exact: a caller that retains the mutable
      # `shape:` Hash or members Array it declared with, and mutates it afterwards, changes what the schema
      # emits without changing any config array — so an identity-keyed verdict would be stale and the new
      # schema would come back unvalidated. Measured at ~16% of the input build and ~59% of the (much smaller)
      # output build, against a build that had to happen regardless.
      def validated_input(klass, &)
        validate_and_build(klass.internal_field_configs, klass.subfield_configs, direction: :input, &)
      end

      def validated_output(klass, &)
        validate_and_build(klass.external_field_configs, direction: :output, &)
      end

      # For APP SETUP, which must validate a class's inbound projection without going through its
      # `input_schema`: that name belongs to the class, and an adapter base that already defines it keeps it
      # (see Core::SchemaReflection) — so calling the class method runs the adapter's transport-shaped reader,
      # builds no axn projection, and validates nothing. Exactly the case that matters most, since a tool
      # subclassing its adapter's base class is the ordinary shape of one.
      #
      # Builds axn's projection here instead — the same build the reader performs, through the same one owner
      # (`Schema.build_input_for`) — and validates it. The schema is discarded: setup wants the verdict.
      # Deliberately NOT memoized, unlike the outbound verdict: nothing reads an inbound verdict later, and a
      # memo would only make a second setup pass skip a check that costs one build.
      def validate_inbound!(klass)
        validated_input(klass) { Schema.build_input_for(klass) }
        nil
      end

      # For `render`, which needs the outbound verdict but has no schema of its own to hand over, so it would
      # pay a whole `build_output` per call. That is the one place a memo earns its keep: rendering is a hot
      # path (measured ~2x per render without it), and the verdict is established once per class.
      #
      # The narrow consequence, stated rather than hidden: a caller that mutates a retained `shape:` graph after
      # the first render is not re-validated HERE. It still is by `output_schema`, which validates every build,
      # and the rendered body itself is still protected by the serializer's own runtime defenses (colliding
      # exposed field names, colliding Hash keys). What is lost is only the earliest warning.
      #
      # Keyed on the IDENTITY of the config arrays, exactly as `_resolved_subfields` keys its cache: those are
      # copy-on-write, so every declaration mints new ones and a grown contract misses with no invalidation hook
      # to keep in sync. A subclass holds its own ivars, so it never inherits a verdict. The verdict is recorded
      # only after validation passes, so a failure raises again on every render rather than being swallowed.
      def validate_outbound!(klass)
        configs = klass.external_field_configs
        # `equal?` on the CACHED value, so a nil cache is simply not equal rather than needing a guard.
        return nil if configs.equal?(klass.instance_variable_get(:@_axn_validated_outbound))

        validate_and_build(configs, direction: :output) { Schema.build_output(configs) }
        klass.instance_variable_set(:@_axn_validated_outbound, configs)
        nil
      end

      # Builds the projection through the caller's block and validates what it built.
      #
      # The block runs exactly once, and its result is what the caller returns — validating never builds a
      # second schema. The size cap runs BEFORE the build, because avoiding the build is the whole point of it:
      # a contract whose property count is exponential has no reflectable schema, and paying for one to discover
      # that would defeat the check.
      def validate_and_build(*config_arrays, direction:, &build)
        reject_oversized_schema!(config_arrays.flatten(1))
        schema = build.call
        reject_colliding_emitted_properties!(schema) do
          direction == :input ? inbound_property_sources(*config_arrays) : outbound_property_sources(*config_arrays)
        end
        schema
      end

      # The escaped SPELLING of a declared name, or nil when the name is neither a String nor a Symbol and
      # so has no spelling this layer can render without running the name's own code.
      #
      # `inspect` is what escapes a name whose bytes have no UTF-8 rendering — which is exactly what these
      # errors report, and interpolating those bytes into a UTF-8 message would raise
      # Encoding::CompatibilityError from the reporting itself. It is bound rather than dispatched for the
      # same reason the renderer binds `to_s`: a Symbol's `inspect` cannot be overridden, but a shape
      # member's name may be a caller-supplied String subclass whose can. The `case`/`when` type test
      # consults the real class, which a singleton `is_a?` cannot lie about, and both branches therefore
      # return a plain String this layer owns.
      SYMBOL_NAME_INSPECT = ::Symbol.instance_method(:inspect)
      STRING_NAME_INSPECT = ::String.instance_method(:inspect)
      private_constant :SYMBOL_NAME_INSPECT, :STRING_NAME_INSPECT

      def field_name_spelling(name)
        case name
        when ::Symbol then SYMBOL_NAME_INSPECT.bind_call(name)
        when ::String then STRING_NAME_INSPECT.bind_call(name)
        end
      end

      # How a declared name is written into a message. A String or Symbol is named by its escaped spelling;
      # anything else is named by its CLASS, derived without dispatching anything the name defines.
      #
      # A name that is neither is reachable only as a shape member's (the field path symbolizes every
      # declared name before any guard runs), and it gets here having rendered a property through its
      # `to_s` — so it is a real object whose `inspect` is real caller code. Dispatching that `inspect`
      # while building the very error the name caused lets the name replace that error with an exception
      # of its own, and one outside StandardError then escapes class definition entirely. That is the
      # same hazard the bound `inspect` above exists to avoid, and it has nothing to do with encoding:
      # a class name identifies the offender without running a line the offender wrote, exactly as
      # `Reflection::Values#describe_key_classes` names a colliding Hash key.
      def inspect_field_name(name)
        field_name_spelling(name) || "a name of class #{Axn::Internal::ClassName.of(name)}"
      end

      # How a name is written into a message that names ONE thing rather than distinguishing two spellings: the
      # UTF-8 property it canonicalizes to, falling back to the escaped form above when its bytes have no UTF-8
      # rendering at all.
      #
      # Every message axn builds is a UTF-8 String, and joining raw non-UTF-8 bytes to one raises
      # Encoding::CompatibilityError from the reporting itself — so a caller gets an encoding failure instead of
      # the failure being reported, or loses a log line entirely. Two ASCII-compatible encodings concatenate
      # fine, which is why this only bites once a message carries non-ASCII text from BOTH sides: a Latin-1
      # `:"caf\xE9"` beside a UTF-8 `:naïve`.
      #
      # The canonical property is byte-identical to the raw spelling for every ASCII name, so ordinary messages
      # are unchanged. Shared by every layer that names something in prose — a shape member in a validation
      # error, a stranded subfield path, a Hash key in a log line, a declared name in a declaration error —
      # because each deriving its own is how three copies of it appeared, and because the fallback has to be the
      # SAFE escape: an exotic name's own `inspect` is caller code that can raise while the message is built.
      def renderable_label(name) = Values.canonical_wire_key(name) || inspect_field_name(name)

      # A declared name becomes a JSON property name — in the reflected schema for an inbound field, in
      # serialized output for an outbound one — so it carries the same UTF-8 promise the serializer
      # enforces on a Hash key. Canonicalization belongs to the layer that renders the property, so the
      # check and the rendering it predicts cannot disagree.
      #
      # Runs before any collision comparison: two unrenderable names both canonicalize to nil, so a
      # collision check reached first would compare nil to nil and report a shared property for two names
      # that share none.
      def reject_unrenderable_field_names!(names, kind: "a field name")
        names.each do |name|
          next if Axn::Reflection::Values.canonical_wire_key(name)

          raise ArgumentError,
                "#{kind} becomes a JSON property name, and #{inspect_field_name(name)} holds bytes that have no " \
                "UTF-8 rendering — JSON is a UTF-8 format, so `JSON.generate` refuses such a property name outright. " \
                "Declare it under a UTF-8 name."
        end
      end

      # Two declared names that render as ONE JSON property collapse in the reflected schema, silently
      # dropping a value. The check reads the property names reflection ACTUALLY EMITS rather than predicting
      # them from the declarations.
      #
      # That direction is the whole design. Six different mechanisms contribute property names at a node — a
      # top-level field, a subfield leaf at its resolved parent, a shape member at any depth, a
      # `model:`-generated `<field>_id`, a nested key a dotted `on:` introduces, and the members of a
      # structured type declared alongside a shape — and a guard that PREDICTED their combined output had to
      # re-derive, for each of them, both "does this emit here" and "under what name". Every such derivation
      # is a second copy of a rule that must agree with the emitter, and each copy that drifted produced
      # either a collapse the guard missed or a legal declaration it rejected. Reading the emitted names
      # instead makes divergence impossible: there is no second copy to drift.
      #
      # It also makes the legal-merge rule structural rather than stated. Two names that are the SAME
      # property merge into one Hash key on their way into the schema — two routes to one wire slot, a shape
      # member beside a same-named subfield, a generated `<field>_id` beside an explicit one — so one key
      # means "merged, legal" and two keys that canonicalize alike mean "collapsed, rejected". Nothing has to
      # decide which case it is looking at.
      #
      # `Schema.build_input`/`build_output` are given the PROSPECTIVE configs, before any class mutation, the
      # same way `SubfieldContradictions.check!` is.
      def reject_colliding_emitted_properties!(schema, &sources)
        each_emitted_node(schema) do |path, property_names|
          claimed = {}
          property_names.each do |name|
            canonical = Axn::Reflection::Values.canonical_wire_key(name)
            # Rejected HERE, one name at a time, before any comparison: two unrenderable names both
            # canonicalize to nil, so comparing first would report them as one collapsed property — a wrong
            # verdict rather than a missing one.
            raise_unrenderable_emitted_name!(path, name, sources) if canonical.nil?
            first = claimed[canonical]
            raise_colliding_properties!(path, canonical, first, name, sources) if first

            claimed[canonical] = name
          end
        end
      end

      # Yields `[path, property_names]` for every node in a built schema that emits object properties. An
      # array's ELEMENT properties are a node of their own — a non-object parent's subfields are not emitted
      # there, so nothing else can name a property beside its elements — and carry a path segment no declared
      # name can produce.
      # Every way a built schema nests property names, enumerated from what `build_property` can produce:
      #
      #   - `properties`      — an object's own; the node itself
      #   - `items`           — an array element's, its own namespace (a non-object parent's subfields are not
      #                         emitted there, so nothing else can name a property beside its elements)
      #   - `anyOf`           — one branch per member of a multi-class `type:` or `of:`, each with its own
      #                         `properties` (`single_type_for` / `single_items_schema`)
      #   - `allOf`           — the conditional schemas `build_input` appends
      #
      # A branch is an ALTERNATIVE, not a sibling: the same name in two different `anyOf` branches describes
      # one property two ways and is not a collision, so each branch gets its own path segment. Recursion is
      # driven by these keys rather than by "has properties", which is what let a collision inside a branch go
      # unseen — the walk returned as soon as a hash had no top-level `properties`.
      def each_emitted_node(schema, path = [], &block)
        return unless schema.is_a?(Hash)

        properties = schema[:properties]
        if properties.is_a?(Hash)
          yield(path, properties.keys)
          properties.each { |name, subschema| each_emitted_node(subschema, [*path, name], &block) }
        end

        each_emitted_node(schema[:items], [*path, ITEMS_SEGMENT], &block)
        %i[anyOf allOf].each do |key|
          branches = schema[key]
          next unless branches.is_a?(Array)

          branches.each_with_index { |branch, index| each_emitted_node(branch, [*path, :"#{key}[#{index}]"], &block) }
        end
      end

      # An array's element node, in a path. A segment no declared name can produce, so it cannot be confused
      # with a property.
      ITEMS_SEGMENT = :[]
      private_constant :ITEMS_SEGMENT

      # Names both SOURCES, not just both spellings: with six mechanisms contributing property names, which
      # two declarations collided is not evident from the names alone.
      #
      # The emitted schema records only names, so provenance is recovered by looking for declarations that
      # could have produced each name at this node — and ONLY here, with a collision already proven, so the
      # success path never pays for it.
      def raise_colliding_properties!(path, canonical, first_name, second_name, sources)
        property = [*path.map { |segment| Axn::Reflection::Values.canonical_wire_key(segment) }, canonical].compact.join(".")
        resolved = attributions(sources)
        first = property_source(resolved, path, first_name)
        second = property_source(resolved, path, second_name)

        # Two members of one shape keep the wording that case has always had: it is by far the most common
        # collision, and its fix reads better in its own terms than as a resolved path.
        if [first, second].all? { |source| source&.kind == :member }
          raise Axn::DuplicateFieldError,
                "Duplicate shape member declared: #{inspect_field_name(first_name)} and " \
                "#{inspect_field_name(second_name)} both render as the JSON property #{canonical.inspect}, so " \
                "the reflected schema would emit it twice. Declare them under names that stay distinct once " \
                "converted to UTF-8."
        end

        raise Axn::DuplicateFieldError,
              "Duplicate field(s) declared: #{first&.description || inspect_field_name(first_name)} and " \
              "#{second&.description || inspect_field_name(second_name)} both resolve to the JSON property " \
              "#{property.inspect} — a declared name becomes a property name in the reflected schema and in " \
              "serialized output, so the two would collapse onto one. Declare them under names that stay " \
              "distinct once converted to UTF-8."
      end

      def property_source(sources, path, name) = sources.find { |source| source.path == [*path, name] }

      # Resolving provenance re-traverses the caller-owned shape graph — its `each`, its members' readers — to
      # ENRICH a message for a verdict that is already established. So it must not be able to replace that
      # verdict: a graph whose second walk raises (an Array subclass counting `each` calls, a reader that
      # answers once) would otherwise substitute its own exception for the collision, which is precisely the
      # escape these rules exist to prevent — and outside StandardError it escapes every rescue above.
      #
      # Attribution is therefore best-effort by construction: anything it raises is dropped and the message
      # degrades to naming the property and the spellings, which is the part derived from the emitted schema and
      # needs no caller code at all. `Exception` rather than StandardError because the hazard is exactly the
      # families that are not StandardError. The failure is always reported; only the enrichment is optional.
      def attributions(sources)
        sources.call
      rescue ::Exception # rubocop:disable Lint/RescueException
        []
      end

      # A declared name becomes a JSON property name, so one whose bytes have no UTF-8 rendering makes
      # `JSON.generate` refuse the schema. Judged on the EMITTED name for the same reason the collision rule
      # is: a name the schema never emits names no property, so rejecting it is an over-rejection — a dropped
      # subfield's leaf, a member under a scalar `of:`, a member of a type an outbound gate strips. Each of
      # those declared cleanly and reflected fine; only a separate precheck said otherwise.
      #
      # The offending name's SOURCE decides the wording, so each kind reads as it always has. Provenance is
      # resolved here only, with a failure already certain.
      def raise_unrenderable_emitted_name!(path, name, sources)
        kind = UNRENDERABLE_KINDS.fetch(property_source(attributions(sources), path, name)&.kind, "a field name")
        reject_unrenderable_field_names!([name], kind:)
      end

      UNRENDERABLE_KINDS = {
        config: "a field name",
        intermediate: "a nested key in `on:`",
        member: "a shape member name",
        type_member: "a member of a declared type",
        model_id: "a `model:` field's generated id",
      }.freeze
      private_constant :UNRENDERABLE_KINDS

      # One declaration that could have produced a property name at a node. Built only to attribute a
      # collision that has already been detected, so `description` is rendered eagerly — the list is walked
      # once, on the failure path, and is never consulted to decide anything.
      PropertySource = Data.define(:path, :kind, :description)
      private_constant :PropertySource

      def inbound_property_sources(field_configs, subfield_configs)
        tree = Axn::Reflection::SubfieldTree.build(field_configs, subfield_configs)

        (field_configs + subfield_configs).flat_map do |config|
          resolved = tree.index[config]
          next [] unless resolved

          property_sources_for(config, resolved.wire_path, model_id: true)
        end
      end

      def outbound_property_sources(field_configs)
        field_configs.flat_map { |config| property_sources_for(config, [config.field], model_id: false) }
      end

      def property_sources_for(config, wire_path, model_id:)
        sources = wire_path.each_index.map do |depth|
          leaf = depth == wire_path.size - 1
          description = leaf ? describe_config(config) : "#{inspect_field_name(wire_path[depth])}, a nested key introduced by #{describe_config(config)}"
          PropertySource.new(path: wire_path[0..depth], kind: leaf ? :config : :intermediate, description:)
        end

        if model_id && config.validations[:model]
          id_key = Internal::FieldConfig.model_id_key(config.field)
          sources << PropertySource.new(path: [*wire_path[0..-2], id_key], kind: :model_id,
                                        description: "the `model:`-generated #{inspect_field_name(id_key)} of #{describe_config(config)}")
        end

        # A shape's members land at the field's node, or at its array element's — the same question the
        # emission itself answers, asked once here for attribution rather than to decide anything.
        plan = Axn::Reflection::Schema.shape_property_plan(config, for_output: !model_id)
        node_path = plan.in_items? ? [*wire_path, ITEMS_SEGMENT] : wire_path
        plan.base_properties.each_key do |member|
          sources << PropertySource.new(path: [*node_path, member], kind: :type_member,
                                        description: "#{inspect_field_name(member)}, a member of the " \
                                                     "#{describe_type(shape_type_klass(config, plan))} type declared on #{describe_config(config)}")
        end
        sources.concat(shape_member_sources(Axn::Internal::ShapeGraph.nested_shape(config), node_path, config))
      end

      def shape_member_sources(shape, node_path, owner)
        Internal::ShapeGraph.members(shape).flat_map do |member|
          name = Internal::ShapeGraph.fetch(member, :field)
          next [] if Internal::ShapeGraph.missing?(name)

          path = [*node_path, name.to_sym]
          [PropertySource.new(path:, kind: :member, description: "shape member #{inspect_field_name(name)} of #{describe_config(owner)}"),
           *shape_member_sources(Axn::Internal::ShapeGraph.nested_shape(member), path, owner)]
        end
      end

      # The type whose members a structured-type property came from: the `of:` element type inside an array,
      # the field's own declared type otherwise.
      def shape_type_klass(config, plan)
        source = plan.in_items? ? config.validations[:of] : config.validations[:type]
        klass = source.is_a?(Hash) ? source[:klass] : source
        klass.is_a?(Class) ? klass : nil
      end

      # A declared type is named through a bound `Module#to_s`: a class can define its own, and one that
      # raises would replace the collision being reported (outside StandardError, escaping class definition).
      def describe_type(klass) = klass.nil? ? "declared" : Axn::Internal::ClassName.of_module(klass)

      def describe_config(config)
        route = config.on ? " (on: #{inspect_field_name(config.on)})" : ""
        "#{inspect_field_name(config.field)}#{route}"
      end

      # Reject a contract whose reflected schema would be exponentially large BEFORE building it, since
      # building it is the cost the cap exists to avoid.
      #
      # A nested shape object reused by SIBLING members multiplies out: every path through the graph is a
      # distinct property path, so N levels of two-way sharing name 2^N properties. Such a contract has no
      # usable schema either — `input_schema` walks the same paths, measured at 786k nodes and 2.7s for
      # eighteen levels — so it is rejected at declaration rather than left to declare and then hang the
      # first time anything reflects it. Counting is far cheaper than building: no property hashes, no
      # canonicalization, no descriptions.
      #
      # Generous enough that no hand-written contract approaches it: a thousand fields carrying twenty
      # members each is a fifth of the cap.
      MAX_EMITTED_PROPERTIES = 25_000
      private_constant :MAX_EMITTED_PROPERTIES

      # An allowance of emitted properties, spent as a graph is walked and exhausted the moment the walk goes
      # past it — so a graph that multiplies out costs the cap rather than its own size. Counting the whole
      # graph first would be the very expense being avoided.
      #
      # The label names whatever the walk is judging, and is carried as a block rather than a built string
      # because it is only ever needed on the failure path: every honest declaration would otherwise pay for
      # rendering a name nothing reads.
      class Budget
        def initialize(remaining, &label)
          @remaining = remaining
          @label = label
        end

        # `properties` is what the walk is about to admit — one for a single member, or, when a walk reaches a
        # shape it has already copied, the whole total that shape expands to (reuse is what makes a graph
        # multiply out, and the cap bounds what a schema would EMIT rather than how many objects are stored).
        def spend!(properties, &label)
          @remaining -= properties
          return unless @remaining.negative?

          raise ArgumentError, Budget.too_many_properties((label || @label).call)
        end

        def self.too_many_properties(label)
          "the shape on #{label} names more than #{MAX_EMITTED_PROPERTIES} JSON " \
            "properties — a nested shape object reused by sibling members multiplies out, so every path " \
            "through it is a separate property and the reflected schema grows exponentially " \
            "(`input_schema` would not finish either). Give each member its own nested shape, or flatten " \
            "the nesting."
        end
      end
      private_constant :Budget

      # The allowance the DECLARATION walk spends. Handed out rather than applied here, because bounding the
      # graph and copying it have to be one walk over the caller's members: the bound gates the copy — copying a
      # graph that multiplies out is the cost being avoided — and two walks let a members list answer them
      # differently, leaving the class holding members the bound never counted.
      def emitted_property_budget(&) = Budget.new(MAX_EMITTED_PROPERTIES, &)

      def reject_oversized_schema!(configs)
        budget = Budget.new(MAX_EMITTED_PROPERTIES)
        configs.each do |config|
          label = -> { describe_config(config) }
          budget.spend!(1, &label)
          count_shape_members!(budget, Axn::Internal::ShapeGraph.nested_shape(config), &label)
        end
      end

      # The same bound over the stored configs a schema build is about to walk, and the FIRST walk of any
      # projection — `validate_and_build` runs it ahead of every build, inbound and outbound — so bounding the
      # graph here is what keeps a projection bounded at all.
      #
      # Cycle-guarded, because a stored graph can be cyclic even though no declared one is. A member axn cannot
      # rebuild (anything that is not a `Data`) is stored as the caller's own object, so the nested shape it
      # carries is theirs to change after the class is declared — and pointing it back at itself made every
      # projection recurse to SystemStackError, which is outside StandardError and so escapes the rescue meant
      # to settle it. The size budget is no defense: depth costs one property per level, and the stack runs out
      # thousands of levels before 25,000 does.
      #
      # Ancestry-scoped (see CycleGuard), so a nested shape reused by SIBLING members is still counted twice —
      # that sharing is exactly what the budget exists to catch, and only genuine self-containment is a cycle.
      def count_shape_members!(budget, shape, seen = nil, via: nil, &label)
        hash = Internal::ShapeGraph.hash_or_nil(shape)
        return if nil.equal?(hash)

        outcome = Axn::Internal::CycleGuard.guard(hash, seen, on_cycle: CYCLIC_SHAPE) do |nested|
          Internal::ShapeGraph.members(hash).each do |member|
            budget.spend!(1, &label)

            count_shape_members!(budget, Axn::Internal::ShapeGraph.nested_shape(member), nested, via: member, &label)
          end
        end
        raise_cyclic_shape!(via) if CYCLIC_SHAPE.equal?(outcome)
      end

      # A private object of this module's own, and always the RECEIVER of `equal?`, so nothing a declaration can
      # produce is mistaken for it.
      CYCLIC_SHAPE = ::Object.new.freeze
      private_constant :CYCLIC_SHAPE

      # Reads as the declaration-time cycle error does (Core::Contract#_raise_cyclic_shape!), because it is the
      # same defect — found later only because the graph became cyclic after the class was declared. The member
      # is named by CLASS, not by its `field`: reading a name here would run the caller's code while the failure
      # is being reported, and the class is the identifying thing anyway, since only a member axn could not
      # rebuild can reach this state.
      def raise_cyclic_shape!(member)
        via = nil.equal?(member) ? "" : " reached from the shape member of class #{Axn::Internal::ClassName.of(member)}"
        raise ArgumentError,
              "a `shape:` graph#{via} contains itself, so building the reflected schema would recurse until the " \
              "stack overflows. A member axn cannot rebuild — anything that is not a `Data` — is stored as your " \
              "own object, so the nested shape it carries can become self-referential after the class is " \
              "declared. Give the nested shape its own members rather than the shape (or the member) that " \
              "encloses it."
      end

      # Six entry points, and everything else internal. Mirrors Reflection::Values' own narrowing: the walk,
      # the message builders, and the provenance resolution are implementation of the two rules, not surface a
      # caller should reach. `field_name_spelling` is deliberately not public either — `inspect_field_name` is
      # the one way a name gets written into a message.
      private_class_method :validate_and_build, :attributions, :inbound_property_sources, :outbound_property_sources,
                           :reject_colliding_emitted_properties!, :reject_oversized_schema!,
                           :field_name_spelling, :each_emitted_node, :raise_colliding_properties!,
                           :property_source, :raise_unrenderable_emitted_name!, :property_sources_for,
                           :shape_member_sources, :shape_type_klass, :describe_type, :describe_config,
                           :count_shape_members!, :raise_cyclic_shape!
    end
  end
end
