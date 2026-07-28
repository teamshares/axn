---
outline: deep
---


# How to _use_ an Action

## Common Case

An action executed via `#call` _always_ returns an instance of the `Axn::Result` class.

This means the result _always_ implements a consistent interface, including `ok?` and `error` (see [full details](/reference/axn-result)) as well as any variables that the action `exposes`.

::: warning What `call` can still raise
`call` swallows **`StandardError`, plus `SystemStackError` and `ScriptError`** — the two families outside `StandardError` that are unambiguously faults in the code being run (runaway recursion; a `NotImplementedError` from an unfinished method, a `LoadError`, a `SyntaxError`). Those come back as an `exception` outcome like any other.

Anything else outside `StandardError` is raised instead of being captured into a result, and fires none of your callbacks or `on_exception` handlers. That includes:

* `SystemExit` (an `exit` call) and anything under `SignalException` — `Interrupt` (Ctrl-C), `Sidekiq::Shutdown`. The process is going away; returning `ok? == false` would invite the caller to carry on through a shutdown.
* `Timeout::ExitException`, `Timeout`'s own internal signal. It must reach the enclosing `Timeout.timeout` for the timeout to fire at all.
* `NoMemoryError`, and any private control-flow signal a library defines as a direct `Exception` subclass.

That last one is why this is stated as what axn *does* swallow rather than a list of what it doesn't: any library can introduce such a signal, so the set axn passes through is open-ended and cannot be enumerated. Absorbing one would silently break whatever it signals. If a caller needs to survive these, rescue at the call site rather than checking `ok?`.
:::

As a consumer, you usually want a conditional that surfaces `error` unless the result is `ok?` (remember that any exceptions have been swallowed), and otherwise takes whatever success action is relevant.

For example:

```ruby
class MessagesController < ApplicationController
  def create
    result = Actions::Slack::Post.call( # [!code focus]
      channel: "#engineering",
      message: params[:message],
    )

    if result.ok?  # [!code focus:3]
      @thread_id = result.thread_id # Because `thread_id` was explicitly exposed
      flash.now[:success] = result.success
    else
      flash[:alert] = result.error # [!code focus]
      redirect_to action: :new
    end
  end
end
```

### Compact flash idiom

When you don't need to read a specific exposure on success, `result.message` is always set — the `success` message when `ok?`, the `error` message otherwise — so the whole branch collapses to a single line:

```ruby
def create
  result = Actions::Slack::Post.call(channel: "#engineering", message: params[:message])
  flash[result.ok? ? :success : :error] = result.message
  redirect_to messages_path
end
```

This pairs especially well with [per-action `success`/`error` declarations](/reference/class#success-and-error), so `result.message` is meaningful in both cases.

::: tip Flash keys
`:success` and `:error` aren't default Rails flash keys. Register them with `add_flash_types :success, :error` in your `ApplicationController`, or use the built-in `:notice` / `:alert` instead.
:::

## Advanced Usage

### `#call!`

An action executed via `#call!` (note the `!`) does _not_ swallow exceptions -- a _successful_ action will return an `Axn::Result` just like `call`, but any exceptions will bubble up uncaught (note: technically they _will_ be caught, your on_exception handler triggered, and then re-raised) and any explicit `fail!` calls will raise an `Axn::Failure` exception with your custom message.

This is a much less common pattern, as you're giving up the benefits of error swallowing and the consistent return interface guarantee, but it can be useful in limited contexts (usually for smaller, one-off scripts where it's easier to just let a failure bubble up rather than worry about adding conditionals for error handling).


### `#call_async`

Before adopting this library, our code was littered with one-line workers whose only job was to fire off a service on a background job. We were able to remove that entire glue layer by directly supporting async execution via background jobs from the Axn itself.

```ruby
class ProcessDataAction
  include Axn

  expects :data

  def call
    # Process data logic here
  end
end

# Execute synchronously
result = ProcessDataAction.call(data: large_dataset)

# Execute asynchronously
ProcessDataAction.call_async(data: large_dataset)
```

For detailed information about configuring async adapters (Sidekiq, ActiveJob, etc.), see the [Async Execution documentation](/reference/async).
