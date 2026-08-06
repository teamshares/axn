# `forward!` — delegate to a sub-action, propagating its exposures (PRO-2941)

Ticket: https://linear.app/teamshares/issue/PRO-2941

`forward!` is a one-line instance helper for the "outer axn thinly delegates to a runtime-chosen inner axn" pattern. It collapses a documented three-line idiom, extends it to the `call!` shape that cannot use that idiom, and — because building it means touching the merge loop three separate places already implement — fixes a silent nil-clobber and a failure-swallowing raise that all three share.

Every behavioural claim below was verified by probe against this branch rather than inferred from the code.

## What is actually missing

The ticket frames this as "wrappers lose the child's exposures on the failure branch." That is true only for the `call!` shape. `docs/usage/writing.md:93-114` documents the facade pattern, and `expose(result)` already forwards a failed child's values:

```ruby
r = Child.call
expose(r)                  # forwards (child's declared exposures ∩ this action's exposes)
fail! unless r.ok?
# => ok?=false, event="E"  — the child's exposure survives its own failure, today
```

So the gap is narrower than the ticket states. What is missing is (a) sugar — PRO-2940 lists this exact three-line snippet under "Some pattern to DRY up delegation" — and (b) the `call!` shape, where the raise leaves `def call` before any `expose` can run, which is why those wrappers cannot collapse to a bare `call!`.

That narrower framing is the honest one, and it is what makes the design small: `forward!` is not new merge machinery, it is `expose(result)` plus outcome propagation.

## The linchpin holds

The design assumed a failed child result still carries the values it exposed before failing, and that the declared-exposure readers are callable on it. Both hold, on the `fail!` branch and on the exception branch:

```
child exposes :event, sets it, then fail!  →  result.event == "made-it",    outcome "failure"
child exposes :event, sets it, then raise  →  result.event == "before-boom", outcome "exception"
```

Nothing clears `exposed_data` on the way out, and `Result`'s generated readers work regardless of outcome.

## Surface

`forward!` is non-terminal and `call!`-shaped: it raises or fails the parent when the child fails, and on success merges the child's exposures, returns the child's `Result`, and lets the rest of `def call` run.

```ruby
class Dispatch
  include Axn
  expects :cap_table, :params
  exposes :event, :certificate

  def call
    forward! event_action_class            # => event_action_class.call(**inputs)
    # or: forward! event_action_class.call(cap_table:, x: y)
  end
end
```

Definitionally it is exactly the documented idiom, in one line:

```ruby
def forward!(target)
  result = target.is_a?(Class) ? target.call(**inputs) : target
  expose(result)
  _propagate_sub_result_outcome!(result)
  result
end
```

Terminal semantics were considered and rejected. Terminal plus success-message propagation would make the parent a pure passthrough, at which point the caller may as well invoke the inner action directly — a wrapper earns its keep with what it does *around* the delegation, and terminal deletes the "after" half of that. Non-terminal also keeps `forward!` a drop-in for the `call!` it replaces, and `done!` already covers "stop here". The bang is earned by the failure branch alone, exactly as `call!`'s is.

The parent does **not** inherit the child's success message; it keeps its own. Only the error path propagates.

### Dual signature

A `Class` argument is invoked as `klass.call(**inputs)`. Anything else is treated as an already-produced result and forwarded as-is. Detection is `arg.is_a?(Class)` and is unambiguous: `Axn::Factory.build` returns a `Class`, and `Axn::Result` is not one.

The class form passes `**inputs` only — the parent's declared, resolved inputs — not the fuller step passthrough that also splats `provided_data` and `exposed_data`. Undeclared-caller-field passthrough is step-chain accumulation behaviour; a standalone `forward!` should forward what you declared and nothing you didn't. The explicit-result form is the escape hatch for subsetting, renaming, or passing extra arguments.

A class that does not include `Axn` raises `ArgumentError`. Step makes the same check at declaration time; `forward!` can only make it at runtime, because the target is runtime-chosen — that is the whole point of the affordance.

## Outcome propagation

| child outcome | parent |
| --- | --- |
| ok | absorb, return the child result, keep executing |
| failure (`fail!` or a `fails_on` classification) | absorb, then `fail!(child.error)` with **no** prefix |
| exception | absorb, then `raise child.exception` |

The no-prefix choice is what makes the migration honest. `call!` and `step` produce identical aggregated errors; the only difference is step's `error_prefix`, which defaults to the step name:

```
inner alone : "inner exploded: child failed"
call! wrap  : "inner exploded: child failed"
step wrap   : "inner: inner exploded: child failed"
```

With an empty prefix, swapping `def call = Inner.call!` for `forward! Inner` changes the exposures and nothing else. No `error_prefix:` option is offered — call!-parity is the point, and a user who wants a prefix already has `error`.

## Three call sites, one write loop

The same merge loop — `exposed_data[field] = source_result.public_send(field)` over `declared_fields` — is implemented three times:

| call site | fields merged | on an empty intersection |
| --- | --- | --- |
| `_expose_from_result` (`contract.rb:2128-2140`) | child's declared ∩ parent's declared outbound | raises `NoMatchingExposures` |
| step orchestrator (`step.rb:151-153`) | child's declared (no filter — chain accumulation) | n/a |
| `forward!` (new) | delegates to `expose(result)` | delegates to `expose(result)` |

The differing field set is a real semantic difference, not duplication: step's unfiltered merge is what lets a step's output reach a *later* step even when the parent does not declare it, and filtering there would break chaining. So the shared piece is not "the merge" but the write loop underneath it, which takes its field list from the caller:

```ruby
def _absorb_result_exposures!(source_result, fields:)
  exposed = source_result.__exposed_keys__
  fields.each do |field|
    next unless exposed.include?(field)

    @__context.exposed_data[field] = source_result.public_send(field)
  end
end
```

`forward!` needs no field list of its own; it calls `expose(result)`, which computes the filtered set. That keeps `forward!` and the documented `expose(result)` idiom semantically identical by construction rather than by matching implementations.

### Fix 1: the nil-clobber

Keying on `declared_fields` merges a field the child *declared* but never *set*, writing `nil` over a value the parent already holds. Both existing call sites do this:

```
expose(result) : parent exposes b="PARENT-OWN", child declares-but-never-sets b  →  b=nil
step           : same, via a later step's unset optional exposure
```

The two are observably distinguishable, and the nil-vs-absent axis survives the fix:

```
child declares exposes :a, :b — sets only :a, then fails
  declared_fields  = [:a, :b]
  __exposed_keys__ = [:a]
  explicit nil     = [:a, :b]     # expose(b: nil) is still recorded
```

Skipping never-set fields is the entire fix. Blast radius is narrow: a required-but-unset exposure already dies in outbound validation before any merge, so only optional exposures can reach the clobbering path.

The loop iterates the **caller's field list** and skips un-set entries, rather than iterating `__exposed_keys__` directly. That ordering is load-bearing: step's unfiltered merge puts keys into a parent's `exposed_data` that the parent does not declare and has no reader for, so iterating the exposed keys of such a result one level up would `public_send` a name that does not exist. Iterating the field list preserves today's propagation boundary exactly, minus the nils.

### Fix 2: `NoMatchingExposures` no longer eats a failure

`_expose_from_result` raises when the intersection is empty. On a failing child that converts a clean failure into an exception and discards the child's message entirely:

```
child fails with "real error", no exposures in common
  →  outcome=exception, error="Something went wrong"
```

The raise is right on the success branch — an empty intersection there is a wiring mistake and nothing is being destroyed by saying so. It is wrong on the failure branch, where it replaces information the caller needs with strictly less. So the raise is gated on `source_result.ok?`.

A wiring mistake is still caught: the first time that child succeeds, the raise fires. Warning on the failure branch instead was considered and rejected — it would fire on every failed call of a correctly-wired action whose child simply shares no exposures, which is legal.

## The outbound contract is conditional, and that is correct

Outbound validation does not run on the failure branch. This came up as a suspected gap and is not one; the design states the invariant rather than caveating it.

Validation classifies the outcome, it does not gate what appears on a result. Even on the success path a violating value stays readable — it only flips the outcome:

```
bad type exposed + success   ok?=false  outcome=exception  n="junk"
bad type exposed + fail!     ok?=false  outcome=failure    n="junk"
```

So the guarantee is conditional: **`ok? == true` means the outbound contract held; `ok? == false` promises nothing about exposures.** That is deliberate — `executor.rb:869-875` applies outbound *defaults* on the failure branch specifically so "the caller (and an `on_error` handler) [can] read sensible exposures off a failed result."

`forward!` sits correctly inside that invariant:

```
SUCCESS branch : ok?=false outcome=exception   ← the parent's own outbound validation catches it
FAILURE branch : ok?=false outcome=failure     ← passes through; the parent is already failing
```

`forward!` therefore cannot launder a contract violation into an `ok?` result, and on the failure branch it propagates the child's real value — which is what the motivating case wants, since the controller reads `@result.event` on the error branch to re-render.

Validating on the failure branch was considered and rejected. Running the outbound contract there would fail nearly every failed action on presence, because a required exposure is legitimately unset when you fail early. Avoiding that needs presence-exempt partial validation, and then a violation has nowhere to go: an already-failed action cannot fail twice, so the options are to warn, to replace the user's real error with a validation error, or to raise — each worse than passing the value through.

Scrubbing the violating value was also rejected. Classifying is the framework's job; hiding the value the author was told was invalid would conceal reality for no gain.

## Deliberately out of scope

**Instance-method shadowing** (PRO-3062). Axn injects ~19 unprefixed public instance methods and its internals dispatch back through several of them, so a user `def result` breaks the framework rather than merely costing a helper. `forward!` ships like its siblings — no instance-side `MethodShadowing` deferral seeded here. Applying deferral to exactly one method creates a one-off asymmetry the eventual sweep would have to reconcile, and it fails silently: a user whose superclass defines `forward!` would get no `forward!` and no explanation.

`forward!` is also not added to `RESERVED_FIELD_NAMES_FOR_EXPECTATIONS`. That list guards field *names*, and nobody writes `expects :forward!`; the real risk is a bare `def forward!`, which the list does not cover. The list's own inconsistencies (`fail!` present but `done!` absent; `result` reserved for exposures but not expectations) are recorded in PRO-3062 rather than patched here. The one addition made here is `__exposed_keys__`, which this design introduces as a reserved public field alongside `__action__`.

**`steps` failure-exposure propagation.** A step exposing `status: :done` followed by a later failing step would surface `status: :done` on a failed parent — temporal conflation across step boundaries, which no filtered-to-declared trick makes honest. `forward!` is clean precisely because it propagates one action's own result faithfully.

**PRO-3060** — an `error` handler interpolating `e.message` duplicates the reason. Surfaced while probing this area; unrelated to `forward!`, which is byte-identical to `call!` on the error path either way.

## Test grid

Linchpin, both unwind types: a child that exposes then `fail!`s, and one that exposes then raises, each surfacing its values on the parent.

Filtering: a child field the parent does not declare never appears on the parent's result.

Nil-clobber, all three call sites: a parent that exposes `b`, then absorbs a child declaring but never setting `b`, keeps its own value — via `expose(result)`, via `forward!`, and via a later step. Its converse: an explicit `expose(b: nil)` in the child does propagate.

`NoMatchingExposures`: still raised when the source result is ok and nothing overlaps; **not** raised when the source failed, where the child's error and outcome survive intact.

Nested-step safety: a step-parent whose `exposed_data` holds a foreign key (no reader) can itself be absorbed one level up without `NoMethodError`.

Contract: a child value violating the parent's declared type flips a **successful** parent to `exception` (the anti-laundering assertion), and passes through unchanged on the failure branch.

Error parity: `forward! Inner` and `Inner.call!` produce the same `result.error` string, with and without `error` declarations on each side.

Signatures: the class form invokes with `**inputs`; the result form forwards a caller-built result unchanged; a non-Axn class raises `ArgumentError`.

Non-Rails safe; specs in `spec/`, with `spec_rails/` coverage only if a Rails-specific path is touched.

## Acceptance

- `forward! Klass` runs `Klass.call(**inputs)`, absorbs its exposures via `expose(result)`, and returns the child result on success.
- On child failure the parent settles as a failure carrying the child's error — byte-identical to today's `call!` — or re-raises on an exception outcome, and in both cases surfaces the child's exposures the parent also declares.
- `forward! Klass.call(custom:)` forwards a caller-built result with identical behaviour.
- One write loop backs `expose(result)`, the step orchestrator, and `forward!`; the nil-clobber is gone from all three.
- `NoMatchingExposures` no longer converts a child's failure into an exception.
- The conditional outbound-contract invariant is documented where users writing `forward!` will meet it.
