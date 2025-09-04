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



