# The `of:` bag takes value validators

PRO-3193. Blocked by PRO-3222 (`NilClass` reflects as `"string"`) and PRO-3223 (`format:`/`numericality:` reflect nowhere), both of which land first.

## Why

`of:` names what is inside a container — an Array's element, a map's `keys:`/`values:` axis, and since PRO-3166 any of those recursively. The bag carries `klass:` / `of:` / `shape:` / `message:` plus the shared ActiveModel options; every validator key is refused as unknown (`_reject_unknown_of_keys!`). So "every element is a two-letter country code" and "every map value is positive" are unsayable.

PRO-3192 settled the positional rule — *a validator constrains the value at the position it is declared at* — and in doing so made `of:` the documented remedy for constraints it now refuses at the field level. Five shipped statements point at a door that is locked: the two refusal messages in `contract.rb` (`:3233`, `:3312`, both reading "a per-element spelling inside `of:` is not supported yet (PRO-3193)"), the `docs/reference/class.md` paragraph ("until that bag accepts value validators, a `validate: ->(value) { ... }` callable expresses it"), the `AGENTS.md` doctrine bullet, the `[BREAKING]` CHANGELOG entry, and the constant comment at `validation/base.rb:22-29`. Declining would mean retracting all five and leaving `validate:` — which emits nothing and reflects nowhere — as the only spelling.

So the decision is yes. What is designed here is the whitelist, the emission mapping, and the two residues PRO-3166 left behind.

## The whitelist is derived, not listed

A bag describes one unnamed position. The question is not "which validators do we like" but "which validators can read what a position offers", and a position offers a *value* and nothing else — no name, no sibling readers, no record.

```
POSITIONAL_VALIDATOR_KEYS = KNOWN_VALIDATION_KEYS - NEEDS_A_NAMED_SLOT - <bag grammar keys>
```

`NEEDS_A_NAMED_SLOT` is the subtraction, one stated reason per member:

| key | what it reads that a position has not got |
| -- | -- |
| `type:` | nothing — the bag already spells this `klass:`, and two spellings for one thing is what PRO-3191 just retired for `shape:` |
| `model:` | a `<field>_id` reader to resolve against |
| `confirmation:` | a sibling `<field>_confirmation` reader |
| `uniqueness:` | a record and a relation. PRO-3219 owns its disposal at every position; the bag inherits whatever lands there rather than deciding it here |
| `coerce:` | nothing — but it is a *transform*, not a constraint: per-position coercion changes the value the action reads, and where the coerced element lives has to settle against PRO-2903's read-path doctrine first. Out of scope, own ticket. |
| `on:` | a validation context, which axn has not got at any position (already refused, with its own message) |

Everything left is admitted: `presence:` `absence:` `format:` `inclusion:` `exclusion:` `length:` `numericality:` `comparison:` `acceptance:` `validate:`.

Admitted is not the end of the check. Each one is then held to **PRO-3192's own two guards**, with `klass:` playing the role `type:` plays at the top level — which it already does everywhere else in the bag grammar (`_inner_of_container!`). So `of: { klass: Array, format: … }` is refused by the same `_reject_container_position_validators!` that refuses `type: Array, format: …`, and `of: { klass: String, inclusion: { in: [1, 2] } }` by the same `_reject_unsatisfiable_value_constraints!`. One rule, four positions, no second table to keep in sync.

## Positional tolerance

Three cases hide under "nil elements", and only one is spellable today.

**Case 1, nil elements with no other validator, is already spellable.** `of: { klass: [String, NilClass] }` works: `["a", nil]` passes, `[1]` fails `element at index 0 is not one of String, NilClass`. `Base.type_klass_admits_nil?(NilClass)` is already `true`, so the nil-tolerance judgment reads it correctly. Only the emission is wrong, and PRO-3222 fixes that.

**Case 2, nil elements alongside another validator, is unspellable by any allow-list.** A union widens only the type check. ActiveModel runs every other validator on `nil` regardless — measured on bare AM with no flags: `format:` reports "is invalid", `length: { minimum: 2 }` reports "is too short", `inclusion: { in: ["AB"] }` reports "not included", `numericality:` reports "is not a number". So `of: { klass: [String, NilClass], format: … }` would declare cleanly and reject every nil element, the union saying nil is legal here and `format:` saying it is not.

**Case 3, blank elements, is worse.** `""` *is* a String, so no type token reaches it, and `inclusion:` can list `nil` but cannot express "any two-letter code **or** blank". Only `allow_blank: true` gets it.

The obstacle is that today's bag `allow_nil:`/`allow_blank:` are a *whole-field* fact that axn itself writes: `expects :f, type: Array, of: Integer` — nothing optional — stores `validations[:of] == {klass: Integer, container: Array, allow_nil: true}`. A hand-written one is meanwhile inert at both levels (`f: nil` still fails `is not a Array`; `f: [nil]` still fails `element at index 0 is not a String`). So the key currently carries a field-level fact and delivers nothing.

**Deferred to PRO-3225, after measurement.** The intended resolution was to stop the push writing into the bag and let the key mean the position. What the measurement found is that the pushed copies are the **only** record of a field's tolerance: `optional: true` is axn sugar, converted at declaration into the `allow_blank:`/`allow_nil:` pair and then distributed into every validator entry, with nothing kept at the top level. `Base.nil_accepted?` — which requires every entry to be nil-tolerant, and which requiredness and nullability both turn on — therefore reads a field's tolerance off its entries. Exempting `:of` from the push alone moves eight examples, including `spec/downstream_contracts/axn_mcp_interface_spec.rb`'s "optional? still works on a field with of: present", which is a published downstream contract, plus three schema-nullability cases and the PRO-3166 example that pinned this very mechanism.

So closing this residue means reworking how a field's tolerance is recorded, not how a bag is read — a change to the judgment every field's requiredness turns on, with a downstream contract riding on it. That is a different piece of work from widening the bag, and it is decided together with `if:`/`unless:`/`strict:` (below) rather than piecemeal. PRO-3225 carries the four candidate designs and the measurements.

One thing the measurement settled and is worth keeping: `OfValidator#validate_each`'s own field-level nil-skip is **not** load-bearing — removing it leaves the suite green, because `validate_elements`/`validate_entries` both `return unless value.is_a?(…)` and no-op on a nil field anyway. The obstacle is `nil_accepted?`, not that line.

`if:`/`unless:`/`strict:` are **left exactly as they are**, for the same reason. Refusing them at every bag position was the intended design — their element-position meaning is "gate the whole field's `of:` check", a field-level fact wearing a positional key — but refusing is breaking for a spelling PRO-3166 shipped days earlier, and doing it here would remove a capability without delivering positional tolerance in exchange. Both decisions land together in PRO-3225.

## The failure grid

Every admitted validator against every position, with the runtime meaning and the emitted keyword decided explicitly. Positions: **F** the field's own value (PRO-3192's, the control — unchanged by this work); **E** an Array's element bag; **V** a map's `values:` axis; **K** a map's `keys:` axis. A nested bag at depth ≥ 2 is an E, V or K by construction and adds no row.

| validator | meaning at a position | E emits (`items`) | V emits (`additionalProperties`) | K emits (`propertyNames`) |
| -- | -- | -- | -- | -- |
| `inclusion:` | the value is a member of the set | `enum` | `enum` | `enum`, members rendered to their wire form |
| `exclusion:` | the value is not a member | nothing | nothing | nothing |
| `format:` | the value matches | `pattern` | `pattern` | `pattern` |
| `length:` | the value's own size | `minLength`/`maxLength` or `minItems`/`maxItems` per `klass:` | same | `minLength`/`maxLength` |
| `numericality:` | numeric bounds on the value | `minimum`/`maximum`/`exclusiveMinimum`/`exclusiveMaximum` | same | nothing |
| `comparison:` | ordering bounds, judged by literal per PRO-3192 | the numeric family when the bounds are numeric literals | same | nothing |
| `presence:` | the value is not blank | `minLength: 1` for a string-typed position | same | `minLength: 1` |
| `absence:` | the value is blank | nothing | nothing | nothing |
| `acceptance:` | the value is in the accept set | nothing | nothing | nothing |
| `validate:` | the callable's verdict | nothing | nothing | nothing |
| `allow_nil:` / `allow_blank:` | **unchanged — a whole-field fact, not positional** (PRO-3225) | nothing | nothing | nothing |

Four of those cells need their reason on the record.

**`exclusion:` emits nothing** because `not: { enum: [...] }` is the honest spelling and PRO-3192 booked it as debt rather than shipping it. Widening the bag does not change that trade, so the bag inherits the same unemitted-and-documented status the field has. Looser than the runtime, deliberately, and already the documented state at F.

**`absence:` and `acceptance:` emit nothing** because neither has an honest keyword. `absence:` wants `maxItems: 0` / `const: null` depending on the position's type and collides with the emptiness floor — which is PRO-3220's whole subject, so it is left to that ticket rather than half-answered here.

**`numericality:` and `comparison:` emit nothing at K, and are still enforced there.** A Ruby Hash key may legitimately be an Integer (`{1 => "a"}`), so `of: { keys: { klass: Integer, numericality: { greater_than: 0 } } }` is a real contract; but a JSON object key is always a string, so no `propertyNames` subschema expresses "parses to an integer greater than zero". This is PRO-3165's existing call for `keys: Symbol` — enforced in Ruby, invisible on the wire — now stated per validator rather than per axis. The general rule for K: **a keys-axis validator is emitted only when its constraint survives the string form of a JSON key.** `format:`, `length:`, `presence:` and a string-renderable `inclusion:` do; numeric bounds and `allow_nil:` (JSON has no null key) do not.

Surviving the string form has a second half on OUTPUT, where the key axn validated and the key axn serializes are two different objects. `format:` and `inclusion:` read the wire form already — ActiveModel matches `#to_s`, and the enum renders through `Values.canonical_wire_key` — so their subject survives by construction. `length:` does not: ActiveModel measures the key object's `#length` while the emitted `minLength`/`maxLength` measure the property name. A class may have both, and a key whose `#length` counts segments serializes to `"a/b"`; the bound then rejects output the action itself produced. So an outbound keys-axis `length:` is emitted only for a class whose `#length` IS its own name's length — String and Symbol — and withheld for every other token, an absent `klass:` included, since the keys may then be anything. Inbound needs no such gate: there the key is the string it was sent as, and the axis class gate has already turned away any axis a JSON key could not satisfy at all.

**The tolerance row is a placeholder for PRO-3225.** Until that lands, a bag's `allow_nil:`/`allow_blank:` keep the whole-field meaning axn's own push gives them and are not forwarded to the position at all — `OfValidator#inner_contract_validations` takes the bag through `Validation::Base.validator_entries`, which is where "the shared options are not validators" is already expressed, so the question cannot be answered here by accident.

### Cells refused at declaration

| declaration | refused by |
| -- | -- |
| `of: { klass: Array, format: … }`, `of: { klass: Hash, numericality: … }` | `_reject_container_position_validators!`, unchanged, reached with `klass:` as the declared type |
| `of: { klass: String, inclusion: { in: [1, 2] } }` and every unsatisfiable-set spelling | `_reject_unsatisfiable_value_constraints!`, unchanged, same adaptation |
| `of: { klass: String, if: -> { … } }` at an axis | `AXIS_INERT_OPTION_KEYS`, unchanged — at an element position it is still admitted and still gates the whole field's check (PRO-3225) |
| `of: { klass: String, model: … }`, `confirmation:`, `coerce:`, `type:` | the derived whitelist, each with its own reason |
| `of: { keys: { klass: String, format: … } }` beside a `shape:` whose member name fails that format | nothing — it is legal, and the emission handles it (below) |

## Emission: one projector, four positions

`build_property` today applies validator-derived keywords in two places — the `enum` block and `apply_size_constraints!` — and `contents_node_schema` applies none. Rather than mirror them, both fold into one `apply_value_constraints!(node, validations, type_hint)` that `build_property`, `contents_node_schema` and the new keys-axis path all call. PRO-3223 builds that projector and adds the `pattern`/numeric-bound rows to it; this change adds the callers a rung down.

`keys:` gains `propertyNames`, which is where it earns its place. A bare `keys: String` or `keys: Symbol` still emits nothing — PRO-3165's reasoning holds, since every JSON object key is already a string and `keys: Symbol` would be a lie on the wire. Only a keys axis carrying a constraint emits, and only the constraints from the K column above.

One asymmetry has to be handled rather than inherited. PRO-3166 exempts a `shape:`-named key from **both** map axes, while JSON Schema's `propertyNames` applies to **every** key, `properties`-matched ones included. So a map carrying both a constrained `keys:` axis and a `shape:` would emit `required: ["label"]` beside `propertyNames: { pattern: … }` — unsatisfiable whenever the member name fails the pattern, which is exactly the corollary PRO-3192 added to `guards-and-projections.md`. The exact spelling is a union of the two things the runtime actually accepts:

```
propertyNames: { anyOf: [ <the keys-axis constraint>, { enum: <the shape's member key names> } ] }
```

which reads as "a key is either one the shape names, or one the axis admits" — the runtime rule, verbatim. Where the map has no shaped keys, the plain `propertyNames: { … }` stands.

Inclusion members on the K axis render through `Internal::Reflection::Values`, so `of: { keys: { klass: Symbol, inclusion: { in: [:a, :b] } } }` emits `propertyNames: { enum: ["a", "b"] }` rather than publishing Symbols the wire has no form for.

## Runtime

The machinery already exists and is one method away from the feature. `Axn::Validation::ContainerContents < Fields` is the positional adaptation of the validator harness (`read_attribute_for_validation(_attr) = @source`), and `OfValidator#position_contract` already builds a one-off validator class per position via `ContainerContents.validator_class_for(field: :__axn_contents__, validations: contents)` and runs it through `Fields.errors_for`. Axn's non-distributing `InclusionValidator`/`ExclusionValidator` are inherited by that one-off class for free, so the positional reading of a set holds at a bag position without a second shadowing.

What changes:

- `inner_contract_validations` returns the bag **minus** the bag's own grammar keys (`klass`, `message`, `container`, `shaped_keys`, `keys`, `values`) instead of picking out `:of` and `:shape`. Derived by subtraction, so a newly-admitted key cannot be silently dropped — that is the exact silent-ignore hole PRO-3165 closed, and a whitelisted-but-unforwarded key would reopen it.
- `position_contract`'s `contents_node` is `bag[:of] || bag[:shape]`, nil for a validator-only bag, which contradicts its own comment that it is "never nil when `contents` is set". `guard_contents_descent` gains a no-child case: run the validator set, charge no depth, take no cycle guard, because there is nothing to recurse into.
- `_reject_unconstraining_of_bag!` and `INNER_CONTRACT_AXES` widen — a bag carrying only a `format:` now constrains something, and the "must constrain something" message names the new options.
- Error classification is unchanged. A positional error carries no `axn_shape_member` tag, so `Executor#_own_errors` treats it as the field's own error and it inherits the field's `user_facing:` — today's behaviour for a type mismatch at a position, and per-position `user_facing:` is out of scope.

## Out of scope, recorded

Per-position `coerce:`/`preprocess:`/`default:`/`sensitive:` (transforms, not constraints — own ticket). `exclusion:` emission (PRO-3192's booked debt). `uniqueness:` disposal (PRO-3219). The unsatisfiable-node refusals, including `absence:` against the emptiness floor (PRO-3220). Per-position `user_facing:` classification. Tuples (PRO-3165).

## Verification

The runtime/schema agreement *is* the feature, so the grid above is pinned as an executable matrix rather than prose: for each admitted validator at each of E, V and K, assert the runtime verdict and the emitted node **on the same value**, in the style of `container_position_validators_spec.rb`'s "agrees with the emitted enum on the same value". The cells that emit nothing are asserted as absences, so a later change cannot quietly start emitting them.

Beyond the matrix: A/B every guard change against the prior commit per `internal-docs/agent-notes/ab-testing-guards.md`, since an example failing in both trees is a broken fixture rather than a finding. Mutation-audit each widened guard, and inverse-mutate the controls — over-rejection is the failure mode when a whitelist widens, and plain mutation cannot see it. Mutation-check the `OfValidator#validate_each` nil-skip specifically before relying on the tolerance unwind. Assert the shaped-keys `propertyNames` node is satisfiable by constructing the adversarial case: a member name that fails the axis constraint must still be accepted at runtime and validate against the emitted document.
