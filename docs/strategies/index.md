# Strategies

Strategies in Axn are reusable modules that provide common functionality and configuration patterns for your actions. They allow you to DRY up your code by encapsulating frequently used behaviors into named, configurable modules.

## What are Strategies?

Strategies are Ruby modules that can be included into your actions to add specific functionality. They're designed to be:

- **Reusable**: Once defined, they can be used across multiple actions
- **Configurable**: Many strategies support configuration options
- **Composable**: You can use multiple strategies in a single action
- **Discoverable**: Built-in strategies are automatically loaded, and custom ones can be registered

## How to Use Strategies

### Basic Usage

To use a strategy in your action, call the `use` method with the strategy name:

```ruby
class CreateUser
  include Axn

  use :transaction

  expects :email, :name

  def call
    # This action will now run within a database transaction (including before/after hooks)
    user = User.create!(email: email, name: name)
    expose :user, user
  end
end
```

### Using Strategies with Configuration

Some strategies support configuration options. These strategies have a `setup` method that accepts configuration and returns a configured module.  As an _imaginary_ example:

```ruby
class ProcessPayment
  include Axn

  use :retry, max_attempts: 3, backoff: :exponential

  expects :amount, :card_token

  def call
    # This action will retry up to 3 times with exponential backoff
    result = PaymentProcessor.charge(amount, card_token)
    expose :transaction_id, result.id
  end
end
```

## Built-in Strategies

The list of built in strategies is available via `Axn::Strategies.built_in`.

## Registering Custom Strategies

### Simple Strategies

To create a custom strategy, define a module that extends `ActiveSupport::Concern`:

```ruby
module MyCustomStrategy
  extend ActiveSupport::Concern

  included do
    # Add your strategy behavior here
    # For example, add hooks, validations, or other functionality
    before { log("Custom strategy before hook") }
    after { log("Custom strategy after hook") }
  end
end
```

Then register it with the strategies system:

```ruby
Axn::Strategies.register(:my_custom, MyCustomStrategy)
```

Now you can use it in your actions:

```ruby
class MyAction
  include Axn

  use :my_custom

  def call
    # Your action implementation
  end
end
```

### Configurable Strategies

For strategies that need configuration, implement a `setup` method that returns a configured module:

```ruby
module RetryStrategy
  extend ActiveSupport::Concern

  def self.setup(max_attempts: 3, backoff: :linear, &block)
    Module.new do
      extend ActiveSupport::Concern

      included do
        around do |hooked|
          attempts = 0
          begin
            attempts += 1
            hooked.call
          rescue StandardError => e
            if attempts < max_attempts
              sleep(backoff_delay(attempts, backoff))
              retry
            else
              raise e
            end
          end
        end
      end

      private

      def backoff_delay(attempt, type)
        case type
        when :linear
          attempt * 0.1
        when :exponential
          0.1 * (2 ** (attempt - 1))
        else
          0.1
        end
      end
    end
  end
end

# Register the strategy
Axn::Strategies.register(:retry, RetryStrategy)
```

### Strategy Registration Best Practices

1. **Register early**: Register custom strategies during application initialization
2. **Use descriptive names**: Choose strategy names that clearly indicate their purpose
3. **Handle configuration validation**: Validate configuration options in your `setup` method
4. **Return proper modules**: Always return a module from the `setup` method
5. **Document your strategies**: Include clear documentation for how to use your custom strategies

### Example: Complete Custom Strategy

Here's a complete example of a custom strategy that adds performance monitoring (note Axn already logs elapsed time, this is just a toy example):

```ruby
module PerformanceMonitoringStrategy
  extend ActiveSupport::Concern

  def self.setup(threshold_ms: 1000, notify_slow: false, &block)
    Module.new do
      extend ActiveSupport::Concern

      included do
        around do |hooked|
          start_time = Time.current
          result = hooked.call
          duration = ((Time.current - start_time) * 1000).round(2)

          if duration > threshold_ms
            log("Action took #{duration}ms (threshold: #{threshold_ms}ms)", level: :warn)
            notify_slow_action(duration) if notify_slow
          else
            log("Action completed in #{duration}ms", level: :info)
          end

          result
        end
      end

      private

      def notify_slow_action(duration)
        # In a real implementation, this might send to a monitoring service
        # like New Relic, DataDog, or a custom alerting system
        Rails.logger.warn("SLOW ACTION ALERT: #{self.class.name} took #{duration}ms")
      end
    end
  end
end

# Register the strategy
Axn::Strategies.register(:performance_monitoring, PerformanceMonitoringStrategy)

# Use it in an action
class ExpensiveCalculation
  include Axn

  use :performance_monitoring, threshold_ms: 500, notify_slow: true

  expects :data

  def call
    # This action will be monitored for performance
    result = perform_expensive_calculation(data)
    expose :result, result
  end

  private

  def perform_expensive_calculation(data)
    # Simulate expensive operation
    sleep(0.1)
    data.map { |item| item * 2 }
  end
end
```

## Strategy Management

### Viewing Available Strategies

You can inspect all registered strategies:

```ruby
Axn::Strategies.all
# Returns a hash of strategy names to their modules
```

### Finding Specific Strategies

To find a specific strategy by name:

```ruby
Axn::Strategies.find(:transaction)
# Returns the strategy module for the transaction strategy

Axn::Strategies.find(:nonexistent)
# Raises Axn::StrategyNotFound: Strategy 'nonexistent' not found
```

The `find` method is useful when you need to programmatically access a strategy module or verify that a strategy exists before using it.

### Clearing Strategies

To reset strategies to only built-in ones (useful in tests):

```ruby
Axn::Strategies.clear!
```

### Strategy Errors

The following errors may be raised when using strategies:

- `Axn::StrategyNotFound`: When trying to use a strategy that hasn't been registered
- `Axn::DuplicateStrategyError`: When trying to register a strategy with a name that's already taken
- `ArgumentError`: When providing configuration to a strategy that doesn't support it

## Best Practices

1. **Keep strategies focused**: Each strategy should have a single, well-defined responsibility
2. **Use meaningful names**: Strategy names should clearly indicate their purpose
3. **Document configuration**: If your strategy accepts configuration, document all available options
4. **Test your strategies**: Write tests for your custom strategies to ensure they work correctly
5. **Consider composition**: Design strategies to work well together when used in combination


