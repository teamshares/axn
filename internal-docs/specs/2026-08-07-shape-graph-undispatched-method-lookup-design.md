# One undispatched method lookup (PRO-3055)

## The defect

`ShapeGraph.bound_method` resolved a shape member's readers through a bound `Object#method`. That removes the `respond_to?` dispatch its comment claimed, and keeps the `respond_to_missing?` one: Ruby consults the value's `respond_to_missing?` whenever the looked-up name is **absent**.

Absence is not a corner on this path — it is the branch the read exists to reach. `fetch`'s whole job is to tell an absent reader from one returning nil, and the walk asks every member for the optional attributes (`user_facing:`, `sensitive:`, `method_call:`, `description:`, `metadata:`) that a minimal member simply does not carry. So a member defining that hook had its own code run by the declaration walk and by failure classification, and a hook raising outside `NameError` left through as the verdict.

Reproduced end-to-end before any fix: a member whose `respond_to_missing?` raises a bare `Exception` escaped `expects` out of `shape_graph.rb:459`.

This is the same hazard PR #215 closed inside `NativeMethods.method_owner`, which resolves through the value's singleton class precisely so an absent name runs nothing. Two more modules held `Object#method` for the reason `NativeMethods` documents for never holding one.

## The change

`NativeMethods` gains the value-level twin of `declared_instance_method`:

```ruby
def self.declared_method(value, name)
  MODULE_INSTANCE_METHOD.bind_call(method_table(value), name)
rescue ::NameError
  nil
end

def self.method_owner(value, name) = declared_method(value, name)&.owner
```

`method_owner` now *derives* from that lookup rather than resolving the method table beside it — one lookup with one absence policy, extending the convergence PR #215 made when three owner lookups with three policies became one. `UnboundMethod#owner` is Ruby's own on an object Ruby constructed, so `&.owner` dispatches nothing foreign.

Both holders then go:

- **`ShapeGraph`** — `OBJECT_METHOD` deleted. `bound_method` is gone entirely (`fetch` was its only caller), so `fetch` resolves through `declared_method` and binds the result. `OBJECT_PUBLIC_SEND` and the `Identity.name_error_for?` rescue are untouched: that fallback is what keeps `method_missing`-backed members readable, and it is now the only thing that reads them.
- **`Reflection::Values`** — `UNBOUND_METHOD` deleted; `owner_of` delegates to `method_owner`. Its absence policy changes from raising `NameError` to nil.

### Why repointing `owner_of` is safe

Both callers compare the owner against a specific module, so nil and "the value's own class" already took the same branch:

- `projection_for`: `Object.equal?(owner_of(value, :as_json))` — a `method_missing`-backed `as_json` reported nil is not `Object`, exactly as its own class was not.
- `default_to_s?`: `DEFAULT_TO_S_OWNERS.include?(...)` — nil is not a default owner. This **removes** a `rescue NameError` that existed only for the `undef_method`'d `to_s` case, which now answers the same way without raising out of a reflection path.

`==` on the `as_json` owner became `Object.equal?(...)`, putting axn's constant on the left so a class-side `==` cannot answer the comparison.

The `respond_to?` calls in `Values` are deliberately unchanged. "Do you claim to respond to this?" is genuinely the value's own answer to give, and overriding it is a supported idiom a `method_missing`-backed proxy depends on. Only the OWNER question is answered from the table — that reasoning moved onto `owner_of` when the constant carrying it was deleted.

## Behaviour matrix

| member shape | before | after |
|---|---|---|
| real method (private, singleton, prepended included) | first lookup | first lookup |
| `OpenStruct` (real singleton accessors via `new_ostruct_member!`) | first lookup | first lookup |
| `method_missing`, no `respond_to_missing?` | `public_send` fallback | `public_send` fallback |
| `method_missing` + `respond_to_missing?` | first lookup | **`public_send` fallback** |
| absent name, `respond_to_missing?` raises | **caller's exception escapes** | clean absence |
| `undef_method`'d name | absent | absent |

Only row 4 changes path, and `public_send` reaches `method_missing` and returns the identical value.

## Verification

- **A/B against `fb7e93b7`** (throwaway worktree, per `ab-testing-guards.md`): exactly two behavioural examples flip — the declaration-path and runtime-path hazard specs. The row-4 control passes at BOTH commits, which is what makes it a control rather than a fixture that only works after the change.
- **Allocations**: 249.0 per call in both trees. The singleton class is materialized once per declared config, not per call — every `ShapeGraph.read`/`fetch` caller reads configs declared once per class, and the failure-classification reader only runs on failure.
- Full suite 5362 examples / 0 failures; `spec_rails` 361 / 0; RuboCop clean.

## Out of scope

The `Identity`-folds-into-`NativeMethods` refactor (PRO-3027 item 1), the `respond_to?` calls in `Values`, and `shape_graph.rb`'s `Identity.name_error_for?` repoint — that last one is left deliberately so PRO-3027 owns it without a same-hunk conflict.

## Comment sites corrected

The change falsifies prose in several places that documented `respond_to_missing?` as load-bearing. Each was rewritten to describe the new mechanism rather than the change:

- `shape_graph.rb` — the two-lookup rationale, now naming the table lookup and why it is first.
- `native_methods.rb` — the lookup rationale moved onto `declared_method`; `method_owner` keeps only what is specific to owners.
- `values.rb` — `owner_of`, `default_to_s?`, and a stale parenthetical claiming the opaque-key check was deferred because `Object#method` can reach `respond_to_missing?` (the real reason, a key's own `to_s` under iteration, still stands).
- `user_facing_spec.rb` — the read is still an AVAILABILITY read overall, but its first lookup is now a table one.
- `property_name_collision_spec.rb` (×4) and `values_spec.rb` — fixtures whose omitted `respond_to_missing?` was described as the point; the fixtures stay valid, the rationale is now "a table declares nothing for a `method_missing`-backed reader".
