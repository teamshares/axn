---
outline: deep
---


# How to _use_ an Action

## Common Case

An action executed via `#call` _always_ returns an instance of the `Axn::Result` class.

This means the result _always_ implements a consistent interface, including `ok?` and `error` (see [full details](/reference/axn-result)) as well as any variables that the action `exposes`.

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

## Advanced Usage

### `#call!`

An action executed via `#call!` (note the `!`) does _not_ swallow exceptions -- a _successful_ action will return an `Axn::Result` just like `call`, but any exceptions will bubble up uncaught (note: technically they _will_ be caught, your on_exception handler triggered, and then re-raised) and any explicit `fail!` calls will raise an `Axn::Failure` exception with your custom message.

This is a much less common pattern, as you're giving up the benefits of error swallowing and the consistent return interface guarantee, but it can be useful in limited contexts (usually for smaller, one-off scripts where it's easier to just let a failure bubble up rather than worry about adding conditionals for error handling).


### `#call_async`

Before adopting this library, our code was littered with one-line workers whose only job was to fire off a service on a background job.  We were able to remove that entire glue layer by directly supporting async execution via background jobs from the Axn itself.

::: danger ALPHA
Async integration is NOT YET TESTED/NOT YET USED IN OUR APP, and naming will VERY LIKELY change to make it clearer which actions will be retried!
:::
