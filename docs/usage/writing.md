---
outline: deep
---

# How to _build_ an Action

The core boilerplate is pretty minimal:

```ruby
class Foo
  include Axn

  def call
    # ... do some stuff here?
  end
end
```

## Declare the interface

The first step is to determine what arguments you expect to be passed into `call`.  These are declared via the `expects` keyword.

If you want to expose any results to the caller, declare that via the `exposes` keyword.

Both of these optionally accept `type:`, `optional:`, `allow_nil:`, `allow_blank:`, and any other ActiveModel validation (see: [reference](/reference/class)).


```ruby
class Foo
  include Axn

  expects :name, type: String # [!code focus:2]
  expects :email, type: String, optional: true # [!code focus:2]
  exposes :meaning_of_life

  def call
    # ... do some stuff here?
  end
end
```

## Implement the action

Once the interface is defined, you're primarily focused on defining the `call` method.

To abort execution with a specific error message, call `fail!`. You can also provide exposures as keyword arguments.

To complete execution early with a success result, call `done!` with an optional success message and exposures as keyword arguments.

If you declare that your action `exposes` anything, you need to actually `expose` it — unless you're re-exposing a field you also `expects`, in which case axn auto-copies it for you (see below).

```ruby
class Foo
  include Axn

  expects :name, type: String
  exposes :meaning_of_life

  def call
    fail! "Douglas already knows the meaning" if name == "Doug" # [!code focus]

    msg = "Hello #{name}, the meaning of life is 42"
    expose meaning_of_life: msg # [!code focus]
  end
end
```

See [the reference doc](/reference/instance) for a few more handy helper methods (e.g. `#log`).

### Re-exposing an expected field (auto-copy)

When a field is declared with both `expects` and `exposes`, axn automatically copies it from the input into the result — no manual `expose` call needed. This works on **all outcome paths**: success, `done!`, `fail!`, and unhandled exceptions.

This is particularly useful when an action mutates an ActiveRecord object in-place (e.g. `user.valid?` populates `user.errors`) and the caller needs to inspect the object after a failure:

```ruby
class UpdateUser
  include Axn

  expects :user, model: true
  exposes :user               # auto-copied — no expose call needed

  def call
    user.assign_attributes(params)
    fail! unless user.save    # user.errors is available on result.user even on failure
  end
end

result = UpdateUser.call(user:, params:)
result.user.errors.full_messages  # populated on both ok? and !ok?
```

### Convenient failure with context

Both `fail!` and `done!` can accept keyword arguments to expose data before halting execution:

```ruby
class UserValidator
  include Axn

  expects :email
  exposes :error_code, :field

  def call
    if email.blank?
      fail!("Email is required", error_code: 422, field: "email")
    end

    # ... validation logic
  end
end
```

## Early completion with `done!`

The `done!` method allows you to complete an action early with a success result, bypassing the rest of the execution:

```ruby
class UserLookup
  include Axn

  expects :user_id
  exposes :user, :cached

  def call
    # Check cache first
    cached_user = Rails.cache.read("user:#{user_id}")
    if cached_user
      done!("User found in cache", user: cached_user, cached: true) # Early completion with exposures
    end

    # This won't execute if done! was called above
    user = User.find(user_id)
    expose user: user, cached: false
  end
end
```

### Important behavior notes

**Hook execution:**
- `done!` **skips** any `after` hooks (or `call` method if called from a `before` hook)
- `around` hooks **will complete** normally, allowing transactions and tracing to finish properly
- If you want code that executes on both normal AND early success, use an `on_success` callback instead of an `after` hook

**Transaction handling:**
- `done!` is implemented internally via an exception, so it **will roll back** manually applied `ActiveRecord::Base.transaction` blocks
- Use the [`use :transaction` strategy](/strategies/transaction) instead - transactions applied via this strategy will **NOT** be rolled back by `done!`
- This ensures database consistency while allowing early completion

**Validation:**
- Outbound validation (required `exposes`) still runs even with early completion
- If required fields are not provided, the action will fail despite the early completion

```ruby
class BadExample
  include Axn

  expects :user_id
  exposes :user  # Required field

  def call
    done!("Early completion") # This will FAIL - user not exposed
  end
end

BadExample.call(user_id: 123).ok? # => false
BadExample.call(user_id: 123).exception # => Axn::OutboundValidationError
```

## Customizing messages

The default `error` and `success` message strings ("Something went wrong" / "Action completed successfully", respectively) _are_ technically safe to show users, but you'll often want to set them to something more useful.

There are `success` and `error` declarations for that -- you can set strings (most common) or a callable (note for the error case, if you give it a callable that expects a single argument, the exception that was raised will be passed in).

For instance, configuring the action like this:

```ruby
class Foo
  include Axn

  expects :name, type: String
  exposes :meaning_of_life

  success { "Revealed to #{name}: #{result.meaning_of_life}" } # [!code focus:2]
  error { |e| "No secret of life for you: #{e.message}" }

  def call
    fail! "Douglas already knows the meaning" if name == "Doug"

    msg = "Hello #{name}, the meaning of life is 42"
    expose meaning_of_life: msg
  end
end
```

Would give us these outputs:

```ruby
Foo.call.error # => "No secret of life for you: Name can't be blank"
Foo.call(name: "Doug").error # => "Douglas already knows the meaning"
Foo.call(name: "Adams").success # => "Revealed the secret of life to Adams"
Foo.call(name: "Adams").meaning_of_life # => "Hello Adams, the meaning of life is 42"
```

### Advanced Error Message Configuration

You can also use conditional error messages with the `prefix:` keyword and combine them with the `from:` parameter for nested actions:

```ruby
class ValidationAction
  include Axn

  expects :input

  error if: ArgumentError, prefix: "Validation Error: " do |e|
    "Invalid input: #{e.message}"
  end

  error if: StandardError, prefix: "System Error: "

  def call
    raise ArgumentError, "input too short" if input.length < 3
    raise StandardError, "unexpected error" if input == "error"
  end
end

class ApiAction
  include Axn

  expects :data

  # Simply inherit child's error (prefix and handler are optional)
  error from: ValidationAction

  # Or combine prefix with from for consistent error formatting
  error from: ValidationAction, prefix: "API Error: " do |e|
    "Request validation failed: #{e.message}"
  end

  # Or use prefix only (falls back to exception message)
  error from: ValidationAction, prefix: "API Error: "

  # Match multiple child actions
  error from: [ValidationAction, AnotherAction]

  # Match any child action
  error from: true

  def call
    ValidationAction.call!(input: data)
  end
end
```

This configuration provides:
- Simple error message inheritance without requiring prefix or handler
- Consistent error message formatting with prefixes
- Automatic fallback to exception messages when no custom message is provided
- Proper error message inheritance from nested actions
- Support for matching multiple child actions or any child action

::: warning Message Ordering
**Important**: When using conditional messages, always define your static fallback messages **first** in your class, before any conditional messages. This ensures proper fallback behavior.

**Correct order:**
```ruby
class Foo
  include Axn

  # Static fallback messages first
  success "Default success message"
  error "Default error message"

  # Then conditional messages
  success "Special success", if: :special_condition?
  error "Special error", if: ArgumentError
end
```
:::

## Reclassifying exceptions as failures

Axn sorts every non-success outcome into one of two buckets:

- **failure** — from `fail!`. Expected and user-facing. Fires `on_failure`, sets `result.error`, and is **not** reported to the global handler (`Axn.config.on_exception`).
- **exception** — any other raised error. Unexpected. Fires `on_exception` and **is** reported globally (e.g. to Honeybadger).

Some exception classes are really expected failure modes, not bugs — `ActiveRecord::RecordInvalid` from a validation, say. `fails_on` moves the listed exception classes from the **exception** bucket into the **failure** bucket: a matching raised exception settles as a failed result (firing `on_failure`, skipping `on_exception` and the global report) while the original exception is preserved on `result.exception` and the usual message resolution still applies.

```ruby
class SubmitOrder
  include Axn

  fails_on ActiveRecord::RecordInvalid

  def call
    order.save!   # raises RecordInvalid on validation failure
  end
end

result = SubmitOrder.call(order:)
result.ok?              # => false
result.outcome.failure? # => true   (not .exception?)
result.exception        # => the original ActiveRecord::RecordInvalid
# Axn.config.on_exception was NOT called
```

`fails_on` rides the same muscle memory as `fail!` and `error` — pass a message positionally or as a block (which receives the exception), or omit it to fall back to the default/your own `error` declaration:

```ruby
fails_on ActiveRecord::RecordInvalid, "Unable to submit"
fails_on(ActiveRecord::RecordInvalid) { |e| e.record.errors.full_messages.to_sentence }
fails_on [ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique], "Couldn't save"
```

The message integrates with the standard message DSL (`prefix:`, ordering, etc.), so it composes with — and can be overridden by — your other `error` declarations.

::: tip Callbacks receive the original exception
Inside `on_failure` / `on_error`, the `exception` argument (and `result.exception`) is the **original** raised object — e.g. the `ActiveRecord::RecordInvalid` — not an `Axn::Failure`. So a handler can read `exception.record.errors` directly. You can branch on `exception.is_a?(Axn::Failure)` to distinguish an explicit `fail!` from a `fails_on` reclassification.
:::

::: tip
For the common "save an ActiveRecord model" case, reach for the [Model strategy](/strategies/model), which wires `fails_on ActiveRecord::RecordInvalid` (and the save/expose boilerplate) for you.
:::

## Lifecycle methods

In addition to `#call`, there are a few additional pieces to be aware of:



### Hooks

`before`, `after`, and `around` hooks are supported. They can receive a block directly, or the symbol name of a local method.

Note execution is halted whenever `fail!` is called, `done!` is called, or an exception is raised (so a `before` block failure won't execute `call` or `after`, while an `after` block failure will make `result.ok?` be false even though `call` completed successfully). The `done!` method specifically skips `after` hooks and any remaining `call` method execution, but allows `around` hooks to complete normally.

#### Around hooks

Around hooks wrap the entire action execution, including before and after hooks. They receive a block that represents the next step in the chain:

```ruby
class Foo
  include Axn

  around :with_timing
  around do |chain|
    log("outer around start")
    chain.call
    log("outer around end")
  end

  def call
    log("in call")
  end

  private

  def with_timing(chain)
    start = Time.current
    chain.call
    log("Took #{Time.current - start}s")
  end
end
```

#### Before/After example

For instance, given this configuration:

```ruby
class Foo
  include Axn

  before { log("before hook") } # [!code focus:2]
  after :log_after

  def call
    log("in call")
  end

  private

  def log_after
    log("after hook")
    raise "oh no something borked"
    log("after after hook raised")
  end
end
```

`Foo.call` would fail (because of the raise), but along the way would end up logging:

```text
before hook
in call
after hook
```

**Hook Ordering with Inheritance:**
- **Around hooks**: Parent wraps child (parent outside, child inside)
- **Before hooks**: Parent → Child (general setup first, then specific)
- **After hooks**: Child → Parent (specific cleanup first, then general)

This follows the natural pattern of setup (general → specific) and teardown (specific → general).

### Callbacks

A number of custom callback are available for you as well, if you want to take specific actions when a given Axn succeeds or fails. See the [Class Interface docs](/reference/class#callbacks) for details.

## Strategies

A number of [Strategies](/strategies/index), which are <abbr title="Don't Repeat Yourself">DRY</abbr>ed bits of commonly-used configuration, are available for your use as well.

::: info Optional Peer Libraries
Axn provides enhanced functionality when certain peer libraries are available:

- **Rails**: Automatic engine loading, autoloading for `app/actions`, and generators
- **Faraday**: Enables the [Client Strategy](/strategies/client) for HTTP API integrations
- **memo_wise**: Extends built-in `memo` helper to support methods with arguments (see [Memoization recipe](/recipes/memoization))

These are all optional—Axn works great without them, but they unlock additional features when present.
:::

## Advanced: Default call behavior

::: tip For Experienced Users
This section covers an advanced shortcut. If you're new to Axn, start by explicitly defining your `call` method.
:::

If you don't define a `call` method, Axn provides a default implementation that automatically exposes all declared exposures by calling methods with matching names. This allows you to simplify actions that only need to compute and expose values:

```ruby
class CertificatesByDestination
  include Axn
  exposes :certs_by_destination, type: Hash

  private

  def certs_by_destination
    # Your logic here - automatically exposed
    { "dest1" => "cert1", "dest2" => "cert2" }
  end
end
```

This is equivalent to:

```ruby
class CertificatesByDestination
  include Axn
  exposes :certs_by_destination, type: Hash

  def call
    expose certs_by_destination: certs_by_destination
  end

  private

  def certs_by_destination
    { "dest1" => "cert1", "dest2" => "cert2" }
  end
end
```

**Important notes:**
- The default `call` requires a method matching each declared exposure (unless a `default` is provided)
- If a method is missing and no default is provided, the action will fail with a helpful error message
- You can still override `call` to implement custom logic when needed
- If a method returns `nil` for an exposed-only field with no default, it's treated as missing (user-defined methods that legitimately return `nil` should use `expose` explicitly or provide a default)
