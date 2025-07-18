---
outline: deep
---

# How to _build_ an Action

The core boilerplate is pretty minimal:

```ruby
class Foo
  include Action

  def call
    # ... do some stuff here?
  end
end
```

## Declare the interface

The first step is to determine what arguments you expect to be passed into `call`.  These are declared via the `expects` keyword.

If you want to expose any results to the caller, declare that via the `exposes` keyword.

Both of these optionally accept `type:`, `allow_nil:`, `allow_blank:`, and any other ActiveModel validation (see: [reference](/reference/class)).


```ruby
class Foo
  include Action

  expects :name, type: String # [!code focus:2]
  exposes :meaning_of_life

  def call
    # ... do some stuff here?
  end
end
```

## Implement the action

Once the interface is defined, you're primarily focused on defining the `call` method.

To abort execution with a specific error message, call `fail!`.

If you declare that your action `exposes` anything, you need to actually `expose` it.

```ruby
class Foo
  include Action

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

## Customizing messages

The default `error` and `success` message strings ("Something went wrong" / "Action completed successfully", respectively) _are_ technically safe to show users, but you'll often want to set them to something more useful.

There's a `messages` declaration for that -- you can set strings (most common) or a callable (note for the error case, if you give it a callable that expects a single argument, the exception that was raised will be passed in).

For instance, configuring the action like this:

```ruby
class Foo
  include Action

  expects :name, type: String
  exposes :meaning_of_life

  messages success: -> { "Revealed the secret of life to #{name}" }, # [!code focus:2]
           error: ->(e) { "No secret of life for you: #{e.message}" }

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

## Lifecycle methods

In addition to `#call`, there are a few additional pieces to be aware of:

<!-- ### `#rollback`
*** TODO: rollback actually only applies to rolling back *completed* steps of a multi-step Axn chain.  Do not document for now -- need to decide if adding a trigger-when-axn-itself-fails rollback path. ***

::: danger ALPHA
* ⚠️ `#rollback` is _expected_ to be added shortly, but is not yet functional!
:::

If you define a `#rollback` method, it'll be called (_before_ returning an `Action::Result` to the caller) whenever your action fails. -->

### Hooks

`before` and `after` hooks are supported. They can receive a block directly, or the symbol name of a local method.

Note execution is halted whenever `fail!` is called or an exception is raised (so a `before` block failure won't execute `call` or `after`, while an `after` block failure will make `result.ok?` be false even though `call` completed successfully).

For instance, given this configuration:

```ruby
class Foo
  include Action

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

### Callbacks

A number of custom callback are available for you as well, if you want to take specific actions when a given Axn succeeds or fails. See the [Class Interface docs](/reference/class#callbacks) for details.

## Strategies
A number of [Strategies](/strategies/index), which are <abbr title="Don't Repeat Yourself">DRY</abbr>ed bits of commonly-used configuration, are available for your use as well.
