# ActiveJob Adapter Setup

This guide covers the setup and configuration for using Axn with the ActiveJob adapter.

## Basic Setup

To use ActiveJob with Axn, configure your actions with `async :active_job`:

```ruby
class SendEmailAction
  include Axn

  async :active_job do
    queue_as :mailers
    retry_on StandardError, wait: 5.seconds, attempts: 3
  end

  expects :user, :template

  def call
    # Send email logic
  end
end

# Execute in background
SendEmailAction.call_async(user: user, template: "welcome")
```

## How It Works

Unlike the Sidekiq adapter (where your action class becomes the worker), the ActiveJob adapter creates a **proxy job class** that inherits from `ActiveJob::Base`. This proxy:

1. Receives the job arguments
2. Calls your action with those arguments
3. Handles the result (re-raising exceptions for retry, swallowing business failures)

## Configuration

### Per-Action Configuration

Use a block to configure ActiveJob options:

```ruby
class MyAction
  include Axn

  async :active_job do
    queue_as :critical
    retry_on NetworkError, wait: :polynomially_longer, attempts: 5
    discard_on ActiveRecord::RecordNotFound
  end
end
```

::: warning
ActiveJob adapter requires a configuration block. Keyword arguments are not supported because ActiveJob methods like `retry_on` and `discard_on` require exception classes as arguments:

```ruby
# ❌ This will raise an error
async :active_job, queue: "critical"

# ✅ Use a block instead
async :active_job do
  queue_as :critical
end
```
:::

### Global Default

Set a default ActiveJob configuration for all actions:

```ruby
Axn.configure do |c|
  c.set_default_async(:active_job) do
    queue_as :default
    retry_on StandardError, wait: 5.seconds, attempts: 3
  end
end
```

## Error Handling Behavior

### Business Failures (fail!)

When an action calls `fail!`, it's treated as a deliberate business decision:

- The job **does NOT retry**
- The job completes successfully (from ActiveJob's perspective)
- `on_exception` is **NOT triggered**

```ruby
class PaymentAction
  include Axn
  async :active_job

  def call
    # This will NOT trigger retries - job completes immediately
    fail! "Card declined" if card_declined?
  end
end
```

### Unexpected Exceptions

When an unexpected exception occurs:

- The job **DOES retry** (based on your `retry_on` configuration)
- `on_exception` is triggered based on `async_exception_reporting` setting

```ruby
class SyncAction
  include Axn

  async :active_job do
    retry_on NetworkError, wait: 5.seconds, attempts: 3
  end

  def call
    # This WILL trigger retries (if NetworkError)
    raise NetworkError, "Connection timeout"
  end
end
```

## Retry Tracking

ActiveJob provides retry information through its built-in `executions` counter:

- `executions == 1`: First attempt
- `executions == 2`: First retry
- `executions == 3`: Second retry
- etc.

Axn uses this to build retry context for exception reporting.

### Max Retries Detection

Axn determines max retries in this order:

1. **Job's `retry_limit`**: If your job class defines a retry limit via `retry_on`
2. **`Axn.config.async_max_retries`**: If you've explicitly configured this
3. **Backend detection**: Axn attempts to detect if Sidekiq is the backend and uses its default (25)
4. **Fallback**: 5 (matches ActiveJob's `retry_on` default)

## Retry Context in Exception Reports

When `on_exception` is triggered, the context includes retry information:

```ruby
Axn.configure do |c|
  c.on_exception = proc do |e, action:, context:|
    if context[:async]
      puts "Adapter: #{context[:async][:adapter]}"  # => :active_job
      puts "Attempt: #{context[:async][:attempt]}"
      puts "Max retries: #{context[:async][:max_retries]}"
      puts "Job ID: #{context[:async][:job_id]}"
    end

    Honeybadger.notify(e, context: context)
  end
end
```

## Using with Sidekiq Backend

If you're using ActiveJob with Sidekiq as the backend:

```ruby
# config/application.rb
config.active_job.queue_adapter = :sidekiq
```

In this case:
- Retry tracking uses ActiveJob's `executions` counter (not Sidekiq's `retry_count`)
- You don't need to register Sidekiq middleware for ActiveJob actions
- The Sidekiq middleware only applies to actions using `async :sidekiq` directly

### Choosing Between Adapters

| Use `async :sidekiq` when... | Use `async :active_job` when... |
|------------------------------|--------------------------------|
| You want direct Sidekiq control | You want backend portability |
| You need Sidekiq-specific features (batches, etc.) | You're using non-Sidekiq backend |
| Performance is critical | You prefer Rails conventions |

## Discarded Job Handling (Rails 7.1+)

On Rails 7.1+, Axn automatically registers an `after_discard` callback on the proxy job class. This triggers `on_exception` when:

- `discard_on` catches an exception
- `retry_on` exhausts all retries
- An unhandled exception causes the job to be discarded

This means `:first_and_exhausted` and `:only_exhausted` modes work correctly—exceptions are reported when the job is actually discarded, not just on the final attempt.

```ruby
class MyAction
  include Axn

  async :active_job do
    discard_on ValidationError  # Will trigger on_exception when discarded
    retry_on NetworkError, attempts: 3  # Will trigger on_exception when exhausted
  end

  def call
    # ...
  end
end
```

The discard context includes `discarded: true` in the async info:

```ruby
Axn.configure do |c|
  c.on_exception = proc do |e, context:|
    if context.dig(:async, :discarded)
      puts "Job was discarded!"
    end
  end
end
```

::: warning
Rails 7.1+ is required for `:first_and_exhausted` and `:only_exhausted` modes with the ActiveJob adapter. These modes rely on `after_discard` which was introduced in Rails 7.1. On older Rails versions, Axn will raise an error if you try to use these modes with ActiveJob.
:::

## Limitations

### Retry Configuration

ActiveJob's retry behavior is defined per-exception type via `retry_on`, while Sidekiq uses a global retry count. Make sure to configure `retry_on` for the exceptions you expect:

```ruby
async :active_job do
  # Retry network errors
  retry_on NetworkError, wait: :polynomially_longer, attempts: 5

  # Retry rate limiting with longer wait
  retry_on RateLimitError, wait: 1.minute, attempts: 10

  # Don't retry validation errors
  discard_on ValidationError
end
```

## Troubleshooting

### Jobs not retrying

Ensure you've configured `retry_on` for the exception types you expect:

```ruby
async :active_job do
  retry_on StandardError, attempts: 3  # Catch-all retry
end
```

### Wrong max_retries in context

If `context[:async][:max_retries]` doesn't match your expectations:

1. Check if your job has `retry_limit` defined (from `retry_on`)
2. Try setting `Axn.config.async_max_retries` explicitly
3. Verify Sidekiq detection is working (if using Sidekiq backend)

### Jobs not completing on fail!

This is expected behavior. `fail!` indicates a business decision, and the job completes successfully (from ActiveJob's perspective) without retrying.
