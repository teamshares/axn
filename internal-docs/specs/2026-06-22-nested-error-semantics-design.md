# Clearer semantics for nested error messages

**Ticket:** PRO-2746
**Status:** Design (approved direction, pending spec review)
**Branch:** `kali/pro-2746-axn-clearer-semantics-for-nested-error-messages`

## Problem

The ticket bundles several symptoms that all trace to **one mechanism**: the nested-only
behavior of `call!` in `lib/axn/core.rb:36-44`.

```ruby
def call!(**)
  result = call(**)
  return result if result.ok?

  # When nested, raise a NEW Failure wrapping result.error + source, to support `from:`
  raise Axn::Failure.new(result.error, source: result.__action__), cause: result.exception if _nested_in_another_axn?

  raise result.exception
end
```

When an inner Axn fails inside an outer one, `call!` behaves **differently than at the top
level**: instead of re-raising the original exception, it wraps it in a fresh `Axn::Failure`
carrying the child's resolved message and a `source` pointer. That single behavior:

1. Powers `error from:` message matching (the only consumer of `source`).
2. Is why `Axn::Failure` shows up in Honeybadger for nested cases (PR-1806), with no consistent
   mental model for "when does `fail!` / `Axn::Failure` report?".
3. Makes "the same code acts differently when nested" — the exact unpredictability that a base
   layer should not have.

Separately, the ticket asks for two ergonomics:

- **Suppress exception *reporting* when an outer handles an inner failure** (the Zendesk
  `Faraday::BadRequestError` "email already used" case sends a Honeybadger notice for a failure the
  outer `Sync` action explicitly handles).
- **A user-friendly way to add a contextual prefix to error messages** — e.g. an orchestrator that
  fails with `"Doing subthing A failed: <child error>"` instead of a bare child message that has no
  idea it ran in a multi-step context.

## Goals

1. **One mental model for `Axn::Failure`**: it means *"this action called `fail!`"* — everywhere,
   nested or top-level. Identical behavior regardless of nesting depth.
2. **Contextual error messages as a first-class, predictable feature**: a declared base `error`
   prefixes the action's specific failure reasons, so a child's errors are self-describing at the
   source — no parent-side magic required.
3. **No new reporting API**: `fails_on` (shipped after the ticket notes were written) already covers
   the legitimate "expected failure → don't report" case, at the correct semantic home.
4. **Predictability over flexibility**: every rule is knowable locally; no behavior that depends on
   an invisible toggle far from the call site.

## Non-goals

- A `suppress_nested_report { … }` block (the notes' original proposal). `fails_on` covers the
  legitimate case; the remaining "contextually hide an otherwise-reportable bug" case is an
  anti-pattern we decline to build until something concrete demands it.
- Success-message *reporting* changes. Success message **prefixing** is in scope (parity); success
  reporting is unaffected.
- A per-action config to toggle prefixing on/off (`prefix_failures`). Deferred — the universal rule
  + declared-base gate covers the need without the non-locality of a far-away switch. Revisit only
  if a real need for action-wide *suppression* appears.

---

## Design

### Mental model

> **The action's declared base `error` is a headline. Every other failure message — a conditional
> `error … if:`, `fail!`, `done!` — is a specific *reason* shown as `"<headline><delimiter><reason>"`
> by default. Opt any one reason out with `prefixed: false`.**
>
> With **no declared base**, reasons stand alone and `"Something went wrong"` remains the
> bare-exception fallback (today's behavior, unchanged).

`success` mirrors `error` exactly: a declared base `success` prefixes `success … if:` and `done!`
messages.

### 1. Message prefixing (`prefixed:`, base `error`, `delimiter:`)

```ruby
class Actions::Zendesk::User::Sync
  include Axn

  error "Couldn't sync user"                         # base / headline. Also the fallback.
  error "Vendor not found", if: NotFound, prefixed: false   # → "Vendor not found"  (standalone)
  error(if: RecordInvalid, &:message)                # → "Couldn't sync user: <validation>"  (prefixed by default)

  def call
    fail!("email already taken")                     # → "Couldn't sync user: email already taken"
    fail!("Account is locked.", prefixed: false)     # → "Account is locked."
  end
end
```

- **Base `error`**: the unconditional `error "…"` declaration — string **or** block; the handler
  kind carries no meaning, conditionality alone sets the role (revised during implementation, see
  `prefixed:` validity below). It is the headline / prefix source and the bare-exception fallback.
  It is never itself prefixed unless explicitly promoted with `prefixed: true`.
- **`prefixed:`** — boolean, controls whether a given reason receives the base prefix.
  - **Default `true`** (composition is the preferred pattern for downstream context).
  - **Gated by a declared base**: with no base declared, there is nothing to prefix, so reasons
    render standalone regardless of `prefixed:`.
  - **`prefixed: false`** opts a single reason out — locally visible at its declaration / `fail!`
    call, so the behavior is readable without scrolling.
- **`delimiter:`** — the join string between headline and reason, declared on the base; default
  `": "`. (Named `delimiter` rather than `prefix_separator`/`suffix_separator`: rarely touched, and
  the double-word kwarg felt awkward.)

  ```ruby
  error "Couldn't sync user", delimiter: " — "   # → "Couldn't sync user — email taken"
  ```

#### `prefixed:` role & validity

> **Revised during implementation** (commit "Make message base/reason role hinge on conditionality,
> not literal-vs-block"). The original design rejected `prefixed: true` on a static unconditional
> message at declaration. The shipped behavior instead lets it *promote*: conditionality alone sets
> the default role, and `prefixed:` is the explicit override. This is what the CHANGELOG, the
> `messages_prefix_spec` suite, and `MessageDescriptor.build` all implement.

- **Default role** is set by conditionality, independent of handler kind: an *unconditional*
  `error`/`success` (string **or** block) is the **base headline**; a *conditional* (`if:`/`unless:`)
  one is a prefixed **reason**.
- **`prefixed: true`** is the explicit override: it *promotes* an unconditional entry to a prefixed
  reason — no `ArgumentError` is raised. This is what enables the **unconditional dynamic detail**
  form `error(prefixed: true, &:message)` → always `"<base>: <exception.message>"` (replaces the
  removed `prefix:`-only pattern, see Migration).
- **`delimiter:` validity still fails at declaration**: `delimiter:` only applies to the base (an
  unconditional, non-prefixed headline). Combining it with `prefixed: true` or a conditional entry
  raises `ArgumentError`, since those are reasons, not the base.

#### Resolution order

Preserves today's first-match semantics:

1. Evaluate error descriptors in registration order; first matching conditional/dynamic reason wins.
2. If that reason is `prefixed` (and a base exists), render `"<base><delimiter><reason>"`; else the
   reason alone.
3. If no reason matches, render the base alone (or `"Something went wrong"` if no base).
4. A `fail!` message is a runtime reason: `"<base><delimiter><message>"` by default (base exists,
   not `prefixed: false`), else the message alone. `fail!` no longer short-circuits the resolver's
   prefix logic.

### 2. Remove the nested-only machinery (BREAKING)

- **`error from:`** — the DSL, the `from:` matcher in
  `lib/axn/core/flow/handlers/descriptors/message_descriptor.rb`, and its declaration validation in
  `lib/axn/core/flow/messages.rb:25,28`.
- **Nested wrapping in `call!`** (`lib/axn/core.rb:40-42`) — a nested `call!` re-raises exactly like
  top-level: `raise result.exception`.
- **`Axn::Failure#source`** (`lib/axn/exceptions.rb:13`) — only existed for `from:`.
- **The `result.rb:135` cause-hack** (`return if exception.cause # We raised this ourselves from
  nesting`) — no longer needed once wrapping is gone.
- **Per-message `prefix:`** on `error`/`success` — its only consumers were `from:`-paired
  (os-app) or internal strategies (migrated below). The base-`error` + `prefixed:` mechanism
  replaces it.

**Result**: `Axn::Failure` means exactly `fail!` everywhere. A nested failure surfaces the inner's
original exception (an `Axn::Failure` from `fail!`, or the raw exception), identical to top-level.
To reshape a child's error with context, the parent uses the explicit idiom:

```ruby
result = ChargeCard.call(...)
fail!("Doing subthing A failed: #{result.error}") unless result.ok?
```

This is per-call-site (a class-level `from:` matcher could not distinguish two invocations of the
same child class anyway), greppable, and reads for the caller.

### 3. Reporting: `fails_on` (documentation only)

No code. The Zendesk case (`Faraday::BadRequestError` = "email already used", an expected business
outcome) is solved by the **inner** action declaring `fails_on Faraday::BadRequestError`:
reclassifies it into the *failure* bucket → fires `on_failure`, **skips** `Axn.config.on_exception`,
and preserves the original exception on `result.exception`. The outer handles via `!result.ok?` or
by rescuing.

Document the pattern and the rationale (expected failure belongs at the action that knows it's
expected, not a contextual outer block).

---

## Internal consumers to migrate (first-party, part of this work)

These `lib/` strategies depend on machinery being removed and must migrate (with their specs). Both
become *simpler* on the new primitives.

### `step` (`lib/axn/mountable/mounting_strategies/step.rb:41-46`) — keep `error_prefix:`, rewrite internals

Today:
```ruby
error_prefix = descriptor.options[:error_prefix] || "#{descriptor.name}: "
target.error from: axn_klass do |e|
  "#{error_prefix}#{e.message}"
end
# ...and the generated #call runs each step via axn.call!(...)
```
Depends on `error from:` + nested wrapping (the child runs via `call!`, the wrapped `Axn::Failure`
is matched by `from:`). Migrate the generated `#call` to run the child with **non-bang `call`** and
`fail!` on failure with the step's prefix:
```ruby
result = axn_klass.call(**combined_data)
fail!("#{error_prefix}#{result.error}") unless result.ok?   # prefixed: true (default)
```
The user-facing `step … error_prefix:` kwarg and its `"#{descriptor.name}: "` default are
**unchanged** (kept verbatim — it is genuinely a per-step error prefix, never standalone; `name`
remains the step's identity for mounting). Because the `fail!` uses the **default `prefixed: true`**
and prefixing is gated by a declared base, **parent-base cascade is a free, opt-in behavior**:

| Parent declares base `error`? | Step failure renders |
|---|---|
| No (today's only os-app usage) | `"<error_prefix><child error>"` — identical to today |
| Yes | `"<parent base><delimiter><error_prefix><child error>"` — cascades |

The orchestrator decides cascade by whether it declares a base error; `step` needs no
step-specific `prefixed` handling.

### `use :model` (`lib/axn/strategies/model.rb:189-210`) — remove `error_prefix:`

Today declares the validation-body error with per-message `prefix:`:
```ruby
error(if: ->(...) { ... }, prefix: configured_prefix) do |exception = nil|
  __axn_invalid_record(exception).errors.full_messages.to_sentence
end
```
Under the new rules the validation body is simply `prefixed: true` (default). A user-declared base
`error "…"` (a normal DSL declaration after `use :model`, already the documented override path)
prefixes it automatically. So the `error_prefix:` kwarg is **redundant and removed** — it is still
`## Unreleased`, so this is a clean removal, not a breaking change:
```ruby
use :model, create: Widget
error "Couldn't save widget"      # validation body → "Couldn't save widget: <validation>"
```
With no base declared, the validation body stands alone (today's no-prefix default). The asymmetry
vs. `step` is intentional: one action needs one base; an orchestrator needs a *per-step* prefix with
no base equivalent.

---

## External migration (os-app; we control rollout)

`error from:` / per-message `prefix:` (4 sites):
- `app/actions/distribution/confirm.rb:11` (`from:` + `prefix:`) → explicit `call` + `fail!`.
- `app/actions/company/exits/create.rb:16` (`from:` + `prefix:`) → explicit `call` + `fail!`.
- `app/actions/modern_treasury/internal_account/destroy.rb:9` (`prefix:`-only) → base `error` +
  `error(prefixed: true, &:message)`.
- `app/actions/codat/company/create.rb:10` (`prefix:`-only) → base `error` +
  `error(prefixed: true, &:message)`.

Manual-composition sites (7) — these **simplify**; if left unmigrated in an action that has a base,
they **double** (`"base: base: …"`), so they must be done with the rollout:
- `[default_error, e.message].join(": ")` in `distribution/approve.rb:13`,
  `company/exits/{create,finalize}.rb` → `error(if: …, &:message)` (prefixed by default).
- `fail! "#{default_error}: #{reason}"` in `codat/connection/create.rb:15-16`,
  `distribution/approve.rb:92,102`, `user/deactivate.rb:30` → `fail!("#{reason}")` (drop the manual
  prefix).

Standalone reasons in actions that **have** a base error → add `prefixed: false` where the message
is already complete (~10% of `fail!`s; the ~75% specific-reason `fail!`s and all `&:message`
validations improve for free).

Zendesk sync (`sync.rb:15,97,121,127`, `sync_memberships.rb:24`) — the `rescue Axn::Failure` +
`error.is_a?(Axn::Failure) ? error.cause : error` unwrapping exists only because of today's nested
wrapping. With wrapping removed, the rescued exception is already the real one; simplify these and
rescue the actual error class.

Actions with **no** declared base error are unaffected (no prefixing).

---

## Rollout ordering

1. **Additive phase**: ship base-`error` + `prefixed:` + `delimiter:` (and `success`/`done!`
   parity). No removals yet. Migrate internal strategies' *implementations* and os-app's
   manual-composition / `prefixed: false` sites onto the new mechanism.
2. **Breaking phase**: remove `error from:`, per-message `prefix:`, the nested `call!` wrapping,
   `Axn::Failure#source`, and the cause-hack, once all consumers (internal strategies + os-app
   `from:`/`prefix:` sites + Zendesk rescues) are migrated.

---

## Testing

Non-Rails `spec/` (POROs) plus `spec_rails/dummy_app/` for AR-specific paths (per AGENTS.md). Cover:

- **Prefixing**: base + prefixed reason; `prefixed: false` opt-out on `error … if:` and on `fail!`;
  no-base gate (reasons standalone, `"Something went wrong"` fallback); custom `delimiter:`;
  unconditional dynamic detail (`error(prefixed: true, &:message)`); `done!`/success parity.
- **Declaration-time raises**: `delimiter:` on a reason (a conditional entry or one marked
  `prefixed: true`) raises. (`prefixed: true` on a static unconditional entry does NOT raise — it
  *promotes* the entry to a prefixed reason; see §"`prefixed:` role & validity".)
- **Nesting parity**: a nested `call!` failure raises the inner's original exception (same as
  top-level); `Axn::Failure` is never auto-wrapped; no `source`; the explicit `call`+`fail!` idiom
  composes a child's `result.error`.
- **Honeybadger/`on_exception` shape** (regression for PR-1806): a `fail!` (nested or not) does not
  report; an `Axn::Failure` never appears as a mysterious wrapper.
- **Migrated strategies**: `step` prefixes child failures with `"#{name}: "` by default and honors
  `error_prefix:`; `use :model` validation-body output renders both standalone and prefixed by a
  base `error` declared after `use :model` (the strategy's old `error_prefix:` kwarg was removed).

---

## CHANGELOG

- `[FEAT]` base-`error` prefixing: `prefixed:` (default true, gated by a declared base),
  `delimiter:` (default `": "`), `success`/`done!` parity; the unconditional dynamic detail form.
- `[BREAKING]` remove `error from:`, per-message `prefix:` on `error`/`success`, the nested `call!`
  wrapping, and `Axn::Failure#source`. State old vs new explicitly: nested `call!` now re-raises the
  inner's original exception (was: a wrapped `Axn::Failure` carrying `result.error` + `source`). To
  reshape a child's message, use `call` + conditional `fail!`.
- `[INTERNAL]` `step` migrated off `error from:` to `call` + `fail!` (`error_prefix:` kwarg and
  default unchanged; parent-base cascade now possible). `use :model` `error_prefix:` removed
  (unreleased; redundant under base-`error` + `prefixed:`).
- Reference `fails_on` (already shipped) as the supported path for "expected failure → don't report".

---

## Open questions / risks

- **Multiple unconditional `error` declarations**: define which is "the base" (proposed:
  last-declared wins, matching override intent). Rare; pin in implementation.
- **Blast radius of default-`prefixed: true`**: bounded to actions that declare a base error;
  one-time, greppable, controlled rollout. The manual-composition doubling is the sharpest edge —
  must be migrated in lockstep with the breaking phase.
