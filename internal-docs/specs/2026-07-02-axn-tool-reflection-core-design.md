# DRY the tool concept into axn core (reflection, naming, semantic hints, ambient context) — design

**Ticket:** [PRO-2842 — \[Axn\] DRY LLM/tool concept across axn-mcp + axn-ruby_llm via axn core reflection](https://linear.app/teamshares/issue/PRO-2842/axn-dry-llmtool-concept-across-axn-mcp-axn-ruby-llm-via-axn-core) (blocks PRO-2844 axn-mcp, PRO-2845 axn-ruby_llm)

**Branch:** `kali/pro-2842-axn-dry-llmtool-concept-across-axn-mcp-axn-ruby_llm-via-axn`

## Problem

We are introducing tools for two surfaces — `axn-mcp` (external MCP tools) and `axn-ruby_llm` (internal RubyLLM function-calling) — and want to author a tool **once** and expose it to **both** (and a future `axn-rest`) without duplicating logic. The chosen authoring model is: a single Axn is surfaced as an MCP tool *and* registered into a RubyLLM chat from one definition.

The key architectural move is that there is **no `axn-tool` middle gem**. Once core can (a) reflect its contract to JSON Schema, (b) name itself, (c) describe its side-effect profile, and (d) let an adapter hang transport-specific config off a class, then **any Axn is already tool-shaped** — an adapter can `wrap(any_axn)`. `include Axn` is the entire authoring surface. Rejected: homing the core in axn-mcp (forces every RubyLLM consumer to transitively install the `mcp` SDK), and keeping a shared `axn-tool` gem (once reflection + naming + hints sink into core, the only remaining shared concern is per-adapter config, which becomes a core extension registry rather than a gem).

This spec covers **axn core only**. The two adapters are separate tickets (PRO-2844, PRO-2845) and consume what this spec builds. os-app is a downstream consumer, later.

## What core gains

All additions are generic (not tool-specific), and the reflection/serialization pieces are read-only and off the execution path:

1. `axn_name` — class-level name override; also repairs the `"Anonymous Class"` literal in the logging context stack.
2. Class-level `description` — extends the field-level `description` core already has.
3. `Axn::Reflection::Schema` — contract → JSON Schema. Moves `axn-mcp`'s `SchemaBuilder` into core. Public surface: `.input_schema` / `.output_schema`.
4. `Axn::Reflection::Values` — Result exposures → JSON-safe Hash. Moves `axn-mcp`'s `Serializer.serialize_exposed`.
5. `semantic_hints` — validated advisory side-effect/behavior vocabulary.
6. `ambient_context` — the caller-identity seam, built on existing subfields + a filtered default provider; replaces the raw `current_attributes` capture in exception reports.
7. A class-level **extension registry** so adapters can register transport-specific DSL + a per-adapter, inherited metadata bag — built on the existing `Axn::Configurable#overrides` primitive.

`render_as` / text-vs-structured rendering stays **out** of core: it is only meaningful to the two LLM surfaces and each already differs (`mcp_text_content` vs a RubyLLM equivalent), so it remains a per-adapter DSL registered via the extension registry.

## Naming: `inbound`/`outbound` stays internal; `input`/`output` is the surface

Core's contract machinery is directional in `inbound`/`outbound` vocabulary throughout — `_declared_fields(:inbound|:outbound)`, `_context_slice(direction:)`, the `InternalContext` (inbound) / `Result` (outbound) facades. That vocabulary is internal and stays internal.

The reflection layer's entire purpose is to render the axn contract into *other ecosystems'* vocabulary — JSON Schema, OpenAPI, MCP `inputSchema`, LLM function `parameters` — all of which say **input/output**. So the user-facing and adapter-facing surface speaks `input`/`output`, while the internal builder still takes an `inbound`/`outbound` direction. `expects`/`exposes` is how you *author*; `input_schema`/`output_schema` is how the outside world asks about what you authored. This also keeps `inbound`/`outbound` from leaking into the public API, and `input`/`output` is a clean symmetric pair where `expects`/`exposes` is lopsided (there is no natural noun for `exposes`).

## 1. `axn_name`

`Core::Logging#_log_prefix` builds the context-stack prefix from `axn.class.name.presence || "Anonymous Class"` (`logging.rb:41`). A truly anonymous `Class.new { include Axn }` has `name == nil` and logs as the literal `"Anonymous Class"`; a `Factory.build` class defines `name` as `"AnonymousAxn_<object_id>"`.

Add a class-level `axn_name` setter/getter. Resolution order for the display name becomes: explicit `axn_name`, else `self.name`, else a stable fallback (keep `"Anonymous Class"` or similar). `_log_prefix` consults the resolved name. This is the single canonical name used by logging, `inspect`, docs, and any adapter that needs a tool name — adapters read the resolved name rather than reaching for `self.name` directly.

## 2. Class-level `description`

Core has field-level `description` (a registered metadata key; `contract.rb:29`, `extension_config.rb:6`) but **no** class-level `description`. The `description(...)` seen in `Axn::MCP::Tool` today is inherited from the `::MCP::Tool` SDK base, not from axn.

Add a class-level `description` getter/setter (a String), inherited by subclasses. Usable in `inspect`/logging/docs, and read by adapters as the tool description. No relationship to the field-level metadata key beyond the shared word.

## 3. `Axn::Reflection::Schema` — contract → JSON Schema

Move `axn-mcp`'s `SchemaBuilder` into core as `Axn::Reflection::Schema`. It reads only core-owned data — `internal_field_configs`, `external_field_configs`, `subfield_configs` (with `.on`/`.reader_as`), and `Axn::Internal::FieldConfig.optional?/.boolean?` — so the move is mechanical. JSON Schema is just Hashes, so there is no new dependency, and the output is format-generic (REST/OpenAPI/docs/LLM), not MCP-specific.

The rationale for co-location: the builder tracks axn's validation vocabulary (`model:`, `of:`, `shape:`, `inclusion:`, `type:`, …). In core it lives next to the vocabulary it mirrors, so a new validation updates its own schema output rather than being tracked from outside.

**Public surface** (the "schema export API" — the transport-free capability that falls out of reflection for free, and doubles as unit-testable proof that reflection is transport-agnostic, plus docs):

```ruby
MyAxn.input_schema   # => Hash (JSON Schema for expects + subfields, minus the ambient_context parent)
MyAxn.output_schema  # => Hash (JSON Schema for exposes)
```

Internally these call `Axn::Reflection::Schema.build(configs, direction: :inbound | :outbound)`. Adapters consume the Hash and wrap it into their transport object (e.g. `::MCP::Tool::InputSchema`).

`sensitive: true` has **zero** effect on schema output — the builder never reads `.sensitive` (only description/type/default/inclusion/of/shape). Preserve this invariant with an explicit test.

### `ambient_context` exclusion

`SchemaBuilder` today hardcodes `EXCLUDED_FROM_SCHEMA = [:server_context]`. Generalize to: the `ambient_context` parent is never in the input schema. Because subfields render only nested under their present parent (`subfields_by_parent = subfield_configs.group_by(&:on)`), excluding the single parent drops all its subfields from the schema for free.

## 4. `Axn::Reflection::Values` — Result → JSON-safe Hash

Move only the transport-agnostic half of `axn-mcp`'s `Serializer`: `serialize_exposed(result, field_configs)` and `serialize_value(value)`. `result_to_mcp_response` and `success_response_text` reference `::MCP::Tool::Response` and **stay** in axn-mcp.

Home it as `Axn::Reflection::Values`. All three adapters need Result → JSON-safe Hash (MCP `structured_content`, REST body, RubyLLM return), so it is generic reflection and belongs in core.

## 5. `semantic_hints`

A single declarative, validated call for a tool's side-effect / operational profile. **Advisory only** — nothing enforces it (a `read_only` tool can still fire a destructive API call; especially `idempotent`, which we cannot detect). The `_hints` suffix keeps that honest. "Semantic" matches the MCP spec's own term and generalizes over effects (`read_only`, `destructive`) *and* operational behavior (`idempotent`) — `idempotent` is not an "effect", which is why `effect_hints` was rejected.

- **Core vocabulary:** `:read_only`, `:idempotent`, `:destructive`.
- **Adapters extend the vocabulary** via the extension registry — e.g. `axn-mcp` adds `:open_world` / `:closed_world` (MCP-spec-only), which proves the extension mechanism (an adapter-specific hint lives in the adapter, not core).
- **Adapters interpret hints:** MCP → tool annotations; REST → default HTTP verb (read_only→GET, idempotent→PUT, destructive→DELETE/POST); RubyLLM → optional safety gating.

Core stores the declared hints (class-level, inherited) and validates them against the known vocabulary (core vocab + any adapter-registered additions). Interpretation is entirely adapter-side.

## 6. `ambient_context`

Tools need ambient caller identity (`current_user`, `company`, …). Each surface sources it differently (MCP `server_context`; RubyLLM ambient/instance closure; REST the request), and the client must never *supply* these, so they must be excluded from the input schema.

The implementation is **existing Axn subfields**: subfields extract from a parent hash-like at runtime via `Core::FieldResolvers.resolve(type: :extract, …)` with indifferent access and the full validator stack (`type:`, `model:`, `of:`, `shape:`, `preprocess`), and render in the input schema only nested under their parent.

```ruby
class ListCompanyNotesTool
  include Axn
  description "List notes for a company."
  semantic_hints :read_only

  expects :company, on: :ambient_context      # reader is `company`; parent excluded from schema
  expects :limit, type: Integer, default: 20  # normal caller/LLM input, in the schema

  exposes :notes, type: Array, allow_blank: true
  def call = expose(notes: company.notes.limit(limit).map(&:as_json))
end
```

### The parent is always-reserved and defaults to `{}`

`ambient_context` is a **reserved parent on every Axn**, whose reader returns `{}` by default. Rationale: `on:` requires the parent reader to already exist (`contract_for_subfields.rb:55` rejects an unknown root), so a subfield-only opt-in cannot work without the parent being present. Making it always-present-and-empty is more coherent than lazy-declare-on-first-use: every Axn *can* carry ambient context, populated by how it is called; returning `{}` rather than `nil` sidesteps read errors on the empty path.

The name is `ambient_context` (not `context`, too generic and users may want their own; not `injected_context`, which names only one of three fill paths). It names *what it is* — ambient environmental state — true on every path. It is a narrower reserved name than `context`, and **replaces** the existing `server_context` reservation.

### Reads are declaration-gated; injection is declared-only

An action can only read `ambient_context.company` because it declared `expects :company, on: :ambient_context` — the subfield reader exists only for declared subfields. So the "explicit registration" property is enforced by the subfield mechanism regardless of what the parent hash contains.

The parent hash itself is **filtered to the declared ambient keys** — it never carries a merged dump of every `CurrentAttributes` in the process. This is the key departure from the ticket's original "reflective-dump-everything" default provider, and it eliminates three things: the "last-descendant-wins + raise-in-dev on cross-`CurrentAttributes` collision" machinery (collisions shrink to "did *this declared key* come from two sources", rare and cheaply raiseable), accidental over-exposure of unrelated `Current` state into logs/reports, and the fat hash. It costs nothing on the migration payoff — you still write one `expects` line and use the reader; the callsite still does not change.

### Resolution chain (per invocation, so per-request `Current` is correct)

1. **Explicit `ambient_context:` passed** → use it (filtered to declared keys). Adapters take this path — MCP maps `server_context`, REST maps the request; precise specs too. Explicit **replaces** the default, so an adapter never silently leaks server-side `Current` into a tool call; merge, if wanted, lives in a custom provider.
2. **Else → default provider**, then filter to declared keys. Overridable via `Axn.config.ambient_context_provider`, which can compose or replace.
3. **Else → `{}`** → required declared ambient subfields fail inbound validation with a clear message; optional ones read `nil`.

The provider stays "dumb" — it returns a source Hash (by default, a view over registered `CurrentAttributes`); **core** filters it down to the declared ambient subfield keys before injecting. Collision-raising, if kept, applies only to declared keys.

`ActiveSupport::CurrentAttributes` is always available to axn (`active_support.rb` autoloads it; axn already requires `active_support`), so the default provider adds no dependency. It is fiber/Falcon-safe on the same profile as plain `Current` (read via the isolated execution path at call time on the executing fiber). **Async caveat:** ambient context does not cross the `call_async`/Sidekiq boundary — an async-executed tool must pass explicit `ambient_context:`.

### Observability: replace the raw `current_attributes` capture

`Internal::ExceptionContext.build` today auto-attaches the raw global `::Current.attributes` to every error report as `current_attributes`, **unfiltered** (`format_hash_values` does GlobalID/params/formobject coercion only — no `ParameterFilter`). So Current state already leaks into error tracking, untyped and unfilterable.

Replace it (breaking change; acceptable in alpha). The declared `ambient_context` hash — resolved, typed, and sensitive-filterable because its keys are real subfield configs flowing through `_static_sensitive_fields` — is attached instead, as a framework-populated, **reserved** `:ambient_context` key in `execution_context`. In `RESERVED_EXECUTION_CONTEXT_KEYS`, `:current_attributes` is replaced by `:ambient_context`, and `ExceptionContext.build`'s raw `::Current` block is removed. It is sensitive-filtered on the way in.

No new `on_exception` argument is needed — `on_exception(e, action:, context:)` already receives everything `ExceptionContext.build` assembles, so `ambient_context` rides the existing `context:` hash straight into Honeybadger/Sentry.

**Routine logging:** keep `ambient_context` *out* of the default per-call input/output log lines (so every log line does not grow an ambient blob) but *present* in the exception/observability context — quiet on the happy path, rich on failure. This also means the `ambient_context` parent is excluded from `inputs`/`outputs_for_logging`, not just from the schema.

### Rubocop cop (opt-in)

The repo already ships opt-in cops (`lib/rubocop/cop/axn/unchecked_result.rb` + README). Add an opt-in cop — e.g. `Axn/AmbientContextBypass` — that flags direct `::Current.foo` / `Current.foo` reads and steers toward a declared `on: :ambient_context` field. This makes the migration enforceable rather than merely available.

## 7. Class-level extension registry

Adapters need to, at load time, register transport-specific class-level DSL and an inherited per-adapter metadata bag, which `wrap` reads via something like `klass.extension_metadata(:mcp)`. Precedent already exists: `Axn.config.additional_includes`, `Axn::ExtensionConfig#registered_field_metadata_keys`, `Axn::Mountable`'s `class_attribute` + `inherited` pattern, and — most directly — `Axn::Configurable#overrides`, which already implements per-class, inherited, validated, load-order-insensitive class-level settings via a shared module that classes extend.

Build the registry **on `Configurable#overrides`** rather than hand-rolling a new `class_attribute` bag, so adapter-registered DSL and per-adapter metadata inherit the same per-class inheritance, validation, and load-order-insensitivity for free. The exact registration API (`Axn.register_extension(:mcp, dsl: …)` vs reopening `ClassMethods`) is deferred to the implementation plan; the constraint is that it reuses the `overrides` machinery.

`semantic_hints` vocabulary extension (an adapter adding `:open_world`/`:closed_world`) flows through this registry.

## Backward compatibility

`Axn::MCP::Tool` remains a thin convenience base — it will `include Axn` and self-register the MCP adapter — so the 7 existing os-app MCP tools subclassing it keep working. New author-once tools are plain Axns wrapped per surface. RubyLLM tools are greenfield (os-app has zero RubyLLM *tool* subclasses today).

**Breaking (acceptable in alpha):** the raw `current_attributes` key in exception reports is replaced by the declared, filtered `ambient_context`; the `server_context` reservation is replaced by `ambient_context`.

## Testing

- Reflection schema: unit tests over plain Hashes for each validation vocabulary element (`type:`, `model:`, `of:`, `shape:`, `inclusion:`, defaults, optional/required, nested subfields), plus the round-trip that `input_schema`/`output_schema` expose them. Explicit test that `sensitive: true` does not change schema output.
- Reflection values: serialization of scalars, Hash/Array, `as_json`/`to_h` fallbacks.
- `axn_name` / `description`: resolution order and inheritance; logging prefix uses resolved name.
- `semantic_hints`: vocabulary validation, inheritance, rejection of unknown hints (with adapter-extended vocab).
- `ambient_context`: always-reserved parent reads `{}`; declared subfield reads from explicit/provider/empty; declared-only filtering; required-subfield validation failure message; sensitive filtering into exception context; exclusion from schema and from routine logging; async boundary caveat.
- Extension registry: an in-test adapter registers DSL + metadata; inheritance and load-order-insensitivity.
- Non-Rails: all of the above must pass in `spec/` (non-Rails) as well as `spec_rails/`; guard any AR/Rails constants with `defined?()`.

## Deferred / open

- Exact registry registration API shape (built on `Configurable#overrides` either way).
- Whether core ships a convenience that auto-wires the ambient provider when a configured `Current` class is present (the lambda stays the primitive regardless).
- `render_as` DSL naming, per adapter (adapter tickets).
- Whether `Factory.build` should accept `axn_name` / `description` / `semantic_hints` as options (minor; can follow).
