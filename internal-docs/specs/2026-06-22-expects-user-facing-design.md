# `expects ..., user_facing:` — surface a field's validation failure to the caller

**Source:** Review thread on os-app#4563 (missing `note` forced `optional: true` + manual `fail!`).
**Date:** 2026-06-22
**Status:** Design approved, ready for implementation plan

## Problem

A required `expects :note` whose value is genuinely *user-supplied* sits wrong against the
dev-facing/bad-data split. When the value is missing, the resulting `InboundValidationError` is
treated as a **programmer error** on two independent axes:

1. **Reporting.** It is not an `Axn::Failure`, so the executor routes it to `trigger_on_exception`
   → it pages the global `on_exception` handler (Sentry). A user omitting a note is not a bug.
2. **Message.** `result.error` resolves to the generic `"Something went wrong"` fallback; the
   meaningful `"Note can't be blank"` is stranded on `result.exception.message`, never reaching the
   caller-facing `result.error`.

The only escapes today are both unsatisfying:

- **`optional: true` + manual `fail!`** — removes the presence check entirely, then re-implements it
  in `call`. The single concern "this field is required, and a user could legitimately omit it" is
  smeared across the declaration and the body (the comingling the reviewer flagged).
- **`use :form`** — correct when the *whole action* is a form handler, but heavyweight for one field.

The missing axis is **per-field**: "a violation of *this* field is the caller's fault, not the
programmer's." (If it were every input, `use :form` is already the honest answer — so this is
deliberately scoped to single fields.)

## Solution overview

Add one option to `expects`:

```ruby
expects :note, user_facing: true            # presence stays on; a violation surfaces the
                                            # field's own message ("Note can't be blank")
expects :note, user_facing: "Add a note"    # same, but override the surfaced message
expects :note, user_facing: :note_message   # same, message from an action method
expects :note, user_facing: ->(e) { ... }   # same, message computed from the field's error
```

Semantics: when a `user_facing:` field's validation fails, that failure settles through the
**failure** bucket (fires `on_failure`, stays out of `on_exception`/Sentry) and its message reaches
`result.error`. A plain `expects` is unchanged — still dev-facing, still pages.

The field stays **required** — `user_facing: true` keeps presence validation on. That is the whole
point versus `optional: true`, which removes it. `user_facing:` changes *who is blamed* for a
violation, not *whether* the field is validated.

`true | String | Symbol | Proc` matches the existing `error` / `fail!` / `fails_on` handler shape
exactly — the Symbol names an action method, the proc receives the field's `InboundValidationError`,
both arity-filtered through the shared handler invoker. There is no new value vocabulary to learn. A
String/Symbol/Proc that resolves blank falls back to the field's own validation message, so a
user-facing failure never leaks the generic dev-facing message onto `result.error`.

## The mixed-failure rule: dev-facing dominates

Inbound validation runs as one pass and currently raises a single `InboundValidationError` carrying
every field's errors. With per-field `user_facing:`, a single pass can produce both kinds of
failure at once (e.g. `note` blank **and** a plain `company_id` of the wrong type). A call settles
as exactly one outcome, so we need a precedence rule:

> **If any non-`user_facing` field failed, the call settles dev-facing** (the existing
> `InboundValidationError` → `on_exception`, generic message), exactly as today. The call settles as
> a clean user-facing `Failure` **only when every failing field is `user_facing:`**.

This preserves the invariant **a real contract bug always pages**. A genuine type bug in the call is
never masked behind a friendly "Note can't be blank" — you fix the bug first, and only once the
contract is otherwise sound does the user-facing message become the thing the caller sees.

Dominance is scoped to *independent* dev-facing violations. A subfield/model check is *derived*
(skipped, so the parent's user-facing message surfaces) only when **both** hold:

1. **Its parent root is one of the failed user-facing fields.** A subfield of any *other* parent —
   an unrelated absent `optional:` field, say — is not derived from the user-facing failure, so it
   runs and pages dev-facing exactly as it would with no `user_facing:` field in play. The root is
   resolved with `_root_wire_field`, which walks an `on:` reader (aliased via `as:`, dotted, or
   rooted at another subfield) back to its top-level wire key — reusing the action's existing
   `_wire_parent_key` for the alias step rather than duplicating that mapping.
2. **That parent value can't be extracted from** — missing or the wrong shape — so reading the
   subfield is meaningless. Extractability is tested *structurally* (mirroring the Extract resolver's
   source-shape branches) **without invoking the reader**: a reader that raises a genuine bug must
   surface as a dev-facing exception via the real validation, never be swallowed into a derived skip.
   Crucially, the check is **shape-aware**: a parent that failed its own declared `type:` is the
   wrong shape, so its subfields are derived even if the value coincidentally answers the subfield's
   reader (e.g. `Array#count` for a parent declared `type: Hash`). Method presence alone doesn't make
   a wrong-typed value extractable. Resolving a *dotted* `on:` ("payload.meta") does invoke the leaf
   reader; only the Extract resolver's typed `UnextractableError` ("can't read this shape") is treated
   as derived there — a reader that exists but raises a genuine bug propagates as a dev-facing
   exception, so dominance still holds.

So with `expects :payload, type: Hash, user_facing: true` plus `expects :id, on: :payload`, an
omitted/wrong-shaped `payload` makes `:id` derived → the parent's message surfaces (a caller who sent
the wrong shape gets the clean user-facing "Payload is not a Hash", not a spurious subfield page). But
a `payload` that satisfies its declared type and resolves to a readable container is extractable even
if it failed some *other* top-level validation (e.g. a custom `validate:` on an otherwise-valid Hash,
or a valid object that failed a custom check) — its subfield's own contract violation (`:id` of the
wrong type) is then genuinely independent and still dominates.

## Outcome shape (when all failing fields are user-facing)

- **Bucket:** failure — `on_failure` fires, `on_exception` does **not**, no Sentry report.
- **`result.error`:** the combined user-facing message. With multiple failing `user_facing:` fields,
  messages combine via `to_sentence`, matching how `ValidationError#message` already renders.
  A `String`/`Symbol`/`Proc` value overrides the message for its field; `true` uses that field's
  `errors.full_messages`. A Symbol/Proc handler receives an `InboundValidationError` **scoped to its
  own field**, so a shared `->(e) { e.message }` reads only that field, not the aggregate.
- **`result.exception`:** the structured `InboundValidationError` is **preserved** (reclassified
  into the failure bucket, not flattened to a bare `Axn::Failure`) so the granular per-field errors
  remain available — mirroring how `fails_on` preserves the original exception.

## Prefixing: the user-facing message is a *reason* (PRO-2746 interaction)

PRO-2746 (#109) established one rule for `result.error`: a declared base `error "Headline"` is a
headline that **prefixes** every failure *reason* — a conditional `error … if:`, a `fail!` message,
a `done!` message — as `"Headline<delimiter>reason"`, with no base meaning reasons stand alone.

A `user_facing:` violation is a failure reason of exactly that kind, so it obeys the same rule
rather than carving out an exception (which would reintroduce the "same content, different treatment
for an invisible reason" unpredictability #109 set out to kill). The composed user-facing message is
surfaced through `Result#_user_provided_error_message` as the reason, and `_resolve_error` applies
the base prefix:

```ruby
error "Couldn't save user"
expects :note, user_facing: true
# → "Couldn't save user: Note can't be blank"          (prefixed — identical to fail!("Note can't be blank"))

# with no base error declared:
# → "Note can't be blank"                               (standalone)
```

This holds for all forms (`true`/String/Symbol/Proc) and honors the base's `delimiter:`. It is
**prefixed-by-default**, matching `fail!`/`error`. The per-reason opt-out (`prefixed: false`) is
**deferred** for `user_facing:` — consistent with #109's "predictability over flexibility; don't
build the toggle until a concrete need appears." Implementation-wise this falls out for free:
`_fail_prefixed?` returns `true` for any non-`Failure` exception, so a user-facing `ValidationError`
is always prefixed.

## Why not the alternatives

- **`error from: :validations`** (a message rule) — only fixes axis 2 (message). The error still
  pages, because `error` resolves a message but does not reclassify the exception out of the
  exception bucket. Also grafts onto `from:`, which is otherwise bound to a child action's `source`.
- **`use :validation_errors`** (a strategy) — fixes both axes but is class-level, so it is
  all-or-nothing across every field; it cannot make `note` user-facing while `company_id` stays
  dev-facing. Same coarseness as `fails_on Axn::InboundValidationError`. A strategy is also heavier
  than a feature that, per field, just flips a bucket and wires a message.
- **`fails_on Axn::InboundValidationError, &:message`** — works *today* as a blunt instrument, but
  reclassifies **all** inbound validation failures, collapsing the dev/user distinction this feature
  exists to keep. It is deliberately **not** promoted in the user docs: separating dev-facing from
  user-facing errors is the whole point of the library, and a blanket reclassification undermines
  that. `user_facing:` softens the line just enough to be pragmatic while keeping the decision
  per-field; fully bypassing it is rarely the right move.

## Naming

`user_facing:` over `surface:` / `friendly:` / `blame: :user`. The reader of the *calling* code (a
dev who has never seen the option) can guess `expects :note, user_facing: true` correctly cold;
`surface:` makes them ask "surface to where?". It also reads as a native member of the existing
`expects` option vocabulary alongside `allow_blank:` / `allow_nil:`. A symbol axis (`blame: :user`)
was the most conceptually honest but forces the message override into a separate key, reintroducing
the declaration/message split this feature removes.

## Scope / non-goals

- **expects-only.** `exposes` is outbound (programmer-owned); an outbound validation failure is by
  definition a bug in the action, so there is no user-facing analogue.
- **No per-validation granularity.** `user_facing:` applies to the whole field's validations, not to
  a single validator on it (e.g. presence user-facing but type dev-facing on the same field). That
  is deliberate YAGNI — the field is the unit of "whose fault." `error(msg, if: ...)` remains the
  escape hatch for anything finer.
- **Additive at the seam.** Every existing `expects` declaration behaves identically; the new axis
  is opt-in and off by default.

## Testing

- Required `user_facing: true` field omitted → failure bucket, `on_failure` fires, `on_exception`
  does **not**, `result.error` is the field's validation message, `result.exception` is the
  preserved `InboundValidationError`.
- `String`, `Symbol`, and `Proc` values override the message; the Symbol names an action method and
  the proc receives the field's error. An override that resolves blank falls back to the field's own
  validation message.
- Field stays required: presence still validated (contrast with `optional: true`).
- **Mixed failure:** `user_facing:` field + plain field both invalid → settles dev-facing
  (`on_exception`, generic message), proving dev-facing dominance.
- Multiple `user_facing:` fields failing together → messages combine via `to_sentence`.
- All paths covered in `spec/` (non-Rails) and, where Rails-adjacent, `spec_rails/`.
