# Conditional validation: `if:`/`unless:` on field declarations (PRO-2881)

**Ticket:** [PRO-2881](https://linear.app/teamshares/issue/PRO-2881/axn-global-conditional-requiredness-ifunless-on-validations-or-dynamic) — follow-up A from PRO-2877 (reject contradiction-only subfield contracts).

## Problem

axn has no global conditional-requiredness mechanism: `optional:`/`allow_nil:`/`allow_blank:` are static booleans baked into the validations hash at declaration, and `if:`/`unless:` exist only on message handlers, callbacks, and step mounting. PRO-2877 deliberately rejects a nil-tolerant ancestor with a required subfield descendant (the "dead nil-tolerance" contradiction: the tolerance can never be exercised because every nil/omitted ancestor strands the required descendant) rather than granting that shape an implicit conditional reading — but real contracts exhibit exactly that conditionality ("if `data` is present, `data.user` is required"), and today there is no sanctioned way to express it.

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

### 3. A required subfield under an optional parent, now expressible (the PRO-2877 payoff)

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
- **Scope:** `expects` (top-level and `on:` subfields), `exposes`, and shape-block members (`field :x` inside a `do…end` block). Uniform at every depth — a condition gates its declaration's validations the same way everywhere, and always resolves against the **action** (a member's condition is action-scoped, not element-scoped; see below).
- **Shape members: action-scoped conditions supported, via a shape-specific fix.** Members already *compile* conditions (they share `_parse_field_validations`, and the gates survive onto `ShapeConfig#validations`), but `ShapeValidator` builds member validators with no `action:` (`shape_validator.rb:50-52`), so any action-scoped Symbol/Proc — an `if:` condition or a Symbol validator argument like `inclusion: { in: :allowed_statuses }` — dies with `NoMethodError` on the one-off validator (verified by probe; top-level works via delegation). The fix: `ShapeValidator#validate_each`'s `record` IS the parent field's one-off validator, which already carries `@action` (threaded by `errors_for` at every level) — read it off the record (via the `_action_for_validation` seam) and pass `action:` into the member `errors_for` call. Nested shapes inherit for free: the member's own validator becomes the next level's `record`, now holding the action. This single change also fixes Symbol validator-argument delegation on shape members generally.
- **Element-scoped member conditions are an explicit NON-GOAL.** A member condition cannot see the element being validated (or its sibling members) — it resolves against the action only, same receivers as everywhere else. JSON-Schema-style `if`/`then` over an element's own shape ("member `b` required when sibling member `a` is present") is deliberately out of scope unless a future ticket takes it on.
- **Orthogonality constraint (PRO-2907):** the shape-member `method_call:` dispatch gate is carried *explicitly* per call site (`permit_method_call:` — the facade call site passes `true`, ShapeValidator passes `member.method_call`) and is deliberately **independent of `@action` presence**. Threading the action into member validation must keep `permit_method_call: member.method_call` untouched and must NOT reintroduce any "action present → permit dispatch" inference — the regression spec "gate is independent of action threading" (`spec/axn/core/validations/shape_contracts_spec.rb`, written against exactly this future change) pins it.
- **Sequencing dependency:** the member-condition work builds on PRO-2907's branch (`ShapeConfig#method_call`, the `permit_method_call:` kwarg on `errors_for`, the extract-layer gate) and edits the same lines of `fields.rb`/`shape_validator.rb`. PRO-2907 must land first; PRO-2881 rebases on top. Every other part of this design is independent of PRO-2907.
- **`on: :ambient_context` subfields:** no special handling — conditions gate their validations like any subfield.
- **Async:** conditions live on the class (frozen `FieldConfig` validations), never in the serialized payload — no Sidekiq/serialization impact.

## Flag interactions: fixes and new declaration-time rejections

The `allow_blank`/`allow_nil` push-down (`contract.rb:721-724`) runs `{ allow_blank:, allow_nil: }.merge(v)` over **every** validations entry via `transform_values!`. With `:if`/`:unless` as sibling keys, that loop needs a guard, and two combinations become dead machinery we reject outright:

| Combination | Today | New behavior |
|---|---|---|
| tolerance flag (`optional:`/`allow_nil:`/`allow_blank:`) + declaration-level `if:`/`unless:` | `TypeError: no implicit conversion of Symbol into Hash` at declaration | **Works** — the push-down skips the shared-option keys (they are not validators; the tolerance flags land on the real validators, and AM distributes the condition). Semantics per example 4 |
| tolerance flag + explicit truthy `presence:` (e.g. `presence: true`, `presence: { if: :cond }`) | `presence: true` crashes with the same bare `TypeError`; `presence: { if: :cond }` is silently neutered (the push-down merges `allow_blank: true` into the presence hash, and blank-tolerant presence always passes) | **Clear `ArgumentError` at declaration**: the tolerance contradicts the presence check — one requiredness signal per field. Same dead-machinery doctrine as PRO-2877/2889/2901. (`presence: false` + tolerance stays legal — redundant but coherent) |
| `if:` + `unless:` together | Accepted, ANDed (AM) | Unchanged — matches AR, documented. And the one subsystem that forbids the combination gets aligned (see "Companion change" below) |
| shape member with `if:`/`unless:` (or any Symbol validator arg) | Breaks at validation time — `NoMethodError` on the one-off validator (no action to resolve against) | **Works** — ShapeValidator threads the parent validator's action into member validation (action-scoped; see Semantics). Requires PRO-2907 to land first |

## Schema reflection

**Governing invariant: a condition can only relax enforcement at runtime, never tighten it.** The declared validators are the maximal contract; a false condition waives some of them for that call. So the schema reflects the **static-maximal** contract, which is the established safe direction (stricter than runtime — same doctrine as Proc defaults). Conditions are opaque Procs/Symbols and are **never executed** during reflection (the existing side-effect-free doctrine; already spec-protected for per-validator `if:`).

**This tradeoff must be loudly documented.** Static-maximal means the schema tells tool consumers they can't send parameter combinations that ARE valid at runtime (omitting a field whose condition would be false). That is deliberately preferred over advertising combinations the runtime rejects, but it is a real cost, so the published docs get an explicit callout of the invariant: *the schema advertises the maximal contract — a conditionally-validated field is reflected as if every gate were open (`if:` conditions treated as true, `unless:` conditions treated as false, every declared validator counted); the schema may be stricter than the runtime, never looser (outside the narrow exceptions documented on the Schema module)*. The implementation must hold that direction in every placement (top-level, subfield, exposes, tolerance-flag combinations), and the test plan includes a direction audit.

Concretely:

- `expects :num, type: Integer, if: :cond` → reflected required, non-nullable (as if unconditional). A caller following the schema always supplies a valid `num`, which passes whether or not the condition fires.
- `expects :note, type: String, optional: true, if: :cond` → reflected optional (the static tolerance is unconditional; only the type check is gated). Requires fixing `nil_accepted?` (`schema.rb:1081-1096`), which iterates every validations key and would treat `:if` as an unknown nil-rejecting validator — it must skip the shared-option keys (`:if`/`:unless`), treating them as neutral. `FieldConfig#optional?` (the axn-mcp shared predicate) already ignores non-Hash entries and keys off `presence` — no change needed.
- **Opaque conditions (Proc, or a Symbol naming a non-field method) emit no conditional schema** — static-maximal is the only sound fallback for them.
- **A gated `exposes` field is reflected UNTYPED on `output_schema`** (description only — no type/format/enum/default). The output direction is the mirror of input: the property must admit a SUPERSET of what the serializer can emit. A closed outbound gate skips *every* validator (not just presence), so the exposed value can be anything the action assigned — `exposes :num, type: Integer, if: :flag` with `flag` false accepts `expose num: "oops"`. Asserting `type: integer` (or even null-admitting `["integer", "null"]`) would advertise a constraint the serialized value can contradict, the looser direction. Untyped is the only sound superset — mirroring the module's existing output doctrine for a value whose serialized shape isn't statically knowable.
- **Shape members reflect static-maximal, always.** Member requiredness flows through the shared `optional_for_schema?`/`nil_accepted?` predicates (which skip the gate keys), so a gated member reflects as if its gates were open — required unless it carries its own tolerance. The declarative emission below is top-level-only: a member's action-scoped condition references a field *outside* the element, and JSON Schema conditionals across that boundary (root `allOf` reaching into `items`) aren't worth their complexity in v1.

### Declarative reflection: Symbol conditions referencing a declared field

A Symbol condition that names a *declared sibling field* is NOT opaque — reflection can resolve it statically (against reader names, including a boolean field's generated `?` predicate alias) without executing anything. For that case we can emit an exact JSON Schema conditional instead of over-requiring. Ruby truthiness on a JSON value is precisely "present, and neither `false` nor `null`", so:

```ruby
expects :promo_enabled, type: :boolean
expects :coupon_code, type: String, if: :promo_enabled?
```

reflects as `coupon_code` absent from the top-level `required`, plus:

```json
"allOf": [{
  "if": { "required": ["promo_enabled"], "properties": { "promo_enabled": { "not": { "enum": [false, null] } } } },
  "then": { "required": ["coupon_code"] }
}]
```

`unless:` emits the same `if` clause with `else` instead of `then`. The gated field's *property* (type etc.) stays static-maximal and unconditional — only its `required` membership becomes conditional (a wrong-typed value sent while the condition is false is rejected by schema but accepted by runtime: stricter, safe).

**Guards — all must hold, else fall back to static-maximal required:**

- exactly one of `if:`/`unless:` is given, and its value is a Symbol;
- the Symbol resolves to a declared **top-level inbound** field's reader (a `?`-suffixed Symbol resolves through the boolean predicate alias to its field) — anything else is an action method, opaque;
- the Symbol still resolves to the **framework-generated** reader — verified by `source_location` against the reader-generation site (`Axn::Core::Contract::GENERATED_READER_SOURCE_PATH`), requiring the action class to be threaded into emission (`build_input(klass:)`; nil for direct callers falls back). A user can suppress predicate generation with a pre-existing `?` method, or redefine a plain reader with `def` after `expects` — in both cases runtime evaluates the USER method against the settled value while the clause conditions on the wire value, so the schema could accept a call runtime rejects. Pure introspection, side-effect-free;
- the referenced field carries no `default:` and no `preprocess:` — either can make the settled runtime value diverge from what the caller sent, flipping the condition relative to the wire (a default of `true` on an omitted field would make the schema looser than runtime, the forbidden direction);
- for an `unless:` gate, the referenced field's type must not admit boolean coercion of a schema-admissible String wire value. Coercion can only flip a truthy wire value (`"false"`/`"f"`/`"0"`) to falsey (the `:boolean` target on a `String`/`:uuid`-admitting type; every other target yields truthy from truthy). For an `if:` gate that flip leaves the emitted `then` STRICTER than runtime (safe — the clause is still emitted), but for an `unless:` gate it OPENS the runtime `else` gate the emitted clause left closed — schema looser than runtime, the forbidden direction — so a flippable reference falls back to unconditional required;
- no subfield **default** anywhere beneath the referenced field can synthesize it — an applied default at any depth materializes the parent (`apply_defaults_for_subfields!` injects `{}`), so a wire-omitted referenced field settles truthy and the runtime gate opens while the emitted clause still sees it absent (schema looser than runtime). Only defaults matter: a subfield `preprocess:` never materializes an absent root (the executor drops the write when the root is nil), so preprocess-at-depth cannot flip the gate;
- the referenced field is not `model:` (its reader resolves a record; lookup success isn't wire-expressible);
- the gated field is itself top-level and statically required (subfields keep the nested-`required` rule above; an already-optional field has nothing to make conditional).

This covers the canonical boolean-flag pattern exactly, degrades to the safe fallback everywhere else, and is purely an emission refinement (zero runtime impact) — so it can land as a fast-follow PR if the main implementation runs large. `dependentRequired` remains unused (it conditions on key *presence* only; truthiness needs `if`/`then`).

**One deliberate exception to static-maximal: a gated required subfield does not force its ancestors.** In plain terms: the parent's optionality is a fact the user declared, not something a child's condition can waive — applied blindly, static-maximal would bubble the child's requiredness upward and mark `data` itself required, contradicting the explicit `optional: true` and telling tool consumers "always send `data`" for the exact pattern this feature legalizes. And JSON Schema already scopes the child's obligation natively: a nested `required` only binds when the parent object is actually sent, dormant otherwise — which is precisely the canonical condition (`if: -> { data.present? }`). So we keep full strictness *inside* the parent object and decline to invent strictness the declaration explicitly disavowed. For the optional-parent example (example 3 above) that means: `data` optional/nullable, with `data`'s object schema carrying `required: ["user_id"]` (the model route's wire token). In strict (schema) mode:

- the gated subfield stays in its parent's nested `required` array (own-level static-maximal), but
- it does NOT propagate requiredness/non-nullability up the ancestor chain (`NodeAnnotation.required` = false for ancestor-forcing purposes).

```ruby
expects :data, optional: true
expects :user, type: String, on: :data, if: -> { data.present? }
```

```json
{
  "properties": {
    "data": {
      "type": ["object", "null"],
      "properties": { "user": { "type": "string" } },
      "required": ["user"]
    }
  }
}
```

`data` stays omittable and nullable (no top-level `required`, `null` admitted) — without the exception, the required child would force `data` into the top-level `required` with `type: "object"`, defeating the declared `optional: true`. The nested `required: ["user"]` binds only when a `data` object is actually sent — which is exactly when the canonical condition fires. For this shape, schema and runtime agree on every input.

**Accepted divergence (documented):** for a NON-parent-presence condition, the schema can be looser than runtime in one corner — the parent omitted while the condition is true:

```ruby
expects :strict_mode, type: :boolean
expects :data, optional: true
expects :user, type: String, on: :data, if: :strict_mode
```

```ruby
Action.call(strict_mode: true) # data omitted
# schema:  accepts — data is optional, so the nested required: ["user"] never binds
# runtime: rejects — strict_mode is truthy, so user's validators run, resolve nil, and presence fires
```

This surfaces as a normal recoverable validation error, and only arises when a condition references something other than its own parent's presence — the canonical pattern is exact. This is the same class of narrow, documented divergence as the invalid-non-blank-default case in the schema header.

## Contradiction detectors (the PRO-2877 seam)

`check_dead_nil_tolerance!` is keyed on static declarations, with the comment already reserving this ticket's space ("a future dynamic/conditional requiredness signal (PRO-2881) is outside the reject set by construction"). Implementation:

- A new predicate `conditionally_gated?(config)` — true when the config's validations carry declaration-level `:if`/`:unless`.
- In **satisfiability mode** (the declaration-rejection detector), a gated config's requiredness is treated as relaxable: the condition may be false at runtime, so a nil/omitted ancestor CAN validate — the tolerance is exercisable, no rejection. This threads through the same `satisfiability:` flag `usable_default?` already uses for Proc defaults (unknowable-at-declaration resolves toward satisfiable; rejection is reserved for provably dead declarations).
- In **strict (schema) mode**, the gated config follows the reflection rules above.
- `check_unanswerable_segments!` and `check_conflicting_defaults!` are unaffected (conditions change neither path reachability nor defaults).
- The dead-tolerance rejection message (`raise_dead_tolerance!`) gains a pointer at the new spelling: "…or gate the required subfield with `if:` (e.g. `if: -> { <parent>.present? }`) if it is only required when the parent is supplied."

## What we're deliberately NOT doing

- **Dynamic `optional:` (Proc/Symbol).** Redundant: `if:` on the declaration already makes requiredness conditional, and two mechanisms for one semantic invite drift. `optional:` stays a static boolean.
- **Duplicate-declaration refinements** (`expects :foo, ...` twice to split validations). Per-validator `if:` covers the motivating case in one line; the duplicate-field guard stays. Possible follow-up if the nested form proves cramped.
- **A separate declarative condition DSL.** Symbol-references-a-field already reflects declaratively (see above) without new surface area; a hash-based condition language stays unbuilt unless demand appears.
- **Consolidating `optional:`/`allow_nil:`/`allow_blank:`.** Separate ticket: it's a breaking change needing a downstream sweep, and `optional:` (omittability) vs `allow_nil:` (nullability) is the closest thing we have to JSON Schema's `required`-vs-`type: null` distinction — collapsing them forecloses ever separating those axes.
- **Merging the `if:`/`unless:` evaluator implementations** (Matcher, steps, fields). Their receivers and rule vocabularies differ for good reason (matchers also match exception classes/strings and receive the exception; fields ride ActiveModel) — only the *combination rule* is aligned, per the companion change below.

## Companion change: allow `if:` + `unless:` together on messages and callbacks

The message/callback `Matcher` forbids combining `if:` and `unless:` — a simplicity shortcut, not a semantic necessity — while steps AND them and fields (this ticket) AND them per AR. That leaves one arbitrary odd-one-out, so we align it: combining becomes legal everywhere, uniformly meaning *every given condition must pass* (`if:` truthy AND `unless:` falsey).

```ruby
error "Payment declined", if: PaymentError, unless: :retryable?
```

Three sites currently reject the combination and change together: `Matcher.build` (`matcher.rb:93`, the core — `Matcher` grows independent if/unless rule sets, ANDed, instead of one rule list with a single global invert flag) plus the redundant early guards at `messages.rb:25` and `callbacks.rb:46`. Existing single-condition behavior (including multi-rule `if: [A, B]` requiring all, and `unless: [A, B]` requiring none) is unchanged. Purely additive: every declaration that raises `UnsupportedArgument`/`ArgumentError` today gains a meaning; nothing legal changes behavior.

## Implementation sketch

1. `_parse_field_validations` (`contract.rb:693-733`): exempt `:if`/`:unless` from the tolerance push-down; keep them as sibling keys in the validations hash (AM distributes them). Reject tolerance flag + explicit truthy `presence:`. (Shared path: covers top-level, subfields, exposes, AND shape members.)
2. `ShapeValidator#validate_members`: read the action off `record` (the parent's one-off validator, via `_action_for_validation`) and thread `action:` into the member `errors_for` call — keeping `permit_method_call: member.method_call` exactly as-is (orthogonality constraint). Depends on PRO-2907 landing first.
3. `Schema.nil_accepted?`/`nil_tolerant_validation?`: skip `:if`/`:unless` keys.
4. `Schema` annotation derivation: `conditionally_gated?` predicate; satisfiability mode treats gated configs as relaxable; strict mode keeps own-level required but suppresses ancestor-forcing for gated subfields.
5. `SubfieldContradictions`: the dead-tolerance rejection message gains the `if:` pointer.
6. Companion change: `Matcher` grows independent if/unless rule sets (ANDed); drop the three both-given guards (`matcher.rb:93`, `messages.rb:25`, `callbacks.rb:46`).
7. Docs: `docs/reference/class.md` (option table rows + new "Conditional validation" section, including the evaluation-receiver caveat and the defaults-are-ungated rule), `docs/usage/writing.md` cross-link + the messages `if:`+`unless:` combination, terminology alignment note with steps/messages.

## Testing

- Runtime matrix: `if:`/`unless:`/both × Symbol/Proc × condition true/false × value present/absent/invalid, on `expects`, `exposes`, and `on:` subfields.
- Declaration rejections: tolerance + truthy `presence:` (all spellings).
- Shape members: action-scoped `if:`/`unless:` and Symbol validator args resolve against the action (top-level and nested members); the PRO-2907 "gate is independent of action threading" regression spec stays green; a member condition referencing element data documented/pinned as unresolvable (non-goal); gated members reflect static-maximal.
- Tolerance + condition combinations (example 4) declare and behave correctly.
- Optional-parent legalization: the PRO-2877 dummy-app shape (optional parent + required subfield) with `if:` declares, enforces conditionally at runtime, and reflects per the schema rules; without `if:` it still rejects with the extended message.
- Schema: conditional fields reflect static-maximal; gated subfields don't force ancestors; conditions never execute during reflection (extend the existing no-execution specs to declaration-level conditions).
- Declarative Symbol emission: exact `allOf`/`if`/`then` for the qualifying shape (including the `?` predicate spelling); each guard individually forces the fallback (Proc, non-field method, defaulted/preprocessed/model referenced field, subfield placements, both-conditions).
- Direction audit: a matrix spec asserting schema-vs-runtime strictness direction (schema stricter or exact, never looser) across condition placements — top-level, subfield, exposes, tolerance combinations, declarative emission.
- Defaults/preprocess apply regardless of condition state.
- Evaluation-count and side-effect documentation backed by a spec pinning "condition may run more than once per validation pass".
- Companion change: `error`/`success`/`fails_on`/`on_*` callbacks accept `if:` + `unless:` together (ANDed, both single rules and arrays); single-condition and array-rule behavior pinned unchanged.
