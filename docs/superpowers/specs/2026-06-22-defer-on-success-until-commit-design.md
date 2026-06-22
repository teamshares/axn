# Defer `on_success` until the enclosing transaction commits

**Date:** 2026-06-22
**Status:** Design — pending review

## Problem

`on_success` is documented (`docs/strategies/transaction.md:28`) as running **after the
transaction commits**, so it is the right place for irreversible side effects (sending an
email, calling an external HTTP service, enqueuing a job) that must only happen once the
DB work is durably persisted.

That guarantee holds only at the **top level**. It silently breaks under nesting:

- The `:transaction` strategy is an `around` hook (`lib/axn/strategies/transaction.rb:11`),
  so it wraps `before`/`call`/`after`. `Executor#trigger_on_success` runs *after*
  `with_hooks` returns (`lib/axn/executor.rb:246`), i.e. after the around block — and thus
  after commit — at the top level. ✅
- A nested `ActiveRecord::Base.transaction` has no `requires_new:`, so AR **absorbs** it into
  the outer transaction. The inner block returning is a no-op, not a real commit. But the
  inner action's `trigger_on_success` fires immediately anyway — **while the outer
  transaction is still open**.

```
outer.transaction {
  ... inner runs, "commits" (no-op), inner on_success FIRES (email sent) ...
  outer fails → ROLLBACK   # inner's DB work is gone, but the email already went out ❌
}
```

So the asymmetry is the bug: **top-level `on_success` is post-real-commit; nested
`on_success` is pre-real-commit.** The documented contract is true at depth 0 and false at
depth ≥ 1.

## Approach

Rails/ActiveRecord 7.2 (the gem's floor, `axn.gemspec`) ships
`ActiveRecord.after_all_transactions_commit` (`active_record.rb:557`), which is purpose-built
for this:

- **No open transaction** → yields the block **immediately** (inline).
- **One+ open transactions** → registers `after_commit` on the outermost → fires at the
  **real** commit.
- **Any enclosing transaction rolls back** → the block is **never called**.
- It is null-safe (`NullTransaction#after_commit` simply yields), and only referenced behind
  a `defined?(ActiveRecord)` guard, so non-Rails usage is untouched
  (see `[[project_axn_works_outside_rails]]`).

This single primitive *is* the discriminator + the deferral + the rollback-skip. Route the
success dispatch through it:

```ruby
# lib/axn/executor.rb
def trigger_on_success
  dispatch = -> { @action_class._dispatch_callbacks(:success, action: @action, exception: nil) }

  if defined?(ActiveRecord)
    ActiveRecord.after_all_transactions_commit(&dispatch)
  else
    dispatch.call
  end
end
```

There are **two** `trigger_on_success` call sites — the normal path (`executor.rb:246`) and
the early-completion (`done!`) path (`executor.rb:254`). Both route through this method, so
`done!` (a success outcome) is covered automatically.

### Why deferral is universal, not scoped to `:transaction`

The deferral triggers whenever *any* enclosing AR transaction is open — it is **not** tied to
the inner action using the `:transaction` strategy. A non-transactional action whose
`on_success` sends an email, invoked inside someone else's transaction (an outer axn's
`:transaction`, or a raw `ActiveRecord::Base.transaction` in app code), has the identical
premature-side-effect bug. The primitive costs nothing at the top level (a pure inline
yield), so universal coverage is free.

## Scope: success only

**Only `on_success` is deferred.** `on_failure` / `on_error` / `on_exception` continue to fire
immediately, as today. This is deliberate, not an oversight:

The error-path callbacks fire in `with_exception_handling` (`executor.rb:198-214`), which sits
*outside* the transaction around-hook. By the time they fire, the action's own transaction has
already rolled back, and an enclosing transaction is usually *about to* roll back too (the
`Axn::Failure` re-raises up via `call!`). If they were routed through
`after_all_transactions_commit`, they would fire **only if the enclosing transaction commits** —
meaning on the common rollback path your error/exception reporting (logging, Sentry, alerting,
cleanup) would **silently never run**.

The semantics are inverted between the two sides:
- `on_success` deferral **suppresses premature good news** — desirable.
- `on_failure`/`on_error`/`on_exception` deferral would **suppress the error report exactly when
  something failed** — the opposite of desirable.

A "fire once the transaction settles either way" semantic for failures (i.e. `after_rollback`)
is explicitly **out of scope**: error reports should fire promptly and unconditionally.

## Ordering guarantee

Child-first ordering (inner `on_success` before outer `on_success`) is preserved for free,
because `after_commit` callbacks run in registration (= completion) order. Walk a nested
O → I where both are transactional and O does work after calling I:

1. I completes first → `trigger_on_success` while O's transaction is open → **deferred**
   (registers after_commit slot #1).
2. O's `after` hooks run (still inside O's transaction).
3. O's transaction commits → AR runs after_commit callbacks → **I's `on_success` fires**.
4. O's around hook returns, transaction closed → O's `trigger_on_success` sees no open
   transaction → runs **inline** → **O's `on_success` fires**.

Result: **I's success → O's success** (child-first ✅), for arbitrarily deep nesting, including
a non-transactional middle axn (it defers too, since *some* enclosing transaction is open).

### Accepted tradeoff (must document)

Because deferral moves `on_success` past the enclosing transaction's commit, **the outer
action's `after` hooks now run *before* the inner action's `on_success`** (step 2 precedes
step 3 above). This is a behavior change from today's immediate firing. It is considered
acceptable and will be called out explicitly in `docs/strategies/transaction.md` and the
`on_success` docs.

## No configuration — this is the definition of `on_success`

There is **no opt-out flag** (no global config, no per-action DSL). Deferral-to-commit *is*
what `on_success` means:

> `on_success` runs after the enclosing transaction commits — immediately if there is no open
> transaction — and is skipped entirely if the enclosing transaction rolls back.

Rationale for shipping it unconditionally rather than behind a toggle:

- There is no current use case for opting out, and the spike removed the only concrete worry
  (transactional tests). An opt-out would only ever restore the old pre-commit nested timing —
  a bug-compat knob, not a feature.
- Anything that must be atomic with the DB work already belongs in `call` / `after`, not
  `on_success` (per the documented contract). So unconditional deferral cannot break a
  correctly-written `on_success`.
- A single unconditional rule means `on_success` timing is knowable by rule, not by
  per-action lookup. A global toggle would be too broad to be useful, and per-action variance
  would make the ordering story something you must inspect case-by-case.
- **Reversibility favors omitting it:** adding a toggle later is a non-breaking, additive
  change; removing a documented flag later is breaking. axn is pre-1.0, so now is the cheapest
  moment to bake in the semantic. If a real opt-out need ever appears, add it then.

The only conditional is the **`defined?(ActiveRecord)` capability guard** (not a lever): with
no ActiveRecord loaded, success dispatches inline exactly as today
(see `[[project_axn_works_outside_rails]]`).

### No `:transaction` strategy change required

The deferral hooks at `trigger_on_success`, not in the strategy, so it works identically for
the `:transaction` strategy, a raw `ActiveRecord::Base.transaction` in app code, or any other
externally-opened transaction. The `:transaction` strategy is left unchanged — there is no
improvement to be had there for this feature, and keeping the hook strategy-agnostic is what
lets us support external transactions.

## Edge cases

- **Exceptions in a deferred callback.** Callbacks already self-contain their exceptions:
  `_dispatch_callbacks` → `CallbackResolver` → `Invoker.call`, which rescues `StandardError`
  (and `EarlyCompletion`/`Failure`) and routes to `PipingError.swallow`
  (`lib/axn/core/flow/handlers/invoker.rb:24-28`). The result is already settled by
  `__finalize!` *before* `trigger_on_success`, so a raising `on_success` never flips the result.
  Deferral only changes *where/when* the swallow runs: at commit-time, in the outer action's
  stack, instead of the inner's pipeline. Still swallowed, still logged with `action:` context.
  - **Dev-only corner:** with `raise_piping_errors_in_dev` enabled in a development env,
    `PipingError.swallow` re-raises (`piping_error.rb`). For a deferred callback that re-raise
    lands in the **outer transaction's commit path**, not the inner pipeline. Document this; it
    is a diagnostic-mode-only behavior.
- **`done!` (early completion)** is a success outcome and routes through the same
  `trigger_on_success`, so it is deferred identically.
- **No ActiveRecord** → `defined?(ActiveRecord)` is false → always inline (current behavior).
- **Multi-database transactions** → handled by `after_all_transactions_commit` (fires once all
  commit); noted by Rails as a sharding anti-pattern, no special handling needed here.

## Testing strategy

- axn's own `spec_rails` dummy app does **not** use transactional fixtures — existing
  transaction specs assert real persistence (`change(User, :count).by(1)` in
  `spec_rails/dummy_app/spec/axn/early_completion_transaction_spec.rb`). So
  `after_all_transactions_commit` callbacks fire normally there and the feature is directly
  testable. New specs live alongside `early_completion_transaction_spec.rb`.
- Cases to cover:
  - Top-level transactional axn: `on_success` still fires (after commit), unchanged.
  - Nested axn whose outer **commits**: inner `on_success` fires, child-first vs outer.
  - Nested axn whose outer **rolls back**: inner `on_success` does **not** fire.
  - Outer `after` hook runs before inner `on_success` (documents the tradeoff).
  - Failure path: `on_failure`/`on_error`/`on_exception` fire immediately even when an
    enclosing transaction later commits or rolls back (the not-deferred guarantee).
  - No-AR path (in `spec/`, non-Rails): success fires inline.

## Transactional tests in consumers — verified safe, no action needed

The worry was that suites using `use_transactional_tests` wrap each example in a transaction
that *rolls back*, which could suppress every deferred `on_success`. **A spike against
ActiveRecord 7.2.2.2 shows this does not happen**, because Rails opens the fixture transaction
with `joinable: false` — the same mechanism that makes model `after_commit` callbacks fire in
transactional tests makes our deferred dispatch fire too.

Spike results (simulating `ActiveRecord::TestFixtures`' `begin_transaction(joinable: false)`
wrapper, which is exactly what rspec-rails / minitest transactional tests do under the hood):

| Scenario | Behavior |
| --- | --- |
| **A.** Fixture txn (rolls back) + app/axn opens its own `transaction` that commits — the dominant `use :transaction` case | Deferred `on_success` **fires** after the inner commit ✅ |
| **B.** Fixture txn only (no app transaction), under transactional tests | Deferred `on_success` **fires** ✅ |
| **C.** Production shape: app transaction rolls back | Deferred `on_success` **does not fire** ✅ (the bug we're fixing) |

So consumers need **no** test-environment configuration and take **no** action. This is called
out explicitly in the docs.

Note also that the no-enclosing-transaction case is unchanged in **production**: with no open
transaction, `after_all_transactions_commit` yields immediately (inline). The deferral only
alters behavior when a transaction is actually open — i.e. exactly the case that was broken.

## Remaining risk

- This is an unconditional timing change for every existing axn with an `on_success` inside a
  transaction (the outer-`after`-before-inner-`on_success` reordering, plus correct
  skip-on-rollback). There is no opt-out by design — see the rationale above. If an unexpected
  regression surfaces in a large consumer, the recourse is to fix the offending `on_success`
  usage (move transaction-coupled work into `call`/`after`) or, as a last resort, add an
  opt-out flag in a follow-up (a non-breaking change). We accept this given the pre-1.0 status
  and the absence of any known opt-out use case.

## Out of scope

- An opt-out flag (global config or per-action DSL) — deliberately omitted; add later only if
  a real use case appears.
- `after_rollback` / "settle either way" semantics for failure callbacks.
- Per-`on_success`-callback granularity.
- Changing `requires_new:` / savepoint behavior of the `:transaction` strategy.
