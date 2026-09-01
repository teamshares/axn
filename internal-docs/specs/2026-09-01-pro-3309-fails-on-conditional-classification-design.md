# `fails_on` conditional classification: `if:`/`unless:` (PRO-3309)

**Ticket:** [PRO-3309](https://linear.app/teamshares/issue/PRO-3309/axn-fails-on-support-ifunless-to-conditionally-reclassify-an-exception)

## Problem

`fails_on` reclassifies an exception class from the **exception** bucket into the **failure**
bucket unconditionally, per declaration. A `message`/`&block` proc can already hold arbitrary
conditional logic, but the synthesized gate it rides only decides which text `result.error`
resolves to — the exception is reclassified either way. A condition written inside the message
proc reads like an opt-out of reclassification and is not one: a real footgun.

The ticket's own motivating example ("only remap `RecordNotFound` in staging, not production") is
already expressible today at declaration time (`fails_on X unless Rails.env.production?`), so the
feature only earns its keep on **per-call runtime state** — the exception's own attributes, the
action's inputs, a per-request/per-tenant flag — not on anything already decided when the class
loads.

## Decision

Add `if:`/`unless:` kwargs to `fails_on`, evaluated at settlement time against the action instance,
reusing `Handlers::Matcher`/`Handlers::Invoker` wholesale — the same mechanism `error`/`success`/
callbacks already use. No new evaluation machinery.

```ruby
fails_on ActiveRecord::RecordNotFound, if: ->(exception:) { exception.record_type_class.retryable? }
fails_on ActiveRecord::RecordInvalid, unless: :critical_write?
```

A message declared alongside a condition is gated by the *same* condition (the class-match proc
`fails_on` already synthesizes is prepended to the caller's own `if:` rules, still ANDed) — a
closed gate means both no reclassification and no message, closing the footgun directly.

## Representation

`_fails_on_matchers` (a flat frozen `Array<Class>`) becomes `_fails_on_entries`, an
`Array<Entry>` where `Entry = Data.define(:classes, :matcher)` and `matcher` is `nil` for an
unconditional declaration. Entries are OR'd across declarations, exactly as the flat list was — a
conditional `fails_on X, if: c` never narrows an earlier unconditional `fails_on X`.

Two predicates replace the old single `_fails_on?`:

- `_fails_on?(exception, action:)` — the full verdict, evaluating every entry's matcher. Runs user
  code, so it is consulted **only** from `_settle_exception!`, which owns the error-handling policy
  for everything it dispatches (`Handlers::Invoker`'s `best_effort`: a raising condition warns and
  reads as no match, never replacing the settlement it's deciding).
- `_unconditionally_fails_on?(exception)` — static entries only, undispatched
  (`Internal::Identity.kind?`), runs no user code. This is what `Result#outcome` reads.

## The settlement reorder (the load-bearing change)

`Result#outcome` used to be deliberately unmemoized, because classification could "finalize at
different points during dispatch." Checking why, rather than assuming the comment still held: every
*existing* classification term (`Axn::Failure` ancestry, `ValidationError.user_facing?`, the old
static `_fails_on?`) is fixed at construction or declaration time — genuinely timing-independent.
The one term that was ever going to have real timing to worry about is the conditional gate this
ticket adds.

Probed directly: inside an action's own `on_error`, for its own `fails_on ArgumentError` (no
condition needed to demonstrate this — it's a property of the *old* code too), `outcome` already
read `"failure"` correctly — but only because `_fails_on?` was a pure static check with no
timing dependence. Once `_fails_on?` can run a user condition, evaluating it lazily inside
`Result#outcome` (a method deliberately read from `inspect`/logging on every later call) would
either (a) run the condition on every unmemoized read — measured at up to one extra evaluation per
`outcome`/`inspect`/pattern-match call, unbounded, for a "no match" verdict — or (b) if memoized
naively, freeze in whatever the *first* read happened to observe, which could be mid-settlement,
before the verdict was even decided.

Fix: hoist the verdict **and its recording** in `_settle_exception!` to run immediately after
`__record_exception`, before `_resolve_and_stamp_presentation` and before any callback dispatch.
`_fails_on?` is deliberately last in the OR (`Identity.kind?(e, Failure) ||
ExceptionClassification.failure?(e) || ValidationError.user_facing?(e) || @action_class._fails_on?(e,
action: @action)`) so an already-sticky or already-Failure exception never even reaches user code,
and an ancestor's own condition is never consulted for an exception an inner action already
classified — stickiness still flows outward only.

This closes two windows in one motion: the action's own `on_error` callback, and message resolution
inside `_resolve_and_stamp_presentation` (which itself calls `result.error`) — both now read the
context flag set immediately after `__record_exception`, never `_fails_on?` itself.

## `Result#outcome` becomes memoizable

Once the reorder holds, every classification term is fixed by the time `finalized?` is observably
true. So `outcome` is memoized exactly like `#error`/`#success` (`return _resolve_outcome unless
finalized?`; memoize once). The static-only `_unconditionally_fails_on?` split still matters even
under memoization: if `Result#outcome`'s first read reached for the *full* `_fails_on?`, a first
read landing anywhere other than inside `_settle_exception!` (which never calls `Result#outcome`
itself) would run the user's condition a second time, unpredictably, depending on read order.
Keeping the static fallback means the executor's own evaluation is the only one that ever runs user
code, regardless of what reads `outcome` afterward or in what order.

## Three bugs found by Codex review, and the fixes

All three are real, confirmed by direct execution before and after — not accepted on the
reviewer's prose.

### 1. A reentrant `result.outcome` read froze in the wrong answer, permanently

The first cut of this design finalized the context (`Context#__record_exception`, called at the top
of `_settle_exception!`) *before* the classify block ran — "the first line of `_settle_exception!`,
before the hoisted classify block even runs" was the claim, and it was wrong: finalization happened
before classification, not after. So a `fails_on if:` condition that read `result.outcome`
reentrant — during its *own* evaluation, not from a later callback — saw `finalized?` already true
while the verdict was still being decided, and `outcome`'s new memoization cached whatever it
resolved to at that moment (`"exception"`, since neither the context flag nor the sticky set was
set yet). Once classification then decided `true`, the memoized value never recomputed: `outcome`
stayed `"exception"` forever, contradicting the `on_failure` callback that had already fired.

Fix: `Context#__record_exception` no longer sets `@finalized`, only `@exception`/`@failure` (`ok?`
is unaffected — it only reads `@failure`). `_settle_exception!` calls the pre-existing
`Context#__finalize!` explicitly, immediately after the classify block decides and records its
verdict — so `finalized?` only becomes observably true once there is an actual verdict to freeze
in. During the classify window itself, `outcome` keeps recomputing live (the pre-memoization
behavior), exactly as `#error`/`#success` already do pre-finalization elsewhere. The only other
caller of `__record_exception` (`Axn::Result.error`'s test-mocking constructor) needed no change:
the exception there is rescued *inside* the user's block, so the surrounding Factory-built action's
own normal-completion path (`@context.__finalize!` at the end of a non-raising `call`) still
finalizes it, just a few lines later in the same synchronous call.

### 2. Classification and the message it gates could disagree

`fails_on X, "msg", if: cond` evaluated `cond` twice — once in `_fails_on?` (classification), once
more when the wired message resolved (a *separate* Matcher built from `[class_gate,
*Array(if_condition)]` and handed to `error(...)`). For a `cond` that isn't perfectly pure (a
counter, a clock, anything stateful), the two evaluations could disagree: classified as a failure
but the message falls back to the generic default (the failure-condition branch not being hit the
second time), or the reverse — reported as an exception while still surfacing the failure-only
message.

Fix: `Internal::FailsOnVerdicts`, a small identity-keyed cache mirroring the existing
`ExceptionClassification`/`CarriedPresentation` pattern exactly (scoped via
`IsolatedExecutionState`, `compare_by_identity` at both levels since a `fails_on` `Entry` is a
`Data.define` with structural `==`, reset when the nesting stack empties). `_fails_on?` records each
conditional entry's verdict as it computes it; the wired message's gate reads that cache instead of
re-invoking `if_condition`/`unless_condition` — falling back to a fresh `entry_matcher.call` only if
somehow the cache is empty (defensive; in the shipped settle order this cache is always already
populated by the time any message resolves, since `_fails_on?` runs synchronously earlier in the
same `_settle_exception!`). Net effect: the condition runs **at most once per exception, full stop**
— a strictly better story than the original design's "once with no message, twice with one," and one
that makes the two-evaluation class of bug structurally impossible rather than merely rare.

### 3. A raising `unless:` rule reclassified instead of staying inert

Not a `fails_on`-specific bug — it lives in the shared `Handlers::SingleRuleMatcher`/`Invoker`
machinery this ticket reuses (decision 2), and would have been latent in `error`/`success`/callback
`unless:` all along had `fails_on` not made the consequence severe enough to surface it.

`apply_callable`/`apply_symbol` call `!!Invoker.call(...)`. When the rule raises, `Invoker.call`
swallows it (warns, returns `nil` — `best_effort`'s documented failure return) and `!!nil` coerces
to a definite `false` *before* `SingleRuleMatcher#call` ever sees it. For an `if:` rule that's
exactly the documented "a broken condition fails in the safe direction" — `false` means no match
either way. But `SingleRuleMatcher#call` then applies `@invert` to that `false`: `unless:` rules are
built with `invert: true`, so a *swallowed raise* got inverted to `true` — a match — turning "the
condition blew up" into "the exclusion doesn't apply, so reclassify." For `fails_on X, unless:
raising_cond`, that meant a genuine bug got silently reclassified as a failure and the global report
suppressed — a materially worse outcome than the equivalent `if:` case, and the exact opposite of
the policy this ticket's own decision 2 asserted (and had only verified for `if:`, never `unless:`).

The two evaluations of `Invoker.call`'s swallow return — `nil` for "genuinely returned nil" and
`nil` for "raised and got swallowed" — are indistinguishable by design; every caller before this one
only needed "something/nothing happened," never "did this raise." Fix: `Invoker.call` gained an
`on_swallow:` kwarg (default `nil`, so the four other call sites are untouched) returned in place of
`nil` specifically on the swallow path. `SingleRuleMatcher` passes a private sentinel
(`SWALLOWED = Object.new.freeze`) and checks for it (via `Internal::Identity.same?`, undispatched —
the checked value could be anything a hostile rule handed back) in `apply_callable`/`apply_symbol`,
propagating it up through `matches?`; `#call` then short-circuits to `false` on either that sentinel
or a bare `nil` (the latter covering `apply_string`/`apply_exception_class`, which have no `Invoker`
underneath and so raise straight into `#call`'s own `best_effort`) — *before* applying `@invert`.
This holds the "Invoker owns the swallow policy, callers don't re-guard" rule (error-paths.md):
Invoker still decides what to catch and when; a caller reading back *what happened* is a different
question from adding a second catch on top.

## Declaration-time guards

Following the `step` precedent (`mounting_strategies/step.rb`), `fails_on` rejects at
class-definition time:

- A rule form the underlying matcher can't apply — checked against a new
  `Handlers::SingleRuleMatcher.applicable?(rule)`, **narrower** than `#matches?`'s own `callable?`
  arm on purpose: `#matches?`'s `callable?` is a bare `respond_to?(:call)`, but `Invoker` needs
  `to_proc`/`arity` to actually invoke it — a `#call`-only object fails both, falls through to
  `Invoker#literal_value`, and comes back **as itself**, i.e. truthy: an unconditional match,
  silently. For a gate deciding whether a bug gets reported, "always matches" is the wrong way to be
  wrong, so a declaration admits only what `Invoker` can actually invoke.
- **Both booleans**, not just `false`. Probed: `Matcher.build(if: false)` and `Matcher.build(if:
  nil)`/`Matcher.build(if: [])` are all `static?` (no condition, i.e. **always** matches) — so
  `if: false` would silently mean the opposite of what it looks like. A bare `if: true` isn't a
  recognized rule shape at all (not callable/Symbol/String/Exception-class), so it falls to
  `handle_invalid` → warn + `false`, meaning **never**. Both directions are wrong, so both are
  refused, with a message naming the actual fix (guard the declaration: `fails_on X if cond`).
- An empty rule set (`if: []`) — dead machinery.

`if:`/`unless:` with **no message** is deliberately *not* rejected — the opposite of `standalone:`,
which raises without one. `standalone:` only configures the wired `error`; `if:` gates classification
and is fully meaningful alone.

## Known pre-existing behavior, not changed by this ticket

A Symbol condition resolves against a **public** action method only —
`SingleRuleMatcher#apply_symbol`'s existence check is a public-only `respond_to?` (shared with
`error`/`success`/callbacks). A private method name falls through to constant lookup, fails that
too, and reads as "no match" with a warning, not an error. Worth documenting since
`fails_on if: :some_private_predicate?` is a natural spelling to reach for.

## Compatibility

`_fails_on_matchers`/`_fails_on?` are internal (no `instance_accessor`, never public API). Grepped
every downstream consumer (os-app, axn-mcp, axn-ruby_llm, axn-openapi, axn-webhooks, data_shifter,
slack_sender) for both names — zero hits outside the public `fails_on` DSL, including
`axn-webhooks/lib/axn/webhooks/handler.rb`'s programmatic `base.fails_on(Axn::Webhooks::RetryLater)`
(a bare positional call, unaffected by an additive kwarg). `[INTERNAL]` in the CHANGELOG entry.

## What we're not doing

- Not touching `#matches?`'s own `callable?` — the `#call`-only asymmetry it has today for
  `error`/`success` (which don't pre-validate) is unchanged; the declaration guard here is
  additive, not a retrofit.
- Not adding a declarative schema story — `fails_on` has no schema projection today and this adds
  none.
- Not fixing the private-Symbol-condition gap — pre-existing, shared, out of scope; documented
  instead.
