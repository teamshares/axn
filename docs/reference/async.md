# Async Execution

Axn provides built-in support for asynchronous execution through background job processing libraries. This allows you to execute actions in the background without blocking the main thread.

## Overview

Async execution in Axn is designed to be simple and consistent across different background job libraries. You can configure async behavior globally or per-action, and all async adapters support the same interface.

## Basic Usage

### Configuring Async Adapters

```ruby
class EmailAction
  include Axn

  # Configure async adapter
  async :sidekiq

  expects :user, :message

  def call
    # Send email logic
  end
end

# Execute immediately (synchronous)
result = EmailAction.call(user: user, message: "Welcome!")

# Execute asynchronously (background)
EmailAction.call_async(user: user, message: "Welcome!")
```

### Available Async Adapters

#### Sidekiq

The Sidekiq adapter provides integration with the Sidekiq background job processing library.

```ruby
# In your action class
async :sidekiq do
  sidekiq_options queue: "high_priority", retry: 5, priority: 10
end

# Or with keyword arguments (shorthand)
async :sidekiq, queue: "high_priority", retry: 5
```

**Configuration options:**
- `queue`: The Sidekiq queue name (default: "default")
- `retry`: Number of retry attempts (default: 25)
- `priority`: Job priority (default: 0)
- Any other Sidekiq options supported by `sidekiq_options`

#### ActiveJob

The ActiveJob adapter provides integration with Rails' ActiveJob framework.

```ruby
# In your action class
async :active_job do
  queue_as "high_priority"
  self.priority = 10
  self.wait = 5.minutes
end
```

**Configuration options:**
- `queue_as`: The ActiveJob queue name
- `priority`: Job priority
- `wait`: Delay before execution
- Any other ActiveJob options

#### Disabled

Disables async execution entirely. The action will raise a `NotImplementedError` when `call_async` is called.

```ruby
# In your action class
async false
```

## Delayed Execution

All async adapters support delayed execution using the `_async` parameter in `call_async`. This allows you to schedule actions to run at specific future times without changing the interface.

```ruby
class EmailAction
  include Axn
  async :sidekiq

  expects :user, :message

  def call
    # Send email logic
  end
end

# Immediate execution
EmailAction.call_async(user: user, message: "Welcome!")

# Delayed execution - wait 1 hour
EmailAction.call_async(user: user, message: "Follow up", _async: { wait: 1.hour })

# Scheduled execution - run at specific time
EmailAction.call_async(user: user, message: "Reminder", _async: { wait_until: 1.week.from_now })
```

### Supported Scheduling Options

- `wait`: Execute after a specific time interval (e.g., `1.hour`, `30.minutes`)
- `wait_until`: Execute at a specific future time (e.g., `1.hour.from_now`, `Time.parse("2024-01-01 12:00:00")`)

### Adapter-Specific Behavior

- **Sidekiq**: Uses `perform_in` for `wait` and `perform_at` for `wait_until`
- **ActiveJob**: Uses `set(wait:)` for `wait` and `set(wait_until:)` for `wait_until`
- **Disabled**: Ignores scheduling options and raises `NotImplementedError`

### Parameter Name Safety

The `_async` parameter is reserved for scheduling options.

## Global Configuration

You can set default async configuration that will be applied to all actions that don't explicitly configure their own async behavior:

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

## Error Handling

Async actions trigger via `call!` internally, so they raise on failure, which means the background job system can seamlessly handle retries.

```ruby
class FailingAction
  include Axn
  async :sidekiq, retry: 3

  def call
    fail! "Something went wrong"
  end
end

# The job will be retried up to 3 times before giving up
FailingAction.call_async(data: "test")
```

## Batch Enqueueing with `enqueues_each`

The `enqueues_each` method provides a declarative way to set up batch enqueueing. It creates methods that iterate over a collection and enqueue each item as a separate background job.

### Basic Usage

```ruby
class SyncForCompany
  include Axn

  async :sidekiq

  expects :company, model: Company

  def call
    puts "Syncing data for company: #{company.name}"
    # Sync individual company data
  end

  # Declare the field to iterate over - source is inferred from model: Company
  enqueues_each :company
end

# Usage
SyncForCompany.enqueue_all  # Enqueues EnqueueAllTrigger, which iterates and enqueues individual jobs
```

**How it works:**
1. `enqueue_all` validates configuration upfront (async configured, static args present)
2. Enqueues an `EnqueueAllTrigger` job in the background
3. When `EnqueueAllTrigger` runs, it iterates over the source collection and enqueues individual jobs

### Key Features

- **Declarative**: Define what to iterate over, not how to iterate
- **Source Options**: Infer from `model:`, provide a lambda, or reference a class method
- **Filtering**: Use a block to filter which items to enqueue
- **Extraction**: Use `via:` to extract a specific attribute (e.g., `:id`)
- **Multi-field**: Multiple `enqueues_each` declarations create cross-product iteration
- **Static Fields**: Fields not covered by `enqueues_each` are passed through to each job

### Examples

```ruby
class SyncForCompany
  include Axn
  async :sidekiq

  expects :company, model: Company

  def call
    # ... sync logic
  end

  # Basic - source inferred from model: Company → Company.all
  enqueues_each :company

  # With explicit source lambda
  enqueues_each :company, from: -> { Company.active }

  # With extraction (passes company_id instead of company object)
  enqueues_each :company_id, from: -> { Company.active }, via: :id

  # With filter block
  enqueues_each :company do |company|
    company.active? && !company.in_exit?
  end

  # Multi-field cross-product (creates user_count × company_count jobs)
  enqueues_each :user, from: -> { User.active }
  enqueues_each :company, from: -> { Company.active }
end
```

### Static Fields

Fields declared with `expects` but not covered by `enqueues_each` become static fields that must be passed to `enqueue_all`:

```ruby
class SyncWithMode
  include Axn
  async :sidekiq

  expects :company, model: Company
  expects :sync_mode

  def call
    # Uses both company (iterated) and sync_mode (static)
  end

  enqueues_each :company  # Only iterates over company
end

# sync_mode must be provided - it's passed to every enqueued job
SyncWithMode.enqueue_all(sync_mode: :full)
```

### Iteration Method

`enqueues_each` uses `find_each` when available (ActiveRecord collections) for memory efficiency, falling back to `each` for plain arrays.
