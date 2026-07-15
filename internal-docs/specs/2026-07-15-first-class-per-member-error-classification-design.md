# First-class per-member error classification (uniform `user_facing:` across shape depth) (PRO-2925)

**Ticket:** [PRO-2925](https://linear.app/teamshares/issue/PRO-2925/axn-first-class-per-member-error-classification-uniform-user-facing) — child of PRO-1610. Supersedes the two separate items "accept `user_facing:` on a shape member" and "remove the `user_facing:` + shape-block guard": both are the SAME underlying change.

## Problem

`user_facing:` classification is **per-config**. A subfield IS its own config, so `user_facing:` composes cleanly across subfield depth. A shape member is NOT a config — `ShapeValidator` folds every member failure into the parent field's `ActiveModel::Errors` as a plain, unmarked string under the parent's attribute (`lib/axn/core/validation/validators/shape_validator.rb:60,69`). Settlement then classifies at per-config granularity: one `ContractFailure` per config, and dev-facing dominates unless *every* failing config is `user_facing:` (`lib/axn/executor.rb:518`). A shape member has no seat at that table.

Two symptoms of this second-class status:

1. `user_facing:` + a `shape:` block on the same field is rejected at declaration (`lib/axn/core/contract.rb:189`) — a depth-dependent DSL asymmetry (accepted on plain fields and on subfields, rejected on shape-carrying fields), because a failing member would otherwise leak onto `result.error` as user-facing.
2. `user_facing:` is not accepted on a shape member at all (`SHAPE_MEMBER_FIELD_OPTIONS`, `contract.rb:646`) — it falls through to the generic "Unknown key" error. It can't be fixed by an allowlist add alone: there is no per-member classification for the option to honor.

## Decision

Make shape-member errors **individually classifiable**, so `user_facing:` composes uniformly at every declaration depth. The `ContractFailure` stops being the atomic classification unit and becomes a **container that can be partitioned** into the field's own errors vs. its member errors — reusing the existing settlement seam, not adding a parallel classification path.

Invariants:

- Member errors default **dev-facing** — a structural member failure never surfaces as user-facing.
- A member may **opt into** `user_facing:` with **full parity** to a field: `true` / String / Symbol / Proc, validated through the existing `_validate_user_facing!`.
- A field's own errors honor the field's `user_facing:` **regardless** of whether it also carries a shape block.
- The `user_facing:` + shape-block declaration guard is **removed**, ending the depth-dependent asymmetry.
- Uniform at every depth: a `user_facing:` member nested inside a nested shape composes correctly (its intent is preserved as errors bubble up through outer re-wraps).

## What we're adding — by example

### 1. `user_facing:` on a field that also carries a shape block (guard removed)

```ruby
expects :order, type: Hash, user_facing: "Order details are required" do
  field :sku, type: String
end
```

The field's *own* failure (e.g. `order` absent) surfaces user-facing as "Order details are required". A malformed `sku` member stays **dev-facing** and does not leak — if only the member fails, the caller sees the dev-facing aggregate; if both fail, dev-facing dominates and both are reported.

### 2. A member opts into `user_facing:`

```ruby
expects :items, type: Array do
  field :status, type: String, inclusion: { in: %w[open closed] },
        user_facing: "Each item needs a valid status"
end
```

A failing `status` member surfaces user-facing with its override. The `items` field's own structural failures (not an Array, etc.) stay dev-facing (the field declared no `user_facing:`).

### 3. Full parity — Symbol/Proc member overrides

```ruby
expects :items, type: Array do
  field :qty, type: Integer, numericality: { greater_than: 0 },
        user_facing: ->(e) { "Quantity problem: #{e.message}" }
end
```

Resolved through the same `_resolve_user_facing_override` seam as a field, with the error **scoped to that member's own failure** (so `e.message` is the member's message, not the aggregate).

## Implementation

### 1. Tag member errors at the source (`shape_validator.rb`)

Both `record.errors.add` sites (`:60` unreadable-member, `:69` member-validator errors) tag with two options:

- `axn_shape_member: true` — this is a structural shape-member error.
- `axn_member_user_facing: <intent>` — the member's own `user_facing:` value (`false` by default).

`ShapeConfig` gains a `user_facing` field (default `false`), read duck-typed in the validator (`member.respond_to?(:user_facing) ? member.user_facing : false`), mirroring `method_call`/`sensitive`.

**Nested-depth preservation.** When the outer `ShapeValidator` re-wraps errors bubbling up from a member's own nested shape (`:69`), an error that is **already** tagged `axn_shape_member` keeps its existing `axn_member_user_facing` intent rather than being overwritten with the outer member's. A member's *own* direct-validator errors are untagged at that point and correctly receive the current member's intent. This is what makes a deeply-nested `user_facing:` member compose.

`ActiveModel::Error` carries arbitrary options (including a Proc) unchanged through `add` → `import` → `message`/`full_message` — verified empirically; a String message type is returned verbatim with no interpolation of these options.

### 2. Partition + per-error dominance (`executor.rb`)

`ContractFailure` is unchanged as a Data type; the *interpretation* changes. Two helpers split a failure's errors:

- `_own_errors(failure)` — errors without `axn_shape_member`.
- `_member_errors(failure)` — errors with `axn_shape_member`.

A failure is **fully user-facing** iff its own errors are user-facing (own empty, or `config.user_facing` truthy) AND every member error carries a truthy `axn_member_user_facing`. The dominance check (`:518`) becomes:

```ruby
raise InboundValidationError, _aggregate_errors(failures, mismatches) unless
  mismatches.empty? && failures.all? { |f| _fully_user_facing?(f) }
```

The dev-facing aggregate (`_aggregate_errors`) is unchanged — it already imports every error (own + member), so "both reported" holds for free.

### 3. Per-error message selection (`_composed_user_facing_error`, `:607`)

Reached only when every classification unit is user-facing. For each failure:

- **Own errors** (if any) resolve through `config.user_facing` via the existing `_resolve_user_facing_override`, `own:` = own errors' full messages, scoped to the own errors.
- **Each member error** resolves through its own `axn_member_user_facing` intent, `own:` = that error's full message, scoped to just that error.

The collected parts are `uniq`-ed before `to_sentence`, so a String/Symbol member override on an `Array` shape doesn't repeat once per failing element (identical resolved parts collapse). `_resolve_user_facing_override` itself is unchanged.

### 4. Declaration surface (`contract.rb`)

- Remove the guard at `:189-191`.
- Add `user_facing` to `SHAPE_MEMBER_FIELD_OPTIONS` (`:646`).
- In `_build_shape_member`, validate the member's `user_facing:` via `_validate_user_facing!` and thread it into `ShapeConfig.new(..., user_facing:)`.

## Testing

Replace the two guard-pinning specs at `spec/axn/core/user_facing_spec.rb:512-534` with behavioral specs:

- Field's own presence fails AND a member fails simultaneously → aggregate stays dev-facing, BOTH reported.
- A `user_facing:` field with a shape block: the field's own failure surfaces user-facing; a member failure stays dev-facing (does not leak) when it fails alone.
- A shape member declared `user_facing:` (true / String / Symbol / Proc) → its own failure surfaces user-facing with the resolved message.
- A `user_facing:` String member on an `Array` shape with multiple failing elements → the override appears once (uniq).
- A nested `user_facing:` member (member of a member) → composes user-facing at depth.
- Subfield `user_facing:` behavior unchanged (already per-config) — existing specs stay green.

## Out of scope / non-goals

- `of:` element-type errors: currently untagged, classified as the field's own errors, and honor the field's `user_facing:` (no existing guard). This is unchanged — bringing `of:` under structural member classification is a separate concern and would alter existing behavior.
- No change to `_resolve_user_facing_override`, `_aggregate_errors`, or the `ContractFailure` shape itself.
