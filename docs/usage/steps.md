---
outline: deep
---

# Using Steps in Actions

Steps let you compose a complex action by **chaining** smaller actions together. The steps share one accumulating context: each step is invoked with everything available so far (the parent's inputs plus whatever earlier steps exposed), and whatever it exposes is merged back in for the steps that follow.

## Basic Concepts

### What are Steps?

Steps are a way to organize action logic into smaller, focused pieces that:
- Execute sequentially, in the order declared
- Chain through a **shared, accumulating context** — a later step sees everything earlier steps exposed
- Are reusable: any existing Axn can be mounted as a step
- Propagate failures and exceptions to the parent with the right semantics (see [Error Handling](#error-handling))

### The shared context (and collisions)

The context is a shared blackboard, not isolated per-step state:

- A step receives the **full** accumulated context, regardless of what it declares via `expects` (its `expects` only controls what it reads and validates).
- A step's exposures are merged into the parent's context, visible to every later step.
- If two steps expose the **same** key, the later step **overwrites** the earlier value — silently. This is intentional (it's how chaining transforms a value through the pipeline), but name your exposures deliberately.

### Defining the orchestrator

Declaring steps generates the action's `#call` — it *is* the orchestrator that runs the steps. So a steps-using class **must not define its own `#call`**; doing so raises an `ArgumentError` at load time. Use `before`/`after` hooks for setup or teardown around the steps.

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
end
```

> Note there is no `def call` — declaring steps generates it. Adding your own would raise.

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
  steps(ValidateInput, CreateUser, SendWelcome) # [!code focus]
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

# If this step fails, the error message becomes: "validation: Input too short"
```

### Failure vs. exception propagation

A step propagates its **outcome category** to the parent — it does not flatten everything into a generic failure. This preserves Axn's distinction between a deliberate failure and an unexpected bug:

**A step that calls `fail!` (a deliberate, expected failure):**
- The parent settles as a **failure**: its `on_failure` and `on_error` callbacks fire (`on_exception` does not).
- The parent's `error` is the step's message, prefixed: `"#{step_name}: #{step_error}"` (and cascaded under the parent's base `error` if it declares one).
- Nothing is reported to the global `on_exception` handler — a `fail!` is not a bug.

**A step that raises an unexpected exception (a bug):**
- The original exception is re-raised, so the parent settles as an **exception**: its `on_exception` and `on_error` callbacks fire (`on_failure` does *not*).
- The global `on_exception` handler fires **exactly once**, at the step (with the step's context). It is not reported again as it propagates.
- The parent's `error` is its declared base `error` (or `"Something went wrong"`) — exception internals are not surfaced into the caller-facing message, so the step-name prefix is **not** applied on this path. The full exception, including which step raised it, goes to the report.

In short: `on_error` is the catch-all at every level; `on_failure` means a deliberate `fail!`; `on_exception` means a real bug bubbled through.

```ruby
step :validate do
  fail! "Input too short"          # → parent FAILS with "validate: Input too short"; no report
end

step :risky_operation do
  raise SomeClient::Error, "..."   # → parent settles as an EXCEPTION; reported once at the step
end
```

### Rollback

There is no built-in rollback DSL. Because a failed/erroring step settles the parent as not-ok, wrap the orchestrator (or the relevant steps) in a database transaction to get all-or-nothing behavior — Axn defers `on_success` until the enclosing transaction commits, so committed side effects only fire if the whole chain succeeds.


## Conditional Steps

Run a step only when a condition holds, using `if:` and/or `unless:`:

```ruby
step :charge_card,  ChargeCard,  if:     -> { paid_plan }
step :send_invoice, SendInvoice, unless: :free_tier?
step :provision,    Provision,   if: :ready?, unless: :dry_run?   # both must pass
```

- A condition is a **Proc** (evaluated on the parent instance) or a **Symbol** naming a parent method — the same forms hooks accept.
- `if:` and `unless:` may be combined; the step runs only if `if:` is truthy **and** `unless:` is falsey.
- A skipped step simply does not run: it exposes nothing and cannot fail. Later steps still run.

Conditions are evaluated on the parent, so they read data the same way the rest of the action does:

- **Inputs** — via the `expects` reader (`-> { tier == "paid" }`) or `inputs` (`-> { inputs[:tier] == "paid" }`).
- **A prior step's output** — via `result.<field>` (`-> { result.flag }`), exactly as in `success`/`error`/`sensitive:` procs. The parent must declare the field in `exposes`, and the earlier step's value is live in the context by the time the next step's condition runs.

```ruby
exposes :eligible, allow_blank: true
step :check,   CheckEligibility            # exposes :eligible
step :enroll,  Enroll, if: -> { result.eligible }
```

A bare reference to an undeclared name (e.g. `-> { flag }` with no `exposes :flag`) raises `NameError` — `exposes` does not create bare instance readers; use `result.flag`.

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
