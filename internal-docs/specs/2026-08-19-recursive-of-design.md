# Recursive `of:` — containers inside containers

Ticket: https://linear.app/teamshares/issue/PRO-3166/axn-recursive-of-containers-inside-containers

Predecessor: https://linear.app/teamshares/issue/PRO-3165/axn-hash-maps-via-of-and-close-the-nested-of-silent-ignore-hole (`internal-docs/specs/2026-08-18-hash-maps-via-of-design.md`)

Split off from this change, in the order they should be read:

* https://linear.app/teamshares/issue/PRO-3191/axn-retire-the-distributing-shape-on-type-array — the `[BREAKING]` removal of the flat spelling this change canonicalizes away.
* https://linear.app/teamshares/issue/PRO-3192/axn-validators-on-a-container-typed-field-runtime-and-schema-disagree — a pre-existing cluster found while scoping this, not caused by it.
* https://linear.app/teamshares/issue/PRO-3193/axn-should-an-of-bag-take-the-full-validator-set — where the two residues this change knowingly leaves are booked.

## Problem

`shape:` recurses through **named** members; `of:` does not recurse at all. Every remaining gap in the declaration grammar is the same gap — a container sitting directly inside a container, with no member name to hang the next level on. Probed against `main` at b57eced0 (ruby 3.3.6, activemodel 8.1.3.1):

| Declaration | Today |
| -- | -- |
| `type: Array, of: Hash` + a block | ✅ validates per element, emits `items.properties` |
| a shape member that is itself `type: Array, of: Hash` + a block | ✅ recurses all the way down |
| `of: { klass: Array, of: Integer }` | ❌ `ArgumentError: of: does not support of:` |
| `of: { values: { klass: Hash, shape: … } }` | ❌ `ArgumentError: of: values: takes a type, not a nested contract — that is not supported yet` |
| `type: Hash, of: { values: … }, shape: …` | ❌ `ArgumentError: of: beside shape: on a Hash is not supported yet` |

The last two are the ones that matter for tool schemas: a map of shaped records — `{"acme" => {name:, tier:}}` — is a realistic thing to want in an MCP tool's `inputSchema`, and it is unspellable, because `shape:` on a `type: Hash` field already means "the hash's own named members" and that slot is taken.

Two claims in the ticket needed correcting before designing against them.

The 25,000-property cap is **not** free. Collisions are derived from the emitted schema (`each_emitted_node`, `property_names.rb:347`, which does walk `items`/`additionalProperties`/`anyOf` generically), but the cap is a **declaration** walk — `count_emitted_properties!` (`property_names.rb:949`) descends `plan.shape`'s members and nothing else. A recursive graph would charge zero.

The ticket's `keys:` example (`type: Hash, keys: String, of: {…}`) predates the grammar PRO-3165 actually shipped. Axes live inside the `of:` bag, so a map of shaped records is spelled `of: { values: { klass: …, shape: … } }`.

One thing is cheaper than the ticket feared: subfields never descend through an Array (`expects :sku, on: <Array parent>` is refused as unresolvable — "segment `:sku` is read from `:items`, declared Array, which cannot answer it"). So `SubfieldTree` / `ResolvedSubfields` are untouched by an Array's inner contract, and the descent seams to change are four, not five.

## Grammar: one bag, three positions

The **inner-contract bag** carries `klass:` / `of:` / `shape:` / `message:` plus the shared ActiveModel options, and it appears in three positions: an Array's element, a map's `keys:` axis, and a map's `values:` axis. Within a bag, `klass:` plays the role `type:` plays at the top level — it names the value's class, and it decides which grammar *that* bag's own `of:` is held to. That symmetry is what makes the recursion one function rather than two.

```ruby
expects :matrix,    type: Array, of: { klass: Array, of: Integer }
expects :by_region, type: Hash,  of: { values: { klass: Array, of: { klass: Hash, shape: { members: [...] } } } }
expects :counts,    type: Hash,  of: { keys: Symbol, values: { klass: Integer, message: "must be a whole number" } }
```

`of:` under an **Array** container takes an inner-contract bag (or a bare type, which is sugar for `{ klass: <type> }`, unchanged). `of:` under a **Hash** container takes the axis bag `{ keys:, values: }`, each axis holding an inner-contract bag or a bare type. The axis bag is not itself an inner-contract bag, and never was; that distinction is PRO-3165's and is unchanged.

An Array anywhere in this grammar still means a **union**, never a pair and never a tuple.

## Canonical storage

The stored contract loses the distributing `shape:` entirely. An `of:` bag becomes the sole home of a container's contents, at every depth. Probed before-states are exact; after-states are the target.

| Declaration | Stored today | Stored after |
| -- | -- | -- |
| `type: Array, of: Hash` + block | `of: {klass: Hash, container: Array}` **and** `shape: {container: Array, members: …}` | `of: {klass: Hash, container: Array, shape: {container: Hash, members: …}}` |
| `type: Array` + block, no `of:` | `of: nil` **and** `shape: {container: Array, members: …}` | `of: {container: Array, shape: {container: ANY_CONTAINER, members: …}}` |
| `type: Hash` + block | `shape: {container: Hash, members: …}` | unchanged |
| `type: SomeData` + block | `shape: {container: SomeData, members: …}` | unchanged |
| `type: Hash, of: {values: Integer}` | `of: {values: Integer, container: Hash}` | unchanged |

Row 1 carries the semantic move this whole change is for: the shape's `container:` goes from `Array` — meaning "distribute over the elements" — to `Hash`, meaning "read members off this element". The distribution becomes the `of:` bag's job, and `shape:` stops having a second meaning. Row 2 is the same move where there is no element class to name.

Canonicalizing **forward** (into the nested form) rather than backward is deliberate. Backward canonicalization would leave every existing consumer untouched, but only at depth 1: a bag two levels down has no flat spelling to canonicalize into, so consumers would have to learn the nested form anyway and the graph would carry two contract shapes permanently. Forward costs the Array branch of four descent seams in this change and leaves one shape, which is also what reduces PRO-3191 to a surface-only change.

### Two relaxations this forces

**A bag need not supply `klass:`.** Row 2 above produces a bag that constrains via `shape:` alone. The rule becomes: a bag must constrain **something** — at least one of `klass:`, `of:`, `shape:`. `of: {}` and `of: { message: "…" }` still raise on the existing "constrains nothing" rule, which is the rule the whole option exists to enforce. A bag carrying `of:` but no `klass:` raises separately and for a different reason: with no container named there is no way to tell the Array grammar from the Hash grammar, which is the same refusal a union `klass:` already gets.

**A shape needs an explicit "no container gate" marker.** Row 2's shape has no class to gate on, and `ShapeValidator`'s non-Array branch does `value.is_a?(options[:container])`, which raises `TypeError` on `nil`. Absence of `container:` already means something: it is the bug signature `_derive_raw_shape_container!` exists to catch — a hand-written nested `shape:` that never got derived, failing every call with a bare `TypeError: class or module required` that names neither the member nor the option. So the marker is an explicit sentinel, `Internal::ShapeGraph::ANY_CONTAINER`, rather than an overloaded `nil`: derived means derived, the sentinel means deliberately unconstrained, and absent still means the bug.

## Declaration-time rules

`shared` below is `Axn::Validation::Base.shared_validation_option_keys`. Rows marked *unchanged* are PRO-3165's and are restated only so the grid is complete.

An **Array**'s `of:`:

| Declaration | Outcome |
| -- | -- |
| `of: String` | unchanged — sugar for `{ klass: String }` |
| `of: [String, Numeric]` | unchanged — union |
| `of: { klass: String, message: "…" }` | unchanged |
| `of: { klass: String, shape: {…} }` | unchanged — a scalar element with members read off it; validated, never emitted as properties |
| `of: { klass: Array, of: Integer }` | **new** |
| `of: { klass: Hash, of: { values: Integer } }` | **new** — an element that is itself a map |
| `of: { klass: Hash, shape: {…} }` | **new** — what `type: Array, of: Hash` + a block canonicalizes to |
| `of: { shape: {…} }` | **new** — element class unconstrained; what `type: Array` + a block canonicalizes to |
| `of: { of: Integer }` | **raise** — names no container, so its `of:` has no grammar |
| `of: { klass: String, of: Integer }` | **raise** — a String has nothing inside it |
| `of: { klass: [Array, Hash], of: … }` | **raise** — a union names no single container |
| `of: {}`, `of: { message: "…" }` | **raise** — constrains nothing |
| `of: { values: String }` | **raise** — unchanged; `of:` names an Array's elements, use `klass:` |
| `of: { klass: String, mesage: "…" }` | **raise** — unchanged; unknown key |

A **Hash**'s `of:`:

| Declaration | Outcome |
| -- | -- |
| `of: { values: Integer }`, `of: { keys: Symbol, values: Integer }` | unchanged |
| `of: { values: { klass: Hash, shape: {…} } }` | **new** — a map of shaped records |
| `of: { values: { klass: Integer, message: "…" } }` | **new** — per-axis message |
| `of: { keys: { klass: String } }` | **new** — validated in Ruby, emits nothing (see *Residues*) |
| `of: Integer` | **raise** — unchanged; the bare form is Array-only |
| `of: { klass: Integer }` | **raise** — unchanged; points at `values:` |
| `of: {}`, `of: { values: [] }` | **raise** — unchanged |
| `of: { values: Integer, message: "…" }` | **raise** — unchanged; one message cannot say which axis failed |
| `type: Hash, of: { values: … }, shape: {…}` | **now legal** — see *The Hash exemption* |
| `type: [Array, Hash], of: …` | **raise** — unchanged |
| a subfield (`on:`) rooted at a map, any depth | **raise** — unchanged, deliberately (see *Scope*) |

## The Hash exemption

A Hash is the only container where `shape:` and `of:` name **different nodes**: `shape:` names specific keys, `of:` names what is left. Everywhere else they describe the same node from two angles — on an Array, `of:` gives the element's class and `shape:` gives that same element's members, one node with nothing to partition; on a `Data`/`Struct`/plain class, `of:` is refused outright, so the pair cannot arise.

Where they do meet, JSON Schema settles it: `additionalProperties` applies only to keys `properties` does not match. So a key named by `shape:` is **exempt** from the map contract, and the runtime mirrors that exactly.

```ruby
expects :metrics, type: Hash, of: { values: Integer } do
  field :label, type: String
end

# { label: "q3", visits: 120, signups: 4 }  ✅
# { label: "q3", visits: "lots" }           ❌  value at index 1 is not a Integer
# { visits: 120 }                           ❌  label could not be read
```

```ruby
# input_schema
{ type: "object",
  properties: { label: { type: "string", minLength: 1 } },
  required: ["label"],
  additionalProperties: { type: "integer" },
  minProperties: 1 }
```

The alternative reading — `of:` governs every value and `shape:` adds to the named ones — was rejected on two grounds. It makes the common case unsatisfiable: the example above would require `label` to be both a String and an Integer, and the whole reason to combine the two options is that the named keys differ in type from the rest. And it has no honest JSON Schema spelling, so the emitted document would be looser than the contract — the exact divergence PRO-3165 added `check_subfields_under_map!` to prevent. Exempt costs one restated `type:` in the narrower case where a named key wants extra constraints on top of the blanket type, and expresses both cases; intersect saves that word and expresses one.

The exemption covers **both axes**, `keys:` as well as `values:`. JSON Schema is asymmetric here — `propertyNames` applies to every key including matched ones — but `keys:` emits nothing (PRO-3165: every JSON object key is already a string), so there is no document to contradict, and the symmetric rule avoids `field :label` quietly acquiring a symbol-key requirement it never asked for.

The exempt key set is **derived** into the `of:` bag at declaration alongside `container:`, from `member_properties`' own key computation rather than re-derived beside it, so the runtime skips exactly the keys the schema emits as `properties`. It therefore needs the same drop-and-re-derive handling `container:` gets (`_drop_derived_of_container!`), because that seam runs over a shape member's bag twice.

One edge to pin explicitly: the emitter canonicalizes member names with `to_sym`, but a runtime Hash may arrive string-keyed. `{"label" => "q3"}` has to be recognized as the exempt key exactly as `{label: "q3"}` is, or the exemption silently stops applying for string-keyed payloads — the common shape for JSON input. The comparison matches how `FieldResolvers.extract_or_nil` reads a member, not a bare Symbol equality.

## Runtime validation

An inner-contract bag maps to a validations bag — `{klass: X, of: Y, shape: Z}` becomes `{type: {klass: X}, of: Y, shape: Z}` — which `Validation::Fields.validator_class_for` compiles exactly as it compiles a shape member's. `TypeValidator`, a recursive `OfValidator` and `ShapeValidator` all follow, at every depth, with the existing gate and ancestry threading intact.

The one seam that does not already exist: `Validation::Fields#read_attribute_for_validation` extracts a **named** attribute from its source, and an unnamed position needs to validate the value itself. That is a small subclass whose read answers the source, not a parallel pipeline. ActiveModel's `error.message` excludes the attribute name, so the synthetic name never surfaces.

`OfValidator#check_validity!` currently raises `must supply :klass` for any non-map bag. It follows the relaxation above: a bag is valid when it constrains something, so `klass:` is required only when neither `of:` nor `shape:` is present. That check is the runtime's last line rather than the author-facing one — the declaration grid is what an author meets — but leaving it as-is would make row 2 of the canonicalization table raise on every call.

`OfValidator` deliberately keeps performing the `klass:` check itself rather than delegating it, because the two existing message shapes differ in punctuation and both must stay byte-identical:

| Situation | Message | Status |
| -- | -- | -- |
| element type | `element at index 0 is not a String` | unchanged — no colon, `OfValidator`'s own |
| element member | `element at index 0: sku is not a String` | unchanged — colon, delegated |
| map key / value type | `key at index 0 is not a Symbol` | unchanged |
| nested container | `element at index 0: element at index 2 is not a Integer` | new, composes |
| map value's members | `value at index 0: sku is not a String` | new, composes |

Map errors continue to locate a failing entry by **ordinal, never by key**, at every depth. A validation message is settled unredacted — it reaches `result.exception.message` and the logged INFO line without passing through `contract/redaction.rb` — so rendering a key would publish exactly what a `sensitive:` declaration asks to be masked. Recursion multiplies the positions where that would happen, and none of them renders a key.

Coercion is unaffected, as it was in PRO-3165: `coerce:` operates on the field's own value and has never descended into a container's contents.

## Schema reflection

`contents_schema_for` currently takes `of[:klass]` and returns a type schema. It becomes a **nameless-node builder** taking the whole bag: the type schema, plus `properties` from `shape:`, plus `items:` or `additionalProperties:` from a nested `of:`. That is precisely what `apply_structured_schema!` does at a field, so the two share it — the emitter and every rule derived from the emitter then charge the same nodes, which is what "a guard derives from what its consumer emits" requires here.

```ruby
expects :matrix, type: Array, of: { klass: Array, of: Integer }
#=> { type: "array", items: { type: "array", items: { type: "integer" } } }

expects :by_region, type: Hash, of: { values: { klass: Hash, shape: { members: [...] } } }
#=> { type: "object", additionalProperties: { type: "object", properties: { sku: {...} }, required: ["sku"] } }
```

Unions keep their per-branch `anyOf` and nest inside each branch, unchanged. `apply_structured_schema!`'s branches are currently mutually exclusive (`map?` / `in_items?` / `shape`); `map?` and `shape` now combine, emitting `properties` and `additionalProperties` at one node.

`each_emitted_node` needs nothing: it already walks `items`, `additionalProperties` and `anyOf` generically, which is why the collision rules and the emitted-property renderers come free. `count_emitted_properties!` does need the new edge — it descends declarations, not the emitted schema, so it charges the `of:` rung under `ITEMS_SEGMENT` / `VALUES_SEGMENT` the way it already charges a member under its name.

`property_sources_for` gains attribution through an unnamed rung, so a collision found inside `items.items` can say where it is rather than reporting a path it cannot name.

## The declaration walk

Today `shape:` is snapshotted in `expects` (`contract.rb:541`) and `of:` is canonicalized later, in `_parse_field_validations` (`contract.rb:~2170`). Two passes are fine while the two edges never interleave. With recursion they do — an `of:` bag holds shapes, and those shapes' members hold `of:` bags — and two passes over one caller-supplied graph means reading caller data twice, which is the inconsistent-reader hazard the walk is built to avoid, and computing the cycle, depth and size bounds per pass rather than over the whole graph.

So it becomes one fused walk over the contract graph, on the terms `_walk_shape_graph!` already sets for its single edge type: nodes are a validations bag (a field's or a member's) and an `of:` bag; edges are `shape:` to named members and `of:` to the unnamed rung — `[]` for an element, one per axis for a map. It canonicalizes, checks, counts and copies in a single pass, because a check pass followed by a copy pass would have to agree about what the graph *is*.

**Sequencing is the main implementation risk.** The shape snapshot currently happens strictly before `of:` canonicalization, and fusing them moves that boundary; anything between the two that reads `validations[:shape]` or `validations[:of]` has to be re-checked. Pin the current order with a characterisation test before touching it.

PRO-3165's property that this seam runs over a shape member's bag **twice** — once as the member is built like a field, once as the walk snapshots it, with the tolerance push rewriting the bag in between — has to survive. The new derived key (the exempt set) needs the same drop-and-re-derive treatment `container:` gets, or the second pass reports axn's own key as unsupported and fails a well-formed declaration.

### Bounds

One budget per hazard, not one per edge type.

| Guard | Rule |
| -- | -- |
| `MAX_NESTING` | one depth counter across both edges — an `of:` rung is a level. Two counters would admit a graph 64 `of:` deep by 64 `shape:` deep. |
| `MAX_MEMBER_PATHS` | an `of:` rung charges 1, as a member does. A bag shared between siblings multiplies 2^N exactly as a shared shape does, so the `walked` memo, the re-judge-per-reference rule and the `height` travelling with the copy all carry over unchanged. |
| `CycleGuard` | `h[:of] = h` is the new cycle, guarded on bag identity in the same `seen` / `walked` structures. `ShapeValidator`'s runtime `guard_pair` needs a sibling for `OfValidator`'s recursion, keyed on the (value, bag) pair for the reason the shape walk keys on (value, members). |
| copy discipline | an `of:` bag is caller-supplied and is copied on `shape:`'s terms, `reject_defaulting_option_container!` included. Recursion multiplies the bound-read sites (`ShapeGraph.hash_or_nil`, `carries_key?`) PRO-3165 introduced; every new read of a caller bag uses them. |

## Consumers: the four seams

Each gets one new branch, and all four call one shared child-enumerator so that "what is inside this node" has exactly one answer.

**The declaration walk**, as above. The bulk of the work, and it sits in the most invariant-dense code in the repo.

**Redaction** (`contract/redaction.rb`). `_mask_shape_value` dispatches on `shape[:container]`, which no longer carries `Array` for row 1 — the distribution moves to the `of:` bag. `_mask_shape_element` is reused for "every element" and gains "every map value" rather than being reinvented. The sensitive-name collectors (`_flatten_sensitive_candidates`, `_derive_sensitive_member_names`) descend the new edge. A map's values have no member name, so a sensitive member inside one falls to the existing safe-over-precise doctrine (`_mask_unfilterable_shape_value`) exactly as an object-backed shape does today.

**Ambient context** (`core/ambient_context.rb:120,150`). `_each_shape_member` descends `nested_shape(member)`; it descends the new edge too.

**Reflection** (`internal/reflection/`). The nameless-node builder, the cap's new rung, and collision attribution through an unnamed rung.

## Scope

**PRO-3165's refusal of a subfield rooted at a map stays.** Granting `shape:` beside `of:` makes relaxing it tempting — a subfield's key becomes a `properties` key, so the exemption covers it and the original hazard dissolves. It is not taken here, because the exempt set would then have to be derived from everything the emitter puts in `properties` at that node (subfield leaves, the nested keys a dotted `on:` introduces, `model:`'s generated `<field>_id`), none of which is knowable from the shape at declaration where the set is derived. Keeping the refusal keeps the exempt set equal to the shape's member keys. PRO-3165's "not supported yet" wording still stands, so relaxing it later contradicts nothing released.

**The inner bag stays containers-only.** `klass:` / `of:` / `shape:` / `message:` plus the shared options; every other validator remains an unknown key. Widening it is PRO-3193, which is blocked on PRO-3192 because pushing `enum` / `pattern` / `minimum` into `items` while the field-level meaning of those same keywords is undefined would produce two rules for one keyword.

**Retiring the distributing `shape:` is PRO-3191.** This change canonicalizes it away in storage; that one stops accepting the surface spelling, which is breaking.

**Tuples** remain out, on PRO-3165's grounds: the array form means union, and the emission is draft-dependent.

### Residues booked in PRO-3193

**Shared options inside a nested bag are inert.** `of: { klass: String, allow_nil: true }` does not make nil elements legal — `OfValidator#validate_each` consults those options once for the whole field, matching the documented rule at `docs/reference/class.md:184`. That is defensible at depth 1, where the keys are present because axn's own tolerance push injected them, and not defensible at depth 2+, where an author who writes one gets a silently ignored option. Refusing them only in nested bags would make the grammar depth-dependent, which is worse, so they stay uniformly accepted-and-inert and are documented as such.

**A nested bag on the `keys:` axis validates in Ruby and reflects nowhere**, because `keys:` emits nothing. Harmless while an axis can only name a type; a real divergence once an axis can carry a `format:`, which is where `propertyNames` earns its place.

## Testing

The failure grid comes first, in the homes the existing `of:` rules already use: declaration rows in `spec/axn/core/validations/shape_contracts_spec.rb`, runtime rows in `spec/axn/core/validations/validators/of_validator_spec.rb`, emission in `spec/axn/internal/reflection/schema_spec.rb`. Every row of both declaration tables and every row of the message table gets a case.

**Stored-config assertions for all five rows of the canonicalization table.** This is the net that proves the four seams read one shape, and the regression that catches a seam left behind — a consumer still reading `validations[:shape]` for an Array field will fail here rather than silently stop redacting.

**Message parity pinned explicitly.** Canonicalization changes *who produces* the two existing message shapes, so byte-identity needs an assertion rather than an assumption.

**Bounds**: a graph at exactly `MAX_NESTING` declares legally and validates at runtime; one level deeper raises. `h[:of] = h`. A bag shared across siblings at N levels, charged 2^N.

**Mutation-audit the new charges** — remove the `of:` depth charge and the suite must fail — and **inverse-mutate the controls**, introducing an over-eager guard to confirm a legal declaration fails, since over-rejection is the recurring failure mode when a guard is tightened.

**A/B the guard specs against the prior commit** per `internal-docs/agent-notes/ab-testing-guards.md`, using a throwaway worktree rather than a stash. Guards are moving here, so an example failing in both trees is a broken fixture rather than a finding.

**Redaction**: a `sensitive:` member two levels inside `of:`, and a map value that is a shaped Hash carrying a sensitive member.

Everything lives under `spec/` — nothing here touches ActiveRecord or Rails. Error-message assertions build expected strings explicitly and never interpolate `Hash#inspect`, whose formatting differs across the supported Ruby matrix.

## Compatibility

Forward canonicalization changes what `internal_field_configs` holds for an `Array`-typed field with a shape. That is internal structure rather than documented API — what a consuming gem reflects with is `input_schema` / `output_schema` and `Extensions::Serialization.render`, none of which change shape — but a gem reading `config.validations[:shape]` directly would break. Sweep the siblings with `rake downstream:check` before landing, and check os-app, axn-mcp, axn-ruby_llm, data_shifter and slack_sender.

The user-visible surface is otherwise **additive**: every declaration legal today stays legal and validates and reflects identically, and the new grammar occupies spellings that raise today.
