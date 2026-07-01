# Suppressing Duplicate Async Error Reports

When an Axn async job fails, your error monitoring integration may report the exception **twice**: once via Axn's `on_exception` path, and once natively from the background job framework's own error integration.

For example, with Honeybadger + Sidekiq: Honeybadger's Sidekiq plugin independently catches the re-raised exception on every execution, producing a separate raw fault in Honeybadger regardless of your `async_exception_reporting` setting. If you've configured `:first_and_exhausted`, you'll still see a raw Sidekiq `RuntimeError` fault with one notice per retry — which makes the reporting look broken.

## General Approach

The fix belongs in your error reporter, not in Axn. Suppress framework-native reports for Axn actions (since Axn is already handling reporting via `on_exception`) while leaving non-Axn jobs unaffected.

The two signals you need:

1. **Is this job/notice Axn-owned?** Ask `Axn::Async.owns?(signal)`. It accepts a resolved Class, a String class name (including the ActiveJob adapter's `"::ActiveJobProxy"` suffix), or a raw Sidekiq job Hash (string or symbol keys), and folds in every detail of Axn's async wiring — the generic Sidekiq worker, the proxy naming convention, and the `display_class` wire format. Pass it whatever your error reporter's plugin hands you; blank/unrecognized input returns `false` without raising.
2. **Was this notice sent by Axn or by the framework natively?** Tag Axn-authored notices in your `on_exception` handler so they can be distinguished from the native ones.

::: tip Why not just check `klass.include?(Axn::Core)`?
Because Axn actions are no longer `Sidekiq::Job`s. The enqueued class is a generic worker (`Axn::Async::Adapters::Sidekiq::Worker` — either a per-action `AxnSidekiqWorker` subclass or the global `DefaultWorker`) that constantizes and runs your action by name; the real action name only survives as a string in `display_class` or the first job arg. A `klass.include?(Axn::Core)` / `klass < Axn` check against the worker class therefore returns `false`, silently letting duplicate reports through. `Axn::Async.owns?` handles all of this, so downstream filters never need to track Axn's internal class hierarchy or wire format.
:::

Add a known key when calling your error reporter from `on_exception`:

```ruby
Axn.configure do |c|
  c.on_exception = proc do |e, action:, context:|
    # Tag this notice as Axn-authored so we can identify it in before_notify filters
    Honeybadger.notify(e, context: context.merge(axn: true)) # [!code focus]
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
    # Axn's on_exception is handling reporting for these. `owns?` recognizes each
    # job-class signal Honeybadger's plugins record, whatever its shape:
    #   - notice.component        (Sidekiq/ActiveJob plugin, a class-name String)
    #   - notice.parameters[:job] (the raw Sidekiq job Hash: display_class / wrapped / class)
    params = notice.parameters
    job_hash = params[:job] || params["job"] || params

    signals = [notice.component, job_hash]
    next notice.halt! if signals.any? { |signal| Axn::Async.owns?(signal) } # [!code focus]
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
