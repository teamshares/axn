# Rejecting declaration-time property-name collisions

**Ticket:** [PRO-2995](https://linear.app/teamshares/issue/PRO-2995/axn-reject-exposure-names-that-canonicalize-to-one-json-property-at)

**Goal:** Make the declared name of a field, subfield, or shape member carry the same UTF-8 property promise at declaration that the serializer already enforces at runtime, so two names that converge on one JSON property — or one name that has no UTF-8 rendering at all — raise when the class is defined rather than during a call, during serialization, or not at all.

## Motivation

`AGENTS.md:61-63` is explicit and names this case: DSL misuse — "bad option combos, reserved names, **collisions**" — `raise`s when the class is *defined*. A declared name becoming a JSON property name is statically knowable, so the check belongs beside the other declaration-time contradiction guards rather than downstream of the business logic.

The guard this sharpens already exists. `_duplicate_fields` (`lib/axn/core/contract.rb:562`) keys field identity on `[c.on.to_s, c.field]` — the raw Symbol. Symbols carry bytes plus an encoding, while a JSON property is text, so two non-`eql?` Symbols can be one property: `:café` in UTF-8 and the same text in ISO-8859-1 are distinct Hash keys and distinct configs, and `Axn::Reflection::Values.canonical_wire_key` (`lib/axn/reflection/values.rb:489`) renders both as `"café"`. This is the same distinction the runtime Hash-key check already draws, for the same reason.

### Verified current behavior

Every row below was run against `898dd0c5`, not inferred:

| Declaration | Today |
| --- | --- |
| `exposes :café` + ISO-8859-1 `:café`, both set | Class defines, call succeeds, `serialize_exposed` raises `UnserializableValue` naming both spellings — after the business logic and any side effects |
| The same two names on `expects` | Class defines, and `JSON.generate(input_schema[:properties])` emits `{"café":{},"café":{}}` — a duplicate JSON property, **silently**, with no raise at any layer |
| `expects` a name whose bytes have no UTF-8 rendering | Class defines; the adapter's `JSON.generate` raises `JSON::GeneratorError: "\xFF" from ASCII-8BIT to UTF-8`, with no path back to the declaration |
| Two shape members whose names collapse | Members build, schema emits `{"café":{"type":"string"},"café":{"type":"integer"}}` |
| Two shape members with the *same* name | Both members build and both validate, and the schema keeps only the last: `{:a=>{:type=>"integer"}}` — the first member's contribution vanishes with no signal |
| Two `on:` routes whose segments collapse | Already rejected, earlier and for its own reason: `on:` must name a declared reader, so the second spelling fails reader lookup |

Two secondary observations from the same run, both consequences of the same root cause and both fixed by rejecting the name at declaration: a mixed-encoding pair of exposure names makes exception *reporting* raise `Encoding::CompatibilityError` inside the `on_exception` hooks, which the executor swallows with `!! IGNORING EXCEPTION RAISED WHILE EXECUTING ON_EXCEPTION HOOKS !!`; and a single non-UTF-8 name reaches outbound validation, which renders its message with the bytes mangled (`Caf� can't be blank`).

The `expects` row is the strongest case in the table and the one the ticket left open. Input field names are not rendered into the response body, which is why the ticket suspected they might not matter — but `Axn::Reflection::Schema` keys `properties[config.field]` by the raw Symbol (`lib/axn/reflection/schema.rb:92`, and nested children at `:767`), so an `expects` name is a property name in the `input_schema` an adapter emits for a tool definition. That path has no runtime defense at all: the exposes case at least raises, while this one ships a JSON object with a repeated key for the consumer to collapse. `expects` is therefore in scope on evidence, not on symmetry.

## Design

One primitive, one identity rule, applied wherever a declared name becomes a property name.

`Axn::Reflection::Values.canonical_wire_key` stays where it is and becomes the single definition of "the JSON property this declared name renders as." Core's declaration path calling a reflection-layer primitive is the established pattern, not a new dependency edge: `contract.rb:1039` already calls `Axn::Reflection::Coercion.coercible_klasses` from a declaration-time check, and four other files under `lib/axn/core/` reach into `Axn::Reflection::*`. `canonical_wire_key` gains exactly the standing `coercible_klasses` has.

### Components

| Unit | Responsibility |
| --- | --- |
| `Values.canonical_wire_key` | Unchanged. The property a name renders as, or `nil` when its bytes have no UTF-8 rendering. |
| `_reject_unrenderable_field_names!(names, kind:)` | New, private in `Core::Contract`. Raises `ArgumentError` for a name `canonical_wire_key` cannot render. |
| `_duplicate_fields(existing, new_configs)` | Modified. Keys identity on `[c.on.to_s, canonical_wire_key(c.field)]`; returns `[claimed_field, offending_field]` pairs instead of bare names. Keeps comparing against `existing` **and** within `new_configs` itself, since `exposes :café, <iso-8859-1 café>` is one batch and its collision is intra-batch. |
| `_reject_duplicate_fields!(existing, new_configs)` | New, private in `Core::Contract`. Owns both messages, so the three existing detect-then-raise sites collapse to one call each. |
| `_reject_colliding_shape_member_names!(shape)` | New, private in `Core::Contract`. Recursive walk over resolved members, applying the same two rules at each nesting level. |

### Data flow

In `expects` and `exposes`, immediately after the existing symbolization and before any comparison, `_reject_unrenderable_field_names!` rejects a name with no UTF-8 rendering. Ordering is load-bearing rather than stylistic: two unrenderable names both canonicalize to `nil`, so a collision check running first would compare `nil` to `nil` and report a property collision for two names that share no property — the message would be a lie. Rejecting the unrenderable name first means the collision check only ever compares real property names.

`_duplicate_fields` then does the collision work, keyed on the canonical property. The route half of the key stays `c.on.to_s` uncanonicalized, because a colliding route is unreachable (see non-goals). Because identity is now the property rather than the Symbol, an identical-name duplicate and a canonical collision arrive at one place, and the message partitions on whether the two spellings are equal:

- equal spellings → the existing `Axn::DuplicateFieldError` with its existing message, byte for byte, so no current declaration error changes wording;
- differing spellings → the same class with a message naming both spellings and the property they collapse to.

That partition lives in a new `_reject_duplicate_fields!` rather than at the call sites, because there are three structurally identical detect-then-raise pairs today — top-level `expects` (`contract.rb:194-195`), `exposes` (`:241-242`), and subfields (`contract_for_subfields.rb:502-503`, which is how ambient subfields are covered too, since they declare through `expects … on:`). Changing `_duplicate_fields`' return shape without moving the raise would triplicate the new partition logic; folding detection and reporting into one helper leaves each site a single line and one definition of both messages.

Shape members reach the same two rules through `_reject_colliding_shape_member_names!`, called from `expects` and `exposes` on `validations[:shape]` once it is resolved — in `expects` after the shape is built (`contract.rb:185`) and before the subfield early return (`:187`), so top-level and subfield shapes are both covered by one call; in `exposes` beside the existing `_reject_outbound_shape_user_facing!` (`:234`). Walking resolved members — rather than checking inside the builder — is the house pattern and covers both declaration forms in one place: the `do…end` block routes through `_build_shape_member`, but a raw `shape:` kwarg supplies pre-built member objects that never do, which is exactly why `_reject_outbound_shape_user_facing!` (`contract.rb:498-508`) already walks resolved members via `_member_shape` and why the comment at `contract.rb:231-234` states that doctrine. Nesting comes free in both directions: `_build_shape_member` recurses into `_build_shape` for subblocks (`contract.rb:784`), and the walker recurses through `_member_shape` the way its sibling does. `_build_shape` itself needs no change.

Every raise happens before the class is mutated, matching the validate-before-commit ordering documented at `contract.rb:197-201`, so a rescued declaration error never leaves a class carrying an orphaned config or a generated reader.

### Error selection

Collisions raise `Axn::DuplicateFieldError`. Once field identity *is* the canonical property, a collision is a duplicate field by that definition, so this widens an existing error rather than inventing one — and it is the class the adjacent branch already raises three lines away (`contract.rb:195`, `:242`). Duplicate and colliding shape member names raise it too, for the same reason.

An unrenderable name raises `ArgumentError`. Nothing is duplicated; the name simply is not a usable field name, which is the defect `_reject_dotted_field_name!` (`contract.rb:605`) already reports with `ArgumentError` from a few lines away.

Every message names the problem and the fix, per `AGENTS.md`: the offending spellings via `inspect`, the property they collapse to, and the instruction to declare them under names that stay distinct once converted to UTF-8. `inspect` rather than raw interpolation is load-bearing — interpolating a non-UTF-8 name into a UTF-8 message is what raises `Encoding::CompatibilityError` from the reporting itself, and `inspect` escapes those bytes to ASCII. For a field name that is `Symbol#inspect`, which cannot be overridden (Symbol takes neither a subclass nor a singleton), matching the reasoning already written at `values.rb:119-123`. A shape member name is not necessarily a Symbol: `expects :payload do field "stringy" end` stores the String verbatim on the `ShapeConfig` (verified), even though the schema symbolizes it into `:stringy` downstream. Member messages therefore lead with the canonical property, a frozen String core built itself, and where a raw spelling is named too, the reporting binds the primitive rather than dispatching it — the technique `values.rb` already uses via `DEFAULT_TO_S` for exactly this hazard. Normalizing `ShapeConfig#field` to a Symbol at declaration would make the hazard structurally impossible and would match what the schema already does, but it changes a reflected value's class and so belongs to its own ticket, not this one.

## Non-goals

**`Reflection::UnserializableValue` stays runtime-only, and `serialize_exposed` keeps its defense.** The declaration check cannot see a runtime Hash's keys, so the serializer remains the last line for the case that is only knowable during a call. A test asserts the runtime check still fires, so nobody later reads the declaration guard as making it redundant. Raising `UnserializableValue` at declaration would also route a programmer error into the adapter response path that rescues it, against `AGENTS.md`'s "pick the error by who's at fault."

**`on:` route segments are not canonicalized.** A colliding route cannot be declared: `on:` must name an already-declared reader, so the second spelling fails reader lookup with its own clear error, and after this change the pair of top-level fields it would need is itself rejected. Canonicalizing the route half of the key would be dead code.

**Reader names are untouched.** `as:` and `prefix:` name Ruby methods, not JSON properties; the wire key stays canonical regardless, and `_validate_reader_names!` already governs reader uniqueness. Schema properties are keyed by wire key, so an alias never reaches a property name.

**`of:` is untouched.** It carries a `:klass`, not member names.

**No new canonicalization home.** Extracting `canonical_wire_key` (and the `utf8_rendering`/`transcode_to_utf8` pair it depends on) into `Axn::Internal` would move three methods with call sites throughout `values.rb` to serve one new caller, for no boundary that the `coercible_klasses` precedent does not already sanction.

## Interaction with the adapter-facing serialization surface

[PRO-2992](https://linear.app/teamshares/issue/PRO-2992/axn-narrow-the-adapter-facing-serialization-surface-behind) narrows `Axn::Reflection::Values` to one adapter entry point, and its plan privatized `canonical_wire_key` by name in a `private_class_method` list written before this second in-core caller existed. That plan has been amended (`60312701` on its branch, ahead of its own Task 2, so no rework): the list drops `:canonical_wire_key`, and the deliverable now reads as one *adapter-facing* entry point with two methods public for named core callers — `serialize_value` for `Reflection::Schema`, `canonical_wire_key` for `Core::Contract`. That is what its surface-closure spec should assert in any case, since `private_class_method` cannot express "internal to core but not to adapters" and its plan already works around that with a `send`.

Files do not otherwise overlap: this ticket touches `lib/axn/core/contract.rb` and its specs, PRO-2992 touches `values.rb`, the new `extensions/serialization.rb`, and adapter docs. Both add to the same CHANGELOG version section.

## Testing

Fixtures are the ones verified above: `:café` alongside `"caf\xE9".dup.force_encoding("ISO-8859-1").to_sym` for a collision, and `"bad\xFF".dup.force_encoding("ASCII-8BIT").to_sym` for an unrenderable name. The unrenderable fixture must be `ASCII-8BIT`: Ruby refuses `to_sym` on bytes that are invalid *in UTF-8*, raising `EncodingError` before the declaration is reached, so a `force_encoding("UTF-8")` fixture tests nothing.

Coverage per surface: a collision and an unrenderable name on `expects` and on `exposes`; a collision on two subfield leaf names under one route, and its counterpart proving two leaves under *different* routes still declare cleanly; a collision and a duplicate at two nesting levels of a shape, through both the block and raw `shape:` forms. Plus the message assertions — the existing duplicate wording unchanged, the collision naming both spellings and the property — and the regression test that `serialize_exposed` still raises on runtime colliding Hash keys.

Never assert `Hash#inspect` text: Ruby 3.4 changed its spacing and CI runs 3.2/3.3/3.4.

## Breaking change

`[BREAKING]` in the CHANGELOG under the current version section. A class that defines cleanly today begins raising in two situations: it declares a field, subfield, or shape member name whose bytes are not UTF-8 or that collapses onto another name's property; or it declares the same shape member name twice, which currently builds two members and silently keeps the last in the schema. Nothing is released, so no deprecation cycle applies. The full suite is the check for whether anything in the repo leans on last-wins member declarations; a hit there is a finding to report, not something to edit around.
