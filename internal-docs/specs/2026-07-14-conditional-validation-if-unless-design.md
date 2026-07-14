# Conditional validation: `if:`/`unless:` on field declarations (PRO-2881)

**Ticket:** [PRO-2881](https://linear.app/teamshares/issue/PRO-2881/axn-global-conditional-requiredness-ifunless-on-validations-or-dynamic) — follow-up A from PRO-2877 (reject contradiction-only subfield contracts).

## Problem

axn has no global conditional-requiredness mechanism: `optional:`/`allow_nil:`/`allow_blank:` are static booleans baked into the validations hash at declaration, and `if:`/`unless:` exist only on message handlers, callbacks, and step mounting. PRO-2877 deliberately rejects the "family 1" shape (nil-tolerant ancestor + required subfield descendant) rather than granting it an implicit conditional reading — but real contracts exhibit exactly that conditionality ("if `data` is present, `data.user` is required"), and today there is no sanctioned way to express it.

## Decision

Bless ActiveModel's own conditional-validation semantics at the field-declaration level, at two tiers:

1. **Declaration-level `if:`/`unless:`** — a sibling kwarg on `expects`/`exposes` that gates *every* validator in the declaration, including the auto-injected `presence: true`. This is the AR-familiar `validates ..., if:` pattern, and conditional requiredness falls out of it.
2. **Per-validator `if:`/`unless:`** — nested inside an individual validator's options hash, gating just that check. This already works mechanically (it flows straight through to ActiveModel); we bless, test, and document it.

No new evaluation machinery is invented: the whole validations hash already lands in a single `validates` call, and `if:`/`unless:` are ActiveModel *shared default options* that AM distributes to every validator in the call itself. The substance of this ticket is the surrounding discipline: fixing the flag-interaction crashes, rejecting dead combinations at declaration, teaching reflection and the contradiction detectors about conditional gates, and documentation.

## What we're adding — by example

### 1. Conditional requiredness (the headline)

```ruby
expects :promo_enabled, type: :boolean
expects :coupon_code, type: String, if: :promo_enabled
```

When `promo_enabled` is falsey, `coupon_code` is wholly unvalidated: it may be omitted, and a supplied value is not type-checked (AR semantics — the condition gates the whole declaration). When truthy, the field is required and must be a String. `unless:` is the negation; both together are allowed and combine with AND (AR semantics — every given condition must pass for validation to run).

### 2. Splitting validations on one field (per-validator conditions)

```ruby
expects :num, type: Integer,
              numericality: { greater_than: 100, if: :big_num_needed? }
```

The type check is unconditional; the numericality check runs only when `big_num_needed?` is truthy. No duplicate `expects :num` declaration needed (the duplicate-field guard stays).

### 3. The family-1 pattern, now expressible (the PRO-2877 payoff)

```ruby
expects :data, optional: true
expects :user, model: User, on: :data, if: -> { data.present? }
```

Today this raises at declaration (dead nil-tolerance: `:data` is nil-tolerant but `:user` is required, so the tolerance can never be exercised). With a conditional gate on the child, the child's requiredness is no longer *unconditional*, so the contradiction no longer holds — the satisfiability-mode carve-out (below) legalizes it. The PRO-2877 rejection message will be extended to point at this spelling as the sanctioned fix.

### 4. Conditions combined with tolerance flags

```ruby
expects :note, type: String, optional: true, if: :notes_enabled?
```

Legal and meaningful: the field is always omittable (`optional:`), and when a value IS supplied, the type check runs only when `notes_enabled?`. (Today this crashes at declaration with a bare `TypeError` — see fixes below.)

### 5. Condition forms

- **Symbol** — names an action method (or reader): `if: :promo_enabled` resolves via the validator's existing `method_missing` delegation to the action instance.
- **Proc/callable** — evaluated by ActiveModel against the one-off validator instance, whose method calls delegate to the action. Zero-arity procs referencing reader methods behave exactly as if evaluated on the action: `if: -> { data.present? }`. Documented caveat: `self` inside the proc is the validator (not the action), so instance variables do not resolve — use reader methods, same guidance as `validate:` custom validators. An arity-1 proc receives the validator instance (AR's "record" convention), which is allowed but not documented as a primary form.

We deliberately do NOT wrap conditions to re-`instance_exec` them against the action (as `default:`/`sensitive:` do): both tiers then share one evaluation mechanism (ActiveModel's), the Symbol form — the primary form — already behaves identically, and a wrapper would make the declaration-level tier subtly diverge from the per-validator tier.

## Semantics

- **`if:`/`unless:` gate validation only.** `default:` and `preprocess:` are pipeline stages, not validations — they still apply when the condition is false. `sensitive:` filtering and readers are likewise ungated. (A defaulted field with a false condition simply carries its default, unvalidated.)
- **Evaluation timing:** during inbound validation, after coercion, preprocessing, and defaults have settled — so conditions can read other fields' final values through readers. Outbound (`exposes`) conditions evaluate after `call` against the result.
- **Evaluation count:** ActiveModel applies the shared condition per validator, so a declaration-level condition may be evaluated once *per validator* on the field (e.g. twice for `type:` + auto-`presence`). Conditions must be cheap and side-effect-free; documented.
- **Scope:** `expects` (top-level and `on:` subfields) and `exposes`. Uniform at every depth — a subfield's condition gates its validations exactly like a top-level field's.
- **Shape members (`do…end` blocks): rejected at declaration.** `ShapeValidator` builds member validators with no action reference (`shape_validator.rb:50` passes no `action:`), so Symbol/Proc conditions have nothing to resolve against. `field :x, ..., if: :cond` raises `ArgumentError` at declaration, joining the existing member rejections (`default:`/`preprocess:`/`sensitive:`). Can be lifted later by threading the action through ShapeValidator, but member conditions evaluated per-element have murky semantics (per-element vs per-action) we don't want to guess at.
- **`on: :ambient_context` subfields:** no special handling — conditions gate their validations like any subfield.
- **Async:** conditions live on the class (frozen `FieldConfig` validations), never in the serialized payload — no Sidekiq/serialization impact.

## Flag interactions: fixes and new declaration-time rejections

The `allow_blank`/`allow_nil` push-down (`contract.rb:721-724`) runs `{ allow_blank:, allow_nil: }.merge(v)` over **every** validations entry via `transform_values!`. With `:if`/`:unless` as sibling keys, that loop needs a guard, and two combinations become dead machinery we reject outright:

| Combination | Today | New behavior |
|---|---|---|
| tolerance flag (`optional:`/`allow_nil:`/`allow_blank:`) + declaration-level `if:`/`unless:` | `TypeError: no implicit conversion of Symbol into Hash` at declaration | **Works** — the push-down skips the shared-option keys (they are not validators; the tolerance flags land on the real validators, and AM distributes the condition). Semantics per example 4 |
| tolerance flag + explicit truthy `presence:` (e.g. `presence: true`, `presence: { if: :cond }`) | `presence: true` crashes with the same bare `TypeError`; `presence: { if: :cond }` is silently neutered (the push-down merges `allow_blank: true` into the presence hash, and blank-tolerant presence always passes) | **Clear `ArgumentError` at declaration**: the tolerance contradicts the presence check — one requiredness signal per field. Same dead-machinery doctrine as PRO-2877/2889/2901. (`presence: false` + tolerance stays legal — redundant but coherent) |
| `if:` + `unless:` together | Accepted, ANDed (AM) | Unchanged — matches AR, documented. (Note: message-handler `Matcher` forbids the combination; steps AND them. We follow AR here and leave the other subsystems alone) |
| shape member with `if:`/`unless:` | Would break at validation time (no action to resolve against) | `ArgumentError` at declaration |

## Schema reflection

**Governing invariant: a condition can only relax enforcement at runtime, never tighten it.** The declared validators are the maximal contract; a false condition waives some of them for that call. So the schema reflects the **static-maximal** contract, which is the established safe direction (stricter than runtime — same doctrine as Proc defaults). Conditions are opaque Procs/Symbols and are **never executed** during reflection (the existing side-effect-free doctrine; already spec-protected for per-validator `if:`).

Concretely:

- `expects :num, type: Integer, if: :cond` → reflected required, non-nullable (as if unconditional). A caller following the schema always supplies a valid `num`, which passes whether or not the condition fires.
- `expects :note, type: String, optional: true, if: :cond` → reflected optional (the static tolerance is unconditional; only the type check is gated). Requires fixing `nil_accepted?` (`schema.rb:1081-1096`), which iterates every validations key and would treat `:if` as an unknown nil-rejecting validator — it must skip the shared-option keys (`:if`/`:unless`), treating them as neutral. `FieldConfig#optional?` (the axn-mcp shared predicate) already ignores non-Hash entries and keys off `presence` — no change needed.
- **No `if`/`then`/`dependentRequired` emission in v1.** Opaque conditions can't be translated. If we later add a declarative condition form (e.g. a sibling-field-presence hash), `dependentRequired` becomes emittable — future ticket.

**One deliberate exception to static-maximal: a gated required subfield does not force its ancestors.** For the family-1 example, the natural JSON Schema is exactly: `data` optional/nullable, with `data`'s object schema carrying `required: ["user_id"]` (the model route's wire token) — nested `required` only binds when the parent object is present, which is precisely the canonical condition (`if: -> { data.present? }`). Full static-maximal propagation would instead force `data` itself required, defeating the declared `optional: true` and re-imposing the family-1 reading this ticket exists to escape. So in strict (schema) mode:

- the gated subfield stays in its parent's nested `required` array (own-level static-maximal), but
- it does NOT propagate requiredness/non-nullability up the ancestor chain (`NodeAnnotation.required` = false for ancestor-forcing purposes).

**Accepted divergence (documented):** for a NON-parent-presence condition (e.g. `if: :flag`), a call omitting the parent while the condition is true fails at runtime (the subfield resolves nil and presence fires) though the schema admits the omission. This is looser-than-runtime, surfaces as a normal recoverable validation error, and only arises when a condition references something other than its own parent's presence — the canonical pattern is exact. This is the same class of narrow, documented divergence as the invalid-non-blank-default case in the schema header.

## Contradiction detectors (the PRO-2877 seam)

`check_dead_nil_tolerance!` is keyed on static declarations, with the comment already reserving this ticket's space ("a future dynamic/conditional requiredness signal (PRO-2881) is outside the reject set by construction"). Implementation:

- A new predicate `conditionally_gated?(config)` — true when the config's validations carry declaration-level `:if`/`:unless`.
- In **satisfiability mode** (the declaration-rejection detector), a gated config's requiredness is treated as relaxable: the condition may be false at runtime, so a nil/omitted ancestor CAN validate — the tolerance is exercisable, no rejection. This threads through the same `satisfiability:` flag `usable_default?` already uses for Proc defaults (unknowable-at-declaration resolves toward satisfiable; rejection is reserved for provably dead declarations).
- In **strict (schema) mode**, the gated config follows the reflection rules above.
- `check_unanswerable_segments!` and `check_conflicting_defaults!` are unaffected (conditions change neither path reachability nor defaults).
- The family-1 rejection message (`raise_dead_tolerance!`) gains a pointer at the new spelling: "…or gate the required subfield with `if:` (e.g. `if: -> { <parent>.present? }`) if it is only required when the parent is supplied."

## What we're deliberately NOT doing

- **Dynamic `optional:` (Proc/Symbol).** Redundant: `if:` on the declaration already makes requiredness conditional, and two mechanisms for one semantic invite drift. `optional:` stays a static boolean.
- **Duplicate-declaration refinements** (`expects :foo, ...` twice to split validations). Per-validator `if:` covers the motivating case in one line; the duplicate-field guard stays. Possible follow-up if the nested form proves cramped.
- **Declarative/reflectable condition forms** (and `dependentRequired`/`if-then` schema emission). Future ticket if demand appears.
- **Consolidating `optional:`/`allow_nil:`/`allow_blank:`.** Separate ticket: it's a breaking change needing a downstream sweep, and `optional:` (omittability) vs `allow_nil:` (nullability) is the closest thing we have to JSON Schema's `required`-vs-`type: null` distinction — collapsing them forecloses ever separating those axes.
- **Unifying the three existing `if:`/`unless:` evaluators** (Matcher, steps, and now fields). Out of scope; noted as a known inconsistency (Matcher forbids `if:`+`unless:` together, steps and fields AND them).

## Implementation sketch

1. `_parse_field_validations` (`contract.rb:693-733`): exempt `:if`/`:unless` from the tolerance push-down; keep them as sibling keys in the validations hash (AM distributes them). Reject tolerance flag + explicit truthy `presence:`.
2. Shape member parsing (`_build_shape_member`): reject `:if`/`:unless`.
3. `Schema.nil_accepted?`/`nil_tolerant_validation?`: skip `:if`/`:unless` keys.
4. `Schema` annotation derivation: `conditionally_gated?` predicate; satisfiability mode treats gated configs as relaxable; strict mode keeps own-level required but suppresses ancestor-forcing for gated subfields.
5. `SubfieldContradictions`: family-1 message gains the `if:` pointer.
6. Docs: `docs/reference/class.md` (option table rows + new "Conditional validation" section, including the evaluation-receiver caveat and the defaults-are-ungated rule), `docs/usage/writing.md` cross-link, terminology alignment note with steps/messages.

## Testing

- Runtime matrix: `if:`/`unless:`/both × Symbol/Proc × condition true/false × value present/absent/invalid, on `expects`, `exposes`, and `on:` subfields.
- Declaration rejections: tolerance + truthy `presence:` (all spellings), shape-member conditions.
- Tolerance + condition combinations (example 4) declare and behave correctly.
- Family-1 legalization: the PRO-2877 dummy-app shape with `if:` declares, enforces conditionally at runtime, and reflects per the schema rules; without `if:` it still rejects with the extended message.
- Schema: conditional fields reflect static-maximal; gated subfields don't force ancestors; conditions never execute during reflection (extend the existing no-execution specs to declaration-level conditions).
- Defaults/preprocess apply regardless of condition state.
- Evaluation-count and side-effect documentation backed by a spec pinning "condition may run more than once per validation pass".
