---
outline: deep
---

# Class Methods

## `.expects` and `.exposes`

Actions have a _declarative interface_, whereby you explicitly declare both inbound and outbound arguments.  Specifically, variables you expect to receive are specified via `expects`, and variables you intend to expose are specified via `exposes`.

Both `expects` and `exposes` support the same core options:

| Option | Example (same for `exposes`) | Meaning |
| -- | -- | -- |
| `sensitive` | `expects :password, sensitive: true` | Filters the field's value when logging, reporting errors, or calling `inspect`
| `default` | `expects :foo, default: 123` | If `foo` isn't explicitly set, it'll default to this value
| `allow_nil` | `expects :foo, allow_nil: true` | Don't fail if the value is `nil`
| `allow_blank` | `expects :foo, allow_blank: true` | Don't fail if the value is blank
| `type` | `expects :foo, type: String` | Custom type validation -- fail unless `name.is_a?(String)`
| anything else | `expects :foo, inclusion: { in: [:apple, :peach] }` | Any other arguments will be processed [as ActiveModel validations](https://guides.rubyonrails.org/active_record_validations.html) (i.e. as if passed to `validates :foo, <...>` on an ActiveRecord model)


### Validation details

::: warning
While we _support_ complex interface validations, in practice you usually just want a `type`, if anything.  Remember this is your validation about how the action is called, _not_ pretty user-facing errors (there's [a different pattern for that](/recipes/validating-user-input)).
:::

In addition to the [standard ActiveModel validations](https://guides.rubyonrails.org/active_record_validations.html), we also support four additional custom validators:
* `type: Foo` - fails unless the provided value `.is_a?(Foo)`
  * Edge case: use `type: :boolean` to handle a boolean field (since ruby doesn't have a Boolean class to pass in directly)
  * Edge case: use `type: :uuid` to handle a confirming given string is a UUID (with or without `-` chars)
  * Edge case: use `type: :params` to accept either a Hash or ActionController::Parameters (Rails-compatible)
* `validate: [callable]` - Support custom validations (fails if any string is returned OR if it raises an exception)
  * Example:
    ```ruby
    expects :foo, validate: ->(value) { "must be pretty big" unless value > 10 }
    ```
* `model: true` (or `model: TheModelClass`) - allows auto-hydrating a record when only given its ID
  * Example:
    ```ruby
    expects :user_id, model: true
    ```
    This line will add expectations that:
      * `user_id` is provided
      * `User.find(user_id)` returns a record

    And, when used on `expects`, will create two reader methods for you:
      * `user_id` (normal), _and_
      * `user` (for the auto-found record)

    ::: info NOTES
    * The field name must end in `_id`
    * This was designed for ActiveRecord models, but will work on any class that returns an instance from `find_by(id: <the provided ID>)`
    :::

### Details specific to `.exposes`

Remember that you'll need [a corresponding `expose` call](/reference/instance#expose) for every variable you declare via `exposes`.


### Details specific to `.expects`

#### Nested/Subfield expectations

`expects` is for defining the inbound interface. Usually it's enough to declare the top-level fields you receive, but sometimes you want to make expectations about the shape of that data, and/or to define easy accessor methods for deeply nested fields. `expects` supports the `on` option for this (all the normal attributes can be applied as well, _except default, preprocess, and sensitive_):

```ruby
class Foo
  expects :event
  expects :data, type: Hash, on: :event  # [!code focus:2]
  expects :some, :random, :fields, on: :data

  def call
    puts "THe event.data.random field's value is: #{random}"
  end
end
```

#### `preprocess`
`expects` also supports a `preprocess` option that, if set to a callable, will be executed _before_ applying any validations.  This can be useful for type coercion, e.g.:

```ruby
expects :date, type: Date, preprocess: ->(d) { d.is_a?(Date) ? d : Date.parse(d) }
```

will succeed if given _either_ an actual Date object _or_ a string that Date.parse can convert into one.  If the preprocess callable raises an exception, that'll be swallowed and the action failed.

## `.success` and `.error`

The `success` and `error` declarations allow you to customize the `error` and `success` messages on the returned result.

Both methods accept a string (returned directly), a symbol (resolved as a local instance method on the action), or a block (evaluated in the action's context, so can access instance methods and variables).

When an exception is available (e.g., during `error`), handlers can receive it in either of two equivalent ways:
- Keyword form: accept `exception:` and it will be passed as a keyword
- Positional form: if the handler accepts a single positional argument, it will be passed positionally

This applies to both blocks and symbol-backed instance methods. Choose the style that best fits your codebase (clarity vs concision).

In callables and symbol-backed methods, you can access:
- **Input data**: Use field names directly (e.g., `name`)
- **Output data**: Use `result.field` pattern (e.g., `result.greeting`)
- **Instance methods and variables**: Direct access

```ruby
success { "Hello #{name}, your greeting: #{result.greeting}" }
error { |e| "Bad news: #{e.message}" }
error { |exception:| "Bad news: #{exception.message}" }

# Using symbol method names
success :build_success_message
error :build_error_message

def build_success_message
  "Hello #{name}, your greeting: #{result.greeting}"
end

def build_error_message(e)
  "Bad news: #{e.message}"
end

def build_error_message(exception:)
  "Bad news: #{exception.message}"
end
```

::: warning Message Ordering
**Important**: Static success/error messages (those without conditions) should be defined **first** in your action class. If you define conditional messages before static ones, the conditional messages will never be reached because the static message will always match first.

**Correct order:**
```ruby
class MyAction
  include Axn

  # Define static fallback first
  success "Default success message"
  error "Default error message"

  # Then define conditional messages
  success "Special success", if: :special_condition?
  error "Special error", if: ArgumentError
end
```

**Incorrect order (conditional messages will be shadowed):**
```ruby
class MyAction
  include Axn

  # These conditional messages will never be reached!
  success "Special success", if: :special_condition?
  error "Special error", if: ArgumentError

  # Static messages defined last will always match first
  success "Default success message"
  error "Default error message"
end
```
:::

## Conditional messages

While `.error` and `.success` set the default messages, you can register conditional messages using an optional `if:` or `unless:` matcher. The matcher can be:

- an exception class (e.g., `ArgumentError`)
- a class name string (e.g., `"Axn::InboundValidationError"`)
- a symbol referencing a local instance method predicate (arity 0 or 1, or keyword `exception:`), e.g. `:bad_input?`
- a callable (arity 0 or 1, or keyword `exception:`)

Symbols are resolved as methods on the action instance. If the method accepts `exception:` it will be passed as a keyword; otherwise, if it accepts one positional argument, the raised exception is passed positionally; otherwise it is called with no arguments. If the action does not respond to the symbol, we fall back to constant lookup (e.g., `if: :ArgumentError` behaves like `if: ArgumentError`). Symbols are also supported for the message itself (e.g., `success :method_name`), resolved via the same rules.

```ruby
error "bad"

# Custom message with exception class matcher
error "Invalid params provided", if: ActiveRecord::InvalidRecord

# Custom message with callable matcher and message
error(if: ArgumentError) { |e| "Argument error: #{e.message}" }
error(if: -> { name == "bad" }) { "Bad input #{name}, result: #{result.status}" }

# Custom message with prefix (falls back to exception message when no block/message provided)
error(if: ArgumentError, prefix: "Foo: ") { "bar" }  # Results in "Foo: bar"
error(if: StandardError, prefix: "Baz: ")            # Results in "Baz: [exception message]"

# Custom message with symbol predicate (arity 0)
error "Transient error, please retry", if: :transient_error?

def transient_error?
  # local decision based on inputs/outputs
  name == "temporary"
end

# Symbol predicate (arity 1), receives the exception
error(if: :argument_error?) { |e| "Bad argument: #{e.message}" }

def argument_error?(e)
  e.is_a?(ArgumentError)
end

# Symbol predicate (keyword), receives the exception via keyword
error(if: :argument_error_kw?) { |exception:| "Bad argument: #{exception.message}" }

def argument_error_kw?(exception:)
  exception.is_a?(ArgumentError)
end

# Lambda predicate with keyword
error "AE", if: ->(exception:) { exception.is_a?(ArgumentError) }

# Using unless: for inverse logic
error "Custom error", unless: :should_skip?

def should_skip?
  # local decision based on inputs/outputs
  name == "temporary"
end

::: warning
You cannot use both `if:` and `unless:` for the same message - this will raise an `ArgumentError`.
:::

## Error message inheritance with `from:`

The `from:` parameter allows you to customize error messages when an action calls another action that fails. This is particularly useful for adding context or prefixing error messages from child actions.

When using `from:`, the error handler receives the exception from the child action, and you can access the child's error message via `e.message` (which contains the `result.error` from the child action).

```ruby
class InnerAction
  include Axn

  error "Something went wrong in the inner action"

  def call
    raise StandardError, "inner action failed"
  end
end

class OuterAction
  include Axn

  # Customize error messages from InnerAction
  error from: InnerAction do |e|
    "Outer action failed: #{e.message}"
  end

  def call
    InnerAction.call!
  end
end
```

In this example:
- When `InnerAction` fails, `OuterAction` will catch the exception
- The `e.message` contains the error message from `InnerAction`'s result
- The final error message will be "Outer action failed: Something went wrong in the inner action"

This pattern is especially useful for:
- Adding context to error messages from sub-actions
- Implementing consistent error message formatting across action hierarchies
- Providing user-friendly error messages that include details from underlying failures

### Combining `from:` with `prefix:`

You can also combine the `from:` parameter with the `prefix:` keyword to create consistent error message formatting:

```ruby
class OuterAction
  include Axn

  # Add prefix to error messages from InnerAction
  error from: InnerAction, prefix: "API Error: " do |e|
    "Request failed: #{e.message}"
  end

  # Or use prefix only (falls back to exception message)
  error from: InnerAction, prefix: "API Error: "

  def call
    InnerAction.call!
  end
end
```

This results in:
- With custom message: "API Error: Request failed: Something went wrong in the inner action"
- With prefix only: "API Error: Something went wrong in the inner action"

### Message ordering and inheritance

Messages are evaluated in **last-defined-first** order, meaning the most recently defined message that matches its conditions will be used. This applies to both success and error messages:

```ruby
class ParentAction
  include Axn

  success "Parent success message"
  error "Parent error message"
end

class ChildAction < ParentAction
  success "Child success message"  # This will be used when action succeeds
  error "Child error message"      # This will be used when action fails
end
```

Within a single class, later definitions override earlier ones:

```ruby
class MyAction
  include Axn

  success "First success message"           # Ignored
  success "Second success message"          # Ignored
  success "Final success message"           # This will be used

  error "First error message"               # Ignored
  error "Second error message"              # Ignored
  error "Final error message"               # This will be used
end
```

::: tip Message Evaluation Order
The system evaluates handlers in the order they were defined until it finds one that matches and doesn't raise an exception. If a handler raises an exception, it falls back to the next matching handler, then to static messages, and finally to the default message.

**Key point**: Static messages (without conditions) are evaluated **first** in the order they were defined. This means you should define your static fallback messages at the top of your class, before any conditional messages, to ensure proper fallback behavior.
:::

## Callbacks

In addition to the [global exception handler](/reference/configuration#on-exception), a number of custom callback are available for you as well, if you want to take specific actions when a given Axn succeeds or fails.

::: tip Callback Ordering
* Callbacks are executed in **last-defined-first** order, similar to messages
* Child class callbacks execute before parent class callbacks
* Multiple matching callbacks of the same type will *all* execute
:::


::: tip Callbacks vs Hooks
  * *Hooks* (`before`/`after`) are executed _as part of the `call`_ -- exceptions or `fail!`s here _will_ change a successful action call to a failure (i.e. `result.ok?` will be false)
  * *Callbacks* (defined below) are executed _after_ the `call` -- exceptions or `fail!`s here will _not_ change `result.ok?`
:::


**Note:** Symbol method handlers for all callback types follow the same argument pattern as [message handlers](#conditional-messages):
- If the method accepts `exception:` as a keyword, the exception is passed as a keyword
- If the method accepts one positional argument, the exception is passed positionally
- Otherwise, the method is called with no arguments

::: warning
You cannot use both `if:` and `unless:` for the same callback - this will raise an `ArgumentError`.
:::

### `on_success`

This is triggered after the Axn completes, if it was successful.  Difference from `after`: if the given block raises an error, this WILL be reported to the global exception handler, but will NOT change `ok?` to false.

### `on_error`

Triggered on ANY error (explicit `fail!` or uncaught exception). Optional filter argument works the same as `on_exception` (documented below).

### `on_failure`

Triggered ONLY on explicit `fail!` (i.e. _not_ by an uncaught exception). Optional filter argument works the same as `on_exception` (documented below).

### `on_exception`

Much like the [globally-configured on_exception hook](/reference/configuration#on-exception), you can also specify exception handlers for a _specific_ Axn class:

```ruby
class Foo
  include Axn

  on_exception do |exception| # [!code focus:3]
    # e.g. trigger a slack error
  end
end
```

Note that by default the `on_exception` block will be applied to _any_ `StandardError` that is raised, but you can specify a matcher using the same logic as for conditional messages (`if:` or `unless:`):

```ruby
class Foo
  include Axn

  on_exception(if: NoMethodError) do |exception| # [!code focus]
    # e.g. trigger a slack error
  end

on_exception(unless: :transient_error?) do |exception| # [!code focus]
    # e.g. trigger a slack error for non-transient errors
  end

def transient_error?
  # local decision based on inputs/outputs
  name == "temporary"
end

  on_exception(if: ->(e) { e.is_a?(ZeroDivisionError) }) do # [!code focus]
    # e.g. trigger a slack error
  end
end
```


If multiple `on_exception` handlers are provided, ALL that match the raised exception will be triggered in the order provided.

The _global_ handler will be triggered _after_ all class-specific handlers.

