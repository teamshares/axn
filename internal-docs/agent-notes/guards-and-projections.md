# Guards and projections: case studies and mechanism

This file holds mechanism and case studies only. The rule each section backs is stated in
`AGENTS.md`; if you find yourself wanting to add a new rule here instead of there, put it in
`AGENTS.md` and link back.

## A guard derives from what its consumer emits; it never predicts it

When a check must agree with a projection — the property-name rules against
`Internal::Reflection::Schema`'s emitted properties, say — read the consumer's own output or call
the consumer's own decision (`Schema.shape_property_plan`, `Schema.build_input_for`), rather than
re-deriving the answer beside it.

A predictor is wrong in two directions at once and both are worse than a late diagnosis: it misses
what the consumer emits by a path the predictor doesn't know, and it *rejects legal declarations*
the consumer would never emit at all. SEVEN defects on one PR shared that root, and each
seam-by-seam fix generated the next one until every charge and claim was routed through the
emitter's own decision.

The last two were in a size BUDGET rather than a name check, which is the form to watch for: a
per-declaration charge predicts "this will emit a property", so it rejected a contract whose schema
names nothing — a config rooted at `on: :ambient_context`, a subfield under a parent that cannot
hold object properties, a `model:` route's own type on input. A budget spends on what the emitter
emits (`SubfieldTree`'s index and `path_blocked?`, `Schema.shape_property_plan`) or it is a
predictor with a number attached.

When a charge cannot be exact, know which way it errs and say so: UNDER-counting only loosens a
bound, while OVER-counting rejects a legal declaration. This is also why a check may legitimately
fire later than declaration: if only the emitted schema reveals a collision, the honest promise is
"before anything can consume it" (at app setup for tools, via `Axn::Tools.validate_contracts!`), not
"at declaration".

## Canonicalization obliges a re-audit of every guard on the raw form

Symbolizing keys, defaulting an absent list to `[]`, normalizing a name — each silently disarms any
downstream check that distinguished what you just erased. Three regressions on one PR:

- `[]`-for-absent hid `ShapeValidator`'s "must supply :members".
- String-keyed option bags hid `_reject_model_transform!`.
- String-keyed option bags made `FieldOptionality#optional?` answer `false` for a declared
  `allow_blank`, publishing a wrong `required` list that adapters build tool definitions from.

Enumerate the consumers of both forms in the same commit, and say which still fire.

## Returning the caller's object unchanged is an aliasing bug

A fast path skipping work because "nothing needs changing" answers a different question than
"nothing needs copying" — a declared contract must be axn's own, so mutating what the caller still
holds cannot change it retroactively.

One exception, and it is the same question answered rather than dodged: an option container that is
already FROZEN is stored as the caller's object (`Internal::ShapeGraph.detached_option_array`),
because "nothing can change it afterwards" is precisely the property the copy was buying — to the
same one-level depth, since a frozen container's elements are still the caller's objects, exactly as
a copy's are.

And a copy detaches only what it actually copies: `Kernel#dup` copies an Array's ELEMENTS while
sharing the instance variables and dropping the singleton class, so a container whose own code
answers from either is not detached by being copied, it is silently changed. (This is the same
`dup`/singleton-class mechanic detailed in `error-paths.md`'s "don't build a guard that depends on
foreign behaviour being honest" — the container copy there and this aliasing rule are two sides of
the same fact about `dup`.)
