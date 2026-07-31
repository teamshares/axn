# frozen_string_literal: true

require "axn/internal/cycle_guard"
require "axn/internal/shape_graph"

module Axn
  module Core
    module Contract
      module ShapeDeclaration
        # The declaration-time walk over a caller-supplied `shape:` graph, and the guards and error messages
        # that belong to it: what it rejects, what it snapshots, and how it names an offending member. Extends
        # onto the action class through `Contract::ClassMethods`, so every method here is reached with an
        # implicit receiver exactly as it was when it lived beside `expects`/`exposes`.

        # How a message names a shape member: its declared name when it has one, else its class. Never
        # its `inspect` — that is the member's own code running while the failure is being reported, and
        # an exception from it would replace the declaration error (escaping every rescue when it is
        # outside StandardError). A member with no `#field` has no name to print, and its class is the
        # only thing left that identifies it.
        #
        # `name` is passed in rather than read here, and every caller reads it on the way DOWN, before it
        # has a failure to report. Re-reading it here would be the same hazard as `inspect` one step
        # removed: a reader that raises (or answers differently) on a second read replaces the declaration
        # error with the caller's exception — verified against a member whose `field` raises the second time
        # it is called.
        def _describe_shape_member(member, name)
          return "of class #{Axn::Reflection::PropertyNames.renderable_class_name(member)}" if Internal::ShapeGraph.missing?(name)

          "`#{_shape_member_label(name)}`"
        end

        # A shape member's name is an object property in the reflected schema on exactly the same terms as a
        # field's, so it carries the same promise. Walks RESOLVED members rather than checking inside
        # ShapeBuilder because the `do…end` form routes through `_build_shape_member` but a raw `shape:`
        # kwarg supplies pre-built members that never do — the same reason
        # `_reject_outbound_shape_user_facing!` walks. Recursion covers a member's own nested block.
        #
        # A member that answers to no `#field` is rejected rather than skipped. The documented member contract
        # is `#field` PLUS `#validations`, and runtime validation reads `member.field` for every member it
        # validates — so a nameless member declared cleanly, reflected as nothing at all, and then raised
        # NoMethodError on the first call. Skipping it in the guard while the consumer dispatches it anyway is
        # the guard/consumer divergence this walk exists to eliminate. What the tolerance was ever for is the
        # opposite direction: a member that DEFINES `field` cannot escape the check by denying the reader,
        # decided from the real method table (see Internal::ShapeGraph), because reflection reads that name
        # regardless and the two must agree.
        #
        # This is the first shape walk on every declaration path, so it is where an untraversable graph is
        # rejected on behalf of all of them: a graph reaching validation, reflection or redaction has
        # already been rejected here if it is untraversable AS READ. What no declaration-time walk can
        # promise is a graph that answers a LATER read differently — a `[]` or a reader giving two answers
        # is a caller contradicting itself, not a guard missing something (see Internal::ShapeGraph).
        #
        # `via`/`via_name` name the member whose nested shape is being entered — the name captured on the
        # way down, never re-read while a failure is being reported.
        #
        # Two ways a graph can be untraversable, and each needs its own answer. A graph that CONTAINS
        # itself repeats an object, which `CycleGuard` detects by identity. A graph that GENERATES itself —
        # a shape Hash whose `[]` builds a fresh nested shape on every read — never repeats an object, so
        # no identity guard can see it; it is infinitely deep rather than cyclic, and only a depth cap
        # stops it. Both otherwise end in SystemStackError, outside StandardError, escaping every rescue.
        # THE declaration walk over a caller-supplied shape graph, and the only one: it rejects what cannot be
        # declared and copies what can, in a single pass. Returns the copy, which the caller stores as the
        # declared shape.
        #
        # Fused rather than a check pass followed by a copy pass, because the two have to agree about what the
        # members ARE: a list that answers a second `each` differently would leave the class holding members no
        # check ever saw.
        #
        # It also bounds the graph's SIZE, in member paths (see ShapeGraph::MAX_MEMBER_PATHS) — deliberately not
        # in emitted JSON properties, which is a different limit belonging to reflection, derived from what the
        # emitter emits, and applied at projection. This one is about the graph itself: the walks that read a
        # stored graph on a live call have no per-reference memo, so a graph that multiplies out costs the CALL.
        # Counting it here is what keeps that knowable at declaration, where the author is present.
        #
        # So a caller's members list is read exactly ONCE per declaration, and the answer it gave is the
        # contract: a list that would answer a later read differently never gets that read. What it cannot do is
        # decline the first one — the declaration is not knowable without it — so a list that raises on being
        # read raises at declaration, which is the intended outcome and the right one: the author is standing
        # there, rather than the failure landing on whoever first reflects the class.
        def _validate_and_snapshot_shape!(shape, fields)
          _walk_shape_graph!(shape, nil, [Internal::ShapeGraph::MAX_MEMBER_PATHS, fields]).copy
        end

        # Stores the copy in place of the caller's shape, and only when there is one to copy: a field that
        # declared no `shape:` must not gain the key here, and a `shape:` that is not a Hash is left exactly as
        # it came for the container check to reject.
        def _snapshot_declared_shape!(validations, fields)
          shape = Internal::ShapeGraph.hash_or_nil(validations[:shape])
          return if nil.equal?(shape)

          validations[:shape] = _validate_and_snapshot_shape!(shape, fields)
        end

        # What one walked shape yields. The path count travels with the copy because a shape REUSED by two
        # members is walked (and copied) once but COUNTED twice: sharing is exactly how a graph multiplies out,
        # so the second reference charges the whole total its subtree expands to.
        #
        # `height` is how many levels the walked subtree adds BELOW this shape — 0 for one whose members carry no
        # nested shape of their own — and it travels for the reason the count does, one step further: DEPTH is not
        # a property of a shape at all, it is a property of a shape at a POSITION. A subtree already walked needs
        # no walking again, but it does need re-judging against the bound wherever it is reused, and its height is
        # the whole of what that judgement needs (see `_walk_shape_graph!`).
        WalkedShape = Data.define(:copy, :paths, :height)
        private_constant :WalkedShape

        # The remaining allowance, and the fields to name if it runs out — a two-element Array rather than an
        # object, because it is threaded through every level of one walk and the label is only ever built on the
        # failure path.
        def _spend_paths!(allowance, paths)
          allowance[0] -= paths
          return unless allowance[0].negative?

          _raise_too_many_member_paths!(allowance[1])
        end

        def _raise_too_many_member_paths!(fields)
          raise ArgumentError,
                "the shape on #{_inspect_field_name(fields.first)} has more than " \
                "#{Internal::ShapeGraph::MAX_MEMBER_PATHS} member paths — a nested shape object reused by " \
                "sibling members multiplies out, so N levels of two-way sharing are 2^N distinct paths, and " \
                "every walk of the stored graph pays one step per path: runtime validation walks it on each " \
                "call, and redaction re-walks it per logged call whenever a `sensitive:` resolves against the " \
                "action (measured: 786,000 paths cost about 1.3 seconds per log line, and about two seconds " \
                "for the one derivation any contract makes on its first). Give each member its own nested " \
                "shape, or flatten the nesting. This is a bound on the graph, not on what a schema emits — an " \
                "oversized SCHEMA is reported separately, when a projection is first built."
        end

        def _walk_shape_graph!(shape, walk, allowance, via: nil, via_name: nil)
          hash = Internal::ShapeGraph.hash_or_nil(shape)
          # Not a shape, so it has no members to walk and nothing to copy — returned as it came, for the
          # container check downstream to reject.
          return WalkedShape.new(copy: shape, paths: 0, height: 0) if nil.equal?(hash)

          # Ahead of "does it supply members?", because a shape whose `members:` comes from a default supplies
          # them to this walk and not to the snapshot it produces — the reverse mismatch of the one below, and
          # reported as the defect it is rather than as a shape with no members.
          Internal::ShapeGraph.reject_defaulting_option_container!(hash) do
            nil.equal?(via) ? "the `shape:`" : "the nested `shape:` at shape member #{_describe_shape_member(via, via_name)}"
          end

          walk ||= ShapeWalk.new(seen: nil, walked: {}.compare_by_identity, depth: 0)
          walked = walk.walked[hash]
          unless nil.equal?(walked)
            # The bound is re-judged HERE, against the reused subtree's whole height, because the memo answers
            # "traversable as read" — a property of the subtree — and not "within the bound", which depends on
            # where it is reused. Without it a graph reaches ANY depth out of subtrees each first met shallow:
            # present every tail of a shared chain as a sibling of the root before the next chain nests it one
            # level lower, and no walk descends past two while the stored graph is arbitrarily deep. Judged
            # ahead of the path charge, as a shape's own depth is judged ahead of its members' charges — one memo
            # hit stands for walking this shape and everything under it.
            _raise_shape_too_deep!(via, via_name) if walk.depth + walked.height > Internal::ShapeGraph::MAX_NESTING
            _spend_paths!(allowance, walked.paths)
            return walked
          end

          # The same inequality with a height not yet known: descending checks each level as it is reached, so a
          # shape walked rather than reused is judged by its own position and its subtree by theirs.
          _raise_shape_too_deep!(via, via_name) if walk.depth > Internal::ShapeGraph::MAX_NESTING

          # Read as SUPPLIED, so a shape that names no members is told apart from one naming an empty list.
          members = Internal::ShapeGraph.declared_members(hash)
          _raise_missing_shape_members!(via, via_name) if nil.equal?(members)

          walked = Axn::Internal::CycleGuard.guard(hash, walk.seen, on_cycle: CYCLIC_SHAPE) do |nested|
            _check_and_copy_shape_members!(hash, members, walk.with(seen: nested), allowance)
          end
          _raise_cyclic_shape!(via, via_name) if CYCLIC_SHAPE.equal?(walked)

          walk.walked[hash] = walked
          walked
        end

        # The state one walk carries. `seen` is the ANCESTRY set `CycleGuard` pushes and pops, which is what
        # makes a diamond (one nested shape reused by two siblings) legal rather than a false cycle.
        # `walked` is the complement: shapes already walked to completion, which never need walking again —
        # without it, that same legal diamond costs 2^depth walks (measured: 18 levels took 1.4s, 22 took
        # 22s), so a generated-but-honest schema with shared sub-shapes hung at class definition. Keyed by
        # identity, per declaration, and populated only AFTER a shape has passed — and carries that shape's copy,
        # so a shape reused by two members is read from the caller once and both members store the one copy. A
        # shape that answers a later read differently is the inconsistent-reader limit above, not something
        # re-walking would have caught.
        #
        # What an entry means is bounded by what it can mean: "this subtree is traversable as read, and here is
        # its size and its height". Every question that is a property of the SUBTREE is answered by reuse; every
        # question that depends on the POSITION — the depth bound, the size allowance — is asked again at each
        # reference (see `_walk_shape_graph!`). Reading an entry as "already verified" full stop admits a graph
        # deeper than any walk of it goes, since a shared chain can present every tail shallow first.
        ShapeWalk = Data.define(:seen, :walked, :depth)
        private_constant :ShapeWalk

        # Sentinel for "this shape was already open on the path" — a private object rather than a value a
        # declaration could produce, so nothing a caller supplies can be mistaken for it, and identity is
        # asked of the sentinel so no caller's `equal?` is dispatched.
        CYCLIC_SHAPE = Object.new.freeze
        private_constant :CYCLIC_SHAPE

        # One node: its members checked, counted, and copied. Each member's name is read exactly ONCE, into a
        # (member, name) pair, and every later use of it — a collision message, a cycle or depth report against
        # a nested shape, the copy stored for it — reads that capture rather than the member again. Same reasoning
        # as the renderer's one-#to_s-per-key rule: a second read may disagree with the first or raise something
        # that is not even a StandardError, replacing the diagnosis with the escape these guards exist to prevent.
        #
        # Reading the name once is not enough on its own, because CANONICALIZING it is a second dispatch on the
        # same caller object: a String subclass whose `to_sym` answers `:alpha` and then `:collide` gave the
        # duplicate check one property name and `ShapeConfig`'s constructor another, so two declared members were
        # stored under one property, `member_properties` emitted one, and nothing raised. So the canonical Symbol
        # is computed once too, beside the check that judges it, and threaded to the snapshot — which is what
        # makes "the guard judged the property this member is stored under" true rather than probable.
        def _check_and_copy_shape_members!(hash, members, walk, allowance)
          named = members.map { |member| [member, Internal::ShapeGraph.fetch(member, :field)] }
          named.each { |member, name| _raise_nameless_member!(member, name) if Internal::ShapeGraph.missing?(name) }
          names = named.map { |_member, name| name }
          # Ahead of every other name check: a name that is not a String or a Symbol has two independent
          # renderings rather than one property (see Contract.validate_shape_member_name!), so asking whether
          # it is renderable, or whether it collides, would be asking about only one of them. A ShapeConfig
          # was already held to this in its constructor; a duck-typed member reaches it only here.
          names.each { |name| Contract.validate_shape_member_name!(name) }

          # Only the SAME key declared twice in one block is judged here — keyed by `to_sym`, which is exactly
          # what `Schema#member_properties` keys a member's property by, so the two agree about what "the same
          # member" is. Two members whose names merely CANONICALIZE alike are two distinct keys at one node,
          # which is a property collapse rather than a repeat declaration, and the one claim space judges every
          # such collapse (`_reject_colliding_property_claims!`) so no mechanism pair can slip between checks.
          # This one cannot move there: two identical claims are a legal MERGE by that rule, while two
          # identical members of one block are a genuine duplicate.
          #
          # The key each member is judged under is CAPTURED here (into a (member, name, key) triple) and stored
          # as that member's `field`, rather than converted again downstream — see the note above. Computed
          # inside this loop rather than in a pass of its own so the order of failures is unchanged: a name whose
          # `to_sym` raises (bytes with no Symbol, say) is still reached after every earlier member has been
          # judged, so a duplicate declared ahead of it is still reported as the duplicate it is.
          claimed = {}
          keyed = named.map do |member, name|
            key = name.to_sym
            _raise_duplicate_member!(name) if claimed.key?(key)

            claimed[key] = name
            [member, name, key]
          end

          child = walk.with(depth: walk.depth + 1)
          paths = 0
          height = 0
          copied = keyed.map do |member, name, key|
            # Charged BEFORE this member is snapshotted, and before its nested shape is walked, so a graph that
            # multiplies out is rejected while the work done on it is still bounded by the allowance.
            _spend_paths!(allowance, 1)
            paths += 1
            # `validations` is read ONCE and threaded to every use — the nested shape to walk, and the snapshot
            # of this member. A second read is a second answer the caller can give.
            validations = _symbol_keyed_member_validations(member, name)
            _raise_member_without_validations!(member, name) if nil.equal?(validations)
            # Every other attribute read (and grammar-checked) BEFORE the nested walk, so a member carrying both
            # a bad `sensitive:` and an untraversable nested shape is reported as the value defect it is.
            attributes = _snapshot_member_attributes!(member, name, key, validations)
            nested = Internal::ShapeGraph.hash_or_nil(validations[:shape])
            unless nil.equal?(nested)
              inner = _walk_shape_graph!(nested, child, allowance, via: member, via_name: name)
              paths += inner.paths
              # This node's height is the deepest member's, plus the level that member's shape adds.
              nested_height = inner.height + 1
              height = nested_height if nested_height > height
              validations[:shape] = inner.copy
            end
            ShapeConfig.new(**attributes)
          end

          WalkedShape.new(copy: Internal::ShapeGraph.snapshot_node(hash, copied), paths:, height:)
        end

        # Everything a stored member carries, read off the caller's object exactly ONCE and held to its grammar
        # on the way — so what the class stores is axn's own `ShapeConfig` and the caller keeps nothing live in a
        # declared contract. Read through `ShapeGraph`, so a member that denies a reader it defines is still held
        # to the rules, and the value snapshotted is the one that reader gives.
        #
        # Snapshotting rather than storing the object is what makes "the contract is what you declared" true for
        # a member too: a retained member's `sensitive:` could be flipped after the class was declared (changing
        # what redaction masked, or not, depending only on whether anything had asked yet), its canonicalized
        # `validations` were computed and then thrown away (so a String-keyed `type:` bag validated nothing and
        # reflected nothing), its option containers stayed aliased where a field's were detached, and the nested
        # shape it carried could gain members or be pointed at itself afterwards.
        #
        # The grammars for `sensitive:`/`user_facing:` are checked HERE, ahead of `ShapeConfig`'s constructor,
        # only so the error keeps its place in this walk's order; the constructor enforces the same rules for the
        # block form, where it is the first thing to see them. A falsey `user_facing:` is "not opted in" and has
        # no grammar to meet — `nil` is what an absent reader answers.
        #
        # `description` is read directly rather than taken from `metadata`, because that is where reflection
        # reads it from (`Schema.declared_attribute`) and a duck-typed member may define the reader without any
        # metadata at all; folding it into the metadata Hash is what `ShapeConfig#description` then answers with.
        #
        # `name` and `key` are the same name in its two roles: `name` is what a message about this member RENDERS
        # (a raw String keeps the spelling the caller wrote, and an unrenderable one its escaped form), while
        # `key` is the canonical Symbol the duplicate check already judged — and so the property this member is
        # stored, validated and emitted under. Both come from the one read; nothing here converts either again.
        def _snapshot_member_attributes!(member, name, key, validations)
          sensitive = Internal::ShapeGraph.read(member, :sensitive)
          Contract.validate_sensitive!(sensitive)
          user_facing = Internal::ShapeGraph.read(member, :user_facing)
          Contract.validate_user_facing!(user_facing) if user_facing

          metadata = _symbol_keyed_member_metadata(member, name) || {}
          description = Internal::ShapeGraph.read(member, :description)
          metadata[:description] = description unless nil.equal?(description)

          { field: key, validations:, metadata:, sensitive: sensitive || false, user_facing: user_facing || false,
            method_call: Internal::ShapeGraph.read(member, :method_call) || false }
        end

        # A shape graph that contains itself has no traversal at all: every walk over it — this one, the
        # runtime validator's, the schema's — recurses until the stack overflows, and SystemStackError is
        # outside StandardError, so it escapes every rescue in the framework rather than settling into a
        # reported failure. Rejected at declaration, where it is knowable and where the author is present.
        def _raise_cyclic_shape!(member, name)
          via = nil.equal?(member) ? "" : " reached from shape member #{_describe_shape_member(member, name)}"
          raise ArgumentError,
                "a `shape:` graph cannot contain itself — the nested shape#{via} is the same shape it is nested " \
                "inside, so validating or reflecting it would recurse until the stack overflows. Give the nested " \
                "shape its own members rather than reusing the shape (or the member) that encloses it."
        end

        # The generative counterpart: no object repeats, so nothing identifies a loop, and the graph is
        # simply endless. Capped rather than walked to exhaustion, for the same reason a cycle is rejected
        # — the alternative outcome is a SystemStackError raised while the class is being defined, which
        # no rescue in the framework can settle.
        def _raise_shape_too_deep!(member, name)
          via = nil.equal?(member) ? "" : " at shape member #{_describe_shape_member(member, name)}"
          raise ArgumentError,
                "a `shape:` graph nested more than #{Internal::ShapeGraph::MAX_NESTING} levels deep#{via} is almost certainly " \
                "generated rather than declared — no hand-written shape block reaches that depth, while a shape " \
                "object that builds a fresh nested shape on every read is endless and would recurse until the " \
                "stack overflows. Have the shape return the same finite nested shape each time it is read, or " \
                "flatten the nesting."
        end

        # A member's declared validations, symbol-canonical at BOTH levels its grammar has: the validator names,
        # and each validator's own option bag (see _symbolize_option_bags!, which does the same for a field).
        # A raw `shape:` member bypasses `expects`' option handling entirely, so this is the one place its
        # grammar gets canonicalized — and it must, because what the snapshot stores is a plain Hash: a member
        # declared with String keys otherwise validated nothing at all, silently, and reflected an empty
        # constraint beside it.
        def _symbol_keyed_member_validations(member, name)
          validations = Internal::ShapeGraph.hash_or_nil(Internal::ShapeGraph.read(member, :validations))
          return nil if nil.equal?(validations)

          Internal::ShapeGraph.reject_defaulting_option_container!(validations) { "the validations of #{_member_owner_label(member, name)}" }
          # A Hash axn owns, ALWAYS — canonicalized and copied in one pass. "Needs no key change" and "needs no
          # copy" are different questions, and answering only the first left a member's options aliased to the
          # objects the caller still held while a top-level field's were detached: mutating an `inclusion:` list
          # afterwards widened a declared member's enum. The copy is also what the snapshot stores, so it is one
          # allocation rather than two.
          copy = {}
          Internal::ShapeGraph.each_entry(validations) do |key, value|
            canonical = case key
                        when ::String then key.to_sym
                        else key
                        end
            _raise_ambiguous_option_key!("the validations of #{_member_owner_label(member, name)}", canonical) if copy.key?(canonical)

            copy[canonical] = value
          end
          # Each bag's own keys, then the containers themselves — through the same two helpers a field's options
          # go through, in the same order, so a member is held to exactly what a field is held to: an
          # `inclusion:` list keeps its class, and a container that answers with code of its own is refused
          # unless it is frozen.
          _symbolize_option_bags!(copy)
          Internal::ShapeGraph.detach_option_containers!(copy)
          copy
        end

        def _member_owner_label(member, name) = "shape member #{_describe_shape_member(member, name)}"

        # Metadata is one level of grammar (`description:` and whatever an extension registered), read as
        # Symbols — `ShapeConfig#description` is `metadata[:description]` — so a String-keyed metadata Hash
        # silently loses every entry it holds.
        def _symbol_keyed_member_metadata(member, name)
          metadata = Internal::ShapeGraph.hash_or_nil(Internal::ShapeGraph.read(member, :metadata))
          return nil if nil.equal?(metadata)

          Internal::ShapeGraph.reject_defaulting_option_container!(metadata) { "the metadata of #{_member_owner_label(member, name)}" }
          # Canonicalized WHILE being copied, in one pass: metadata is copied either way (what is stored IS the
          # contract — see `_snapshot_member_attributes!`), so asking about its keys separately would be a second
          # pass over every member for nothing.
          copy = {}
          Internal::ShapeGraph.each_entry(metadata) do |key, value|
            canonical = case key
                        when ::String then key.to_sym
                        else key
                        end
            _raise_ambiguous_option_key!("the metadata of #{_member_owner_label(member, name)}", canonical) if copy.key?(canonical)

            copy[canonical] = value
          end
          copy
        end

        # Named by class, since it has no name — through `_describe_shape_member`, so nothing of the member's
        # own runs while the declaration error is being built.
        def _raise_nameless_member!(member, name)
          raise ArgumentError,
                "a shape member must answer to `field`, naming the key it validates — the member " \
                "#{_describe_shape_member(member, name)} answers to none. Runtime validation reads " \
                "`member.field` for every member, so such a member would validate nothing, be omitted from " \
                "the reflected schema entirely, and raise NoMethodError on the first call. Give it a `field` " \
                "reader (with `validations`, the rest of the member contract), or declare it with " \
                "`field :name` inside a `shape` block."
        end

        # A shape is a container plus the members that describe what is inside it, so a raw one that names no
        # members list at all is malformed — it declares a shaped field nothing describes. It used to be caught
        # on the first CALL (`ShapeValidator#check_validity!` refuses a nil members list); rejecting it here is
        # strictly earlier and is where every other malformed declaration is answered.
        #
        # An empty list is NOT this: `members: []` is a real declaration (the container type still constrains the
        # value), pointless rather than wrong, and axn's business is not to refuse it.
        def _raise_missing_shape_members!(member, name)
          via = nil.equal?(member) ? "" : " at shape member #{_describe_shape_member(member, name)}"
          raise ArgumentError,
                "a raw `shape:`#{via} must supply `members:` — a shape describes what is inside a container, so " \
                "one with no members list constrains nothing beyond the container type, and runtime validation " \
                "has nothing to validate against. Supply `members: [...]` (an empty list is accepted, if " \
                "pointless), or declare the shape with a `do … end` block, which builds the members list for you."
        end

        # The other half of the documented member contract (see _raise_nameless_member!): runtime validation
        # reads `member.validations` for every member it validates — repeatedly, and dispatched directly — so a
        # member that answers to `field` but not `validations` declared cleanly and then raised NoMethodError on
        # the first call. `validations: {}` is the honest spelling of "constrains nothing".
        def _raise_member_without_validations!(member, name)
          raise ArgumentError,
                "a shape member must answer to `validations` as well as `field` — the member " \
                "#{_describe_shape_member(member, name)} answers to `field` only. Runtime validation reads " \
                "`member.validations` for every member, so such a member would raise NoMethodError on the first " \
                "call. Give it a `validations` reader (`{}` when it constrains nothing), or declare the member " \
                "with `field :name` inside a `shape` block."
        end

        # The same member key declared twice in one block. No comparison of the two names is needed — and so
        # none is made: they arrived under one `to_sym` key, which is the identity the schema itself uses, so
        # nothing a name's class can define (an `==` that raises) is dispatched to reach this conclusion.
        def _raise_duplicate_member!(offending)
          raise Axn::DuplicateFieldError,
                "Duplicate shape member declared: #{_inspect_field_name(offending)} — two members of one shape would " \
                "validate the same key, and the reflected schema would keep only the last. Declare each member once."
        end

        # Private, though declared next to their definitions rather than relocated below: these are
        # declaration-time internals of the shape-member walk, called only with an implicit receiver (from here
        # and from ContractForSubfields, which is extended onto the same class). Kept in place so each stays
        # beside the walk it belongs to, with its comment.
        #
        # The leading-underscore class methods still PUBLIC on an action class are the ones another layer calls
        # on it from a different file (`_resolved_subfields`, `_declared_fields`, `_context_slice`, …) plus the
        # `class_attribute` accessors, whose class-level reader ActiveSupport's own generated instance reader
        # calls as `self.class.<name>` — hiding it would break that.
        private :_spend_paths!, :_raise_too_many_member_paths!, :_symbol_keyed_member_validations,
                :_symbol_keyed_member_metadata, :_snapshot_member_attributes!,
                :_member_owner_label, :_describe_shape_member,
                :_snapshot_declared_shape!, :_validate_and_snapshot_shape!, :_walk_shape_graph!,
                :_check_and_copy_shape_members!, :_raise_cyclic_shape!, :_raise_shape_too_deep!,
                :_raise_duplicate_member!, :_raise_nameless_member!,
                :_raise_missing_shape_members!, :_raise_member_without_validations!
      end
    end
  end
end
