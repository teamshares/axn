# Instance Methods

## `#expose`

Used to set a value on the Action::Result. Remember you can only `expose` keys that you have declared in [the class-level interface](/reference/class).

* Accepts two positional arguments (the key and value to set, respectively): `expose :some_key, 123`
* Accepts a hash with one or more key/value pairs: `expose some_key: 123, another: 456`

Primarily used for its side effects, but it does return a Hash with the key/value pair(s) you exposed.


## `#fail!`

Called with a string, it immediately halts execution (including triggering any [rollback handler](/reference/class#rollback) you have defined) and sets `result.error` to the provided string.

## `#log`

Helper method to log (via the [configurable](/reference/configuration#logger) `Action.config.logger`) the string you provide (prefixed with the Action's class name).

* First argument (required) is a string message to log
* Also accepts a `level:` keyword argument to change the log level (defaults to `info`)

Primarily used for its side effects; returns whatever the underlying `Action.config.logger` instance returns but it does return a Hash with the key/value pair(s) you exposed.

## `#try`

Accepts a block.  Any exceptions raised within that block will be swallowed, but _they will NOT fail the action_!

A few details:
* An explicit `fail!` call _will_ still fail the action
* Any exceptions swallowed _will_ still be reported via the `on_exception` handler

This is primarily useful in an after block, e.g. trigger notifications after an action has been taken.  If the notification fails to send you DO want to log the failure somewhere to investigate, but since the core action has already been taken often you do _not_ want to fail and roll back.

Example:

```ruby
class Foo
  include Action

  after do
    try { send_slack_notifications } # [!code focus]
  end

  def call = ...

  private

  def send_slack_notifications = ...
end
```

## `#hoist_errors`

Useful when calling one Action from within another.  By default the nested action call will return an Action::Result, but it's up to you to check if the result is `ok?` and to handle potential failure modes... and in practice this is easy to miss.

By wrapping your nested call in `hoist_errors`, it will _automatically_ fail the parent action if the nested call fails.

Accepts a `prefix` keyword argument -- when set, prefixes the `error` message from any failures in the block (useful to return different error messages for each if you're calling multiple sub-actions in a single service).

NOTE: expects a single action call in the block -- if there are multiple calls, only the last one will be checked for `ok?` (although anything _raised_ in the block will still be handled).

::: tip Versus `call!`
* If you just want to make sure your action fails if the subaction fails: call subaction via `call!` (any failures will raise, which will fail the parent).
  * Note this passes _child_ exception into _parent_ `messages :error` parsing.
* If you want _the child's_ `result.error` to become the _parent's_ `result.error` on failure, use `hoist_errors` + `call`
:::

### Example

```ruby
class SubAction
  include Action

  def call
    fail! "bad news"
  end
end

class MainAction
  include Action

  def call
    SubAction.call
  end
end
```

_Without_ `hoist_errors`, `MainAction.call` returns an `ok?` result, even though `SubAction.call` always fails, because we haven't explicitly handled the nested call.

By adding `hoist_errors`, though:

```ruby
class MainAction
  include Action

  def call
    hoist_errors(prefix: "From subaction:") do
      SubAction.call
    end
  end
end
```

`MainAction.call` now returns a _failed_ result, and `result.error` is "From subaction: bad news".
