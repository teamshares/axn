# Additional pre-release tool support: Factory DSL parity + deterministic tool enumeration

Prompted by downstream gems (`axn-mcp`, `axn-ruby_llm`) building tool adapters on top of Axn. Two classes of friction surfaced, each with a working downstream shim we want to retire into core:

1. `Axn::Factory.build` has drifted behind the DSL. It was last meaningfully touched at `auto_log` consolidation (#127) and the `hydrate` extraction (#152); since then `tool`, `tag`/`dimension`, `semantic_hints`, `axn_name`, `description`, and `fails_on` all landed as class-level DSL and none flowed back into the builder. An adapter relocating a `define` into a factory-built class can't declare these, and works around it by poking the class post-build.
2. `Axn::Tools::Registry#tools_for` enumerates in `Set`-insertion (load) order, which is non-deterministic across boots — an adapter that publishes a numbered/ordered tool list gets unstable output.

## Scope

**In:** the parity gaps that are genuine *builder config* — declarative state a factory-built Axn should be able to set at construction — plus the registry sort.

**Out (adapter-owned, correctly handled post-build by the adapter):** `tool` membership declaration, `set_extension_metadata`/`extension_metadata` (adapters stash transport config themselves), `memo` (a factory body is a single block; naming a method to memoize is near-useless there). These stay as-is.

## Part 1 — `Axn::Factory.build` new params

All new params are applied inside the existing `build` `.tap` block, alongside the current `expects`/`success`/hooks application. Ordering within the block is not semantically load-bearing for these (they set independent class state), so they slot in naturally.

### Single-value params

- **`axn_name:`** (String) → `axn.axn_name(value)`. This is the clean fix for the synthetic-name problem: a factory-built anonymous class gets a `define_singleton_method(:name)` of `"AnonymousAxn_<object_id>"`. `tool_name` derives from `axn_name.presence || name.presence`, so setting `axn_name:` yields a clean provider-facing `tool_name` **and** a clean `resolved_axn_name`, while the synthetic `.name` remains as the debug fallback it was designed to be. We name the param `axn_name:` (not `name:`) for symmetry with every other Factory param, each of which mirrors its DSL method name exactly. Validation (`non-blank String`) is inherited from the DSL method — no re-check in the factory.

- **`description:`** (any) → **`axn._axn_description = value`** written directly, **not** `axn.description(value)`. Per PRO-2875, `Naming` only extends axn's `description` DSL when no non-Axn ancestor already defines `description`; a tool base class (e.g. `::MCP::Tool`) commonly does, in which case `axn.description(...)` would call *that* ancestor's setter, not axn's. Writing the `class_attribute` backing field directly is shadow-safe and is exactly what the downstream post-build shim was doing. `_axn_description` is a `class_attribute` with `instance_accessor: false`, so the class-level writer `_axn_description=` is always present regardless of the shadowing outcome.

- **`semantic_hints:`** (Symbol or Array<Symbol>) → `axn.semantic_hints(*Array(value))`. One variadic call sets the whole list; the DSL validates against the registered vocabulary and raises on unknown hints (inherited, no re-check).

### Multi-call params (fan-out)

`fails_on`, `tag`, and `dimension` are "call repeatedly; each call accumulates" DSLs. Each param accepts a single spec or a list of specs and fans out into one DSL call per spec — the same pattern `build` already uses for `success`/`error`/`on_*` via `_apply_handlers`. Each gets a small dedicated normalizer (the signatures differ enough that one generic splatter would be more obscure than three focused helpers).

**Guiding principle (documented for users):** a bare/flat value is one spec; wrap specs in an outer array to register several.

#### `fails_on:`

DSL signature: `fails_on(exceptions, message = nil, standalone: nil, &block)` — `exceptions` is a `Class` or `Array<Class>`.

Normalization:
- `nil` → skip.
- a `Class` → one matcher: `fails_on(Class)`.
- an `Array` → a **list of specs**. Each element:
  - a `Class` → `fails_on(Class)`.
  - an `Array` → pop a trailing `Hash` as kwargs; then
    - if every remaining element is a `Class` → **one matcher over all of them**: `fails_on(remaining, **kwargs)`.
    - else → `[exceptions, message]`: `fails_on(remaining[0], remaining[1], **kwargs)` (where `remaining[0]` may itself be a `Class` or `Array<Class>`).

Consequences (as agreed):
- `fails_on: MyError` → one matcher.
- `fails_on: [A, B]` → **two** matchers (each covers one class).
- `fails_on: [[A, B]]` → **one** matcher covering both.
- `fails_on: [[A, "msg", { standalone: true }]]` → `fails_on(A, "msg", standalone: true)`.
- `fails_on: [[[NetA, NetB], "network"]]` → `fails_on([NetA, NetB], "network")`.

Per-matcher blocks are out of scope; where a block is wanted, pass a callable as the `message` (the DSL accepts `#call`).

#### `tag:` / `dimension:`

DSL signature: `tag(*args, from: :inputs, &block)` — one facet per call, `args` is `[name, resolver]` (or `[name]` with a block); `resolver` may be any value or a callable.

Normalization:
- `nil` → skip.
- an `Array` whose **first element is itself an `Array`** → a list of specs.
- otherwise → the value is a **single spec**.
- each spec is an `Array` `[name, resolver]` or `[name, resolver, { from: … }]` → pop trailing `Hash` as kwargs → `tag(name, resolver, **kwargs)`. (Names are never arrays, so first-element-is-array unambiguously signals a list.)

Consequences:
- `tag: [:foo, "bar"]` → one tag `tag(:foo, "bar")`.
- `tag: [:foo, "bar", { from: :result }]` → `tag(:foo, "bar", from: :result)`.
- `tag: [[:a, 1], [:b, 2]]` → two tags.

`dimension:` is identical, calling `axn.dimension(...)`.

## Part 2 — `Axn::Tools::Registry#tools_for` deterministic order

Append `.sort_by(&:tool_name)` to the returned members, placed **after** `_assert_unique_tool_names!`:

```ruby
def tools_for(adapter)
  ensure_loaded!
  members = all_classes.select { |klass| member?(klass, adapter) }
  _assert_unique_tool_names!(members, adapter)
  members.sort_by(&:tool_name)
end
```

Because uniqueness is asserted first, `tool_name` values are guaranteed distinct at the point of sorting, so `sort_by(&:tool_name)` is a total order with no ties — fully deterministic, independent of load order.

## Testing

- **Factory spec** (`spec/axn/factory_spec.rb`): one context per new param.
  - `axn_name:` sets `resolved_axn_name` and drives `tool_name`.
  - `description:` sets `_axn_description`, including the shadowed-ancestor case (build with a `superclass` that defines its own `description`) — assert axn's value is stored and the ancestor's method is not miscalled.
  - `semantic_hints:` single + array; unknown hint raises.
  - `fails_on:` single class, `[A, B]` → two matchers, `[[A, B]]` → one matcher, tuple with message + `standalone:`; behavior verified by running the axn and asserting failure (not exception) settlement.
  - `tag:`/`dimension:` single spec, list of specs, `from:` kwarg.
- **Registry spec**: register classes so insertion order differs from `tool_name` order; assert `tools_for` returns `tool_name`-sorted.

## Docs / CHANGELOG

`docs/` does not document Factory params, so no doc-site change. Add `## Unreleased` CHANGELOG entries: one `[FEAT]` for the Factory parity params, one `[FEAT]` for deterministic `tools_for` ordering.

## Not user-breaking

All additions are new optional params and a stable-ordering guarantee on an enumeration that previously made no ordering promise. No existing behavior changes.
