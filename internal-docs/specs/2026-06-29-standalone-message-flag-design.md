# `prefixed:` → `standalone:` message flag — design

**Ticket:** [PRO-2832 — \[Axn\] Polish error message presentation](https://linear.app/teamshares/issue/PRO-2832/axn-polish-error-message-presenation) (parent: PRO-1610)

**Branch:** `kali/pro-2832-axn-polish-error-message-presentation` — stacks onto the open `join:` work (PR #134); same ticket, same unreleased files.

## Problem

The `prefixed:` message kwarg has two issues, both surfaced by the `join:` rename:

1. **The name describes a mechanism that `join:` generalized away.** `prefixed: false` reads as "don't prepend the base," but with a wrapping `join:` Proc (`"Outer (inner)"`) the base isn't a prefix at all. The flag really controls *whether a reason is combined with the base at all*, independent of *how* `join:` combines them.
2. **It conflates two concepts.** Today `prefixed:` does double duty: (a) **render opt-out** — `prefixed: false` on a `fail!`/`done!`/conditional `error` renders the reason standalone; and (b) **promotion** — `prefixed: true` on an *unconditional* `error` headline turns it into a prefixed reason under the base.

## Decisions

### 1. Rename to `standalone:`, inverted sense

Replace `prefixed:` with **`standalone:`** (opt-out flag, default-false where a reason would otherwise attach). `standalone: true` renders the reason on its own; the name describes the message's own presentation, so it reads correctly regardless of what `join:` does and without the reader needing to know about "the base."

```ruby
fail!("card declined", standalone: true)                       # => "card declined" (base suppressed for this action)
error "Vendor not found", if: ArgumentError, standalone: true  # => "Vendor not found"
```

The opt-out is **action-scoped**, exactly as `prefixed: false` was: a bubbled child `fail!(..., standalone: true)` still receives an *ancestor's* base on the way up through `call!`. `standalone:` describes the declaring action's local rendering, not a global guarantee — which is why a "frozen text" name like `verbatim:`/`final:` was rejected.

### 2. `bare:` as an undocumented alias

Accept **`bare:`** as a synonym for `standalone:` in the DSL and in `fail!`/`done!`. It is **not documented** — docs use `standalone:` exclusively. Both names are unreleased; we **collapse to one before the first non-alpha release**. (Tracking note for that cleanup lives in this spec and the CHANGELOG entry.)

### 3. `standalone:` is a single universal flag (promotion retained)

`standalone:` replaces `prefixed:` everywhere with **inverted polarity**; it is **not** reason-only, and no feature is dropped. `standalone: true` renders a message on its own; `standalone: false` attaches it to the base. The default when unset follows conditionality:

- An **unconditional** entry defaults to standalone (it is the base headline).
- A **conditional** entry defaults to attached (it is a reason under the base).

So `standalone: false` on an **unconditional** entry **promotes** it into an attached reason under the base — exactly the capability the old `prefixed: true` provided, now spelled self-evidently ("not standalone → attach it"). One flag covers every case, which is why the model strategy needs no workaround: `success(prefixed: true)` simply becomes `success(standalone: false)`.

This is a **pure rename + boolean inversion** of the existing machinery — the resolver's role logic (`base_candidates`, `reason?`) and the resolution polarity flip in lock-step; nothing is added or removed.

## Internal renames (invert carefully)

The render flag is inverted everywhere — `prefixed (default varies)` becomes `standalone (default false for reasons)`:

- `MessageDescriptor` — drop `@prefixed`/`prefixed?`; add `@standalone`/`standalone?`. `build` accepts `standalone:` (the DSL maps `bare:` → `standalone:` before calling `build`), defaulting `standalone = matcher.static? if standalone.nil?` (unconditional → standalone headline; conditional → attached reason). `join:` stays base-only, where `base = matcher.static? && standalone` — so `standalone: false` on an unconditional entry (a promoted reason) correctly rejects `join:`. No reason-only restriction; `standalone:` is valid on any entry.
- `Axn::Failure` / `Axn::ValidationError` — `initialize(..., prefixed: true)` → `initialize(..., standalone: false)`; `prefixed?` → `standalone?`. (User-facing `ValidationError` stays attached-by-default; the deferred per-field opt-out remains deferred.)
- `Result#_fail_prefixed?` → `_fail_standalone?` returning `exception.standalone?`; call sites invert (attach when **not** standalone).
- `__early_completion_prefixed` context flag → `__early_completion_standalone` (records the `done!` opt-out); `_resolve_success` inverts accordingly.
- `MessageResolver`:
  - `resolve_message`: `descriptor.prefixed? ? with_base_prefix(r) : r` → `descriptor.standalone? ? r : with_base(r)`.
  - `reason?(d)`: `prefixed? || !static?` → `!standalone? || !static?`.
  - `base_candidates`: `static? && !prefixed?` → `static? && standalone?` (a promoted unconditional entry has `standalone? == false`, so it's correctly excluded from base candidates).
  - Rename `with_base_prefix` → **`with_base`** ("apply the base to this reason") since "prefix" is no longer accurate; it still delegates to `combine`.
- `executor.rb`, `carried_presentation.rb`, `async_serialization.rb`, `step.rb` — follow the attr/flag rename through their references.

## Docs + CHANGELOG

- `docs/usage/writing.md` — replace all `prefixed:`/`prefixed: false` references with `standalone:`; remove the promotion (`prefixed: true`) row/example and the always-on-detail example (or recast it as the base-block form above). `bare:` is **not** mentioned.
- Other docs touching the message `prefixed` concept (`docs/reference/instance.md`, `docs/reference/class.md` if they reference it) — update to `standalone:`.
- `CHANGELOG.md` (Unreleased) — amend the prefixing entry: the flag is `standalone:` (opt-out, render a reason on its own), promotion is removed, base-only/reason-only symmetry with `join:`. Add a one-line note that `bare:` exists as an undocumented alias to be collapsed before the first non-alpha release. No `[BREAKING]` (unreleased).

## Testing

- Rename `messages_prefix_spec.rb` → `messages_standalone_spec.rb` (or keep filename, update contents); port every `prefixed: false` → `standalone: true`, asserting identical output.
- Add `bare: true` parity tests (a few, asserting `bare:` behaves identically to `standalone:`) — these are the only `bare:` coverage; keep them even though it's undocumented.
- **Promotion tests are kept, ported:** `prefixed: true` (promote an unconditional entry to an attached reason) → `standalone: false`; assert identical output (`"<base>: <detail>"`). No declaration-error/raise tests — `standalone:` is valid on any entry.
- Invert and keep the success/`done!` parity tests (`done!("x", standalone: true)` → standalone; default attached).
- Keep the nested-`call!` action-scoping test (child `standalone: true` still gets the ancestor's base).
- Update the direct/Factory `MessageDescriptor.build` tests to the inverted flag (`standalone:`), keeping the existing `join:` base-only validation tests.
- Full suite green; docs link-check green.
