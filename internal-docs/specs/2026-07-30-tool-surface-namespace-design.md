# Move the tool surface behind `Axn::Tools` (PRO-3005)

Linear: https://linear.app/teamshares/issue/PRO-3005/axn-move-the-tool-surface-behind-axntools-before-the-api-is-frozen-by

## Why

The top-level `Axn` module accumulated a tool-specific vocabulary: of the methods a user or gem can call on it, five are about tools, one more (`owns_failure_exception?`) is for gem implementors rather than users, and only three are the library's own. Nothing is released, so moving them costs three unreleased adapter gems a handful of one-line changes. After a release these names are permanent and `Axn.tools_for` versus `Axn::Tools.for` stops being a taste question and becomes a deprecation cycle.

The goal is a top-level module holding only what a **user** needs (`config`, `configure`, `included`), with everything an **implementor** needs behind the namespace that says so — `Axn::Tools` for the registry surface, `Axn::Extensions` for the extension-author surface.

`Axn::Tools` is not becoming public: all three adapter gems already `extend Axn::Tools::AdapterRoots` in their `lib/` (two of them also instantiate `Axn::Tools::Invoker`), and their specs assert on `Axn::Tools::Registry.adapters`. This gives an already-public namespace the call surface it should have had, exactly as `Axn::Extensions` holds both methods and child constants.

## The surface

| before | after |
| -- | -- |
| `Axn.tools_for(adapter, all_versions: false)` | `Axn::Tools.for(adapter, all_versions: false)` |
| `Axn.versions_for(adapter, tool_name)` | `Axn::Tools.versions(adapter, tool_name)` |
| `Axn.register_tool_adapter(key, source = nil)` | `Axn::Tools.register_adapter(key, source = nil)` |
| `Axn.validate_tool_contracts!` (arrives in #208) | `Axn::Tools.validate_contracts!` |
| `Axn._registered_tool_adapter!(adapter)` | `Axn::Tools._registered_adapter!(adapter)` (private) |
| — | `Axn::Tools.adapters` (new) |
| `Axn.owns_failure_exception?(exception)` | `Axn::Extensions.owned_failure?(exception)` |

Top-level `Axn` is left with `config`, `configure`, and `included`.

**No aliases and no delegating shims.** Nothing is released; a shim is the thing that becomes permanent.

### Decisions and why

**`.for` over `.tools_for` / `.enumerate`.** `Axn::Tools.for(:mcp)` is the English sentence the call already is, and it's the only candidate that doesn't stutter — the stutter is what this ticket exists to remove. `for` is a keyword only in statement position; as a method name it dispatches normally (including via `public_send`), and `URI.for` is a stdlib precedent. The one cost is that a bare `Tools.for` read apart from its argument is momentarily ambiguous with the loop keyword; every real call site carries the argument.

**`.versions` over `.versions_for`.** Once `.for` owns the enumeration slot, a `_for` suffix elsewhere is a leftover from needing to disambiguate on a crowded top-level module. `.for(:mcp)` / `.versions(:mcp, "approve_loan")` read as a pair. Returns the `VersionGroup` (`.all` ascending, `.latest`) unchanged.

**`Axn::Tools.adapters` is added.** The registered keys. The registered-adapter guard already computes this set on every call, `Registry.adapters` already returns a fresh Set rather than internal state, and it is the read-companion to `register_adapter`. Three downstream spec suites reach through to `Registry` for it today.

`Registry.adapter_config_source` is deliberately **not** mirrored — that is registry wiring, and the downstream specs asserting on it are testing exactly that.

**`owned_failure?` moves to `Axn::Extensions`, and is renamed.** That module's own docstring states the charter: "the extension-author surface: 'for gems building on axn,' distinct from `Axn::Internal` (private) and the user-facing DSL." The predicate is asked by the executor (deciding whether to stamp a resolved presentation) and by adapter authors (deciding whether `exception.message` is safe to show a client) — tools are only one caller. Its new neighbor `Extensions.swallowable?` is the same shape answering the same kind of question, so it takes the same adjective-style name; `owned failure` is already the phrase the docs recipe uses. It has **zero** call sites in any downstream gem, so the rename is free. The docstring keeps carrying the distinction that matters: a foreign exception reclassified via `fails_on` travels axn's failure path but is *not* owned, and its `#message` is a technical cause not to be leaked.

Two homes were rejected. `Axn::Failure.owns?` would misrepresent scope — the predicate is true for a user-facing `ValidationError`, which is a `ContractViolation`, not an `Axn::Failure`. A new `Axn::Exceptions` module would be a namespace with one occupant; `exceptions.rb` defines its classes directly under `Axn`.

## Related naming cleanup

Three items in the same vocabulary family, found by scanning the tool-adjacent surface.

**1. `tool_paths` outlived its setting.** PRO-2948 replaced the `tool_paths` setting with per-adapter `tool_roots`, but the name survives in `Axn::Configuration`: `broad_tool_path?`, `normalize_tool_path`, `_broad_tool_path_reason`, and the constants `TOOL_PATHS_BLOCKLIST` / `BROAD_TOOL_PATH_LEAVES` — plus comments describing "a `tool_paths` entry," a setting a reader can no longer find. Every caller is validating a `tool_roots` entry. Rename to `broad_tool_root?`, `normalize_tool_root`, `_broad_tool_root_reason`, `TOOL_ROOTS_BLOCKLIST`, `BROAD_TOOL_ROOT_LEAVES`, and correct the comments. Zero downstream references.

**2. `Registry` speaks the old vocabulary.** With the facade at `.for` / `.versions`, `Registry.tools_for` / `Registry.versions_for` would leave the delegation target named after the surface it replaced. Rename to `Registry.members(adapter, all_versions: false)` and `Registry.version_group(adapter, tool_name)`, matching the membership language the file already uses throughout (`member?`, `_version_groups`). The facade then reads as intent over storage rather than a same-name pass-through. Core-only.

**3. `Axn::Core::Tools` → `Axn::Core::ToolDeclaration`.** The class-side DSL module has one reference in `lib/` (`core.rb:70`) plus `AGENTS.md:37` — which is where the collision bites, since that line must now name both `Axn::Core::Tools` and `Axn::Tools` in one sentence about two different things. `ToolDeclaration` fits sibling style (`Core::Versioning`, `Core::SemanticHints`, `Core::Tagging`). File moves to `lib/axn/core/tool_declaration.rb`; the specs covering it (`spec/axn/core/tool_dsl_spec.rb`, `tool_name_spec.rb`) keep their names, which already describe behavior rather than the module.

**Checked and left alone:** `Tools::Invoker` (adapters instantiate it directly; out of scope per the ticket), `Tools::AdapterRoots`, `Tools::VersionGroup`, `Registry.adapter_config_source`, the author-facing `tool` / `tool_name` / `tool_version` / `tool_roots` vocabulary (consistent, and documented in three gems), `Extensions.swallowable?` / `.best_effort` / `.config`, and `Axn.included` (a Ruby hook).

## Migration surface

**axn-core.** `lib/axn.rb` (remove the five methods; keep `config`/`configure`/`included` and the `Registry.register_class` call inside `included`), a new `lib/axn/tools.rb` holding the facade, `lib/axn/extensions.rb` (gains `owned_failure?`), `lib/axn/core/executor.rb:390` (its one caller), `lib/axn/tools/registry.rb` (method renames + the `tool_root` callers), `lib/axn/configuration.rb`, `lib/axn/tools/adapter_roots.rb`, `lib/axn/core/tools.rb` → `tool_declaration.rb` with `lib/axn/core.rb:70`, and `lib/axn/rails/engine.rb` (the `after_initialize` / `to_prepare` calls, once #208 lands).

Specs: `spec/axn/tools/registry_spec.rb`, `spec/support/tool_adapter_helpers.rb`, `spec/axn/core/configuration_spec.rb`, `spec_rails/dummy_app/spec/axn/tools_eager_load_spec.rb`, and #208's `spec/axn/tools/validate_tool_contracts_spec.rb`. `spec/spec_helper.rb:35` keeps calling `Registry.reset_adapters!` — that is test wiring, not the public surface.

Docs: `docs/recipes/authoring-tool-adapters.md` (teaches the old names throughout), `docs/recipes/gem-configuration.md`, `docs/reference/configuration.md:91`, `docs/reference/factory.md:113`, `AGENTS.md:37` and `:55` (the namespace-policy line must now describe `Tools` as a namespace *and* a call surface), and `AGENTS-tool-adapters.md` (several).

**CHANGELOG.** Everything affected sits under the unreleased `## 0.1.0-alpha.5` heading, so edit those entries in place to name the new API. Do not add `[BREAKING]` rename entries — an unreleased changelog is a description of the release being assembled, not a history of how it was assembled.

**Downstream, all unreleased and all pinned to axn by git revision**, so each migrates on its own bump:

| gem | `lib/` | `spec/` | prose |
| -- | -- | -- | -- |
| axn-mcp | `mcp.rb:92`, `mcp/wrap.rb:32` | 3 lines in `registry_spec.rb` | README, AGENTS.md, CHANGELOG |
| axn-openapi | `openapi.rb:60`, `openapi.rb:75` | 1 line in `registration_spec.rb` | README, AGENTS-consuming.md, CHANGELOG, internal-docs |
| axn-ruby_llm | `ruby_llm.rb:28`, `ruby_llm/tool_adapter.rb:157` | 2 lines in `tool_adapter_spec.rb` | README, CHANGELOG |
| axn-webhooks | none | none | one design-doc mention |

`slack_sender` and `data_shifter` have no call sites (data_shifter's apparent hits are a vendored axn copy in its bundle path). No gem calls `owns_failure_exception?` at all.

## Sequencing

1. Rebase this branch once #208 (PRO-2995) merges, so `validate_tool_contracts!` exists to be renamed rather than added twice.
2. Land axn-core: the facade, the `Extensions` move, the three cleanups, docs, CHANGELOG edits.
3. Migrate the three adapter gems, each on its own axn revision bump.
4. Cut `0.1.0-alpha.5` only after the core PR merges.

## Not in scope

`Axn::Tools::Registry`, `Invoker`, `AdapterRoots`, and `VersionGroup` stay where they are — implementation constants that adapters reach through the public methods, already covered by `AGENTS.md`'s namespace policy. No behavior changes anywhere: this is a rename of the surface and its vocabulary.
