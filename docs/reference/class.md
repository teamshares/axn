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

In addition to the [standard ActiveModel validations](https://guides.rubyonrails.org/active_record_validations.html), we also support three additional custom validators:
* `type: Foo` - fails unless the provided value `.is_a?(Foo)`
  * Edge case: use `type: :boolean` to handle a boolean field (since ruby doesn't have a Boolean class to pass in directly)
  * Edge case: use `type: :uuid` to handle a confirming given string is a UUID (with or without `-` chars)
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

## `.messages`

The `messages` declaration allows you to customize the `error` and `success` messages on the returned result.

Accepts `error` and/or `success` keys.  Values can be a string (returned directly) or a callable (evaluated in the action's context, so can access instance methods and variables).  If `error` is provided with a callable that expects a positional argument, the exception that was raised will be passed in as that value.

In callables, you can access:
- **Input data**: Use field names directly (e.g., `name`)
- **Output data**: Use `result.field` pattern (e.g., `result.greeting`)
- **Instance methods and variables**: Direct access

```ruby
messages success: -> { "Hello #{name}, your greeting: #{result.greeting}" },
         error: ->(e) { "Bad news: #{e.message}" }
```

## `error_from` and `rescues`

While `.messages` sets the _default_ error/success messages and is more commonly used, there are times when you want specific error messages for specific failure cases.

`error_from` and `rescues` both register a matcher (exception class, exception class name (string), or callable) and a message to use if the matcher succeeds.  They act exactly the same, except if a matcher registered with `rescues` succeeds, the exception _will not_ trigger the configured exception handlers (global or specific to this class).

Callable matchers and messages follow the same data access patterns as other callables: input fields directly, output fields via `result.field`, instance variables, and methods.

```ruby
messages error: "bad"

# Note this will NOT trigger Action.config.on_exception
rescues ActiveRecord::InvalidRecord => "Invalid params provided"

# These WILL trigger error handler (callable matcher + message with data access)
error_from ArgumentError, ->(e) { "Argument error: #{e.message}" }
error_from -> { name == "bad" }, -> { "Bad input #{name}, result: #{result.status}" }
```

## Callbacks

In addition to the [global exception handler](/reference/configuration#on-exception), a number of custom callback are available for you as well, if you want to take specific actions when a given Axn succeeds or fails.

::: danger ALPHA
* The callbacks themselves are functional. Note the ordering _between_ callbacks is not well defined (currently a side effect of the order they're defined).
  * Ordering may change at any time so while in alpha DO NOT MAKE ASSUMPTIONS ABOUT THE ORDER OF CALLBACK EXECUTION!
:::


::: tip Callbacks vs Hooks
  * *Hooks* (`before`/`after`) are executed _as part of the `call`_ -- exceptions or `fail!`s here _will_ change a successful action call to a failure (i.e. `result.ok?` will be false)
  * *Callbacks* (defined below) are executed _after_ the `call` -- exceptions or `fail!`s here will _not_ change `result.ok?`
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
  include Action

  on_exception do |exception| # [!code focus:3]
    # e.g. trigger a slack error
  end
end
```

Note that by default the `on_exception` block will be applied to _any_ `StandardError` that is raised, but you can specify a matcher using the same logic as for [`error_from` and `rescues`](#error-for-and-rescues):

```ruby
class Foo
  include Action

  on_exception NoMethodError do |exception| # [!code focus]
    # e.g. trigger a slack error
  end

  on_exception ->(e) { e.is_a?(ZeroDivisionError) } do # [!code focus]
    # e.g. trigger a slack error
  end
end
```

If multiple `on_exception` handlers are provided, ALL that match the raised exception will be triggered in the order provided.

The _global_ handler will be triggered _after_ all class-specific handlers.
