## History

The need to consistently organize your business logic somewhere within the MVC Rails stack is a perennial topic of discussion, with many approaches in the community. Over the course of a few years, [we at Teamshares](https://github.com/teamshares) had three teams building three separate apps, each of which chose a different approach.

After observing the challenges that emerged from each approach, we extracted a list of explicit design goals and then set out to build a library that would implement them.

## Design Goals

::: tip Overall Focus
A simple, declarative core API. Concise enough to pick up quickly, but sufficiently powerful to manage real-world complexity.
:::

**Core needs:**

  - Consistent, DRY pattern to reach for when building services (`FooService.call`)
  - Ability to declaratively specify pre- and post- conditions
  - Consistent return interface (including exception swallowing)
    - Clear distinction between user-facing and internal errors
  - Minimal boilerplate
  - Easy backgrounding (no need for a separate Worker class just to wrap a service call)

**Additional benefits devs get for free:**

  - Integrated metrics
  - Integrated debug logging
  - Automatic error reporting

## Orchestration

We found that many of our existing solutions were _also_ pretty solid for individual services, but started to break down when complex use-cases required nesting service calls within each other (hard to tell at a glance how exceptions bubble up, what the end-user ends up seeing in various failure modes, which parts get unwound by DB transactions, etc.).

The core library provides many benefits for individual action calls, but also aims to establish a few clear usage patterns to make it easy to reason about nested services.

### "Blessed" patterns:
* Single action
* Linear flow
  * A list of actions to execute in series
  * Each layer `expects` and `exposes` its own accessor set, but internally all the values are passed down the chain (i.e. actor C can accept something A exposed that B didn’t touch and knows nothing about).
  * The top-level action must `expose` it’s own layer (effectively documenting public vs private exposures, which drastically eases refactoring)
* Ad hoc (called arbitrarily from within other actions)
  * `hoist_errors` (usage: `hoist_errors { Nested::Action.call }`) ensures any failure from a nested service is bubbled up to the top level (by default, as if the failure had happened there directly).
  * Allows configurable handling at call site (e.g. setting `prefix`, so identical failures from different nested calls are distinguishable)

::: danger ALPHA
* TODO: add links to sections showing usage guides/examples for the more complex flows
:::
