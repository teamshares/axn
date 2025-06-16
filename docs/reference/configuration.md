# Configuration

Somewhere at boot (e.g. `config/initializers/actions.rb` in Rails), you can call `Action.configure` to adjust a few global settings.


```ruby
  Action.configure do |c|
    c.on_exception = ...

    c.top_level_around_hook = ...

    c.additional_includes = []

    c.default_log_level = :info
    c.default_autolog_level = :debug

    c.logger = ...
  end
```

## `on_exception`

By default any swallowed errors are noted in the logs, but it's _highly recommended_ to wire up an `on_exception` handler so those get reported to your error tracking service.

For example, if you're using Honeybadger this could look something like:


```ruby
  Action.configure do |c|
    c.on_exception = proc do |e, action:, context:|
      message = "[#{action.class.name}] Failing due to #{e.class.name}: #{e.message}"

      Rails.logger.warn(message)
      Honeybadger.notify(message, context: { axn_context: context })
    end
  end
```

A couple notes:

  * `context` will contain the arguments passed to the `action`, _but_ any marked as sensitive (e.g. `expects :foo, sensitive: true`) will be filtered out in the logs.
  * If your handler raises, the failure will _also_ be swallowed and logged
  * This handler is global across _all_ Axns.  You can also specify per-Action handlers via [the class-level declaration](/reference/class#on-exception).


## `top_level_around_hook`

If you're using an APM provider, observability can be greatly enhanced by adding automatic _tracing_ of Action calls and/or emitting count metrics after each call completes.

For example, to wire up Datadog:

```ruby
  Action.configure do |c|
    c.top_level_around_hook = proc do |resource, &action|
      Datadog::Tracing.trace("Action", resource:) do
        (outcome, _exception) = action.call

        TS::Metrics.increment("action.#{resource.underscore}", tags: { outcome:, resource: })
      end
    end
  end
```

A couple notes:

  * `Datadog::Tracing` is provided by [the datadog gem](https://rubygems.org/gems/datadog)
  * `TS::Metrics` is a custom implementation to set a Datadog count metric, but the relevant part to note is that outcome (`success`, `failure`, `exception`) of the action is reported so you can easily track e.g. success rates per action.


## `logger`

Defaults to `Rails.logger`, if present, otherwise falls back to `Logger.new($stdout)`.  But can be set to a custom logger as necessary.

## `additional_includes`

This is much less critical than the preceding options, but on the off chance you want to add additional customization to _all_ your actions you can set additional modules to be included alongside `include Action`.

For example:

```ruby
  Action.configure do |c|
    c.additional_includes = [SomeFancyCustomModule]
  end
```

For a practical example of this in practice, see [our 'memoization' recipe](/recipes/memoization).

## `default_log_level`

Sets the log level used when you call `log "Some message"` in your Action.  Note this is read via a `default_log_level` class method, so you can easily use inheritance to support different log levels for different sets of actions.

## `default_autolog_level`

By default, every `action.call` will emit log lines when it is called and after it completes:

  ```
    [YourCustomAction] About to execute with: {:foo=>"bar"}
    [YourCustomAction] Execution completed (with outcome: success) in 0.957 milliseconds
  ```

You can change the default _auto_-log level separately from the log level used for your explicit `log` calls (just like above, via Action.config or a `default_autolog_level` class method).
