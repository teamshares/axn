---
outline: deep
---

# Introduction

This library provides a set of conventions for writing business logic in Rails (or other Ruby) applications with:

  * Clear calling semantics: `Foo.call`
  * A declarative interface
  * A [consistent return interface](/intro/overview#return-interface)
    * Exception swallowing + clear distinction between internal and user-facing errors

### Minimal example

Your logic goes in a <abbr title="Plain Old Ruby Object">PORO</abbr>. The only requirements are to `include Action` and a `call` method, meaning the basic skeleton looks something like this:

```ruby
class Foo
  include Action

  def call
    log "Doesn't do much, but this technically works..."
  end
end
```

## Inputs and Outflows

Most actions require inputs, and many return values to the caller; no need for any `def initialize` boilerplate, just add:

  * `expects :foo` to declare inputs the class expects to receive.

    You pass the `expect`ed keyword arguments to `call`, then reference their values as local `attr_reader`s.

  * `exposes :bar` to declare any outputs the class will expose.

    Within your action, use `expose :bar, <value>` to set a value that will be available on the return interface.

::: info
By design you _cannot access anything you do not explicitly `expose` from outside the action itself_.  Making the external interface explicit helps maintainability by ensuring you can refactor internals without breaking existing callsites.
:::

::: warning
The declarative interface (`expects` and `exposes`) constitutes a contract you are making _with yourself_ (and your fellow developers). **This is _not_ for validating user input** -- [there's a Form Object pattern for that](/recipes/validating-user-input).
:::

If any declared expectations or exposures are _not_ met the action will fail, setting `error` to a generic error message (because a failed validation means _you_ called _your own_ service wrong; there's nothing the end user can do about that).


### Example

```ruby
class Actions::Slack::Post
  include Action
  VALID_CHANNELS = [ ... ]

  expects :channel, default: VALID_CHANNELS.first, inclusion: { in: VALID_CHANNELS } # [!code focus:4]
  expects :message, type: String

  exposes :thread_id, type: String

  def call
    response = client.chat_postMessage(channel:, text: message)
    the_thread_id = response["ts"]

    expose :thread_id, the_thread_id # [!code focus]
  end

  private

  def client = Slack::Web::Client.new
end
```

## Return interface {#return-interface}


The return value of an Action call is always an `Action::Result`, which provides a consistent interface:

* `ok?` will return a boolean (false if any errors or exceptions occurred, otherwise true)
  * if OK, `success` will return a string that is _safe to show end users_
  * if _not_ OK, `error` will return an error string that is _safe to show end users_
* `message` is a helper to return the relevant message in either case (defined as `ok? ? success : error`)


### Example

This interface yields a common usage pattern:


```ruby
class MessagesController < ApplicationController
  def create
    result = Actions::Slack::Post.call( # [!code focus]
      channel: "#engineering",
      message: params[:message],
    )

    if result.ok?  # [!code focus:2]
      @thread_id = result.thread_id # Because `thread_id` was explicitly exposed
      flash.now[:success] = "Sent the Slack message"
    else
      flash[:alert] = result.error # [!code focus]
      redirect_to action: :new
    end
  end
end
```

Note this simple pattern handles multiple levels of "failure" ([details below](#error-handling)):
* Showing specific user-facing flash messages for any arbitrary logic you want in your action (from `fail!`)
* Showing generic error message if anything went wrong internally (e.g. the Slack client raised an exception -- it's been logged for the team to investigate, but the user doesn't need to care _what_ went wrong)
* Showing generic error message if any of your declared interface expectations fail (e.g. if the exposed `thread_id`, which we pulled from Slack's API response, somehow _isn't_ a String)


## Error handling {#error-handling}

::: tip BIG IDEA
By design, `result.error` is always safe to show to the user.

Calling code _usually_ only cares about `ok?` and `error` -- no complex error handling needed. :star_struck:
:::


We make a clear distinction between user-facing and internal errors.

### User-facing errors (`fail!`)

For _known_ failure modes, you can call `fail!("Some user-facing explanation")` at any time to abort execution and set `result.error` to your custom message.

### Internal errors (uncaught `raise`)

Any exceptions will be swallowed and the action failed (i.e. _not_ `ok?`). `result.error` will be set to a generic error message ("Something went wrong" by default, but [highly configurable](/reference/class#messages)).

The swallowed exception will be available on `result.exception` for your introspection, but it'll also be passed to your `on_exception` handler so, [with a bit of configuration](/usage/setup), you can trust that any exceptions have been logged to your error tracking service automatically (one more thing the dev doesn't need to think about).
