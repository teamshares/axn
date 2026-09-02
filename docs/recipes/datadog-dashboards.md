# Dashboards from Axn Metrics

Once you've wired up [`emit_metrics`](/reference/configuration#emit-metrics) and (optionally) [OpenTelemetry tracing](/reference/configuration#opentelemetry-tracing), every action execution is already emitting telemetry. This recipe is about the next step: turning that telemetry into dashboards you actually look at.

This is a **convention, not a framework requirement**. Axn deliberately doesn't ship dashboard tooling or couple itself to any metrics backend — `emit_metrics` is the seam, and what you build on top is yours. The examples below use Datadog because it's a common target, but the shape transfers to any provider.

## Start from a stable metric + tag schema

Dashboards are only as reusable as the metric they query. The single most useful decision is to emit **one count metric for all actions**, tagged by `resource` and `outcome`, rather than a differently-named metric per action:

```ruby
# config/initializers/axn.rb
Axn.configure do |c|
  c.emit_metrics = proc do |resource:, result:, dimensions:|
    StatsD.increment("axn.call", tags: dimensions.merge(resource:, outcome: result.outcome.to_s))
  end
end
```

This gives you one metric (`axn.call`) tagged with `resource:` (the action class name), `outcome:` (`success` / `failure` / `exception`), and every bounded [`dimension`](/reference/configuration#tagging-spans-with-domain-context-tag-dimension) an action or the framework itself resolves — merged so `resource:`/`outcome:` always win a name collision. Because every action shares one metric name, a single dashboard can render the whole fleet, and drilling into one action is just adding a `resource:` filter — no per-action dashboard wiring required.

::: tip Accept `dimensions:` even if you don't use it yet
Declare the block with `dimensions:` from the start, as above, even before you have any dimensions to merge. Axn resolves it either way, but a block that only takes `resource:`/`result:` silently never sees a `dimension` — including the framework's own [`invoked_via`](/recipes/declaring-entry-points), which distinguishes tool-driven calls (MCP, an LLM tool call) from ordinary direct traffic. Adding the kwarg later works too — `Internal::Callable` shape-adapts to whatever keywords your proc declares — but there's no warning if you forget it, so a dashboard segmented by `invoked_via` just silently shows nothing until you do.
:::

::: warning Keep tags bounded
Tag only with values from a known, finite set — `resource` (the set of action classes) and `outcome` (three values) are safe. Never tag with IDs, emails, or other per-call values: unbounded tag cardinality is what drives metrics cost and slows queries. See the [cardinality note](/reference/configuration#emit-metrics) on `emit_metrics`.
:::

If you also want latency, emit a distribution from `result.elapsed_time` under the same tag schema (e.g. `axn.call.duration`). Distributions cost more per series than counts, so confirm your `resource` set is bounded first — but at the scale of "number of action classes," it's negligible.

Per-action facets ride on top of this schema. A `dimension` declared on an action flows into `emit_metrics` as `dimensions:`, so merging it into your tag set adds a bounded, per-action metric dimension without touching the global hook. A `tag` (high-cardinality) does not reach metrics — it lands on the `axn.tag.*` span attributes instead, for filtering traces in APM.

One dimension is worth calling out specifically because it's framework-supplied rather than something you declare: `invoked_via`. A tool-adapter gem ([`Axn::Tools::Invoker`](/reference/tool-invoker)) or any gem dispatching Axns on behalf of an external trigger ([Declaring an Entry Point](/recipes/declaring-entry-points)) can stamp it on a whole call tree — it's what lets `sum:axn.call{invoked_via:mcp}.as_count()` answer "how much of our traffic is agent-driven" as a query against the same schema, with no separate metric or dashboard for tool calls.

## Two dashboards, two altitudes

A pair of dashboards covers most needs:

**1. A fleet overview** — one per app/service, answering "is everything healthy?":

- Total throughput (`sum:axn.call{*}.as_count()` over time) — DogStatsD stores the counter as a per-second rate, so apply `.as_count()` wherever you want raw totals
- Outcome mix and error rate (`outcome:failure` + `outcome:exception` over total)
- **Top actions by failure** (`sum:axn.call{outcome:failure} by {resource}.as_count()`) — this surfaces a single misbehaving action instantly
- Top actions by volume, and by exception
- Latency percentiles (p50/p95/p99) once you're emitting `axn.call.duration`

**2. A per-action drill-down** — the same widgets scoped to one `resource`, for when the overview points you at a specific action.

Because both are built from the same `axn.call` schema, the per-action view is just the overview with a `resource:` filter applied — which is what makes a single template reusable across every action and every Axn-based app (each one only supplies its own `service` name).

::: tip A "dead pipeline" alarm
The most valuable single monitor is often the simplest: alert when `sum:axn.call{service:your-app}.as_count()` drops to ~zero. That rarely means your actions stopped running — it usually means the metrics pipeline itself broke (a bad deploy, a misconfigured agent), which otherwise fails silently and leaves every other widget looking deceptively calm.
:::

Once you've settled on dashboards worth keeping, store their definitions in version control rather than hand-editing in the UI — most providers expose a dashboards API you can drive from a rake task to create or update them reproducibly.
