# Rejecting opaque outbound values

**Ticket:** [PRO-2988](https://linear.app/teamshares/issue/PRO-2988/axn-strict-mode-for-outbound-value-serialization-opaque-leaves-opaque)

**Goal:** Make `Axn::Reflection::Values` the sole owner of "this exposed value has no honest JSON representation," so an adapter never re-implements core's walk in order to pre-check it. Adds a `reject_opaque:` mode covering two dishonest-but-lossless renderings, and closes one silent data-loss bug unconditionally.

## Motivation

PR #203 made core the owner of the cycle case: `serialize_value` raises `Axn::Reflection::UnserializableValue` on a self-referential value, and `docs/recipes/authoring-tool-adapters.md:130` now tells adapters "You don't need your own cycle detection." That claim is true for cycles and false for everything else — core still silently renders three other shapes that no JSON consumer should receive:

| Input | Core renders today |
| --- | --- |
| `User.new` (no own `as_json`, no `to_h`, inherited `to_s`) | `"#<User:0x00000001232124a0>"` |
| `{ KeyObj.new => 1 }` | `{"#<KeyObj:0x0000000123210ab0>"=>1}` |
| `{ id: 1, "id" => 2 }` | `{"id"=>2}` — the `1` is gone, no error |

`axn-openapi` compensates with `Axn::OpenAPI::Serializer.assert_serializable!`, a full second walk over the value graph whose only job is to add these three rejections. To do that it has to mirror `serialize_value`'s branch decisions — the leaf-type list, `as_json`-before-`to_h` ordering, key stringification — and it has **already drifted**: it calls its cycle guard only in the `Hash`/`Array` branch, never on the `as_json`/`to_h` source object. Because each `to_h` call returns a fresh Hash with a new identity, `class Selfy; def to_h = { child: self }; end` recurses unboundedly in the adapter's pre-pass while core handles it correctly. A strictness check is only sound colocated with the rendering it predicts; that is the core argument of this change.

Collapsing the two walks also removes a double-invocation of every user `as_json`/`to_h`, which the adapter's own comment apologizes for.

## Scope: the four defects

Core will diagnose four shapes. Two gates, drawn on whether the rendered body would be *wrong* or merely *ugly*:

**Unconditional — the rendering lies about the data.**

1. *Self-referential value.* Already shipped in #203. No JSON representation exists at all.
2. *Colliding Hash keys.* `transform_keys(&:to_s)` maps `{id: 1, "id" => 2}` to one property, dropping a value with no signal. This is the only defect where the caller cannot tell from the output that anything went missing, so gating it behind an opt-in would leave a correctness bug unfixed for the two adapters shipping today. Neither `axn-mcp` nor `axn-ruby_llm` would rationally set `reject_opaque: true` — an ugly `#<User:0x…>` in an LLM tool result still beats a hard tool failure — so a gated collision check would only ever fire for the adapter that already has its own guard. **This is the deliberate resolution of the open question raised in the proposal, against the proposal's own default.**

**Under `reject_opaque:` — the rendering is honest but unpresentable.** Every exposed datum is present; it just reads as garbage.

3. *Leaf with no projection of its own.* `serialize_value`'s final fallback is `value.to_s`, reached only when the value has no own `as_json` and no `to_h`. If that `to_s` is the inherited `Object#to_s`, an object address ships in the response body. The check is simpler here than downstream because the earlier `when` branches and the `as_json`/`to_h` arms have already routed away everything that stringifies meaningfully. Inside Rails the same value never reaches that fallback: ActiveSupport defines a generic `Object#as_json` on every object, so it lands in the `as_json` arm and what ships is an instance-variable dump — equally undeclared by the value's author, and worse than an address in that it leaks internals and doesn't match the reflected `output_schema`. The gate therefore covers both routes: a leaf whose `to_s` is the inherited one, and a leaf admitted to the `as_json` arm only by that generic `Object#as_json` (`value.method(:as_json).owner == Object`, the same comparison the routing predicate makes, which inside that arm also proves the value has no `to_h`).
4. *Default-`to_s` Hash key.* Keys render via `transform_keys(&:to_s)` and never touch the `as_json`/`to_h` chain, so the same garbage becomes a JSON *property name*.

### Explicit non-goals

- **Non-finite floats and non-real Numerics.** `Float::INFINITY` and `Complex(1,2)` (rendered as `"1+2i"`) are encode-time or type-mismatch concerns, not presentation ones. `spec/axn/reflection/schema_spec.rb:710-722` already records the deliberate decision that `Complex` reflects untyped on output *because* `serialize_value` emits its string form, and `axn-openapi` scopes these to its own `Dispatcher.ensure_encodable`. Adding them here would relitigate a settled call.
- **Comparing colliding values.** A middle option — raise only when the two colliding keys hold *different* values — was rejected. It requires `==` or `equal?` on arbitrary user objects inside the serializer: user code that can raise or be slow, and `equal?` false-positives on two equal-but-distinct strings. A Hash carrying both `:id` and `"id"` is essentially always a bug; the refinement buys tolerance for a shape nobody wants.
- **Exporting `Axn::Internal::CycleGuard` to `Axn::Extensions`.** This was under consideration so `axn-openapi` could guard its own walk. This change deletes that walk, so no adapter needs a cycle primitive and the namespace stays private.

## API

```ruby
serialize_exposed(result, field_configs, reject_opaque: false)
serialize_value(value, path: "(exposed value)", seen: nil, reject_opaque: false)
```

`reject_opaque` threads through the recursion alongside `seen`. Defaulting to `false` keeps `axn-mcp` and `axn-ruby_llm` byte-identical with no adapter edit; that is the whole of what the default buys. Schema reflection is unaffected either way: `Schema.normalize_schema_literal` traverses a literal `default:`'s Hashes and Arrays itself and routes only `Symbol`/`Time`/`Date`/`Numeric` leaves to `serialize_value`, returning any other object untouched, so none of the four checks is reachable from a reflection call site.

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

### `lib/axn/exceptions.rb`

`UnserializableValue` gains `reason:`, defaulting to the current cycle text so every existing message stays byte-identical and the existing `new(path:, value:)` call form keeps working (it is public API, and `values.rb:97` is currently its only construction site):

```ruby
"Cannot serialize exposed value at `#{@path}` (#{@value.class}): #{@reason || cycle_reason}"
```

Each reason string carries its own terminal punctuation so the format string adds none. The three new reasons live in `values.rb` next to the checks that raise them; the cycle reason stays in the exception as the no-reason-given fallback. Draft wording:

- leaf — `"it serializes only via the default Object#to_s (it would render as garbage like \"#<User:0x…>\") — declare it `type: String` and format it, or give the value an `as_json`/`to_h`."`
- key — `"a Hash key is rendered via #to_s and this one has only the default Object#to_s (it would stringify to garbage like \"#<…>\")."`
- collision — `"two keys stringify to the same JSON property #{wire_key.inspect} (#{first.inspect} and #{second.inspect}), which would silently collapse and drop a value."` (the only reason of the three that interpolates; the other two are fixed hint text)

For both key cases the `path` names the offending key — `data (hash key #<KeyObj:0x…>)` — and `value:` is the key itself, so `(#{@value.class})` reports the key's class. The class's doc comment ("Currently only a self-referential container") is updated: the family is now four.

No adapter-specific escape hatch appears in any core message. `axn-openapi`'s current wording ends with "Disable with `Axn::OpenAPI.config.strict_serialization = false`" — core must not know that knob, so it moves to the adapter's dispatcher log line.

## Testing

`spec/axn/reflection/values_spec.rb` carries the new cases; the cycle cases stay in `spec/axn/self_referential_values_spec.rb`.

- Each of defects 3 and 4 both ways: raises under `reject_opaque: true`, renders as today under the default.
- Defect 2 raises under both settings, and the message names both original keys and the collapsed property.
- Nested occurrences: inside a Hash, inside an Array, and behind a custom `to_h`, asserting the reported `path`.
- Negative cases under `reject_opaque: true`: a value with a meaningful custom `to_s`, a Symbol/String/Integer-keyed Hash, `Time`/`BigDecimal`/`Symbol` leaves, and an object with its own `as_json`.
- A `Reflection::Schema` case proving a literal `default:` whose Hash keys stringify to one property still reflects rather than raising. The colliding-key check is the one that raises unconditionally, so it is the only one that could surface in `input_schema` if `normalize_schema_literal` ever handed a container to `serialize_value`.
- Never assert `Hash#inspect` text: Ruby 3.4 changed its spacing and CI runs 3.2–3.4. Object addresses in messages need regex or substring matching.

## Also update

- `docs/recipes/authoring-tool-adapters.md` (~L121-130) — document `reject_opaque:` beside the existing `serialize_exposed` guidance, and widen "you don't need your own cycle detection" to cover all four defects.
- `AGENTS-tool-adapters.md:82` — note the `reject_opaque:` kwarg on the one-line `serialize_exposed` reference.
- `CHANGELOG.md` under `## 0.1.0-alpha.5` — that version is not released yet and is waiting on this work, so it is the section to edit rather than opening an `## Unreleased` above it. `[BREAKING]` for the unconditional colliding-key raise, `[FEAT]` for `reject_opaque:`.

## Downstream follow-up (not this PR)

Once this lands, `axn-openapi` deletes `assert_serializable!`, `validate_hash!`, `within_container`, `SAFE_LEAVES`, `DEFAULT_TO_S_OWNERS`, and `UnserializableExposureError` (~90 lines; `errors.rb` loses its only subclass), replacing the pre-pass with the `reject_opaque:` kwarg and moving its disable hint into the dispatcher log line.

It also renames its own `strict_serialization` setting to `reject_opaque`, which is unreleased and so free to change. That knob is genuinely narrower than the word "strict" implied: it gated only the opaque pre-pass, never `Dispatcher.ensure_encodable`, which is unconditional. Keeping the two names aligned stops a reader assuming core's kwarg promises encodability.

## Why `reject_opaque:` and not `strict:`

The kwarg was `strict:` through the first three commits. `strict` names an intensity rather than an axis, and it over-promises: a reader reasonably expects `strict: true` to mean "the Hash I get back is JSON," and it does not — `Float::INFINITY`, `NaN`, and invalid-UTF-8 Strings all pass every check here and then raise inside `JSON.generate`.

That gap cannot be closed under any name, because **core never encodes**. `serialize_exposed` returns a Hash; encoding happens in the adapter. Core could only *predict* encodability by re-implementing what the encoder already answers authoritatively — the exact mirror-walk this change exists to delete. The asymmetry is the principled scope line: an opaque `to_s` is undetectable downstream (`"#<User:0x…>"` encodes fine, so only the renderer can catch it), while a non-finite Float is authoritatively caught by `JSON.generate` with no drift possible. `reject_opaque:` names what it does and leaves encodability where it is already answered correctly.
