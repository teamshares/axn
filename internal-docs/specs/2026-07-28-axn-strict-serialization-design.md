# Rejecting opaque outbound values

**Ticket:** [PRO-2988](https://linear.app/teamshares/issue/PRO-2988/axn-strict-mode-for-outbound-value-serialization-opaque-leaves-opaque)

**Goal:** Make `Axn::Reflection::Values` the sole owner of "this exposed value has no honest JSON representation," so an adapter never re-implements core's walk in order to pre-check it. Adds a `reject_opaque:` mode covering two dishonest-but-lossless renderings, and closes three unconditional bugs: one silent data-loss path and two renderings `JSON.generate` refuses outright.

## Motivation

PR #203 made core the owner of the cycle case: `serialize_value` raises `Axn::Reflection::UnserializableValue` on a self-referential value, and `docs/recipes/authoring-tool-adapters.md:130` now tells adapters "You don't need your own cycle detection." That claim is true for cycles and false for everything else — core still silently renders three other shapes that no JSON consumer should receive:

| Input | Core renders today |
| --- | --- |
| `User.new` (no own `as_json`, no `to_h`, inherited `to_s`) | `"#<User:0x00000001232124a0>"` |
| `{ KeyObj.new => 1 }` | `{"#<KeyObj:0x0000000123210ab0>"=>1}` |
| `{ id: 1, "id" => 2 }` | `{"id"=>2}` — the `1` is gone, no error |

`axn-openapi` compensates with `Axn::OpenAPI::Serializer.assert_serializable!`, a full second walk over the value graph whose only job is to add these three rejections. To do that it has to mirror `serialize_value`'s branch decisions — the leaf-type list, `as_json`-before-`to_h` ordering, key stringification — and it has **already drifted**: it calls its cycle guard only in the `Hash`/`Array` branch, never on the `as_json`/`to_h` source object. Because each `to_h` call returns a fresh Hash with a new identity, `class Selfy; def to_h = { child: self }; end` recurses unboundedly in the adapter's pre-pass while core handles it correctly. A strictness check is only sound colocated with the rendering it predicts; that is the core argument of this change.

Collapsing the two walks also removes a double-invocation of every user `as_json`/`to_h`, which the adapter's own comment apologizes for.

## Scope: the six defects

Core will diagnose six shapes. Two gates, drawn on whether the rendered body would be *wrong* or merely *ugly*:

**Unconditional — the rendering lies about the data, or is not JSON at all.**

1. *Self-referential value.* Already shipped in #203. No JSON representation exists at all.
2. *Colliding Hash keys.* `transform_keys(&:to_s)` maps `{id: 1, "id" => 2}` to one property, dropping a value with no signal. The unit of comparison is the JSON *property* each key produces — its `to_s` rendered into UTF-8 — not the Ruby String that `to_s` returned. A property name is text, while a Ruby String is bytes plus an encoding, so an ISO-8859-1 `"\xE9"` and a UTF-8 `"é"` are two non-`eql?` Strings a Hash holds separately and one single property: compared as they came they pass the check, and `JSON.generate` then emits the property twice for `JSON.parse` to collapse. Keys are therefore canonicalized to UTF-8 before comparison, which is also what makes the rendered Hash's property names the bytes an encoder emits. This is the only defect where the caller cannot tell from the output that anything went missing, so gating it behind an opt-in would leave a correctness bug unfixed for the two adapters shipping today. Neither `axn-mcp` nor `axn-ruby_llm` would rationally set `reject_opaque: true` — an ugly `#<User:0x…>` in an LLM tool result still beats a hard tool failure — so a gated collision check would only ever fire for the adapter that already has its own guard. **This is the deliberate resolution of the open question raised in the proposal, against the proposal's own default.**
3. *Non-finite Float.* `Float::INFINITY`, `-Float::INFINITY`, and `Float::NAN` have no JSON literal, and `JSON.generate` refuses each with a `JSON::GeneratorError`. A `BigDecimal("Infinity")`/`BigDecimal("NaN")`, and a `Rational` or `BigDecimal` too large for a double, reach the same place through the `Numeric` arm's `Float()` coercion, so the check sits on the coerced result rather than on the `Float` leaf alone. An encoder's `allow_nan: true` would emit a bare `Infinity`, which is not standard JSON and consumers reject, so that is no honest rendering either.
4. *String with no UTF-8 rendering.* JSON is a UTF-8 format, so bytes with no UTF-8 rendering are refused outright. The predicate is *transcodability to UTF-8*, not `valid_encoding?`: `"\xFF"` in `BINARY` is valid BINARY (`valid_encoding? == true`) and `JSON.generate` still refuses it. It is equally not "are these bytes literally UTF-8" — a valid ISO-8859-1 or Shift_JIS String transcodes cleanly and encodes fine, so that rule would reject real data. The check applies to every String the serializer returns (the String leaf, a Symbol's `to_s`, a caller's `to_s`/`iso8601`) and to a rendered Hash *property name*, which is a String in the output on exactly the same terms. Transcodability and the transcoding are one computation, so the two answers it can give are used differently by the two callers: a *value* is only checked and keeps the encoding it was exposed in (it transcodes losslessly at encode time, and it cannot collide with anything), while a *key* is rendered through the transcode, because two encodings of one property name have to compare as one property (defect 2).

**Under `reject_opaque:` — the rendering is honest but unpresentable.** Every exposed datum is present; it just reads as garbage.

5. *Leaf with no projection of its own.* `serialize_value`'s final fallback is `value.to_s`, reached only when the value has no own `as_json` and no `to_h`. If that `to_s` is the inherited `Object#to_s`, an object address ships in the response body. The check is simpler here than downstream because the earlier `when` branches and the `as_json`/`to_h` arms have already routed away everything that stringifies meaningfully. Inside Rails the same value never reaches that fallback: ActiveSupport defines a generic `Object#as_json` on every object, so it lands in the `as_json` arm and what ships is an instance-variable dump — equally undeclared by the value's author, and worse than an address in that it leaks internals and doesn't match the reflected `output_schema`. The gate therefore covers both routes: a leaf whose `to_s` is the inherited one, and a leaf admitted to the `as_json` arm only by that generic `Object#as_json` (`value.method(:as_json).owner == Object`, the same comparison the routing predicate makes, which inside that arm also proves the value has no `to_h`).
6. *Default-`to_s` Hash key.* Keys render via `transform_keys(&:to_s)` and never touch the `as_json`/`to_h` chain, so the same garbage becomes a JSON *property name*.

Defects 3 and 4 were originally listed as non-goals here, on the reasoning that "the encoder answers it authoritatively downstream." **That premise was wrong, and the non-goal is reversed deliberately.** Two of the three shipped adapters never ask an encoder anything it can report: `axn-mcp` calls `JSON.generate(exposed)` bare and `axn-ruby_llm` calls `.to_json` bare, so both surface an unadorned `JSON::GeneratorError`. The third, `axn-openapi`, catches it in `Dispatcher.ensure_encodable` and turns it into a **pathless generic 500**. Core is the only layer that still knows the value was at `records[3].price`; by the time an encoder refuses it, that is gone.

### Explicit non-goals

- **`JSON::NestingError` (depth > 100).** Verified as a third refusal cause and deliberately excluded. `max_nesting` is an encoder *option* the adapter controls, and core cannot know an adapter's generate options, so refusing at a hardcoded default would reject valid data. A legitimately deep structure is also real data rather than a defect — unlike a cycle, which is unrepresentable at any depth.
- **`Complex`.** Its `to_s` (`"1+2i"`) encodes fine, so this is a schema *type* mismatch rather than an encode failure. `spec/axn/reflection/schema_spec.rb:709-723` already records the decision that `Complex` reflects untyped on output *because* `serialize_value` emits its string form; that decision stands, now for a sharper reason.
- **The literal `default:`/`enum` path.** `Schema.normalize_schema_literal` routes scalar leaves to `serialize_value`, so a `default: Float::INFINITY` would raise from `input_schema`. Reflection describes a declaration and must never raise on user data (`spec/axn/reflection/schema_spec.rb`, "reflects a literal default whose Hash keys stringify to one property rather than raising"), and a reflected literal makes no encodability promise, so the refusal is caught there and the literal is reported as declared. `serialize_exposed`'s output is where the promise lives.
- **Comparing colliding values.** A middle option — raise only when the two colliding keys hold *different* values — was rejected. It requires `==` or `equal?` on arbitrary user objects inside the serializer: user code that can raise or be slow, and `equal?` false-positives on two equal-but-distinct strings. A Hash carrying both `:id` and `"id"` is essentially always a bug; the refinement buys tolerance for a shape nobody wants.
- **Exporting `Axn::Internal::CycleGuard` to `Axn::Extensions`.** This was under consideration so `axn-openapi` could guard its own walk. This change deletes that walk, so no adapter needs a cycle primitive and the namespace stays private.

## API

```ruby
serialize_exposed(result, field_configs, reject_opaque: false)
serialize_value(value, path: "(exposed value)", seen: nil, reject_opaque: false)
```

`reject_opaque` threads through the recursion alongside `seen`. Defaulting to `false` keeps `axn-mcp` and `axn-ruby_llm` byte-identical with no adapter edit; that is the whole of what the default buys. Schema reflection is unaffected either way: `Schema.normalize_schema_literal` traverses a literal `default:`'s Hashes and Arrays itself and routes only `Symbol`/`Time`/`Date`/`Numeric` leaves to `serialize_value`, returning any other object untouched, so none of the presentation checks is reachable from a reflection call site.

`axn-openapi` becomes a one-line pass-through:

```ruby
Axn::Reflection::Values.serialize_exposed(result, configs, reject_opaque: Axn::OpenAPI.config.reject_opaque)
```

## Implementation

### `lib/axn/reflection/values.rb`

The `Hash` branch renders key by key rather than via `transform_keys(&:to_s)`, which is what makes a collapse observable at all — and it renders from a shallow copy taken before the first value is projected:

```ruby
when Hash
  within_container(value, path, seen) do |nested|
    snapshot = snapshot_container(value)

    rendered = snapshot.each_with_object({}) do |(key, element), acc|
      check_opaque_key!(key, path) if reject_opaque
      wire_key = key.to_s
      acc[wire_key] = serialize_value(element, path: "#{path}.#{wire_key}", seen: nested, reject_opaque:)
    end
    raise_colliding_keys!(snapshot, path) unless rendered.size == snapshot.size
    rendered
  end
```

The snapshot is load-bearing, not defensive. Serializing an element runs user code (`as_json`/`to_h`), and that code can reach back into the container being serialized: iterating it live skips whatever the projection removed, and the size comparison still agrees because the live Hash shrank in step with `rendered` — a body quietly missing entries, which is the exact failure this whole change exists to prevent. Comparing against the snapshot's size is what keeps the check honest. The `Array` branch snapshots for the same reason; an element's projection can `delete_at` a later index just as easily.

Allocation is unchanged from `transform_keys`: one intermediate container either way, plus the rendered Hash, and one `to_s` per key. So the unconditional collision check still costs an O(1) size comparison and nothing else. Do not "optimize" the snapshot away — it is the fix for a data-loss path, not overhead.

The offending pair is located by re-scanning the snapshot on the error path only (`group_by(&:to_s)`), so the message names both original keys without a per-key registry in the hot path, and a container mutated mid-serialization cannot change the reported pair. Insertion order makes that pair deterministic. When the re-walk finds no duplicate — a key whose `to_s` returns a different String each call — the collapse is still reported, without naming a pair it cannot identify.

The leaf check sits in the existing `else` arm's final fallback, the only place `value.to_s` is reached:

```ruby
else
  raise UnserializableValue.new(path:, value:, reason: OPAQUE_LEAF_REASON) if reject_opaque && default_to_s?(value)

  value.to_s
end
```

`default_to_s?(obj)` is `DEFAULT_TO_S_OWNERS.include?(obj.method(:to_s).owner)` with `DEFAULT_TO_S_OWNERS = [::Object, ::Kernel]`. `Kernel` is the entry that actually fires — `Object.new.method(:to_s).owner` is `Kernel`, not `Object`, since that is where the default `#to_s` is defined — so dropping it would make the predicate silently never true; `Object` covers a value whose own ancestry reports it there instead. Checking `owner` rather than `respond_to?` is what lets a meaningful `def to_s = "$#{cents / 100.0}"` through.

Because the checks live inside the recursion, they fire at depth for free: `[{ a: User.new }]` raises at path `rows[0].a`, and a value reached through a custom `to_h` is checked exactly like a directly-exposed one.

The two encodability checks (defects 3 and 4) attach to the leaves rather than to a post-pass. `Float` and `String` get their own `when` arms, and the `Numeric` arm checks the *coerced* Float — with the check placed outside the coercion's `rescue`, since `UnserializableValue` is an `ArgumentError` and would otherwise be swallowed into the string fallback. Every String the module returns funnels through one checkpoint, so the guarantee holds by construction rather than one branch at a time: the String leaf, a `Symbol#to_s`, a `Time#iso8601`, the `to_s` fallback, and the rendered wire key. The String predicates are String's own unbound methods, `bind_call`ed — a String subclass can override `valid_encoding?`/`encoding`/`ascii_only?`/`encode`, and a subclass claiming valid UTF-8 over bytes that have none would defeat the guard on exactly the value it exists to catch (verified). `Float#finite?` is dispatched directly: a `when Float` match or a `Kernel#Float` return is always a genuine Float, since a Float subclass has no allocator and no instance of one can exist.

The predicate order is `ascii_only?` → (UTF-8) `valid_encoding?` → transcode. ASCII-only bytes are already UTF-8 under any ASCII-compatible encoding and cover most of a response body, and Ruby caches a String's coderange, so the common case is one C-level check with no allocation. Measured on a 200-record × 10-field payload (2000 leaves, 2000 keys): 1.42 ms → 1.69 ms per serialization, ≈77 ns per guarded String/number. Same category of cost as the capture guarantee documented above, and for the same reason.

One divergence from `json` 2.x is known and deliberate: a `BINARY` String whose bytes happen to be valid UTF-8 is refused here, while `JSON.generate` currently accepts it with `warning: JSON.generate: UTF-8 string passed as BINARY, this will raise an encoding error in json 3.0`. The declared encoding says those bytes are not text; the fix the message names (`force_encoding("UTF-8")`) is the same one json 3.0 will require.

### `lib/axn/exceptions.rb`

`UnserializableValue` gains `reason:`, defaulting to the current cycle text so every existing message stays byte-identical and the existing `new(path:, value:)` call form keeps working (it is public API, and `values.rb:97` is currently its only construction site):

```ruby
"Cannot serialize exposed value at `#{@path}` (#{@value.class}): #{@reason || cycle_reason}"
```

Each reason string carries its own terminal punctuation so the format string adds none. The new reasons live in `values.rb` next to the checks that raise them; the cycle reason stays in the exception as the no-reason-given fallback. Draft wording:

- leaf — `"it serializes only via the default Object#to_s (it would render as garbage like \"#<User:0x…>\") — declare it `type: String` and format it, or give the value an `as_json`/`to_h`."`
- key — `"a Hash key is rendered via #to_s and this one has only the default Object#to_s (it would stringify to garbage like \"#<…>\")."`
- collision — `"two keys stringify to the same JSON property #{wire_key.inspect} (#{first.inspect} and #{second.inspect}), which would silently collapse and drop a value."` (the only reason of the three that interpolates; the other two are fixed hint text)

For both key cases the `path` names the offending key — `data (hash key #<KeyObj:0x…>)` — and `value:` is the key itself, so `(#{@value.class})` reports the key's class. The class's doc comment ("Currently only a self-referential container") is updated: the family is now six.

No adapter-specific escape hatch appears in any core message. `axn-openapi`'s current wording ends with "Disable with `Axn::OpenAPI.config.strict_serialization = false`" — core must not know that knob, so it moves to the adapter's dispatcher log line.

## Testing

`spec/axn/reflection/values_spec.rb` carries the new cases; the cycle cases stay in `spec/axn/self_referential_values_spec.rb`.

- Each of defects 5 and 6 both ways: raises under `reject_opaque: true`, renders as today under the default.
- Defects 3 and 4 raise at BOTH `reject_opaque:` settings, since they are unconditional: each non-finite Float (`Infinity`, `-Infinity`, `NaN`), a `BigDecimal`/`Rational` that coerces to one, invalid UTF-8 bytes, and a BINARY String with a high byte (the case `valid_encoding?` alone calls valid). Negative cases pin the absence of over-rejection: a pure-ASCII BINARY String, multibyte UTF-8, and a String valid in ISO-8859-1/Shift_JIS that transcodes cleanly.
- The round-trip property, as a real assertion rather than a comment: over a representative set of successfully-serialized values, `JSON.generate` never refuses `serialize_value`'s output.
- Defect 2 raises under both settings, and the message names both original keys and the collapsed property.
- Nested occurrences: inside a Hash, inside an Array, and behind a custom `to_h`, asserting the reported `path`.
- Negative cases under `reject_opaque: true`: a value with a meaningful custom `to_s`, a Symbol/String/Integer-keyed Hash, `Time`/`BigDecimal`/`Symbol` leaves, and an object with its own `as_json`.
- `Reflection::Schema` cases proving reflection never raises on a literal: a `default:` whose Hash keys stringify to one property (the container path never reaches `serialize_value`), and a `default: Float::INFINITY` (the scalar path does reach it, and `normalize_scalar_literal` reports the literal as declared instead).
- Never assert `Hash#inspect` text: Ruby 3.4 changed its spacing and CI runs 3.2–3.4. Object addresses in messages need regex or substring matching.

## Also update

- `docs/recipes/authoring-tool-adapters.md` (~L121-130) — document `reject_opaque:` beside the existing `serialize_exposed` guidance, and widen "you don't need your own cycle detection" to cover every defect in the family — including that what `serialize_exposed` returns is now encodable JSON, so an adapter's own encode step no longer needs to defend against a non-finite Float or unrenderable bytes.
- `AGENTS-tool-adapters.md:82` — note the `reject_opaque:` kwarg on the one-line `serialize_exposed` reference.
- `CHANGELOG.md` under `## 0.1.0-alpha.5` — that version is not released yet and is waiting on this work, so it is the section to edit rather than opening an `## Unreleased` above it. `[BREAKING]` for the unconditional colliding-key raise and for the two encodability raises (which replace a bare `JSON::GeneratorError` in `axn-mcp`/`axn-ruby_llm` and a pathless 500 in `axn-openapi`), `[FEAT]` for `reject_opaque:`.

## Downstream follow-up (not this PR)

Once this lands, `axn-openapi` deletes `assert_serializable!`, `validate_hash!`, `within_container`, `SAFE_LEAVES`, `DEFAULT_TO_S_OWNERS`, and `UnserializableExposureError` (~90 lines; `errors.rb` loses its only subclass), replacing the pre-pass with the `reject_opaque:` kwarg and moving its disable hint into the dispatcher log line.

It also renames its own `strict_serialization` setting to `reject_opaque`, which is unreleased and so free to change. That knob is genuinely narrower than the word "strict" implied: it gated only the opaque pre-pass, never `Dispatcher.ensure_encodable`, which is unconditional. Keeping the two names aligned stops a reader assuming core's kwarg promises encodability.

## Why `reject_opaque:` and not `strict:`

The kwarg was `strict:` through the first three commits. `strict` names an intensity rather than an axis, and it over-promises: a reader reasonably expects `strict: true` to mean "the Hash I get back is JSON," and it does not — `Float::INFINITY`, `NaN`, and invalid-UTF-8 Strings all pass every check here and then raise inside `JSON.generate`.

That gap cannot be closed under any name, because **core never encodes**. `serialize_exposed` returns a Hash; encoding happens in the adapter. Core could only *predict* encodability by re-implementing what the encoder already answers authoritatively — the exact mirror-walk this change exists to delete. The asymmetry is the principled scope line: an opaque `to_s` is undetectable downstream (`"#<User:0x…>"` encodes fine, so only the renderer can catch it), while a non-finite Float is authoritatively caught by `JSON.generate` with no drift possible. `reject_opaque:` names what it does and leaves encodability where it is already answered correctly.
