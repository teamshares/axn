# Steps: shape hardening before real production use

**Ticket:** (none yet — internal hardening)
**Status:** Design (approved direction, pending spec review)
**Branch:** `kali/improve-steps`

## Problem

`step` / `steps` are fully implemented and documented, but have barely run in production. Before
real usage builds on them, we want to confirm the feature is shaped correctly and close the gaps a
review surfaced. Four threads, plus one explicit non-goal:

1. **The data model is mislabeled.** Code comments call steps "isolated units of work," but the
   runner passes each step the *entire* accumulated context (`@__context.__combined_data`) and
   silently merges each step's exposures back into the parent — later steps overwrite earlier
   exposures with no warning (a passing-data spec relies on exactly this). The intended use case is
   **chaining** (a shared blackboard the steps read and extend), which is the opposite of "isolated."
   Docs and comments should say what the feature actually is.

2. **Custom `#call` + steps is an order-dependent silent footgun.** The generated `#call` is defined
   when `step`/`steps` runs in the class body. If a user also writes `def call`, whichever appears
   last silently wins. This violates the repo's "explicit conflicts raise / inferred behavior defers
   with a breadcrumb" principle (AGENTS.md).

3. **The on_exception / callback contract for step failures is described in docs but untested — and
   wrong.** The runner blanket-`fail!`s the parent whenever a step stops, regardless of *why*. So a
   step that raises an unexpected exception (a bug) gets recategorized as a *deliberate parent
   failure*, firing the parent's `on_failure`. That conflates Axn's two error categories. (Original
   note: "Should have clear specs about what happens when substep fails vs top-level failure in terms
   of global on_exception handler calls.")

4. **No conditional step execution.** Steps always run. (Original note: "Could add conditional
   support (if / unless).")

**Non-goal — rollback.** (Original note: "Could implement a rollback flow…. probably not worth
it.") Confirmed out of scope. Axn already defers `on_success` until the enclosing AR transaction
commits; the natural rollback story is "wrap the orchestrator in a transaction," which steps inherit
for free. No rollback DSL.

## Goals

1. Docs and comments describe steps accurately: a **chaining / shared-blackboard** composition, not
   isolated units.
2. Declaring steps and a custom `#call` on the same class **raises at declaration time**, in either
   declaration order, with a message pointing at `before`/`after` hooks.
3. A **locked, tested contract** for how step failures vs. step exceptions settle the parent and
   which callbacks fire — honoring Axn's failure-vs-exception distinction, with **exactly one**
   global exception report per real bug.
4. **`if:` / `unless:` conditionals** on `step`, matching the Proc/Symbol ergonomics already used by
   hooks and message conditionals.

## Non-goals

- Rollback (above).
- Changing the data-flow model itself. The shared blackboard is the intended design (thread 1 is
  docs/comments only, **no behavior change**).
- Per-step conditions on the bulk `steps(*classes)` form. Conditions are a per-step concern, declared
  via `step`.
- Generalizing prefix-cascade through `call!` for *all* nested actions. Tempting for consistency, but
  it changes `result.error` for every nested action in the codebase and steps don't require it.
  Filed as a separate follow-up; this work stays **step-local** (see §3).

---

## Design

### 1. Rename the model in docs & comments (no behavior change)

The runner's contract is a **shared blackboard**:

- Each step is invoked with the full accumulated context (parent inputs + everything exposed so far).
- Each step's exposures merge back into the parent's `exposed_data`, visible to every later step and
  to the parent's own outbound contract.
- A later step exposing a key already exposed earlier **overwrites** it (intentional — chaining).

Update:
- `lib/axn/mountable/mounting_strategies/step.rb` — the `# Steps default to :none - they are isolated
  units of work` comment is misleading; replace with an accurate description of the chaining model and
  the blackboard merge/overwrite semantics.
- `docs/usage/steps.md` — frame the feature as chaining; make the shared-context and
  later-step-wins-on-collision behavior explicit (today it's only implied). Keep the existing
  examples.

### 2. Custom `#call` + steps → raise at declaration

Declaring steps and defining your own `#call` on the same class is contradictory: the generated
`#call` *is* the orchestrator. Make it an `ArgumentError` at declaration, in **either** order:

- **steps declared when a user `#call` already exists** — detected when `step`/`steps` runs.
- **a user `#call` defined after steps were declared** — detected via `method_added(:call)`.

The generated `#call` must be distinguishable from a user-authored one (e.g. a marker set when the
strategy defines it, checked in `method_added` to avoid self-triggering). **Subclassing stays legal**:
a subclass that adds more steps inherits the generated `#call` and re-mounts normally — it is not a
user-authored `#call` and must not raise.

Message points at the supported alternative:

> `<Class>` declares steps and a custom `#call`. Steps generate the `#call` orchestrator — you can't
> also define one. Use `before`/`after` hooks for setup/teardown around the steps.

Per AGENTS.md "fail at declaration, not runtime."

### 3. Locked failure/exception contract (the core change)

The runner inspects each step's **outcome** and propagates its *category*, instead of flattening
everything to a parent `fail!`. This honors Axn's distinction: `on_failure` means a deliberate
`fail!`; `on_exception` means a real bug bubbled through; `on_error` is the catch-all for both.

Generated `#call`, per step (replaces the current unconditional `fail!`):

```ruby
step_result = axn.call(**@__context.__combined_data)   # non-bang: child fully settles & (for a
                                                        # bug) fires the global report at its own level

if step_result.ok?
  merge step_result's declared exposures into @__context.exposed_data    # (unchanged)
elsif step_result.outcome.failure?
  # Deliberate fail! (or a fails_on-classified exception): an expected failure.
  fail!("#{error_prefix}#{step_result.error}")          # parent settles as FAILURE, prefixed message
else
  # Unclassified exception: a bug. Re-raise the original object.
  raise step_result.exception                            # parent settles as EXCEPTION
end
```

#### Resulting contract

**Step calls `fail!`** (deliberate failure):
| Level | Callbacks | Global report |
|---|---|---|
| Step | `on_failure` + `on_error` | none |
| Parent | settles as **failure** → `on_failure` + `on_error`; `on_exception` does *not* fire | none |

Net global reports: **0**. Parent `result.error` = `"#{error_prefix}#{child.error}"` — byte-identical
to today (the failure path still reads `child.result.error` and `fail!`s, preserving the existing
prefix cascade, including parent-base headlining).

**Step raises an unclassified exception** (a bug):
| Level | Callbacks | Global report |
|---|---|---|
| Step | `on_exception` + `on_error` | ×1 (at the step, with the step's context) |
| Parent | settles as **exception** → `on_exception` + `on_error`; **`on_failure` does *not* fire** | deduped (the same object is already `reported?`) |

Net global reports: **1**, attributed to the step. The parent observing it via `on_exception` is
consistent with Axn's existing nested-`call!` semantics (per-action `:exception` callbacks fire at
each level; the global report is deduped per exception object).

**Step calls `done!`** (early completion): the step settles ok, its exposures merge, the parent
continues to the next step.

#### Why non-bang `call` + outcome branch, not a blanket `call!`

Switching wholesale to `call!` would lose the **per-step prefix** on the failure path — the
historical blocker noted as "we hadn't figured out how to prefix the raised message." Reading the
resolver confirms the prefix problem only ever existed on the failure path (`fail!` already solves
it); a bubbling *exception* never surfaces its raw message as `result.error` anyway (Axn shows the
declared base `error` / `"Something went wrong"`, deliberately hiding internals). So the hybrid gives
us the honest classification on the exception path **and** keeps failure messages exactly as they are
today — no new prefix machinery.

#### Consequence on the exception path (accepted)

The parent's surfaced `result.error` on the exception path becomes its declared base `error` /
`"Something went wrong"` — it **loses** the `"stepname: "` segment (full detail still goes to the
exception report). Concretely, the existing spec asserting
`"Onboarding failed: setup: Something went wrong"` changes to `"Onboarding failed"`. This is the
deliberate, consistent choice (matches how Axn hides exception internals everywhere else); updating
that spec is part of this work.

**Step identity in the report:** each mounted step is registered as a namespaced constant, so the
report's `resource` (the child class name) already identifies the step. Verify this during
implementation; only if it does *not* surface the step identity, add a breadcrumb to the step's
exception context. No change to the caller-facing message either way.

### 4. `if:` / `unless:` conditionals on `step`

```ruby
step :charge_card,  ChargeCard,  if:     -> { plan.paid? }
step :send_invoice, SendInvoice, unless: :free_tier?
step :provision,    Provision,   if: :ready?, unless: :dry_run?   # both → AND
```

- Accept a **Proc** (instance-`exec`'d on the parent) or a **Symbol** (a parent method) — the same
  pairing hooks and message conditionals already accept.
- Evaluated on the parent instance **immediately before** that step would run, so a condition reads
  data exactly as the rest of the action does — reusing existing seams, no new accessor:
  - **inputs** via the `expects` reader (`-> { tier == "paid" }`) or `inputs` (`-> { inputs[:tier] }`).
  - **a prior step's output** via `result.<field>` (`-> { result.flag }`) — the sanctioned exposure
    read (same as `success`/`error`/`sensitive:` procs). The parent must declare the field in
    `exposes`; the earlier step's value is live by the time the condition runs.
  - A **bare** reference to an undeclared name (`-> { flag }`) raises `NameError` — `exposes` defines
    no bare instance readers, by design. (Verified during implementation: this is the only thing that
    doesn't work; `result.<field>` covers branching on prior steps, so no `ctx` arg / `exposures`
    accessor is added.)
- `if:` and `unless:` **may be combined** (the step runs only if `if` passes *and* `unless` fails) —
  matching Rails callback ergonomics. (Note: this deliberately differs from message conditionals,
  which reject `if:`+`unless:` together; for a guard condition the AND combination is normal and
  useful.)
- A **skipped** step simply does not execute: no exposures, no failure, the runner moves to the next
  step.
- Stored in the step descriptor's options; the generated `#call` checks them before invoking each
  step. The bulk `steps(*classes)` form takes no conditions.

---

## Testing

Non-Rails `spec/` (POROs); add `spec_rails/dummy_app/` coverage only where AR transaction behavior is
asserted (per AGENTS.md). Extend `spec/axn/mountable/steps/`.

**Model/docs (1):** a passing-data spec already documents collision-overwrite; add an explicit
assertion that a later step overwrites an earlier exposure (lock the blackboard contract).

**Custom `#call` collision (2):**
- steps then `def call` → raises `ArgumentError` with the hooks hint.
- `def call` then steps → raises the same.
- a subclass adding steps to a steps-using parent does **not** raise and runs all steps.

**Failure/exception contract (3)** — the centerpiece, currently untested. Using a spy on
`Axn.config.on_exception` and per-action `on_failure`/`on_exception`/`on_error` callbacks:
- step `fail!` → step `on_failure`+`on_error`, parent `on_failure`+`on_error`, parent **not**
  `on_exception`, **0** global reports; `result.error` keeps the `"stepname: "` prefix (and parent
  base cascade when declared) — assert byte-identical to current output.
- step raises unclassified → step `on_exception`+`on_error`, parent `on_exception`+`on_error`, parent
  **not** `on_failure`, **exactly 1** global report; parent `result.error` is the declared base /
  `"Something went wrong"` (update the existing `"…: setup: Something went wrong"` assertion).
- step `done!` → settles ok, exposures merge, next step runs.
- step exception classified as failure via the step's own `fails_on` → travels the failure path
  (parent failure, prefixed, no report).
- report-dedup across depth: one global report even with nested step-mounting parents.

**Conditionals (4):**
- `if:` Proc true/false; `unless:` Proc true/false; Symbol forms; combined `if:`+`unless:` (all four
  truth combinations).
- skipped step exposes nothing and does not fail; later steps still run.
- a condition reads a parent `expects` input (direct reader and via `inputs`), and a prior step's
  exposure via `result.<field>`; a bare reference to an undeclared name raises `NameError`.

## CHANGELOG

- `[FIX]` step exceptions now settle the parent as an **exception** (fires `on_exception`), not a
  failure — a step raising an unexpected error no longer fires the parent's `on_failure`. Deliberate
  `fail!` in a step still settles the parent as a **failure**. `on_error` fires for both. Global
  exception reporting is unchanged: exactly one report per bug, at the step.
  - **Behavior change:** on the exception path the parent's `result.error` is now its declared base
    `error` / `"Something went wrong"` (was `"<base>: <stepname>: …"`). Failure-path messages are
    unchanged.
- `[FEAT]` `step … if:`/`unless:` (Proc or Symbol; combinable) to run a step conditionally.
- `[FIX]` declaring steps and a custom `#call` on the same class now raises at declaration (was:
  silent, order-dependent override).
- `[DOCS]` steps documented as a chaining / shared-blackboard composition (shared accumulated
  context; later step wins on exposure collision).

## Open questions / risks

- **Blast radius of the exception-path message change.** Any internal/os-app step orchestrator that
  asserts on `result.error` for a step *exception* (not a `fail!`) will see the message change. Step
  *failure* messages are unchanged. Grep step consumers during rollout; expected to be ~none given
  steps' minimal production use (the premise of this work).
- **`method_added` interplay.** The collision guard must not trip on the strategy's own generated
  `#call`, nor on inheritance. Pin the marker/guard mechanics in implementation with the subclass
  test above.
- **Condition evaluation context.** Resolved by reusing existing seams: conditions read inputs (the
  `expects` reader or `inputs`) and prior-step output (`result.<field>`). No new accessor was needed.
  Only a bare reference to an undeclared name raises `NameError` (no bare exposure readers, by
  design) — documented, not worked around.
