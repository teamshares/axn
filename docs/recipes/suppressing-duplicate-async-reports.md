# Suppressing Duplicate Async Error Reports

When an Axn async job fails, your error monitoring integration may report the exception **twice**: once via Axn's `on_exception` path, and once natively from the background job framework's own error integration.

For example, with Honeybadger + Sidekiq: Honeybadger's Sidekiq plugin independently catches the re-raised exception on every execution, producing a separate raw fault in Honeybadger regardless of your `async_exception_reporting` setting. If you've configured `:first_and_exhausted`, you'll still see a raw Sidekiq `RuntimeError` fault with one notice per retry — which makes the reporting look broken.

## General Approach

The fix belongs in your error reporter, not in Axn. Suppress framework-native reports for Axn actions (since Axn is already handling reporting via `on_exception`) while leaving non-Axn jobs unaffected.

The two signals you need:

1. **Is this an Axn action?** Check whether the job class includes `Axn::Core`.
2. **Was this notice sent by Axn or by the framework natively?** Tag Axn-authored notices in your `on_exception` handler so they can be distinguished from the native ones.

Add a known key when calling your error reporter from `on_exception`:

```ruby
Axn.configure do |c|
  c.on_exception = proc do |e, action:, context:|
    # Tag this notice as Axn-authored so we can identify it in before_notify filters
    Honeybadger.notify(e, context: context.merge(axn: true))
  end
end
```

## Honeybadger + Sidekiq Example

Honeybadger's `before_notify` hook lets you inspect and halt notices before they're sent:

```ruby
# config/initializers/honeybadger.rb
Honeybadger.configure do |config|
  config.before_notify do |notice|
    # Axn-authored notices (tagged via on_exception) always pass through
    next if notice.context[:axn] || notice.context["axn"]

    # Halt native Sidekiq/ActiveJob notices for Axn actions —
    # Axn's on_exception is handling reporting for these.
    component = notice.component.to_s

    # Direct Sidekiq worker: component is the Axn action class itself
    klass = component.safe_constantize
    next notice.halt! if klass&.include?(Axn::Core)

    # ActiveJob proxy: component is "MyAction::ActiveJobProxy"
    if component.end_with?("::ActiveJobProxy")
      action_klass = component.delete_suffix("::ActiveJobProxy").safe_constantize
      next notice.halt! if action_klass&.include?(Axn::Core)
    end
  end
end
```

**What this does:**

- Axn-authored notices (tagged `axn: true`) pass through unchanged
- Native Sidekiq/ActiveJob notices for Axn actions are halted
- Notices for non-Axn workers are unaffected
- Multiple `before_notify` hooks compose — this doesn't interfere with other app-specific filters

## Notes

- The exact implementation varies by error reporter and adapter. The pattern is the same: detect Axn ownership at the filter layer and suppress native reports, passing through Axn-authored ones.
- This fix is typically applied in your application or framework layer rather than in Axn itself, since it depends on which error reporter you're using.
