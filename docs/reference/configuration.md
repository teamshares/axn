# Configuration

Somewhere at boot (e.g. `config/initializers/actions.rb` in Rails), you can call `Axn.configure` to adjust a few global settings.

```ruby
Axn.configure do |c|
  c.log_level = :info
  c.logger = ...
  c.on_exception = proc do |e, action:, context:|
    message = "[#{action.class.name}] Failing due to #{e.class.name}: #{e.message}"

    Rails.logger.warn(message)
    Honeybadger.notify(message, context: { axn_context: context })
  end
end
```

## `on_exception`

By default any swallowed errors are noted in the logs, but it's _highly recommended_ to wire up an `on_exception` handler so those get reported to your error tracking service.

For example, if you're using Honeybadger this could look something like:

```ruby
  Axn.configure do |c|
    c.on_exception = proc do |e, action:, context:|
      message = "[#{action.class.name}] Failing due to #{e.class.name}: #{e.message}"

      Rails.logger.warn(message)
      Honeybadger.notify(message, context: { axn_context: context })
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

A couple notes:

  * `context` will contain the arguments passed to the `action`, _but_ any marked as sensitive (e.g. `expects :foo, sensitive: true`) will be filtered out in the logs.
  * If your handler raises, the failure will _also_ be swallowed and logged
  * This handler is global across _all_ Axns.  You can also specify per-Action handlers via [the class-level declaration](/reference/class#on-exception).
  * The `context` hash may contain complex objects (like ActiveRecord models, `ActionController::Parameters`, or `Axn::FormObject` instances) that aren't easily serialized by error tracking systems. See [Formatting Context for Error Tracking Systems](/recipes/formatting-context-for-error-tracking) for a recipe to convert these to readable formats.

### Adding Additional Context to Exception Logging

When processing records in a loop or performing batch operations, you may want to include additional context (like which record is being processed) in exception logs. You can do this in two ways:

**Option 1: Explicit setter** - Call `set_logging_context` during execution:

```ruby
class ProcessPendingRecords
  include Axn

  def call
    pending_records.each do |record|
      set_logging_context(current_record_id: record.id, batch_index: @index)
      # ... process record ...
    end
  end
end
```

**Option 2: Hook method** - Define a private `additional_logging_context` method that returns a hash:

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

  def additional_logging_context
    return {} unless @current_record

    {
      current_record_id: @current_record.id,
      record_type: @current_record.class.name
    }
  end
end
```

Both approaches can be used together - they will be merged. The additional context is **only** included in exception logging (not in normal pre/post execution logs), and is evaluated lazily (the hook method is only called when an exception occurs).

Action-specific `on_exception` handlers can also access this context by calling `context_for_logging` directly:

```ruby
class ProcessPendingRecords
  include Axn

  on_exception do |exception:|
    log "Failed with this extra context: #{context_for_logging}"
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

No configuration is required—if OpenTelemetry is loaded in your application, Axn will automatically instrument all actions. To send traces to an APM provider like Datadog, configure OpenTelemetry with the appropriate exporter.

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
    message = "[#{action.class.name}] Failing due to #{e.class.name}: #{e.message}"
    Rails.logger.warn(message)
    Honeybadger.notify(message, context: { axn_context: context })
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
