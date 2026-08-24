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

## An unsatisfiable projection satisfies a directional invariant vacuously

Reflection is documented as biased STRICTER than the runtime — schema-valid ⇒ runtime-valid
(`docs/reference/class.md`, `docs/recipes/authoring-tool-adapters.md`), with two documented looser exceptions.
A directional rule alone does not catch the worst kind of divergence, because a node admitting NO value is
maximally strict and therefore trivially "not looser".

`inclusion: { in: %w[a b] }` on a `type: Array` field emitted `{type: "array", enum: ["a","b"]}` — nothing is
both an array and the string `"a"` — while the runtime accepted `["a","b"]` by distributing the set over the
elements (ActiveModel's `Clusivity`). Every value the runtime accepted, the document rejected; the invariant
as written did not name it, because the schema was strict rather than loose.

So the invariant has a corollary: the projection of a satisfiable contract must itself be satisfiable. And the
fix ran the other way from the schema — the runtime moved to meet the document (PRO-3192's positional rule),
after which the emitted `enum` needed no change at all, and the spelling that produced the unsatisfiable node
is refused at declaration before any projection exists. When a node cannot be satisfied, suspect the two sides
disagree about what the validator TARGETS, not about how strict to be.

## …and a contract that admits nothing has no honest projection at all

The corollary above was written from one side: a satisfiable contract emitting an unsatisfiable node. The other side reaches the same place from a broken contract — the DECLARATION admits nothing, so there is no honest node to emit and whatever comes out is a document about a contract that does not exist.

Four spellings looked like one shape (PRO-3220): the admissible SIZES form an empty interval, a floor the declaration imposes sitting above a ceiling it also imposes. `absence:` on a typed field, a `length:` ceiling of 0, a `length:` naming `minimum: 3, maximum: 2`, and an `inclusion:` set every member of which the bounds exclude. Looking for the one axis is worth doing before writing the second detector of a family — but three of those four are on the size axis and the `absence:` one is not, which is the subject of the section below.

Three mechanics that made the single test possible, each an instance of a rule already stated here:

- **Both bounds come from the emitter's own derivations** (`Schema.declared_size_minimum` / `declared_size_maximum`), so what is refused is exactly the pair that would have been emitted. Those two took a `FieldConfig` and were pure functions of its `validations`; widening them to the bag is what let a declaration-time guard read them at all, and is cheaper than the parallel derivation that sank PRO-2877's pulled detectors.
- **A missing bound was a missing EMISSION first.** `absence:` names size 0 as the only admissible size and emitted nothing, which made the guard blind to it AND left `absence: true, allow_empty: true` advertising a node looser than its contract. Teaching the emitter fixed both — the guard's blindness and the projection defect were one gap seen from two sides.
- **The guard runs LAST in `_parse_field_validations`**, unlike every other guard there, which reads the author's own spelling. The floor it weighs is one axn itself installs (`_apply_default_presence!`), so it has to judge the settled bag — the same bag the emitter will read.

The stand-downs split along whether the emitted NODE survives, not whether the runtime does. A nil tolerance rescues, because the tolerated nil is a passing value and the node stays satisfiable through its null branch. An `if:`/`unless:` gate does not, because reflection is static-maximal and emits the gated bound anyway — so the runtime is satisfiable while the document is not, which is the original defect wearing a gate.

## A biased-stricter projection is not evidence about the contract

`absence:` rejects every non-blank value. On an `Array` that means size 0 exactly, so a `maxItems: 0` is its faithful projection. On a `String` it does not: ActiveSupport gives String its own `blank?`, under which `"  "` is blank and two characters long. Emitting `maxLength: 0` there is still *permissible* — it is biased stricter, the documented direction for reflection to err in — and PRO-3220 first shipped it that way.

The guard then read that ceiling back and used it to prove a contract unsatisfiable, which refused `type: String, presence: false, absence: true, length: { minimum: 1 }` — a contract satisfied by every whitespace-only String. Two rules collided and only one of them can bend:

- a PROJECTION may be stricter than the runtime, because a caller who obeys it is still correct;
- a GUARD may not, because over-restriction rejects a legal declaration, and there is no recovery from a declaration that will not declare.

So an approximation loses its licence the moment a guard reads it as fact. Where a guard must lean on a projected bound, the bound has to be EXACT on the axis being judged, or the guard stands down. The fix split the family in two: `presence:` ∧ `absence:` is a blank-axis contradiction, exact at every type and needing no size reasoning at all, while the size rule keeps only the bounds that really are about size — which meant withdrawing the String ceiling from the emitter as well, since a bound no guard may trust is one worth asking whether to emit at all.

The same distinction settles gates in opposite directions in the two rules, and the test is *authored or inferred*, not *conditional or not*. Whichever way a rule resolves, ask it of EFFECTIVE gates (`Base.entry_effectively_gated?`) rather than of each entry's own (`entry_self_gated?`): a declaration-level `if:` is nobody's own gate and stops every check in the declaration regardless, so a rule asking "does this run on every call" that consults only nested gates is wrong on the commonest spelling. A `length:` ceiling is a size constraint the author wrote, so it is emitted as written whatever gates it, and the size rule counts it static-maximally. A size meaning for `absence:` is one axn infers, so it may only be inferred from a check that always runs — `presence: { unless: :archived }, absence: { if: :archived }` is a working contract, and a `maxItems: 0` derived from its conditional half would describe a document the contract does not carry on the calls where the gate is closed.

## Four review rounds, one class: shape read where effect was the question

PRO-3220's guard drew a finding in each of four rounds, and every one was the same mistake wearing different clothes — a declaration's SHAPE consulted where its EFFECT at runtime was the question:

| read | should have read |
|---|---|
| `value.size` | `value.length` — what `LengthValidator` measures |
| an emitted `maxLength: 0` | nothing; it was a biased-stricter approximation, not a fact |
| `entry_self_gated?` | `entry_effectively_gated?` — a declaration gate skips the entry too |
| two of three measurement routes | all three: `length`, `empty?`, `blank?` |
| "a `presence:` entry exists" | "a `presence:` entry rejects something" — a blank-tolerant one does not |
| a member's own size | its size AND whether its `==` decides what it matches |

Six hand-written fixes, each one round apart, and the count was not falling. What ended it was not a seventh fix: it was **enumerating the product and measuring it against the real runtime**. The soundness invariant is mechanical — *if the guard refuses, no value passes* — so it can be checked rather than argued: build every combination of floor × ceiling × set × modifier × type, build each one again with the guard stubbed off on that one class, and run axn's own validation over a candidate spread.

The product must span every axis the guard reads, and getting that wrong is the failure mode to expect — it happened twice. The first cut carried a gated `absence:` but no gated `length:` or `inclusion:`, and the next round reported a case in exactly the column it had left out. The cut after that added singleton-bearing members but wired one to a value the CANDIDATE spread did not contain, so the cell existed and still proved nothing: an over-restriction is only observable when some candidate actually passes. Derive the axes from what the guard consults, then check each new axis by inverse mutation — a cell that does not fail when you break the fix it was added for is decoration.

Even so it found a twenty-five-cell hole no round had reported (a declaration-level `if:` suspends the entire contract, so every value passes, while the size rule never consulted gates at all), and it is now `spec/axn/core/validations/unsatisfiable_size_soundness_spec.rb`. Two inverse mutations confirm it bites: remove the declaration-gate stand-down and all five examples fail; remove the blank-tolerant-presence test and four do.

Three transferable rules:

- **A declaration-time guard has one asymmetric failure mode.** Refusing a legal declaration cannot be recovered from — there is no runtime left to correct it — while admitting a broken one merely leaves it broken. So the invariant worth checking mechanically is soundness (*refuses ⇒ unsatisfiable*), not completeness, and every stand-down is cheap.
- **Measure against the runtime, not against a second model of it.** The stub-the-guard-and-run-it trick works for any guard that blocks its own construction, and it is what makes "does anything pass" an observation rather than a claim.
- **A list derived from one side of a question goes stale the moment you add the other side.** The methods a member must answer natively were enumerated from the checks that hold a FLOOR (`length`, `blank?`, `empty?`). The same PR then taught `absence:` to name a CEILING — `absence:` asks `present?` — and did not revisit the list, so a member answering `present? => false` was weighed against a ceiling it does not obey. Adding a bound means re-asking every question that was answered "for the bounds we have".
- **A soundness probe's candidate spread must hold only HONEST values, while its declared literals need not.** The two are not symmetric: a candidate whose `blank?`/`present?` is its own satisfies contracts that admit nothing on any ordinary value, so one in the spread reports every correct refusal as an over-restriction (measured — it did). A set MEMBER carrying a singleton is fair game, because the author named that object and the guard holds it. Where the only witness would BE the lying object, the case belongs in a targeted spec with an explicit runtime control, not in the product.
- **When round N rhymes with round N−1, the next artifact is a product probe, not another fix.** Same conclusion as PRO-2883's malformed-input matrix and PRO-2995's derive-don't-enumerate specs; this is the third time, which is the point at which the rule should be reached for first rather than last.

## `presence:` and `absence:` are complements by ActiveSupport, not by ActiveModel

Worth knowing before reasoning about the pair: they are not spelled against the same predicate. `PresenceValidator` errors `if value.blank?`; `AbsenceValidator` errors `if value.present?` (activemodel 8.1.3.1). What makes them complements is ActiveSupport's `Object#present?` being defined as `!blank?`, plus every core class it specializes defining the pair together — measured, `Array`, `Hash`, `String`, `Symbol`, `Numeric`, `Time`, `NilClass`, `TrueClass` and `FalseClass` all own both.

So a class overriding one and not the other escapes the complement, and it escapes in a direction the override does not suggest: `Array#present?` is its own `!empty?` rather than a call to `blank?`, so a subclass answering `blank? => true` with contents is still `present?` — it fails an `absence:`, exactly as a plain non-empty Array does. Only overriding `present?` itself divides the pair.

That is an assumption about VALUES, and a declaration-time guard cannot check it: a declared `type:` admits every subclass, and nothing at declaration sees what will arrive. It is also not any one guard's assumption — the `minItems: 1` reflection emits for a bare `presence:` is unsound against the same object. Where a rule rests on it, say so at the rule and move on; the alternative is deleting every size and requiredness derivation in the layer.
