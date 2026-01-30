# Sidekiq Adapter Setup

This guide covers the setup and configuration for using Axn with the Sidekiq background job adapter.

## Basic Setup

To use Sidekiq with Axn, configure your actions with `async :sidekiq`:

```ruby
class SendEmailAction
  include Axn

  async :sidekiq, queue: "mailers", retry: 5

  expects :user, :template

  def call
    # Send email logic
  end
end

# Execute in background
SendEmailAction.call_async(user: user, template: "welcome")
```

## Automatic Configuration

When you set `async_exception_reporting` to `:first_and_exhausted` or `:only_exhausted` in your Axn configuration, Axn **automatically registers** the required Sidekiq middleware and death handler:

```ruby
# config/initializers/axn.rb
Axn.configure do |c|
  # This automatically registers Sidekiq middleware and death handler
  c.async_exception_reporting = :first_and_exhausted
end
```

No manual Sidekiq configuration is needed in this case.

## Manual Configuration

If you prefer to configure Sidekiq manually, or if auto-configuration doesn't work for your setup, add the following to your Sidekiq initializer:

```ruby
# config/initializers/sidekiq.rb

# Option 1: Use the auto-configure helper (recommended)
Axn::Async::Adapters::Sidekiq::AutoConfigure.register!

# Option 2: Manual registration
Sidekiq.configure_server do |config|
  # Middleware for retry context tracking
  config.server_middleware do |chain|
    chain.add Axn::Async::Adapters::Sidekiq::Middleware
  end

  # Death handler for exhausted retry reporting
  config.death_handlers << Axn::Async::Adapters::Sidekiq::DeathHandler
end
```

## What the Middleware Does

### Retry Context Middleware

`Axn::Async::Adapters::Sidekiq::Middleware` sets up retry context for each job execution:

- **Tracks attempt number**: Knows which retry attempt is currently running (1st, 2nd, 3rd, etc.)
- **Tracks max retries**: Reads the job's configured retry limit
- **Enables smart exception reporting**: Allows `on_exception` to be triggered only on specific attempts

Without the middleware, `on_exception` will trigger on every retry attempt regardless of your `async_exception_reporting` setting.

### Death Handler

`Axn::Async::Adapters::Sidekiq::DeathHandler` triggers `on_exception` when a job exhausts all retries:

- Only activates for jobs using the Axn Sidekiq adapter
- Provides full context including job arguments and retry information
- Respects the `async_exception_reporting` configuration

The death handler is required when using `:first_and_exhausted` or `:only_exhausted` modes.

## Configuration Options

### Per-Action Options

```ruby
class MyAction
  include Axn

  async :sidekiq do
    sidekiq_options queue: "critical",
                    retry: 10,
                    backtrace: true,
                    dead: false
  end
end

# Or using keyword shorthand
async :sidekiq, queue: "critical", retry: 10
```

Common Sidekiq options:

| Option | Default | Description |
|--------|---------|-------------|
| `queue` | `"default"` | Queue name for the job |
| `retry` | `25` | Max retry attempts (or `false` to disable) |
| `backtrace` | `false` | Store backtrace with job on failure |
| `dead` | `true` | Move to dead queue when exhausted |

### Global Default

Set a default Sidekiq configuration for all actions:

```ruby
Axn.configure do |c|
  c.set_default_async(:sidekiq, queue: "default", retry: 5) do
    sidekiq_options backtrace: true
  end
end
```

## Error Handling Behavior

### Business Failures (fail!)

When an action calls `fail!`, it's treated as a deliberate business decision:

- The job **does NOT retry**
- The job completes (not moved to dead queue)
- `on_exception` is **NOT triggered** (it's not an exception)

```ruby
class PaymentAction
  include Axn
  async :sidekiq, retry: 5

  def call
    # This will NOT trigger retries - job completes immediately
    fail! "Card declined" if card_declined?
  end
end
```

### Unexpected Exceptions

When an unexpected exception occurs:

- The job **DOES retry** (up to the configured limit)
- `on_exception` is triggered based on `async_exception_reporting` setting
- When exhausted, job moves to dead queue and death handler fires

```ruby
class SyncAction
  include Axn
  async :sidekiq, retry: 5

  def call
    # This WILL trigger retries
    raise NetworkError, "Connection timeout"
  end
end
```

## Retry Context in Exception Reports

When `on_exception` is triggered, the context includes retry information:

```ruby
Axn.configure do |c|
  c.on_exception = proc do |e, action:, context:|
    # context[:async] contains retry information when in async context
    if context[:async]
      puts "Attempt: #{context[:async][:attempt]}"
      puts "Max retries: #{context[:async][:max_retries]}"
      puts "Exhausted: #{context[:async][:retries_exhausted]}"
      puts "Job ID: #{context[:async][:job_id]}"
    end

    Honeybadger.notify(e, context: context)
  end
end
```

## Troubleshooting

### Exceptions reported on every retry

If you're seeing `on_exception` triggered on every retry attempt despite configuring `:first_and_exhausted`:

1. Ensure the Sidekiq middleware is registered
2. Check that you're using `async :sidekiq` (not `async :active_job` with Sidekiq backend)

```ruby
# Verify middleware is registered
Axn::Async::Adapters::Sidekiq::AutoConfigure.middleware_registered?
# => should be true
```

### Death handler not firing

If exhausted jobs aren't triggering `on_exception`:

1. Ensure the death handler is registered
2. Verify `async_exception_reporting` is set to `:first_and_exhausted` or `:only_exhausted`

```ruby
# Verify death handler is registered
Axn::Async::Adapters::Sidekiq::AutoConfigure.death_handler_registered?
# => should be true
```

### Jobs not retrying on fail!

This is expected behavior. `fail!` indicates a business decision, not a transient error. If you need retries for a specific failure case, raise an exception instead:

```ruby
def call
  # Use fail! for business logic (no retry)
  fail! "Invalid input" if invalid_input?

  # Use raise for transient errors (will retry)
  raise RetryableError, "Service unavailable" if service_down?
end
```
