# Config predicate readers + override-accessor cleanup

**Date:** 2026-07-13
**Status:** Approved
**Scope:** `lib/axn/configurable.rb` (+ specs, docs). Sibling-gem migrations (data_shifter, axn-mcp, slack_sender) are follow-up PRs in their own repos.

## Motivation

Converting axn-slack_sender's hand-written config settings (`sandbox_mode?`, `async_backend`, `max_async_file_upload_size`) to the `Axn::Configurable` DSL — including making `sandbox_mode` per-class overridable — surfaced one genuine gap and one cleanup opportunity.

Investigation confirmed the DSL already covers most of what the hand-written settings need, so no new capability is required for dynamic defaults:

- **Compute-on-read defaults** already work: `callable: true` with a lambda default re-evaluates on every read (verified in both flavors), so "unset ⇒ derive from Rails.env / detect loaded backend now" is expressible today. Per-read evaluation is deliberate — it picks up late-loaded constants and avoids the `||=` nil-memoization footgun.
- **Explicit-false vs unset** is already distinguished (ivar-defined / `@values.key?` checks).
- **nil as a legal value** works by including nil in `one_of:`.
- **Custom validation messages** work by raising `ArgumentError` inside a `validate:` lambda (the raise propagates from `Setting#validate!`). Document this pattern.

The genuine gap: no generated `?` predicate reader in the class flavor (`Configurable::Settings`) or on the per-class override accessors — so a predicate-shaped public API like `config.sandbox_mode?` / `SomeAction.sandbox_mode?` can't be expressed. (The module flavor's `Config` bag already answers `?` via `method_missing`.)

The cleanup: the per-overridable-setting read surface (`name` / `resolved_<name>` / `raw_<name>`) carries a redundant member and an opaque name.

## Design

### 1. Predicate readers (`#{name}?`)

Generated **unconditionally** for every setting (parity with the module flavor's existing `Config#method_missing` behavior; no `predicate:` opt-in knob). Returns `!!` of the same read path as the plain reader.

Two surfaces:

- **Class flavor** (`Settings#setting`): instance method `#{name}?` alongside the existing reader/writer.
- **Override accessors** (`_define_override_methods`, shared by both flavors): class method `#{name}?` on the shared methods module, returning `!!resolve_override.call(self)` — full resolution chain (per-class override → superclass chain → library config fallback → callable default).

Shadow discipline: extend `_warn_on_shadowed_overrides` to also check the `?` names (same best-effort debug breadcrumb; install anyway per the PRO-2856 reasoning — `overridable: true` is opt-in). Framework code keeps using `resolve_override_for` and applies `!!` itself; no `resolve_predicate_for` variant.

### 2. Remove `resolved_<name>`

`resolved_<name>` is byte-for-byte identical to the no-arg `name` read (both dispatch through the same `resolve_override` closure) and is equally shadowable, so it has no distinct semantics. Its prefix also collides confusingly with the unrelated Naming DSL's `resolved_axn_name`. Remove it outright — axn is at `0.1.0-alpha`, and all consumers are internal:

- axn-mcp: `resolved_mcp_text_content` in `tool.rb`, `wrap.rb` + specs → bare `mcp_text_content`.
- data_shifter: `resolved_progress_enabled` / `resolved_suppress_repeated_logs` in `shift.rb` + specs → bare getters.
- axn's own `spec/axn/core/configuration_spec.rb` assertions.

### 3. Rename `raw_<name>` → `<name>_override`

The accessor answers "what's the stored override, if any?" (nearest override in the ancestry, or `UNSET`; no config fallback, no `Setting#resolve`). `raw_` names the mechanism; `<name>_override` names the thing returned, and the suffix form groups with `name` / `name?`. Keeps the `UNSET` sentinel return — mapping to nil would re-blur explicit-nil vs unset, the distinction PR #135 exists to expose.

Migration: data_shifter's `shift.rb` (`raw_progress_enabled` → `progress_enabled_override`) plus its comments; axn's own spec assertions; the shadow-warn key list.

### Resulting accessor family per overridable setting

| Method | Question it answers |
|---|---|
| `name` | effective value (override → ancestry → config fallback, resolved) |
| `name(value)` / `configure { \|c\| c.name = … }` | set a per-class override (validated eagerly when the namespace's source is registered) |
| `name?` | effective value as a boolean |
| `name_override` | the stored override itself, or `UNSET` |
| `resolve_override_for(klass, :name)` | effective value via the shadow-proof framework path |

Net generated-method count per overridable setting stays flat (add `name?`, drop `resolved_<name>`).

### Explicitly not building

- Memoized callable defaults (per-read is cheap and behaves better with late-loaded constants).
- nil-means-reset assignment semantics (footgun; converting downstream setters changes assigned-nil from "revert to derive" to "stored nil" — an accepted behavior change).
- `allow_nil:` sugar for `one_of:` (include nil in the list).
- Structured validation-message API (raising inside `validate:` works; add a docs line).
- `resolved_<name>?` / `name_override?` variants.
- A single `axn_override(:name)` method replacing per-setting accessors — structurally impossible: the namespace is baked into each setting's closure, and one class-level method couldn't disambiguate same-named settings from two adapter sources.

## Testing

- Class flavor: `config.foo?` truthiness/falsiness with callable defaults and explicit false.
- Override predicate resolving through per-class value, parent-class value, and library fallback; both flavors.
- Shadow-warn breadcrumb for a colliding `?` method.
- Module-flavor sanity: `Config#foo?` and the override predicate agree.
- `name_override` semantics unchanged from `raw_<name>` (rename-only), including `UNSET` when unset.
- Removal: no `resolved_<name>` method defined.

## Downstream follow-ups (separate PRs, after axn bump)

- **slack_sender:** convert `sandbox_mode` (callable default, `overridable: true`), `async_backend` (callable default, `one_of: [*SUPPORTED, nil]`), `max_async_file_upload_size` (raising `validate:`) to `setting`; keep `async_backend_available?` as a hand-written derived helper. Decide which others (e.g. `enabled`) become overridable.
- **data_shifter:** `resolved_*` → bare getters; `raw_progress_enabled` → `progress_enabled_override`.
- **axn-mcp:** `resolved_mcp_text_content` → `mcp_text_content`.
