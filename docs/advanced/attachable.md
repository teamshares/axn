---
outline: deep
---

# Attachable Actions

The attachable functionality is an advanced feature that allows you to attach actions directly to classes, providing convenient access patterns and reducing boilerplate. This is particularly useful for service objects, background processors, and other classes that need to execute specific actions as part of their core functionality.

## Overview

When you attach an action to a class, you get multiple ways to access it:

1. **Direct method calls** on the class (e.g., `SomeClass.foo`), which depend on how you told it to mount
3. **Namespace method calls** (e.g., `SomeClass::AttachedAxns.foo`) which always call the underlying axn directly (i.e. returning Axn::Result like a normal SomeAxn.call)

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
- `UserService.create_user!(**kwargs)` - Returns `Axn::Result`, raises on error
- `UserService.create_user_async(**kwargs)` - Executes asynchronously

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

# You can still access the full result if needed
result = Calculator.AttachedAxns::add(a: 5, b: 3)   # Returns Axn::Result
```

**Mounted methods:**
- `Calculator.add!(**kwargs)` - Returns the extracted value directly, raises on error
- `Calculator::AttachedAxns.add(**kwargs)` - Returns `Axn::Result`

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

## Advanced Options

### Custom Superclass

You can specify a custom superclass for attached actions using the `superclass` option:

```ruby
class BaseService
  include Axn

  # Inherit from Object instead of the default proxy superclass
  axn(:utility_method, superclass: Object) do
    def call
      "This action inherits from Object"
    end
  end
end
```

This is useful when you want the attached action to inherit from a specific base class rather than the default proxy superclass.

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
axn(:send_welcome_email) do
  expects :user_id
  def call
    WelcomeMailer.send_welcome(user_id).deliver_now
  end
end

# ❌ Bad: Too many responsibilities - prefer a standalone class
axn(:process_user) do
  expects :user_data
  def call
    user = User.create!(user_data)
    WelcomeMailer.send_welcome(user.id).deliver_now
    Analytics.track_user_signup(user.id)
    # ... more logic
  end
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

### 4. Handle Errors Appropriately

```ruby
# For expected failures, use fail!
axn(:validate_user) do
  expects :email
  def call
    fail! "Email is required" if email.blank?
    fail! "Invalid email format" unless email.match?(/\A[^@\s]+@[^@\s]+\z/)
  end
end

# For unexpected errors, let them bubble up
axn(:external_api_call) do
  expects :data
  def call
    # This will be caught and handled by the error system
    ExternalAPI.post(data)
  end
end
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

### Background Job Processing

```ruby
class DataProcessor
  include Axn

  axn(:process_batch) do |batch_id:, data:|
    processed = 0
    errors = []

    data.each do |item|
      begin
        process_item(item)
        processed += 1
      rescue => e
        errors << e.message
      end
    end

    expose :processed_count, processed
    expose :errors, errors
  end

  axn_method(:queue_processing) do |batch_id:|
    ProcessDataJob.perform_later(batch_id)
  end
end

# Usage
result = DataProcessor.process_batch(batch_id: "123", data: large_dataset)
job_id = DataProcessor.queue_processing!(batch_id: "123")
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
