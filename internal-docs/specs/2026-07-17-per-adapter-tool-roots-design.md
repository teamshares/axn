# Per-adapter tool roots + union membership (PRO-2948)

Linear: https://linear.app/teamshares/issue/PRO-2948/axn-tool-registration-reworked

## Motivation

Today a tool's directory residence collapses to "member of every registered adapter." `Axn.config.tool_paths` is a single global list (`%w[agent_tools actions/tools]`), and `Registry#member?` treats a file living under any of those paths as an adapter-agnostic grant — it feeds `:mcp`, `:ruby_llm`, and every future adapter simultaneously (`lib/axn/tools/registry.rb:124`, `_under_tool_path?` at `:214`). That was fine when the only adapters were mcp and ruby_llm, which genuinely want the same population.

It breaks the moment adapters want *different* populations. The roadmap has three distinct relationships in play at once:

- **Shared** — mcp + ruby_llm serve the same set of "agent tools" (today's behavior).
- **Disjoint** — data_shifter_web (PRO-2937) serves a curated ops-UI approve-list that must *never* reach mcp or ruby_llm.
- **Opt-in overlap** — an HTTP/OpenAPI adapter (PRO-2936) reuses *a subset* of the shared tools plus its own directory, but not everything by default.

The current model can only express "one global population minus explicit opt-outs," and its single opt-out (`tool false`) is all-or-nothing across every adapter. There is no per-adapter directory scoping and no per-adapter opt-out. This spec closes both gaps.

This is also the immediate unblock for os-app: shared agent tools were originally under `lib/agent_tools` (matching the `agent_tools` default path) but failed to resolve (lib is not on the Rails autoload path), so they were moved to `app/actions/tools/`, leaving `agent_tools` inert. Under this design the directory name stops being magic — each adapter names the directories it consumes — so os-app points mcp/ruby_llm at whatever real directory holds the shared tools.

## Proposal

Membership becomes a **union of two grants, minus an opt-out**:

> **Final membership = (directory grant ∪ declaration grant) − `except`**

- **Directory grant** — the set of adapters whose configured roots contain the tool's source file. Replaces today's boolean "under a tool path → all adapters."
- **Declaration grant** — adapters named in the `tool` DSL (positional, per-adapter bag keys, or bare `tool` = all).
- **`except`** — a new per-adapter opt-out, applied last.

Directory→adapter mapping is owned by each adapter's own global config, not a central map. The registry aggregates.

### Directory→adapter mapping lives on each adapter

axn's established pattern is that global (non-per-class) config stays on each module — `Axn.configure` for core, `Axn::MCP.configure` for mcp, with no combined entry point (`docs/reference/configuration.md:74`). Directory roots follow that pattern: each adapter declares the directories *it* consumes, in the one initializer block already kept for that gem.

```ruby
Axn::MCP.configure            { |c| c.tool_roots = %w[agent_tools] }
Axn::RubyLLM.configure        { |c| c.tool_roots = %w[agent_tools] }
Axn::OpenAPI.configure        { |c| c.tool_roots = %w[agent_tools http_tools] }
Axn::DataShifterWeb.configure { |c| c.tool_roots = %w[support_tools] }
```

A shared directory is simply one named in more than one adapter's `tool_roots`. An adapter with no `tool_roots` (empty default) is purely declaration-driven — it only gets tools that explicitly name it.

This is the cohesive shape: an adapter's entire setup — its behavioral config *and* the directories it exposes — reads in one block, rather than being split between the adapter's module and a central `Axn.config.tool_paths` map. It also matches the ownership boundary: an adapter declaring "I consume `agent_tools`" is an intentional statement, not a derived list.

### The registry aggregates roots lazily

`register_tool_adapter` grows an **optional trailing positional** config source so the registry can read each adapter's roots. The adapter registers itself from its own module body, so the source is just `self`:

```ruby
# inside the adapter's own module (e.g. Axn::OpenAPI):
Axn.register_tool_adapter(:openapi, self)   # registry reads self.config.tool_roots lazily
Axn.register_tool_adapter(:some_adapter)    # source omitted → declaration-driven only, no directory roots
```

A positional (not a kwarg) is deliberate: the source is the only payload registration will ever carry — there is no other per-adapter registration metadata today or anticipated — and passing `self` from the adapter's own module is self-evident, so a named kwarg buys nothing over the positional and an options bag would be premature. Omitting it is a first-class state: an adapter with no config source is purely declaration-driven (empty directory grant).

An adapter becomes a registered *thing* with a config source rather than a bare symbol in a Set. At `ensure_loaded!` time (already lazy), the registry iterates registered adapters, reads each one's current `tool_roots`, and computes a tool's directory grant as the set of adapters whose roots contain that tool's `const_source_location`. Reading roots lazily is required: `tool_roots` is set in the app initializer, which runs after gem load / adapter registration.

`member?(klass, adapter)` becomes: `adapter` is in the union of the directory grant and the declaration grant for `klass`, and `adapter` is not in the tool's `except` set. `tool false` still short-circuits to no membership before any of this.

### DSL semantics

| Spelling | Meaning |
|---|---|
| *(no `tool` call)* | Membership from directory grant only |
| `tool` (bare) | All registered adapters (unchanged) |
| `tool :openapi` | **Adds** openapi to the directory grant (union) — *reversed from today's "replaces"* |
| `tool mcp: { … }` | Adds mcp (union) and configures it; unchanged sugar over `configure(:mcp)` |
| `tool except: :ruby_llm` | Directory/declaration grant **minus** ruby_llm |
| `tool :openapi, except: :ruby_llm` | (grant ∪ openapi) − ruby_llm |
| `tool false` | No membership anywhere (unchanged; cannot combine with adapters/`name:`/bags/`except:`) |

The one behavioral reversal: an explicit adapter list now **adds to** the directory grant instead of **replacing** it. This is what lets a tool in the shared `agent_tools` directory say `tool :openapi` and serve all three adapters, without restating `mcp, ruby_llm` (which would go stale when the directory mapping changes).

### The three openapi shapes fall out of one mechanism

- **All of a shared dir** → list that dir in the adapter's `tool_roots` (directory grant).
- **A subset** → don't give the adapter that root; put `tool :openapi` on the specific tools (declaration grant adds openapi on top of their directory-granted mcp/ruby_llm).
- **All-but-a-few** → give the adapter the shared root, then `tool except: :openapi` on the handful to exclude.

## Decisions

### Union, not replace (the pivotal fork)

Declaration grants **add** to the directory grant. Rejected alternative — keep today's "an explicit `tool` declaration is the complete truth, overriding the directory": simpler to state ("what you declare is exactly what you get") but forces the subset-reuse case to restate the directory's whole adapter set inline, which drifts the day the directory mapping changes. The subset-reuse requirement is fundamentally "add HTTP to *these already-shared* tools," and only union expresses that without restatement.

### Roots owned per-adapter, not a central map

Rejected alternatives — a central `Axn.config.tool_paths` map, either root-keyed (`{ "agent_tools" => %i[mcp ruby_llm] }`) or adapter-keyed (`{ mcp: %w[agent_tools] }`). Root-keyed audits well ("who sees this dir?" on one line) but scatters an adapter's configuration across the core config *and* its own module, against the established one-module-per-adapter pattern. The global "who sees this directory?" view is recovered through reflection (`Axn.tools_for(:data_shifter_web)` enumerates the resolved truth), which for the PRO-2937 curation/audit story is better than a declared-intent map — it reflects what is actually exposed. Cost accepted: a shared dir is named in two gems' blocks and could drift; each naming is an intentional ownership statement, so this is tolerable.

### Per-adapter opt-out via `except:`

`except:` (single adapter or list) subtracts from the union, applied last. It composes with positional adapters and bags. It cannot combine with `tool false` (which is the canonical "off everywhere" and short-circuits). `except:` naming a non-member is a harmless no-op.

### No migration path

All downstream gems have in-flight, not-yet-landed work; they update in sync with this release. Consequences accepted as breaking, no deprecation shims:

- `Axn.config.tool_paths` (the global list) is **removed**. The directory→adapter mapping moves to per-adapter `tool_roots`.
- An explicit `tool` adapter list changes from *replace* to *add* (union) semantics.
- `register_tool_adapter` gains an optional trailing positional config-source argument.

## Cross-cutting details

- **Security guard travels with the setter.** The existing broad-path validation (`broad_tool_path?`, `BROAD_TOOL_PATH_LEAVES`, the `..`/blocklist rejection in `configuration.rb`) stays in core and is applied by every adapter's `tool_roots=` setter, so no adapter can widen a root to `app/`, `.`, or a traversal. Core keeps the validation helper; only the global `tool_paths` *setting* is removed.
- **Shared setting shape.** The `tool_roots` overridable setting is identical for every adapter, so core exposes it as a shared concern (mixin/helper) that each adapter's global config includes, rather than each gem redefining it. This keeps the validation and default (`[]`) consistent.
- **Enumeration invariants unchanged.** `tools_for` still sorts by `tool_name(adapter)` and enforces per-adapter name uniqueness (`_assert_unique_tool_names!`). Only the membership predicate feeding it changes.
- **Empty roots is a first-class state.** An adapter with `tool_roots = []` is declaration-driven only. This is the expected shape for an opt-in adapter (a minimal data_shifter_web that curates purely by `tool :data_shifter_web`, or an openapi that only takes a hand-picked subset).

## Downstream impact

- **axn-mcp, axn-ruby_llm** — set a default `tool_roots` (the conventional shared agent-tools directory) and pass `config_source:` when registering; update READMEs to show `tool_roots` and the union/`except` semantics.
- **os-app** — point mcp/ruby_llm `tool_roots` at the real shared-tools directory (`app/actions/tools/` or a restored `agent_tools` if the autoload issue is separately fixed); no more reliance on the magic default path.
- **Future adapters (PRO-2936 openapi, PRO-2937 data_shifter_web)** — register with their own `config_source` and either a dedicated `tool_roots` (data_shifter_web's curated dir) or empty roots plus per-tool opt-in (openapi subset).

## Non-goals

- Reworking per-class/per-adapter *behavioral* config (`configure(:mcp)`, `tool mcp: {…}` bags) — unchanged; only membership and directory mapping move.
- Adapter *groups/aliases* (addressing mcp+ruby_llm by one name). The union model plus shared directory roots covers the shared-population case without a grouping primitive; revisit only if a real need appears.
- Fixing the `lib/` autoload resolution bug — orthogonal; this design removes the dependency on that specific directory being magic, but does not require restoring `lib/agent_tools`.
