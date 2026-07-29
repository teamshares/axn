# Axn — tool-adapter author guide

For an LLM writing an **axn tool-adapter gem**: a gem that exposes plain Axn actions over a tool/agent
transport (`axn-mcp` → MCP, `axn-ruby_llm` → RubyLLM function-calling, a hypothetical `axn-http_api` →
OpenAPI). Not for action authors — for *those* (declaring/calling Axns) read `AGENTS-consuming.md`, the
sibling in this gem. On an edge case, read the core source — paths below, via `bundle show axn`.
Docs: <https://teamshares.github.io/axn/recipes/authoring-tool-adapters>.

## Mental model

**Author-once.** A tool is a plain Axn (`include Axn` + `expects`/`exposes`/`call`) with nothing
transport-specific. The SAME class is wrapped by every adapter, called directly, or enqueued async. Your
adapter *projects* that class into the transport's native tool object, reading everything from Axn's public
reflection surface. Two hard rules:

- **Never require the author to write against your adapter.** No marker mixin, no adapter base class they
  must subclass. They write a normal Axn; you wrap it.
- **Never mutate the shared class in a way that breaks a different adapter.** The class is wrapped by
  others. Overriding `input_schema` to a non-Hash is the canonical bug that retired `Axn::MCP::Tool` — do
  transport shaping inside `wrap`, not by redefining reflection on the class.

Core owns the shared machinery (membership, naming, reflection, config store, extension registry,
invocation contract); you consume its public API. Expose exactly two public methods so every adapter has
the same shape:

```ruby
GemName.tools                    # zero-arg: Axn.tools_for(:key).map { |a| wrap(a) }
GemName.wrap(axn_class, **opts)  # one Axn -> the transport's native tool object
```

`.tools` MUST be zero-arg — so every `wrap` option must default (name/description from the class).

## Registration & discovery

- **Register at gem load, from the entry file:** `Axn.register_tool_adapter(:key)`. Pass a config source
  second arg (`Axn.register_tool_adapter(:key, self)`) ONLY if you offer directory discovery; else omit.
  Re-registering with no source is idempotent.
- **Enumerate with `Axn.tools_for(:key)`** — returns the latest version per `tool_name`, sorted by
  `tool_name` (a duplicate `(tool_name, tool_version)` raises), tool-root dirs eager-loaded first. Pass
  `all_versions: true` for every version, or use `Axn.versions_for(:key, tool_name)` for one tool's group.
- **Only currently-loaded classes are enumerated.** A `tool :key` class outside a tool-root dir must be
  `require`d first. Enumerate from `config.after_initialize` / `to_prepare` — **never** a
  `config/initializers` file (runs before autoload paths are wired; `tools_for` warns).
- **Membership** = `(directory grant ∪ declaration grant) − except`, computed by the registry. You don't
  parse it — you call `tools_for`. The author declares it: `tool` (all adapters), `tool :mcp` (add),
  `tool mcp: { … }` / `configure(:mcp)` (implies `:mcp`), residency under a tool root, `tool false` (opt
  out), `tool except: :x` (narrow).
- **Directory membership is optional.** `extend Axn::Tools::AdapterRoots` → a validated `tool_roots`
  setting the registry reads. Its `validate!` reuses core's broad-path guard (rejects `app`/`actions`/`.`/`..`).
  The reference gems don't adopt it (they use explicit `tool`/`configure`); add it only if it fits.

Source: `lib/axn.rb` (`register_tool_adapter`, `tools_for`), `lib/axn/tools/registry.rb` (membership,
eager-load), `lib/axn/tools/adapter_roots.rb`, `lib/axn/core/tools.rb` (`tool` DSL, `tool_name`).

## Naming & description

- **Name = `axn_class.tool_name(:your_key)` — pass your adapter key.** Don't roll your own — the same Axn
  must yield the same name across adapters. It's provider-safe, never blank, honors `tool name:` and prefix
  stripping. `tools_for` sorts on `tool_name(:your_key)` and collapses to the latest per name (uniqueness is
  on `(tool_name, tool_version)`); a per-adapter `tool your_key: { name: }` override is only returned when
  you pass the key — the zero-arg form ignores per-adapter overrides, so reading it would publish a name
  the registry didn't collapse on.
- **Description = `axn_class.description`.** `wrap`'s `description:` defaults to it (keeps `.tools` zero-arg).

## Schema reflection

- Use public `axn_class.input_schema` / `axn_class.output_schema` — plain JSON Schema **Hashes**. Wrap them
  into your transport's schema object inside `wrap`.
- **Don't** reach into `Axn::Reflection::Schema` internals. **Don't** override `input_schema` to a non-Hash
  (breaks other adapters on the shared class).
- `on: :ambient_context` fields are **auto-excluded** from `input_schema` — you get a clean model-facing
  schema; don't re-add them.
- Reflection is best-effort, biased **stricter** than runtime (a schema-following call won't be rejected),
  with one documented **looser** case (an invalid literal `default:`). Surface the caveat; don't fight it.
  A deep subfield under a `model:`/non-object parent is omitted with a `logger.warn` — pass it through.

Source: `lib/axn/core/schema_reflection.rb`, `lib/axn/reflection/schema.rb`.

## Value serialization

- Render a success result's exposures with `Axn::Extensions::Serialization.render(result)` → JSON-safe Hash.
  Don't hand-roll (it handles Symbol/BigDecimal/Time/`as_json`-vs-`to_h` so output matches `output_schema`).
- **You pass no config list** — `render` derives the declared `exposes` from the result itself. Rendering a
  subset is deliberately unsupported: it would emit a body contradicting `output_schema`.
- **Don't reach into `Axn::Reflection::Values`.** `render` is the surface; the renderer's helpers are private, and
  what stays public is there for core's own cross-module callers, not for you.
- No **value** in the result is one `JSON.generate` refuses (no non-finite number, no non-UTF-8 bytes, no
  cycle, no collapsed property). That is a promise about values, NOT about your encoder's config: a structure
  deeper than `max_nesting` (100 default) still raises `JSON::NestingError`. Drop your pre-*pass* over the
  value graph; **keep** your encode `rescue`.
- Raises `Axn::Reflection::UnserializableValue` (an `ArgumentError`), naming the path, on four unconditional
  defects: a cycle; two Hash keys that render as one JSON property (compared as the PROPERTY each produces,
  not as the Ruby String its `to_s` returned — keys are transcoded to UTF-8 first, so one property name in
  two encodings collides); a non-finite Float (incl. a `BigDecimal`/`Rational` coercing to one); and a
  String — or a key's String form — whose bytes have no UTF-8 rendering (stricter than `valid_encoding?`:
  `"\xFF"` in `BINARY` is valid BINARY and unencodable; a valid ISO-8859-1/Shift_JIS value transcodes and
  passes untouched, a key comes back as UTF-8). Add `reject_opaque: true` to also reject a
  value or key that declares no rendering of its own — `to_s` inherited from `Object`, or (in Rails)
  ActiveSupport's generic `Object#as_json` ivar dump as its only projection. A meaningful
  `to_s`/`as_json`/`to_h` defined anywhere else passes, address-looking or not. Never write your own
  pre-pass — it drifts from the renderer.
- Keep the two guarantees apart: encodability is unconditional, declared-shape is what the flag buys.
  `reject_opaque: false` never means "might not be JSON" — that is why it isn't named `strict:`.

Source: `lib/axn/extensions/serialization.rb` (the renderer itself is `lib/axn/reflection/values.rb`, core-internal).

## Per-adapter configuration

- `extend Axn::Configurable` + `config_namespace :key` (declare it before any overridable setting); declare
  `setting :x, …, overridable: true`. See <https://teamshares.github.io/axn/recipes/gem-configuration>.
- **Resolve a per-class value with `Axn::<Mod>.resolve_override_for(axn_class, :x)` — NOT
  `axn_class.public_send(:x)`.** A wrapped plain Axn never included your `overrides` module, so it has no
  such accessor; but the app may have set the value via `configure(:key)` / `tool key: { … }`.
  `resolve_override_for` is the shadow-proof reader over the override store.
- A **render toggle** (structured serialized `exposes` vs. the Axn's message) is a common per-adapter
  setting. `axn-mcp` and `axn-ruby_llm` both name it `present_as` (`:structured` / `:message`) — reuse the
  name/values if you have the concept. It's adapter-specific, not core (an `axn-http_api` has no such toggle).

Source: `lib/axn/configurable.rb` (`config_namespace`, `resolve_override_for`, `overrides`).

## Extension registry

- Add transport-only vocabulary without a core change: `Axn::Extensions.config.register_semantic_hint(:open_world,
  :closed_world)` at load. Read `axn_class._semantic_hints` in `wrap` to map declared hints to your
  annotations; let an explicit adapter override win. Hints are advisory (nothing enforces them).

Source: `lib/axn/extensions/config.rb`, `lib/axn/core/semantic_hints.rb`.

## Invocation & result → response

- **`axn_class.call(**kwargs)` returns an `Axn::Result` and never raises for a business failure** (`call!`
  raises; `call` doesn't). Prefer calling through **`Axn::Tools::Invoker`** — it applies the tool contract
  (always-on wire coercion, opt-in user-facing input-error surfacing, undeclared-key rejection, the
  ambient guard) that a trusted in-process `.call` deliberately omits. See
  <https://teamshares.github.io/axn/reference/tool-invoker>.
- Map from: `result.ok?`; `result.error` (**user-facing** — show to the LLM/client); `result.success` /
  `result.message` (success string); `result.exception` (**dev-facing** detail, e.g. the
  `Axn::InboundValidationError` — do **NOT** surface it).
- **`Axn.owns_failure_exception?(exception)`** — true for an axn-owned failure (`Axn::Failure` or a
  user-facing validation error, whose `#message` is client-safe), false for a foreign exception
  reclassified via `fails_on` (technical cause — don't leak). Check it before reading `#message` off an
  exception.
- **Impose no gem-wide error headline.** Surface `result.error`; let each tool declare its own base
  `error "…"`. A base `error` prefixes `fail!("reason")` as `"Headline: reason"` unless
  `fail!("…", standalone: true)`.
- For per-field inbound detail: `Axn::Tools::Invoker.input_invalid?(result)` and
  `result.exception.field_errors`.

Source: `lib/axn.rb` (`owns_failure_exception?`), `lib/axn/tools/invoker.rb`, `lib/axn/result.rb`.

## ambient_context

Server/session data (`current_user`, `company`) an author declares via `expects :user_id, on: :ambient_context`.

- **Spread it AS `ambient_context:`** — pass the injected context as the `ambient_context:` keyword, NOT
  nested under an adapter key. Nesting couples the Axn to one adapter; spreading keeps it portable (the
  same class resolves from an MCP server context, from `Current` on a direct call, or from ruby_llm). On a
  direct `.call`, strip any model-supplied `ambient_context` from the args before splatting them (`**`) or
  the model could override your trusted value — or just use the Invoker, which strips it for you.
- It's **filtered to declared keys**; the injected value must be a `Hash` / hash-like (responds to
  `key?`/`[]`, e.g. `HashWithIndifferentAccess`) — axn keys into it and drops any source it can't key into,
  so a bare opaque object resolves every ambient field as absent. Wrap a transport context object in a Hash
  of the injected fields (keys string or symbol, indifferent).
- **Always pass an explicit `ambient_context:` (even `{}`)** — it *replaces* the `Current`-derived default
  (no merge), preventing server-side state leaking into the call. The Invoker also strips any
  `ambient_context` smuggled through model args before merging yours.

Source: `lib/axn/core/ambient_context.rb`, `lib/axn/tools/invoker.rb`.

## Live transport capabilities

- Progress/cancellation are **objects/operations, not ambient data** — they don't survive ambient_context
  filtering. Expose them via an adapter handle scoped with `ActiveSupport::IsolatedExecutionState`
  (thread-/fiber-scoped per the configured isolation level), matching how axn scopes its own per-execution
  state. A raw `Thread.current[...]` local is wrong under a Fiber scheduler. See `Axn::MCP.server_context` /
  `with_server_context` in axn-mcp.

## Inline / one-off tools

- **Don't ship a per-gem `define`.** Wrap a core `Axn::Factory.build`:
  `GemName.wrap(Axn::Factory.build(expects:, exposes:, axn_name: "…", description: "…") { … })`. The block is
  the `#call` body (keyword-only args; not available for `exposes`/`shape:` coercion). A factory-built
  class is **not** auto-discovered by `tools_for` (synthetic name) — the constructor holds the reference
  and wraps it directly. See <https://teamshares.github.io/axn/reference/factory>.

## Deprecations

- Own a dedicated `ActiveSupport::Deprecation.new("1.0", "gem-name")` as `GemName.deprecator`, so a
  consuming Rails app can register it (`Rails.application.deprecators[:gem] = GemName.deprecator`) and
  govern its behavior. `axn-mcp` does this; `axn-ruby_llm` currently uses raw `warn` — follow axn-mcp.

## Testing

- Reuse `Axn::Testing::SpecHelpers` (`build_axn { … }`, `with_ambient_context`) to construct the wrapped
  Axns. Verify adapter output against **real** transport objects (a real `MCP::Tool::Response`/`InputSchema`,
  a real `RubyLLM::Tool`), not hand-built hashes. **Pin the exact user-facing failure/success strings.** An
  end-to-end spec driving a real `MCP::Server.new(tools:, server_context:)` catches wiring a unit test can't.

## Reference gems

- **axn-mcp** — adapter key `:mcp`; `wrap` → `::MCP::Tool` subclass → `MCP::Tool::Response`. Full worked
  example of every convention above (registration, `server_context`, `semantic_hints` → annotations,
  dedicated deprecator, real-object specs).
- **axn-ruby_llm** — adapter key `:ruby_llm`; `wrap` → `::RubyLLM::Tool`. No output schema, no
  transport-capability handle, no semantic_hints (RubyLLM has no annotations) — a simpler adapter surface.

## Pointers

Docs — <https://teamshares.github.io/axn/>: authoring a tool-adapter gem
(`/recipes/authoring-tool-adapters`), tool invoker (`/reference/tool-invoker`), gem configuration
(`/recipes/gem-configuration`), factory (`/reference/factory`), class DSL (`/reference/class`), result
(`/reference/axn-result`). Action-authoring: `AGENTS-consuming.md` (this gem).

Core source entry points (resolve with `bundle show axn`):
- `lib/axn.rb` — `register_tool_adapter`, `tools_for`, `owns_failure_exception?`.
- `lib/axn/extensions.rb` — `Axn::Extensions.best_effort`, `Axn::Extensions.config` (the extension-author surface).
- `lib/axn/tools/registry.rb`, `lib/axn/tools/adapter_roots.rb`, `lib/axn/core/tools.rb` — membership, `tool_name`.
- `lib/axn/core/schema_reflection.rb`, `lib/axn/reflection/schema.rb`, `lib/axn/reflection/values.rb` — reflection.
- `lib/axn/configurable.rb` — `config_namespace`, `resolve_override_for`, `overrides`.
- `lib/axn/tools/invoker.rb` — the tool call path.
- `lib/axn/core/ambient_context.rb` — ambient filtering/resolution.
- `lib/axn/factory.rb` — `Axn::Factory.build`.
