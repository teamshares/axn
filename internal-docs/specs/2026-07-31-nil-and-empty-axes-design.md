# Separate the nil and empty axes (PRO-3016)

/ Linear: https://linear.app/teamshares/issue/PRO-3016/axn-separate-the-nil-and-empty-axes-allow-empty-requiredness-parity

## Problem

`presence` means `!blank?` — non-nil **and** non-empty — so one word governs two independent questions. That welding is harmless for a `String` name field, where `nil` and `""` are equally useless. It breaks the moment emptiness is meaningful data, which is every collection.

Split the axes and there are four coherent contracts. Two of them have first-class names; both cells where the axes disagree are reachable only by accident, through a kwarg that names neither axis correctly.

## What the probe found

Every row below was run against both `0.1.0-alpha.4.3` (the version the report came from) and `0.1.0-alpha.5`, at top level and as shape members, with identical results.

```
type: Array                                            nil=FAIL  []=FAIL  [1]=PASS
type: Array, optional: true                            nil=PASS  []=PASS  [1]=PASS
type: Array, allow_blank: true                         nil=PASS  []=PASS  [1]=PASS
type: Array, allow_nil: true                           nil=PASS  []=PASS  [1]=PASS
type: Array, presence: false                           nil=FAIL  []=PASS  [1]=PASS
type: Array, presence: { allow_blank: true }           nil=FAIL  []=PASS  [1]=PASS
type: Array, presence: true, allow_nil: true           → ArgumentError at declaration
type: Array, presence: { allow_nil: true }             nil=FAIL  []=FAIL  [1]=PASS
type: Array, allow_nil: true, length: { minimum: 1 }   nil=PASS  []=FAIL  [1]=PASS
```

`optional:` / `allow_blank:` / `allow_nil:` are three spellings of one cell. "Non-nil, may be empty" has two accidental spellings (`presence: false`, `presence: { allow_blank: true }`) and no name. "May be nil, must be non-empty" is expressible only through `length:`, while its natural Rails spelling raises at declaration.

Three consequences follow, in the ticket. The two that shape this design:

`FieldOptionality#optional?` (`contract.rb:44`) answers `true` for `presence: false`, while `input_schema` emits that same field as `required` and non-nullable. Two independent requiredness derivations, one of them keyed on a proxy (`is there a presence: true?`) rather than the question that matters. The schema layer asks the right one: `nil_accepted?` (`reflection/schema.rb:1240`) — "do this field's real validators accept nil?"

`minItems` / `minLength` / `minProperties` are emitted nowhere in `lib/`. A bare `expects :order_ids, type: Array` rejects `[]` at runtime and emits `{"type":"array"}`, which permits it — the schema being *looser* than the runtime, with no flag involved, contradicting the invariant `docs/reference/class.md:214` states. An axis that is not modeled cannot be reflected.

## Decisions

### 1. `allow_empty:` is a top-level requiredness flag, not a type refinement

```ruby
type: Array                                       # non-nil, non-empty   (default, unchanged)
type: Array, allow_empty: true                    # non-nil, may be empty
type: Array, optional: true                       # may be nil, may be empty
type: Array, optional: true, allow_empty: false    # may be nil, non-empty
```

Because the flags sit on different axes they compose, which is what makes the fourth cell expressible. `allow_empty: true` adds no check — it suppresses the auto-injected `presence: true` (`contract.rb:1150-1152`). `allow_empty: false` asserts non-emptiness: already satisfied by the default `presence: true` on a non-tolerant field, and injected (decision 2) under a nil-tolerance. It is never silently ignored, though it may restate what the default already guarantees. `allow_empty: true` alongside a nil-tolerance (`optional: true, allow_empty: true`) is likewise permitted and redundant — it names the emptiness half of what the tolerance already grants, which is emphasis rather than dead machinery, and rejecting it would punish authors for spelling out the cell they meant.

It lives at top level, alongside `optional:` / `allow_blank:` / `allow_nil:`, and follows `optional:`'s existing path as a declaration-level kwarg that never becomes a validation entry (`contract.rb:862`). Nesting it in the type bag was rejected: the real constraint is "a type whose instances can be empty," and `type: { klass: Integer, allow_empty: true }` is as meaningless as the bare form, so nesting does not earn the guard that is needed either way. `of:` faced the identical choice and stayed top-level behind a guard; `coerce:`, which genuinely binds to the type, is still *spelled* flat (`contract.rb:1090`).

**Guard:** `allow_empty:` requires a declared type whose instances can be empty — `Array`, `Hash`, `Set`, `String`, `:params`. Raise for `Integer` / `:boolean` / `:uuid` / no type at all, per *Fail at declaration, not runtime* (`AGENTS.md:61-63`). Without a type the flag is a silent no-op that accepts everything including `nil`; on a non-empty-able type there is no empty state to permit.

Add `allow_empty` to `SHAPE_MEMBER_FIELD_OPTIONS` (`contract.rb:710`) for parity with `allow_blank` / `allow_nil` / `optional`. The motivating downstream fields are shape members; without this they cannot use the flag.

### 2. The emptiness predicate is size-based, not blankness-based

`presence` cannot serve the emptiness axis, and the probe shows why in two directions. `presence: { allow_nil: true }` does not produce the mirror cell — the type validator still rejects `nil`, so it lands back on "non-nil, non-empty". And `presence` rejects whitespace-only strings: `type: String` rejects `" "`, which is not empty. `blank?` and `empty?` are different predicates, and this axis is `empty?`.

`length: { minimum: 1 }` is the correct primitive. It is size-based, so `" "` satisfies it; it works uniformly across `Array` / `Hash` / `Set` / `String` (all probed); and it maps directly onto the reflection targets in decision 6. What it gets wrong is register — `"is too short (minimum is 1 character)"` is the wrong sentence about an Array — so the injected form carries a message override reading `can't be empty`.

When the author has already declared a `length:` minimum of 1 or more, nothing is injected: their own constraint already forbids empty. That is a stronger statement, not a contradiction, so it does not raise.

### 3. Narrow the tolerance-vs-`presence:` rejection rather than deleting it

`contract.rb:1119-1125` rejects any tolerance flag combined with a truthy `presence:`. The reasoning is sound about the *mechanism* — tolerance is pushed into every validator, so the presence check could never fire — but it is stated as though the author asked for something incoherent, and they did not: `presence: true, allow_nil: true` is the plain Rails idiom for the mirror cell. Narrow the guard so it rejects only genuinely dead combinations, and route the coherent request through `allow_empty: false`, whose injected check tolerates `nil` by construction.

### 4. One requiredness question, not two

`FieldOptionality#optional?` reuses the question the schema layer already asks rather than keeping its own proxy. Its comment claiming axn-mcp derives `required` from this predicate is stale — axn-mcp consumes core's schema generation now — so the predicate has no remaining schema-consumer justification and no reason to disagree with `input_schema`. `default_call.rb:18` is the other reader.

This is the only correctness bug in the batch: today a `presence: false` field is `optional? == true` and `required` in the schema simultaneously.

### 5. One error per nil, not N

`presence: false` plus `validate:` currently yields `H is not a Hash and H failed validation: undefined method 'values' for nil` — the type error plus a crashed custom validator. Where a field rejects `nil` by type, push a nil-skip into the non-type validators so a `nil` produces exactly the type error. Without this, blessing any spelling of cell 2 obliges every `validate:` lambda in every downstream codebase to grow a nil guard.

### 6. Reflect the emptiness axis

Emit `minItems` (Array), `minProperties` (Hash), `minLength` (String) whenever the field's validator set rejects empty — from the injected check, from an author-declared `length:` minimum, and from the plain default `presence: true` on an empty-able type. The last is what closes the consequence above for the default case, independent of any new flag.

One honest limit: for `String` under `presence: true` the runtime also rejects `" "`, which `minLength: 1` permits. The emitted schema is therefore still looser than the runtime for strings — narrower than today, but not exact. `Array` / `Hash` / `Set` become exact.

### 7. Docs

A four-cell table in `docs/reference/class.md` showing all four contracts adjacently, so it is visible on one screen that three existing spellings occupy one cell. A row in `AGENTS-consuming.md`, whose tolerance table (L64) lists only `optional:`. And a correction to `reflection/schema.rb:14-15`, which lists `presence: false` among the *omittable* signals — true only of the type-less form that decision 1 makes illegal.

## Tests

Table-driven cell coverage is the shape that fits: for each of `Array` / `Hash` / `Set` / `String`, assert all four cells against `nil` / empty / non-empty / wrong-type, at top level, as a subfield, and as a shape member. The bug being fixed is a missing cell, so the test that matters is the one that enumerates cells rather than examples.

Beyond that: the guard rejects each non-empty-able type and the type-less form; `optional?` and `input_schema` agree for every cell (a shared-derivation test, since disagreement is the bug); a `nil` under cell 2 with a `validate:` lambda that would crash on `nil` produces exactly one error; and reflection emits the right length constraint for each container, including the flag-free default.

## Scope boundary

Core only. Downstream migration is a separate pass — `os-app` `lib/vanguard/sentry/internal/normalize_snapshot.rb` deletes its hand-maintained `NIL_COLLECTION_FIELD_PATHS` guard, and the `allow_blank:` collection fields in `os-app` / `axn-mcp` / `axn-ruby_llm` / `data_shifter` / `slack_sender` each need a decision about which cell they meant.

Sequence `minItems` emission last within the PR. It is the only piece with no new syntax and the widest blast radius: every required-collection schema in every downstream tool changes shape, and nothing in `reflection/schema.rb` emits length constraints today.

## Non-goals

**Changing the default.** `type: Array` meaning "non-empty" is arguably the true root cause — it is what pushes authors onto `allow_blank:` and into the `nil` hole. Making it mean "must be an Array" with non-emptiness opt-in silently loosens every existing `expects :ids, type: Array`. Out of scope; revisit only with deliberate intent, not as a side effect of this work.

**`of:` or shape blocks carrying the signal.** Structurally disqualified: `of:` raises `of: requires type: Array`, and shape blocks describe *named* members, so neither can reach a dynamic-key map like the motivating `cogs_nl_history`. Letting `of:` *imply* non-nil-may-be-empty was considered and rejected — it covers only the Array half, and would make requiredness a side effect of declaring an element type, so adding `of: Integer` to an existing field would silently start accepting `[]`.

**Blessing `presence: false` in docs instead of naming the cell.** Its plain reading is the opposite of its effect, its meaning is not local to the line (it has teeth only because a sibling `type:` supplies them), and `presence: false` → `optional: true` reads like a tidy-up while reopening the hole. The concept becomes documented load-bearing API either way; the only question is whether it gets a name that says what it does.

**Collapsing the three synonyms.** `optional:` / `allow_blank:` / `allow_nil:` all landing on one cell is redundant surface, but deduplicating them is a breaking rename with no correctness content. Note it in the docs table; leave the code alone.

**`type: Set` outbound nullability.** `output_schema` emits `required` for both `allow_blank: true` and `presence: false` on a `Set` exposure, apparently because `Set` has no JSON mapping to hang nullability on. Found while probing, almost certainly orthogonal, tracked in the ticket's closing note.
