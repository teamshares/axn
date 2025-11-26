# Profiling

Axn supports performance profiling using [Vernier](https://github.com/Shopify/vernier), a Ruby sampling profiler that provides detailed insights into your action's performance characteristics.

## Overview

Profiling helps you identify performance bottlenecks in your actions by capturing detailed execution traces. Vernier is particularly useful for:

- Identifying slow methods and code paths
- Understanding memory allocation patterns
- Analyzing call stacks and execution flow
- Optimizing performance-critical actions

## Setup

### 1. Install Vernier

Add the Vernier gem to your Gemfile:

```ruby
# Gemfile
gem 'vernier', '~> 0.1'
```

Then run:

```bash
bundle install
```

**Note:** Vernier is not included as a dependency of Axn, so you must explicitly add it to your Gemfile if you want to use profiling features.

### 2. Enable Profiling

No global configuration is needed! Simply use the `:vernier` strategy on the actions you want to profile.

## Basic Usage

Profiling is enabled per-action by using the `:vernier` strategy. This follows the same pattern as other Axn strategies like `:transaction` and `:form`.

### Simple Profiling

Enable profiling on any action:

```ruby
class UserCreation
  include Axn

  # Always profile this action
  use :vernier

  expects :user_params

  def call
    user = User.create!(user_params)
    send_welcome_email(user)
  end

  private

  def send_welcome_email(user)
    UserMailer.welcome(user).deliver_now
  end
end
```

### Conditional Profiling

Profile only under specific conditions:

```ruby
class DataProcessing
  include Axn

  # Profile only when processing large datasets
  use :vernier, if: -> { record_count > 1000 }

  expects :records, :record_count

  def call
    records.each { |record| process_record(record) }
  end
end
```

**Alternative using a method:**

```ruby
class DataProcessing
  include Axn

  # Profile using a method
  use :vernier, if: :should_profile?

  expects :records, :record_count, :debug_mode, type: :boolean, default: false

  def should_profile?
    record_count > 1000 || debug_mode
  end

  def call
    records.each { |record| process_record(record) }
  end
end
```


## Advanced Usage

### Sampling Rate Control

Adjust the sampling rate per action:

```ruby
class DevelopmentAction
  include Axn

  # High sampling rate for development (more detailed data)
  use :vernier, sample_rate: 0.5 if Rails.env.development?

  def call
    # Action logic
  end
end

class ProductionAction
  include Axn

  # Low sampling rate for production (minimal overhead)
  use :vernier, sample_rate: 0.01 if Rails.env.production?

  def call
    # Action logic
  end
end
```

### Custom Output Directory

Organize profiles by environment or feature:

```ruby
class MyAction
  include Axn

  # Custom output directory
  use :vernier, output_dir: Rails.root.join("tmp", "profiles", Rails.env)

  def call
    # Action logic
  end
end
```

### Multiple Conditions

Combine multiple profiling conditions:

```ruby
class ComplexAction
  include Axn

  # Profile when debug mode is enabled OR when processing admin users
  use :vernier, if: -> { debug_mode || user.admin? }

  expects :user, :debug_mode, type: :boolean, default: false

  def call
    # Complex logic
  end
end
```

## Viewing and Analyzing Profiles

### 1. Generate Profile Data

Run your action with profiling enabled:

```ruby
# This will generate a profile file if conditions are met
result = UserCreation.call(user_params: { name: "John", email: "john@example.com" })
```

### 2. Locate Profile Files

Profile files are saved as JSON in your configured output directory:

```bash
# Default location
ls tmp/profiles/

# Example output
axn_UserCreation_1703123456.json
axn_DataProcessing_1703123457.json
```

### 3. View in Firefox Profiler

1. Open [profiler.firefox.com](https://profiler.firefox.com/)
2. Click "Load a profile from file"
3. Select your generated JSON file
4. Analyze the performance data

### 4. Understanding the Profile

The Firefox Profiler provides several views:

- **Call Tree**: Shows the complete call stack with timing
- **Flame Graph**: Visual representation of call stacks
- **Stack Chart**: Timeline view of function calls
- **Markers**: Custom markers and events

## Best Practices

### 1. Use Conditional Profiling

Avoid profiling all actions in production:

```ruby
# Good: Conditional profiling
use :vernier, if: -> { Rails.env.development? || debug_mode }

# Avoid: Always profiling in production
use :vernier  # This can impact performance
```

### 2. Appropriate Sampling Rates

Choose sampling rates based on your environment:

```ruby
class MyAction
  include Axn

  # High detail for debugging
  use :vernier, sample_rate: 0.5 if Rails.env.development?

  # Moderate sampling for staging
  use :vernier, sample_rate: 0.1 if Rails.env.staging?

  # Minimal overhead for production
  use :vernier, sample_rate: 0.01 if Rails.env.production?

  def call
    # Action logic
  end
end
```

### 3. Profile Specific Scenarios

Focus on performance-critical paths:

```ruby
class OrderProcessing
  include Axn

  # Profile only expensive operations
  use :vernier, if: -> { order.total > 1000 }

  expects :order

  def call
    process_payment
    send_confirmation
    update_inventory
  end
end
```

### 4. Clean Up Old Profiles

Implement profile cleanup to avoid disk space issues:

```ruby
# Add to a rake task or cron job
namespace :profiles do
  desc "Clean up old profile files"
  task cleanup: :environment do
    profile_dir = Rails.root.join("tmp", "profiles")
    Dir.glob(File.join(profile_dir, "*.json")).each do |file|
      File.delete(file) if File.mtime(file) < 7.days.ago
    end
  end
end
```

## Troubleshooting

### Vernier Not Available

If you see this error:

```
LoadError: Vernier gem is not loaded. Add `gem 'vernier', '~> 0.1'` to your Gemfile to enable profiling.
```

Make sure to:
1. Add `vernier` to your Gemfile
2. Run `bundle install`
3. Restart your application

### No Profile Files Generated

If profile files aren't being generated:

1. Verify your action has `use :vernier` enabled
2. Ensure profiling conditions are met
3. Check the output directory exists and is writable

### Performance Impact

Profiling adds overhead to your application:

- **Sampling overhead**: ~1-5% depending on sample rate
- **File I/O**: Profile files are written to disk
- **Memory usage**: Slight increase due to sampling

Use appropriate sampling rates and conditional profiling to minimize impact.

## Integration with Other Tools

### OpenTelemetry and Datadog Integration

Axn automatically creates OpenTelemetry spans for all actions when OpenTelemetry is available. To send traces to Datadog, configure OpenTelemetry with the Datadog exporter.

You can combine profiling with OpenTelemetry tracing:

```ruby
class MyAction
  include Axn

  # Profiling with custom options
  use :vernier, sample_rate: 0.1

  def call
    # Action logic
    # OpenTelemetry spans are automatically created
  end
end
```

## Resources

- [Vernier GitHub Repository](https://github.com/Shopify/vernier)
- [Firefox Profiler](https://profiler.firefox.com/)
- [Ruby Performance Optimization Guide](https://ruby-doc.org/core-3.2.1/doc/performance_rdoc.html)
- [Axn Configuration Reference](/reference/configuration)
