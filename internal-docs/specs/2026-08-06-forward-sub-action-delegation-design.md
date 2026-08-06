# `forward!` — delegate to a sub-action, propagating its exposures (PRO-2941)

Ticket: https://linear.app/teamshares/issue/PRO-2941

The "outer axn thinly delegates to a runtime-chosen inner axn" pattern loses the inner's exposures on the failure branch. `def call = Inner.call!(...)` gives the parent the child's aggregated error but not its values, so a controller reading `@result.event` on the error branch gets `nil`. `forward!` is an opt-in-by-existence instance helper that closes that gap.

Every behavioural claim below was verified by probe against this branch rather than inferred from the code.

## The linchpin holds

The design assumed a failed child result still carries the values it exposed before failing, and that the declared-exposure readers are callable on it. Both hold, on the `fail!` branch and on the exception branch:

```
child exposes :event, sets it, then fail!  →  result.event == "made-it",   outcome "failure"
child exposes :event, sets it, then raise  →  result.event == "before-boom", outcome "exception"
```

Nothing clears `exposed_data` on the way out, and `Result`'s generated readers work regardless of outcome. No "let exposures survive their own failure" change is needed.

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

Terminal semantics were considered and rejected. Terminal plus success-message propagation would make the parent a pure passthrough, at which point the caller may as well invoke the inner action directly — a wrapper earns its keep with what it does *around* the delegation, and terminal deletes the "after" half of that. Non-terminal also keeps `forward!` a drop-in for the `call!` it replaces, and `done!` already covers "stop here". The bang is earned by the failure branch alone, exactly as `call!`'s is.

The parent does **not** inherit the child's success message; it keeps its own. Only the error path propagates.

### Dual signature

A `Class` argument is invoked as `klass.call(**inputs)`. Anything else is treated as an already-produced result and forwarded as-is. Detection is `arg.is_a?(Class)` and is unambiguous: `Axn::Factory.build` returns a `Class`, and `Axn::Result` is not one.

The class form passes `**inputs` only — the parent's declared, resolved inputs — not the fuller step passthrough that also splats `provided_data` and `exposed_data`. Undeclared-caller-field passthrough is step-chain accumulation behaviour; a standalone `forward!` should forward what you declared and nothing you didn't. The explicit-result form is the escape hatch for subsetting, renaming, or passing extra arguments.

A class that does not include `Axn` raises `ArgumentError`. Step makes the same check at declaration time; `forward!` can only make it at runtime, because the target is runtime-chosen — that is the whole point of the affordance.

## Merge rule

Merge the child's **actually-exposed** keys — the keys present in its `exposed_data` — not its `declared_fields`.

The distinction is load-bearing and the two are observably different on a child that declares a field it never sets:

```
child declares exposes :a, :b — sets only :a, then fails
  declared_fields  = [:a, :b]
  exposed_data     = {a: "SET"}
  explicit nil     = {a: "SET", b: nil}    # expose(b: nil) is still recorded
```

Merging `declared_fields` writes `b => nil` and destroys a value the parent set for `b` before calling `forward!`. Merging `exposed_data` does not, while still propagating an explicit `expose(b: nil)` — the nil-vs-absent axis survives.

The merge writes straight into the parent's `@__context.exposed_data`. It cannot go through `expose`, which rejects undeclared keys and would fail the action whenever the child exposes something the parent does not declare.

Filtering to the parent's own `exposes` needs no code. The `Result` layer already does it: a step child exposing `event` and `extra` under a parent declaring only `event` yields `#<Axn::Result [OK] event: "E">`, with no `extra` reader. Over-merging into `exposed_data` is invisible at the result boundary.

The merge runs on **both** branches.

## Outcome propagation

| child outcome | parent |
| --- | --- |
| ok | merge, return the child result, keep executing |
| failure (`fail!` or a `fails_on` classification) | merge, then `fail!(child.error)` with **no** prefix |
| exception | merge, then `raise child.exception` |

The no-prefix choice is what makes the migration honest. `call!` and `step` produce identical aggregated errors; the only difference is step's `error_prefix`, which defaults to the step name:

```
inner alone : "inner exploded: child failed"
call! wrap  : "inner exploded: child failed"
step wrap   : "inner: inner exploded: child failed"
```

With an empty prefix, swapping `def call = Inner.call!` for `forward! Inner` changes the exposures and nothing else. No `error_prefix:` option is offered — call!-parity is the point, and a user who wants a prefix already has `error`.

## One shared merger, and the step fix folded in

Both `forward!` and the step orchestrator get their merge-and-settle from a single helper, parameterized only by `error_prefix` (step passes its step name, `forward!` passes none). Duplicating it was rejected under mirror-layers-reuse-source; a shared merger with a behaviour flag was rejected as the same duplication wearing a parameter.

That requires changing step, because step merges `declared_fields` today (`lib/axn/mountable/mounting_strategies/step.rb:151-153`) and therefore carries the same nil-clobber: a later step with an unset **optional** exposure silently nils out an earlier step's value for that key. It reads as the same bug, not an intentional difference, so it is fixed rather than preserved behind a flag — close the full class in one pass.

Blast radius is narrow. A required-but-unset exposure already dies in outbound validation before any merge, so only optional exposures (`allow_blank: true` and friends) can reach the clobbering path.

The helper needs a Result reader for the actually-exposed keys. `_context_data_source` is private today; this adds a small internal accessor rather than reaching through `send`.

Home is `lib/axn/internal/`, not the mountable tree — `forward!` is core, and core cannot depend on mountable.

## The outbound contract is conditional, and that is correct

Outbound validation does not run on the failure branch. This came up as a suspected gap and is not one; the design states the invariant rather than caveating it.

Validation classifies the outcome, it does not gate what appears on a result. Even on the success path a violating value stays readable — it only flips the outcome:

```
bad type exposed + success   ok?=false  outcome=exception  n="junk"
bad type exposed + fail!     ok?=false  outcome=failure    n="junk"
```

So the guarantee is conditional: **`ok? == true` means the outbound contract held; `ok? == false` promises nothing about exposures.** That is deliberate, not incidental — `executor.rb:869-875` applies outbound *defaults* on the failure branch specifically so "the caller (and an `on_error` handler) [can] read sensible exposures off a failed result."

`forward!` sits correctly inside that invariant. Simulating the merge against a parent whose declared type the child's value violates:

```
SUCCESS branch : ok?=false outcome=exception   ← the parent's own outbound validation catches it
FAILURE branch : ok?=false outcome=failure     ← passes through; the parent is already failing
```

`forward!` therefore cannot launder a contract violation into an `ok?` result, and on the failure branch it propagates the child's real value — which is exactly what the motivating case wants, since the controller reads `@result.event` on the error branch to re-render.

Validating on the failure branch was considered and rejected. Running the outbound contract there would fail nearly every failed action on presence, because a required exposure is legitimately unset when you fail early. Avoiding that needs presence-exempt partial validation, and then a violation has nowhere to go: an already-failed action cannot fail twice, so the options are to warn, to replace the user's real error with a validation error, or to raise — each worse than passing the value through.

## Deliberately out of scope

**Instance-method shadowing** (PRO-3062). Axn injects ~19 unprefixed public instance methods and its internals dispatch back through several of them, so a user `def result` breaks the framework rather than merely costing a helper. `forward!` ships like its siblings — no instance-side `MethodShadowing` deferral seeded here. Applying deferral to exactly one method creates a one-off asymmetry the eventual sweep would have to reconcile, and it fails silently: a user whose superclass defines `forward!` would get no `forward!` and no explanation. A uniformly-absent policy is easier to fix than a half-applied one.

`forward!` is also not added to `RESERVED_FIELD_NAMES_FOR_EXPECTATIONS`. That list guards field *names*, and nobody writes `expects :forward!`; the real risk is a bare `def forward!`, which the list does not cover. The list's own inconsistencies (`fail!` present but `done!` absent; `result` reserved for exposures but not expectations) are recorded in PRO-3062 rather than patched here.

**`steps` failure-exposure propagation.** A step exposing `status: :done` followed by a later failing step would surface `status: :done` on a failed parent — temporal conflation across step boundaries, which no filtered-to-declared trick makes honest. `forward!` is clean precisely because it propagates one action's own result faithfully. Shipping it commits us to nothing here.

**PRO-3060** — an `error` handler interpolating `e.message` duplicates the reason. Surfaced while probing this area; unrelated to `forward!`, which is byte-identical to `call!` on the error path either way.

## Test grid

Linchpin, both unwind types: a child that exposes then `fail!`s, and one that exposes then raises, each surfacing its values on the parent.

Filtering: a child field the parent does not declare never appears on the parent's result.

Nil-clobber: a parent that exposes `b`, then forwards to a child declaring but never setting `b`, keeps its own value. Its converse: an explicit `expose(b: nil)` in the child does propagate.

Contract: a child value violating the parent's declared type flips a **successful** parent to `exception` (the anti-laundering assertion), and passes through unchanged on the failure branch.

Error parity: `forward! Inner` and `Inner.call!` produce the same `result.error` string, with and without `error` declarations on each side.

Signatures: the class form invokes with `**inputs`; the result form forwards a caller-built result unchanged; a non-Axn class raises `ArgumentError`.

Step regression: an earlier step's value survives a later step whose optional exposure goes unset.

Non-Rails safe; specs in `spec/`, with `spec_rails/` coverage only if a Rails-specific path is touched.

## Acceptance

- `forward! Klass` runs `Klass.call(**inputs)` and merges its actually-exposed keys, filtered to the parent's `exposes` by the result layer, on success.
- On child failure the parent settles as a failure carrying the child's error — byte-identical to today's `call!` — or re-raises on an exception outcome, and in both cases surfaces the child's exposures the parent also declares.
- `forward! Klass.call(custom:)` forwards a caller-built result with identical behaviour.
- Merge and outcome-category logic live in one helper shared with the step orchestrator; step's nil-clobber is fixed by that sharing.
- The conditional outbound-contract invariant is documented where users writing `forward!` will meet it.
