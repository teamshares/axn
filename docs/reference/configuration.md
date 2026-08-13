# Configuration

Somewhere at boot (e.g. `config/initializers/actions.rb` in Rails), you can call `Axn.configure` to adjust a few global settings.

```ruby
Axn.configure do |c|
  c.log_level = :info
  c.logger = Rails.logger
  
  c.on_exception = proc do |e, action:, context:|
    Honeybadger.notify(
      "[#{action.class.name}] #{e.class.name}: #{e.message}",
      context: context
    )
  end
end
```

## Per-Class Overrides

Most settings are global — one value for every action. A few are also **per-axn overridable**: an individual action can override the library-level value for its own runs (and its subclasses'), falling back to `Axn.config` when it doesn't. Currently `sidekiq_job_tag_sources` is the overridable setting.

For each overridable setting, every action gets three class-level accessors:

```ruby
class ChargeCompany
  include Axn

  sidekiq_job_tag_sources %i[dimension]   # set this class's override

  # sidekiq_job_tag_sources               # → resolved value (override → Axn.config fallback)
  # sidekiq_job_tag_sources?              # → same resolved value, as a boolean
  # sidekiq_job_tag_sources_override      # → this class's override, or unset (no fallback)
end
```

- The bare `name` reads the **resolved** value: the nearest override up the class ancestry, or `Axn.config`'s value if none is set. `name?` is the same read, coerced to a boolean.
- `name_override` returns only an override (the class's own or an inherited one); it does **not** fall back to `Axn.config`, so a caller can tell "no override" from "resolves to the global default".
- Overrides are inherited by subclasses and never leak to siblings. Setting one leaves `Axn.config` untouched.

### Setting overrides with `configure`

The flat setter has an equivalent block form. `configure` (no argument) targets Axn's own settings — the same override store the flat setters write to:

```ruby
class ChargeCompany
  include Axn

  configure { |c| c.sidekiq_job_tag_sources = %i[dimension] }
end
```

The block form is what you reach for when configuring **namespaced** settings contributed by an extension (below). For the `:core` namespace the schema is always known, so a typo'd setter (`c.sidekiq_job_tag_sorces = …`) fails at class definition just as the flat setter would.

If a base class you inherit from already defines its own class-level `configure`, Axn leaves it untouched and exposes its own writer as `axn_configure` instead — always available regardless of the base.

### Namespaced config for extensions

Axn extensions (for example `axn-mcp` or `axn-ruby_llm`) can register their own overridable settings under a namespace, so one action can be configured for several adapters at once — and their settings never collide, even when two adapters happen to use the same setting name:

```ruby
class QuoteLookup
  include Axn

  configure(:mcp)      { |c| c.text_content = :structured }
  configure(:ruby_llm) { |c| c.temperature = 0.2 }
end
```

Each namespace's config is stored independently, so composing adapters never clobber one another.

When an extension is loaded and its overrides are in play, its setters are validated eagerly. When they aren't, `configure` is **tolerant**: you can set config for a namespace whose extension isn't loaded in the current process — useful for a reusable tool that declares its behavior for several transports in one place. The value sits inert until that extension reads it, and is validated against the extension's schema then, so a bad value surfaces when the extension first resolves it rather than at the `configure` call.

Global (non-per-class) config stays on each module — `Axn.configure` for Axn's own settings, `Axn::MCP.configure` for MCP's, and so on. There is no single combined entry point, though nothing stops you from keeping the calls together in one initializer.

### Tool directories are declared per adapter

Each tool adapter names the directories it consumes, on its own global config, via `tool_roots`. A directory listed by more than one adapter is a shared population; an adapter with empty `tool_roots` is purely declaration-driven.

```ruby
Axn::MCP.configure            { |c| c.tool_roots = %w[agent_tools] }
Axn::RubyLLM.configure        { |c| c.tool_roots = %w[agent_tools] }
Axn::OpenAPI.configure        { |c| c.tool_roots = %w[agent_tools http_tools] }
```

A tool's final adapter membership is the union of its directory grant (adapters whose `tool_roots` contain its file) and its `tool` declaration, minus any `except:` opt-out. An explicit `tool :openapi` *adds* openapi on top of the directory grant; `tool except: :ruby_llm` subtracts; `tool false` opts out entirely. `tool_roots` rejects broad entries (`actions`, `app`, `.`, `..`).

An adapter registers itself, passing its own module as the config source the registry reads roots from:

```ruby
Axn::Tools.register_adapter(:openapi, self) # inside Axn::OpenAPI
```

## `on_exception`

By default any swallowed errors are noted in the logs, but it's _highly recommended_ to wire up an `on_exception` handler so those get reported to your error tracking service.

For example, if you're using Honeybadger this could look something like:

```ruby
Axn.configure do |c|
  c.on_exception = proc do |e, action:, context:|
    Honeybadger.notify(
      "[#{action.class.name}] #{e.class.name}: #{e.message}",
      context: context
    )
  end
end
```

**Note:** The `action:` and `context:` keyword arguments are *optional*—your proc can accept any combination of `e`, `action:`, and `context:`. Only the keyword arguments you explicitly declare will be passed to your handler. All of the following are valid:

```ruby
# Only exception object
c.on_exception = proc { |e| ... }

# Exception and action
c.on_exception = proc { |e, action:| ... }

# Exception and context
c.on_exception = proc { |e, context:| ... }

# Exception, action, and context
c.on_exception = proc { |e, action:, context:| ... }
```

### Context Structure

The `context` hash is automatically formatted and contains:

```ruby
{
  inputs: { ... },              # Action inputs (declared expects fields only), formatted recursively
  outputs: { ... },             # Action outputs (declared exposes fields only), formatted recursively
  # ... any extra keys from set_execution_context or additional_execution_context hook
  # e.g. client_strategy__last_request: { url: ..., method: ..., status: ... }
  ambient_context: { ... },     # Declared `ambient_context` subfields, sensitive-filtered (present when the action declares any)
  tags: { ... },                # Resolved `tag` facets (only when the action declares any)
  dimensions: { ... },          # Resolved `dimension` facets (only when the action declares any)
  async: { ... }                # Async retry info (only present in async context)
}
```

Additional context (like `client_strategy__last_request` from the `:client` strategy) appears at the top level alongside `inputs` and `outputs`, not nested inside them. Formatting is applied recursively to nested hashes and arrays.

**What gets formatted automatically:**
- **ActiveRecord objects** → GlobalID strings (e.g., `"gid://app/User/123"`)
- **ActionController::Parameters** → Plain hashes
- **Axn::FormObject instances** → Hash representation

**Example with all context fields:**

```ruby
Axn.configure do |c|
  c.on_exception = proc do |e, action:, context:|
    # context[:inputs] - Your action's inputs (formatted)
    # context[:outputs] - Your action's outputs (formatted)
    # context[:client_strategy__last_request] - Example extra key from :client strategy
    # context[:ambient_context] - Declared ambient_context subfields, sensitive-filtered (if any declared)
    # context[:async] - Retry info (if in async context)
    
    Honeybadger.notify(e, context: context)
  end
end
```

### Additional Notes

- Sensitive fields (marked with `expects :foo, sensitive: true`) are automatically filtered to `"[FILTERED]"`
- If your handler raises an exception, the failure will be swallowed and logged (it is deliberately not re-reported — see [`on_ignored_exception`](#on-ignored-exception))
- This handler is global across _all_ actions. You can also specify per-action handlers via [the class-level declaration](/reference/class#on-exception)
- Complex objects are automatically formatted for error tracking systems

### Adding Additional Context to Exception Logging

When processing records in a loop or performing batch operations, you may want to include additional context (like which record is being processed) in exception logs. You can do this in two ways:

**Option 1: Explicit setter** - Call `set_execution_context` during execution:

```ruby
class ProcessPendingRecords
  include Axn

  def call
    pending_records.each do |record|
      set_execution_context(current_record_id: record.id, batch_index: @index) # [!code focus]
      # ... process record ...
    end
  end
end
```

**Option 2: Hook method** - Define a private `additional_execution_context` method that returns a hash:

```ruby
class ProcessPendingRecords
  include Axn

  def call
    pending_records.each do |record|
      @current_record = record
      # ... process record ...
    end
  end

  private

  def additional_execution_context # [!code focus:8]
    return {} unless @current_record

    {
      current_record_id: @current_record.id,
      record_type: @current_record.class.name
    }
  end
end
```

Both approaches can be used together - they will be merged at the top level of the context hash. The additional context is **only** included in `execution_context` (used for exception reporting and handlers), not in normal pre/post execution logs, and is evaluated lazily (the hook method is only called when needed).

**Reserved keys:** The keys `:inputs` and `:outputs` are reserved. If you try to set them via `set_execution_context` or the hook, they will be ignored—the actual inputs and outputs always come from the action's contract.

Action-specific `on_exception` handlers can access the full context by calling `execution_context`:

```ruby
class ProcessPendingRecords
  include Axn

  on_exception do |exception:| # [!code focus:3]
    ctx = execution_context
    log "Failed processing. Inputs: #{ctx[:inputs]}, Extra: #{ctx[:current_record_id]}"
    # ... handle exception with context ...
  end
end
```

## `on_ignored_exception`

Some exceptions never reach the result at all. An `on_success` callback that raises, an observability facet resolver, a custom `validate:` block, a tracer that fails to export — all of these run in a side channel that is guarded so it cannot break the action, and their failures are **ignored**: logged, then discarded.

This is the difference between the two hooks, and it is worth being precise about:

| | `on_exception` | `on_ignored_exception` |
| --- | --- | --- |
| Where it went | Became the result | Discarded |
| `result.ok?` | `false` | usually `true` |
| Who else can see it | The caller, via `result.exception` | Nobody |

That last row is the reason this hook exists. When an `on_success` callback raises, the caller gets a successful result and a side effect silently did not happen — the welcome email wasn't sent, the audit row wasn't written. Nothing in the return value records it, so this report is the only evidence it occurred.

**By default, ignored exceptions are reported through whatever you configured for [`on_exception`](#on-exception).** If your app already reports exceptions, you get these too, with no wiring:

```ruby
Axn.configure do |c|
  c.on_exception = ->(e, action:, context:) { Honeybadger.notify(e, context:) }
  # ignored exceptions now reach the same handler
end
```

Assign a callable to send them somewhere else instead, or `false` to drop them (log-only, the pre-existing behavior):

```ruby
Axn.configure do |c|
  c.on_ignored_exception = ->(e, action:, context:) { Honeybadger.notify(e, context:, tags: "axn-ignored") }
  # ...or:
  c.on_ignored_exception = false
end
```

The handler receives the same `(exception, action:, context:)` shape as `on_exception` and is arity-filtered the same way, so a handler declared `->(e)` works fine. The exception is passed **unwrapped**, so your error tracker groups these by the class and backtrace of the code that actually raised.

### Telling the two apart

An ignored report carries a `context[:axn_ignored]` key that an `on_exception` report never has:

```ruby
{
  axn_ignored: {
    while: "executing on_success callback",  # what was being attempted
    outcome: "success",                      # the surrounding action's outcome
  },
}
```

`outcome` is the severity signal. `"success"` means the caller got their result and a side effect vanished — the alarming case. `"failure"` or `"exception"` means this is collateral to a failure `on_exception` is already reporting separately, and is usually lower priority.

`outcome` is **omitted** when the action had not settled yet (many guards fire mid-run, before there is an outcome to report) and when there is no action to ask. Branch on its presence rather than assuming it:

```ruby
Axn.configure do |c|
  c.on_ignored_exception = lambda do |e, context:, **|
    ignored = context[:axn_ignored]
    severity = ignored[:outcome] == "success" ? :error : :warning
    Honeybadger.notify(e, context:, severity:)
  end
end
```

**Important notes:**
- A handler that raises cannot break the action — the failure is logged and swallowed, like every other side channel
- A failing `on_exception` handler is **not** re-reported through this hook. Handing a failed report back to the handler that just failed is useless when it is persistently broken, and doubles the load on a provider that is merely degraded. The warning log still names it
- A handler that runs an Axn action of its own will not re-enter itself if that action trips a guard
- Under [`best_effort_raises_in_dev`](#best-effort-raises-in-dev) the exception is raised rather than ignored, so nothing is reported — there is nothing being papered over

## `best_effort_raises_in_dev`

By default, errors that occur in framework code (e.g., in logging hooks, exception handlers, validators, or other user-provided callbacks) are swallowed and logged to prevent them from interfering with the main action execution — and reported via [`on_ignored_exception`](#on-ignored-exception). In development, you can opt-in to have these errors raised instead of logged:

```ruby
Axn.configure do |c|
  c.best_effort_raises_in_dev = true
end
```

**Important notes:**
- This setting only applies in the development environment—errors are always swallowed in test and production
- Test and production environments behave identically (errors swallowed), ensuring tests verify actual production behavior
- When enabled in development, errors in framework code (like logging hooks, exception handlers, validators) will be raised instead of logged, putting issues front and center during manual testing
- What you get is the exception your code raised, re-raised as itself. The one exception is an exception class that defines its own `#exception` method: Ruby's `raise` always calls that method on the object it is handed, so re-raising such an object would run its code and could surface something else entirely. Axn refuses to run it, and raises `Axn::ReraiseFailed` instead — it names what was being attempted and the original class, repeats the original's message, and carries the original as its `cause`. It is a `StandardError`, so an enclosing `rescue => e` catches it in the same place. This is rare and only affects which class you see; the raise itself is never downgraded to a log line

## OpenTelemetry Tracing

Axn automatically creates spans for all action executions when a tracer is available — by default, the OpenTelemetry tracer when OpenTelemetry is loaded. The framework creates a span named `"axn.call"` with the following attributes:

- `axn.resource`: The action class name (e.g., `"UserManagement::CreateUser"`)
- `axn.outcome`: The execution outcome (`"success"`, `"failure"`, or `"exception"`)

When an action fails or raises an exception, the span is marked as an error with the exception details recorded.

### Supplying or disabling the tracer

`Axn.config.tracer` decides which tracer receives axn's spans, and has three states.

Leave it unset — the default — and axn auto-detects: it uses the OpenTelemetry tracer when OpenTelemetry is loaded, and creates no spans otherwise. Detection re-runs on every action, so OpenTelemetry configured later in boot is still picked up.

Assign a tracer to use it instead, whether or not OpenTelemetry is loaded. Anything responding to `in_span(name, attributes:)` and yielding a span works — a differently-named instrumentation scope, a custom provider, or a test fake. `in_span` must invoke the block **synchronously, on the calling thread and fiber**: the action's entire pipeline runs inside it, and axn's per-execution state (the nesting stack, exception classification) is scoped the same way. A tracer that hands the block to a worker thread or wraps it in a fiber gets that block refused, and axn runs the action untraced on the caller's own thread and fiber instead — the call still succeeds, with correct nesting and logging, but loses its span.

```ruby
Axn.configure do |c|
  c.tracer = OpenTelemetry.tracer_provider.tracer("my-app.axn", "1.0.0")
end
```

::: tip A misbehaving tracer cannot cost you the action
Axn runs the action exactly once whether `in_span` raises before yielding, returns without ever yielding, yields more than once, or raises after the action has already settled — and the same holds if resolving the tracer itself raises. Tracing observes the call; it never decides whether it happens.

In production and test, the tracing failure is logged and swallowed, so a span that fails to export does not turn a successful action into an exception from `.call`. Under [`best_effort_raises_in_dev`](#best-effort-raises-in-dev) in development it is deliberately re-raised instead, so you see it — the action has still run exactly once by then.
:::

Assign `nil` to turn axn's spans off without unloading OpenTelemetry — the rest of your instrumentation keeps working:

```ruby
Axn.configure { |c| c.tracer = nil }
```

`Axn.config.reset!(:tracer)` returns to auto-detection, which is what a spec that installs a fake tracer wants in its teardown. Note that assigning `nil` is a value, not a reset.

Called with no arguments, `Axn.config.reset!` resets every setting declared through the `setting` DSL — `tracer` among them — back to its declared default. It does not touch the hand-written accessors (`logger`, `env`, `on_exception`, `rails`, and the async defaults), which aren't declared through `setting` and so are outside its scope.

A tracer that is not OpenTelemetry's receives the span, its `axn.resource` / `axn.outcome` attributes, every `axn.tag.*` and `axn.dimension.*` facet, and `record_exception` for a failure — but not an error `Status`, which can only be constructed through OpenTelemetry's own class.

An object that is neither `nil` nor responds to `#in_span` is rejected at assignment, naming the `#in_span` contract in the raised `ArgumentError`. The one exception is a value that cannot be asked: a `BasicObject`-based proxy has no `respond_to?`, and no reflection method reaches it, so axn accepts it rather than rejecting a legitimate wrapper over a real tracer. If such a proxy turns out to lack `in_span`, that surfaces on the first traced call — logged, with the action running untraced — instead of at assignment.

### Basic Setup

If you just want OpenTelemetry spans (without sending to an APM provider), install the API gem:

```ruby
# Gemfile
gem "opentelemetry-api"
```

Then configure a tracer provider:

```ruby
# config/initializers/opentelemetry.rb
require "opentelemetry-sdk"

OpenTelemetry::SDK.configure do |c|
  c.service_name = "my-app"
end
```

### Datadog Integration

To send OpenTelemetry spans to Datadog APM, you need both the OpenTelemetry SDK and the Datadog bridge. The bridge intercepts `OpenTelemetry::SDK.configure` and routes spans to Datadog's tracer.

**1. Add the required gems:**

```ruby
# Gemfile
gem "datadog"           # Datadog APM
gem "opentelemetry-api" # OpenTelemetry API
gem "opentelemetry-sdk" # OpenTelemetry SDK (required for Datadog bridge)
```

**2. Configure Datadog first, then OpenTelemetry:**

The order matters — Datadog must be configured before loading the OpenTelemetry bridge, and `OpenTelemetry::SDK.configure` must be called after the bridge is loaded.

```ruby
# config/initializers/datadog.rb (use a filename that loads early, e.g., 00_datadog.rb)

# 1. Configure Datadog first
Datadog.configure do |c|
  c.env = Rails.env
  c.service = "my-app"
  c.tracing.enabled = Rails.env.production? || Rails.env.staging?
  c.tracing.instrument :rails
end

# 2. Load the OpenTelemetry SDK and Datadog bridge
require "opentelemetry-api"
require "opentelemetry-sdk"
require "datadog/opentelemetry"

# 3. Configure OpenTelemetry SDK (Datadog intercepts this)
OpenTelemetry::SDK.configure do |c|
  c.service_name = "my-app"
end
```

::: warning Important
The `opentelemetry-sdk` gem is required — not just `opentelemetry-api`. The Datadog bridge only activates when `OpenTelemetry::SDK` is defined and `OpenTelemetry::SDK.configure` is called.
:::

With this setup, all Axn actions will automatically create spans that appear in Datadog APM as children of your Rails request traces.

### Tagging spans with domain context (`tag` / `dimension`)

Any action can declare domain facets that are resolved once per execution and attached to its `axn.call` span (and notification payload). Use `tag` for high-cardinality facets (ids, references) and `dimension` for bounded ones (a small, known set of values).

```ruby
class ChargeCompany
  include Axn
  expects :company

  tag :company_id, -> { company.id }         # → span attribute axn.tag.company_id
  dimension :plan_tier, -> { company.plan }  # → span attribute axn.dimension.plan_tier (+ emit_metrics)
  tag :charged_cents, -> { result.charged_cents }, from: :result  # reads a settled output
end
```

Each `tag`/`dimension` declares one facet: a name plus a resolver — a block/lambda (evaluated in the action's context, so `expects` readers are in scope), a symbol naming an action method, or a literal. Note that `exposes` fields are **not** in-action readers (read them via `result.<name>`), so a `from: :result` facet that needs an exposed value reads it off `result` — see the `charged_cents` example above. A resolver returning `nil` omits that facet for the call; a resolver that raises is swallowed and that one facet skipped, leaving the others intact.

**Resolution phase (`from:`).** By default (`from: :inputs`) a facet resolves early — before `call` runs. Pass `from: :result` for a facet whose resolver reads a **settled output** (an `exposes` value, the result). The distinction matters for one sink only — in-flight logs (below); every other sink sees both. A `from: :inputs` facet that mistakenly reads an unset output just resolves to `nil` and is omitted, so mark such facets `from: :result`.

**Cardinality mapping.** An Axn `tag` is high-cardinality and becomes a span attribute, a log field, and an exception-report facet (`context[:tags]`) — safe for per-call values like ids. An Axn `dimension` is bounded and additionally flows to **metrics-style** indexing sinks (`emit_metrics` and the exception report's `context[:dimensions]`, meant for indexed tags like Sentry/Honeybadger) where unbounded values are costly. This is the reverse of "tag" in Datadog/Sentry (where a tag is the bounded thing); pick the Axn macro by cardinality, not by the downstream tool's word. **Sidekiq job tags are the exception:** they carry no metrics-billing cost, so by default *both* `tag` and `dimension` surface there (see below).

**Log annotation.** Declared facets also annotate [`auto_log`](#automatic-logging) output. When your configured logger is a [`SemanticLogger`](https://logger.rocketjob.io/) (e.g. via `rails_semantic_logger`), facets are forwarded to its tagged context as named tags — `axn.tag.<name>` / `axn.dimension.<name>` — so they become structured log fields, and dimensions are legible as Datadog log facets: **input-phase facets tag every log line emitted during `call`** (plus the completion line), while `from: :result` facets tag only the completion line (they aren't resolved until the result settles). With any other logger, facets are appended to the completion line as a readable suffix, e.g. `… [tags: {company_id: 7}] [dimensions: {plan_tier: "pro"}]`. Axn takes no dependency on `semantic_logger`; it forwards only when the configured logger is already one.

**Exception reports.** Both facet maps also ride along in the `on_exception` `context`, so a handler routes them onto its reporter:

```ruby
c.on_exception = proc do |e, context:| # [!code focus:5]
  Honeybadger.notify(e,
    context: context, # tags land here as freeform extra
    tags: context[:dimensions]&.values&.join(", ")) # dimensions → indexed tags
end
```

They appear only when the action declares facets; a handler that just forwards `context` wholesale picks up `context[:tags]`/`context[:dimensions]` automatically.

### Surfacing facets as Sidekiq job tags

When an action runs as a Sidekiq job, its declared facets are also attached to the enqueued job's Sidekiq `tags`, so you can find and filter jobs in the Sidekiq web UI (e.g. every job for a given company). Each facet becomes a `name:value` tag; an array-valued facet fans out to one tag per element.

```ruby
Axn.config.sidekiq_job_tag_sources # => default %i[tag dimension]
```

This is per-axn overridable — an individual action can narrow (or disable) its own job tags without changing the global:

```ruby
class ChargeCompany
  include Axn
  async :sidekiq

  sidekiq_job_tag_sources %i[dimension]   # this action's jobs carry bounded tags only
end
```

The Sidekiq adapter reads the resolved `sidekiq_job_tag_sources` at enqueue, so the per-class value wins with the global as fallback. See [Per-Class Overrides](#per-class-overrides).

Because Sidekiq tags are ephemeral job-payload strings (gone when the job finishes) with no per-value metrics cost, both `tag` and `dimension` surface here by default — unlike the metrics sink. Set `%i[dimension]` for bounded-only, or `[]` to disable the sink entirely.

**Enqueue-time limitation (important).** Unlike the span/`emit_metrics` sinks — which resolve at completion, when results are available — Sidekiq `tags` are set at *enqueue*, before the job runs, in a different process. So only **input-phase** facets (`from: :inputs`) become job tags, resolved from the **raw enqueued inputs**; **result-phase** facets (`from: :result` — reading `exposes`/the result) cannot and are silently omitted. `preprocess:`/`default:` are deliberately **not** applied at enqueue (those hooks run once, at perform — applying them here would double-run side effects and could compute a value that drifts from the run), so a facet derived from a defaulted/preprocessed field reflects the raw input, or is omitted when that field was absent. Resolution is best-effort: a failure never breaks the enqueue. This sink is **Sidekiq-specific** — ActiveJob has no native tag concept, and its per-execution facets are already carried on the `axn.call` APM span.

## `emit_metrics`

If you're using a metrics provider, you can emit custom metrics after each action completes using the `emit_metrics` hook. This is a post-execution hook that receives the action result—do NOT call any blocks.

The hook only receives the keyword arguments it explicitly expects (e.g., if you only define `resource:`, you won't receive `result:`).

For example, to wire up Datadog metrics:

```ruby
  Axn.configure do |c|
    c.emit_metrics = proc do |resource:, result:|
      TS::Metrics.increment("axn.call", tags: { resource:, outcome: result.outcome.to_s })
      TS::Metrics.distribution("axn.call.duration", result.elapsed_time, tags: { resource:, outcome: result.outcome.to_s })
    end
  end
```

Prefer a **single metric name tagged by `resource`** (as above) over a separate metric name per action (e.g. `"action.#{resource.underscore}"`). One tagged metric lets a single dashboard render the whole fleet and drill into any one action with a `resource:` filter — see [Dashboards from Axn Metrics](/recipes/datadog-dashboards).

You can also define `emit_metrics` to only receive the arguments you need:

```ruby
  # Only receive resource (if you don't need the result)
  c.emit_metrics = proc do |resource:|
    TS::Metrics.increment("axn.call", tags: { resource: })
  end

  # Only receive result (if you don't need the resource)
  c.emit_metrics = proc do |result:|
    TS::Metrics.increment("axn.call", tags: { outcome: result.outcome.to_s })
  end

  # Accept any keyword arguments (receives both)
  c.emit_metrics = proc do |**kwargs|
    # kwargs will contain both :resource and :result
  end
```

`emit_metrics` also receives `dimensions:` — the resolved `dimension` facets for the action (an empty hash if none). Merge them into your metric tags to get per-action bounded dimensions for free:

```ruby
c.emit_metrics = proc do |resource:, result:, dimensions:|
  TS::Metrics.increment("axn.call", tags: { resource:, outcome: result.outcome.to_s, **dimensions })
end
```

`dimensions:` is opt-in: existing blocks that only declare `resource:`/`result:` are unaffected. Keep dimension values bounded (see the cardinality note above) — they become metric tags.

**Important:** When using `result:` in your `emit_metrics` hook, be careful about cardinality. Avoid creating metrics with unbounded tag values from the result (e.g., user IDs, email addresses, or other high-cardinality data). Instead, use bounded values like `result.outcome.to_s` or aggregate data. High-cardinality metrics can cause performance issues and increased costs with metrics providers.

A couple notes:

  * `TS::Metrics` is a custom implementation to set a Datadog count metric, but the relevant part to note is that the result object provides access to the outcome (`result.outcome.success?`, `result.outcome.failure?`, `result.outcome.exception?`) and elapsed time of the action.
  * The `emit_metrics` hook is called after execution with the result - do not call any blocks

## `logger`

Defaults to `Rails.logger`, if present, otherwise falls back to `Logger.new($stdout)`.  But can be set to a custom logger as necessary.

### Background Job Logging

When using background jobs, you may want different loggers for web requests vs. background job execution. Here's a recommended pattern:

```ruby
Axn.configure do |c|
  # Use Sidekiq's logger when running in Sidekiq workers, otherwise use Rails logger
  c.logger = (defined?(Sidekiq) && Sidekiq.server?) ? Sidekiq.logger : Rails.logger # [!code focus]
end
```

This ensures that:
- Web requests log to `Rails.logger` (typically `log/production.log`)
- Background jobs log to `Sidekiq.logger` (typically STDOUT or a separate log file)


## `additional_includes`

This is much less critical than the preceding options, but on the off chance you want to add additional customization to _all_ your actions you can set additional modules to be included alongside `include Axn`.

For example:

```ruby
  Axn.configure do |c|
    c.additional_includes = [SomeFancyCustomModule]
  end
```

For a practical example of this in practice, see [our 'memoization' recipe](/recipes/memoization).

## `log_level`

Sets the log level used when you call `log "Some message"` in your Action.  Note this is read via a `log_level` class method, so you can easily use inheritance to support different log levels for different sets of actions.

## `env`

Automatically detects the environment from `RACK_ENV` or `RAILS_ENV`, defaulting to `"development"`. Returns an `ActiveSupport::StringInquirer`, allowing you to use predicate methods like `env.production?` or `env.development?`.

```ruby
Axn.config.env.production?   # => true/false
Axn.config.env.development?  # => true/false
Axn.config.env.test?         # => true/false
```

### Environment-Dependent Behavior

Several Axn behaviors change based on the detected environment:

| Behavior | Production | Test | Development |
| -------- | ---------- | ---- | ----------- |
| Log separators in async calls | Hidden | Visible (`------`) | Visible (`------`) |
| `best_effort_raises_in_dev` | Always swallowed | Always swallowed | Configurable |
| Error message verbosity | Minimal | More detailed | More detailed |

### Overriding the Environment

You can explicitly set the environment if auto-detection doesn't work for your setup:

```ruby
Axn.configure do |c|
  c.env = "staging"
end

Axn.config.env.staging?  # => true
```

A Symbol works too, and so does handing over Rails' own environment object:

```ruby
Axn.configure do |c|
  c.env = :staging   # coerced to "staging"
  c.env = Rails.env  # a String subclass, stored as-is
  c.env = nil        # clears the override, back to auto-detection
end
```

Anything that is not a String, a Symbol, or `nil` is rejected on the spot with an `ArgumentError`, rather than being accepted and then failing on every later read of `Axn.config.env`:

```ruby
Axn.configure { |c| c.env = 123 }
# => ArgumentError: env must be a String or Symbol naming the environment,
#    or nil to auto-detect it from RACK_ENV/RAILS_ENV (got a value of class Integer)
```

## Async Exception Reporting

Controls when `on_exception` is triggered for unexpected exceptions in async jobs. This helps manage the volume of error reports during retries.

```ruby
Axn.configure do |c|
  c.async_exception_reporting = :first_and_exhausted  # default
end
```

### Available Modes

| Mode | When `on_exception` fires |
|------|---------------------------|
| `:every_attempt` | Every time the job runs and fails (includes all retries) |
| `:first_and_exhausted` | First attempt + when job exhausts all retries (default) |
| `:only_exhausted` | Only when job exhausts all retries |

### Retry Context

When `on_exception` is triggered in an async context, the `context` hash includes retry information under the `:async` key:

```ruby
Axn.configure do |c|
  c.on_exception = proc do |e, action:, context:|
    # context[:async] is automatically included when in async context
    # Available fields:
    # context[:async][:adapter]           # :sidekiq or :active_job
    # context[:async][:attempt]           # Current attempt (1-indexed)
    # context[:async][:max_retries]       # Max retry attempts
    # context[:async][:job_id]            # Job ID (if available)
    # context[:async][:first_attempt]     # true if first attempt
    # context[:async][:retries_exhausted] # true if all retries exhausted
    
    if context[:async]
      # Add custom retry info to context
      enhanced_context = context.merge(
        retry_info: "Attempt #{context[:async][:attempt]} of #{context[:async][:max_retries]}"
      )
      Honeybadger.notify(e, context: enhanced_context)
    else
      # Foreground execution - context still includes inputs and ambient_context
      Honeybadger.notify(e, context: context)
    end
  end
end
```

## `async_max_retries`

Optional override for max retries across all async jobs. When set, this value is used for retry context tracking instead of the adapter's default.

```ruby
Axn.configure do |c|
  # Override the default max retries for all async jobs
  c.async_max_retries = 10
end
```

When not set (default), each adapter uses its own default:
- **Sidekiq**: 25 (Sidekiq's default)
- **ActiveJob**: 5 (matches `retry_on` default), or auto-detected from Sidekiq if used as backend

## `set_default_async`

Configures the default async adapter and settings for all actions that don't explicitly specify their own async configuration.

```ruby
Axn.configure do |c|
  # Set default async adapter with configuration
  c.set_default_async(:sidekiq, queue: "default", retry: 3) do
    sidekiq_options priority: 5
  end

  # Set default async adapter with just configuration
  c.set_default_async(:active_job) do
    queue_as "default"
    self.priority = 5
  end

  # Disable async by default
  c.set_default_async(false)
end
```

`Axn.config.default_async?` answers whether a default adapter is configured — the supported way for a gem to ask "is async on?".

### Async Configuration

Axn supports asynchronous execution through background job processing libraries. You can configure async behavior globally or per-action.

**Available adapters:**
- `:sidekiq` - Sidekiq background job processing
- `:active_job` - Rails ActiveJob framework
- `false` - Disable async execution

**Basic usage:**
```ruby
# Configure per-action
async :sidekiq, queue: "high_priority"

# Configure globally
Axn.configure do |c|
  c.set_default_async(:sidekiq, queue: "default")
end
```

For detailed information about async execution, including delayed execution, adapter configuration options, and best practices, see the [Async Execution documentation](/reference/async).

#### Disabled

Disables async execution entirely. The action will raise a `NotImplementedError` when `call_async` is called.

```ruby
# In your action class
async false
```

### Default Configuration

By default, async execution is disabled (`false`). You can set a default configuration that will be applied to all actions that don't explicitly configure their own async behavior:

```ruby
Axn.configure do |c|
  # Set a default async configuration
  c.set_default_async(:sidekiq, queue: "default") do
    sidekiq_options retry: 3
  end
end

# Now all actions will use Sidekiq by default
class MyAction
  include Axn
  # No async configuration needed - uses default
end
```

## Rails-specific Configuration

When using Axn in a Rails application, additional configuration options are available under `Axn.config.rails`:

### `app_actions_autoload_namespace`

Controls the namespace for actions in `app/actions`. Defaults to `nil` (no namespace).

```ruby
Axn.configure do |c|
  # No namespace (default behavior)
  c.rails.app_actions_autoload_namespace = nil

  # Use Actions namespace
  c.rails.app_actions_autoload_namespace = :Actions

  # Use any other namespace
  c.rails.app_actions_autoload_namespace = :MyApp
end
```

When `nil` (default), actions in `app/actions/user_management/create_user.rb` will be available as `UserManagement::CreateUser`.

When set to `:Actions`, the same action will be available as `Actions::UserManagement::CreateUser`.

When set to any other symbol (e.g., `:MyApp`), the action will be available as `MyApp::UserManagement::CreateUser`.

## Automatic Logging

By default, every `action.call` will emit log lines when it is called and after it completes:

  ```
    [YourCustomAction] About to execute with: {:foo=>"bar"}
    [YourCustomAction] Execution completed (with outcome: success) in 0.957 milliseconds
  ```

Automatic logging will log at `Axn.config.log_level` by default, but can be overridden, scoped per outcome, or disabled using the declarative `auto_log` method:

```ruby
# Set default for all actions (affects both explicit logging and automatic logging)
Axn.configure do |c|
  c.log_level = :debug
end

# Override the level for a specific action (logs every outcome at :warn)
class MyAction
  auto_log :warn
end

# Disable automatic logging for an action
class SilentAction
  auto_log false
end

# Use the configured default level — any of these is equivalent to no declaration at all
class DefaultAction
  auto_log         # or: auto_log true
end
```

`auto_log` resolves a level for each of the three outcomes — `success`, `failure`, and `exception` (the values `result.outcome` reports). A positional level is the default for any outcome you do not name; per-outcome keywords override it. The **"About to execute" before line** is emitted only when success logging is on, at the success level — so narrating successful calls gives you the before/after bookend, and an errors-only configuration stays quiet until something goes wrong.

`auto_log` supports inheritance, so subclasses inherit the setting from their parent class unless they redeclare it.

### Error-Only Logging

To log only when something goes wrong, turn off `success` while leaving the failure/exception outcomes on. This logs **no** before line and an after line only on a failure or exception:

```ruby
class MyAction
  auto_log :warn, success: false  # log failures and exceptions at :warn; nothing on success
end
```

Because each outcome is configured independently, you can also distinguish an explicit `fail!` (outcome `failure`) from an unhandled raised error (outcome `exception`). For example, to log only genuine raised bugs and stay silent on expected `fail!`s:

```ruby
class MyAction
  auto_log exception: :error  # only log raised exceptions; nothing on success or fail!
end
```

When you give keywords but no positional level, the unnamed outcomes are off — so `auto_log exception: :error` logs *only* exceptions. Each keyword accepts a level, `false` (off), or `true` (the configured default level); an invalid level raises `ArgumentError` at declaration.

## Complete Configuration Example

Here's a complete example showing all available configuration options:

```ruby
Axn.configure do |c|
  # Logging
  c.log_level = :info
  c.logger = Rails.logger

  # Exception handling
  c.on_exception = proc do |e, action:, context:|
    Honeybadger.notify(
      "[#{action.class.name}] #{e.class.name}: #{e.message}",
      context: context
    )
  end

  # Exceptions swallowed in side channels (a raising on_success callback, a failing tracer, ...)
  # route to on_exception above by default. Assign a callable to send them elsewhere, or
  # false to drop them.
  # c.on_ignored_exception = false

  # Observability
  # Tracing auto-detects OpenTelemetry when it's loaded; assign c.tracer to use a different
  # tracer, or c.tracer = nil to disable spans without unloading OpenTelemetry.

  c.emit_metrics = proc do |resource:, result:|
    Datadog::Metrics.increment("axn.call", tags: { resource:, outcome: result.outcome.to_s })
    Datadog::Metrics.distribution("axn.call.duration", result.elapsed_time, tags: { resource:, outcome: result.outcome.to_s })
  end


  # Async configuration
  c.set_default_async(:sidekiq, queue: "default") do
    sidekiq_options retry: 3, priority: 5
  end

  # Global includes
  c.additional_includes = [MyCustomModule]

  # Rails-specific configuration
  c.rails.app_actions_autoload_namespace = :Actions
end
```
