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

### 3. Drop promotion — the flag is opt-out-only

The promotion direction (`prefixed: true` on an unconditional headline) is removed. Rationale: a static boolean that promotes an always-on entry adds little over just authoring the base to include the detail, and making it a *predicate* would duplicate `if:`/`unless:`. So:

- An **unconditional** `error "X"` / `success "X"` is **always** the base headline. There is no kwarg to turn it into a reason.
- `standalone:` is therefore only meaningful on a **reason** (a conditional `error`/`success`, or a `fail!`/`done!` message). On an unconditional headline it **raises at declaration** — symmetric with `join:`, which is base-only. (`join:` → base-only; `standalone:` → reason-only.)

**This is a structural simplification, not just a rename.** Role (headline vs reason) collapses to pure conditionality, and `standalone:` becomes the single render toggle. The two concepts `prefixed:` conflated are cleanly separated: structure is decided by `if:`/`unless:`, rendering by `standalone:`.

**Migration of the always-on-detail pattern.** The old `error(prefixed: true, &:message)` ("always show `base: <exception.message>`") is dropped. Author it into the base instead:

```ruby
# before:  error "Couldn't sync user"; error(prefixed: true, &:message)
# after:   error { "Couldn't sync user: #{exception.message}" }
```

The one capability lost: that internal `base: detail` seam is now literal text, so `join:` doesn't govern it and nested `call!` treats it as one base segment. Acceptable for an always-on detail; revisit only if a real need appears. All `prefixed: true` tests are migrated or removed accordingly.

## Internal renames (invert carefully)

The render flag is inverted everywhere — `prefixed (default varies)` becomes `standalone (default false for reasons)`:

- `MessageDescriptor` — drop `@prefixed`/`prefixed?`; add `@standalone`/`standalone?`. `build` accepts `standalone:` (and the DSL maps `bare:` → `standalone:` before calling `build`). Reason-vs-headline is now `!matcher.static?` (conditionality) with no promotion override. Reject `standalone:` on an unconditional headline ("standalone: only applies to a reason").
- `Axn::Failure` / `Axn::ValidationError` — `initialize(..., prefixed: true)` → `initialize(..., standalone: false)`; `prefixed?` → `standalone?`. (User-facing `ValidationError` stays attached-by-default; the deferred per-field opt-out remains deferred.)
- `Result#_fail_prefixed?` → `_fail_standalone?` returning `exception.standalone?`; call sites invert (attach when **not** standalone).
- `__early_completion_prefixed` context flag → `__early_completion_standalone` (records the `done!` opt-out); `_resolve_success` inverts accordingly.
- `MessageResolver`:
  - `resolve_message`: `descriptor.prefixed? ? with_base_prefix(r) : r` → `descriptor.standalone? ? r : with_base_prefix(r)`.
  - `reason?(d)` drops the `prefixed?` term → `!d.static?`.
  - `base_candidates` = unconditional (`static?`) entries — drop the `!d.prefixed?` term.
  - Rename `with_base_prefix` → **`with_base`** ("apply the base to this reason") since "prefix" is no longer accurate; it still delegates to `combine`.
- `executor.rb`, `carried_presentation.rb`, `async_serialization.rb`, `step.rb` — follow the attr/flag rename through their references.

## Docs + CHANGELOG

- `docs/usage/writing.md` — replace all `prefixed:`/`prefixed: false` references with `standalone:`; remove the promotion (`prefixed: true`) row/example and the always-on-detail example (or recast it as the base-block form above). `bare:` is **not** mentioned.
- Other docs touching the message `prefixed` concept (`docs/reference/instance.md`, `docs/reference/class.md` if they reference it) — update to `standalone:`.
- `CHANGELOG.md` (Unreleased) — amend the prefixing entry: the flag is `standalone:` (opt-out, render a reason on its own), promotion is removed, base-only/reason-only symmetry with `join:`. Add a one-line note that `bare:` exists as an undocumented alias to be collapsed before the first non-alpha release. No `[BREAKING]` (unreleased).

## Testing

- Rename `messages_prefix_spec.rb` → `messages_standalone_spec.rb` (or keep filename, update contents); port every `prefixed: false` → `standalone: true`, asserting identical output.
- Add `bare: true` parity tests (a few, asserting `bare:` behaves identically to `standalone:`) — these are the only `bare:` coverage; keep them even though it's undocumented.
- **Removal/declaration-error tests:** `standalone:` on an unconditional headline raises; the old `prefixed: true` promotion path no longer exists (remove those tests; add one asserting an unconditional `error(..., standalone: ...)` raises).
- Invert and keep the success/`done!` parity tests (`done!("x", standalone: true)` → standalone; default attached).
- Keep the nested-`call!` action-scoping test (child `standalone: true` still gets the ancestor's base).
- Update the direct/Factory `MessageDescriptor.build` validation tests to the new reason-only rule.
- Full suite green; docs link-check green.
