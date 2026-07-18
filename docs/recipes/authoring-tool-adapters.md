---
outline: deep
---

# Authoring a Tool-Adapter Gem

A **tool-adapter gem** exposes plain [Axn](/reference/class) action classes over some tool/agent transport — [`axn-mcp`](https://github.com/teamshares/axn-mcp) (Anthropic's Model Context Protocol), `axn-ruby_llm` (RubyLLM function-calling), a hypothetical `axn-http_api` (OpenAPI/REST). This page is the reference for **writing one**. If you're an action author *using* an adapter, you don't need it — you write a normal Axn and the adapter wraps it.

The governing idea is **author-once**: a tool is a plain Axn, declared with the ordinary `expects`/`exposes`/`call` contract and nothing transport-specific. The same class is wrapped by every adapter, called directly from Ruby, or enqueued async — all from one definition. An adapter's job is to *project* that class into its transport's native tool object, reading everything it needs from Axn's public reflection surface. It must never require the author to write against the adapter, and never mutate the class in a way that breaks a *different* adapter wrapping the same class. (The retired `Axn::MCP::Tool` base class is the cautionary tale: it overrode `input_schema` to a non-Hash, which broke `Axn::RubyLLM.wrap` on the same class — see [Schema reflection](#schema-reflection).)

Core owns the pieces every adapter shares — membership, naming, schema/value reflection, the config store, the extension registry, the invocation contract. This page maps each to the public API you consume and shows how the two reference gems use it. Read [AGENTS-tool-adapters.md](https://github.com/teamshares/axn/blob/main/AGENTS-tool-adapters.md) for the same material as a dense checklist.

## The two public methods

Every adapter gem exposes the same pair, so a consuming app learns one shape:

```ruby
GemName.tools                    # zero-arg: every registered tool, wrapped
GemName.wrap(axn_class, **opts)  # one Axn class -> the transport's native tool object
```

`.tools` is `Axn.tools_for(:key).map { |a| wrap(a) }` — it must be callable with no arguments, which is why `wrap`'s every option defaults (see [Naming & description](#naming-description)). `wrap` returns the transport-native object: for `axn-mcp` a `::MCP::Tool` subclass, for `axn-ruby_llm` a `::RubyLLM::Tool` subclass.

```ruby
# axn-mcp
module Axn::MCP
  def self.tools = Axn.tools_for(:mcp).map { |axn_class| wrap(axn_class) }
end

# a consumer wiring an MCP server
MCP::Server.new(name: "acme", version: "1", tools: Axn::MCP.tools)
```

## Registration & discovery

**Register the adapter at gem load, from the entry file.** Call `Axn.register_tool_adapter(:key)` where the gem is first required, so the key exists in the process-global registry before any app code enumerates tools:

```ruby
# lib/axn/mcp.rb (required from lib/axn-mcp.rb)
Axn.register_tool_adapter(:mcp)
```

`register_tool_adapter` takes an optional second argument — a config source the registry reads directory roots from (see [Directory-based membership](#directory-based-membership-optional)). Pass it (`Axn.register_tool_adapter(:mcp, self)`) only if your adapter offers directory discovery; omit it otherwise. Re-registering with no source is idempotent and won't wipe a source already supplied.

**`Axn.tools_for(:key)` enumerates the members** — deterministically sorted by [`tool_name`](#naming-description), asserted unique-per-name, with each adapter's tool-root directories eager-loaded first. Two rules follow from *how* it enumerates:

- **Only currently-loaded classes are enumerated.** `tools_for` reflects over classes that are defined *now*; a `tool :key` class that lives outside a tool-root directory must already be `require`d. Enumerate from a point where your app's classes are loaded — `config.after_initialize` or a `to_prepare` block under Rails, **not** a `config/initializers` file (which runs before the app's autoload paths are wired; `tools_for` will warn that discovery is incomplete).
- **A duplicate `tool_name` for one adapter raises.** Two classes deriving the same provider name is only knowable once both are loaded, so `tools_for` fails loudly with a message pointing at `tool name:` to disambiguate, rather than silently clobbering one.

### Membership

A class is a member of adapter `:key` when the registry's `member?` says so. Membership is a **union minus an opt-out**: `(directory grant ∪ declaration grant) − except`.

| Declaration | Effect |
| --- | --- |
| `tool` | Grant **every** registered adapter. |
| `tool :mcp, :ruby_llm` | Add these adapters to whatever the directory already granted. |
| `tool mcp: { … }` | Add `:mcp` (a per-adapter option bag also implies membership). |
| `configure(:mcp) { … }` | A `configure(:key)` bag on the class implies membership in `:key`. |
| residency under a tool-root dir | Directory grant (below). |
| `tool false` | Opt out of **every** adapter (for a helper Axn living under a tool root). |
| `tool except: :ruby_llm` | Narrow: keep every grant *except* this adapter. |

The action author owns these declarations — see [the class reference](/reference/class) and [Configuration for Axn-based Gems](/recipes/gem-configuration#declaring-per-adapter-tool-config-inline). As an adapter author you don't parse them; you call `Axn.tools_for(:key)` and get the resolved set.

### Directory-based membership (optional)

An adapter can let apps expose every tool in a directory without a per-class `tool` line. Mix `Axn::Tools::AdapterRoots` into your config module to get a validated `tool_roots` setting; the registry reads `<adapter>.config.tool_roots` and grants membership to any class whose source file lives under one:

```ruby
module Axn::MCP
  extend Axn::Configurable
  extend Axn::Tools::AdapterRoots     # adds `setting :tool_roots, default: []`
  config_namespace :mcp
end

Axn::MCP.configure { |c| c.tool_roots = %w[agent_tools] }
```

`AdapterRoots.validate!` reuses core's single broad-path guard, so a root that resolves to the project root, escapes via `..`, or ends in a bulk directory (`app`, `actions`) is rejected at assignment — no adapter can accidentally expose every business action. Directory membership is a convenience the reference gems don't currently adopt (they rely on explicit `tool`/`configure`); add it only if directory discovery fits your transport.

## Naming & description

**Names come from `axn_class.tool_name` — never roll your own.** `tool_name` is the canonical, provider-safe derivation (honors an explicit `tool name:`, strips configured prefixes, snake_cases, restricts to `[a-z0-9_]`, and is never blank). The *same Axn must yield the same name across every adapter*, so a client sees one stable identity regardless of transport. When the registry hands you classes, it already resolved per-adapter name overrides; if you need the name yourself, call `axn_class.tool_name` (the zero-arg form) and pass nothing:

```ruby
# axn-mcp/lib/axn/mcp/wrap.rb
tool_name = axn_class.tool_name          # provider-safe, never blank
description(description || axn_class.description)
```

**Description comes from `axn_class.description`**, and `wrap`'s `description:` option should default to it so `.tools` stays zero-arg:

```ruby
def wrap(axn_class, description: nil, name: nil, **)
  description ||= axn_class.description
  # ...
end
```

## Schema reflection

Use the public `axn_class.input_schema` / `axn_class.output_schema` — both plain JSON Schema **Hashes** derived from `expects`/`exposes` (subfields, `model:`, `of:`, `shape:`, `inclusion:`, defaults, unions). Wrap them into your transport's schema object:

```ruby
# axn-mcp
input_schema(axn_class.input_schema)
output_schema(axn_class.output_schema) unless axn_class.external_field_configs.empty?

# axn-ruby_llm
params(axn_class.input_schema)           # ruby_llm has no output-schema concept
```

Three rules keep adapters interoperable:

- **Don't reach into `Axn::Reflection::Schema` internals**, and **never override an Axn's `input_schema` to return a non-Hash.** The class is shared: a non-Hash `input_schema` breaks every *other* adapter wrapping the same class. This is the concrete defect that retired the old `Axn::MCP::Tool` base — wrap the Hash into your transport object in `wrap`, don't redefine the reflection method on the class.
- **`on: :ambient_context` fields are auto-excluded from `input_schema`** (they're framework-supplied, never model input — see [ambient_context](#ambient-context)). You get a clean model-facing schema for free; don't re-add them.
- **Reflection is best-effort and biased *stricter* than runtime** — a call that follows the schema won't be schema-rejected. There is one documented *looser* case: an invalid literal `default:` (`type: :uuid, default: "nope"`) reflects as optional though the omitted call fails at runtime. Surface this caveat to your users; don't try to fight it in the adapter. (A deep subfield under a `model:`/non-object parent has no JSON representation and is omitted with a `logger.warn` — pass it through, don't paper over it.)

## Value serialization

To render a successful `Axn::Result`'s exposed values into a JSON-safe hash, use `Axn::Reflection::Values.serialize_exposed` — don't hand-roll it (it handles Symbol/BigDecimal/Time/`as_json`-vs-`to_h` edge cases so the output validates against the reflected `output_schema`):

```ruby
# axn-mcp/lib/axn/mcp/serializer.rb
exposed = Axn::Reflection::Values.serialize_exposed(result, axn_class.external_field_configs)
```

Pass `axn_class.external_field_configs` (the declared `exposes` configs) as the second argument.

## Per-adapter configuration

Declare adapter settings with `Axn::Configurable` (the same machinery Axn uses internally — full detail in [Configuration for Axn-based Gems](/recipes/gem-configuration)):

```ruby
module Axn::MCP
  extend Axn::Configurable
  config_namespace :mcp
  setting :present_as, default: :structured, one_of: %i[structured message], overridable: true
  setting :title, default: nil, overridable: true
end
```

`config_namespace :mcp` keys per-class overrides under `:mcp`, so two adapters declaring a same-named setting on one tool never collide. Declare it **before** any `overridable:` setting.

**Resolve a per-class value with `resolve_override_for`, not `axn_class.public_send(:setting)`.** This is the load-bearing rule of the author-once model: a plain wrapped Axn *never included your `overrides` module*, so it has no `present_as` accessor to call — but the app may still have set the value via `configure(:mcp) { |c| c.present_as = :message }` or `tool mcp: { present_as: :message }`. `resolve_override_for` reads the override store directly (shadow-proof), returning the per-class value or the library default:

```ruby
# axn-mcp/lib/axn/mcp/wrap.rb — resolve at wrap/call time
present_as = present_as_kwarg || Axn::MCP.resolve_override_for(axn_class, :present_as)
```

Per-class writes are the action author's `configure(:key) { |c| c.x = … }` / `axn_configure`, or the inline [`tool key: { … }`](/recipes/gem-configuration#declaring-per-adapter-tool-config-inline) sugar over the same store.

### `present_as`

A **render toggle** — structured serialized `exposes` vs. the Axn's human message — is a common per-adapter setting. Both `axn-mcp` and `axn-ruby_llm` call it `present_as` with values `:structured` / `:message`; if your transport has the concept, **reuse the name and values**. Note it's *adapter-specific*, not core: an `axn-http_api` wouldn't have it (a REST response is always structured). Resolve it per-class via `resolve_override_for` as above.

## Extension registry

For transport-only vocabulary that core doesn't know about, extend the registry rather than patching core. `Axn.extension_config.register_semantic_hint(*hints)` adds allowed [`semantic_hints`](/reference/class) values so an author can declare them on a tool:

```ruby
# axn-mcp, at load
Axn.extension_config.register_semantic_hint(:open_world, :closed_world)
```

Then read `axn_class._semantic_hints` in `wrap` to map the declared hints to your annotations, letting an explicit adapter override win:

```ruby
# axn-mcp/lib/axn/mcp/wrap.rb
hint_annotations = Axn::MCP::Annotations.annotations_for(axn_class._semantic_hints)
resolved = configured_annotations || hint_annotations.presence
annotations(**resolved) if resolved
```

`semantic_hints` are advisory (core's `:read_only`/`:idempotent`/`:destructive` don't enforce anything); adapters interpret them (MCP annotations, a REST verb, RubyLLM gating).

## Invocation & result mapping

**Call the class with `axn_class.call(**kwargs)`.** It returns an [`Axn::Result`](/reference/axn-result) and **never raises for a business failure** (`call!` raises; `call` doesn't). The *sanctioned* tool call path is [`Axn::Tools::Invoker`](/reference/tool-invoker) — prefer it over a bare `.call`, because it applies the tool contract (always-on coercion of wire args, optional user-facing input-error surfacing, undeclared-key rejection, the ambient-context guard) that a trusted in-process `.call` deliberately doesn't. Read that page; it's the runtime half of this one.

Map the `Result` to your transport response from these members:

| Member | Use |
| --- | --- |
| `result.ok?` | Success branch. |
| `result.error` | **User-facing** failure string — what the LLM/client should see. |
| `result.success` / `result.message` | Success string (`message` is always set; `success` only on the success path). |
| `result.exception` | **Dev-facing** detail (e.g. the `Axn::InboundValidationError` behind a coercion failure). Do **not** surface it to the client. |

```ruby
result = invoker.call(axn_class, model_args, ambient_context: server_context || {})
if result.ok?
  present_as == :message ? result.message : serialize_exposed(result, ...)
else
  { error: result.error }        # surface result.error, never result.exception
end
```

Two rules:

- **Impose no gem-wide error headline.** Surface `result.error` and let each tool declare its own base `error "…"`. A base `error` combines with `fail!("reason")` as `"Headline: reason"` by default; `fail!("…", standalone: true)` opts out. A blanket adapter-level headline erases the per-tool message the author wrote. (See [failure semantics](/usage/writing#prefixing-failure-reasons).)
- **`Axn.owns_failure_exception?(exception)`** distinguishes an axn-owned failure (an `Axn::Failure` or a user-facing validation error, whose `#message` is meant for the client) from a *foreign* exception reclassified via `fails_on` (whose `#message` is a technical cause you should not leak). Use it when you're tempted to read `#message` off `result.exception`.

For inbound-validation detail (which argument the model got wrong), the Invoker exposes `Axn::Tools::Invoker.input_invalid?(result)` and `result.exception.field_errors` — see [Tool Invoker](/reference/tool-invoker#per-field-detail).

## ambient_context

Server/session data an app injects (`current_user`, `company`) reaches a tool through Axn's [`ambient_context`](/reference/class#ambient-context-on-ambient-context) — an author declares `expects :user_id, on: :ambient_context` and the value resolves from whatever the caller supplied. Three rules make this work adapter-agnostically:

- **Spread the injected context *as* `ambient_context:`** — pass it as the `ambient_context:` keyword, **not** nested under an adapter-specific key. This is what keeps the Axn portable: the same `expects :user_id, on: :ambient_context` class resolves from an MCP server context, from `Current` on a direct call, or from ruby_llm. Nesting it (`ambient_context: { mcp: server_ctx }`) couples the Axn to one adapter and defeats the feature.

  ```ruby
  # axn-mcp: server_context spread directly as ambient_context
  axn_class.call(ambient_context: server_context || {}, **model_args)
  ```

- **`ambient_context` is filtered to declared keys**, and the axn extracts each declared field via `#[]`/`#dig` — so a plain `Hash` or an opaque object both work as the injected value. An undeclared key is dropped, never leaked into the call.
- **Always pass an explicit `ambient_context:` (even `{}`).** An explicit value *replaces* the `Current`-derived default entirely (no merge), so passing `{}` prevents ambient server-side state from silently leaking into a tool call. The Invoker also strips any `ambient_context` a model tried to smuggle through the tool arguments before merging your trusted value — see the [ambient_context guard](/reference/tool-invoker#ambient-context-guard).

## Live transport capabilities

Capabilities like progress reporting or cancellation are *objects and operations*, not ambient *data* — so they don't survive `ambient_context`'s declared-key filtering. Expose them through an adapter-specific handle scoped with `ActiveSupport::IsolatedExecutionState` (thread- or fiber-scoped per the configured isolation level), matching how Axn scopes its own per-execution state. A raw `Thread.current[...]` local is wrong under a Fiber scheduler.

```ruby
# axn-mcp/lib/axn/mcp.rb
def self.server_context
  ActiveSupport::IsolatedExecutionState[:__axn_mcp_server_context]
end

def self.with_server_context(value)
  previous = ActiveSupport::IsolatedExecutionState[:__axn_mcp_server_context]
  ActiveSupport::IsolatedExecutionState[:__axn_mcp_server_context] = value
  yield
ensure
  ActiveSupport::IsolatedExecutionState[:__axn_mcp_server_context] = previous
end
```

A tool reaching for `Axn::MCP.server_context.report_progress(...)` is knowingly MCP-coupled — appropriate, since these operations are transport-only. Ambient *data* still belongs in `ambient_context`.

## Inline / one-off tools

**Don't ship a per-gem `define`.** The inline primitive is core: wrap an [`Axn::Factory.build`](/reference/factory):

```ruby
Axn::MCP.wrap(
  Axn::Factory.build(
    expects: { query: { type: String } },
    exposes: { results: { type: Array } },
    name: "search", description: "Search for items",
  ) { expose results: Item.search(query) },
)
```

`Factory.build`'s block is the `#call` body — see the [factory reference](/reference/factory) for its contract (keyword-only args, `expose_return_as:`, and why factory-built classes are *not* auto-discovered by `tools_for`). A factory-built class carries a synthetic name that never resolves to a loaded constant, so the adapter constructing it must hold the reference and `wrap` it directly.

## Deprecations

Own a dedicated `ActiveSupport::Deprecation` instance so a consuming Rails app can register and govern it (silence in test, raise in CI):

```ruby
# axn-mcp/lib/axn/mcp.rb
def self.deprecator
  @deprecator ||= ActiveSupport::Deprecation.new("1.0", "axn-mcp")
end
# a consuming app: Rails.application.deprecators[:axn_mcp] = Axn::MCP.deprecator
```

## Testing

Reuse [`Axn::Testing::SpecHelpers`](/recipes/testing) (`build_axn { … }`, `with_ambient_context`) to construct the Axns you wrap. Then verify adapter output against **real transport objects**, not hand-built hashes — a real `MCP::Tool::Response`/`InputSchema` for `axn-mcp`, a real `RubyLLM::Tool` for `axn-ruby_llm` — and **pin the exact user-facing failure and success strings**:

```ruby
# axn-mcp/spec: real MCP objects, not stubbed hashes
tool = Axn::MCP.wrap(build_axn { … })
expect(tool).to be < MCP::Tool
response = tool.call(**args)
expect(response).to be_a(MCP::Tool::Response)
expect(response.content.first[:text]).to eq("the exact user-facing message")
```

An integration spec that drives a real `MCP::Server.new(tools: Axn::MCP.tools, server_context:)` end-to-end catches the wiring a unit test can't — including that `ambient_context` fields stay absent from the advertised input schema.

## See also

- [AGENTS-tool-adapters.md](https://github.com/teamshares/axn/blob/main/AGENTS-tool-adapters.md) — the same conventions as a dense agent checklist.
- [Tool Invoker](/reference/tool-invoker) — the runtime call path (coercion, input-error surfacing, ambient guard).
- [Configuration for Axn-based Gems](/recipes/gem-configuration) — the config machinery in depth.
- [Building Axns from Callables](/reference/factory) — `Axn::Factory.build` for inline tools.
- [Class Interface](/reference/class) — `tool`, `tool_name`, `semantic_hints`, `ambient_context`, the schema readers.
