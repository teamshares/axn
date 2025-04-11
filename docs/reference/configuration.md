# Configuration

Somewhere at boot (e.g. `config/initializers/actions.rb` in Rails), you can call `Action.configure` to adjust a few global settings.


```ruby
  Action.configure do |c|
    c.on_exception = ...

    c.top_level_around_hook = ...

    c.additional_includes = []

    c.global_debug_logging = false

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

## `global_debug_logging`

By default, every `action.call` will emit _debug_ log lines when it is called and after it completes:

  ```
    [YourCustomAction] About to execute with: {:foo=>"bar"}
    [YourCustomAction] Execution completed (with outcome: success) in 0.957 milliseconds
  ```

You can bump the log level from `debug` to `info` for specific actions by including their class name (comma separated, if multiple) in a `SA_DEBUG_TARGETS` ENV variable.

You can also turn this on _globally_ by setting `global_debug_logging = true`.

```ruby
  Action.configure do |c|
    c.global_debug_logging = true
  end
```
