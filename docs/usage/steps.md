---
outline: deep
---

# Using Steps in Actions

The steps functionality allows you to compose complex actions by breaking them down into sequential, reusable steps. Each step can expect data from the parent context or previous steps, and expose data for subsequent steps.

## Basic Concepts

### What are Steps?

Steps are a way to organize action logic into smaller, focused pieces that:
- Execute in a defined order
- Can share data between each other
- Handle failures gracefully with error prefixing
- Can be reused across different actions

### How Steps Work

1. **Step Definition**: Define steps using the `step` class method
2. **Execution Order**: Steps execute sequentially in the order they're defined
3. **Data Flow**: Each step can expect and expose data
4. **Error Handling**: Step failures are caught and can trigger error handlers

## Defining Steps

### Using the `step` Method

The `step` method allows you to define steps inline with blocks:

```ruby
class UserRegistration
  include Axn
  expects :email, :password, :name
  exposes :user_id, :welcome_message

  step :validate_input, expects: [:email, :password, :name], exposes: [:validated_data] do
    # Validation logic
    fail! "Email is invalid" unless email.match?(/\A[^@\s]+@[^@\s]+\z/)
    fail! "Password too short" if password.length < 8
    fail! "Name is required" if name.blank?

    expose :validated_data, { email: email.downcase, password: password, name: name.strip }
  end

  step :create_user, expects: [:validated_data], exposes: [:user_id] do
    user = User.create!(validated_data)
    expose :user_id, user.id
  end

  step :send_welcome, expects: [:user_id, :validated_data], exposes: [:welcome_message] do
    WelcomeMailer.send_welcome(user_id, validated_data[:email]).deliver_now
    expose :welcome_message, "Welcome #{validated_data[:name]}!"
  end

  def call
    # Steps handle execution automatically
  end
end
```

### Using the `steps` Method

The `steps` method allows you to compose existing action classes:

```ruby
class ValidateInput
  include Axn
  expects :email, :password, :name
  exposes :validated_data

  def call
    fail! "Email is invalid" unless email.match?(/\A[^@\s]+@[^@\s]+\z/)
    fail! "Password too short" if password.length < 8
    fail! "Name is required" if name.blank?

    expose :validated_data, { email: email.downcase, password: password, name: name.strip }
  end
end

class CreateUser
  include Axn
  expects :validated_data
  exposes :user_id

  def call
    user = User.create!(validated_data)
    expose :user_id, user.id
  end
end

class SendWelcome
  include Axn
  expects :user_id, :validated_data
  exposes :welcome_message

  def call
    WelcomeMailer.send_welcome(user_id, validated_data[:email]).deliver_now
    expose :welcome_message, "Welcome #{validated_data[:name]}!"
  end
end

class UserRegistration
  include Axn
  expects :email, :password, :name
  exposes :user_id, :welcome_message

  # Use existing action classes as steps
  steps(ValidateInput, CreateUser, SendWelcome)
end
```

### Mixed Approach

You can combine both approaches:

```ruby
class UserRegistration
  include Axn
  expects :email, :password, :name
  exposes :user_id, :welcome_message

  # Use existing action for validation
  steps(ValidateInput)

  # Define custom step for user creation
  step :create_user, expects: [:validated_data], exposes: [:user_id] do
    user = User.create!(validated_data)
    expose :user_id, user.id
  end

  # Use existing action for welcome email
  steps(SendWelcome)
end
```

## Data Flow Between Steps

### Expecting Data

Steps can expect data from:
- **Parent context**: Data passed to the parent action
- **Previous steps**: Data exposed by earlier steps

```ruby
step :step1, expects: [:input], exposes: [:processed_data] do
  expose :processed_data, input.upcase
end

step :step2, expects: [:processed_data], exposes: [:final_result] do
  # This step can access both 'input' (from parent) and 'processed_data' (from step1)
  expose :final_result, "Result: #{processed_data}"
end
```

### Exposing Data

Steps expose data using the `expose` method:

```ruby
step :calculation, expects: [:base_value], exposes: [:doubled_value, :final_result] do
  doubled = base_value * 2
  expose :doubled_value, doubled
  expose :final_result, doubled + 10
end
```

### Using `expose_return_as`

For simple calculations, you can use `expose_return_as`:

```ruby
step :calculation, expects: [:input], expose_return_as: :result do
  input * 2 + 10  # Return value is automatically exposed as 'result'
end
```

## Error Handling

### Automatic Error Prefixing

When a step fails, error messages are automatically prefixed with the step name:

```ruby
step :validation, expects: [:input] do
  fail! "Input too short"
end

# If this step fails, the error message becomes: "validation step: Input too short"
```

### Step Failure Propagation

When a step fails:
1. The step's exception is caught
2. The parent action fails with the prefixed error message
3. The `on_exception` handlers are triggered appropriately

### Exception Handling

Steps can raise exceptions that will be caught and handled:

```ruby
step :risky_operation, expects: [:input] do
  raise StandardError, "Something went wrong with #{input}"
end

# The exception is caught and the error message becomes: "risky_operation step: Something went wrong with [input]"
```



## Best Practices

### 1. Keep Steps Focused

Each step should have a single responsibility:

```ruby
# ❌ Bad: Step does too many things
step :process_user, expects: [:user_data], exposes: [:user_id, :welcome_sent] do
  user = User.create!(user_data)
  WelcomeMailer.send_welcome(user.id).deliver_now
  expose :user_id, user.id
  expose :welcome_sent, true
end

# ✅ Good: Steps are focused
step :create_user, expects: [:user_data], exposes: [:user_id] do
  user = User.create!(user_data)
  expose :user_id, user.id
end

step :send_welcome, expects: [:user_id], exposes: [:welcome_sent] do
  WelcomeMailer.send_welcome(user_id).deliver_now
  expose :welcome_sent, true
end
```

### 2. Use Descriptive Step Names

Step names should clearly indicate what the step does:

```ruby
# ❌ Bad: Unclear names
step :step1, expects: [:input] do
  # ...
end

# ✅ Good: Descriptive names
step :validate_email_format, expects: [:input] do
  # ...
end
```

### 3. Handle Failures Gracefully

Use `fail!` for expected failures and raise exceptions for unexpected errors:

```ruby
step :validation, expects: [:input] do
  # Expected failure - use fail!
  fail! "Input too short" if input.length < 3

  # Unexpected error - raise exception
  raise StandardError, "Database connection failed" if database_unavailable?
end
```

### 4. Expose Only Necessary Data

Only expose data that subsequent steps actually need:

```ruby
# ❌ Bad: Exposing unnecessary data
step :validation, expects: [:input], exposes: [:input, :validated, :timestamp] do
  expose :input, input
  expose :validated, true
  expose :timestamp, Time.current
end

# ✅ Good: Only exposing what's needed
step :validation, expects: [:input], exposes: [:validated_input] do
  expose :validated_input, input.strip
end
```

## Common Use Cases

### API Request Processing

```ruby
class ProcessAPIRequest
  include Axn
  expects :request_data
  exposes :response_data

  step :authenticate, expects: [:request_data], exposes: [:authenticated_user] do
    # Authentication logic
    expose :authenticated_user, authenticate_user(request_data[:token])
  end

  step :authorize, expects: [:authenticated_user, :request_data], exposes: [:authorized] do
    # Authorization logic
    fail! "Access denied" unless authorized_user?(authenticated_user, request_data[:action])
    expose :authorized, true
  end

  step :process_request, expects: [:request_data, :authenticated_user], exposes: [:response_data] do
    # Process the actual request
    expose :response_data, process_user_request(request_data, authenticated_user)
  end
end
```



## Troubleshooting

### Common Issues

1. **Steps not executing**: Ensure the Steps module is properly included
2. **Data not flowing**: Check that step names match between `expects` and `exposes`
3. **Error messages unclear**: Verify step names are descriptive

### Debugging Tips

- Use descriptive step names for better error messages
- Check that data is properly exposed between steps
- Verify that step dependencies are correctly specified

## Summary

The steps functionality provides a powerful way to compose complex actions from smaller, focused pieces. By following the patterns and best practices outlined here, you can create maintainable, testable, and reusable action compositions.
