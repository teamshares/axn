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
  current_attributes: { ... },  # Current.attributes (auto-included if defined and present)
  tags: { ... }                 # Resolved `tag` facets (only when the action declares any)
  dimensions: { ... }           # Resolved `dimension` facets (only when the action declares any)
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
    # context[:current_attributes] - Rails Current.attributes (if present)
    # context[:async] - Retry info (if in async context)
    
    Honeybadger.notify(e, context: context)
  end
end
```

### Additional Notes

- Sensitive fields (marked with `expects :foo, sensitive: true`) are automatically filtered to `"[FILTERED]"`
- If your handler raises an exception, the failure will be swallowed and logged
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

## `raise_piping_errors_in_dev`

By default, errors that occur in framework code (e.g., in logging hooks, exception handlers, validators, or other user-provided callbacks) are swallowed and logged to prevent them from interfering with the main action execution. In development, you can opt-in to have these errors raised instead of logged:

```ruby
Axn.configure do |c|
  c.raise_piping_errors_in_dev = true
end
```

**Important notes:**
- This setting only applies in the development environment—errors are always swallowed in test and production
- Test and production environments behave identically (errors swallowed), ensuring tests verify actual production behavior
- When enabled in development, errors in framework code (like logging hooks, exception handlers, validators) will be raised instead of logged, putting issues front and center during manual testing

## OpenTelemetry Tracing

Axn automatically creates OpenTelemetry spans for all action executions when OpenTelemetry is available. The framework creates a span named `"axn.call"` with the following attributes:

- `axn.resource`: The action class name (e.g., `"UserManagement::CreateUser"`)
- `axn.outcome`: The execution outcome (`"success"`, `"failure"`, or `"exception"`)

When an action fails or raises an exception, the span is marked as an error with the exception details recorded.

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

**Cardinality mapping.** An Axn `tag` is high-cardinality and becomes a span attribute, a log field, and an exception-report facet (`context[:tags]`) — safe for per-call values like ids. An Axn `dimension` is bounded and additionally flows to indexing sinks — `emit_metrics` and the exception report's `context[:dimensions]`, meant for indexed tags (e.g. Sentry/Honeybadger tags) — where unbounded values are costly. This is the reverse of "tag" in Datadog/Sentry/Sidekiq (where a tag is the bounded thing); pick the Axn macro by cardinality, not by the downstream tool's word.

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
| `raise_piping_errors_in_dev` | Always swallowed | Always swallowed | Configurable |
| Error message verbosity | Minimal | More detailed | More detailed |

### Overriding the Environment

You can explicitly set the environment if auto-detection doesn't work for your setup:

```ruby
Axn.configure do |c|
  c.env = "staging"
end

Axn.config.env.staging?  # => true
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
      # Foreground execution - context still includes inputs and current_attributes
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

  # Observability
  # OpenTelemetry tracing is automatic when OpenTelemetry is available

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
