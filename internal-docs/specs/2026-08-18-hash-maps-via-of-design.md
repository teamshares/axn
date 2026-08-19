# Hash maps via `of:`, and closing the `of:`-bag silent-ignore hole

Ticket: https://linear.app/teamshares/issue/PRO-3165/axn-hash-maps-via-of-and-close-the-nested-of-silent-ignore-hole

Follow-up (out of scope here): https://linear.app/teamshares/issue/PRO-3166/axn-recursive-of-containers-inside-containers

## Problem

`of:` is Array-only. `expects :h, type: Hash, of: String` raises `of: requires type: Array (got [Hash])`, so an open-ended map — arbitrary keys, homogeneous values — cannot be declared at all. Hash structure comes only from `shape:`, which describes **named** members, so `{"acme" => 12, "globex" => 3}` has no spelling for either validation or schema reflection.

Separately, an `of:` bag reaches `OfValidator` as an `ActiveModel::EachValidator` options hash, which ignores every key it does not read. The guard at `lib/axn/core/contract.rb:2132` runs only on top-level bags, so anything written *inside* an `of:` bag is silently dropped:

```ruby
of: { klass: Hash, shape: { members: [...] } }            # shape dropped — [{a: 1}] passes
of: { klass: String, mesage: "typo" }                     # custom message dropped
of: { klass: String, keys: Symbol, of: Integer, wat: 1 }  # all four ignored
```

This is the failure mode the comment at that guard warns about — "an `of:` that constrains nothing is refused instead of ignored" — reached by a path the guard does not cover. The author writes a constraint, the class declares cleanly, and every value passes.

## Grammar

`of:` names **what is inside a container**, and the declared `type:` decides what "inside" means: an Array has elements, a Hash has keys and values.

```ruby
expects :counts, type: Hash,  of: { keys: Symbol, values: Integer }
expects :counts, type: Hash,  of: { values: Integer }               # keys unconstrained, visibly
expects :ids,    type: Array, of: Integer                           # unchanged
expects :ids,    type: Array, of: { klass: Integer, message: "…" }  # unchanged
```

`keys:` and `values:` exist **only inside the `of:` bag**, so no top-level declaration name is taken. Each accepts the same forms as `type:`: a single class, a union array, the `:boolean`/`:uuid`/`:params` symbols, or a `Data` class. Either may be omitted, and omitting one is how "that axis is unconstrained" is said.

The bare form stays Array-only. `type: Hash, of: Integer` raises rather than guessing which axis it constrains — a Hash has two things inside, and picking one by convention is the ambiguity this grammar exists to avoid.

An Array anywhere in this grammar means a **union**, unchanged from today: `values: [String, Integer]` is "String or Integer", never a key/value pair and never a tuple.

### Why the `of:` bag rather than the alternatives

**A positional pair (`of: [Symbol, Integer]`)** forces a wildcard token into the grammar for the common values-only case (`of: [:any, Integer]`), makes array *depth* carry meaning once an axis needs a union (`of: [Symbol, [String, Integer]]`), and mixes positional with bag form as soon as an axis may carry a nested contract.

**Top-level `keys:`/`values:`** would take two generic words out of the field-declaration namespace permanently.

**The `type:` bag (`type: { klass: Hash, keys:, values: }`)** would put an Array's inner contract under `of:` and a Hash's under `type:`, leaving PRO-3166 two descent seams to make recursive instead of one.

Container-dependent option meaning is existing precedent rather than a new idea: `shape:` already means "each element's members" under `type: Array` and "this hash's own members" under `type: Hash`, and `container:` is derived at declaration (`lib/axn/core/contract/shape_declaration.rb:282`) precisely to carry that distinction into the validator. `of:` reading as element-versus-pair on the same basis rides machinery that is already there.

## Declaration-time rules

The `of:` bag's allowed keys become container-dependent, and that one whitelist is what closes the silent-ignore hole. `shared` below is `Axn::Validation::Base.shared_validation_option_keys` (ActiveModel's `if`/`unless`/`on`/`allow_nil`/`allow_blank`/`strict`).

| container | allowed keys |
|---|---|
| `Array` | `klass`, `message`, *shared* |
| `Hash` | `keys`, `values`, *shared* |

`message:` is deliberately **not** allowed under `Hash`: one message cannot say which axis failed, and per-axis messages arrive with PRO-3166's nested bags (`values: { klass: Integer, message: "…" }`). `on:` passes the whitelist and is left to the existing context-scope guard (`_reject_validator_context_scope!`), which has the better message for it — so it is admitted here and refused a line later, on every container, and the unknown-key error does not list it among the keys it calls supported.

Every declaration-time outcome:

| Declaration | Outcome |
|---|---|
| `type: Array, of: String` | unchanged |
| `type: Array, of: [String, Numeric]` | unchanged — union |
| `type: Array, of: { klass: String, message: "…" }` | unchanged |
| `type: Array, of: { values: String }` | **raise** — `of:` names an Array's elements; use `klass:` |
| `type: Array, of: { klass: String, of: Integer }` | **raise** — unknown key (closes the hole) |
| `type: Array, of: { klass: Hash, shape: {…} }` | **raise** — unknown key (closes the hole) |
| `type: Array, of: { klass: String, mesage: "…" }` | **raise** — unknown key (closes the hole) |
| `type: Hash, of: { values: Integer }` | **new** — map |
| `type: Hash, of: { keys: Symbol, values: Integer }` | **new** — map |
| `type: Hash, of: { keys: Symbol }` | **new** — keys constrained, values not |
| `type: Hash, of: Integer` | **raise** — the bare form is Array-only; name the axis |
| `type: Hash, of: { klass: Integer }` | **raise** — point at `values:` |
| `type: Hash, of: {}` | **raise** — constrains nothing |
| `type: Hash, of: { values: [] }` | **raise** — an axis naming an empty union names no class, so it constrains nothing; judged as an absent axis |
| `type: Hash, of: { keys: [], values: Integer }` | **new** — one empty axis is the same as omitting it, so the other still stands |
| `type: Hash, of: { values: Integer, message: "…" }` | **raise** — unknown key; per-axis messages are PRO-3166 |
| `type: Hash, of: { values: { klass: Integer } }` | **raise** — not supported yet (PRO-3166) |
| `type: Hash, of: { values: Integer }, shape: {…}` | **raise** — not supported yet (PRO-3166) |
| `type: [Array, Hash], of: …` | **raise** — the container cannot be derived from a union |
| `of:` with no `type:`, or a scalar `type:` | **raise** — message updated to name Array **or Hash** |

Two of those rows carry wording constraints. `of:` together with `shape:` on a Hash must say **"not supported yet"** rather than implying it is meaningless — the two are complements (`shape:` emits `properties`, `of:` emits `additionalProperties`), and PRO-3166 grants the combination, so an error claiming incoherence would contradict a later release. Likewise the union-`type:` rejection mirrors the existing shape rule ("a shape block requires a single structured type") rather than inventing a second sentence for the same situation.

## Runtime validation

Map errors locate a failing entry by ORDINAL, never by key: `key at index 0 is not a Symbol`, `value at index 0 is not a Integer`. Validator messages do not pass through redaction, so a rendered key would leak a `sensitive:` field's data into `result.exception.message` and the INFO log line — which the element branch deliberately avoids (`type_validator.rb`: "Value-free, like `msg`, so no sensitive input leaks"). `sensitive:` is not reachable where the `of:` bag is canonicalized, so the message is unconditionally value-free rather than value-free only for sensitive fields. Restoring key names for non-sensitive fields is follow-up work.

`OfValidator` grows a Hash branch beside its Array loop, mirroring `ShapeValidator`'s two-branch structure (`lib/axn/core/validation/validators/shape_validator.rb:35-45`). Dispatch is on a `container:` derived into the bag at declaration — the same move `_derive_raw_shape_container!` makes for `shape:` — never on the runtime value's class, so a Hash arriving under `type: Array` is not quietly validated as a map.

| Value | Outcome |
|---|---|
| not a Hash, under `type: Hash` | return; `TypeValidator` owns the type error |
| `nil` with `allow_nil`/`allow_blank` | skipped, as today |
| `{}` | no entries, so no `of:` errors; emptiness stays `allow_empty`'s and `presence`'s business |
| `{"a" => 1}` with `keys: Symbol` | `key at index 0 is not a Symbol` |
| `{a: "x"}` with `values: Integer` | `value at index 0 is not a Integer` |
| `{"a" => "x"}` with both declared | both errors, independently |

No key is rendered at all, so nothing dispatches to one: a key that raises from its own `inspect`/`to_s` cannot replace a validation verdict with its exception, and there is no rendering seam to route it through. The ordinal supplies the locating information instead — a Hash enumerates in insertion order, so index 0 names the entry the caller wrote first. The traversal itself is a BOUND `Hash#each` (`ShapeGraph.each_entry`), so a Hash subclass cannot decide which entries get validated.

`allow_nil`/`allow_blank` govern whether the **whole field** may be absent, not whether an individual key or value may be blank — identical to the documented behaviour for Array elements (`docs/reference/class.md:182`).

Coercion is unaffected. `coerce:` operates on the field's own value (`type: { klass:, coerce: true }`) and has never descended into an Array's elements; a map's keys and values are treated the same way, so nothing here coerces per entry.

## Schema reflection

A map emits `additionalProperties`, built by generalizing `items_schema_for` (`lib/axn/internal/reflection/schema.rb:1548`) rather than duplicating it, so a union falls out unchanged:

```ruby
expects :counts, type: Hash, of: { values: Integer }
#=> { "type": "object", "additionalProperties": { "type": "integer" } }

expects :counts, type: Hash, of: { values: [String, Integer] }
#=> { "type": "object", "additionalProperties": { "anyOf": [{ "type": "string" }, { "type": "integer" }] } }

expects :points, type: Hash, of: { values: Point }   # Point = Data.define(:x, :y)
#=> { "type": "object", "additionalProperties": { "type": "object", "properties": { "x": {}, "y": {} } } }
```

`keys:` emits **nothing**. Every JSON object key is a string, so `keys: String` would say nothing a client can act on and `keys: Symbol` would be a lie on the wire. It is a Ruby-side check in this change; `propertyNames` becomes worth emitting only once an axis can carry a format or an inclusion, which is PRO-3166's nested-bag territory.

`each_emitted_node` (`lib/axn/internal/reflection/property_names.rb:343`) learns `additionalProperties`, with a new unnamed path segment beside `ITEMS_SEGMENT` — a segment no declared name can produce, on the same terms. This is required rather than precautionary: the third example above puts real property names under the map rung, and both the collision rules and the 25,000-property cap are derived from the emitted schema, so a rung they cannot walk is a rung they cannot charge.

Output projections take the same path as input, through `effective_validations`/`shape_property_plan`, so per-validator gating and the outbound-serialization checks apply to a map exactly as they do to an array's items.

## Consumers deliberately untouched

**Redaction** descends by member **name**, via `shape_in`/`nested_shape`. A map declares no members in this change — nested contracts inside `keys:`/`values:` are PRO-3166 — so there is nothing new to descend into, and `sensitive:` on the field masks the whole value exactly as it does today.

**Subfields and dotted `on:` paths** gain one rule and nothing else: a subfield rooted at a map-typed parent is REFUSED at declaration, at any depth and in either declaration order. It is `_reject_map_beside_shape!` in a second spelling — a subfield names one of the hash's own keys exactly as a `shape:` member does — and it carries the same "not supported yet" wording, so PRO-3166 granting the combination contradicts nothing shipped. Without it the emitted schema is looser than the runtime: `additionalProperties` applies only to keys `properties` does not match, so the document calls valid exactly the payload the contract rejects. The check (`SubfieldContradictions.check_subfields_under_map!`) is asked from every seam a map can be declared at — the subfield seam, the ambient seam, and top-level `expects`, which commits its configs on its own path and would otherwise let a map written last escape entirely.

**The declaration walk** (`MAX_NESTING`, `MAX_MEMBER_PATHS`, the snapshot/copy discipline) is unchanged, because nothing in this change makes `of:` descend. That is precisely the work PRO-3166 buys, and keeping it out is what makes this change small.

## Testing

Failure-grid coverage comes first: every row of both tables above gets a case, in `spec/axn/core/validations/validators/of_validator_spec.rb` (runtime) and `spec/axn/core/validations/shape_contracts_spec.rb` (declaration), matching where the existing `of:` rejections already live.

Schema emission is asserted in the reflection specs against the full emitted Hash, including the `Data`-valued case, which is the one that proves `each_emitted_node` sees through the new rung. A collision and a cap case exercise it through the rules rather than only through the emitter.

Specs live under `spec/` (non-Rails), since none of this touches ActiveRecord or Rails.

Error-message assertions build expected strings explicitly and never interpolate `Hash#inspect`, whose formatting differs across the supported Ruby matrix.

## Out of scope

**Tuples.** The array form means union, `shape:` already covers positional-with-worse-names, and the emission is draft-dependent — `prefixItems` in 2020-12 versus `items: [a, b]` in draft-07 — so a client on the wrong draft silently reads a tuple as "every element matches the first type".

**Nested contracts inside `keys:`/`values:`**, per-axis `message:`, `of:` together with `shape:` on a Hash, and the `shape:`-on-Array redundancy this grammar creates: all PRO-3166.
