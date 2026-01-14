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

The `enqueues_each` method provides a declarative way to set up batch enqueueing. It automatically iterates over collections and enqueues each item as a separate background job.

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

  # No enqueues_each needed! Source is auto-inferred from model: Company
end

# Usage
SyncForCompany.enqueue_all  # Automatically iterates Company.all and enqueues each company
```

**How it works:**
1. `enqueue_all` validates configuration upfront (async configured, static args present)
2. Enqueues an `EnqueueAllTrigger` job in the background
3. When `EnqueueAllTrigger` runs, it iterates over the source collection and enqueues individual jobs
4. Model-based iterations (using `find_each`) are processed first for memory efficiency

### Auto-Inference from `model:` Declarations

If a field has a `model:` declaration and the model class responds to `find_each`, you **don't need to explicitly declare `enqueues_each`**. The source collection is automatically inferred:

```ruby
class SyncForCompany
  include Axn
  async :sidekiq

  expects :company, model: Company  # Auto-inferred: Company.all

  def call
    # ... sync logic
  end

  # No enqueues_each needed - automatically iterates Company.all
end

SyncForCompany.enqueue_all  # Works without explicit enqueues_each!
```

### Explicit Configuration with `enqueues_each`

Use `enqueues_each` when you need to:
- Override the default source (e.g., `Company.active` instead of `Company.all`)
- Add filtering logic
- Extract specific attributes
- Iterate over fields without `model:` declarations

```ruby
class SyncForCompany
  include Axn
  async :sidekiq

  expects :company, model: Company

  def call
    # ... sync logic
  end

  # Override default source
  enqueues_each :company, from: -> { Company.active }

  # With extraction (passes company_id instead of company object)
  enqueues_each :company_id, from: -> { Company.active }, via: :id

  # With filter block
  enqueues_each :company do |company|
    company.active? && !company.in_exit?
  end

  # Method name as source
  enqueues_each :company, from: :active_companies
end
```

### Overriding on `enqueue_all` Call

You can override iteration sources or make fields static when calling `enqueue_all`:

```ruby
class SyncForCompany
  include Axn
  async :sidekiq

  expects :company, model: Company
  expects :user, model: User

  def call
    # ... sync logic
  end

  # Default: iterates Company.all
  enqueues_each :company
end

# Override with a subset (enumerable kwarg replaces source)
SyncForCompany.enqueue_all(company: Company.active.limit(10))

# Override with a single value (scalar kwarg makes it static, no iteration)
SyncForCompany.enqueue_all(company: Company.find(123))

# Mix static and iterated fields
SyncForCompany.enqueue_all(
  company: Company.active,  # Iterates over active companies
  user: User.find(1)        # Static: same user for all jobs
)
```

### Dynamic Iteration via Kwargs

You can iterate over fields without any `enqueues_each` declaration by passing enumerables directly:

```ruby
class ProcessFormats
  include Axn
  async :sidekiq

  expects :format
  expects :mode

  def call
    # ... process logic
  end
end

# Pass enumerables to create cross-product iteration
ProcessFormats.enqueue_all(
  format: [:csv, :json, :xml],  # Iterates: 3 jobs
  mode: :full                    # Static: same mode for all
)

# Multiple enumerables create cross-product
ProcessFormats.enqueue_all(
  format: [:csv, :json],         # 2 formats
  mode: [:full, :incremental]    # 2 modes
)
# Result: 2 × 2 = 4 jobs total
```

**Note:** Arrays and Sets are treated as static values (not iterated) when the field expects an enumerable type:

```ruby
expects :tags, type: Array

# This passes the entire array as a static value
ProcessTags.enqueue_all(tags: ["ruby", "rails", "testing"])
```

### Multi-Field Cross-Product Iteration

Multiple `enqueues_each` declarations create a cross-product of all combinations:

```ruby
class SyncForUserAndCompany
  include Axn
  async :sidekiq

  expects :user, model: User
  expects :company, model: Company

  def call
    # ... sync logic for user + company combination
  end

  enqueues_each :user, from: -> { User.active }
  enqueues_each :company, from: -> { Company.active }
end

# Creates user_count × company_count jobs
# Each combination of (user, company) gets its own job
SyncForUserAndCompany.enqueue_all
```

### Static Fields

Fields declared with `expects` but not covered by `enqueues_each` (or auto-inference) become static fields that must be passed to `enqueue_all`:

```ruby
class SyncWithMode
  include Axn
  async :sidekiq

  expects :company, model: Company  # Auto-inferred, will iterate
  expects :sync_mode                 # Static, must be provided

  def call
    # Uses both company (iterated) and sync_mode (static)
  end
end

# sync_mode must be provided - it's passed to every enqueued job
SyncWithMode.enqueue_all(sync_mode: :full)
```

### Memory Efficiency

For optimal memory usage, model-based configs (using `find_each`) are automatically processed first in nested iterations. This ensures ActiveRecord-style batch processing happens before loading potentially large enumerables into memory.

```ruby
# Model-based iteration uses find_each (memory efficient)
expects :company, model: Company  # Processed first

# Array-based iteration uses each (loads all into memory)
enqueues_each :format, from: -> { [:csv, :json, :xml] }  # Processed second
```

### Iteration Method Selection

- **`find_each`**: Used when the source responds to `find_each` (ActiveRecord collections) - processes in batches for memory efficiency
- **`each`**: Used for plain arrays and other enumerables - loads all items into memory

### Edge Cases and Limitations

1. **Fields expecting enumerable types**: If a field expects `Array` or `Set`, arrays/sets passed to `enqueue_all` are treated as static values (not iterated)
2. **Strings and Hashes**: Always treated as static values, even though they respond to `:each`
3. **No model or source**: If a field has no `model:` declaration and no `enqueues_each` with `from:`, you must pass it as a kwarg to `enqueue_all` or it will raise an error
4. **Required static fields**: Fields without defaults that aren't covered by iteration must be provided to `enqueue_all`
