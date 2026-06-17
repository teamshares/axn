# `expects ..., as:` / `prefix:` — decouple reader name from wire key

**Linear:** [PRO-2747](https://linear.app/teamshares/issue/PRO-2747/axn-consider-some-sort-of-alias-support)
**Date:** 2026-06-17
**Status:** Design approved, ready for implementation plan

## Problem

`expects` forces the action-internal reader name to equal the external param name.
That couples the public contract to the action's internals and creates two recurring frictions:

- **Reader name-squatting.** `expects :channel` auto-defines a `channel` reader returning the
  *raw* inbound value. If the action wants `channel` to mean the *resolved* object (a method it
  writes), the auto-reader squats on the name. The only escape today is forcing the **caller** to
  pass `raw_channel:` — leaking internal naming into the public contract.
- **Subfield flattening / collision.** `expects :id, :type, on: :event_params` creates bare
  `id` / `type` readers that collide easily and lose their `event_` context. (Motivating case:
  os-app#4534 / #4617 — "unwrapped_params".)

Both reduce to one missing axis on the contract DSL: **let the generated reader be named
independently of the wire key**, while the wire key stays the canonical caller-facing contract.

## Solution overview

Add two options to `expects` (top-level and subfield):

```ruby
expects :channel, as: :raw_channel                       # reader: raw_channel
def channel = @channel ||= Channel.find(raw_channel)     # the name is now free

expects :id, :type, on: :event_params, prefix: :event_   # readers: event_id, event_type
expects :id, on: :event_params, as: :event_id            # subfield single rename
```

- The declared field (`:channel`, `:id`) remains the **canonical wire key** for everything
  caller-facing. `as:` / `prefix:` rename **only** the generated reader method (and its `?`
  predicate).
- `as:` renames a single reader. `prefix:` is pure sugar that desugars to a per-field
  `as: :"#{prefix}#{field}"`, enabling multi-field renames (the `event_params` unwrap case).

This is **expects-only**. Symmetric `as:` on `exposes` is explicitly **not planned** — `exposes`
generates no instance reader (nothing to free up), and output naming is already covered by manual
`expose(:key, value)`, `expose_return_as:`, and the strategies' own `as:` / `expose:` options.
See "Rejected: exposes alias" below.

## Semantics — which name wins where

| Concern | Name used |
|---|---|
| Validation error messages | wire key (`channel`) |
| MCP schema / required-inputs / `_declared_fields` | wire key |
| Logging + sensitive-field filter | wire key |
| Reader method + `?` predicate | reader name (`raw_channel`) |
| `result` / context storage | wire key |

Everything caller-facing keeps the wire key; only the in-action reader changes. Because
`config.field` stays the wire key, **every existing consumer that iterates `config.field` is
untouched** — the entire change is additive at the two reader-definition seams.

## API rules & edge cases

- **`as:` is single-field only.** `expects :a, :b, as: :x` raises `ArgumentError` (same rule as
  field metadata today).
- **`prefix:` uses literal concatenation** — `:"#{prefix}#{field}"`. The caller supplies the
  separator (`prefix: :event_`, not `:event`). Works for one or many fields.
- **`as:` + `prefix:` together raises** `ArgumentError`.
- **`as:` / `prefix:` on a dotted subfield key** (e.g. `"billing.zip"`) raises — dotted keys never
  generate readers (`_define_subfield_reader` returns early on `.`), so a rename is meaningless.
- **`as:` / `prefix:` with `readers: false`** (subfields) raises — no reader to name.
- **Reserved-name check** runs against the **reader name**: the `as:`/prefixed name must not be in
  `RESERVED_FIELD_NAMES_FOR_EXPECTATIONS`.
- **Collision check** runs against the **reader name**: two configs may not resolve to the same
  reader, and a reader name may not shadow an already-declared field's reader. (Wire-key duplicate
  detection on `config.field` is unchanged.)

## Implementation touchpoints

All in `lib/axn/core/contract.rb` and `lib/axn/core/contract_for_subfields.rb`:

1. **Add a `reader_as` member** to both `FieldConfig` (`contract.rb:24`) and `SubfieldConfig`
   (`contract_for_subfields.rb:8`). Defaults to `field` when no alias is given. Both construction
   sites (`contract.rb:308`, `contract_for_subfields.rb:91`) are keyword-based, so threading one
   more keyword through is non-breaking for named-accessor consumers (e.g. axn-mcp reads
   `config.field` / `config.validations` / `config.description`).
2. **Plumb `as:` / `prefix:`** through `expects` → `_parse_field_configs` and
   `_expects_subfields` → `_parse_subfield_configs`. Compute per-field reader name:
   `reader_as || (prefix ? :"#{prefix}#{field}" : field)`.
3. **Define readers under `reader_as`** instead of `field`:
   - `_define_field_reader(reader_as)` — body still reads `internal_context.public_send(field)`
     (the wire key), exposed under the reader name.
   - `_define_boolean_predicate_reader(reader_as)`.
   - `_define_subfield_reader` / `_define_subfield_model_reader` — define under `reader_as`; the
     resolver still extracts the wire-key `field` from the parent.
4. **Guards** (raise sites) for the API rules above, placed in `expects` / `_expects_subfields`
   before parsing.

## Testing

- Top-level: `as:` produces the aliased reader + `?` predicate; the wire key still drives
  validation errors, presence requirements, logging keys, and `result`/context.
- Name-freeing: `expects :x, as: :raw_x` + user-defined `def x` coexist; `def x` is callable and
  not clobbered.
- Subfields: `as:` and `prefix:` both produce correctly-named readers that extract the right
  wire-key subfield from `on:`; `model: true` subfield readers honor the alias.
- Guards: multi-field `as:`, `as:` + `prefix:`, dotted-key alias, `readers: false` + alias,
  reserved reader name, and reader-name collision each raise with a clear message.
- Sensitive filtering still redacts by wire key when a field is aliased.

## Rejected: exposes alias

`exposes` never defines an instance reader (outbound fields are read via `result.foo`), so there
is no name to free up — the primary driver is absent. The default `call` auto-exposes by calling a
method of the **same name** as the exposure; an `as:` there would only redirect that auto-expose
source method, while manual `expose()` would still validate against the canonical key — a subtle
split for a convenience already served by `expose(:key, value)`, `expose_return_as:`, and strategy
config. Not worth the surface. Unified mental model ("`as:` = the name this field goes by inside my
action") remains coherent, so it could be added non-breakingly later if a real case emerges — but
it is not planned.
