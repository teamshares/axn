# Changelog

## Unreleased

### Field contract & subfields

* [BREAKING] Field keys are normalized to symbols, giving the contract indifferent access: `expects "note"` ≡ `expects :note`, `.call("note" => …)` ≡ `.call(note: …)`, and string keys on `expose` all resolve to the declared symbol. Splatting a string-keyed params hash into `.call(**params)` no longer silently reads `nil`. Normalization is top-level keys only; field values (including nested hashes) are untouched.
* [FEAT] `expects … on:` (subfields) now supports the full top-level option surface — `default:`, `preprocess:`, `coerce:`, `sensitive:`, `shape:`, and `user_facing:` — at any nesting depth. Subfields nest arbitrarily deep, and a dotted `on:` pulls a value out of a deeply-nested structure in one line: `expects :zip, on: "address.billing"` validates `address[:billing][:zip]` and defines a flat `zip` reader.
* [BREAKING] Dotted field NAMES are removed. Use a dotted `on:` for nested extraction (`expects :zip, on: "address.billing"`, not `expects "billing.zip", on: :address`) — it generates a clean flat reader with no `as:` ceremony. To read two values from the same wire key, disambiguate the distinct routes with `as:`.
* [BREAKING] All subfield `coerce:`/`preprocess:`/`default:` resolve on the read path, and axn never materializes or mutates the parent to apply them. A subfield transform is visible through its own reader and validation, but the parent reader returns exactly what the caller passed — `expects :note, on: :payload, default: "d"` with `payload: nil` leaves `payload` `nil` and `note` `"d"`. A subfield `default:` no longer satisfies the parent's own presence check, and a caller-supplied object is never written through its setter during validation.
* [BREAKING] Reading a subfield by method dispatch now requires `method_call: true`. The safe default reads declared data only — Hash keys and `Struct`/`OpenStruct`/`Data` members. Reaching a value that can only be resolved by invoking a method (a plain object's reader, an `Array` method, a resolved `model:` record's attribute) requires `method_call: true` on that declaration; without it axn raises a loud `MethodCallNotPermittedError` rather than silently invoking the method during validation. The same rule applies to shape-block members.
* [FEAT] A subfield whose parent is omitted or `nil` is treated as "subfields absent" — each subfield's own rule applies against `nil` (optional passes, required fails cleanly with `InboundValidationError`), instead of raising. An all-optional nested structure can simply be omitted.
* [BREAKING] Several unsatisfiable contracts now raise at class definition instead of failing (or silently reading absent) on every call: a subfield path no contract-valid input could answer; a nil-tolerant field with an unrescued required descendant; two `default:`s on one merged wire node; and a `model:` batch that also names its own `<field>_id`. Each error names the offending declarations and the fix.
* [FEAT] A failing call now collects every violation across top-level fields, subfields, and model-consistency and reports them together, and each nested-subfield failure names the stranding hop (`'payload.address' is nil, so nested expectations beneath it cannot be satisfied`).
* [BREAKING] `readers:` is removed — every declared field generates a reader. Use `as:`/`prefix:` to rename a colliding reader.
* [FEAT] `as:`/`prefix:` rename a field's generated reader independently of the wire key (`expects :channel, as: :raw_channel`), freeing the name for your own method; `prefix:` renames several subfields at once (`prefix: :event_`).

### Validation, coercion & schema

* [FEAT] `coerce:` parses an inbound wire string into a field's declared Ruby type before validation, so a JSON or form client sending `"2026-07-08"` or `"123"` is accepted for a `Date`/`Integer` field. Coercible types are `Date`, `DateTime`, `Time`, `Symbol`, `Integer`, `Float`, and `:boolean`. Coercion is opt-in per field and coerce-or-leave (a real Ruby value passes through; an unparseable string fails validation normally, reported as "could not be coerced to a Date"). No effect on `input_schema`/`output_schema`.
* [FEAT] `coerce_input_types` (a per-class-overridable config setting) turns on `coerce:` for every coercible top-level field and subfield of an action — for a fully transport-facing action such as a controller handing it a params hash or an adapter decoding JSON — without annotating each field. A field's own `coerce:` always wins.
* [FEAT] Tolerance flags now combine with a scalar validator value: `expects :num, numericality: true, optional: true` (and likewise `inclusion:`/`format:` under `optional:`/`allow_nil:`/`allow_blank:`) work instead of raising a `TypeError`.
* [FEAT] Conditional validation: `expects`/`exposes` (and shape members) accept `if:`/`unless:`. The condition gates every validator including the implicit presence check, so requiredness itself can be conditional — expressing the conditionally-required-subfield pattern (`expects :user, on: :data, if: -> { data.present? }`). `error`/`success` and the `on_*` callbacks now also accept `if:` and `unless:` together (combined with AND).
* [FEAT] `MyAxn.input_schema` / `MyAxn.output_schema` return JSON Schema derived from `expects`/`exposes` (subfields, `model:`, `of:`, `shape:`, `inclusion:`, defaults, unions), and `Axn::Reflection::Values.serialize_exposed` renders a `Result` to a JSON-safe Hash — one definition an adapter can turn into an MCP `inputSchema`, an LLM `parameters` block, or an OpenAPI schema. Read-only and off the execution path; `sensitive:` has no effect on schema output.
* [BUGFIX] A bare-Array `inclusion:` shorthand (`inclusion: %w[a b c]`) now reflects into `input_schema`/`output_schema` identically to the `{ in: [...] }` / `{ within: [...] }` long form — emitting the `enum` and inferring the member type, and contributing its nil-membership to the field's nullability/requiredness (a bare set containing `nil`, and a bare `exclusion:` set not containing `nil`, are now correctly read as nil-tolerant). Previously the bare form validated at runtime but reflected as an unconstrained `{}`, leaving schema looser than runtime.

### Shape blocks

* [FEAT] Shape-block members accept `sensitive:` (redacted from logs, exception context, and `inspect` — precisely by member name for Hash values, wholesale for non-Hash values the filter can't descend into), `method_call:`, `if:`/`unless:`, and `user_facing:`, all with the same semantics as a top-level field.
* [BREAKING] `model:` on a shape member now raises at declaration — a member is reader-less and never resolves a record. Use `type: Klass` for a plain instance check.

### `model:` fields

* [FEAT] A `model:` field now also defines a `<field>_id` reader that returns the record's primary key, whether the action was called with `user:` or `user_id:`. It's alias-aware and triggers no extra lookup.
* [BREAKING] Passing both a `model:` record and a contradictory `<field>_id` (default `:find` finder) now raises `InboundValidationError` instead of silently preferring the record. Passing one, or both in agreement, is unchanged.
* [FEAT] A `model:` field's record lookup consumes the read-path-transformed `<field>_id`: when a sibling `<field>_id` declares `coerce:`/`preprocess:`/`default:`, the finder sees the transformed id (or the sibling's `default:` when the id is omitted), so an id-only input resolves the same record the `<field>_id` reader reports.
* [BREAKING] `coerce:`/`preprocess:` on a `model:` field or subfield now raise at declaration — a model field resolves a record, not a scalar wire value. Transform the `<field>_id` field instead.
* [BREAKING] `model:` record and key reads now route through the canonical reader path (dispatching the reader method for object sources, indifferent to string/symbol keys for Hash sources), unifying model resolution with every other reader.

### `ambient_context`

* [FEAT] `ambient_context` is a reserved, always-present parent for ambient caller identity (`current_user`, `company`, …). Declare `expects :company, on: :ambient_context` and read `company` through the full validator stack; the parent is excluded from `input_schema` (so a client or LLM can never supply it) and only declared subfields get readers. Per invocation the value comes from an explicit `ambient_context:` kwarg, else `Axn.config.ambient_context_provider`, else a view over the registered `ActiveSupport::CurrentAttributes`, then filtered to the declared keys. It does not cross the `call_async` boundary.
* [FEAT] Ambient subfields support `default:`/`preprocess:`/`coerce:`/`sensitive:` and a leaf `shape:`, and nest to any depth — a dotted `on: "ambient_context.request"` or a subfield under an ambient subfield. The filtered hash is reconstructed along each declared path, so an undeclared sibling at any depth never reaches the resolved value, logs, or exception context. `user_facing:` stays rejected (an ambient value is framework-supplied, so there is no caller to face).
* [BREAKING] Exception reports now carry the declared, sensitive-filtered `ambient_context` instead of the raw, unfiltered global `::Current.attributes` — replacing the reserved `current_attributes` context key with `ambient_context`. Breaking for any error-tracker rule, `on_exception` handler, or spec keyed on the old key.
* [FEAT] `with_ambient_context(**attrs)` test helper (auto-included into RSpec) injects ambient inputs for a block across the whole call chain — the action under test and any nested calls — restoring the provider afterward. An opt-in `Axn/AmbientContextBypass` RuboCop cop flags direct `Current.<attr>` reads inside actions, steering toward a declared ambient subfield.

### Failures & messages

* [FEAT] A declared base `error "…"` composes with an action's failure reasons: a conditional `error … if:`/`unless:`, a `fail!` message, or an entry marked `standalone: false` renders as `"<base>: <reason>"`. An unconditional entry is the base headline; conditionality sets the role, overridable with `standalone:`. `join:` on the base controls the separator (a String, or a `->(base, reason) {}` Proc). `success`/`done!` mirror this. `result.error` returns the composed string, and for axn-owned failures the raised exception's `#message` is stamped to match it.
* [FEAT] `fails_on` reclassifies chosen exception classes from the exception outcome into the failure outcome — firing `on_failure`, skipping the global `on_exception` report, and keeping the original exception on `result.exception`. It accepts a message, a block, an array of classes, and `standalone:`. Classification is sticky to the exception object and flows outward only, so declare it on the action that raises. `result.error` never defaults to the exception's own `#message`; opt one in with `fails_on Klass, &:message` when the message is genuinely user-facing.
* [FEAT] `user_facing:` marks an `expects` field whose violation is the caller's fault, reclassifying it from the exception bucket into the failure bucket (fires `on_failure`, skips the global report, surfaces the field's validation message on `result.error`). The value rides `fail!` muscle memory — `true`, a String, a Symbol, or a callable. The field stays required. It composes uniformly at every declaration depth, including shape members; in a mixed failure any dev-facing field still dominates, so a real contract bug is never masked. Rejected on `exposes` and on ambient subfields.
* [BREAKING] A nested `call!` failure re-raises the inner action's original exception (previously a fresh `Axn::Failure` wrapping it, with a `source:` pointer — both removed), so `Axn::Failure` now means exactly "`fail!` was called". A nested `call!` aggregates every level's declared base header (`"Outer: Inner: leaf"`), and an unhandled exception is reported to the global `on_exception` once, at the innermost executor. To reshape a child's error, run it with non-bang `call` and re-`fail!`; to branch on a failure, match the exception type or `result.exception` rather than the message string.
* [BREAKING] `error from:` and the per-message `prefix:` option on `error`/`success` are removed. Use a declared base `error "…"` and the `call` + `fail!` idiom for cross-action message shaping.
* [BREAKING] Removed the experimental `_include_retry_command_in_exceptions` setting and its `retry_command` exception-context key — it embedded field values into a single command string that defeated key-based redaction in error trackers. Use the structured `inputs`/`outputs` context, whose per-key filtering is intact.
* [BREAKING] Actions can no longer be instantiated directly — `new` is a private class method. Use `.call`/`.call!` (which build the instance internally, running hooks and validation); a test needing a bare instance can `.send(:new, …)`.

### Steps

* [FEAT] `step` accepts `if:`/`unless:` (a Proc `instance_exec`'d on the parent, or a Symbol naming a parent method, combinable), evaluated immediately before the step would run. A skipped step exposes nothing and cannot fail; later steps still run.
* [BREAKING] A step that raises an unexpected exception now settles the parent as an exception (fires `on_exception`/`on_error`, not `on_failure`), while a deliberate `fail!` or a `fails_on`-classified exception still settles the parent as a failure with the composed message. Declaring steps and a custom `#call` on the same class now raises `ArgumentError` at load time.

### Async

* [BREAKING] The Sidekiq adapter no longer turns the action into a `Sidekiq::Job`. A generic worker runs every action by name, so `MyAction.perform_async`/`sidekiq_options`/`.set`, and Sidekiq's class-level testing helpers (`.jobs`/`.drain`/`.perform_one`) are gone from the action — use `call_async`. Per-action config is unchanged in spelling (`async :sidekiq, queue: "x", retry: 3` and the `async :sidekiq do … end` block form), now applied to a per-action worker subclass. The Web UI still shows the real action name. Verified on Sidekiq 7 and 8.
* [FEAT] Async argument serialization uses `ActiveJob::Arguments` whenever ActiveJob is loaded (for all adapters, including Sidekiq), so GlobalID models, `Date`/`Time`/`DateTime`, `Symbol`, `Range`, `BigDecimal`, and nested symbol-keyed hashes round-trip losslessly — fixing a Sidekiq-enqueued `expects :at, type: Time` that used to arrive as a `String`. A deployment without ActiveJob accepts only JSON-native and GlobalID-able args.
* [BREAKING] Enqueuing an async action with an unserializable argument now raises a field-aware `Axn::Async::UnserializableArgument` at enqueue time instead of silently corrupting it. The Sidekiq wire format changed to ActiveJob's `_aj_*` tagging for rich types — drain the queue across the deploy.
* [FEAT] `Axn::Async.owns?(candidate)` answers "is this job/notice signal Axn-owned?" for error-reporter `before_notify`-style filters that suppress duplicate backend-native reports; it accepts a Class, a class-name String, or a raw Sidekiq job Hash. `Axn::Async.register_ownership_predicate` lets an adapter extend detection.

### Logging & observability

* [BREAKING] `log_calls` and `log_errors` are replaced by a single declarative `auto_log` that resolves a level (or off) per outcome — `success`, `failure`, `exception`. A positional level is the default for any unnamed outcome; keyword overrides target one outcome, so `auto_log exception: :error` logs only raised exceptions, distinguishing an unhandled raise from an expected `fail!`. Migration: `log_calls <lvl>` → `auto_log <lvl>`; `log_calls false` → `auto_log false`; `log_calls false` + `log_errors <lvl>` → `auto_log <lvl>, success: false`.
* [FEAT] `tag` (high-cardinality) and `dimension` (bounded) declare per-action observability facets, resolved from inputs before the body (`from: :inputs`) or from the settled result (`from: :result`). Each facet flows to the `axn.call` OpenTelemetry span, the notification payload, `emit_metrics`, `auto_log` output (as SemanticLogger tags, or a readable suffix under any other logger), the `on_exception` report (`context[:tags]`/`context[:dimensions]`, now reserved keys), and Sidekiq per-job tags (selected by `Axn.config.sidekiq_job_tag_sources`, per-class overridable).
* [BREAKING] `on_success` now fires after the enclosing transaction commits (immediately when none is open) and is skipped on rollback, so an action nested inside another's transaction no longer fires its side effect when the outer transaction later rolls back. Implemented via `ActiveRecord.after_all_transactions_commit` (requires ActiveRecord 7.2+; inline without ActiveRecord). Failure-path callbacks are unaffected.
* [FEAT] `on_enqueue_all` is a once-per-run callback for `enqueues_each`/`enqueue_all` fan-out, firing after the loop completes with the enqueued `count:` and a `sources:` hash (flexible arity). It's error-isolated, so a raising callback can't abort the fan-out.

### Configuration

* [FEAT] `Axn::Configurable` is a small DSL for gems built on Axn to declare validated configuration — `setting` with `default:`/`one_of:`/`validate:`/`callable:` and a `<name>?` predicate — instead of hand-rolling a config object, `configure` yielder, and test reset. `extend Axn::Configurable::Settings` declares the same validated settings as instance accessors on a plain class.
* [FEAT] Settings declared `overridable: true` gain per-class overrides on actions: `MyAction.configure { |c| c.setting = value }` resolves the nearest-ancestor override and falls back to the library default, inherits into subclasses, and never leaks to siblings or mutates `Axn.config`. Each overridable setting also gets a `<name>?` predicate and a `<name>_override` reader (the stored override, or the `UNSET` sentinel with no fallback). Per-class config is namespaced — `configure(:mcp) { … }` — so an action composing several adapter mixins carries each adapter's overrides without collision.

### Tools & adapters

* [FEAT] Tool support: every Axn derives one provider-safe `tool_name` (mirroring an explicit `axn_name`, else derived from the class name), and a `tool` class-DSL declares registry membership — `tool` (every registered adapter), `tool :mcp, :ruby_llm` (an explicit set), `tool false` (opt out), `tool name: "…"` (override). `Axn.tools_for(:mcp)` returns an adapter's member classes in deterministic `tool_name` order, and adapters self-register via `Axn.register_tool_adapter(:mcp)`. Membership is fail-safe — only classes explicitly marked, living under an adapter's `tool_roots` dir, or carrying a `configure(<adapter>)` bag are exposed.
* [FEAT] The `tool` DSL accepts per-adapter option bags — `tool mcp: { title: "Search", present_as: :message }, ruby_llm: { halt_after: true }` — as sugar over `configure(<adapter>)`: each key lands in the same per-class override store and resolves the same way, and a bag key implies membership in that adapter. `name:` inside a bag overrides the provider name for that adapter only (bare `tool name:` stays shared across adapters); a per-adapter name is honored by `Axn.tools_for`'s ordering and duplicate detection. Bag keys are validated eagerly when the adapter is loaded and tolerantly otherwise, exactly like `configure`.
* [FEAT] `Axn::Factory.build` accepts the full class-level DSL, so a factory-built Axn can declare everything a hand-written class can: `axn_name:`, `description:`, `semantic_hints:`, and the accumulating `fails_on:`/`tag:`/`dimension:` (each a single spec or a list of specs). Now documented at `/reference/factory`.
* [FEAT] Class-level `axn_name "…"` and `description "…"`, both inherited. `axn_name` is the single source of an action's display name across logging, the `axn.call` notification `resource` (the Datadog dimension), exception breadcrumbs, and profiling labels — so a factory-built or adapter-wrapped tool reports under one canonical identity. The async enqueue/constantize path still uses the real Ruby class name.
* [FEAT] `semantic_hints :read_only, :idempotent, :destructive` — an advisory declaration of an action's side-effect profile, inherited and extensible by adapters. Class-level extension primitives (`Axn::Extensions.config.register_semantic_hint`, `Klass.set_extension_metadata` / `extension_metadata`) let an adapter hang transport-specific config off any Axn with no marker mixin.
* [FEAT] `Axn::Tools::Invoker` — run an Axn as a tool with auto-coercion and opt-in structured, non-reported inbound-validation surfacing (`user_facing_input_errors`, `reject_undeclared_inputs`); adds `ValidationError#field_errors`. Normal `.call` semantics unchanged. (PRO-2943)
* [BREAKING] Tool adapter membership is now the union of a per-adapter directory grant and the `tool` declaration, minus a new `except:` opt-out. An explicit `tool :openapi` now *adds* that adapter on top of the tool's directory grant instead of replacing it. `tool except: :ruby_llm` removes a single adapter; `tool false` still opts out of all.
* [BREAKING] The global `Axn.config.tool_paths` setting is removed. Each adapter declares the directories it serves via `tool_roots` on its own config (`Axn::MCP.configure { |c| c.tool_roots = %w[agent_tools] }`); a directory shared by several adapters is listed under each. The same broad-path guard (`actions`/`app`/`.`/`..` rejected) applies.
* [BREAKING] `register_tool_adapter` takes an optional config source (`Axn.register_tool_adapter(:mcp, self)`) so the registry can read that adapter's `tool_roots`. Adapters with no directory roots may omit it.
* [FEAT] Ship `AGENTS-tool-adapters.md` at the gem root and an "Authoring a Tool-Adapter Gem" docs recipe (`/recipes/authoring-tool-adapters`) — the conventions for building a gem that exposes Axns over a transport (MCP/RubyLLM/HTTP), so a downstream author has one source of truth instead of reverse-engineering an existing adapter. Covers registration + `tools_for` discovery, the zero-arg `.tools`/`.wrap` pair, `tool_name`/`input_schema`/`output_schema`/`serialize_exposed` reflection (and why an adapter must never override `input_schema` to a non-Hash on the shared class), per-adapter `Axn::Configurable` config resolved via `resolve_override_for`, the `semantic_hints` extension registry, `Axn::Result` → transport mapping (surface `result.error`, keep `result.exception` dev-facing, `owns_failure_exception?`, no gem-wide headline), spreading `ambient_context:`, `IsolatedExecutionState`-scoped transport-capability handles, inline `Axn::Factory.build` tools, and testing against real transport objects. Grounded throughout in `axn-mcp` and `axn-ruby_llm`.

### Other

* [FEAT] `inputs` returns the action's resolved declared-inbound fields as a Hash, for splatting into nested calls (`Child.call(**inputs, role: ROLE)`); `inputs` is now a reserved field name. `expose(result)` forwards a nested action result's declared exposures (the intersection with the current action's `exposes`) in one call.
* [BUGFIX] `Axn.config.logger` no longer returns `nil` during the Rails boot window (when `Rails` is defined but `Rails.logger` isn't set yet), which had crashed any load-time log call — notably `include Axn` on a class whose ancestor defines `description`. It falls back to a transient stdout logger without memoizing, so a later call picks up `Rails.logger` once the initializer has run.
* [BUGFIX] Re-including `Axn` in a subclass (`class Child < Parent; include Axn; end`) is now a no-op instead of silently wiping the parent's inherited `expects`/`exposes`.
* [BUGFIX] `include Axn` no longer shadows a `description`/`input_schema`/`output_schema` class method the including class already inherits from a non-axn base (e.g. an adapter's `Tool` base where those names carry transport meaning) — axn layers its own only when the name isn't already provided.
* [FEAT] Ship `AGENTS-consuming.md` at the gem root (packaged in the gem, readable offline via `bundle show axn`) — a dense, agent-facing cheat-sheet for code that uses Axn. README gains an "Using Axn with an AI agent" section with a copy-paste snippet.
* [INTERNAL] The packaged gem now uses an explicit `spec.files` allowlist (`lib/` + `README`/`CHANGELOG`/`LICENSE` + the `AGENTS-consuming.md`/`AGENTS-tool-adapters.md` guides) instead of a `git ls-files` denylist, so the VitePress `docs/` site and editor/tooling files no longer ship (177 → 132 files). Contributor tooling: the pre-commit RuboCop hook moved to lefthook (`bin/setup` installs it), and `bin/new-gem` gained a `--check` conformance audit for downstream gems.

### Namespaces & extension API

* [BREAKING] The dev-loud/prod-quiet best-effort guard is now `Axn::Extensions.best_effort("intent") { … }` (block form) — the sanctioned surface for gems building on axn. `Axn::Internal::PipingError` is removed. Config knob `raise_piping_errors_in_dev` is renamed `best_effort_raises_in_dev`.
* [BREAKING] The extension-config registry moved to the `Axn::Extensions` namespace: `Axn.extension_config` → `Axn::Extensions.config`, `Axn::ExtensionConfig` → `Axn::Extensions::Config` (methods like `register_semantic_hint` unchanged on the object).
* [BREAKING] Internal machinery moved out of the top-level `Axn::` namespace under `Axn::Core` (`Executor`, `Context`, `ContextFacade`, `ContextFacadeInspector`, `InternalContext`); public constants (`Result`, `Failure`, `Factory`, `FormObject`, `Configuration`, `Strategies`, the exception classes) stay top-level. Sibling gems own `Axn::<GemName>`; policy documented in AGENTS.md.

## 0.1.0-alpha.4.3
* [FEAT] Plain namespace **modules** can now host mounted actions: `include Axn::Mountable` on a module (not just a class) exposes `mount_axn` / `mount_axn_method` / `step`. Class hosts keep the existing `class_attribute` + `inherited` behavior; module hosts use singleton accessors and skip the `inherited` hook (modules have no subclasses). Also fixes a `.name` clobber so passing an already-named class to `mount_axn` preserves its original name instead of rewriting it to the `Axns` namespace path.
* [BUGFIX] Fixed an off-by-one in `async.attempt` reported from the Sidekiq death handler: Sidekiq increments `retry_count` before invoking death handlers, so an exhausted `retry: 3` job (4 executions) reported attempt `5` instead of `4`. The bug was metadata-only — control flow (`retries_exhausted?`, `first_attempt?`, `should_trigger_on_exception?`) was unaffected. Also documents why framework-native integrations (e.g. Honeybadger's Sidekiq plugin) can produce duplicate async error reports, with a tag-and-filter suppression recipe.
* [BUGFIX] Subfield names that collide with a method on the parent value (e.g. `zip`, `count`, `first` — any `Hash`/`Enumerable` method) are now read as keys instead of being dispatched as method calls. Previously `expects :zip, on: :address` extracted `address.zip` (`Enumerable#zip`) and failed with a bogus error; `FieldResolvers::Extract` now digs the key first for Hash-like sources and only falls back to a reader method for non-diggable objects (e.g. `Data` instances).
* [FEAT] `expects … on:` now accepts a **dotted path** to reach a deeply-nested parent (e.g. `expects :zip, on: "address.billing", type: String` validates `address[:billing][:zip]` and defines a flat `zip` reader). The root segment must be a declared field/subfield. `default:`/`preprocess:`/`sensitive:` combined with a dotted `on:` raise `ArgumentError` (writing into — and redacting — an arbitrary nested path isn't supported yet); single-key `on:` is unchanged.
* [FEAT] Add block syntax for declaring the per-member shape of a structured field on `expects`/`exposes`. On a `type: Array`, `type: Hash`, or class-typed field, a block declares member contracts: `expects :items, type: Array do field :status, type: String, inclusion: { in: %w[a b] } end`. Members accept the same options as top-level fields (`type`, `inclusion`, `optional`, `description`, …) and recurse via nested blocks. For arrays each element is validated with indexed errors (`element at index 2: status …`); for a single Hash/object value its members are validated directly. The block requires a single structured `type:` (raises `ArgumentError` on scalars, unions, or no type), composes with `of:` (which still checks element class), and — unlike `on:` subfields — defines **no** reader methods. Downstream tooling reads members from `config.validations[:shape][:members]`.
* [FEAT] Add `of:` array-element validation for `expects`/`exposes`. On a `type: Array` field, `of:` validates each element: a single class (`of: String`), a union (`of: [String, Numeric]` — an element passes if it matches *any*), the `:boolean`/`:uuid`/`:params` symbols, or a `Data.define` class. Only valid alongside `type: Array` (raises `ArgumentError` otherwise, including for unions like `type: [Array, String]`). Error messages report the failing element's index (e.g. `element at index 2 is not a String`) and honor a custom `message:`. `optional`/`allow_blank`/`allow_nil` govern whether the whole field may be absent — they do not make individual elements blank-able. Downstream tooling can read the element type from `config.validations[:of][:klass]`.
* [FEAT] `exposes`-declared fields that are also `expects`-declared are now auto-copied from the input into the result on **all** outcome paths — success, `done!`, `fail!`, and unhandled exception. Previously, the auto-copy only ran on success/`done!` paths, leaving `result.field` as `nil` after `fail!` or an exception even when the field was provided as input. This is particularly useful for re-exposing mutated ActiveRecord objects (e.g. inspecting `user.errors` after a failed save). Explicit `expose` calls before a failure continue to work and take precedence.
* [FEAT] Execution log messages now display elapsed time in human-readable units (milliseconds, seconds, minutes, or hours) instead of always showing milliseconds
* [BREAKING] `exposes` no longer defines a direct reader method on the action instance. Exposed fields must be accessed via `result.field` (e.g., `result.greeting`). `expects` readers are unaffected. User-defined methods with the same name as an exposed field are preserved (DefaultCall still calls them). Use `result.field` in `success`/`error` message callables and `sensitive:` procs to access output values.
* [FEAT] Add boolean predicate readers for `expects` and `exposes`: `expects :enabled, type: :boolean` defines `enabled?` on the action instance; `exposes :enabled, type: :boolean` defines `result.enabled?`.
* [BUGFIX] `ExceptionContext.build` no longer raises `URI::GID::MissingModelIdError` when an exposed or expected value is an unpersisted ActiveRecord record. The formatter now renders such values as `#<ClassName (unpersisted)>` and the optional retry command falls back to `inspect` instead of generating `Model.find(nil)`.
* [FEAT] Add dynamic `sensitive:` option support for `expects` and `exposes` fields - accepts procs or symbols that are evaluated at runtime against the action instance, allowing conditional sensitivity based on input values (e.g., `exposes :data, sensitive: -> { redact_mode }`)

## 0.1.0-alpha.4.2
* [FEAT] Add extensible field metadata support for `expects`/`exposes`:
  * **New** `Axn.extension_config` registry for library-facing configuration (separate from app-facing `Axn.config`)
  * **New** `description:` metadata option for field declarations (e.g., `expects :name, description: "The user's name"`)
  * **New** `FieldConfig#metadata` and `SubfieldConfig#metadata` attributes with `#description` accessor
  * **New** `Axn.extension_config.register_field_metadata_key(:key)` for wrapper gems to register custom metadata keys
  * **New** Unknown validation keys now raise `ArgumentError` (catches typos like `nummericality:`)
  * **New** Metadata can only be provided when declaring a single field (multi-field + metadata raises `ArgumentError`)
* [FEAT] Add `readers:` option validation: `readers: false` now raises `ArgumentError` when used without `on:` (only valid for subfields)
* [BUGFIX] `set_default_async(:sidekiq)` now properly triggers `AutoConfigure.register!`
* [BREAKING] Refactored context API for exception reporting and handlers:
  * **Removed** `context_for_logging(direction)` instance method
  * **Added** public `execution_context` method returning structured hash: `{ inputs: {...}, outputs: {...}, **extra_keys }`
  * **Added** private `inputs_for_logging` / `outputs_for_logging` methods for automatic pre/post logging (do NOT include extra context)
  * **Renamed** `set_logging_context` → `set_execution_context`, `clear_logging_context` → `clear_execution_context`, hook `additional_logging_context` → `additional_execution_context`
  * **Reserved keys:** `:inputs` and `:outputs` cannot be set via `set_execution_context` or the hook—they always come from the action's contract
  * **Internal:** Class method `context_for_logging(data:, direction:)` renamed to `_context_slice(data:, direction:)`
  * Exception context now includes both `inputs` and `outputs` with additional context merged at the top level (not nested inside `inputs`)

## 0.1.0-alpha.4.1
* [BREAKING][BUGFIX] `fail!` in async jobs no longer triggers retries - business logic failures complete without retry (Sidekiq and ActiveJob adapters)
* [FEAT] Add `async_exception_reporting` config to control when `on_exception` triggers in async context (`:every_attempt`, `:first_and_exhausted`, `:only_exhausted`)
* [FEAT] Add retry context to `on_exception` calls in async jobs - includes attempt number, max retries, exhausted status, and job ID
* [INTERNAL] ActiveJob adapter now uses `after_discard` callback (Rails 7.1+) to properly report discarded jobs including `discard_on` exceptions and exhausted retries
* [FEAT] Add ability for individual actions to override global `async_exception_reporting`

## 0.1.0-alpha.4
* [FEAT] Action class constants are now created eagerly when child classes inherit from parents with mounted actions, allowing direct constant access (e.g., `TeamsharesAPI::Company::Axns::Get.call`)
* [FEAT] Add ability to determine if currently running in background
* [FEAT] Handle done! and fail! while executing user blocks
* [BREAKING] `emit_metrics` hook now receives keyword arguments (`resource:`, `result:`) instead of positional arguments
* [FEAT] Default `call` method automatically exposes declared exposures by calling methods with matching names - you can now omit `call` entirely when you only need to expose values from private methods
* [BREAKING] Rename `auto_log` -> `log_calls`
* [FEAT] Add `log_errors`
* [FEAT] Add `raise_piping_errors_in_dev` config option to raise framework errors in dev only
* [BREAKING] Convert profiling from `profile` method to `use :vernier` strategy - profiling now only captures hooks and user code (excludes framework overhead like tracing, logging, timing)
* [FEAT] Add `set_logging_context` and `additional_logging_context` hook to inject additional context into exception logging
* [FEAT] Added ActiveSupport::Notification emission for `axn.call_async` (separate from `axn.call`) - emits notification when async jobs are enqueued with payload including resource, action_class, kwargs, and adapter name
* [INTERNAL] Refactored async adapters to use template method pattern - adapters now implement `_enqueue_async_job` hook instead of overriding `call_async`, eliminating duplication of notification and logging logic
* [FEAT] Enhanced `error from:` to support arrays of child classes and `from: true` to match any child action - prefix is now optional when using `from:`
* Improve handling of _async options to call_async (bugfix + serialization improvements)
* [BREAKING] Replace `enqueue_all_via` block with new `enqueues_each` DSL (now in `Axn::Async`) - declarative batch enqueueing for background job processing

## 0.1.0-alpha.3
* [FEAT] Added Vernier profiling support with `profile if:` conditional interface and `Axn.config.profiling` configuration
* [FEAT] Extended model validation to support custom finder methods with `expects :user, model: { klass: User, finder: :find }` syntax
* [BREAKING] Removed `#try` method
* [BREAKING] Removed `Axn()` method sugar (use `Axn::Factory.build` directly)
* [BREAKING] Renamed `Action::Configuration` + `Action.config` -> `Axn::Configuration` + `Axn.config`
* [BREAKING] Move `Axn::Util` to `Axn::Internal::Logging`
* [BREAKING] !! Move all `Action` to `Axn` (notably `include Action` is now `include Axn`)
* [FEAT] Continues to support plain ruby usage, but when used alongside Rails now includes a Rails Engine integrate automatically (e.g. providing generators).
  * Added Rails generator `rails generate axn Some::Action::Name foo bar` to create action classes with expectations
  * Autoload actions from `app/actions` (add config.rails.app_actions_autoload_namespace to allow setting custom namespace)
* [INTERNAL] Clearer hooks for supporting additional background providers in the future
* [BREAKING] spec_helpers: removed rarely used `build_axn`; renamed existing `build_action` -> `build_axn`
* [FEAT] `Axn::Factory.build` can receive a callable OR a block
* [FEAT] Added `#finalized?` method to `Axn::Result` to check if result has completed execution
* [FEAT] Added `type: :params` validation option for `expects`/`exposes` that accepts Hash or ActionController::Parameters (Rails-compatible)
* [FEAT] Allow validations to access instance methods (e.g. `inclusion: { in: :some_method }`)
* [FEAT] Allow message `prefix` to invoke callables/method name symbols the same way e.g. `if` does
* [BREAKING] `default`s for `expects` and `exposes` are only applied to explicitly `nil` values (previous applied if given value was blank, which caused bugs for boolean handling)
* [FEAT] Support `sensitive: true` on subfields (with `on:`)
* [FEAT] Support `preprocess` on subfields (with `on:`)
* [FEAT] Support `default` on subfields (with `on:`)
* [FEAT] Added `#done!` method for early completion with success result
* [FEAT] Extended `#fail!` and `#done!` methods to accept keyword arguments for exposing data before halting execution
* [INTERAL] Renamed `Axn::Enqueueable` to `Axn::Async`
* [BREAKING] Replaced `.enqueue` (only supported sidekiq) with `.call_async` (via a configurable registry of backgrounding libraries)
* [FEAT] attachable now creates a foo_async to call call_async
* `type` validator is not still applied to the blank value when allow_blank is true (`type: Hash` will no longer accept `false` or `""`)
* [FEAT] `expects`/`exposes` now prefers new `optional: true` over allow_blank for simplicity
* [FEAT] `Axn::Result` now supports Ruby 3's pattern matching feature
* [FEAT] Extended attachable functionality: added `mount_axn_method` for creating class methods that return values directly instead of wrapped in `Axn::Result`
* [Internal] Replaced `Axn::Attachable` with `Axn::Mountable` - complete refactor of action mounting system
  * [BREAKING] `#axn` → `#mount_axn` for method mounting
  * [BREAKING] `#axn_method` → `#mount_axn_method` for direct method mounting
  * [NEW] `enqueue_all_via` - Mount batch enqueueing functionality for background job processing
* [FEAT] Enhanced async execution with job scheduling support
  * [NEW] Support for scheduled async jobs via `_async` parameter with `wait_until:` and `wait:` options
  * [NEW] `enqueue` shortcut methods for all mounted actions

## 0.1.0-alpha.2.8.1
* [BUGFIX] Fixed symbol callback and message handlers not working in inherited classes due to private method visibility issues
* [BUGFIX] `default_error` and `default_success` are now properly available for before hooks
* [FEAT] Support scheduling async jobs (via new `_async` key)

## 0.1.0-alpha.2.8
* [FEAT] Custom RuboCop cop `Axn/UncheckedResult` to enforce proper result handling in Actions with configurable nested/non-nested checking
* [FEAT] Added `prefix:` keyword support to `error` method for customizing error message prefixes
  * When no block or message is provided, falls back to `e.message` with the prefix
* [BREAKING] `result.outcome` now returns a string inquirer instead of a symbol
* [BREAKING] **Message ordering change**: Static success/error messages (without conditions) should now be defined **first** in your action class, before any conditional messages. This ensures proper fallback behavior and prevents conditional messages from being shadowed by static ones.
* [CHANGE] `result.exception` will new return the internal Action::Failure, rather than nil, when user calls `fail!`
* [BREAKING] `hoist_errors` has been replaced by `error from:`
* [FEAT] Improved Axn::Factory.build support for newly-added messaging and callback descriptors

## 0.1.0-alpha.2.7.1
* [FEAT] Implemented symbol method handler support for callbacks

## 0.1.0-alpha.2.7
* [BREAKING] Replaced `messages` declaration with separate `success` and `error` calls
* [BREAKING] Removed `rescues` method (use `error_from` for custom error messages; all exceptions now report to `on_exception` handlers)
* [BREAKING] Replaced `error_from` with an optional `if:` argument on `error`
  * [FEAT] Implemented conditional success message filtering as well
* [FEAT] Added block support for `error` and `success`
* [FEAT] `if:` now supports symbol predicates referencing instance methods (arity 0, 1, or keyword `exception:`). If the method accepts `exception:` it is passed as a keyword; else if it accepts one positional arg, it is passed positionally; otherwise it is called with no args. If the method is missing, the symbol falls back to constant lookup (e.g., `:ArgumentError`).
* [FEAT] `success`/`error` now accept symbol method names (e.g., `success :local_method`). Handlers can receive the exception via keyword (`exception:`) or single positional argument; otherwise they are called with no args.
* [BREAKING] Updated callback methods (`on_success`, `on_error`, `on_failure`, `on_exception`) to use consistent `if:` interface (matching messages)
* [FEAT] Added `unless:` support to both `success`/`error` messages and callbacks (`on_success`, `on_error`, `on_failure`, `on_exception`)

## 0.1.0-alpha.2.6.1
* [FEAT] Added `elapsed_time` and `outcome` methods to `Action::Result`
  * `elapsed_time` returns execution time in milliseconds (Float)
  * `outcome` returns execution outcome as symbol (`:success`, `:failure`, or `:exception`)
* [BREAKING] `emit_metrics` hook now receives the full `Action::Result` object instead of just the outcome
  * Provides access to both outcome and elapsed time for richer metrics
  * Example: `proc { |resource, result| TS::Metrics.histogram("action.duration", result.elapsed_time) }`
* [BREAKING] Replaced `Action.config.default_log_level` and `default_autolog_level` with simpler `log_level`
* [BREAKING] `autolog_level` method overrides with e.g. `auto_log :warn` or `auto_log false`
* [BREAKING] Direct access to exposed fields in callables no longer works -- `foo` becomes `result.foo`
* [BREAKING] Removed `success?` check on Action::Result (use `ok?` instead)
* [FEAT] Added callback and strategy support to Axn::Factory.build

## 0.1.0-alpha.2.6
* Inline interactor code (no more dependency on unpublished forked branch to support inheritance)
  * Refactor internals to clean implementation now that we have direct control
  * [BREAKING] Replaced `Action.config.top_level_around_hook` with `.wrap_with_trace` and `.emit_metrics`
  * [BREAKING] the order of hooks with inheritance has changed to more intuitively follow the natural pattern of setup (general → specific) and teardown (specific → general):
    * **Before hooks**: Parent → Child (general setup first, then specific)
    * **After hooks**: Child → Parent (specific cleanup first, then general)
    * **Around hooks**: Parent wraps child (parent outside, child inside)
* Removed non-functional #rollback traces (use on_exception hook instead)
* Clean requires structure

## 0.1.0-alpha.2.5.3.1
* Remove explicit 'require rspec' from `axn/testing/spec_helpers` (must already be loaded)

## 0.1.0-alpha.2.5.3
* More aggressive logging of swallowed exceptions when not in production mode
* Make automatic pre/post logging more digestible

## 0.1.0-alpha.2.5.2
* [BREAKING] Removing `EnqueueAllInBackground` + `EnqueueAllWorker` - better + simply solved at application level
* [TEST] Expose spec helpers to consumers (add `require "axn/testing/spec_helpers"` to your `spec_helper.rb`)
* [FEAT] Added ability to use custom Strategies (via e.g. `use :transaction`)

## 0.1.0-alpha.2.5.1.2
* [BUGFIX] Subfield expectations: now support hashes with string keys (using with_indifferent_access)
* [BUGFIX] Subfield expectations: Model reader fields now cache initial value (otherwise get fresh instance each call, cannot make in-memory changes)

## 0.1.0-alpha.2.5.1.1
* [BUGFIX] TypeValidator must handle anonymous classes when determining if given argument is an RSpec mock

## 0.1.0-alpha.2.5.1
* Added new `model` validator for expectations
* [FEAT] Extended `expects` with the `on:` key to allow declaring nested data shapes/validations

## 0.1.0-alpha.2.5
* Support blank exposures for `Action::Result.ok`
* Modify Action::Failure's initialize signature (to better match StandardError)
* Reduce reserved fields to allow some `expects` (e.g. `message`) that would shadow internals if used as `exposes`
* Default logging changes:
  * Add `default_log_level` and `default_autolog_level` class methods (so inheritable) via `Action.config`
  * Remove `global_debug_logging?` from Configuration + unused `SA_DEBUG_TARGETS` approach to configuring logging
* Improved testing ergonomics: the `type` expectation will now return `true` for _any_ `RSpec::Mocks::` subclass
* Enqueueable improvements:
  * Extracted out of Core
  * Renamed to `Enqueueable::ViaSidekiq` (make it easier to support different background runners in the future)
  * Added ability to call `.enqueue_all_in_background` to run an Action's class-level `.enqueue_all` method (if defined) on a background worker
    (important if triggered via a clock process that is NOT intended to execute actual jobs)
* Restructure internals (call/call! + run/run! + Action::Failure) to simplify upstream implementation since we always wrap any raised exceptions

## 0.1.0-alpha.2.4.1
* [FEAT] Adds full suite of per-Axn callbacks: `on_exception`, `on_failure`, `on_error`, `on_success`

## 0.1.0-alpha.2.4
* [FEAT] Adds per-Axn `on_exception` handlers

## 0.1.0-alpha.2.3
* `expects` / `exposes`: Add `type: :uuid` special case validation
* [BUGFIX] Allow `hoist_errors` to pass the result through on success (allow access to subactions' exposures)
* [`Axn::Factory`] Support error_from + rescues
* `Action::Result.error` spec helper -- creation should NOT trigger global exception handler
* [CHANGE] `expects` / `exposes`: The `default` key, if a callable, should be evaluated in the _instance_'s context

## 0.1.0-alpha.2.2
* Expands `Action::Result.ok` and `Action::Result.error` to better support mocking in specs

## 0.1.0-alpha.2.1
* Expects/Exposes: Add `allow_nil` option
* Expects/Exposes: Replace `boolean: true` with `type: :boolean`
* Truncate default debug line at 100 chars
* Support complex Axn::Factory configurations
* Auto-generate self.class.name for attachables

## 0.1.0-alpha.2
* Renamed `.rescues` to `.error_from`
* Implemented new `.rescues` (like `.error_from`, but avoids triggering on_exception handler)
* Prevented `expect`ing and `expose`ing fields that conflict with internal method names
* [Action::Result] Removed `failure?` from public interface (prefer negating `ok?`)
* Reorganized internals into Core vs (newly added) Attachable
* Add some meta-functionality: Axn::Factory + Attachable (subactions + steps support)

## 0.1.0-alpha.1.1
* Reverted `gets` / `sets` back to `expects` / `exposes`

## 0.1.0-alpha.1
* Initial implementation
