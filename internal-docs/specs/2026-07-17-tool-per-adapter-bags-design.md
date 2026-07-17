# More tool declaration support: per-adapter option bags (PRO-2942)

Linear: https://linear.app/teamshares/issue/PRO-2942/axn-more-tool-declaration-support

## Motivation

Core gives an Axn two disjoint ways to say "how I participate as a tool":

1. The `tool` DSL — membership plus one shared attribute (`name:`).
2. Per-adapter config — `configure(:mcp) { |c| c.present_as = :message }`, stored in `@_axn_config_overrides[namespace]` and read via `resolve_override_for`.

These don't talk to each other. Declaring "an mcp tool with this title" means `tool :mcp` *plus* a detached `configure(:mcp) { … }` block, and the shared `tool name:` is all-or-nothing across adapters with no clean per-surface override. Adapter gems (axn-mcp, axn-ruby_llm) increasingly need per-tool, per-adapter metadata declared on the class so it survives the zero-arg enumeration path (`Axn::MCP.tools`), and a detached `configure` block per tool reads poorly.

## Proposal

Let `tool` accept per-adapter option bags that write into the adapter's existing config-override store:

```ruby
tool mcp:      { name: "search", title: "Search", present_as: :message,
                 annotations: { read_only_hint: true } },
     ruby_llm: { halt_after: true }
```

This is **sugar over** `configure(<adapter>)`: each key/value (except `name`) lands in the same `@_axn_config_overrides[adapter]` slot and resolves through the same `resolve_override_for`. An adapter key implies membership in that adapter. Fully additive — every existing `tool …` spelling resolves identically.

## Decisions

Two forks were genuinely open in the ticket; both are settled here.

### `name` nests in the bag (option A)

`name` is the one identity attribute core already owns (it is the shared `tool name:` today, and the registry enforces uniqueness on the resolved name). It is **not** adapter-specific like `title`/`present_as`, so core intercepts it wherever it appears — top-level *or* inside any bag — and never writes it to the opaque config store.

- `tool name: "x"` stays the shared shorthand: same provider name on every surface (the common case, unchanged).
- `tool mcp: { name: "x" }` overrides the provider name for the mcp surface only.
- A single-adapter author writes one coherent block with no top-level/nested split to reason about:
  ```ruby
  tool mcp: { name: "search", title: "Search", present_as: :message }
  ```

Cross-adapter name divergence (mcp knows it as `tool_m`, ruby_llm as `tool_r`) is allowed and harmless: the uniqueness check is scoped per-adapter, and nothing requires a tool to share a name across surfaces. The only invariant core must keep is *within-adapter* uniqueness, which the registry preserves by resolving `tool_name(adapter)` (below).

Rejected alternative — `name` as an opaque adapter setting (`@_axn_config_overrides[:mcp][:name]`, adapter declares its own `setting :name`): core's `tool_name`-based uniqueness check would not see the override, so it would dedup on the *derived* name while the adapter publishes a *different* one. Core would silently lose the naming authority that AGENTS.md makes a non-negotiable.

### Mixing positional adapters and bags is coherent (union)

```ruby
tool :ruby_llm, mcp: { title: "Search" }   # member of both :ruby_llm and :mcp
```

Memberships union: `_tool_declaration = (adapters + bags.keys).uniq`. The redundant `tool :mcp, mcp: { … }` (member of mcp, with config) is allowed silently — no guard, no upside to rejecting it.

## Behavior

### `tool` signature

```ruby
def tool(*adapters, name: nil, **bags)
```

Positional `adapters` and the shared `name:` are unchanged. `**bags` captures per-adapter option bags.

- **Membership.** `_tool_declaration = (adapters + bags.keys).uniq`, or `:all` when both are empty. Bare `tool`, `tool :mcp, :ruby_llm`, and `tool false` behave exactly as today.
- **Bag value type.** Each bag value must be a `Hash`; a non-Hash (`tool color: "red"`) raises `ArgumentError` at declaration.
- **Empty bag.** `tool mcp: {}` is membership only, equivalent to `tool :mcp`.
- **`name` extraction.** For each bag, a `name` key is pulled out (not written to the config store) and recorded as that adapter's provider-name override. A bag whose `name` sanitizes to empty raises at declaration, exactly like the shared `tool name:` does.
- **Config write.** The remaining keys of each bag are written via `axn_configure(<adapter>) { |c| c.<key> = <value> }` — the same `NamespaceWriter`, so writes land in the same `@_axn_config_overrides[adapter]` slot, get **eager** validation when the adapter's source is registered on the class (schema known) and **tolerant + validate-on-read** otherwise. No second resolution path.
- **`tool false`.** Extends its existing rejection to also forbid bags (and `name:`, as today): opting out can't be combined with configuring.

### `tool_name(adapter = nil)` reader

The existing resolved-name reader gains an optional, internal-only `adapter` argument. Resolution order:

1. per-adapter bag name for `adapter` (if given and present), then
2. shared `tool name:` override, then
3. derivation from `axn_name`/class name (existing: strip configured prefixes, snake_case, sanitize to `[a-z0-9_]`, never blank).

Each candidate is sanitized and skipped if it sanitizes to empty (defense-in-depth, mirroring today). Zero-arg `tool_name` is unchanged (shared/derived) so existing callers (`Axn::Extras::Strategies::Vernier`, factory) keep working. Users never pass the argument — only the registry does.

### Storage

- `_tool_name_override` (existing `class_attribute`, scalar) stays the shared name.
- `_tool_name_overrides` (new `class_attribute`, default `{}`) holds `{adapter => raw_name}` for per-adapter names.

Both are rebuilt fresh on each `tool` call (a fresh declaration resets names, matching how the shared name is reset today). A subclass that does not redeclare `tool` inherits the parent's declaration and names; a subclass that declares its own `tool` rebuilds everything. Per-adapter names live in a dedicated core structure, not in `@_axn_config_overrides` — names are core-owned, not opaque adapter config (consistent with `_tool_name_override` already being its own attribute rather than a config entry).

### Registry

`tools_for(adapter)` and `_assert_unique_tool_names!(members, adapter)` switch from `&:tool_name` to `{ |k| k.tool_name(adapter) }`, so within-adapter uniqueness detection and deterministic ordering honor per-adapter names. Both already have `adapter` in hand; no new plumbing. Membership resolution is unchanged: a bag sets an explicit `_tool_declaration` array, so `member?` matches via the Array branch — the `_declares_adapter_config?` fall-through still applies only to the pure `configure(:adapter)`-without-`tool` case.

## Guards and edge cases

- **Repeat-`tool` guard.** The existing `@__axn_tool_declared` ivar already rejects a second `tool` on the same class regardless of form; the bag form is covered with no change.
- **Collision with a separate `configure(:adapter)` block.** Last-writer-wins into the shared slot, identical to two `configure` calls — documented, not guarded.
- **Unknown / unregistered bag adapter key.** Config stores tolerantly (no source registered ⇒ never validated, never resolved) and the key never matches `tools_for` — same outcome as an unknown positional symbol today.
- **Unknown setting key for a *registered* adapter.** Fails at declaration exactly like a bad `configure` setter (routed through the same `NamespaceWriter` eager validation).

## Acceptance

- `tool mcp: { present_as: :message }` resolves identically to `tool :mcp` + `configure(:mcp) { |c| c.present_as = :message }` via `resolve_override_for`.
- An adapter key implies membership (`Axn.tools_for(:mcp)` includes a class declared only via `tool mcp: { … }`).
- Unknown keys for a registered adapter fail the same way a bad `configure` setter does.
- `tool mcp: { name: "x" }` overrides the provider name for the mcp surface only; bare `tool name:` stays shared; `tool_name(:mcp)` reflects the override and the registry dedups/enumerates on it.
- Core carries no adapter-specific key names (only `name`, which it already owns).
- Every existing `tool …` spelling and zero-arg `tool_name` behave identically.

## Out of scope

Adapter-side changes (consuming `tool_name(adapter)`, dropping detached `configure(:adapter)`-per-tool guidance) are the follow-ups in axn-mcp (PRO-2923) and axn-ruby_llm (PRO-2924). This PR is core only: the `tool` DSL and the `tool_name` reader.
