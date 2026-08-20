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
          return "of class #{Axn::Internal::Reflection::PropertyNames.renderable_class_name(member)}" if Internal::ShapeGraph.missing?(name)

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
        def _validate_and_snapshot_shape!(shape, allowance, depth)
          _walk_shape_graph!(shape, ShapeWalk.new(seen: nil, walked: {}.compare_by_identity, depth:), allowance).copy
        end

        # ONE path allowance per field DECLARATION, threaded to both of that declaration's edges: the `shape:`
        # snapshot `expects`/`exposes` takes, and the `of:` chain `_parse_field_validations` descends after it.
        # Minting one per edge charged the same field two independent budgets — twice the graph the bound
        # permits — which was unexploitable only while the two edges could not interleave at field level, i.e.
        # only until `:shape` joined `OF_OPTION_KEYS` (PRO-3166 task 4).
        #
        # A block-form MEMBER's pre-pass (`_build_shape_member` → `_parse_field_configs`) deliberately mints its
        # own: it walks the member's chain a second time, at depth 0, and the real charge is made by the walk
        # that knows where the member sits. Sharing there would charge those rungs twice, and an over-charge
        # rejects a legal declaration.
        #
        # A two-element Array rather than an object, because it is threaded through every level of one walk and
        # the label is only ever built on the failure path.
        def _new_path_allowance(fields) = [Internal::ShapeGraph::MAX_MEMBER_PATHS, fields]

        # The `of:` walk's entry point for a FIELD, where there is no enclosing walk to inherit a position from:
        # depth starts at 0, and the path allowance is this declaration's own. It descends the field's OWN chain
        # and no other — `inner_contracts` reads `:of` alone, so the chains hanging off the field's shape members
        # are not reachable from here and are descended at the member site instead.
        #
        # A BLOCK-form member reaches this method too, because `_build_shape_member` parses a member exactly as a
        # field is parsed: its chain is walked here at depth 0 and again from `_check_and_copy_shape_members!` at
        # the member's real depth. That is the same runs-twice property `_drop_derived_of_container!` exists for,
        # and it is the second pass that binds — the first cannot know how far down the member sits, so it
        # under-charges depth, and under-charging only ever admits what the position-aware pass then refuses. A
        # member supplied as a RAW `shape:` kwarg never routes through here at all, which is why the member site
        # is where the chain is canonicalized rather than merely re-checked.
        def _walk_declared_inner_contracts!(validations, fields, allowance)
          _walk_inner_contracts!(validations, ShapeWalk.new(seen: nil, walked: {}.compare_by_identity, depth: 0),
                                 allowance, fields:)
        end

        # Stores the copy in place of the caller's shape, and only when there is one to copy: a field that
        # declared no `shape:` must not gain the key here.
        def _snapshot_declared_shape!(validations, allowance, fields)
          _reject_unshaped_shape!(validations, "`shape:` on #{_declared_fields_label(fields)}")
          shape = Internal::ShapeGraph.hash_or_nil(validations[:shape])
          return if nil.equal?(shape)

          validations[:shape] = _validate_and_snapshot_shape!(shape, allowance, _distributing_shape_depth(validations, 0))
        end

        # Where a shape SITS, which is what its whole subtree is judged against. A DISTRIBUTING `shape:` sits one
        # level lower than it is written: canonicalization folds it into the `of:` bag naming the elements it
        # describes (`_fold_distributing_shape!`), so the rung that reaches it is the container's, and its
        # members are read off an ELEMENT rather than off the declared value itself.
        #
        # That extra level is not bookkeeping — it is what keeps the declaration bound and the runtime bound the
        # SAME bound. A value walked against this contract spends two rungs per link: `OfValidator` descends the
        # container to the element, then `ShapeValidator` descends the element to its members. Judging the shape
        # where it was WRITTEN spent one, so a chain that declared legally at 64 links raised `a shape: graph
        # nests more than 64 levels deep` on every call from link 33 — declared clean, failed always, which is
        # exactly the split two bounds over one graph exist to prevent.
        def _distributing_shape_depth(node, depth) = _distributing_shape?(node) ? depth + 1 : depth

        # THE refusal for a `shape:` that is not a Hash, at every position one can be written: a field's own,
        # a shape MEMBER's, and either kind of `of:` bag (an Array's element, a map's `keys:` or `values:`).
        # One guard rather than four, because it is one defect — every one of those positions classifies with
        # `hash_or_nil` and skips what it cannot read, so a non-Hash declared cleanly and then failed EVERY
        # call with a bare `ArgumentError: must supply :members`, naming neither the declaration nor the
        # option. It is the same defect, and the same closing, as the nested `container:` derivation in
        # `_check_and_copy_shape_members!`: the check the field path already made, called from wherever the
        # walk actually is.
        #
        # Only a Hash carries a `members:` list, so nothing else can name members — which is why the
        # classification is the verdict rather than an approximation of it.
        #
        # Keyed on `key?` rather than on the value, so `shape: nil` — supplied and naming nothing — is refused
        # while a declaration that simply carries no `shape:` stays the honest spelling of "no members". The
        # offender is named through `_declared_type_label`, never its own `inspect`: it is the caller's object,
        # and one whose `inspect` raises would replace this declaration error with its own exception (outside
        # StandardError, one that escapes every rescue meant to settle it).
        #
        # `where` is built by the caller, which is the only place that knows WHICH of the four positions this
        # is — the same reason `_raise_cyclic_graph!` is passed its `edge:` rather than inferring one. A
        # message naming a slot the author did not write prescribes a fix their declaration has nowhere to
        # make.
        def _reject_unshaped_shape!(carrier, where)
          return unless Internal::ShapeGraph.carries_key?(carrier, :shape)
          return unless nil.equal?(Internal::ShapeGraph.hash_or_nil(carrier[:shape]))

          raise ArgumentError,
                "#{where} must be a Hash naming the members it describes (got " \
                "#{_declared_type_label(carrier[:shape])}) — a shape describes what is inside a value, so one " \
                "that names no `members:` list constrains nothing and makes every call raise " \
                "`ArgumentError: must supply :members`. Supply `shape: { members: [...] }`, or drop shape:."
        end

        # Where a `shape:` hanging off an `of:` bag sits, as the phrase the refusal names it by, from the two
        # things that locate one: which SLOT of the bag grammar it is in, and which declaration encloses it —
        # a shape member when the walk reached it through one, else the field. Both are carried down by the
        # walk rather than re-read here, exactly as `_raise_cyclic_graph!`'s are.
        def _inner_shape_position_label(position, member, name, fields)
          slot =
            case position
            when Internal::ShapeGraph::KEYS_POSITION then "the `of: { keys: … }` bag"
            when Internal::ShapeGraph::VALUES_POSITION then "the `of: { values: … }` bag"
            else "the `of:` bag"
            end
          owner = nil.equal?(member) ? _declared_fields_label(fields) : "shape member #{_describe_shape_member(member, name)}"
          "`shape:` inside #{slot} on #{owner}"
        end

        # Which edge a declaration walk descended to reach an offending node: `shape:` to a node's named
        # members, `of:` to the unnamed rung inside a container. The refusals further down are written once per
        # edge rather than once with a noun swapped, because it is the FIX that differs — a cyclic `shape:` is
        # repaired by giving the nested shape its own members, a cyclic `of:` by giving the nested bag contents
        # of its own — and a sentence naming the construct the author did not write prescribes a change their
        # declaration has nowhere to make. Passed explicitly by each walk rather than defaulted, so a third edge
        # cannot inherit the wrong vocabulary by omission, and carried on the two walk results below for the
        # same reason: a memo hit is re-judged with the subtree gone, so the answer has to travel with it.
        SHAPE_EDGE = :shape
        INNER_CONTRACT_EDGE = :of
        private_constant :SHAPE_EDGE, :INNER_CONTRACT_EDGE

        # What one walked shape yields. The path count travels with the copy because a shape REUSED by two
        # members is walked (and copied) once but COUNTED twice: sharing is exactly how a graph multiplies out,
        # so the second reference charges the whole total its subtree expands to.
        #
        # `height` is how many levels the walked subtree adds BELOW this shape — 0 for one whose members carry no
        # nested shape of their own — and it travels for the reason the count does, one step further: DEPTH is not
        # a property of a shape at all, it is a property of a shape at a POSITION. A subtree already walked needs
        # no walking again, but it does need re-judging against the bound wherever it is reused, and its height is
        # the whole of what that judgement needs (see `_walk_shape_graph!`).
        #
        # `edge` names which KIND of rung that deepest level is, and travels for the reason `height` does: the
        # re-judgement happens at a memo hit, where the only thing left of the subtree is this record, and the
        # too-deep message differs by edge because the FIX differs. A shape whose height comes mostly from an
        # `of:` chain would otherwise be reported as a `shape:` graph and told to flatten a nesting it has not got.
        WalkedShape = Data.define(:copy, :paths, :height, :edge)
        private_constant :WalkedShape

        # What one walked chain of inner contracts yields, in the same currencies a walked shape reports — so a
        # member's `of:` folds into the same totals its nested `shape:` does, and a subtree the memo hands back
        # is re-judged against a height that counts both kinds of level, attributed to whichever kind is deepest.
        # There is no `copy` to report: an `of:` bag is canonicalized in place onto the node that holds it (see
        # `_walk_inner_contracts!`), where a shape is snapshotted into a new node its member then has to be
        # pointed at.
        WalkedContracts = Data.define(:paths, :height, :edge)
        private_constant :WalkedContracts

        # Height 0 means nothing below, so the edge is inert; named rather than left nil so no reader has to
        # decide what an absent edge means.
        NO_INNER_CONTRACTS = WalkedContracts.new(paths: 0, height: 0, edge: INNER_CONTRACT_EDGE)
        private_constant :NO_INNER_CONTRACTS

        # THE declaration walk over a node's `of:` chain, and the seam that canonicalizes each rung of it. An
        # `of:` bag is the other kind of child a node has, and it is bounded on exactly the terms a nested
        # `shape:` is: one depth counter (a graph 64 `of:` deep by 64 `shape:` deep is 128 levels of walking,
        # which two counters would admit), one path allowance (an `of:` rung charges 1, as a member does), and
        # one cycle guard (`h[:of] = h` is reachable by hand).
        #
        # The walk DRIVES the canonicalization rather than following it. Canonicalizing a bag's own `of:` from
        # inside `_canonical_array_of!` recurses over the CALLER's graph with no bound of any kind, and a
        # self-referential bag ended that recursion in `SystemStackError` — outside StandardError, raised while
        # the class is being defined, so no rescue in the framework settles it — before any guard here could
        # report it. Descending one rung at a time is what puts the bounds ahead of the recursion instead of
        # behind it.
        #
        # The cycle guard is keyed on the RAW child, not on the bag being descended into: every canonical rung
        # is a fresh Hash of axn's (each is a `merge` result), so nothing in the canonical graph can ever repeat
        # — the only object a cycle can bring back around is the caller's own, which is what sits under this
        # bag's `:of` until the rung below it is canonicalized. Detaching a bag copies one level (see
        # `_canonicalize_inner_contract!`), so a caller's cyclic Hash keeps resurfacing there at every turn of
        # the loop and is caught on the second.
        #
        # It is also where a distributing `shape:` is FOLDED into the bag that names the elements it describes
        # (`_fold_distributing_shape!`), which is the canonicalization PRO-3166 exists for — the walk is the
        # only place that has both the node and its bag in hand with each of their shapes already final.
        #
        # It is also where this node's OWN map bag learns which of its keys a `shape:` beside it exempts
        # (`_derive_shaped_keys!`). Here rather than at the canonicalization, because here the shape is final:
        # a member's is snapshotted by the loop above and a bag's by `_snapshot_inner_shape!` below, both AFTER
        # the `of:` beside them was canonicalized. FIRST, before the children are enumerated and ahead of the
        # early return: it replaces the node's `of:` with an extended copy, and an enumeration taken across that
        # write would hand the loop bags belonging to the Hash that was just replaced.
        def _walk_inner_contracts!(validations, walk, allowance, fields:, via: nil, via_name: nil)
          # BEFORE the enumeration, because a node whose `shape:` distributes over its elements and which named
          # no `of:` at all has no rung yet for that shape to be folded into (`expects :rows, type: Array do …
          # end`). The bag this mints is what gives the fold below somewhere to land.
          _open_distributing_bag!(validations)
          _derive_shaped_keys!(validations)
          contracts = Internal::ShapeGraph.inner_contracts(validations)
          return NO_INNER_CONTRACTS if contracts.empty?

          paths = 0
          height = 0
          # Which kind of rung the deepest level below this node is (see `WalkedShape`); inert while height is 0.
          edge = INNER_CONTRACT_EDGE
          contracts.each do |(position, bag)|
            # Charged before the rung is descended, so a graph that multiplies out is rejected while the work
            # done on it is still bounded by the allowance.
            _spend_paths!(allowance, 1)
            paths += 1
            _raise_graph_too_deep!(via, via_name, edge: INNER_CONTRACT_EDGE) if walk.depth > Internal::ShapeGraph::MAX_NESTING

            raw = Internal::ShapeGraph.hash_or_nil(bag[:of])
            walked = Axn::Internal::CycleGuard.guard(raw || bag, walk.seen, on_cycle: CYCLIC_SHAPE) do |nested|
              child = walk.with(seen: nested, depth: walk.depth + 1)
              _canonicalize_inner_contract!(bag, fields)
              # The bag's OTHER kind of child, walked off the same state — one depth budget and one path
              # allowance across both edges, exactly as a shape MEMBER's two edges share them.
              shaped = _snapshot_inner_shape!(bag, child, allowance, fields:, position:, via:, via_name:)
              # Between the two, and never beside them: the enclosing node's distributing `shape:` describes
              # THIS bag's contents, so it is merged into the bag once the bag's own shape is final and before
              # the descent that reads the merged result (`_derive_shaped_keys!` at the rung below).
              _fold_distributing_shape!(validations, bag, position)
              inner = _walk_inner_contracts!(bag, child, allowance, fields:, via:, via_name:)
              _combine_inner_contracts(shaped, inner)
            end
            _raise_cyclic_graph!(via, via_name, edge: INNER_CONTRACT_EDGE) if CYCLIC_SHAPE.equal?(walked)

            paths += walked.paths
            # This node's height is the deepest rung's, plus the level this rung itself adds. The level ADDED
            # here is the `of:` rung; anything below it keeps the edge that subtree reported.
            rung_height = walked.height + 1
            if rung_height > height
              height = rung_height
              edge = walked.height.zero? ? INNER_CONTRACT_EDGE : walked.edge
            end
          end

          WalkedContracts.new(paths:, height:, edge:)
        end

        # The `shape:` hanging off an `of:` bag: walked by the SAME walk a nested shape at a member is walked
        # by, off the state the enclosing rung is descending with, so the two edges of a bag share one depth
        # counter, one path allowance, one cycle ancestry and one memo of walked sub-shapes. Anything else and
        # a graph 64 `of:` deep by 64 `shape:` deep would be declarable.
        #
        # Copy first, then derive — the member site's own order (`_check_and_copy_shape_members!`), and
        # load-bearing for the same reason: the walk's memo hands two positions reusing one shape the SAME copy,
        # and `_derive_inner_shape_container!` detaches before it writes, so a shape reused under `klass: Hash`
        # and under a klass-less bag stores the right container in each place rather than the last one walked.
        # Deriving first would defeat that memo outright, since a fresh detached node is a fresh identity.
        #
        # `height` is the shape's own subtree plus the level the shape node itself adds below the bag, matching
        # what a member's nested shape contributes to its node's height.
        def _snapshot_inner_shape!(bag, walk, allowance, fields:, position:, via:, via_name:)
          _reject_unshaped_shape!(bag, _inner_shape_position_label(position, via, via_name, fields))
          shape = Internal::ShapeGraph.hash_or_nil(bag[:shape])
          return NO_INNER_CONTRACTS if nil.equal?(shape)

          walked = _walk_shape_graph!(shape, walk, allowance, via:, via_name:)
          bag[:shape] = walked.copy
          _derive_inner_shape_container!(bag)
          # The level added here is the SHAPE node the bag carries; below it, the subtree's own answer stands.
          WalkedContracts.new(paths: walked.paths, height: walked.height + 1,
                              edge: walked.height.zero? ? SHAPE_EDGE : walked.edge)
        end

        # Two children of one bag folded into the one total the rung reports: paths add, height is the deeper.
        def _combine_inner_contracts(left, right)
          deeper = right.height > left.height ? right : left
          WalkedContracts.new(paths: left.paths + right.paths, height: deeper.height, edge: deeper.edge)
        end

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
          return WalkedShape.new(copy: shape, paths: 0, height: 0, edge: SHAPE_EDGE) if nil.equal?(hash)

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
            # Attributed to the edge the reused subtree's own deepest rung sits on, not to the reference that
            # reached it: a shape whose height is mostly an `of:` chain is an `of:` graph to flatten.
            if walk.depth + walked.height > Internal::ShapeGraph::MAX_NESTING
              _raise_graph_too_deep!(via, via_name, edge: walked.height.zero? ? SHAPE_EDGE : walked.edge)
            end
            _spend_paths!(allowance, walked.paths)
            return walked
          end

          # The same inequality with a height not yet known: descending checks each level as it is reached, so a
          # shape walked rather than reused is judged by its own position and its subtree by theirs.
          _raise_graph_too_deep!(via, via_name, edge: SHAPE_EDGE) if walk.depth > Internal::ShapeGraph::MAX_NESTING

          # Read as SUPPLIED, so a shape that names no members is told apart from one naming an empty list.
          members = Internal::ShapeGraph.declared_members(hash)
          _raise_missing_shape_members!(via, via_name) if nil.equal?(members)

          walked = Axn::Internal::CycleGuard.guard(hash, walk.seen, on_cycle: CYCLIC_SHAPE) do |nested|
            _check_and_copy_shape_members!(hash, members, walk.with(seen: nested), allowance)
          end
          _raise_cyclic_graph!(via, via_name, edge: SHAPE_EDGE) if CYCLIC_SHAPE.equal?(walked)

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
          edge = SHAPE_EDGE
          copied = keyed.map do |member, name, key|
            # Charged BEFORE this member is snapshotted, and before its nested shape is walked, so a graph that
            # multiplies out is rejected while the work done on it is still bounded by the allowance.
            _spend_paths!(allowance, 1)
            paths += 1
            # `validations` is read ONCE and threaded to every use — the nested shape to walk, and the snapshot
            # of this member. A second read is a second answer the caller can give.
            validations = _symbol_keyed_member_validations(member, name, key)
            _raise_member_without_validations!(member, name) if nil.equal?(validations)
            # Every other attribute read (and grammar-checked) BEFORE the nested walk, so a member carrying both
            # a bad `sensitive:` and an untraversable nested shape is reported as the value defect it is.
            attributes = _snapshot_member_attributes!(member, name, key, validations)
            shaped = _snapshot_member_shape!(validations, member, name, child, allowance)
            # The member's OTHER kind of child. `_symbol_keyed_member_validations` canonicalized the member's
            # own `of:` exactly as `_parse_field_validations` does a field's — one rung — and this is where the
            # rest of the chain is descended, off the same walk state the nested `shape:` above used, so both
            # edges spend one depth budget and one path allowance rather than one each. This is the pass that
            # knows where the member SITS, and so the only one whose depth verdict is the real one (see
            # `_walk_declared_inner_contracts!`).
            walked_of = _walk_inner_contracts!(validations, child, allowance, fields: [key], via: member, via_name: name)
            both = _combine_inner_contracts(shaped, walked_of)
            paths += both.paths
            if both.height > height
              height = both.height
              edge = both.edge
            end
            ShapeConfig.new(**attributes)
          end

          WalkedShape.new(copy: Internal::ShapeGraph.snapshot_node(hash, copied), paths:, height:, edge:)
        end

        # A shape MEMBER's own nested `shape:`, walked and snapshotted — the member-position twin of
        # `_snapshot_inner_shape!`, reporting in the same currencies so a member's two edges fold into one total
        # exactly as a bag's two do.
        def _snapshot_member_shape!(validations, member, name, walk, allowance)
          _reject_unshaped_shape!(validations, "`shape:` on shape member #{_describe_shape_member(member, name)}")
          nested = Internal::ShapeGraph.hash_or_nil(validations[:shape])
          return NO_INNER_CONTRACTS if nil.equal?(nested)

          # A DISTRIBUTING member's shape is judged one level lower than the member, for the reason
          # `_distributing_shape_depth` gives — the same offset the field path applies to its own, and the
          # levels below it are what that offset has to reach.
          depth = _distributing_shape_depth(validations, walk.depth)
          inner = _walk_shape_graph!(nested, walk.with(depth:), allowance, via: member, via_name: name)
          validations[:shape] = inner.copy
          # The field path's own derivation and check, called from where the walk already is, so a NESTED shape
          # is held to exactly what a field's `shape:` is held to — at every level, since this runs on each
          # member the walk descends through. Without it a hand-written nested `shape:` (the natural spelling
          # for a raw member) reached ShapeValidator with a nil container and failed EVERY call with a bare
          # `TypeError: class or module required`, naming neither the member nor the option, while the block
          # form derived one and worked; a nested `container:` that is not a class did the same.
          #
          # AFTER the walk, matching the field path's own order (`expects` snapshots the graph, then
          # `_parse_field_validations` derives), and after the copy is stored so what is derived onto is axn's
          # own node. A container belongs to the POSITION rather than to the node — it comes from the enclosing
          # member's `type:`, exactly as a field's comes from the field's — so it is resolved per REFERENCE: the
          # walk's memo hands two members sharing one nested shape the same copy, and
          # `_derive_raw_shape_container!` detaches before it writes, so a shape reused under `type: Hash` and
          # under `type: Array` stores the right container in each place rather than the last one walked.
          # Deriving BEFORE the walk instead would defeat that memo outright (a fresh detached node per
          # reference is a fresh identity), which is what keeps a shared sub-shape from costing 2^depth walks.
          # A DISTRIBUTING member's container is derived here and derived again by the fold, which is where its
          # position — and so what its members are read off — actually settles.
          _derive_raw_shape_container!(validations)
          # The levels this member's shape adds below the member: the shape node itself, plus the `of:` rung the
          # fold puts above it where the shape distributes.
          WalkedContracts.new(paths: inner.paths, height: inner.height + 1 + (depth - walk.depth),
                              edge: inner.height.zero? ? SHAPE_EDGE : inner.edge)
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

        # A declaration graph that contains itself has no traversal at all: every walk over it — this one, the
        # runtime validator's, the schema's — recurses until the stack overflows, and SystemStackError is
        # outside StandardError, so it escapes every rescue in the framework rather than settling into a
        # reported failure. Rejected at declaration, where it is knowable and where the author is present.
        def _raise_cyclic_graph!(member, name, edge:)
          via = nil.equal?(member) ? "" : " reached from shape member #{_describe_shape_member(member, name)}"
          raise ArgumentError, _cyclic_graph_message(via, edge)
        end

        def _cyclic_graph_message(via, edge)
          if edge == INNER_CONTRACT_EDGE
            return "an `of:` graph cannot contain itself — the nested `of:` bag#{via} is the same bag it is " \
                   "nested inside, so validating or reflecting it would recurse until the stack overflows. " \
                   "Give the nested `of:` contents of its own rather than reusing the bag that encloses it."
          end

          "a `shape:` graph cannot contain itself — the nested shape#{via} is the same shape it is nested " \
            "inside, so validating or reflecting it would recurse until the stack overflows. Give the nested " \
            "shape its own members rather than reusing the shape (or the member) that encloses it."
        end

        # The generative counterpart: no object repeats, so nothing identifies a loop, and the graph is
        # simply endless. Capped rather than walked to exhaustion, for the same reason a cycle is rejected
        # — the alternative outcome is a SystemStackError raised while the class is being defined, which
        # no rescue in the framework can settle.
        def _raise_graph_too_deep!(member, name, edge:)
          via = nil.equal?(member) ? "" : " at shape member #{_describe_shape_member(member, name)}"
          raise ArgumentError, _graph_too_deep_message(via, edge)
        end

        def _graph_too_deep_message(via, edge)
          if edge == INNER_CONTRACT_EDGE
            return "an `of:` graph nested more than #{Internal::ShapeGraph::MAX_NESTING} levels deep#{via} is " \
                   "almost certainly generated rather than declared — no hand-written declaration nests " \
                   "containers that far, while a bag that builds a fresh nested bag on every read is endless " \
                   "and would recurse until the stack overflows. Flatten the nesting, or have the declaration " \
                   "give back the same finite nested bag each time it is read."
          end

          "a `shape:` graph nested more than #{Internal::ShapeGraph::MAX_NESTING} levels deep#{via} is almost certainly " \
            "generated rather than declared — no hand-written shape block reaches that depth, while a shape " \
            "object that builds a fresh nested shape on every read is endless and would recurse until the " \
            "stack overflows. Have the shape return the same finite nested shape each time it is read, or " \
            "flatten the nesting."
        end

        # A member's declared validations, canonical at every level its grammar has: the validator names, each
        # validator's own option bag (see _symbolize_option_bags!, which does the same for a field), and each
        # axn validator's shorthand VALUE (see _canonicalize_validator_options!, likewise). A raw `shape:` member
        # bypasses `expects`' option handling entirely, so this is the one place its grammar gets canonicalized
        # — and it must, because what the snapshot stores is a plain Hash: a member declared with String keys
        # otherwise validated nothing at all, silently, and reflected an empty constraint beside it, while one
        # declared `type: Hash` (the spelling every author writes) failed every call with `must supply :klass`.
        def _symbol_keyed_member_validations(member, name, key)
          validations = Internal::ShapeGraph.hash_or_nil(Internal::ShapeGraph.read(member, :validations))
          return nil if nil.equal?(validations)

          Internal::ShapeGraph.reject_defaulting_option_container!(validations) { "the validations of #{_member_owner_label(member, name)}" }
          # A Hash axn owns, ALWAYS — canonicalized and copied in one pass. "Needs no key change" and "needs no
          # copy" are different questions, and answering only the first left a member's options aliased to the
          # objects the caller still held while a top-level field's were detached: mutating an `inclusion:` list
          # afterwards widened a declared member's enum. The copy is also what the snapshot stores, so it is one
          # allocation rather than two.
          copy = {}
          Internal::ShapeGraph.each_entry(validations) do |option_key, value|
            canonical = case option_key
                        when ::String then option_key.to_sym
                        else option_key
                        end
            _raise_ambiguous_option_key!("the validations of #{_member_owner_label(member, name)}", canonical) if copy.key?(canonical)

            copy[canonical] = value
          end
          # The bag's own KEYS, held to the member grammar before anything reads a value out of it — the field
          # path's own order (`_partition_field_options` rejects an unknown key ahead of `_symbolize_option_bags!`),
          # and the block form's (`_build_shape_member` names a refused option before parsing anything). Without
          # it a typo, or a field-level option in a member bag, declared cleanly and raised `Unknown validator:
          # 'TpyeValidator'` on every call. Runs at every level the walk reaches, since it sits in the per-member
          # loop the recursion runs at each node.
          _check_member_option_keys!(name, copy)
          # Each bag's own keys, then the containers themselves, then each axn validator's shorthand and the
          # guards that read what it expanded — through the same three helpers a field's options go through, in
          # the same order, so a member is held to exactly what a field is held to: an `inclusion:` list keeps
          # its class, a container that answers with code of its own is refused unless it is frozen, `type: Hash`
          # means what it says, and an `of:` that constrains nothing is refused instead of ignored.
          #
          # Canonicalizing runs after both, as it does for a field, and that order is load-bearing at one end: an
          # expander reads a bag by Symbol, so a String-keyed one has to be canonical first
          # (`validate: { "with" => … }` is otherwise a Hash carrying no callable, rejected at declaration for
          # a callable it does supply). What an expander then builds on top is a Hash axn owns, holding values
          # the detach pass has already copied. `model:` is refused rather than expanded, under whichever key
          # spelling declared it, which is why that check sits between the two.
          #
          # Expansion and the checks over what it produced are ONE call deliberately: a member that expanded
          # like a field and validated like nothing is exactly how the `of:` pair went missing here the first
          # time, when the expansion alone was extracted from `_parse_field_validations`.
          _symbolize_option_bags!(copy)
          Internal::ShapeGraph.detach_option_containers!(copy)
          _raise_member_model_unsupported!(name) if copy.key?(:model)
          # Truthy, not key presence: `confirmation: false` is the same disabled-validator no-op it is on a
          # field (see Validation::Base.nil_tolerant_validation?), so it is left alone rather than refused.
          _raise_member_confirmation_unsupported!(name) if copy[:confirmation]
          _canonicalize_validator_options!(copy, [key])
          # A raw member never reaches `_parse_field_validations`, so this is where its entries are held to the
          # rule a field's are. The member's own BAG-level `on:` is refused earlier, by
          # `_check_member_option_keys!` above, with the reason particular to a member.
          _reject_validator_context_scope!(copy, where: "shape member `#{_shape_member_label(name)}`")
          # Last, where the block form checks it too (after the same canonicalization), so a declaration failing
          # both is reported by the same one on either route. A raw member's `coerce:` used to reach ActiveModel
          # as a validator (`Unknown validator: 'CoerceValidator'` on every call) while `type: { coerce: true }`
          # was accepted and silently did nothing — a member has no reader for a coerced value to land on.
          _reject_member_coerce!(copy)
          copy
        end

        def _member_owner_label(member, name) = "shape member #{_describe_shape_member(member, name)}"

        # `model:` resolves a record from an id and exposes a `<field>_id` companion reader — both live in the
        # reader/facade layer a reader-less member never routes through, so on a member it can only type-check
        # the element in place (what `type: Klass` already does) while implying resolution/companion behavior
        # that never happens. Rejected rather than accepted in that degenerate form, pointing at the plain
        # type check.
        #
        # Raised for a member declared BOTH ways: the block form checks the option it was handed
        # (`_build_shape_member`), and the declaration walk checks a raw member's bag before canonicalizing it
        # (`_symbol_keyed_member_validations`). The walk's check has to be there, and ahead of the
        # canonicalization, precisely because the shorthand expansion would otherwise make the option WORK — as
        # a silent type check, which is the option being reinterpreted rather than honored — where before it
        # failed every call with `must supply :klass`.
        #
        # The companion reader is named off the message-safe label too, so the `_id` name it reports is derived
        # from the same rendering of the member name the sentence already used.
        def _raise_member_model_unsupported!(name)
          label = _shape_member_label(name)
          raise ArgumentError,
                "shape member `#{label}` does not support model: — a model field resolves a record from an id " \
                "and exposes a `#{Internal::FieldConfig.model_id_key(label)}` reader, but a shape member is " \
                "reader-less and validates the element in place (use `type: Klass` for a plain instance check)."
        end

        # A confirmation pair's requiredness rule cannot be written for a shape member: the companion has to be
        # required only when the member itself is present, but a member's `if:`/`unless:` condition resolves
        # against the ACTION rather than the element (`ShapeValidator#validate_members_of` threads the action
        # down deliberately, so a member condition is action-scoped exactly like a top-level field's — never
        # element-scoped). A gate aimed at a sibling member therefore has nothing to call: the action has no
        # reader for it, so the gate raises NoMethodError on every call rather than skipping cleanly. Without a
        # gate the companion is either required when the member is absent (nothing supplied it) or never
        # enforced (the exact defect this option exists to fix) — neither is a shape-only variant worth
        # honoring, so the option is refused at declaration instead.
        #
        # Raised for a member declared BOTH ways, mirroring `_raise_member_model_unsupported!`: the block form
        # checks the option it was handed (`_build_shape_member`), and the declaration walk checks a raw
        # member's bag (`_symbol_keyed_member_validations`).
        def _raise_member_confirmation_unsupported!(name)
          label = _shape_member_label(name)
          raise ArgumentError,
                "shape member `#{label}` does not support confirmation: — the companion is required only when " \
                "the member is present, and a member's `if:` condition resolves against the action rather than " \
                "the element, so it cannot refer to a sibling member. Declare the pair as subfields " \
                "(`expects :#{label}, on: :<parent>`) to get the confirmation contract."
        end

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
          raise Axn::ContractViolation::DuplicateFieldError,
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
                :_member_owner_label, :_describe_shape_member, :_raise_member_model_unsupported!,
                :_raise_member_confirmation_unsupported!,
                :_snapshot_declared_shape!, :_validate_and_snapshot_shape!, :_walk_shape_graph!,
                :_distributing_shape_depth,
                :_reject_unshaped_shape!, :_inner_shape_position_label,
                :_walk_inner_contracts!, :_walk_declared_inner_contracts!, :_new_path_allowance,
                :_snapshot_inner_shape!, :_snapshot_member_shape!, :_combine_inner_contracts,
                :_check_and_copy_shape_members!, :_raise_cyclic_graph!, :_raise_graph_too_deep!,
                :_cyclic_graph_message, :_graph_too_deep_message,
                :_raise_duplicate_member!, :_raise_nameless_member!,
                :_raise_missing_shape_members!, :_raise_member_without_validations!
      end
    end
  end
end
