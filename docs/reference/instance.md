# Instance Methods

## `#expose`

Used to set a value on the Action::Result. Remember you can only `expose` keys that you have declared in [the class-level interface](/reference/class).

* Accepts two positional arguments (the key and value to set, respectively): `expose :some_key, 123`
* Accepts a hash with one or more key/value pairs: `expose some_key: 123, another: 456`

Primarily used for its side effects, but it does return a Hash with the key/value pair(s) you exposed.


## `#fail!`

Called with a string, it immediately halts execution and sets `result.error` to the provided string.

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

This is primarily useful in an after block, e.g. trigger notifications after an action has been taken.  If the notification fails to send you DO want to log the failure somewhere to investigate, but since the core action has already been taken often you do _not_ want to fail.

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


