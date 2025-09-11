# Instance Methods

## `#expose`

Used to set a value on the Axn::Result. Remember you can only `expose` keys that you have declared in [the class-level interface](/reference/class).

* Accepts two positional arguments (the key and value to set, respectively): `expose :some_key, 123`
* Accepts a hash with one or more key/value pairs: `expose some_key: 123, another: 456`

Primarily used for its side effects, but it does return a Hash with the key/value pair(s) you exposed.


## `#fail!`

Called with a string, it immediately halts execution and sets `result.error` to the provided string. Can also accept keyword arguments that will be exposed before halting execution.

* First argument (optional) is a string error message
* Additional keyword arguments are exposed as data before halting

## `#done!`

Called with an optional string, it immediately halts execution and sets `result.success` to the provided string (or default success message if none provided). Can also accept keyword arguments that will be exposed before halting execution. Skips `after` hooks and remaining `call` method execution, but allows `around` hooks to complete normally.

* First argument (optional) is a string success message
* Additional keyword arguments are exposed as data before halting

**Important:** This method is implemented internally via an exception, so it will roll back manually applied `ActiveRecord::Base.transaction` blocks. Use the [`use :transaction` strategy](/strategies/transaction) instead for transaction-safe early completion.

## `#log`

Helper method to log (via the [configurable](/reference/configuration#logger) `Axn.config.logger`) the string you provide (prefixed with the Action's class name).

* First argument (required) is a string message to log
* Also accepts a `level:` keyword argument to change the log level (defaults to `info`)

Primarily used for its side effects; returns whatever the underlying `Axn.config.logger` instance returns but it does return a Hash with the key/value pair(s) you exposed.



