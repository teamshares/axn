# Concurrency & Fiber Safety

Axn is safe to run concurrently. This page explains how, and the one knob you need to set if you run actions under a **fiber-based** server or job processor (e.g. [async](https://github.com/socketry/async) / [Falcon](https://github.com/socketry/falcon)).

## TL;DR

- **Thread-based concurrency** (Sidekiq, Puma threads, ActiveJob on a threaded backend): safe out of the box. Nothing to configure.
- **Fiber-based concurrency** (async / Falcon): set `isolation_level = :fiber` in your host app. Axn will emit a warning at runtime if it detects a fiber scheduler while this is still set to the default `:thread`.

## How Axn scopes per-execution state

Almost all of Axn's state is held in instance variables on objects created fresh for each `call` (the context, the result, memoized readers). That state is never shared between executions, so it is inherently isolated regardless of threads or fibers.

The small amount of state that is *ambient* to a call tree — the nesting stack, the exception report-dedup and `fails_on` classification sets, and the current async retry context — is stored in [`ActiveSupport::IsolatedExecutionState`](https://api.rubyonrails.org/classes/ActiveSupport/IsolatedExecutionState.html). Axn deliberately uses this rather than raw thread-locals, because it is the same mechanism ActiveRecord and `CurrentAttributes` ride: its scoping follows a single host-app setting, `isolation_level`.

## The `isolation_level` knob

`ActiveSupport::IsolatedExecutionState.isolation_level` is either `:thread` (the default) or `:fiber`, and it decides what "current execution" means for *all* of the above:

- Under `:thread`, state is keyed to `Thread.current`. Each thread gets its own state, so thread-based concurrency is isolated — but **multiple fibers on one thread share it**.
- Under `:fiber`, state is keyed to `Fiber.current`. Each fiber (and therefore each thread, since every thread has its own root fiber) gets its own state, so **both** thread- and fiber-based concurrency are isolated.

This is why a fiber host needs `:fiber`: under the default `:thread`, concurrent fibers would share — and corrupt — Axn's nesting stack and classification sets. In Rails:

```ruby
# config/application.rb — only needed for fiber-based servers/job processors
config.active_support.isolation_level = :fiber
```

Outside Rails:

```ruby
ActiveSupport::IsolatedExecutionState.isolation_level = :fiber
```

In practice a Rails app on Falcon almost always sets this already, because ActiveRecord's per-execution connection lease depends on the very same setting — leave it `:thread` under fibers and connection pooling breaks before Axn ever would.

### Why Axn doesn't set it for you

`isolation_level` is an application-global that also governs ActiveRecord and `CurrentAttributes`, and assigning it at runtime calls `IsolatedExecutionState.clear` (wiping all existing state). A library flipping it would be both presumptuous and unsafe, so Axn inherits the host's choice and warns on a dangerous mismatch instead.

### The runtime warning

When Axn opens a call tree, if it detects an active `Fiber.scheduler` (the signal that fibers are in play) while `isolation_level` is still `:thread`, it logs a one-time warning pointing at the fix. Under plain threads (no scheduler) it stays silent.

## Using async in an action

Two different things get called "async" — keep them separate:

**Background jobs (`call_async`).** Axn's `async :sidekiq` / `async :active_job` run the action later on a background-job worker. These are thread-based (one job per thread), so the default `:thread` isolation is correct and there is nothing to configure. This is the common path; see [Async Execution](/reference/async).

**In-process fan-out with the [async](https://github.com/socketry/async) gem.** Axn has no fiber-based adapter, so you orchestrate this yourself by wrapping `.call` in `Async {}`:

```ruby
require "async"

class FetchAllProfiles
  include Axn
  expects :user_ids

  def call
    profiles = Sync do
      user_ids.map { |id| Async { FetchProfile.call!(id:).profile } }.map(&:wait)
    end
    expose :profiles, profiles
  end
end
```

This only behaves correctly when the host has `isolation_level = :fiber` — otherwise the concurrent fibers share the calling thread's execution state. Two things to keep in mind:

- It is safe to set `:fiber` even under a thread-based server like Puma: each server thread has its own root fiber, so normal request handling stays isolated, and the fan-out fibers get their own state too.
- Each `Async {}` task is its own call tree (the child-fiber caveat below), and it leases its own ActiveRecord connection — so size your pool for the concurrency, and don't rely on `CurrentAttributes`/ambient state set outside the task.

## The invariant (for contributors)

Axn keeps **no** per-execution state in raw thread-locals (`Thread.current[...]`, `thread_variable_*`), class variables (`@@foo`), or globals. Those patterns leak across fibers no matter how `isolation_level` is set, so they are banned — a spec (`spec/axn/no_unscoped_execution_state_spec.rb`) fails the build if any appear in `lib/`. If you need ambient per-execution state, use `ActiveSupport::IsolatedExecutionState[...]` so it inherits the host's scoping like everything else.

## Notes & sharp edges

**Lazy-initialized singletons.** A few process-global config objects (`Axn.config`, the extension config) memoize on first use. The computation is idempotent, so a concurrent first-touch is harmless — but if you want to avoid even redundant work on a hot path, touch them once at boot (e.g. reference `Axn.config` in an initializer) so initialization never races.

**Child fibers don't inherit the parent's call tree.** `IsolatedExecutionState` is keyed by fiber *identity*, not inherited into child fibers. So if you fan out sub-actions across child fibers *inside* an action (`Async { SubAction.call }`), each child starts a fresh call tree — nested-report dedup and `fails_on` stickiness won't span that boundary. For genuinely concurrent sub-actions this is usually the behavior you want, but it's worth knowing.
