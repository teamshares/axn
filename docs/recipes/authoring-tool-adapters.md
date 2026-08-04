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

`.tools` is `Axn::Tools.for(:key).map { |a| wrap(a) }` — it must be callable with no arguments, which is why `wrap`'s every option defaults (see [Naming & description](#naming-description)). `wrap` returns the transport-native object: for `axn-mcp` a `::MCP::Tool` subclass, for `axn-ruby_llm` a `::RubyLLM::Tool` subclass.

```ruby
# axn-mcp
module Axn::MCP
  def self.tools = Axn::Tools.for(:mcp).map { |axn_class| wrap(axn_class) }
end

# a consumer wiring an MCP server
MCP::Server.new(name: "acme", version: "1", tools: Axn::MCP.tools)
```

## Registration & discovery

**Register the adapter at gem load, from the entry file.** Call `Axn::Tools.register_adapter(:key)` where the gem is first required, so the key exists in the process-global registry before any app code enumerates tools:

```ruby
# lib/axn/mcp.rb (required from lib/axn-mcp.rb)
Axn::Tools.register_adapter(:mcp)
```

`Axn::Tools.register_adapter` takes an optional second argument — a config source the registry reads directory roots from (see [Directory-based membership](#directory-based-membership-optional)). Pass it (`Axn::Tools.register_adapter(:mcp, self)`) only if your adapter offers directory discovery; omit it otherwise. Re-registering with no source is idempotent and won't wipe a source already supplied.

**`Axn::Tools.for(:key)` enumerates the members** — one entry per `tool_name` (the latest [version](#versioning) when several coexist), deterministically sorted by [`tool_name`](#naming-description), with each adapter's tool-root directories eager-loaded first. Two rules follow from *how* it enumerates:

- **Only currently-loaded classes are enumerated.** `Axn::Tools.for` reflects over classes that are defined *now*; a `tool :key` class that lives outside a tool-root directory must already be `require`d. Enumerate from a point where your app's classes are loaded — `config.after_initialize` or a `to_prepare` block under Rails, **not** a `config/initializers` file (which runs before the app's autoload paths are wired; `Axn::Tools.for` will warn that discovery is incomplete).
- **Two classes sharing both a `tool_name` *and* a `tool_version` for one adapter raise.** That conflict is only knowable once both are loaded, so `Axn::Tools.for` and `Axn::Tools.versions` fail loudly with a message pointing at `tool name:` or [`tool_version`](#versioning) to disambiguate, rather than silently clobbering one. Two classes sharing a `tool_name` with *different* versions are not a conflict — they're the versioned-tool convention.

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

The action author owns these declarations — see [the class reference](/reference/class) and [Configuration for Axn-based Gems](/recipes/gem-configuration#declaring-per-adapter-tool-config-inline). As an adapter author you don't parse them; you call `Axn::Tools.for(:key)` and get the resolved set.

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

**Names come from `axn_class.tool_name(:your_key)` — never roll your own.** `tool_name` is the canonical, provider-safe derivation (honors an explicit `tool name:`, strips configured prefixes, snake_cases, restricts to `[a-z0-9_]`, and is never blank). The *same Axn must yield the same name across every adapter*, so a client sees one stable identity regardless of transport. **Pass your adapter key.** `Axn::Tools.for` sorts and groups the set by `tool_name(:your_key)` (collapsing to the latest [version](#versioning) per name), and a per-adapter `tool your_key: { name: "…" }` override is only returned when you pass the key — the zero-arg `tool_name` deliberately ignores per-adapter overrides. So an adapter that reads the zero-arg form would publish a *different* name than the registry grouped on:

```ruby
tool_name = axn_class.tool_name(:mcp)    # provider-safe, never blank; honors a per-adapter `tool mcp: { name: }`
description = description || axn_class.description
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

- **Don't reach into `Axn::Internal::Reflection::Schema` internals**, and **never override an Axn's `input_schema` to return a non-Hash.** The class is shared: a non-Hash `input_schema` breaks every *other* adapter wrapping the same class. This is the concrete defect that retired the old `Axn::MCP::Tool` base — wrap the Hash into your transport object in `wrap`, don't redefine the reflection method on the class.
- **`on: :ambient_context` fields are auto-excluded from `input_schema`** (they're framework-supplied, never model input — see [ambient_context](#ambient-context)). You get a clean model-facing schema for free; don't re-add them.
- **Reflection is best-effort and biased *stricter* than runtime** — a call that follows the schema won't be schema-rejected. There is one documented *looser* case: an invalid literal `default:` (`type: :uuid, default: "nope"`) reflects as optional though the omitted call fails at runtime. Surface this caveat to your users; don't try to fight it in the adapter. (A deep subfield under a `model:`/non-object parent has no JSON representation and is omitted with a `logger.warn` — pass it through, don't paper over it.)

## Value serialization

To render a successful `Axn::Result`'s exposed values into a JSON-safe hash, use `Axn::Extensions::Serialization.render` — don't hand-roll it (it handles Symbol/BigDecimal/Time/`as_json`-vs-`to_h` edge cases so the output validates against the reflected `output_schema`):

```ruby
# An MCP or LLM tool adapter
exposed = Axn::Extensions::Serialization.render(result)

# An HTTP adapter, which must not ship an undeclared rendering in a response body
exposed = Axn::Extensions::Serialization.render(result, reject_opaque: config.reject_opaque)
```

You don't pass the field configs: `render` derives them from the result's own action class, so a rendered body always covers exactly the declared `exposes` — and therefore always matches `output_schema`. Rendering a subset isn't supported, deliberately; a partial body would contradict the schema the same adapter published.

Where the rendering actually happens — `Axn::Internal::Reflection::Values` — is core-internal, exactly like `Axn::Internal::Reflection::Schema`. `render` is the declared entry point; the module's helpers are private, and what stays public is there for core's own callers rather than for an adapter.

There are two guarantees here, and it's worth keeping them apart, because only one of them is behind a flag.

**Always:** nothing was silently dropped along the way, and no *value* in the result is one `JSON.generate` refuses — no non-finite number, no bytes without a UTF-8 rendering, no cycle, no two keys collapsing into one property.

That guarantee is about the values, not about your encoder's configuration, and the difference is load-bearing: a structure nested deeper than `max_nesting` (100 by default) is made of perfectly encodable values and still raises `JSON::NestingError`. Core can't own that — `max_nesting` is your option to set, and a deeply-nested structure is real data rather than a defect. **So keep your encode step's error handling.** What it no longer needs is a *pre-pass over the value graph*; catching what your encoder raises is still yours.

**Additionally under `reject_opaque: true`:** every value was rendered through a projection *its author declared*, rather than one the serializer guessed at. That is a separate promise about meaningfulness, not about encodability — which is why the flag is named for what it rejects rather than called something like `strict:`. Reading `reject_opaque: false` should not suggest the output might not be JSON; it always is.

It raises `Axn::Extensions::Serialization::UnserializableValue` (an `ArgumentError`) when an exposed value has no honest JSON representation, naming the path to it (`records[3].price`, not "something"). Five cases raise always, because the body would be *wrong* — or not JSON at all:

- a self-referential value (a cycle has no JSON representation at all);
- two exposed field *names* that render as the same JSON property — the same collapse as the Hash-key case, one level up: a declared field name is canonicalized to UTF-8 exactly the way a Hash key is, so two distinct Symbols (an ISO-8859-1-encoded one beside its UTF-8 counterpart) would converge on one property and silently overwrite. In practice you will not see this one from `render`: axn now rejects that pair when the class is defined, and rejects a collapse contributed by any other part of the contract (a shape member, a nested key, a `model:`-generated id) when the outbound projection is first built — which `render` itself triggers. This remains the last line under it;
- two Hash keys that render as the same JSON property (`{id: 1, "id" => 2}` renders one property, silently dropping a value). What's compared is the *property* each key produces, not the Ruby String its `to_s` returned — keys are transcoded to UTF-8 first, so one property name in two encodings (an ISO-8859-1 `"\xE9"` beside a UTF-8 `"é"`) is caught as the single property it is;
- a non-finite Float — `Float::INFINITY`, `-Float::INFINITY`, `Float::NAN`, or a `BigDecimal`/`Rational` that coerces to one. JSON has no literal for these, and an encoder's `allow_nan:` would emit a bare `Infinity` that consumers reject;
- a String — or a Hash key's String form — whose bytes have no UTF-8 rendering. JSON is a UTF-8 format. Note that this is stricter than `valid_encoding?`: `"\xFF"` in `BINARY` is valid BINARY and still unencodable. A String that is merely in some other encoding is fine, as long as it transcodes: a valid ISO-8859-1 or Shift_JIS *value* passes untouched, while a *key* comes back transcoded to UTF-8, since a property name is the text an encoder emits. One case is deliberately stricter than json 2.x: a `BINARY` String carrying valid UTF-8 bytes is refused here, while that encoder accepts it with a deprecation warning and json 3.0 will refuse it outright — so this rejects a hair early rather than emitting something that stops encoding on a dependency bump.

The last two are why your encode step needs no pre-*pass* of its own. Without them an adapter surfaces a bare `JSON::GeneratorError` — or catches it at encode time, by which point the path to the offending value is gone and all you can report is a generic failure. Nesting depth is the one refusal that still reaches your encoder, so keep the `rescue` even though the walk can go.

Pass `reject_opaque: true` to also reject a value — or a Hash key — that declares no rendering of its own. The rule is about where the method it would render through is *defined*, not what that method produces: a value is opaque when its `to_s` is the one inherited from `Object`, or (in a Rails app, where ActiveSupport defines a generic `Object#as_json` that dumps instance variables) when that generic method is its only `as_json` and it has neither a `to_h` nor a `to_hash`. A `to_hash` counts because that generic `as_json` delegates to it rather than dumping, so the value renders the shape its author declared. So it catches the value that ships `"#<User:0x000055…>"` outside Rails and the instance-variable dump the same value ships inside Rails — but not, for instance, a `Proc`, a class doing `alias_method :to_s, :inspect`, or a delegator forwarding `to_s` to a wrapped object: each of those renders through a method defined somewhere other than `Object`, so the flag lets it through. It is not a promise that no object address reaches the wire.

Such a rendering is honest — every exposed datum is there — just not one the value's author declared, so whether it's a failure is the adapter's call: an HTTP contract shouldn't ship it in a response body, while an LLM tool result is arguably better off with an ugly string than a failed call. The default is `false`.

You don't need your own detection for any of these — and shouldn't write one. A strictness check only stays correct while it's colocated with the rendering it predicts; a parallel walk has to mirror the leaf-type list, the `as_json`-before-`to_h` ordering, and key stringification, and will drift. Let the error reach whatever `rescue` already maps a failed serialization to your transport's error response, and keep any "how to turn this off" hint in your own config's voice — core's messages never mention an adapter's settings.

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

For transport-only vocabulary that core doesn't know about, extend the registry rather than patching core. `Axn::Extensions.config.register_semantic_hint(*hints)` adds allowed [`semantic_hints`](/reference/class) values so an author can declare them on a tool:

```ruby
# axn-mcp, at load
Axn::Extensions.config.register_semantic_hint(:open_world, :closed_world)
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
  present_as == :message ? result.message : Axn::Extensions::Serialization.render(result)
else
  { error: result.error }        # surface result.error, never result.exception
end
```

Two rules:

- **Impose no gem-wide error headline.** Surface `result.error` and let each tool declare its own base `error "…"`. A base `error` combines with `fail!("reason")` as `"Headline: reason"` by default; `fail!("…", standalone: true)` opts out. A blanket adapter-level headline erases the per-tool message the author wrote. (See [failure semantics](/usage/writing#prefixing-failure-reasons).)
- **`Axn::Extensions.owned_failure?(exception)`** distinguishes an axn-owned failure (an `Axn::Failure` or a user-facing validation error, whose `#message` is meant for the client) from a *foreign* exception reclassified via `fails_on` (whose `#message` is a technical cause you should not leak). Use it when you're tempted to read `#message` off `result.exception`.

For inbound-validation detail (which argument the model got wrong), the Invoker exposes `Axn::Tools::Invoker.input_invalid?(result)` and `result.exception.field_errors` — see [Tool Invoker](/reference/tool-invoker#per-field-detail).

## ambient_context

Server/session data an app injects (`current_user`, `company`) reaches a tool through Axn's [`ambient_context`](/reference/class#ambient-context-on-ambient-context) — an author declares `expects :user_id, on: :ambient_context` and the value resolves from whatever the caller supplied. Three rules make this work adapter-agnostically:

- **Spread the injected context *as* `ambient_context:`** — pass it as the `ambient_context:` keyword, **not** nested under an adapter-specific key. This is what keeps the Axn portable: the same `expects :user_id, on: :ambient_context` class resolves from an MCP server context, from `Current` on a direct call, or from ruby_llm. Nesting it (`ambient_context: { mcp: server_ctx }`) couples the Axn to one adapter and defeats the feature.

  ```ruby
  # axn-mcp: strip any model-supplied ambient_context, THEN spread the trusted server context as
  # the kwarg — otherwise a model that sent an `ambient_context` arg would override it via the splat.
  safe_args = model_args.except(:ambient_context, "ambient_context")
  axn_class.call(ambient_context: server_context || {}, **safe_args)
  ```

  Better, let [`Axn::Tools::Invoker`](/reference/tool-invoker#ambient-context-guard) do this for you — it strips any model-supplied `ambient_context` before merging your trusted value: `invoker.call(axn_class, model_args, ambient_context: server_context || {})`.

- **`ambient_context` is filtered to declared keys**, so the injected value must be a `Hash` (or a hash-like that responds to `key?`/`[]`, e.g. an `ActiveSupport::HashWithIndifferentAccess`) — axn keys into it to extract each declared field and **drops any source it can't key into**, so passing a bare opaque transport object resolves every ambient field as *absent*. Wrap a context object in a Hash of the fields you're injecting (`ambient_context: { user_id: ctx.user_id }`). Keys may be strings or symbols (indifferent); an undeclared key is dropped, never leaked into the call.
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
    axn_name: "search", description: "Search for items",
  ) { expose results: Item.search(query) },
)
```

`Factory.build`'s block is the `#call` body — see the [factory reference](/reference/factory) for its contract (keyword-only args, `expose_return_as:`, and why factory-built classes are *not* auto-discovered by `Axn::Tools.for`). A factory-built class carries a synthetic name that never resolves to a loaded constant, so the adapter constructing it must hold the reference and `wrap` it directly.

## Deprecations

Own a dedicated `ActiveSupport::Deprecation` instance so a consuming Rails app can register and govern it (silence in test, raise in CI):

```ruby
# axn-mcp/lib/axn/mcp.rb
def self.deprecator
  @deprecator ||= ActiveSupport::Deprecation.new("1.0", "axn-mcp")
end
# a consuming app: Rails.application.deprecators[:axn_mcp] = Axn::MCP.deprecator
```

## Versioning

A tool declares its contract version with `tool_version` — a first-class core attribute, a sibling of `tool_name`, never part of it. Absent, a tool is version 1. Multiple versions of one logical tool coexist by sharing a `tool_name`:

```ruby
class ApproveLoan
  include Axn
  tool :mcp
  tool_version 2
end
```

The registry identity is `(tool_name, tool_version)`: two tools may share a `tool_name` as long as their versions differ (same name *and* version still raises). Enumeration exposes two projections for an adapter to pick between:

- `Axn::Tools.for(:mcp)` returns the **latest** version per `tool_name` — a model re-reads the schema each session and wants the newest contract. Backward-compatible: today's unversioned tools are groups of one, so latest-of-one is unchanged.
- `Axn::Tools.for(:mcp, all_versions: true)` returns **every** version (sorted by `tool_name`, then ascending version) — for an adapter that addresses each one separately, e.g. path-routed HTTP.
- `Axn::Tools.versions(:mcp, "approve_loan")` returns one tool's version group (`.all` ascending, `.latest`) for an adapter resolving a single name rather than walking the whole enumeration.

The latest-vs-every asymmetry is intentional: a fresh model call wants newest, while a long-lived HTTP client wants a URL that means exactly one version forever. Core resolves both; which to serve is the adapter's projection policy. Core deliberately has no "default version" concept — an adapter that wants a stable pin should make every version separately addressable (so no URL ever changes meaning) rather than blessing one behind an unqualified alias.

### Filesystem convention

`tool_version N` is the sole source of truth for the number — nothing derives version from the filesystem. The recommended layout is a convention with no magic:

- **Single version: stay flat** — `agent_tools/approve_loan.rb`.
- **Second version: promote to a folder** — rename to `agent_tools/approve_loan/v1.rb` (declaring `tool_version 1`) and add `v2.rb` (`tool_version 2`). With no `approve_loan.rb`, Zeitwerk treats `approve_loan/` as a namespace module (`AgentTools::ApproveLoan`) and nests `::V1`/`::V2`; the module itself is not a tool (it does not `include Axn`).

When a class declares `tool_version` and its constant ends in a `::Vn` segment, `tool_name` derives from the enclosing namespace (`AgentTools::ApproveLoan::V2` → `"approve_loan"`), so both versions group. The promotion moves the Ruby constant but not the wire contract — identity stays `tool_name`. Two guardrails keep the convention honest, enforced at enumeration (and, when the constant name is already visible, at declaration): a `::Vn` member that didn't declare its own `tool_version` — a forgotten declaration, or one merely inherited from a superclass — raises rather than silently orphaning or mis-versioning itself, and a `::V2` whose declared `tool_version` disagrees with the suffix raises. `Axn::Tools.for` checks every member; `Axn::Tools.versions` checks the members it matched, so the two never disagree while an unrelated malformed tool under a different name doesn't derail a lookup. `tool_name` derivation itself is a pure reader that does not raise.
Versions group by their resolved `tool_name`, so if two versions set different per-adapter name overrides (`tool mcp: { name: … }`) they resolve to different names and won't group — keep the name consistent across versions.

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
