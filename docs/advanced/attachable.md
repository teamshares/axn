---
outline: deep
---

# Attachable Actions

The attachable functionality is an advanced feature that allows you to attach actions directly to classes, providing convenient access patterns and reducing boilerplate. This is particularly useful for API clients to automatically wrap bits of logic in full Axn affordances, and for tacking on `enqueue_all` methods that can then be themselves run in a background job via enqueue_all_async (without requiring creating a separate worker class just to trigger the Axn).

::: danger ALPHA
This is in VERY EXPERIMENTAL use at Teamshares, but the API is still definitely in flux.
In particular we don't current support `inherit: self` (we're hoping to figure this out eventually), so for now in practice using this requires an awkward dance where you wrap up code to want to share in explicit modules. Note you can reference back to the mounting class via `__axn_attached_to__` (name likely to change, hence the underscores).
:::

## Overview

When you attach an action to a class, you get multiple ways to access it:

1. **Direct method calls** on the class (e.g., `SomeClass.foo`), which depend on how you told it to mount
3. **Namespace method calls** (e.g., `SomeClass::Axns.foo`) which always call the underlying axn directly (i.e. returning Axn::Result like a normal SomeAxn.call)

## Attachment Strategies

### `axn` Strategy

The `axn` strategy attaches an action that returns an `Axn::Result` object.

```ruby
class UserService
  include Axn

  axn(:create_user) do |email:, name:|
    user = User.create!(email: email, name: name)
    expose :user_id, user.id
  end
end

# Usage
result = UserService.create_user(email: "user@example.com", name: "John")
if result.ok?
  puts "User created with ID: #{result.user_id}"
else
  puts "Error: #{result.error}"
end
```

**Mounted methods:**
- `UserService.create_user(**kwargs)` - Returns `Axn::Result`
- `UserService.create_user!(**kwargs)` - Returns `Axn::Result` on success, raises on error
- `UserService.create_user_async(**kwargs)` - Executes asynchronously (requires async adapter configuration)

### `axn_method` Strategy

The `axn_method` strategy creates methods that automatically extract the return value from the `Axn::Result`. This is a useful shorthand when you have a snippet that needs to return one or zero values, when you don't want to manually check if the result was ok?.

Note we only attach a bang version to be clear that on failure it'll raise an exception.

```ruby
class Calculator
  include Axn

  axn_method(:add) do |a:, b:|
    a + b
  end

  axn_method(:multiply) do |a:, b:|
    a * b
  end
end

# Usage
sum = Calculator.add!(a: 5, b: 3)        # Returns 8 directly
product = Calculator.multiply!(a: 4, b: 6) # Returns 24 directly

# NOTE: you can still access the underlying Axn on the <wrapping_class>::Axns namespace
result = Calculator::Axns.add(a: 5, b: 3)   # Returns Axn::Result
```

**Mounted methods:**
- `Calculator.add!(**kwargs)` - Returns the extracted value directly, raises on error
- `Calculator::Axns.add(**kwargs)` - Returns `Axn::Result`

### `step` Strategy

The `step` strategy is designed for composing actions into sequential workflows. Steps are executed as part of a larger action flow.

```ruby
class OrderProcessor
  include Axn
  expects :order_data
  exposes :order_id, :confirmation_number

  step :validate_order, expects: [:order_data], exposes: [:validated_data] do
    fail! "Invalid order data" if order_data[:items].empty?
    expose :validated_data, order_data
  end

  step :create_order, expects: [:validated_data], exposes: [:order_id] do
    order = Order.create!(validated_data)
    expose :order_id, order.id
  end

  step :send_confirmation, expects: [:order_id], exposes: [:confirmation_number] do
    confirmation = ConfirmationMailer.send_order_confirmation(order_id).deliver_now
    expose :confirmation_number, confirmation.number
  end

  # call is automatically defined -- will execute steps in sequence
end

# Usage
result = OrderProcessor.call(order_data: { items: [...] })
if result.ok?
  puts "Order #{result.order_id} created with confirmation #{result.confirmation_number}"
end
```

**Available methods:**
- `OrderProcessor.call(**kwargs)` - Executes all steps in sequence

## Async Execution

Attachable actions automatically support async execution when an async adapter is configured. Each attached action gets a `_async` method that executes the action in the background.

### Configuring Async Adapters

```ruby
class DataProcessor
  include Axn

  # Configure async adapter (e.g., Sidekiq, ActiveJob)
  async :sidekiq

  axn(:process_data, async: :sidekiq) do |data:|
    # Processing logic
    expose :processed_count, data.count
  end
end

# Usage
# Synchronous execution
result = DataProcessor.process_data(data: large_dataset)

# Asynchronous execution
DataProcessor.process_data_async(data: large_dataset)
```

### Available Async Methods

When you attach an action using the `axn` strategy, you automatically get:
- `ClassName.action_name(**kwargs)` - Synchronous execution
- `ClassName.action_name!(**kwargs)` - Synchronous execution, raises on error
- `ClassName.action_name_async(**kwargs)` - Asynchronous execution

The `_async` methods require an async adapter to be configured. See the [Async Execution documentation](/reference/async) for more details on available adapters and configuration options.

## Advanced Options

### Inheritance Behavior

By default, attached actions inherit from their target class, allowing them to access target methods and share behavior. However, the `step` strategy defaults to inheriting from `Object` to avoid field conflicts with `expects` and `exposes` declarations.

#### Default Behavior

- **`axn` and `axn_method` strategies**: Inherit from target class by default
- **`step` strategy**: Inherits from `Object` by default to avoid field conflicts

```ruby
class UserService
  include Axn

  def shared_method
    "from target"
  end

  # Inherits from UserService - can access shared_method
  axn :create_user do
    expose :user_id, shared_method
  end

  # Inherits from Object - cannot access shared_method
  step :validate_user do
    expose :valid, true
  end
end
```

#### Controlling Inheritance

You can control inheritance behavior using the `_inherit_from_target` parameter:

```ruby
class UserService
  include Axn

  def shared_method
    "from target"
  end

  # Force step to inherit from target
  step :validate_user, _inherit_from_target: true do
    expose :valid, shared_method  # Can now access target methods
  end

  # Force axn to inherit from Object
  axn :standalone_action, _inherit_from_target: false do
    expose :result, "standalone"  # Cannot access target methods
  end
end
```

::: danger Experimental Feature
The `_inherit_from_target` parameter is experimental and likely to change in future versions. This is why the parameter name is underscore-prefixed. Use with caution and be prepared to update your code when this feature stabilizes.
:::

### Error Prefixing for Steps

Steps automatically prefix error messages with the step name:

```ruby
step :validation, expects: [:input] do
  fail! "Input is invalid"
end

# If this step fails, the error message becomes: "validation: Input is invalid"
```

You can customize the error prefix:

```ruby
step :validation, expects: [:input], error_prefix: "Custom: " do
  fail! "Input is invalid"
end

# Error message becomes: "Custom: Input is invalid"
```

## Method Naming and Validation

### Valid Method Names

Method names must be convertible to valid Ruby constant names:

```ruby
# ✅ Valid names
axn(:create_user)           # Creates CreateUser constant
axn(:process_payment)       # Creates ProcessPayment constant
axn(:send-email)            # Creates SendEmail constant (parameterized)
axn(:step_1)                # Creates Step1 constant

# ❌ Invalid names
axn(:create_user!)          # Cannot contain method suffixes (!?=)
axn(:123invalid)            # Cannot start with number
```

### Special Character Handling

The system automatically handles special characters using `parameterize`:

```ruby
axn(:send-email)     # Becomes SendEmail constant
axn(:step 1)         # Becomes Step1 constant
axn(:user@domain)    # Becomes UserDomain constant
```

## Best Practices

### 1. Choose the Right Strategy

- **Use `axn`** when you need full `Axn::Result` objects and error handling
- **Use `axn_method`** when you want direct return values for simple operations
- **Use `step`** when composing complex workflows with multiple sequential operations

### 2. Keep Actions Focused

```ruby
# ✅ Good: Focused action
axn(:send_welcome_email) do |user_id:|
  WelcomeMailer.send_welcome(user_id).deliver_now
end

# ❌ Bad: Too many responsibilities - prefer a standalone class
axn(:process_user) do |user_data:|
  user = User.create!(user_data)
  WelcomeMailer.send_welcome(user.id).deliver_now
  Analytics.track_user_signup(user.id)
  # ... more logic
end
```

### 3. Use Descriptive Names

```ruby
# ✅ Good: Clear intent
axn(:validate_email_format)
axn_method(:calculate_tax)
step(:send_confirmation_email)

# ❌ Bad: Unclear purpose
axn(:process)
axn_method(:do_thing)
step(:step1)
```



## Common Patterns

### Service Objects

```ruby
class UserService
  include Axn

  axn(:create) do |email:, name:|
    user = User.create!(email: email, name: name)
    expose :user_id, user.id
  end

  axn_method(:find_by_email) do |email:|
    User.find_by(email: email)
  end
end

# Usage
result = UserService.create(email: "user@example.com", name: "John")
user = UserService.find_by_email!(email: "user@example.com")
```


### Workflow Composition

```ruby
class OrderWorkflow
  include Axn
  expects :order_data
  exposes :order_id, :confirmation_number

  step :validate, expects: [:order_data], exposes: [:validated_data] do
    # Validation logic
    expose :validated_data, order_data
  end

  step :create_order, expects: [:validated_data], exposes: [:order_id] do
    order = Order.create!(validated_data)
    expose :order_id, order.id
  end

  step :send_confirmation, expects: [:order_id], exposes: [:confirmation_number] do
    # Send confirmation logic
    expose :confirmation_number, "CONF-123"
  end

  def call
    # Steps execute automatically
  end
end
```
