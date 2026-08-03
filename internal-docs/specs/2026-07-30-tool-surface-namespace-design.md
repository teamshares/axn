# Move the tool surface behind `Axn::Tools` (PRO-3005)

Linear: https://linear.app/teamshares/issue/PRO-3005/axn-move-the-tool-surface-behind-axntools-before-the-api-is-frozen-by

## Why

The top-level `Axn` module accumulated a tool-specific vocabulary: of the methods a user or gem can call on it, five are about tools, one more (`owns_failure_exception?`) is for gem implementors rather than users, and only three are the library's own. Nothing is released, so moving them costs the unreleased adapter gems a handful of one-line changes. After a release these names are permanent and `Axn.tools_for` versus `Axn::Tools.for` stops being a taste question and becomes a deprecation cycle.

The goal is a top-level module holding only what a **user** needs (`config`, `configure`, `included`), with everything an **implementor** needs behind the namespace that says so — `Axn::Tools` for the tool surface, `Axn::Extensions` for the extension-author surface, `Axn::Internal` for axn's own mechanisms.

`Axn::Tools` is not becoming public: all three adapter gems already `extend Axn::Tools::AdapterRoots` in their `lib/` (two of them also instantiate `Axn::Tools::Invoker`), and their specs assert on `Axn::Tools::Registry.adapters`. This gives an already-public namespace the call surface it should have had, exactly as `Axn::Extensions` holds both methods and child constants.

The accumulation continued while #208 (PRO-2995) was in review, which is itself the argument for doing this now: that PR added a public tool-named *constant* (`Axn::InvalidToolContract`) and privatized four underscore-named singleton methods on `Axn`, leaving a comment at `lib/axn.rb:212` that says "PRO-3005 re-homes them all under `Axn::Tools`."

## The surface

| before | after |
| -- | -- |
| `Axn.tools_for(adapter, all_versions: false)` | `Axn::Tools.for(adapter, all_versions: false)` |
| `Axn.versions_for(adapter, tool_name)` | `Axn::Tools.versions(adapter, tool_name)` |
| `Axn.register_tool_adapter(key, source = nil)` | `Axn::Tools.register_adapter(key, source = nil)` |
| `Axn.validate_tool_contracts!` | `Axn::Tools.validate_contracts!` |
| `Axn::InvalidToolContract` | `Axn::Tools::InvalidContract` |
| `Axn.owns_failure_exception?(exception)` | `Axn::Extensions.owned_failure?(exception)` |
| `Axn::Reflection::UnserializableValue` | `Axn::Extensions::Serialization::UnserializableValue` |
| `Axn._registered_tool_adapter!` (private) | `Axn::Tools._registered_adapter!` (private) |
| `Axn._named_invalid_tool_contract` (private) | `Axn::Tools._named_invalid_contract` (private) |
| `Axn._reported_message` / `_raw_reported_message` (private) | `Axn::Internal::ExceptionMessage.of(error)` |
| — | `Axn::Tools.adapters` (new) |
| — | `Axn.config.default_async?` (new) |

Top-level `Axn` is left with `config`, `configure`, and `included`.

**No aliases and no delegating shims.** Nothing is released; a shim is the thing that becomes permanent.

## Decisions and why

**`.for` over `.tools_for` / `.enumerate`.** `Axn::Tools.for(:mcp)` is the English sentence the call already is, and it's the only candidate that doesn't stutter — the stutter is what this ticket exists to remove. `for` is a keyword only in statement position; as a method name it dispatches normally (including via `public_send`), and `URI.for` is a stdlib precedent. The one cost is that a bare `Tools.for` read apart from its argument is momentarily ambiguous with the loop keyword; every real call site carries the argument.

**`.versions` over `.versions_for`.** Once `.for` owns the enumeration slot, a `_for` suffix elsewhere is a leftover from needing to disambiguate on a crowded top-level module. `.for(:mcp)` / `.versions(:mcp, "approve_loan")` read as a pair. Returns the `VersionGroup` (`.all` ascending, `.latest`) unchanged.

**`Axn::Tools.adapters` is added.** The registered keys. The registered-adapter guard already computes this set on every call, `Registry.adapters` already returns a fresh Set rather than internal state, and it is the read-companion to `register_adapter`. Three downstream spec suites reach through to `Registry` for it today. `Registry.adapter_config_source` is deliberately **not** mirrored — that is registry wiring, and the downstream specs asserting on it are testing exactly that.

**`Axn::Tools::InvalidContract`, defined in `exceptions.rb`.** The first tool-specific constant on the top-level namespace, so it also settles that `Axn::Tools` holds the tool surface's exceptions as well as its calls — it should; a namespace that holds the calls but not their errors sends half the surface elsewhere. It stays *defined* in `lib/axn/exceptions.rb` with every other exception class, namespaced in place, exactly as `Reflection::UnserializableValue` already is there. Opening `module Tools` early in that file is load-order safe (it only creates the module), but the existing comment above the class — which explains why the renderer reference resolves at call time, and states that the only code able to construct this error is `Axn.validate_tool_contracts!` — must be updated to name `Axn::Tools.validate_contracts!`.

**`owned_failure?` moves to `Axn::Extensions`, and is renamed.** That module's own docstring states the charter: "the extension-author surface: 'for gems building on axn,' distinct from `Axn::Internal` (private) and the user-facing DSL." The predicate is asked by the executor (deciding whether to stamp a resolved presentation) and by adapter authors (deciding whether `exception.message` is safe to show a client) — tools are only one caller. Its new neighbor `Extensions.swallowable?` is the same shape answering the same kind of question, so it takes the same adjective-style name; `owned failure` is already the phrase the docs recipe uses. It has **zero** call sites in any downstream gem, so the rename is free. The docstring keeps carrying the distinction that matters: a foreign exception reclassified via `fails_on` travels axn's failure path but is *not* owned, and its `#message` is a technical cause not to be leaked.

Two homes were rejected. `Axn::Failure.owns?` would misrepresent scope — the predicate is true for a user-facing `ValidationError`, which is a `ContractViolation`, not an `Axn::Failure`. A new `Axn::Exceptions` module would be a namespace with one occupant; `exceptions.rb` defines its classes directly under `Axn`.

**`UnserializableValue` moves to `Extensions::Serialization`.** Its own docstring already describes it as adapter-facing ("so a serializing adapter (axn-openapi, axn-mcp, axn-ruby_llm) fails the call"), and `Extensions::` is the only namespace a gem should name. This is the *entire* downstream dependency on `Reflection::` — measured on the in-flight branches, nothing downstream calls `Values` or `Schema`, and both axn-mcp and axn-openapi already render through `Extensions::Serialization.render`. 92 references across 12 files, concentrated (61 in `spec/axn/reflection/values_spec.rb`, 13 in `values.rb`), so mostly mechanical. No alias.

### The private methods are a re-parenting, not a rename

#208's `dc04194f` made four underscore-named singleton methods on `Axn` genuinely `private`, so each must now travel with its caller or be explicitly re-published. The message helpers are a **chain three deep**, not the pair the ticket describes: `_named_invalid_tool_contract` → `_reported_message` → `_raw_reported_message`.

* `_registered_tool_adapter!` → `Axn::Tools._registered_adapter!`, private, travelling with its only callers (`.for`, `.versions`).
* `_named_invalid_tool_contract` → `Axn::Tools._named_invalid_contract`, private, travelling with `validate_contracts!`.
* `_reported_message` + `_raw_reported_message` → **`Axn::Internal::ExceptionMessage.of(error)`**, with the raw read as its own private internals.

`ExceptionMessage` is the right home because it mirrors `Axn::Internal::ClassName.of(value)` and does the same job: a hostile-safe degradation read for text being built *about* an exception, where every dispatch is a method the exception's class may override. `ClassName.of(error)` / `ExceptionMessage.of(error)` are the pair a reader expects to find together.

It gets its own file, `lib/axn/internal/exception_message.rb`, alongside the seventeen other `Internal::` modules — *not* a spot beside `ClassName` in `exceptions.rb`. `ClassName` lives there because the exception classes in that file need it during a standalone load of one entry point; nothing in `exceptions.rb` needs `ExceptionMessage`. Its reference to the renderer (`PropertyNames.renderable_label`) resolves at call time, which is sound for the same reason the comment above `InvalidToolContract` already gives about its own: the only code that reaches it lives in the fully-loaded gem. Re-publishing inside `Internal::` costs nothing in API terms, which is precisely what that namespace is for — so nothing is made public to satisfy a call site, and `dc04194f`'s privatization is preserved rather than partly undone.

### `Axn.config.default_async?`

`axn-webhooks` reads `Axn.config._default_async_adapter` at `dispatch.rb:66`, `outbound/deliver.rb:105`, and `outbound/emit.rb:51` — all three as `!!…`, asking one boolean: *is a default async adapter configured?* The trio of `_default_async_*` readers is public deliberately (there is a comment at `configuration.rb:177` saying so and naming axn-webhooks), because core itself reads all three across files with an explicit receiver (`lib/axn/async.rb:71,72,73,89,188,190`), so they cannot simply become private.

So publish the question actually being asked: `Axn.config.default_async?`, matching the `<name>?` predicate convention from PRO-2888. webhooks' three sites migrate to it on its next bump, the trio stays public-but-underscored for core's own reads, and no gem names an underscore method. The writer (`set_default_async`) is already public and unchanged.

## Related naming cleanup

Three items in the same vocabulary family, found by scanning the tool-adjacent surface.

**1. `tool_paths` outlived its setting.** PRO-2948 replaced the `tool_paths` setting with per-adapter `tool_roots`, but the name survives in `Axn::Configuration`: `broad_tool_path?`, `normalize_tool_path`, `_broad_tool_path_reason`, and the constants `TOOL_PATHS_BLOCKLIST` / `BROAD_TOOL_PATH_LEAVES` — plus comments describing "a `tool_paths` entry," a setting a reader can no longer find. Every caller is validating a `tool_roots` entry. Rename to `broad_tool_root?`, `normalize_tool_root`, `_broad_tool_root_reason`, `TOOL_ROOTS_BLOCKLIST`, `BROAD_TOOL_ROOT_LEAVES`, and correct the comments. Zero downstream references.

**2. `Registry` speaks the old vocabulary.** With the facade at `.for` / `.versions`, `Registry.tools_for` / `Registry.versions_for` would leave the delegation target named after the surface it replaced. Rename to `Registry.members(adapter, all_versions: false)` and `Registry.version_group(adapter, tool_name)`, matching the membership language the file already uses throughout (`member?`, `_version_groups`). The facade then reads as intent over storage rather than a same-name pass-through. Core-only.

**3. `Axn::Core::Tools` → `Axn::Core::ToolDeclaration`.** The class-side DSL module has one reference in `lib/` (`core.rb:70`) plus `AGENTS.md:37` — which is where the collision bites, since that line must now name both `Axn::Core::Tools` and `Axn::Tools` in one sentence about two different things. The namespace policy below makes it sharper still: `Tools::X` *is* the tool surface, so a second `Tools` holding the author-facing DSL directly contradicts it. `ToolDeclaration` fits sibling style (`Core::Versioning`, `Core::SemanticHints`, `Core::Tagging`). File moves to `lib/axn/core/tool_declaration.rb`; the specs covering it (`spec/axn/core/tool_dsl_spec.rb`, `tool_name_spec.rb`) keep their names, which already describe behavior rather than the module.

**Checked and left alone:** `Tools::Invoker` (adapters instantiate it directly; out of scope per the ticket), `Tools::AdapterRoots`, `Tools::VersionGroup`, `Registry.adapter_config_source`, the author-facing `tool` / `tool_name` / `tool_version` / `tool_roots` vocabulary (consistent, and documented in three gems), `Extensions.swallowable?` / `.best_effort` / `.config`, and `Axn.included` (a Ruby hook).

## Namespace policy (into `AGENTS.md`)

The rule, written down so the next addition follows a rule instead of copying a precedent:

* `Internal::X` — internal **and generically useful**: a value-level mechanism any layer can use, with no presence in the action's surface. `CycleGuard`, `ShapeGraph`, `NativeMethods`, `Timing`, `Callable`, `ClassName`, and now `ExceptionMessage`.
* `Core::X` — internal **and contextual to one topic**: a layer extended onto the action class, named for what the *author* writes. `Contract`, `Hooks`, `Tagging`, `Logging`, `AmbientContext`, `ToolDeclaration`.
* `Core::Contract::X` — machinery one layer owns and that is meaningless outside it. `FieldConfig`, `ShapeConfig`, `ShapeDeclaration`, `Redaction`.
* `Extensions::X` — axn **or downstream gems**. The only namespace a gem should name. Adding to it is adding to the public API.
* `Tools::X` — the tool surface: its calls *and* its exceptions.
* `Reflection::` — deliberately **unclaimed**, vacated by the companion PR below and left free for a future public reflection API.

**A namespace is not a substitute for `private`.** #208 found that `Axn::Configurable` is `extend`ed onto each consuming gem's own module, so its underscore-named methods were public methods of `Axn::MCP`, `Axn::OpenAPI`, `Axn::Webhooks`, `Axn::RubyLLM` and `DataShifter` — an "internal" namespace guaranteed nothing. 37 methods were privatized in `dc04194f`; 13 stay public with a recorded per-method reason.

## Scope: two PRs, split on "can a consumer see it"

**This PR — everything consumer-visible.** The tool surface, `Tools::InvalidContract`, the private re-parenting (including `Internal::ExceptionMessage`), `Extensions::Serialization::UnserializableValue`, `Axn.config.default_async?`, the three cleanups, the namespace policy, docs, and CHANGELOG edits.

**Companion PR, immediately after — vacate `Axn::Reflection`.** `Axn::Reflection::X` → `Axn::Internal::Reflection::X`, files to `lib/axn/internal/reflection/`. 195 references across 36 files; zero consumer impact once `UnserializableValue` has left, since that exception is the entire downstream dependency on the namespace.

Moving `PropertyNames` alone (as PRO-3005 originally proposed) would not vacate anything: `Reflection::` holds **seven** modules — `Coercion`, `ResolvedSubfields`, `SubfieldContradictions`, `SubfieldTree`, `PropertyNames`, `Values`, `Schema` — so relocating one pays a 56-reference sweep and still leaves axn squatting on a public-looking name holding nothing but internals. Vacating wholesale is one mechanical rename reviewable as a pure rename, and it *dissolves* the `PropertyNames → Core::Contract::` item rather than doing it: once everything is under `Internal::`, redistributing by topic is a pure internal reorganization with no API implication, free to happen later alongside the `core/contract/` consolidation. Distributing all seven by topic now would be seven judgment calls — and `Values`/`Schema` are projection machinery, not contract machinery — for the same API outcome.

Keeping the split means review attention lands on the part with judgment in it rather than on a 195-line rename.

### Out of scope, tracked elsewhere

* **Tracing seam** — PRO-3017 (`Axn.config.tracer`) is already In Review as PR #209. It also touches `lib/axn/configuration.rb`, where this PR renames the `tool_path` helpers: a trivial conflict for whichever lands second. #209 cites this ticket's namespace policy as its justification, so recording the policy is load-bearing for it.
* **Readability items from #208** — relocating the hardening-doctrine prose out of the guard files (~900 lines of comment, targeting the repo's 27% median density) and moving `FieldConfig` / `ShapeConfig` / `FieldOptionality` / `ShapeBuilder` into `core/contract/`. Both are readability, not a frozen surface, and would bury this diff.

## Migration surface

**axn-core.** `lib/axn.rb` (remove the tool methods and the private helpers; keep `config`/`configure`/`included` and the `Registry.register_class` call inside `included`), a new `lib/axn/tools.rb` holding the facade, `lib/axn/extensions.rb` (gains `owned_failure?`), `lib/axn/exceptions.rb` (`Tools::InvalidContract`, `Extensions::Serialization::UnserializableValue`, `Internal::ExceptionMessage`), `lib/axn/core/executor.rb` (the `owned_failure?` caller), `lib/axn/tools/registry.rb`, `lib/axn/configuration.rb` (`tool_root` renames plus `default_async?`), `lib/axn/tools/adapter_roots.rb`, `lib/axn/core/tools.rb` → `tool_declaration.rb` with `lib/axn/core.rb:70`, `lib/axn/reflection/values.rb` and `schema.rb` (the exception's new name), and `lib/axn/rails/engine.rb` (the `after_initialize` / `to_prepare` calls).

Specs: `spec/axn/tools/registry_spec.rb`, `spec/axn/tools/validate_tool_contracts_spec.rb`, `spec/support/tool_adapter_helpers.rb`, `spec/axn/core/configuration_spec.rb`, `spec/axn/reflection/values_spec.rb`, `spec/axn/extensions/serialization_spec.rb`, `spec_rails/dummy_app/spec/axn/tools_eager_load_spec.rb`, and `spec_rails/dummy_app/spec/axn/reflection/values_spec.rb`. `spec/spec_helper.rb:35` keeps calling `Registry.reset_adapters!` — test wiring, not the public surface.

`spec/support/constant_references.rb` needs no edit — it derives every constant a file references from its parse tree rather than listing them, so it cannot go stale. Its consumer, `spec/axn/standalone_require_spec.rb`, is the guard that will catch a load-order mistake in these moves: a constant referenced by a file but not reachable when that file is loaded alone.

Docs: `docs/recipes/authoring-tool-adapters.md` (teaches the old names throughout), `docs/recipes/gem-configuration.md`, `docs/reference/configuration.md:91`, `docs/reference/factory.md:113`, `AGENTS.md:37` and `:55`, and `AGENTS-tool-adapters.md`. `docs/.vitepress/dist/` hits are build artifacts — ignore.

**CHANGELOG.** Everything affected sits under the unreleased `## 0.1.0-alpha.5` heading, so edit those entries in place to name the new API. Do not add `[BREAKING]` rename entries — an unreleased changelog describes the release being assembled, not how it was assembled.

**Downstream, all unreleased and all pinned to axn by git revision**, so each migrates on its own bump:

| gem | tool surface | other |
| -- | -- | -- |
| axn-mcp | `mcp.rb:92`, `mcp/wrap.rb:32`; 3 lines in `registry_spec.rb` | `UnserializableValue`: `serializer_spec.rb:102,107`, `wrap_spec.rb:357,361,368` (two are `it` descriptions), comments at `mcp.rb:35`, `wrap.rb:67`, `server_integration_spec.rb:198,307` |
| axn-openapi | `openapi.rb:60`, `openapi.rb:75`; 1 line in `registration_spec.rb` | `UnserializableValue`: comments only — `openapi.rb:29`, `dispatcher.rb:95,120` |
| axn-ruby_llm | `ruby_llm.rb:28`, `ruby_llm/tool_adapter.rb:157`; 2 lines in `tool_adapter_spec.rb` | `UnserializableValue`: `tool_adapter.rb:105` (the `rescue` list) |
| axn-webhooks | none | `default_async?`: `dispatch.rb:66`, `outbound/deliver.rb:105`, `outbound/emit.rb:51` |
| slack_sender | none | none |
| data_shifter | none | none |

**Measure downstream on the in-flight branches, not `main`** — and re-measure at handoff time, because a branch that was in flight may have merged. PRO-3005's snippet for axn-openapi named `kali/clean-serialization` and a comment in `lib/axn/openapi/serializer.rb`; as of 2026-08-03 that branch is **merged into main** (its tip commit is `refactor!: … drop Serializer`) and `serializer.rb` no longer exists, so the real targets are the three comments listed above. axn-mcp is on `kali/pro-2770-axn-mcp-adopt-axn-configuration-dsl`, axn-ruby_llm on `kali/pro-2771-axn-ruby_llm-adopt-axn-configuration-dsl`, axn-webhooks and axn-openapi on `main`.

axn-ruby_llm's `spec/axn/ruby_llm/ask_spec.rb:550` stubs `Axn::Internal::Tracing.tracer` — the only place any gem reaches into `Axn::Internal::`. That belongs to PRO-3017's handoff, not this one, but the two snippets land in the same session and should be given together.

**Sweep method and result.** Every consumer repo was grepped for the full rename set — `owns_failure_exception`, `tools_for`, `register_tool_adapter`, `versions_for`, `validate_tool_contracts`, `broad_tool_path`, `normalize_tool_path`, `TOOL_PATHS_BLOCKLIST`, `BROAD_TOOL_PATH_LEAVES`, `Core::Tools` — as bare substrings rather than `Axn.`-qualified, over `.rb`/`.rake`/`.erb`/`.md`/`.gemspec`, excluding vendored and bundled paths. Beyond the axn-prefixed gems: `slack_sender`, `data_shifter`, `buyout-app`, `invoice-app`, `teamshares-rails`, `workbench`, and `agents` have zero hits. `os-app` has zero real hits — its 24 matches are all one data-shift method, `role_versions_for_users_with_employment`, incidentally containing `versions_for`, duplicated across seven `.claude/worktrees` copies of the same file. An earlier check reporting `data_shifter` hits was reading a vendored axn copy in its bundle path.

No consumer calls `owns_failure_exception?`, and none references the renamed `Configuration` predicates or constants, so those two cleanups are core-only in fact and not just by intent.

## Sequencing

1. ~~Rebase once #208 (PRO-2995) merges~~ — done; this branch sits on `aafabea4`.
2. Land this PR: the facade, the `Extensions` moves, `Tools::InvalidContract`, the private re-parenting, `default_async?`, the three cleanups, the namespace policy, docs, CHANGELOG edits.
3. Land the companion PR vacating `Axn::Reflection` into `Axn::Internal::Reflection`.
4. Hand each downstream session its snippet; each gem migrates on its own axn revision bump.
5. Cut `0.1.0-alpha.5` only after both core PRs merge.

## Not in scope

`Axn::Tools::Registry`, `Invoker`, `AdapterRoots`, and `VersionGroup` stay where they are — implementation constants that adapters reach through the public methods. `Core::Contract::ShapeDeclaration` and `Core::Contract::Redaction` (extracted in #208) are internal and unaffected. No behavior changes anywhere except the one new predicate: this is a rename of the surface and its vocabulary.
