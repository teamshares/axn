# `model:` `<field>_id` reader + record/id consistency

**Linear:** [PRO-2748](https://linear.app/teamshares/issue/PRO-2748/axn-model-true-expectation-create-consistent-id-reader)
**Date:** 2026-06-17
**Status:** Design approved, ready for implementation plan
**Ships with:** [PRO-2747 alias work](2026-06-17-expects-reader-alias-design.md) (same model-reader seams)

## Problem

`expects :user, model: true` defines only a `user` reader (the resolved record). There is no
`user_id` reader — whether you call the action with `user:` or `user_id:`, the raw id key the
resolver reads internally is invisible. Actions that need "the id, however it was passed" have to
reach for it manually.

## Solution

Two behaviors, both anchored on the single `FieldResolvers.resolve(type: :model)` chokepoint that
top-level (facade) and subfield model readers share.

### 1. The `<field>_id` reader — one meaning: the primary key

Define `<reader>_id` alongside `<reader>` for every `model:` field (top-level and subfield). Its
contract is *always* "the primary key of the record", uniform across finders:

| Input | `<field>_id` returns | Cost |
|---|---|---|
| `user_id: 5`, default `:find` | `5` (a supplied id **is** the pk) | none — no resolution |
| `user: <rec>` | `rec.id` | none — record in hand |
| `user_id: <token>`, custom finder | the resolved record's `.id` | reuses the **memoized** `user` resolution |

Because the model reader is memoized, the custom-finder path triggers no second lookup — `<field>_id`
piggybacks on the resolution `user` already performs. This is why the reader is uniform and
always-present (one-sentence contract) rather than gated to id-based finders: gating an observable
reader reads as "the feature is sometimes missing", which is awkward; gating an invisible *check*
(below) does not.

Alias-aware: `as: :raw_user` → `raw_user_id`. Defers (debug-logged) to any same-named pre-existing
method. `.id` is reliable for standard AR single primary keys (including custom ones like `uuid`);
composite primary keys are a documented non-goal for the singular `<field>_id` convention; non-AR
records are guarded via `respond_to?(:id)`.

### 2. Record / id consistency check — gated to the default finder

For the default `:find` finder, if **both** a record and a `<field>_id` are supplied and they
disagree (`user: <id=5>, user_id: 9`), raise `InboundValidationError`. One-only, or both-in-agreement,
pass. Operates on raw provided data (no resolution). **This is a behavior change** — previously the
record silently won and the id was discarded, even when contradictory.

Skipped for custom finders: there the `<field>_id` value is a finder-specific token, not a primary
key, so a `record.id`-vs-token comparison would be meaningless. This gate is invisible (you can't
"see" an absent validation), so it documents cleanly as "id-based finders only".

Error type is `InboundValidationError` (dev-facing) deliberately: contradictory record+id is a
caller/programming error, not user-facing bad data (which belongs to `use :form`).

## Implementation touchpoints

- `contract.rb`: `_define_model_id_reader` (top-level), called from `_parse_field_configs` when the
  field has `model:`; new `_reader_name_available?(name, kind:)` helper.
- `contract_for_subfields.rb`: `_define_subfield_model_id_reader`, called from
  `_define_subfield_model_reader`.
- `executor.rb`: `validate_model_consistency!` (+ `_id_based_model?`, `_model_record_id_mismatch`),
  invoked from `validate_contract!` on the inbound pass.

## DRY: silencing auto-companion readers

The new `_reader_name_available?(name, kind:)` helper centralizes the "already defined? → skip +
debug-log" decision and is routed through the **auto-companion** readers — those derived as a
convenience that should quietly yield to a user's own method: the boolean-predicate reader and the
new `<field>_id` reader.

It is deliberately **not** applied to:
- **By-design override seams** — `use :model`'s exposed-record reader and `model_params`. Their skip
  is the *expected* path (in update/upsert mode the exposed name is the input field, which already
  has a reader), not a surprising shadow; logging it on every such action would be noise.
- **Primary-reader collisions** — subfield duplicate sub-keys and the `as:`/`prefix:` alias collision
  check, which **raise** rather than defer.
