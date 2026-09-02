# Declaring an Entry Point

This recipe is for **gem authors** whose gem dispatches Axns on behalf of some external trigger — an inbound webhook, a scheduled job runner, a queue consumer — but isn't itself a [tool-adapter gem](/recipes/authoring-tool-adapters). If you're building a tool adapter (MCP, an LLM function-calling bridge, an HTTP tool endpoint), you get this for free through [`Axn::Tools::Invoker`](/reference/tool-invoker) — read on anyway for what it does, then skip straight to passing `adapter:`.

## The problem this solves

The same Axn class is often callable more than one way: directly from a controller or job, and also dispatched by a gem on behalf of something external. Nothing about the class itself can tell those calls apart — the difference is a fact about *this particular call*, not about the class. A dashboard that wants to separate "traffic that came in through webhooks" from "everything else" needs that fact to travel with the call, not be declared on the class.

## Declaring it

Call `Axn::Extensions::InvokedVia.with(value) { ... }` around your dispatch, at the outermost point your gem controls:

```ruby
Axn::Extensions::InvokedVia.with(:webhooks) do
  handler_class.call!(**args)
end
```

`value` becomes the `invoked_via` dimension on every Axn that runs inside the block — including nested sub-Axns, since the stamp covers the whole call tree, not just the one call you wrap. It reaches every existing facet sink automatically: the `axn.dimension.invoked_via` span attribute, the `axn.call` notification payload, [`emit_metrics`](/reference/configuration#emit-metrics)'s `dimensions:` kwarg, the completion log line, and the `on_exception` report context. See [Dashboards from Axn Metrics](/recipes/datadog-dashboards) for querying it once it's flowing.

If your gem also enqueues a Sidekiq job from inside the block (`SomeAxn.call_async(...)`), the job picks up an `invoked_via:<value>` job tag at enqueue time. That's enqueue-time provenance only, not cross-process propagation — the *performed* job runs in a different process, where nothing is stamped, so its own `axn.call` metrics carry no `invoked_via`. If you need the value to survive into the performed job, you'll need to serialize it into the job's own arguments and re-stamp on the way in; there's no built-in mechanism for that today.

## Why not just declare a `dimension`?

`dimension :invoked_via, -> { "webhooks" }` on your gem's own Axn classes would work for calls that stay inside your gem — but it wouldn't reach the app-authored handler an inbound trigger goes on to call, and it can't distinguish two different calls to the *same* class based on how each one arrived. If your gem only ever dispatches Axns it authors itself, and doesn't need per-call granularity, a plain `dimension` declared once on your gem's base class is simpler and is the right tool — reach for `Axn::Extensions::InvokedVia` when the call crosses into code you don't own, or when the same class needs a different value depending on the call.

`invoked_via` itself is reserved: no class may declare `dimension :invoked_via` or `tag :invoked_via` — `Axn::Extensions::InvokedVia` is the only way to set it, so a dashboard built on it can trust the value always means what this recipe says.

## One choke point, not every call site

Call `.with` once, wrapping your gem's entire dispatch, rather than at every place you happen to invoke an Axn. Nesting is safe (an inner `.with` restores the outer value when it returns), but it isn't the intended shape, and wrapping only *some* of your dispatch sites produces a dashboard that under-counts your own traffic without any error telling you so.

If your gem's dispatch isn't behind a single method — for example, several independent handlers that each call an Axn directly — wrap the outermost shared entry point they're all reached through, even if that means wrapping a plain Ruby method rather than an Axn call itself.

## Picking a value

Use a short, stable Symbol identifying your gem — `:webhooks`, `:data_shifter`, not a per-call detail like a vendor name or job ID (that belongs in a `tag`, which is unbounded-cardinality by design; `invoked_via` is meant to stay a small, bounded set you can group a dashboard by).
