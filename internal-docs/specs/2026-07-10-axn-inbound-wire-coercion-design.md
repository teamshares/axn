# Inbound wire coercion for Ruby-object input types — design

**Ticket:** [PRO-2873 — \[Axn\] Inbound wire coercion for Ruby-object input types (Date/Time/Symbol)](https://linear.app/teamshares/issue/PRO-2873/axn-inbound-wire-coercion-for-ruby-object-input-types-datetimesymbol) (follow-up from PRO-2842; needed by PRO-2844 axn-mcp, PRO-2845 axn-ruby_llm)

**Branch:** `kali/pro-2873-axn-inbound-wire-coercion-for-ruby-object-input-types`

## Problem

Core owns the outbound **wire encoder** (`Axn::Reflection::Values.serialize_value`: `Date`→iso8601, `Symbol`→to_s, `BigDecimal`→Float) but has no inbound **decoder**. Schema reflection advertises a Ruby-object `type:` as its JSON wire form — `expects :on, type: Date` reflects as `{ type: "string", format: "date" }`, `expects :mode, type: Symbol` as `{ type: "string" }` — but `TypeValidator` does a strict `value.is_a?(klass)`, so a JSON client sending `"2026-07-08"` or `"active"` is **rejected**. Output round-trips cleanly; input does not. This is documented today as a known limitation in `docs/reference/class.md` with a manual `preprocess:` escape hatch.

This is the DRY gap PRO-2842 set out to close: if axn-mcp, axn-ruby_llm, and a future REST adapter each coerce inbound JSON scalars independently, they drift from `serialize_value`'s mapping. The encoder lives in core; the decoder should too.

It also motivates a non-tool case: os-app controllers hand-write `preprocess:` blocks to turn Rails form strings into `Date`/`Time`/`Integer` objects. A shared, standard coercion DRYs those up. Rails form inputs don't emit exactly the JSON-Schema wire form — `datetime-local` has no timezone, a `number_field` submits `"123"` as a string — so coercion is **parse-based and lenient** (`Date.parse`/`Time.parse`/`Integer(_, 10)`), NOT format-strict against `serialize_value`'s output. (Refined during review: the date/time coercers gate that lenient `.parse` behind an ISO-8601 *shape* check, so a no-offset `datetime-local` still coerces but ambiguous/partial input Ruby would guess against today — `"12"`, `"01/02/2026"`, a bare `14:30` — is left uncoerced. Lenient within the ISO shape, not fully heuristic.)

This spec covers **axn core only**: the coercion engine, the `coerce:` authoring DSL, the executor step, and the docs. The two adapters (PRO-2844, PRO-2845) consume the engine primitives and are separate tickets.

## Decided design

### 1. `Axn::Reflection::Coercion` — the inbound decoder (single source of truth)

A new module under `Axn::Reflection`, the parse-based inverse of `Values.serialize_value`, keyed off the same class set so encoder and decoder can't drift. It is **the** home for the wire→Ruby mapping; both the `coerce:` DSL (per-field, at runtime) and adapters (bulk, by walking configs) call it rather than reinventing.

**v1 coercible set** — exactly the types with a strict, unambiguous `String → T` parse:

```
Date, DateTime, Time, Symbol, Integer, Float
```

Coercers:

| Target      | Parse                        | Notes |
|-------------|------------------------------|-------|
| `Date`      | `Date.parse(s)`              | inverse of `iso8601` |
| `DateTime`  | `DateTime.parse(s)`          | inverse of `iso8601` |
| `Time`      | `Time.parse(s)`              | inverse of `iso8601` |
| `Symbol`    | `s.to_sym`                   | inverse of `to_s` |
| `Integer`   | `Integer(s, 10)`             | base 10 explicit — bare `Integer("08")` raises on octal ambiguity, which a zero-padded form field would trip |
| `Float`     | `Float(s)`                   | |

**Public primitives:**

```ruby
Axn::Reflection::Coercion.coerce_value(value, klass_or_klasses)  # => coerced value, or the original
Axn::Reflection::Coercion.coercible_klasses(type_opt)            # => the coercible subset of a type: bag's klass(es)
```

`coercible_klasses` is the single source of truth for "what does this field coerce to" — it reads a `type:` validation option (a Class, an array of Classes, or a `{ klass: … }` hash) and returns the members in the v1 coercible set. Adapters and the executor both consult it, so neither hardcodes the set.

**Coerce-or-leave semantics.** `coerce_value` only attempts on a `String` input; a non-String (a direct Ruby caller already passing a real `Date`, or a JSON-native `123`) is returned untouched. A parse that raises (`ArgumentError`/`TypeError`) returns the **original** value, so an unparseable string passes through to the normal `TypeValidator` — behavior degrades exactly to today's, with no new raise path (see the coercion-failure message below for how that error is made clearer). For a union, coercible members are tried in declaration order; the first successful parse wins; if none parse, the original is returned. (`Symbol`'s `to_sym` never raises, so a `Symbol` target always "wins" for any string — order it last in a union if a parse-first type should get priority.)

Coercion never changes strictness for a direct Ruby caller: it runs only where declared, and only transforms strings.

### 2. `coerce:` authoring DSL — lives under the `type:` option bag

Coercion is meaningless without a type and is type-specific, so it binds to the type rather than reserving a new top-level validation word (which would otherwise fall through to ActiveModel `validates`). It is a `TypeValidator` option: the `coerce` key inside the `type:` hash.

- **Explicit form:** `expects :date, type: { klass: Date, coerce: true }` — use when you also need sibling type options (`message:`).
- **Sugar (common case):** top-level `coerce: <Type>` expands to `type: { klass: <Type>, coerce: true }`, parallel to how bare `type: Date` expands to `type: { klass: Date }`. The sugar value carries the target type (a Class or array of Classes), **never** a boolean — the boolean lives only inside the type hash.
  - `expects :date, coerce: Date`
  - `expects :count, coerce: Integer`
  - `expects :mode, coerce: Symbol, inclusion: { in: %i[a b] }` (parse `"a"` → `:a`, then validate inclusion)
  - Unions: `coerce: [Date, String]`

Expansion happens in `Contract#_parse_field_validations`, before the unknown-key partition, so `coerce:` is intercepted and rewritten rather than rejected as an unknown validation key.

**Declaration-time guards (fail loudly, per "never silently ignore an option"):**

1. `coerce: <Type>` **and** `type:` together → raise (the sugar already declares the type).
2. A `coerce:` target outside the v1 coercible set → raise a clear **not-yet-supported** error naming the supported set, e.g.
   `coerce: does not yet support BigDecimal (supported: Date, DateTime, Time, Symbol, Integer, Float)`.
   This covers `coerce: :boolean`, `coerce: BigDecimal`, and arbitrary classes. Expanding the set is a future ticket (see Deferred).
3. In a union, the one allowed non-coercible member is `String` — it is the raw wire scalar itself (the coerce-or-leave fallback branch), which is why `coerce: [Date, String]` is legal. Any other non-coercible member raises (guard 2). A union must contain **≥1** coercible member, else the declaration coerces nothing → raise.
4. `coerce: true` inside a `type:` hash is rejected on **subfields, ambient-context subfields, and shape members** — mirroring the existing `preprocess:` boundary (DSL scope v1: top-level fields only). Adapters can still coerce deeper by walking the schema through the engine.

**Rejected: a config-level global setting.** Source format varies per field (JSON client vs Rails form vs direct Ruby caller passing a real `Date`), so a global can't express intent; and a global that relaxes `TypeValidator` would silently weaken strictness for direct Ruby callers everywhere. Coercion is a transport concern, opt-in per field.

### 3. Executor step — `apply_inbound_coercion!`

The inbound pipeline in `Executor#with_contract` runs `apply_inbound_preprocessing!` → `apply_defaults!(:inbound)` → `validate_contract!(:inbound)`. Coercion slots in **before** `apply_inbound_preprocessing!`, so the ordering is: **coerce (wire→Ruby), then any user `preprocess:`, then defaults, then validation.** This reuses the existing inbound-mutation slot (preprocess already runs before defaults and validation).

`apply_inbound_coercion!` iterates `internal_field_configs`, and for each field whose `validations.dig(:type, :coerce)` is truthy, rewrites `@context.provided_data[field]` via `Coercion.coerce_value(current, coercible_klasses(type_opt))`. Top-level fields only (subfields are excluded at declaration by guard 4). A coercion attempt is pure (string parse) and its failure is coerce-or-leave, so — unlike `preprocess:` — it needs no `ContractErrorHandling` wrapping; an unparseable value simply flows to `TypeValidator`.

### 3a. Coercion-failure message — distinguish uncoerceable from invalid

An uncoerceable string is bad data a caller could legitimately send, so it stays an ordinary `InboundValidationError` (recoverable, no new exception class or raise path) — but the message must distinguish *"you sent a string I couldn't coerce"* from *"you sent the wrong type"*, or a client can't tell why it failed.

`TypeValidator` sharpens its own default message rather than any new pipeline state being threaded through: when the field opted into coercion (`options[:coerce]`) **and** the leftover value is still a `String` that matched no target branch, coercion must have failed to parse it — emit *"could not be coerced to a Date"* (single target) / *"could not be coerced to one of Date, Integer"* (union), reusing the existing `types` formatting. Otherwise the plain *"is not a Date"* message stands.

This inference is precise, not a guess:
- It fires only for a **`String`** value, so a non-string mismatch (`coerce: Date` handed a real `123`) keeps *"is not a Date"* — we never attempt coercion on a non-string, so it genuinely is wrong-type data, not uncoerceable data.
- A union carrying a `String` branch (`coerce: [Date, String]`) never reaches the error path — a plain string validates against `String` — so it never emits a misleading coercion message.
- `Symbol`'s `to_sym` never fails, so in practice the coercion message only ever fires for `Date`/`DateTime`/`Time`/`Integer`/`Float` parse failures.

An explicit `message:` in the type bag still wins (`options[:message] || <default>`), unchanged — the coercion-aware string is only an alternate default. The message stays value-free (it never interpolates the raw input), matching the existing type message and avoiding leaking a sensitive field's value.

### 4. Docs

In `docs/reference/class.md`:
- Replace the "Ruby-object input types need coercion" **known-limitation warning** with a `coerce:` feature section (sugar + explicit form, the v1 coercible set, coerce-or-leave semantics, the ordering-before-`preprocess` note, and the top-level-only scope).
- Update the manual `preprocess: ->(d) { Date.parse(d) }` example in the `preprocess` section to point at `coerce: Date` as the standard replacement, keeping `preprocess:` documented for genuinely custom transforms.

## Testing

Non-Rails (`spec/`) is the primary home — coercion touches no AR/Rails constants — with Rails-adjacent behavior mirrored in `spec_rails/dummy_app/` where relevant (e.g. a form-string round-trip). Use `build_axn { … }`.

- **Coercion engine** (`spec/axn/reflection/coercion_spec.rb`): each coercible type from a valid string; `Integer("08", 10)` zero-padded case; unparseable string returns the original (identity); non-String input returned untouched; union tries members in order and falls through to original; `coercible_klasses` extracts the coercible subset from a Class / array / `{ klass: }` hash and drops non-coercible members.
- **Round-trip invariant:** for each coercible type, `coerce_value(serialize_value(x), T) == x` (or `.to_s`-equal for Time/DateTime precision), proving decoder is the inverse of the encoder.
- **DSL parsing:** sugar `coerce: Date` expands to `type: { klass: Date, coerce: true }`; explicit form accepted; guard 1 (`coerce:` + `type:`) raises; guard 2 (unsupported type, incl. `:boolean`/`BigDecimal`) raises with the supported-set message; guard 3 (`coerce: String` alone, and non-String non-coercible union member) raises; guard 4 (`coerce: true` on subfield / ambient subfield / shape member) raises.
- **Executor:** a `coerce: Date` field accepts an ISO string (coerced) AND a real `Date` (untouched); ordering — `coerce:` runs before a user `preprocess:` on the same field (preprocess observes the coerced Ruby value); a defaulted field whose default is a real object is not clobbered by coercion; direct Ruby caller strictness is unchanged for a field without `coerce:`.
- **Coercion-failure message:** `coerce: Date` given `"nope"` fails with a *"could not be coerced"* message (distinct from the plain *"is not a Date"*); `coerce: Date` given a non-string wrong-type value (a real `123`) keeps the plain *"is not a Date"*; `coerce: [Date, String]` given `"nope"` validates (String branch) with no error; an explicit `message:` overrides the coercion default.
- **Reflection unchanged:** `input_schema` for a `coerce: Date` field is identical to `type: Date` (coercion is runtime-only; `coerce:` has zero schema effect) — assert explicitly.
- **Inclusion after coerce:** `coerce: Symbol, inclusion: { in: %i[a b] }` — `"a"` coerces then passes; `"z"` coerces to `:z` then fails inclusion.

## Deferred / open

- **`:boolean`-from-string** — genuinely lenient/ambiguous (`"true"/"1"/"yes"/"on"`), no single canonical mapping, and the obvious `ActiveModel::Type::Boolean` is Rails-coupled. Its own ticket; raises not-yet-supported until then.
- **`BigDecimal`-from-string** — only matters if someone declares `type: BigDecimal` AND sends a string. Its own ticket; raises not-yet-supported until then.
- **Bulk adapter walk** (`coerce_params(data, field_configs)` or similar) — the primitives (`coerce_value` / `coercible_klasses`) ship here so adapters don't reinvent the mapping, but the bulk walk and its gating (coerce-by-declared-type on a known-JSON boundary vs only `coerce:`-flagged fields) are decided with a real consumer in hand, in PRO-2844 / PRO-2845.
- **`klass` vs `class`** naming inside the type hash — orthogonal to coercion; kept `klass` here (consistent with `model:`/`of:`), tracked separately.
- **Multiparameter `date_select`** (`date(1i)`/`date(2i)`/…) — a different mechanism (not one wire scalar), out of scope; manual/AR handling.
