# frozen_string_literal: true

require "axn/internal/shape_graph"
require "axn/internal/cycle_guard"
# Declared rather than left to the top-level entrypoint's require order: both rules are DERIVED from a built
# schema and reported through the canonicalization, so an adapter loading this file (or
# `axn/extensions/serialization`) standalone would otherwise NameError on its first call instead of at
# require time.
require "axn/reflection/schema"
require "axn/reflection/values"

module Axn
  module Reflection
    # The three rules a declared name must satisfy to be a JSON property: it must render through Ruby's own `to_s`
    # (so the property it names is one fact rather than one answer per reader), that rendering must have a UTF-8
    # form, and it must not collapse onto a property another declared name already renders as. They are judged in
    # that order, each being the next one's premise.
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
      #
      # `resolved:` is the class's own cached subfield resolution — the artifact `Schema.build_input_for` nests
      # properties from — so the size cap reads the emitter's tree rather than building a second one.
      def validated_input(klass, &)
        validate_and_build(klass.internal_field_configs, klass.subfield_configs,
                           direction: :input, resolved: klass._resolved_subfields, &)
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
      def validate_and_build(field_configs, subfield_configs = [], direction:, resolved: nil, &build)
        reject_oversized_schema!(field_configs, subfield_configs, for_output: direction == :output, resolved:)
        schema = build.call
        reject_colliding_emitted_properties!(schema) do
          direction == :input ? inbound_property_sources(field_configs, subfield_configs) : outbound_property_sources(field_configs)
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

      # Whether two declared names are the SAME name — the raw-spelling half of field identity, decided
      # without dispatching anything either name defines.
      #
      # Identity answers it for a Symbol, and is all identity can honestly say about an exotic object. Two
      # Strings are compared through a BOUND `String#==`, because equal-but-not-identical is the ordinary
      # case rather than an exotic one: a Hash keyed by a plain String stores a frozen COPY of the key, so an
      # emitted property name is never the same object as the declared name it came from.
      #
      # Shared rather than re-derived per layer (like `renderable_label`), because both places that ask are
      # places a wrong answer is dangerous in the same specific way. A name's own `==`/`eql?` is caller code,
      # and both callers ask AFTER a collision is established — attribution enriching the report, and the
      # contract choosing between the two duplicate wordings — so a name that raises when asked replaces the
      # verdict with its own exception, which outside StandardError escapes every rescue above. This is the
      # comparison AGENTS.md's error-path rule requires and `Array#==`/`Object#==` cannot give.
      STRING_NAME_EQ = ::String.instance_method(:==)
      private_constant :STRING_NAME_EQ

      def same_declared_name?(first, second)
        return true if first.equal?(second)

        case first
        when ::String
          case second
          when ::String then STRING_NAME_EQ.bind_call(first, second)
          else false
          end
        else false
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

          raise ArgumentError, unrenderable_name_message(name, kind)
        end
      end

      # One text for both routes to this failure — the eager check above, and the emitted-name walk, which
      # raises through this builder rather than by re-entering the check. The verdict there is already
      # established, and canonicalizing a second time to re-confirm it is a second dispatch of the name's own
      # `to_s` on the failure path: it can raise INSTEAD of the report, and a `to_s` that answers differently
      # the second time made the check return without raising at all, leaving the unrenderable name to be
      # claimed under a nil canonical key — the wrong verdict the walk's ordering exists to prevent.
      def unrenderable_name_message(name, kind)
        "#{kind} becomes a JSON property name, and #{inspect_field_name(name)} holds bytes that have no " \
          "UTF-8 rendering — JSON is a UTF-8 format, so `JSON.generate` refuses such a property name outright. " \
          "Declare it under a UTF-8 name."
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
      #
      # Every emitted name is canonicalized ONCE for the whole walk. A name is a node's own key at one node and an
      # ancestor SEGMENT at every node below it, and the collision message renders the whole path, so a segment
      # derived twice is a name read twice. The memo is identity-compared, so nothing is asked to hash or compare
      # itself either, and a node is always walked before its children, so every ancestor segment is already in it.
      # What the memo COSTS is one read per name; what it no longer has to defend against is a name answering a
      # second read differently, because a name whose rendering is its own code is refused above before anything
      # canonicalizes it — every name that reaches the canonicalization renders through Ruby's own `to_s`, which
      # answers the same every time it is asked.
      def reject_colliding_emitted_properties!(schema, &sources)
        canonicals = {}.compare_by_identity
        each_emitted_node(schema) do |path, property_names|
          claimed = {}
          property_names.each do |name|
            # Ahead of the canonicalization rather than after it: this refuses a name axn would have to RUN to read
            # at all, so no name's own code decides a property, and the canonicalization below is left with names
            # whose rendering is Ruby's.
            raise_foreign_rendering_name!(path, name, sources) unless Axn::Internal::NativeMethods.native_name_rendering?(name)
            canonical = canonicals[name] = Axn::Reflection::Values.canonical_wire_key(name)
            # Rejected HERE, one name at a time, before any comparison: two unrenderable names both
            # canonicalize to nil, so comparing first would report them as one collapsed property — a wrong
            # verdict rather than a missing one.
            raise_unrenderable_emitted_name!(path, name, sources) if canonical.nil?
            first = claimed[canonical]
            raise_colliding_properties!(path, canonical, first, name, sources, canonicals) if first

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
      def raise_colliding_properties!(path, canonical, first_name, second_name, sources, canonicals)
        # Read from the memo, not re-derived (see reject_colliding_emitted_properties!). The `fetch` default is for
        # the walk's OWN namespace segments — an array's `[]`, an `anyOf[0]` branch — which are Symbols this module
        # names and no name of a caller's, so canonicalizing one runs nothing.
        segments = path.map { |segment| canonicals.fetch(segment) { Axn::Reflection::Values.canonical_wire_key(segment) } }
        property = [*segments, canonical].compact.join(".")
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

      # The declaration that named `name` at `path`, matched on the emitted PATH rather than on the name alone
      # (the same name at two nodes is two properties).
      #
      # Compared segment by segment through `same_declared_name?`, never with `Array#==`, which dispatches each
      # element's own `==`. The elements ARE caller-supplied names, this runs with a failure already certain,
      # and the guard below does not cover it — the attribution walk has returned by the time the lookup runs —
      # so a raising `==` here replaced the collision report with its own exception. Being dispatch-free is what
      # makes the lookup safe outside the guard; it is not merely guarded elsewhere.
      def property_source(sources, path, name)
        wanted = [*path, name]
        sources.find { |source| same_property_path?(source.path, wanted) }
      end

      # Both Arrays are this module's own, so `size`/`each_index` are Ruby's; only the SEGMENTS are the caller's.
      def same_property_path?(first, second)
        first.size == second.size && first.each_index.all? { |depth| same_declared_name?(first[depth], second[depth]) }
      end

      # Resolving provenance re-traverses the shape graph the class holds to ENRICH a message for a verdict that is
      # already established. For a DECLARED contract that graph is axn's own snapshot, so nothing of the caller's
      # runs here at all; for one assigned onto a class directly it is still whatever its author built. Either way
      # this must not be able to replace the verdict — a walk that raises would otherwise substitute its own
      # exception for the collision, which is precisely the escape these rules exist to prevent, and outside
      # StandardError it escapes every rescue above.
      #
      # The WALK is therefore best-effort by construction: anything it raises is dropped and the message degrades
      # to naming the property and the spellings, which is the part derived from the emitted schema and needs no
      # caller code at all. `Exception` rather than StandardError because the hazard is exactly the families that
      # are not StandardError. The failure is always reported; only the enrichment is optional.
      #
      # The guard covers the walk and nothing after it, which is the whole reason everything the failure path
      # then does with the walk's RESULT — the path lookup, the wording choice, each name written into the
      # message — dispatches nothing a name defines. A guard around one step is not a property of the path.
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
        kind = PROPERTY_NAME_KINDS.fetch(property_source(attributions(sources), path, name)&.kind, "a field name")
        raise ArgumentError, unrenderable_name_message(name, kind)
      end

      # A name that decides its own rendering names no ONE property, so there is nothing for the other rules to
      # judge. Three readers read a property name — these rules canonicalize it, the emitter writes it into
      # `required` through its `to_s`, and `JSON.generate` renders a Hash key through that same `to_s` — and they
      # agree only where the rendering is Ruby's own (see `NativeMethods.native_name_rendering?`). A String
      # subclass rendering `"dup"` over the bytes `"other"` passed these rules beside a `:dup` field and then
      # emitted the property `"dup"` twice; a plain String carrying a singleton `to_s` emitted a `required` entry
      # for a property its `properties` does not define, needing no second declaration at all.
      #
      # Refused rather than reconciled, and rejecting the OTHER of the two candidate names would only trade one
      # silent collapse for the one it replaced: a name whose bytes have no UTF-8 rendering but whose `to_s`
      # renders fine would then ship a property that is neither. Judged on the emitted name, like every rule here,
      # and reachable only through a config ASSIGNED onto a class — the DSL symbolizes every declared name, and a
      # shape member is stored as the Symbol the declaration walk judged.
      def raise_foreign_rendering_name!(path, name, sources)
        kind = PROPERTY_NAME_KINDS.fetch(property_source(attributions(sources), path, name)&.kind, "a field name")
        raise ArgumentError, foreign_rendering_name_message(name, kind)
      end

      # Named without rendering the name — `inspect_field_name` escapes a String's bytes through a bound `inspect`
      # and names anything else by its class — for the reason the whole rule exists: the offender is the name's own
      # rendering, so asking for it here would let the name answer the report instead of the report being made.
      def foreign_rendering_name_message(name, kind)
        "#{kind} becomes a JSON property name, and #{inspect_field_name(name)} does not render through Ruby's own " \
          "`to_s` — so the property this name means is not one fact: it is judged by a String's own bytes, while " \
          "the reflected schema's `required` list and `JSON.generate` each read it from the name's `to_s`. Two " \
          "declarations can then land on one JSON property, or one declaration on two, with nothing to signal it. " \
          "Declare it under a Symbol, or under a String that has not redefined `to_s`."
      end

      PROPERTY_NAME_KINDS = {
        config: "a field name",
        intermediate: "a nested key in `on:`",
        member: "a shape member name",
        type_member: "a member of a declared type",
        model_id: "a `model:` field's generated id",
      }.freeze
      private_constant :PROPERTY_NAME_KINDS

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
        # Every namespace of the type schema, so a source's path is where the property is actually EMITTED —
        # a multi-class `of:` puts each element type's members in its own `anyOf` branch, one path segment
        # below the node (see each_type_namespace).
        origin = describe_type(shape_type_klass(config, plan))
        each_type_namespace(plan) do |type_path, members|
          members.each do |member|
            sources << PropertySource.new(path: [*node_path, *type_path, member], kind: :type_member,
                                          description: "#{inspect_field_name(member)}, a member of #{origin} declared on #{describe_config(config)}")
          end
        end
        # The shape the PLAN carries, not a second read of the config: attribution then lists exactly the members
        # the emitter would have emitted here, so an outbound gate that drops a `shape:` leaves no source claiming
        # a member the schema names nowhere.
        sources.concat(shape_member_sources(plan.shape, node_path, config))
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

      # Every namespace of property names a declared TYPE contributes, as `[path_below_the_node, names]`.
      #
      # Walked with `each_emitted_node` — the same enumeration that reads a BUILT schema for collisions — over
      # the type schema `shape_property_plan` carries, which is the very Hash `apply_structured_schema!` emits.
      # So both consumers of this (the projection size cap, and collision attribution) see every property name
      # anywhere the emitter puts one, including a nesting no rule here knows about yet. Asking the node's own
      # `properties` instead missed a whole class of them: a multi-class `of:` emits one `anyOf` BRANCH per
      # element type, each carrying its own properties, so 26 branches of 1,000 members charged nothing and a
      # schema of 26,000 properties declared and projected past a 25,000 cap.
      #
      # Branches are sibling NAMESPACES, which is why they are enumerated separately rather than flattened: two
      # branches may legally name the same member (`of: [A, B]` where both define `:id`), and each gets its own
      # path segment so it counts toward SIZE without reading as a collision.
      def each_type_namespace(plan, &)
        each_emitted_node(plan.type_schema, &)
      end

      # The type whose members a structured-type property came from: the `of:` element type inside an array,
      # the field's own declared type otherwise. Nil for a UNION (`of: [A, B]`), where the property lives in
      # one `anyOf` branch and pinning which class contributed it would mean mapping a branch index back to a
      # declaration — a derivation of the emitter's own ordering, for prose, on a path that only runs once a
      # failure is certain. The message names the union collectively there instead. A nil answer means exactly
      # that case: every other way of reaching nil contributes no type properties for a source to describe.
      def shape_type_klass(config, plan)
        source = plan.in_items? ? config.validations[:of] : config.validations[:type]
        klass = source.is_a?(Hash) ? source[:klass] : source
        klass.is_a?(Class) ? klass : nil
      end

      # A declared type is named through a bound `Module#to_s`: a class can define its own, and one that
      # raises would replace the collision being reported (outside StandardError, escaping class definition).
      def describe_type(klass) = klass.nil? ? "one of the element types" : "the #{Axn::Internal::ClassName.of_module(klass)} type"

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
      # Spent per emitted property PATH, never per declaration, which is what makes the count the schema's
      # rather than the contract's: several declarations legally name ONE property — two routes to one wire
      # path, a shape member beside a same-named subfield, a `model:`-generated `<field>_id` beside an explicit
      # one, a `Data` type's member beside a shape member overriding it — and the emitter merges each such pair
      # into a single Hash key. Charging the declarations instead rejected a contract of legal merges at
      # two-thirds of the cap.
      #
      # The paths are held in a TRIE of identity-compared Hashes rather than as whole paths in a Set: a segment
      # may be any object a shape member is named with, and an identity-compared Hash never asks it to hash or
      # compare itself (see `property_segment`). The trie is also what makes charging a wire path exact in one
      # walk — each prefix is a node, and a node charged once is a property emitted once.
      #
      # The label names whatever the walk is judging, and is carried as a block rather than a built string
      # because it is only ever needed on the failure path: every honest declaration would otherwise pay for
      # rendering a name nothing reads.
      class Budget
        def initialize(remaining, &label)
          @remaining = remaining
          @label = label
          @claimed = {}.compare_by_identity
        end

        # A wire path from the root, EVERY segment of which names a property: the top-level field, plus each
        # intermediate key a dotted `on:` introduces. Those intermediates are shared nodes, so charging them by
        # path is what counts each of them once however many configs pass through it.
        #
        # Returns the trie node for the path's own property — the CURSOR a walk descending from there carries, so
        # a shape's members are charged with one lookup each rather than by rebuilding a path per member.
        def charge_nested_path!(path, &label)
          node = @claimed
          path.each { |segment| node = claim!(node, segment, label) }
          node
        end

        # One property named directly under `node`, returning ITS node so the walk can descend again.
        def charge_child!(node, segment, &label) = claim!(node, segment, label)

        # A NAMESPACE under `node` — an array's `items`, one `anyOf` branch of a multi-class type. It carries a
        # path segment (so nothing beneath it is confused with a property beside it) but names no property, so it
        # is descended into without being charged.
        def namespace(node, segment) = descend(node, segment)

        # One property under `node` reached through namespaces of the emitter's own (`each_emitted_node`'s path
        # into a type schema): every segment but the last is such a namespace.
        def charge_under!(node, path, &label)
          last = path.size - 1
          path.each_with_index { |segment, index| node = index == last ? claim!(node, segment, label) : descend(node, segment) }
          nil
        end

        def self.too_many_properties(label)
          "the contract at #{label} names more than #{MAX_EMITTED_PROPERTIES} JSON " \
            "properties — most often a nested shape object reused by sibling members multiplies out, so every " \
            "path through it is a separate property and the reflected schema grows exponentially " \
            "(`input_schema` would not finish either). Give each member its own nested shape, flatten the " \
            "nesting, or declare fewer properties."
        end

        private

        def descend(node, segment) = (node[segment] ||= {}.compare_by_identity)

        # Charges a node the first time it is claimed and never again — a second claim on one path is the merge
        # the emitter performs, so it must cost nothing.
        def claim!(node, segment, label)
          child = descend(node, segment)
          return child if child[CLAIMED]

          child[CLAIMED] = true
          spend!(label)
          child
        end

        def spend!(label)
          @remaining -= 1
          return unless @remaining.negative?

          raise ArgumentError, Budget.too_many_properties((label || @label).call)
        end

        # "This node has been charged", as a key of the node's own children Hash. A private object of this
        # class, in an identity-compared Hash, so nothing a declaration can name is mistaken for it.
        CLAIMED = ::Object.new.freeze
        private_constant :CLAIMED
      end
      private_constant :Budget

      # THE THREE CHARGE SITES, all spending on the PATH a property is emitted at (see Budget), and which way
      # each can be wrong — stated, because an over-count rejects a legal declaration while an under-count only
      # loosens the bound, and a charge that cannot say which it does is a predictor. Nothing here is charged for
      # a config the emitter represents nowhere, and no SHAPE is charged for a config the emitter builds no
      # property from (`emitted_configs` answers both).
      #
      # 1. One per emitted wire path, below — charged as a CHAIN, so the path's own property and every implicit
      #    intermediate key a dotted `on:` introduces are each charged exactly once, at the node the emitter
      #    emits them at. It is EXACT, in both directions. It cannot over-count: a path is charged only where
      #    `emitted_configs` has established the emitter emits a property, and a second declaration reaching a
      #    path already charged is the MERGE the emitter performs (two routes to one wire path; a
      #    `model:`-generated `<field>_id` beside an explicitly declared one, which is why a `model:` route is
      #    charged at the id key it actually emits). Nor is anything left for it to under-count: the one place the
      #    schema writes a property name twice is the reference a conditional-requiredness `allOf` clause repeats,
      #    and that clause constrains a top-level property this charge has already paid for — counting it again
      #    would be counting one property twice.
      # 2. Every property name a declared TYPE contributes (`each_type_namespace`), read out of `plan.type_schema`
      #    — the very Hash `apply_structured_schema!` assigns — so it is exact GIVEN the plan, including a
      #    multi-class `of:` whose element types each land in their own `anyOf` branch. "Given the plan" is the
      #    whole of the claim, and it is not vacuous only because the plan's input is now the emitter's own: a
      #    plan is derived from `Schema.effective_validations`, applied inside `shape_property_plan` itself, so
      #    this charge cannot be handed a config `build_property` would have reduced first. That is what was
      #    false when the claim said "exact by construction" with the reduction living in `build_property` alone:
      #    an OUTBOUND `type: { klass: SomeData, if: :flag }` is dropped before the emitter names one member of
      #    it, and 25,000 members were charged against a schema that names none. A type that emits nothing (a
      #    scalar `of:`, a wholly gated outbound config, a per-validator-gated outbound `type:`/`of:`, an input
      #    `model:` route) carries no properties to charge.
      # 3. One per shape MEMBER, recursively, over `plan.shape` and gated on `plan.emitted` — the same shape
      #    `apply_structured_schema!` emits members from, so this walk and that emission cannot see different
      #    members (an outbound gate on the `shape:` entry itself drops both). Exact given the plan for the same
      #    reason as site 2, plus: a member the emitter names no property for is skipped by the same rule
      #    (`Schema.member_name`, nil for a member answering to no `field` — which only a config ASSIGNED onto a
      #    class can carry, since the declaration walk rejects one). Sites 2 and 3 land at the same node, so a
      #    `Data` type's member and a shape member overriding it are one property and one charge, exactly as
      #    `base_properties.merge(member_props)` emits one.
      #
      # The single residue in the OVER-counting direction, and it is not reachable by declaring anything: a shape
      # member named with an object that is neither String nor Symbol is charged by that object's IDENTITY, since
      # normalizing it to the emitter's key would mean dispatching its own `to_sym` while counting. Two such
      # names that convert alike therefore charge twice for one property. `Contract.validate_shape_member_name!`
      # rejects such a name at declaration, so only a config assigned onto a class can hold one.
      #
      # Separately, `ShapeGraph::MAX_MEMBER_PATHS` charges the STORED graph at declaration — every member path,
      # emitted or not. That one deliberately does not derive from the emitter: it bounds the cost of WALKING a
      # graph axn holds (runtime shape validation, redaction), which happens whether or not a property is emitted.
      def reject_oversized_schema!(field_configs, subfield_configs, for_output:, resolved: nil)
        budget = Budget.new(MAX_EMITTED_PROPERTIES)
        emitted_configs(field_configs, subfield_configs, for_output:, resolved:).each do |config, wire_path, shapes_a_property|
          label = -> { describe_config(config) }
          node = budget.charge_nested_path!(wire_path, &label)
          count_emitted_properties!(budget, config, node, for_output:, &label) if shapes_a_property
        end
      end

      # The Symbol the emitter keys a property by, derived without dispatching anything the NAME defines: a String
      # is interned through String's own `to_sym`, and everything else stands for itself — a Symbol IS the key,
      # and anything else is distinguished by identity (see the over-counting residue above).
      # `member_properties` keys by `name.to_sym`, so this agrees with it for every name a declaration can carry,
      # without adding a dispatch to a walk that only needs to count.
      #
      # This is the MEMBER/type-property key, where `member_properties` interns (`name.to_sym`) and so must this.
      # `wire_key_segment` below is the top-level analog, where the emitter does not intern.
      STRING_TO_SYM = ::String.instance_method(:to_sym)
      private_constant :STRING_TO_SYM

      def property_segment(name)
        case name
        when ::String then STRING_TO_SYM.bind_call(name)
        else name
        end
      end

      # The same idea for a top-level WIRE KEY, where the emitter's key is the declared name itself
      # (`properties[config.field] =`) rather than a Symbol: a String is copied into a plain String of the same
      # bytes and encoding, so String's own `hash`/`eql?` decide the merge and a SUBCLASS's cannot, and anything
      # else stands for itself. That makes it exactly the emitter's answer — `"a"` and `:a` stay two keys here as
      # they are two properties there — with no interning, so a name whose bytes are no valid Symbol still
      # reaches the rule that reports it rather than dying of `EncodingError` inside the size guard.
      def wire_key_segment(name)
        case name
        when ::String then ::String.new(name)
        else name
        end
      end

      # The configs the projection emits properties FOR, each with the PATH its property is emitted at and
      # whether the projection builds that property from this config (and so emits its `shape:`/type members) —
      # all three asked of the emitter's own artifacts rather than predicted from the declarations, because a
      # config the schema names nowhere must cost nothing: charging it rejects a contract over a schema it does
      # not have. Charging one was the seventh defect on this branch with that single root, and the last charge
      # still predicting instead of deriving.
      #
      # The PATH is what the budget spends on, so it has to be the emitter's key rather than the declaration's
      # name: a `model:` route emits `<leaf>_id` in place of the field (`model_id_property`, and the nested
      # analog in `apply_children!`, both keyed off the leaf wire segment), so charging the field's own path
      # would charge a property the schema never names and miss the merge with an explicitly declared
      # `<field>_id`.
      #
      # Outbound, every declared field is emitted at its own name — but `build_output` writes
      # `properties[config.field]` per config, so where two configs share a wire key the LAST write is the
      # property and the earlier config's shape is emitted nowhere (reachable only by assigning configs onto a
      # class; a declared duplicate is rejected outright). Same rule as the inbound top-level one below, for the
      # same reason.
      #
      # Inbound, emission depends on the config's POSITION, and `SubfieldTree` is what decides it. A config rooted
      # at `on: :ambient_context` is never attached to a tree at all, so `index` has no entry for it and the
      # projection is an empty object however many are declared (each was charged one property, plus every member
      # of its shape). A config whose ancestor chain passes through a parent that cannot hold JSON object
      # properties — a `model:` route, a non-object or mixed-union type, an implicit key already claimed by a
      # non-object shape member — is omitted at that ancestor, along with its whole subtree. And a field
      # `build_input` skips outright (`EXCLUDED_FROM_INPUT_SCHEMA`) emits nothing at all; only a config assigned
      # onto a class can carry such a name, since `ambient_context` is a reserved field name.
      #
      # `path_blocked?` is the predicate that decides the second one: the same call `compute_dropped` makes, so
      # the charge and the drop cannot disagree. It is asked at EVERY depth, because the emitter blocks at every
      # depth (`apply_nested_subfields!` returns at the blocking node) while `dropped` deliberately records only
      # the deep configs it reports to the author, a depth-1 subfield under such a parent being silently omitted.
      #
      # WHICH config shapes the property is a separate question, because one wire path can be declared by two
      # routes and the emitter builds from ONE of them. At a subfield node that is `Schema.property_representative`
      # — the very config `apply_children!` emits from. At top level it is the last config declared with that wire
      # key, because `build_input` writes `properties[config.field]` per config and a later write wins; that too is
      # reachable only by assigning configs onto a class (a declared duplicate is rejected outright), and if it
      # ever drifts it UNDER-counts, which only loosens the bound.
      #
      # That "same wire key" question is asked through `wire_key_segment`, so deciding it dispatches nothing a
      # NAME defines. Keying the owner map by the raw name instead meant `Hash#[]=` asking the name its own
      # `hash`/`eql?` to decide merge-versus-two-properties, which is a caller's answer to axn's question about
      # axn's own artifact: a String SUBCLASS can define either, and one that raised took the projection down
      # from inside the size guard. The substitute is byte-for-byte the emitter's own key rule, decided by
      # String's methods rather than the name's, so it does not trade the dispatch for an approximation.
      #
      # The tree comes from the class's own cache when the caller has it (`resolved:`), which is the artifact
      # `Schema.build_input_for` nests from — the same tree, not a second one built beside it.
      def emitted_configs(field_configs, subfield_configs, for_output:, resolved: nil)
        if for_output
          owners = surviving_configs(field_configs)
          return field_configs.map { |config| [config, [config.field], owners.key?(config)] }
        end

        subfields = Array(subfield_configs)
        tree = resolved&.tree || SubfieldTree.build(field_configs, subfields)
        # A `model:` route writes `<field>_id` instead of the field, so it never claims a top-level slot.
        top_level = surviving_configs(field_configs.reject { |c| c.validations[:model] })
        (field_configs + subfields).filter_map do |config|
          path = tree.index[config]
          next unless path && !SubfieldTree.path_blocked?(path.ancestors)
          # `Array#include?` asks each reserved Symbol whether it equals the name, so the name's own `==` is
          # never the one dispatched.
          next if Schema::EXCLUDED_FROM_INPUT_SCHEMA.include?(config.field)

          owns = if path.ancestors.empty?
                   top_level.key?(config)
                 else
                   Schema.property_representative(path.node.configs).equal?(config)
                 end
          [config, input_property_path(config, path.wire_path), owns]
        end
      end

      # The configs whose write SURVIVES at their wire key, as an identity-keyed set: `build_input`/`build_output`
      # both write `properties[config.field] =` per config, so a later write at one key wins.
      #
      # Answered in a single pass, and the answer is a set of CONFIGS rather than a name-keyed map, so a config's
      # wire key is derived once — recording the owner and then asking "is that me" derived it twice, which on a
      # wide contract is the whole cost of asking.
      def surviving_configs(configs)
        last = {}
        configs.each { |config| last[wire_key_segment(config.field)] = config }
        last.each_value.with_object({}.compare_by_identity) { |config, owners| owners[config] = true }
      end

      # Where the input schema emits this config's own property: its wire path, or — for a `model:` route, which
      # emits the generated id INSTEAD of the field at every depth — that path with its leaf replaced by the id
      # key. The key comes from `Internal::FieldConfig.model_id_key`, the one owner of it that `build_input` and
      # `apply_children!` both emit through.
      def input_property_path(config, wire_path)
        return wire_path unless config.validations[:model]

        [*wire_path[0..-2], Internal::FieldConfig.model_id_key(wire_path.last)]
      end

      # The same bound over the stored configs a schema build is about to walk, and the FIRST walk of any
      # projection — `validate_and_build` runs it ahead of every build, inbound and outbound — so bounding the
      # graph here is what keeps a projection bounded at all.
      #
      # Bounded BOTH ways, because the configs it walks need not have been DECLARED: the declaration walk rejects
      # an untraversable graph and snapshots what it accepts, but a config assigned onto a class directly
      # (`internal_field_configs=`) carries whatever shape its author built, unwalked. The two ways need different
      # answers, and this walk needs both — exactly as the declaration walk does.
      #
      # A graph that CONTAINS itself repeats an object, which `CycleGuard` sees by identity. A graph that
      # GENERATES itself — a member whose `validations` mints a fresh nested shape on every read — repeats
      # nothing, so no identity guard can see it; it is endless rather than cyclic, and only the depth bound
      # stops it. Either way the stack goes before StandardError does, escaping the rescue meant to settle a
      # result, and the size budget is no defense: depth costs one property per level, so the stack runs out
      # thousands of levels before 25,000 does.
      #
      # The bound is `ShapeGraph::MAX_NESTING`, the same number from the same place the declaration walk reads —
      # one cap, so the two cannot drift into disagreeing about what is traversable.
      #
      # Ancestry-scoped (see CycleGuard), so a nested shape reused by SIBLING members is still counted twice —
      # that sharing is exactly what the budget exists to catch, and only genuine self-containment is a cycle.
      #
      # What it charges is DERIVED from `Schema.shape_property_plan` — the same plan the emitter itself acts on,
      # built from the same reduced view of the config (`Schema.effective_validations`, applied inside the plan so
      # nothing can ask for one from a config the emitter would not have used) — rather than predicted from the
      # declaration. A shape whose members never become properties therefore costs nothing: a scalar `of:`
      # (`of: String` with `field :length`) validates its members off an element that stays a string, and an
      # outbound-gated value, a non-member-keyed one, or an INPUT `model:` route (whose `<field>_id` is emitted in
      # place of the field) emits no object at all. Nor does a `type:`/`of:`/`shape:` entry an OUTBOUND
      # per-validator gate drops, which is why the walk reads its members off `plan.shape` rather than off the
      # config: the plan's shape is the one `apply_structured_schema!` emits from. Charging those rejected a
      # contract over a schema it does not have — as did charging a config the projection places nowhere, or one
      # whose property the projection builds from a different route, which are the same question one level up and
      # are settled before this walk is reached (see `emitted_configs`). The type's own properties ARE charged even
      # when the shape overlay is not emitted, because an `of:` element type's own members reach `items` with or
      # without a shape — and they are charged through `each_type_namespace`, so a type that emits its properties
      # across several namespaces (a multi-class `of:`) is counted in all of them rather than only at the node.
      #
      # The plan is asked once per shape-bearing node, not per member: a member with no nested shape has no
      # subtree to charge and never reaches this. The pre-check that skips it reads the config's OWN
      # `validations` — sound because the reduction only ever REMOVES entries, so a config with neither `shape:`
      # nor `of:` declared can have neither effectively, while one whose only such entry is gated away reaches
      # the plan and is charged nothing.
      def count_emitted_properties!(budget, owner, property_node, seen = nil, depth = 0, via: nil, for_output: false, &label)
        validations = Internal::ShapeGraph.hash_or_nil(Internal::ShapeGraph.read(owner, :validations))
        return if nil.equal?(validations)
        return if nil.equal?(Internal::ShapeGraph.hash_or_nil(validations[:shape])) && nil.equal?(validations[:of])

        plan = Schema.shape_property_plan(owner, for_output:)
        # WHERE those properties land — at the field's own node, or at its array ELEMENT's, which is the same
        # question `apply_structured_schema!` asks the plan (and `property_sources_for` asks it for attribution).
        node = plan.in_items? ? budget.namespace(property_node, ITEMS_SEGMENT) : property_node
        each_type_namespace(plan) do |type_path, names|
          names.each { |name| budget.charge_under!(node, [*type_path, property_segment(name)], &label) }
        end
        hash = Internal::ShapeGraph.hash_or_nil(plan.shape)
        return if nil.equal?(hash) || !plan.emitted

        raise_shape_too_deep!(via) if depth > Internal::ShapeGraph::MAX_NESTING

        outcome = Axn::Internal::CycleGuard.guard(hash, seen, on_cycle: CYCLIC_SHAPE) do |nested|
          Internal::ShapeGraph.members(hash).each do |member|
            # Skipped on the emitter's own rule for which members become properties: a member with no name is one
            # `named_members` filters out, so it names nothing here and its nested shape is emitted nowhere.
            name = Schema.member_name(member)
            next if nil.equal?(name)

            member_node = budget.charge_child!(node, property_segment(name), &label)

            count_emitted_properties!(budget, member, member_node, nested, depth + 1, via: member, for_output:, &label)
          end
        end
        raise_cyclic_shape!(via) if CYCLIC_SHAPE.equal?(outcome)
      end

      # A private object of this module's own, and always the RECEIVER of `equal?`, so nothing a declaration can
      # produce is mistaken for it.
      CYCLIC_SHAPE = ::Object.new.freeze
      private_constant :CYCLIC_SHAPE

      # Both read from ShapeGraph, which owns the two sentences: the same defects are reported by the ambient
      # placement check, which re-walks an already-declared graph for the same reason this does, and one text
      # keeps them from describing it two ways. Each reads as its declaration-time counterpart
      # (Core::Contract#_raise_cyclic_shape! / #_raise_shape_too_deep!) plus the one thing only a re-walk can
      # say: the graph was traversable when the class was declared, so it changed afterwards.
      def raise_cyclic_shape!(member) = raise(ArgumentError, Internal::ShapeGraph.self_containing_message(member))

      def raise_shape_too_deep!(member) = raise(ArgumentError, Internal::ShapeGraph.too_deep_message(member))

      # Seven entry points, and everything else internal. Mirrors Reflection::Values' own narrowing: the walk,
      # the message builders, and the provenance resolution are implementation of the two rules, not surface a
      # caller should reach. `field_name_spelling` is deliberately not public either — `inspect_field_name` is
      # the one way a name gets written into a message. `same_declared_name?` is public for the same reason
      # `renderable_label` is: the contract asks the same question about the same names, and two answers to it
      # is how a raw-spelling comparison came to be re-derived beside this one.
      private_class_method :validate_and_build, :attributions, :inbound_property_sources, :outbound_property_sources,
                           :reject_colliding_emitted_properties!, :reject_oversized_schema!,
                           :field_name_spelling, :each_emitted_node, :raise_colliding_properties!,
                           :property_source, :same_property_path?, :unrenderable_name_message,
                           :raise_unrenderable_emitted_name!, :raise_foreign_rendering_name!,
                           :foreign_rendering_name_message, :property_sources_for,
                           :shape_member_sources, :each_type_namespace, :shape_type_klass, :describe_type, :describe_config,
                           :count_emitted_properties!, :raise_cyclic_shape!, :raise_shape_too_deep!, :emitted_configs,
                           :property_segment, :wire_key_segment, :surviving_configs, :input_property_path
    end
  end
end
