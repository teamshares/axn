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
      set_execution_context(current_record_id: record.id, batch_index: @index)
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

  def additional_execution_context
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

  on_exception do |exception:|
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

## `emit_metrics`

If you're using a metrics provider, you can emit custom metrics after each action completes using the `emit_metrics` hook. This is a post-execution hook that receives the action result—do NOT call any blocks.

The hook only receives the keyword arguments it explicitly expects (e.g., if you only define `resource:`, you won't receive `result:`).

For example, to wire up Datadog metrics:

```ruby
  Axn.configure do |c|
    c.emit_metrics = proc do |resource:, result:|
      TS::Metrics.increment("action.#{resource.underscore}", tags: { outcome: result.outcome.to_s, resource: })
      TS::Metrics.histogram("action.duration", result.elapsed_time, tags: { resource: })
    end
  end
```

You can also define `emit_metrics` to only receive the arguments you need:

```ruby
  # Only receive resource (if you don't need the result)
  c.emit_metrics = proc do |resource:|
    TS::Metrics.increment("action.#{resource.underscore}")
  end

  # Only receive result (if you don't need the resource)
  c.emit_metrics = proc do |result:|
    TS::Metrics.increment("action.call", tags: { outcome: result.outcome.to_s })
  end

  # Accept any keyword arguments (receives both)
  c.emit_metrics = proc do |**kwargs|
    # kwargs will contain both :resource and :result
  end
```

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
  c.logger = (defined?(Sidekiq) && Sidekiq.server?) ? Sidekiq.logger : Rails.logger
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

Automatic logging will log at `Axn.config.log_level` by default, but can be overridden or disabled using the declarative `log_calls` method:

```ruby
# Set default for all actions (affects both explicit logging and automatic logging)
Axn.configure do |c|
  c.log_level = :debug
end

# Override for specific actions
class MyAction
  log_calls :warn  # Use warn level for this action
end

class SilentAction
  log_calls false  # Disable automatic logging for this action
end

# Use default level (no log_calls call needed)
class DefaultAction
  # Uses Axn.config.log_level
end
```

The `log_calls` method supports inheritance, so subclasses will inherit the setting from their parent class unless explicitly overridden.

### Error-Only Logging

For actions where you only want to log when something goes wrong, use `log_errors` instead of `log_calls`. This will:
- **Not** log before execution
- **Only** log after execution if `result.ok?` is false (i.e., on failures or exceptions)

```ruby
class MyAction
  log_calls false   # Disable full logging
  log_errors :warn  # Only log failures/exceptions at warn level
end

class SilentOnErrorsAction
  log_calls false
  log_errors false  # Disable error logging for this action
end

# Use default level
class DefaultErrorLoggingAction
  log_calls false
  log_errors Axn.config.log_level  # Uses default log level
end
```

The `log_errors` method supports inheritance, just like `log_calls`. If both `log_calls` and `log_errors` are set, `log_calls` takes precedence (it will log before and after for all outcomes). To use `log_errors` exclusively, you must first disable `log_calls` with `log_calls false`.

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
    Datadog::Metrics.increment("action.#{resource.underscore}", tags: { outcome: result.outcome.to_s })
    Datadog::Metrics.histogram("action.duration", result.elapsed_time, tags: { resource: })
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
