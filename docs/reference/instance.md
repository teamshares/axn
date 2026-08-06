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

## `#forward!`

Delegates to a sub-action, forwarding its exposures onto this action's result and propagating its outcome. Collapses the [facade idiom](/usage/writing#forwarding-to-a-nested-action-facades) (`r = Child.call(**inputs); expose(r); raise r.exception unless r.ok?`) into one line, and is the only way to get exposure forwarding from the `call!` shape, where the raise leaves `#call` before any `expose` can run.

* First argument (required) is either an Axn class — invoked as `Klass.call(**inputs)`, i.e. with this action's resolved declared inbound fields — or an `Axn::Result` you produced yourself, when you need to control the arguments (`forward! Klass.call(**inputs.except(:plan), plan: DEFAULT)`). Anything else raises `ArgumentError`.
* **Non-terminal on success:** it returns the sub-action's `Axn::Result` and the rest of `#call` still runs.
* On any non-ok outcome it settles this action exactly as `Klass.call!` would: the same outcome, the same `result.error` (with your own declared `error` base applied on top), and a `result.exception` that is the sub-action's own exception object — so your `error ..., if: SomeError` handlers still match it.
* Forwards the intersection of the sub-action's declared exposures and your own `exposes`, including on the failure branch. Unlike a direct `expose(result)` — which raises `Axn::ContractViolation::NoMatchingExposures` when a *successful* source shares no fields with you — an empty intersection here is tolerated, so delegating to a side-effect-only action works.

## `#log`

Helper method to log (via the [configurable](/reference/configuration#logger) `Axn.config.logger`) the string you provide (prefixed with the Action's class name).

* First argument (required) is a string message to log
* Also accepts a `level:` keyword argument to change the log level (defaults to `info`)

Primarily used for its side effects; returns whatever the underlying `Axn.config.logger` instance returns.



