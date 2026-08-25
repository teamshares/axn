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
| the floor-holding checks' methods | every BOUND-holding check's: `length`, `empty?`, `blank?`, `present?` |
| the measurement a check names | the measurement it PERFORMS — `length:` reads `respond_to?(:length) ? length : to_s.length`, so the capability probe is part of it and `respond_to?` belongs on the list beside the four |
| "a `presence:` entry exists" | "a `presence:` entry rejects something" — a blank-tolerant one does not |
| a member's own size | its size AND whether its `==` decides what it matches |
| a member's exact class | its class AND the owner of the `==` that will run — a singleton is invisible to a class check |
| "an `inclusion:` set" | which CONTAINER, and whose `include?` — only Array's own dispatches `member ==` |
| every declared type token alike | only the SIZE-BEARING ones; a token carrying no size must not veto a bound |
| the field path's guards | every route into a contract, the raw `ShapeConfig` member's included |

A dozen hand-written fixes, each a round apart, and the count was not falling. What ended it was not a seventh fix: it was **enumerating the product and measuring it against the real runtime**. The soundness invariant is mechanical — *if the guard refuses, no value passes* — so it can be checked rather than argued: build every combination of floor × ceiling × set × modifier × type, build each one again with the guard stubbed off on that one class, and run axn's own validation over a candidate spread.

The product must span every axis the guard reads, and getting that wrong is the failure mode to expect — it happened twice. The first cut carried a gated `absence:` but no gated `length:` or `inclusion:`, and the next round reported a case in exactly the column it had left out. The cut after that added singleton-bearing members but wired one to a value the CANDIDATE spread did not contain, so the cell existed and still proved nothing: an over-restriction is only observable when some candidate actually passes. Derive the axes from what the guard consults, then check each new axis by inverse mutation — a cell that does not fail when you break the fix it was added for is decoration.

Even so it found a twenty-five-cell hole no round had reported (a declaration-level `if:` suspends the entire contract, so every value passes, while the size rule never consulted gates at all), and it is now `spec/axn/core/validations/unsatisfiable_size_soundness_spec.rb`. Two inverse mutations confirm it bites: remove the declaration-gate stand-down and all five examples fail; remove the blank-tolerant-presence test and four do.

Three transferable rules:

- **A declaration-time guard has one asymmetric failure mode.** Refusing a legal declaration cannot be recovered from — there is no runtime left to correct it — while admitting a broken one merely leaves it broken. So the invariant worth checking mechanically is soundness (*refuses ⇒ unsatisfiable*), not completeness, and every stand-down is cheap.
- **Measure against the runtime, not against a second model of it.** The stub-the-guard-and-run-it trick works for any guard that blocks its own construction, and it is what makes "does anything pass" an observation rather than a claim.
- **A list derived from one side of a question goes stale the moment you add the other side.** The methods a member must answer natively were enumerated from the checks that hold a FLOOR (`length`, `blank?`, `empty?`). The same PR then taught `absence:` to name a CEILING — `absence:` asks `present?` — and did not revisit the list, so a member answering `present? => false` was weighed against a ceiling it does not obey. Adding a bound means re-asking every question that was answered "for the bounds we have".
- **A list of measurements is not a list of what a check dispatches.** The same list went stale a second time in the other direction: it named the four methods that MEASURE and not the `respond_to?` each check runs first to choose among them. `LengthValidator` measures `value.respond_to?(:length) ? value.length : value.to_s.length`, so an exact `Array` answering `false` there is measured by its rendering — `"[]"`, two characters — and clears a floor of 2 that `Array#length`'s zero fails. Reading a validator's source for the method it measures with is half the read; the branch that selects it counts too, and a capability probe the caller can answer is as much of the measurement as the measurement. Note the asymmetry it creates with axn's own checks, which bind `Object#respond_to?` so the caller cannot answer for them (`NonEmptinessValidator::CAPABILITY_CHECK`): where a bound is ActiveModel's, the guard must model ActiveModel's dispatch, not axn's hardening of the same question.
- **A soundness probe's candidate spread must hold only HONEST values, while its declared literals need not.** The two are not symmetric: a candidate whose `blank?`/`present?` is its own satisfies contracts that admit nothing on any ordinary value, so one in the spread reports every correct refusal as an over-restriction (measured — it did). A set MEMBER carrying a singleton is fair game, because the author named that object and the guard holds it. Where the only witness would BE the lying object, the case belongs in a targeted spec with an explicit runtime control, not in the product.
- **When round N rhymes with round N−1, the next artifact is a product probe, not another fix.** Same conclusion as PRO-2883's malformed-input matrix and PRO-2995's derive-don't-enumerate specs; this is the third time, which is the point at which the rule should be reached for first rather than last.

## A projection can be unsatisfiable, or it can PROMISE what the runtime refuses

The corollary this file already carries reads one way: the projection of a satisfiable contract must itself be satisfiable, and an unsatisfiable node is the emitter and runtime disagreeing. The disagreement has a second direction, and it is the one that reached production code here: a SATISFIABLE node for a contract that admits nothing.

`length: { is: 2, maximum: 1 }` declared cleanly and emitted `{minItems: 2, maxItems: 2}`, so the schema told every caller that a two-element array was acceptable while ActiveModel rejected values of every length. The cause was reading the interval as `is: || minimum:` and `is: || maximum:`, when `LengthValidator` iterates its CHECKS and adds an error for each that fails — `is:` does not replace a bound beside it, both run. The effective floor is the LARGEST lower bound declared and the ceiling the SMALLEST upper one.

Two things worth carrying forward:

- **"Which bound wins" is a question about the VALIDATOR's loop, not about which option is more specific.** `is:` reads like it supersedes a range, and in most schema languages it would. Read the validator's iteration before deciding that one option subsumes another; the derivation had been correct for every single-bound spelling, which is why nothing caught it.
- **Check both directions of the projection invariant.** A guard built to prevent unsatisfiable emissions will not notice that it is emitting a satisfiable node for an impossible contract — the failure is invisible to a probe that only asks "does anything the schema allows get rejected at declaration". Ask the mirror: for a contract nothing satisfies, does the projection say so? `Float::INFINITY` is the case that tells you the derivation understands the difference — it is ActiveModel's spelling for "no ceiling", so it must LOSE to a real bound rather than making the pair unverifiable.

## A shared type reader cannot carry a gate policy, because the rules disagree about gates

Three declaration guards read the declared `type:` to rule values OUT: a set no value of the type could match, a forbidden set no value of the type could be, and a member the size bounds exclude. So a `type:` check that does not run rules nothing out — `type: { klass: Array, if: -> { false } }, presence: false, length: { minimum: 3 }, inclusion: { in: ["abc"] }` is satisfied by `"abc"` on every call, because the closed gate admits the String, the set contains it, and its length clears the floor. All three refused it.

The fix belongs in the shared reader (`_judgeable_type_klasses`), and the reader must ask for the entry's OWN gate. Reaching for `entry_effectively_gated?` there — normally the right reader, and the one this PR's size rules use — broke two pinned examples immediately, which is how the distinction got found:

- **Gating the SET leaves the type live**, so the set is unreadable whichever way the gate falls: closed the check enforces nothing, open it rejects everything. The value-constraint and vacuity rules refuse that, deliberately.
- **Gating the TYPE leaves the set live and WIDENS what can arrive**, so the declaration means something on exactly the calls where the gate is closed. Stand down.
- **A gate on the whole DECLARATION reaches both**, so it creates no asymmetry between them — and the three rules answer it in opposite directions on purpose (the size rules stand down; the value-constraint and vacuity rules refuse). An effective-gate read collapses that into one policy and imposes whichever rule wrote the reader.

`entry_self_gated?` is usually the wrong reader — it answers "skippable independently of its siblings", which is not "does this bound always hold". Here that IS the question, and it is worth recognising the shape: **when a guard reads entry A to constrain what entry B can mean, the gate question is about the ASYMMETRY between A and B, not about either one's absolute skippability.** A shared gate cancels; a gate on one side does not.

Corollary for the surrounding audit: the reported spelling was refused by TWO guards independently — this PR's size rule and PRO-3192's value-constraint rule — so fixing only the reported one leaves the declaration refused and looks like a fix. Isolate which guards own a reported over-refusal by stubbing each off in turn before deciding scope.

## Deriving a guard from the emitter inherits the emitter's dispatches

Two rules in this file pull in opposite directions and one round landed exactly between them. A guard must derive from what its consumer emits rather than re-predict it (the first section above); and a guard must run none of the caller's code, because a token that answers for itself decides the verdict and one that raises replaces it. Routing the blank axis's "can this token's branch carry a size at all" through the emitter's own `single_type_for` satisfied the first and broke the second: that function asked the token `== :boolean` five times, `is_a?(Class)`, `< Numeric`, `<= Complex`, and `TYPE_MAP.key?(token)` — which hashes the token and compares it with `eql?`. An `Array` subclass with a singleton `hash` could not be declared.

The reconciliation is not to choose: it is to make the shared function native, so both readers get the same answer and neither runs the token. Identity (`Identity.same?`) for `==` against a known token, `Identity.kind?` for `is_a?`, `NativeMethods.includes_module?` for `<`/`<=`/`>=`, and an identity scan of the emitter's own maps for a `Hash#key?`. The maps are ten frozen core-class keys, so the scan costs nothing worth measuring, and the answers are identical for every token that defines none of those methods — which is every token a declaration means.

**A dispatch is fine in an emitter and not fine in a guard, so the boundary moves when a guard starts reading the emitter.** Reflection is allowed to run caller code where the dispatch IS the work; the moment a declaration guard reads the same function, every dispatch in it is on the deciding path. Before wiring a guard to a projection, read the projection for dispatches — not just for the answer it gives.

**Two related traps found in the same pass:**

- **A helper named for reading the method table can still compare with `==`.** `NativeMethods.includes_module?` read the ancestry natively and then asked `Array#include?`, which compares `element == other` — and the FIRST element of any class's ancestry is the class itself, so a class carrying its own `==` answered the membership question about itself. Three call sites pass a caller's declared token as the receiver. The fix is identity per element; the lesson is that "reads the table" is a claim about one of the two halves.
- **Measure the whole dispatch surface at once, not the method a round reported.** After three consecutive rounds of "the guard dispatches X on a declared token", the artifact that ended it was a probe that instruments a token with every method a declaration might call (`hash`, `eql?`, `==`, `is_a?`, `<`, `<=`, `>=`, `ancestors`, `inspect`, `name`, `respond_to?`, `to_s`) and tallies what each spelling actually invokes, run against HEAD and against the merge base. That distinguishes what a branch ADDED from what it inherited in one command, and it is what showed this PR's `absence:` path was the only spelling above base parity — and, after the fix, that it was back to it.

## `Kernel#Array` on a declared token, and why the sweep is not mechanical

A declared `type:`/`of:` token is a caller's own Class or Module, so reading it through `Kernel#Array` runs its `to_ary` and then its `to_a` — from a declaration guard, which is the one place reflection may run none of the caller's code. One that returns `[String]` waves an unsupported token through as a union of a real class; one that raises stops the class being defined. `ShapeGraph.type_tokens` is THE classification (`case`/`when ::Array`), read by the contract's guards, by `Validation::Base.type_admits_nil?` and by schema reflection, so the three cannot disagree about what one declaration names.

Two things are worth knowing before anyone finishes the job (PRO-3233 holds the rest — eleven further sites in `contract.rb`, fifteen in `schema.rb`):

- **Fixing one site relocates the failure rather than removing it.** Closing the dispatch in `type_admits_nil?` moved the raise on the same declaration from `nil_accepted?` to `_default_presence_applies?`, one guard later on the same `expects` call. So a per-site fix is only honest if it says which site it closed; the *declaration* is fixed when the path is.
- **The swap is not a rename, because the two disagree on a Hash.** `Array({a: 1})` is `[[:a, 1]]` — a two-element list of pairs — while `type_tokens` answers `[{a: 1}]`, one unsupported token. That is the wanted reading, but it changes the verdict of every site that asks `.empty?`, `.size == 1` or `.first` about a bag whose `klass:` is a Hash. Each of those needs its own reasoning and its own example; sweeping them together is how a thorough change goes wrong.

## `presence:` and `absence:` are complements by ActiveSupport, not by ActiveModel

Worth knowing before reasoning about the pair: they are not spelled against the same predicate. `PresenceValidator` errors `if value.blank?`; `AbsenceValidator` errors `if value.present?` (activemodel 8.1.3.1). What makes them complements is ActiveSupport's `Object#present?` being defined as `!blank?`, plus every core class it specializes defining the pair together — measured, `Array`, `Hash`, `String`, `Symbol`, `Numeric`, `Time`, `NilClass`, `TrueClass` and `FalseClass` all own both.

So a class overriding one and not the other escapes the complement, and it escapes in a direction the override does not suggest: `Array#present?` is its own `!empty?` rather than a call to `blank?`, so a subclass answering `blank? => true` with contents is still `present?` — it fails an `absence:`, exactly as a plain non-empty Array does. Only overriding `present?` itself divides the pair.

That is an assumption about VALUES, and a declaration-time guard cannot check it: a declared `type:` admits every subclass, and nothing at declaration sees what will arrive. It is also not any one guard's assumption — the `minItems: 1` reflection emits for a bare `presence:` is unsound against the same object. Where a rule rests on it, say so at the rule and move on; the alternative is deleting every size and requiredness derivation in the layer.

**The alternative is now measured, so it need not be argued again.** The same assumption carries the size axis, and by a route worth naming: `Array#==` compares CONTENTS, so an `Array` subclass with empty contents and a `length` of its own is MATCHED by the member `[]` and measured by ActiveModel as whatever it says — `type: Array, presence: false, length: { minimum: 3 }, inclusion: { in: [[]] }` is satisfied by `Class.new(Array) { def length = 3 }.new` and by no honest value. So a member's `==` being native does not make measuring the member evidence about the values it matches.

Honouring that candidate is not a narrowing of one branch. Across the guard's product it takes **22 of 76 refusals** with it, the two spellings the rule exists for included (`absence:` on a typed field, `length: { maximum: 0 }`) — because every size a declaration bounds can be answered by a value that measures itself. There is no version of a size rule that survives the standard.

And standing down is not the safe direction here, which is the usual reason to prefer it. With the branch off, that declaration EMITS `{type: "array", enum: [[]], minItems: 3}` — a node no document satisfies, which the directional-invariant rule forbids outright. **Weigh the two reachabilities, not just the two directions:** the over-refusal needs a value whose measurement contradicts its contents; the unsatisfiable emission reaches every consumer of the schema. When a stand-down would produce a forbidden projection, "under-restriction is recoverable" stops being the tiebreak.
