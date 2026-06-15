# Design: `fails_on` (reclassify exceptions as failures) + a `:model` strategy

- **Ticket:** PRO-2672 — [Axn] Reclassify exceptions as failures (`fails_on` declaration + `use :model` strategy)
- **Date:** 2026-06-15
- **Status:** Implemented (TDD; full suite green) — pending review / docs / CHANGELOG

## Problem

When an Axn `call` raises, the executor routes the exception through
`Executor#trigger_on_exception` → `Axn.config.on_exception` (the global handler;
Honeybadger in os-app). The class-level `error if: SomeException` declaration only
selects the `result.error` **message** — it does **not** suppress the global report.

So there is no declarative way to say *"treat this exception class as an expected,
user-facing failure: settle as a failure with a nice message, but don't report it
globally."* Today that requires manually `rescue`-ing inside `call` and calling
`fail!` (see `Actions::LedgerEvent::ChangeTeamsharesShareholder#save_changes` in
os-app), while sibling actions using `error if: ActiveRecord::RecordInvalid` accept
the Honeybadger noise.

### What os-app actually does (survey)

- **~98 actions (37%) save an ActiveRecord model**; `update!` (72) dominates over
  `save!`/`create!`. ~52 use `use :transaction`.
- **13 actions declare `error if: ActiveRecord::RecordInvalid`**, almost all turning
  `record.errors.full_messages.to_sentence` into a message — and **all 13 currently
  leak `RecordInvalid` to Honeybadger.** This is the real, widespread pain, not just
  the two files named in the ticket.
- Param handling before save is **highly varied** (40% untouched, 15% slice/permit,
  35% domain-specific: computed fields, injected `created_by`/`reviewed_by`, enum
  remapping). It is **not** abstractable as strategy magic — it must stay a per-action
  concern, but it can be delegated to a hook (the way `use :form` delegates to a form
  object).
- `use :form` is niche (4 actions) and the wrong tool when there is a real model and
  no form object.

## The reframing: error vs failure

Axn already has a three-way outcome taxonomy (`Result#outcome`, `result.rb:71`):

| Outcome | Trigger | Reported globally? | Callbacks |
|---|---|---|---|
| `success` | normal return / `done!` | — | `on_success` |
| `failure` | `fail!` (`Axn::Failure`) | **no** | `on_failure`, `on_error` |
| `exception` | any other raised error | **yes** | `on_exception`, `on_error` |

The feature request is simply: *let some raised exception classes be reclassified
from the `exception` bucket into the `failure` bucket.* That single sentence is the
mental model we will teach.

**Key constraint — preserve the original exception.** We reclassify by *routing*
(fire `on_failure`, report `outcome.failure?`, skip `on_exception` + global report)
**without wrapping the exception in `Axn::Failure`.** `result.exception` keeps the
original (e.g. the `RecordInvalid`). This is what lets the existing `error if:
SomeException` message resolution keep working unchanged (`result.rb:53` resolves
non-`Failure` exceptions through the `error` DSL) — satisfying the ticket's "message
resolution / ordering unchanged" for free.

(A rescue→`fail!` approach would wrap in `Axn::Failure`, lose the exception identity,
and break `error if:` matching. We explicitly avoid that.)

## Architecture: three layers

```
core seam  →  fails_on              →  use :model
(mechanism)    (declaration / DSL)     (ergonomic, model-saving sugar)
```

### Layer 1 — Core seam (mechanism)

Core gains an internal, unopinionated "does this action reclassify this exception as a
failure?" capability. The mechanism itself **never names a specific exception class** —
classes are named by the `fails_on` declaration (Layer 2).

- A class-level registry of reclassified-exception matchers (a `class_attribute`) plus
  a predicate `_fails_on?(exception)`.
- `Executor#with_exception_handling` (`executor.rb:200`) branch becomes:
  ```ruby
  if e.is_a?(Failure) || @action_class._fails_on?(e)
    @action_class._dispatch_callbacks(:failure, action: @action, exception: e)
  else
    trigger_on_exception(e)
  end
  ```
  `on_error` still dispatches unconditionally first (`executor.rb:198`), so it fires
  for reclassified exceptions too — consistent with its "both fail! and exceptions"
  contract.
- `Result#outcome` (`result.rb:72`) classifies reclassified exceptions as
  `OUTCOME_FAILURE` (it has `@action`, so it can consult
  `@action.class._fails_on?(exception)`).
- Async parity: `Async::ExceptionReporting.trigger_on_exception`
  (`exception_reporting.rb:32`) guards the global call with the same predicate, so
  discarded/exhausted async jobs also skip the report for reclassified exceptions.

### Layer 2 — `fails_on` (top-level declaration)

The public primitive. A class-level declaration (peer to `error`/`success`/`expects`,
**not** a `use :` strategy — it only registers config, it adds no hooks/orchestration).
Registers exception classes as failures and, optionally, wires their message.

```ruby
fails_on ActiveRecord::RecordInvalid                              # default message
fails_on ActiveRecord::RecordInvalid, "Unable to submit"          # string message
fails_on(ActiveRecord::RecordInvalid) { |e| e.record.errors.full_messages.to_sentence }  # block
fails_on [RecordInvalid, RecordNotUnique], "Couldn't save"        # array for multiple
```

Signature: `fails_on(exceptions, message = nil, &block)` — the `error(message = nil,
if:, &block)` shape with the exception list standing in for `if:`. It rides existing
`fail!`/`error` muscle memory: message as a positional string (like `fail!("msg")`) or a
block that receives the exception (like `error { |e| … }`).

- `exceptions` — a class or array of classes, added to the Layer-1 registry.
- `message`/block (optional) — when given, registers the same kind of `error`-descriptor
  against those classes (so message resolution stays unified). Omit it to supply your
  own `error if:` or fall back to the default message.

No rescue, no `fail!`, no `Axn::Failure` wrapping — just reclassification + optional
message.

### Layer 3 — `use :model`

Built on `fails_on` (auto-declares `fails_on ActiveRecord::RecordInvalid`). Standardizes
the dominant "build/find a model, apply attributes, save, settle validation failures
cleanly" pattern. Sibling to `use :form`: *validate via a form object → `use :form`;
validate via the AR model directly → `use :model`.*

#### Forms (mode resolution)

| Declaration | Mode | Auto-contract for the model |
|---|---|---|
| `use :model, as: :user` | upsert (decide at runtime) | `expects :user, model: true, optional: true` |
| `use :model, update: :user` | update-only | `expects :user, model: true` (**required**) |
| `use :model, create: User` | create-only | none fed in; exposes the record |

- **Upsert** (`as:`): update the record if one was provided (or found via `:user_id`),
  otherwise build a new one. The least to type; the common case.
- **`update:`** flips the auto-`expects` to required, for actions where building a
  fresh record is nonsense (e.g. `UpdateProfile`).
- **`create:`** takes the class explicitly, covering field-name ≠ class-name (e.g.
  `create: CapTable::Event, as: :event`).
- Class derivation: `model: true` already derives the class from the field name
  (`model_validator.rb:13`, `:user → User`), so `as:`/`update:` need only the symbol.
- Explicit `persist: :create | :update` may override inference at a callsite.

#### Exposure naming

- `as:` is **fully optional**. Exposure name = `as:` if given, else the
  `update:`/`as:` symbol, else **`:model`** (so `result.model` always works
  generically regardless of form).

#### No manual `expects`

The strategy auto-declares:
- `expects :params, optional: true` (override the key with `expect:`, mirroring
  `:form`).
- the model field per the table above.

If the action **pre-declares** the model field (e.g. needs a custom `finder:` or extra
options), the strategy uses the existing declaration instead of adding its own.

#### Param hook

An optional, overridable instance method supplies the attributes — the seam that keeps
domain-specific param logic in the action (mirrors how `:form` delegates to the form
object). Runs in full instance context, so it can reference other fields/helpers.

```ruby
def model_params = params.slice(*PERMITTED).merge(updated_by: Current.user)
```

- Defaults to `params` when undefined.
- Covers slice/permit, inject context fields, transform/coerce, or replace entirely.
- `inject:` sugar mirrors `:form` for the common "merge these context fields" case:
  `use :model, as: :user, inject: [:company]` merges `{ company: }` into `model_params`
  without writing the method.

#### Orchestration — prepare-and-gate in `before`, `call` is post-save logic

This mirrors `use :form`: both strategies prepare and gate in `before`, leaving the
rest to `call`. `:form` gates on `form.valid?` (a form object has nothing to persist —
the action persists downstream); `:model` gates **and persists**, because the model is
the artifact.

1. `before` #1: resolve the record (provided/found for update, or `Klass.new` for
   create), assign `model_params`, and `expose` it (so views can render it — including
   on failure, with `record.errors` populated).
2. `before` #2: `fail!(<error message>) unless record.save` — aborts before `call` if
   the record can't persist.
3. `call`: optional post-save logic, now with a persisted record (default no-op). This
   is where actions do their "save then …" work — AASM transitions, related records,
   notifications, sub-actions.

Saving in `before` (not `call`) avoids a footgun: if the save lived in a default `call`,
a user-defined `call` (for post-save work) would silently override it and nothing would
persist. In `before`, the save always happens regardless of whether `call` is defined.

`fails_on ActiveRecord::RecordInvalid` is still wired as a **safety net** (it is not hit
on the happy path): non-bang `record.save` turns routine model-validation failures into
a clean failure (no raise; `record.errors` populated for form rendering), while a
*raised* `RecordInvalid` (association autosave, an explicit `save!` in `call`,
`validate!`, or nested code) is caught by the `fails_on` reclassification.

**Rollback is preserved.** `fail!` raises `Axn::Failure` internally, which propagates
out of a `use :transaction` block (that block only rescues `EarlyCompletion`) and rolls
back. Note that a `call` doing post-save work that fails will leave the record committed
**unless** wrapped in `use :transaction` — standard guidance for any save-then-work
action.

> **Tradeoff — imperative pre-save manipulation.** Since `call` now runs after the save,
> imperative tweaks to the record beyond `model_params` attributes (e.g. mutating an
> association before save) have no natural home. Rare in the os-app survey (mostly the
> multi-model cases, which don't fit `:model` anyway). For v1 these go in `model_params`
> or stay hand-written; a future `save: false` opt-out (action controls the save point
> in `call`) is the escape hatch if it proves common.

#### Fit boundary (os-app survey)

Against the model create/update actions, with the prepare-and-gate-in-`before`
orchestration:

- **Folds with no `call`** — simple creators and attribute updaters; the `before` save
  is the whole action (e.g. `Distribution::Create`, `Loan::Create`,
  `User::UpdateProfile`).
- **Folds with a post-save `call`** — actions that save then do more work; the save
  happens in `before`, their post-save logic lives in `call` (e.g.
  `Company::UpdateCompanyInfo`'s AASM transition, `Company::Exits::Create`'s cleanup
  sub-actions, `Distribution::Confirm`'s `.confirm!`).
- **Does not fit `:model`** (~40%) — multi-model saves (e.g.
  `ChangeTeamsharesShareholder`, `CapTable::Event::Create::Issue`), AASM-driven
  approval/finalize workflows, multi-sub-action orchestrators, and actions needing
  imperative *pre-save* manipulation. These stay hand-written but can still adopt the
  **`fails_on`** declaration for the silencing — which alone resolves the ticket for
  them.

#### Messages — register through the DSL, don't `fail!("string")`

`:model` registers its defaults through the ordinary `success`/`error` DSL in its
`included` block, and the save-gate aborts with a **bare `fail!`** (no message). This
keeps a single resolution path and lets overrides use the normal DSL.

Why not `fail!("#{prefix}#{full_messages}")`? An explicit string sets
`_user_provided_error_message` (`result.rb:132`), which **short-circuits the message
resolver** — so the `error`/`fails_on` DSL could no longer override it, and it would be
a second, divergent message path from the raised-`RecordInvalid` safety net.

What `:model` registers at the `use :model` line:

```ruby
success { "#{__model_created? ? 'Created' : 'Updated'} #{__model_human_name}" }

# Clean validation body (NOT exception.message). Matched when the gated save failed.
error(if: :__model_invalid?, prefix: config[:error_prefix]) do
  record.errors.full_messages.to_sentence
end
```

and the gate is simply `fail! unless record.save`.

**Resolution trace (`registry.rb` prepends → last-defined wins; `message_resolver.rb`
picks the first matching descriptor):**

- *Happy path:* `record.save` → `false` → bare `fail!`. The `Failure` has a default
  message, so `_user_provided_error_message` is `nil` and the resolver runs; `:model`'s
  `error(if: :__model_invalid?)` matches (record exposed and invalid) → `"<prefix><full
  messages>"`. No `"Validation failed:"` noise, because the body comes from a handler
  rather than the `exception.message` fallback.
- *Safety net:* a *raised* `RecordInvalid` (an explicit `save!`, association autosave,
  `validate!`, nested action) is reclassified by the auto-wired
  `fails_on ActiveRecord::RecordInvalid` (registered without its own message); the same
  `error(if: :__model_invalid?)` descriptor produces the identical body. One body, both
  paths.

**Override surface:**

- **Prefix only:** `use :model, error_prefix: "Unable to update profile: "` sets
  `prefix:` on the registered descriptor; the default `full_messages` body stays. (This
  is exactly what bare `prefix:` on `error` can't do, since it'd fall back to
  `exception.message` — which is why `:model` owns the body.)
- **Success string:** `use :model, success: "Profile updated"`, or declare `success "…"`
  after `use :model`.
- **Full override:** declare your own `error(if: :__model_invalid?) { … }` /
  `fails_on` / `success` *after* `use :model` — registered later, so it's evaluated
  first and wins. Standard Axn message behavior; nothing `:model`-specific.

**Open implementation details (planning):** the `__model_invalid?` matcher (record
present and `errors.any?`; when an exception is present, prefer `exception.record.errors`
for the nested-autosave edge), single-descriptor-vs-two, and the `error_prefix:`/
`success:` kwarg names.

## Worked examples

```ruby
# Update — was: expects + error-if-RecordInvalid handler leaking to Honeybadger
class Actions::User::UpdateProfile
  include Axn
  use :model, update: :user, error_prefix: "Unable to update profile: "

  PERMITTED = %i[first_name last_name title bio].freeze
  def model_params = params.to_h.symbolize_keys.slice(*PERMITTED)
end

# Create
class Actions::Distribution::Create
  include Axn
  use :model, create: Distribution, as: :distribution
  use :transaction

  def model_params
    params.merge(company:, created_by: Current.user, dividend: dividend_amount, buyback: buyback_amount)
  end
end

# Low-level: reclassify a non-model exception class as a failure, without :model
fails_on SomeGem::RateLimited, "Service busy, try again shortly"
```

## Semantics summary

For a matched `fails_on` exception:
- `result.ok?` is `false`; `result.outcome.failure?` is `true`.
- `result.exception` is the **original** exception (not wrapped in `Axn::Failure`).
- `result.error` resolves via the existing message DSL (or the message wired into
  `fails_on`).
- `on_error` and `on_failure` fire; `on_exception` does **not**.
- `Axn.config.on_exception` (global report) is **skipped**, sync and async.

## Goals / Non-goals

**Goals**
- Declarative, idiomatic way to reclassify chosen exception classes as failures.
- Remove the manual `rescue … fail!` workaround and de-noise the 13 leaking actions.
- A `:model` strategy that standardizes model-saving actions with minimal boilerplate.

**Non-goals**
- No param-massaging magic — transformation stays in `model_params`.
- No multi-model orchestration in `:model` (those stay custom; cf. the
  validate-both-then-save pattern in `ChangeTeamsharesShareholder`).
- Core's *mechanism* (Layer 1) names no exception classes; `fails_on` is the only place
  classes are named.

## Open decisions (resolve during review / planning)

1. **Message override ergonomics.** (Resolved — see below.)
2. **`:model` success/error defaults: on by default, or opt-in?** (Resolved.) Shipped
   **on by default** (mode-aware "Created/Updated <model>" success + validation-error
   message), overridable via `success:`/`error_prefix:` or a later `success`/`error`/
   `fails_on` declaration.
3. **`use :transaction` stays explicit — `:model` does NOT auto-wrap.** (Resolved.)
   For the simplest case (single save, no `call`) a transaction is moot — a lone failed
   save persists nothing. It only matters once `call` does post-save work: a *succeeded*
   save followed by a failing `call` would orphan the committed record. But auto-wrapping
   is rejected because post-save `call` work is frequently non-DB side effects (enqueue
   jobs, send email, external APIs), and an implicit transaction around those is an
   anti-pattern (job runs before commit; DB connection held during I/O). Whether a
   transaction is wanted is action-specific (DB writes → yes; side effects → no), so it
   stays an explicit, composable `use :transaction` (~52 os-app actions already pair
   them) and `:model` stays single-purpose.
4. **`use :model` strategy name** vs the `model:` kwarg on `expects` — accepted as a
   mild, different-syntactic-slot collision in favor of the `:form`/`:model` parallel.

## Testing approach

- Core seam: a `fails_on` exception → `outcome.failure?`, `on_failure` fires,
  `on_exception` and global `on_exception` do not; `result.exception` preserved;
  message resolves via `error if:`. Sync and async (discarded job) paths.
- `fails_on`: single class / array; positional-string vs block message vs no message;
  block receives the exception; interaction with a separately-declared `error if:`.
- `:model`: create / update / upsert resolution; `as:` default to `:model`;
  auto-`expects` (and respecting a pre-declared model field); `model_params` default
  and override; `inject:`; validation failure → failure with `record.errors`
  populated and no global report; success/error message defaults and overrides;
  composition with `use :transaction`.

## os-app follow-up (after release)

- `Actions::LedgerEvent::ChangeTeamsharesShareholder`: delete the manual `rescue
  ActiveRecord::RecordInvalid` in `save_changes`; use the new declarative path.
- Revisit the 13 `error if: ActiveRecord::RecordInvalid` actions: adopt
  `use :model` / `fails_on` to stop the Honeybadger leak.
