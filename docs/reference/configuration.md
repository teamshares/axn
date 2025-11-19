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

## `raise_piping_errors_outside_production`

By default, errors that occur in framework code (e.g., in logging hooks, exception handlers, validators, or other user-provided callbacks) are swallowed and logged to prevent them from interfering with the main action execution. In development and test environments, you can opt-in to have these errors raised instead of logged:

```ruby
Axn.configure do |c|
  c.raise_piping_errors_outside_production = true
end
```

**Important notes:**
- This setting only applies in development and test environments—errors are always swallowed in production for safety
- When enabled, errors in framework code (like logging hooks, exception handlers, validators) will be raised instead of logged
- This is useful for debugging issues in user-provided callbacks or framework instrumentation code

## `wrap_with_trace` and `emit_metrics`

If you're using an APM provider, observability can be greatly enhanced by adding automatic _tracing_ of Axn calls and/or emitting count metrics after each call completes.

The framework provides two distinct hooks for observability:

- **`wrap_with_trace`**: An around hook that wraps the entire action execution. You MUST call the provided block to execute the action.
- **`emit_metrics`**: A post-execution hook that receives the action result. Do NOT call any blocks.

For example, to wire up Datadog:

```ruby
  Axn.configure do |c|
    c.wrap_with_trace = proc do |resource, &action|
      Datadog::Tracing.trace("Action", resource:) do
        action.call
      end
    end

    c.emit_metrics = proc do |resource, result|
      TS::Metrics.increment("action.#{resource.underscore}", tags: { outcome: result.outcome.to_s, resource: })
      TS::Metrics.histogram("action.duration", result.elapsed_time, tags: { resource: })
    end
  end
```

A couple notes:

  * `Datadog::Tracing` is provided by [the datadog gem](https://rubygems.org/gems/datadog)
  * `TS::Metrics` is a custom implementation to set a Datadog count metric, but the relevant part to note is that the result object provides access to the outcome (`result.outcome.success?`, `result.outcome.failure?`, `result.outcome.exception?`) and elapsed time of the action.
  * The `wrap_with_trace` hook is an around hook - you must call the provided block to execute the action
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

This is much less critical than the preceding options, but on the off chance you want to add additional customization to _all_ your actions you can set additional modules to be included alongside `include Action`.

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

Automatically detects the environment from `RACK_ENV` or `RAILS_ENV`, defaulting to `"development"`. This is used internally for conditional behavior (e.g., more verbose logging in non-production environments).

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

## Profiling

Axn supports performance profiling using [Vernier](https://github.com/Shopify/vernier), a Ruby sampling profiler. Profiling is enabled per-action by calling the `profile` method.

### Usage

Enable profiling on specific actions using the `profile` method:

```ruby
class MyAction
  include Axn

  # Profile conditionally (only one profile call per action)
  profile if: -> { debug_mode }

  expects :name, :debug_mode

  def call
    "Hello, #{name}!"
  end
end
```

### Configuration Options

The `profile` method accepts several options:

```ruby
class MyAction
  include Axn

  # Profile with custom options
  profile(
    if: -> { debug_mode },
    sample_rate: 0.1,  # Sampling rate (0.0 to 1.0, default: 0.1)
    output_dir: "tmp/profiles"  # Output directory (default: Rails.root/tmp/profiles or tmp/profiles)
  )

  def call
    # Action logic
  end
end
```

**Important**:
- You can only call `profile` **once per action** - subsequent calls will override the previous one
- This prevents accidental profiling of all actions and ensures you only profile what you intend to analyze

### Viewing Profiles

Profiles are saved as JSON files that can be viewed in the [Firefox Profiler](https://profiler.firefox.com/):

1. Run your action with profiling enabled
2. Find the generated profile file in your `profiling_output_dir`
3. Upload the JSON file to [profiler.firefox.com](https://profiler.firefox.com/)
4. Analyze the performance data

For more detailed information, see the [Profiling guide](/advanced/profiling).

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
  c.wrap_with_trace = proc do |resource, &action|
    Datadog::Tracing.trace("Action", resource:) do
      action.call
    end
  end

  c.emit_metrics = proc do |resource, result|
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
