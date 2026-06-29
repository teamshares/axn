# Message join customization (`join:`) — design

**Ticket:** [PRO-2832 — \[Axn\] Polish error message presentation](https://linear.app/teamshares/issue/PRO-2832/axn-polish-error-message-presenation) (parent: PRO-1610)

**Branch:** `kali/pro-2832-axn-polish-error-message-presentation` (off `main` @ #132)

## Problem

Today a base header joins to its reason via `delimiter:`, a plain infix string fed into one interpolation in `MessageResolver#with_base_prefix`: `"#{base_message}#{delimiter}#{reason}"`. Because a delimiter is purely the text *between* base and reason, it cannot express two things users want:

- **Recasing the reason** — `"Outer error: inner error"` vs `"Outer error: Inner error"`. The join can't touch the reason's text.
- **Wrapping the reason** — `"Outer error (inner error)"`. An infix has no closing side; `delimiter: " ("` yields `"Outer error (inner error"` with no closing paren.

The general fix: the join is a function `(base, reason) → String`, currently hardcoded to one shape. `delimiter:` is unused in practice downstream, so we have freedom to replace rather than extend it.

## Decision

Replace `delimiter:` with a single `join:` kwarg on the base header that accepts **either** a `String` (the infix, as before) **or** a `Proc` (the full combiner). The name reads correctly for both forms (`Array#join` precedent for the string; "join using this function" for the proc), where neither `delimiter` nor `separator` covers the proc case.

```ruby
error   "Outer error", join: " — "                                    # String: infix (default ": ")
error   "Outer error", join: ->(base, reason) { "#{base} (#{reason})" }  # Proc: owns the whole combination
success "All done",    join: ->(base, reason) { "#{base} — #{reason}" }  # identical mechanism for success
```

Casing lives in the proc — `->(b, r) { "#{b}: #{r[0]&.downcase}#{r[1..]}" }` — so we add no `downcase:` sugar. One mechanism.

## Semantics

**Single join site.** All combination happens in `MessageResolver#with_base_prefix`, which both `Result#_resolve_error` and `Result#_resolve_success` already call. Generalize it from a hardcoded interpolation to "apply the join":

```ruby
def with_base_prefix(reason)
  return reason unless base_message.present?

  combine(base_message, reason)
end
```

`combine` applies the resolved base's `join`: `"#{base}#{str}#{reason}"` for a String (with `str` defaulting to `": "` when unset), or `proc.call(base, reason)` for a Proc.

**Proc signature.** Exactly `(base, reason)` — two positional args. `base` is this level's resolved base header text; `reason` is the already-resolved segment immediately below it.

**Per-segment aggregation is preserved.** Across nested `call!`, every level runs its own `with_base_prefix`, so each level's `join:` governs how *its* header attaches to the segment below (the next header, or the leaf). A proc at one level and a string at another compose without conflict, exactly as per-segment delimiters do today.

**`prefixed: false` interaction unchanged.** An opted-out reason skips the prefix entirely, so the join (and any proc) never runs for it.

**Success parity is structural.** Success/`done!` resolves through the same resolver and the same `with_base_prefix`; no success-specific code is added. String and proc `join:` behave for `success` exactly as for `error`.

## Placement rule (unchanged from `delimiter:`)

`join:` is only legal on the base — an unconditional, unprefixed headline. On a reason (conditional, or explicitly `prefixed:`) it raises at declaration. `MessageDescriptor.build` already enforces this for `delimiter:`; the check moves verbatim to `join:`.

## Raise-safety

A String join cannot fail; a Proc can (it runs on the error-presentation path, which must never itself raise). If the proc raises or has the wrong arity, rescue and fall back to the default `": "` join, and log a warning through the existing logging mechanism — the same spirit as a base-header block that raises falling back down the headline chain. Where it reads cleanly, route the proc invocation through `Invoker` (used today for header/reason blocks) to get consistent rescue + logging; otherwise a local rescue around the call.

## Migration: remove `delimiter:`

`delimiter:` is removed, not aliased. It joins the existing `REMOVED_OPTION_MESSAGES` map in `MessageDescriptor` so it raises an actionable hint at declaration instead of being silently ignored — mirroring `from:` and `prefix:`:

```
delimiter: is no longer supported — use join: (a String, or a ->(base, reason) {} proc)
```

Update the affected docs (`docs/usage/writing.md`) and the existing per-segment delimiter specs to `join:`, and add a `CHANGELOG` entry tagged `[BREAKING]`.

## Implementation surface

- `lib/axn/core/flow/handlers/descriptors/message_descriptor.rb` — `@delimiter`→`@join` attr; `build` accepts `join:` (String|Proc), rejects it on non-base; add `delimiter:` to `REMOVED_OPTION_MESSAGES`.
- `lib/axn/core/flow/handlers/resolvers/message_resolver.rb` — `#delimiter` → resolve `descriptor.join`; `with_base_prefix` applies String-or-Proc via `combine`; raise-safety fallback.
- Docs: `docs/usage/writing.md` (delimiter rows/examples → `join:`, add proc + casing/wrapping examples), `CHANGELOG.md`.

## Testing

- **Parity:** port existing per-segment delimiter specs to `join:` string form (behavior unchanged).
- **Proc form:** wrapping (`"Outer (inner)"`), casing (`"Outer: inner"`).
- **Aggregation:** mixed string + proc levels across nested `call!`.
- **Success parity:** the proc-form wrapping/casing specs run for `success`/`done!`, not just `error`/`fail!`.
- **Raise-safety:** a proc that raises (and wrong arity) → falls back to default join, does not raise.
- **Placement:** `join:` on a reason → raises at declaration.
- **Migration:** `delimiter:` → raises the migration hint.
