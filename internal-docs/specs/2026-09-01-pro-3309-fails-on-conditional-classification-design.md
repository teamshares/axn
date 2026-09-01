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

## Eight bugs found across review and self-review, and the fixes

All eight are real, confirmed by direct execution before and after — not accepted on prose alone,
the reviewer's or my own. One reviewer-suggested remedy (fix 8) was itself verified wrong before
being replaced with a different fix.

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

### 4. The message gate closed over the caller's own (mutable) array

Decision 1's own aliasing note — `Array(exceptions)` returns the caller's array unchanged when one
was passed, so `entry.classes` stores a `.dup.freeze` copy rather than the bare `classes` local —
was applied to the `Entry` but not to `message_gate`'s closure, which kept reading `classes`
directly. Classification (`_fails_on?`, reading `entry.classes`) and the message gate (reading the
live `classes` local) therefore had two DIFFERENT views of "which classes this declaration covers"
whenever the caller mutated the array they originally passed after `fails_on` returned — verified
live: `fails_on classes, "msg"` then `classes.delete(ArgumentError); classes << TypeError` made an
`ArgumentError` still classify as a failure (correct, via the frozen `entry.classes`) while losing
its message (wrong, the gate's `classes.any?` now checking the mutated array). Fix: the gate reads
`entry.classes` too — the same aliasing guard decision 1 already stated, now actually applied
everywhere the classes list is read, not just where it's stored.

### 5. A reentrant `result.error`/`.message`/`.inspect` read inside the condition recursed unboundedly, and could permanently poison the message

`message_gate`'s cache-miss fallback (`entry_matcher.call(exception:, action: self)`, justified as
"defensive only... the cache should already be populated") was wrong on both counts. A condition
that reads `result.error`/`.message`/`.inspect` reentrant — during its *own* evaluation — resolves
LIVE (`finalized?` is still false at that point, by decision 3's own design), which walks every
declared `error` handler including this entry's OWN wired message, mid-classification — a genuine,
reachable cache miss, not a hypothetical one. Falling back to re-invoking the condition there
doesn't just cost an extra evaluation: the re-invoked condition can *itself* read `result.error`
again, recursing. Measured: 254 nested calls before hitting whatever incidentally bounded it, for a
condition as simple as `-> { result.error; true }`.

Fix, part one (per the reviewer's own suggested remedy): a cache miss now means "not decided yet,"
read as a plain `false` — `Axn::Internal::FailsOnVerdicts.fetch(exception, entry) || false` — never
re-invoking the condition. This alone closes the recursion (confirmed: exactly 1 call), but not the
whole finding — with only this half applied, `outcome` still correctly settled `"failure"` while
`result.error` stayed **permanently** stuck on the generic fallback, exactly the disagreement the
reviewer named.

The second layer: `Result#_error_resolver` memoizes unconditionally (`@_error_resolver ||= ...`),
and the `MessageResolver` it builds separately memoizes its OWN `matched_reason` ("a resolver is
single-use... run once, not twice"). The reentrant read is the FIRST ever call to `.error` on this
result, so it builds and permanently caches both — freezing in the premature "no match" answer
computed while classification was still mid-flight, before `FailsOnVerdicts` had anything to
`fetch`. Every later call, including the real one after classification finishes, reused that same
frozen resolver and its already-decided (wrong) `matched_reason` — `Result#error`'s OWN `finalized?`
gate on `@__resolved_error` never got a chance to matter, because the resolver **underneath** it was
already poisoned. Fix: `_error_resolver` now defers its memoization to `finalized?`, mirroring
`outcome`/`#error` — a throwaway resolver per pre-finalization read (isolated, discarded), one real
memoized resolver from the first post-finalization read onward. `_error_from_declared_source?`
(`TransparentBubbling`) and `_resolve_and_stamp_presentation`'s own `result.error` call — the two
real "share one pass" callers the original comment was written for — are both already
post-finalization by construction, so neither loses anything.

### 6. A later same-class entry's message went cold once an earlier entry already matched (self-review, not Codex)

Found reviewing this very file after fix 5, not from a review round: `_fails_on?` originally
short-circuited on the first matching entry (`_fails_on_entries.any? { ... }`). Classification
stayed correct regardless (an OR is an OR either way), but a SECOND `fails_on` declaration sharing
the same class as an earlier one never got its own condition evaluated at all once the earlier entry
already matched — so its `FailsOnVerdicts` entry was never populated, and its own `message_gate`
read that empty cache as "no match" (the same safe default fix 5 gave a genuine miss), even when the
second entry's condition was genuinely true. Verified live:

```ruby
fails_on ArgumentError                                      # unconditional, matches (and used to short-circuit) first
fails_on ArgumentError, "second entry message", if: -> { true }
```

reclassified correctly (`outcome == "failure"`) but resolved `result.error` to the generic default,
never `"second entry message"`, even though its `if:` is unconditionally true. This is a genuine
behavioral regression against the OLD (pre-ticket) `fails_on`, where each declaration's message gate
was an INDEPENDENT proc checking only its own class list — nothing coupled one declaration's message
to whether ANOTHER declaration happened to be consulted first.

Fix: `_fails_on?` no longer short-circuits. Every entry whose class matches gets its condition
evaluated (and cached) exactly once, and the overall verdict is the OR of all of them — so an early
match no longer starves a later entry's own cache, and each entry's "runs at most once" guarantee
(fix 2) now holds per-entry rather than only for whichever entry happens to be consulted first.

(Fix 6 landed one commit ahead of the review round that independently found the identical bug and
proposed the identical remedy — replied on that thread noting it was already fixed.)

### 7. A rule that never RAN (not just one that raised) suffered the same invert bug as fix 3

Fix 3 closed the "raised, swallowed, then inverted" path via a `SWALLOWED` sentinel threaded through
`Invoker.call`'s `on_swallow:` — but two OTHER "the rule never produced a real answer" paths still
returned a bare `false`, not the sentinel: `apply_symbol`'s `rescue NameError` branch (a Symbol
naming neither an action method nor a real constant) and `handle_invalid` (a rule shape none of
`apply_callable`/`apply_symbol`/`apply_string`/`apply_exception_class` can apply). Both warn and log,
then return `false` directly — and `#call`'s guard only special-cased `nil`/`SWALLOWED` before
inverting, so this bare `false` read as a GENUINE answer and got inverted for `unless:`. Verified
live: `fails_on ArgumentError, unless: :this_method_does_not_exist_anywhere` on a genuine
`ArgumentError` silently reclassified it and suppressed the report — a typo'd `unless:` symbol is
exactly the kind of mistake this should have caught, not amplified. Fix: both paths now return
`SWALLOWED` instead of `false`, closing the same class of bug fix 3 closed, for the paths fix 3
didn't reach.

### 8. An inherited `fails_on` entry's verdict from one settlement level leaked into another

`FailsOnVerdicts` keyed on `(exception, entry)` only. `_fails_on_entries` is a `class_attribute`, so
a subclass inherits the SAME `Entry` object its base declared — meaning the same cache slot could be
written by TWO DIFFERENT settling action instances: an inner (subclassed) action whose own
evaluation of the shared entry comes back false (so nothing marks the exception sticky), bubbling
via `call!` to an outer action that shares the same entry and gets asked again. The reviewer's
suggested remedy — consult the cache before invoking the matcher at all — would have been WRONG here
on inspection, not just incomplete: it would make the OUTER action's classification silently reuse
the INNER action's verdict (a DIFFERENT `self`, decision 2's own action-scoping violated) instead of
evaluating its own condition against its own action at all. Verified live that the two levels
legitimately need independent answers: a condition keyed to `self.class` returned `false` for the
inner subclass and `true` for the outer one, and the CORRECT behavior is exactly axn's existing,
tested, documented "mixed outcome" shape for unconditional `fails_on` (reported once as a bug at the
level that didn't classify it, `outcome == "failure"` at a level that did) — extended to the
conditional case, not a new failure mode.

Fix: `FailsOnVerdicts` now keys on `(exception, action, entry)` — `action` from `_fails_on?`'s own
parameter, `self` (the settling action, via `Invoker`'s `instance_exec`) inside `message_gate`. Each
settlement level gets its own cache slot for the same inherited entry, so the two instances' verdicts
can never collide, each one's condition still runs at most once **for that level**, and each level's
own message resolves against its own classification rather than a different action's.

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
