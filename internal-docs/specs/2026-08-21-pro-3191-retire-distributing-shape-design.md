# Retire the distributing `shape:` on `type: Array`

Ticket: https://linear.app/teamshares/issue/PRO-3191/axn-retire-the-distributing-shape-on-type-array

Predecessor: https://linear.app/teamshares/issue/PRO-3166/axn-recursive-of-containers-inside-containers (`internal-docs/specs/2026-08-19-recursive-of-design.md`)

## Problem

`shape:` has one rule and one exception. On `type: Hash`, a `Data`/`Struct`, or a plain class it names *that value's* members. On `type: Array` it names *each element's* members — it distributes. The exception existed only because `of:` could name an element's class but not its members, so `shape:` had to reach through.

PRO-3166 gave `of:` that word recursively and, as part of landing it, **canonicalized the flat spelling forward at declaration**: `expects :rows, type: Array, of: Hash, shape: S` is stored as `of: { klass: Hash, container: Array, shape: { members: …, container: Hash } }` with no top-level `shape:`. Every descent seam (the declaration walk, redaction, ambient context, reflection) already reads only the nested form. Probed at `5e309e17` (the branch base): the stored graph already carries one contract shape. What was left was purely the accepted *surface* — the raw kwarg still declared, and canonicalization silently rewrote it.

## The rule

A raw `shape:` kwarg is refused when it asks to distribute — either of:

* **(a)** it sits beside a `type:` naming `Array` (single, not a union), or
* **(b)** it hand-writes `container: Array` itself, regardless of the enclosing `type:`.

(a) is the ticket's headline change. (b) was found while implementing: `expects :row, type: Hash, shape: { container: Array, members: [<sku, type: String>] } }` declared cleanly, published `required: ["sku"]` in the schema, and accepted `{ row: { sku: 123 } }` at runtime — `ShapeValidator` reads `container: Array` as "distribute over the elements" rather than as a gate, so its non-Array branch (which checks members) never ran. This is the same defect `_reject_distributing_inner_shape!` already closes at `of:`-bag positions (PRO-3166); (b) completes that class at field/member positions. (b) is checkable with no provenance marker precisely *because* (a) is refused: once `type: Array` + a raw `shape:` raises, the only remaining producer of a shape carrying `container: Array` is the block form's `_build_shape` (`contract.rb:1392`), so a **raw** shape naming it is always the hand-written divergence.

The block form is unaffected by either condition. An Array has no members of its own, so `type: Array, of: Hash do … end` has exactly one honest reading — there is no other spelling for an array's elements, and it is the one the docs teach.

## Where the guard sits

A raw `shape:` kwarg can be written at exactly four positions. One helper, `_reject_distributing_shape!(carrier, where)` (`shape_declaration.rb`), is called from all four — modelled on the existing `_reject_unshaped_shape!`, with the same `where`-built-by-the-caller convention, since only the caller knows which position it is.

| # | Position | Call site | Why the ordering matters |
| -- | -- | -- | -- |
| 1 | field (`expects`) | Right after `_partition_field_options`, before `_build_shape` | A block legitimately writes `container: Array`; the guard must see the caller's raw slot, not what the block replaces it with |
| 2 | field (`exposes`) | Same position | Same reason |
| 3 | member declared in a block, itself carrying a raw `shape:` kwarg (`field :rows, type: Array, shape: {…}`) | Inside `_build_shape_member`, before its own `_build_shape` call (for a subblock) | Same reason, one level down |
| 4 | member supplied as a duck-typed object inside a raw `shape: { members: [...] }` list | `_snapshot_member_shape!`, before `_reject_unshaped_shape!` | This is where a raw member's own `:shape` is first read — no separate pre-pass exists for it |

Position 4 never sees a **block-built** member's distributing shape: `_build_shape_member`'s own call to `_parse_field_configs` folds a subblock's shape into the member's `of:` bag during that member's pre-pass (depth 0), before the member is ever handed to the outer walk — verified by probe for `of: Hash`, no `of:`, and two levels deep. So positions 3 and 4 are not overlapping cases of the same spelling; 3 catches a raw kwarg that a *sibling* block would otherwise silently discard, 4 catches every other raw-member route.

Both conditions are checked in one function, (a) unconditionally (it only needs `type:`), (b) only once the shape is confirmed to be a Hash — a non-Hash `shape:` is `_reject_unshaped_shape!`'s defect to report, so (b) stands down rather than raising a less specific error first.

## Dead code the flip retires

With positions 3 and 4 closed, a shape *member's* own validations bag can never be distributing by the time `_snapshot_member_shape!` reaches it. Two branches that existed only for that case were removed outright (pre-alpha tombstone convention):

* `depth = _distributing_shape_depth(validations, walk.depth)` — always equalled `walk.depth`
* `rungs = _distributing_shape?(validations) ? 2 : 1` — always equalled `1`

Proven dead rather than assumed: a pure block-form distributing chain (`type: Array do field :m, type: Array do … end end`, repeated) was probed against the branch base and the PRO-3191 branch and produced byte-identical depth-cap behavior (31 levels legal, 32 raises) in both, and a Hash-chain baseline (64 legal, 65 raises) matched too — confirming the removed branches never charged anything a block-form declaration could reach.

One test in `canonical_storage_spec.rb` ("charges a reused DISTRIBUTING member shape its two rungs") tested exactly this removed path via identity-shared raw members. It was deleted rather than converted: the scenario it tested — a distributing member's shape referenced by two sibling members via object identity — can no longer be constructed by *any* legal declaration. The raw route is refused outright; the block route always allocates a fresh Hash per declaration site (`_build_shape` returns `{ members:, container: }` freshly each call), so no two block-declared positions can ever share the same underlying object.

## Message design

Two messages off the one helper, since the two conditions have different fixes:

* **(a)**: names the retired reading, then offers both surviving spellings — the `of:` bag (`of: { klass: Hash, shape: { members: [...] } }`, or `of: { shape: { members: [...] } }` with the class left open) and the block form.
* **(b)**: names what `ShapeValidator` actually does with `container: Array` and why that makes the declaration self-contradictory, then says to drop `container:` and let it derive from `type:`.

Neither message interpolates the caller's `of:` value — at positions 1–3 it is still the caller's un-canonicalized value (bare class vs. bag), and the nested spelling is not always available for it (`of: { klass: String, shape: … }` and `of: { klass: Array, shape: … }` both raise for unrelated reasons). Illustrative literals only, matching `_reject_distributing_inner_shape!`'s own style.

## What stays exactly as it was

* Every block-form declaration — verified byte-identical (stored `validations` *and* `input_schema`) against the branch base for: `type: Array, of: Hash do … end`, `type: Array do … end` (no `of:`), `type: Array, of: String do … end`, `type: Array, of: Array do … end`, `of: { klass: Hash, shape: … }`, and `type: Hash, of: { values: … } do … end` (the Hash exemption).
* `type: Hash`/`Data`/`Struct`/plain-class `shape:` with no explicit `container:` — unaffected by either condition.
* Downstream: swept `axn-mcp`, `axn-openapi`, `axn-ruby_llm`, `axn-webhooks`, `data_shifter`, `slack_sender`, `os-app`, `buyout-app`, `invoice-app`, `teamshares-rails` for the raw flat spelling and for direct reads of `config.validations[:shape]`. Found neither — every `shape:` usage in the sibling gems is the block form.

## Testing

The failure grid lives in `spec/axn/core/validations/shape_contracts_spec.rb`, under `"retiring the distributing shape: (PRO-3191)"` — every refused spelling from the rule above, plus a "what still declares" positive-control group so the guard is proven not to over-fire on the surviving spellings. Thirty pre-existing flat-spelling declarations across eight spec files were rewritten to the bag or block form they now must use; three tests whose entire premise was the retired spelling's depth/identity-sharing behavior were either converted to refusal assertions or (the one case with no surviving analog) deleted with a comment recording why.

Both conditions were mutation-audited: disabling (a) or (b) in turn fails specific specs (3 and 3 respectively) and no others; disabling neither and instead moving the guard to fire *after* the block-build in `expects` breaks 11 legitimate block-form specs, confirming the ordering constraint is load-bearing rather than incidental.
