# Dashboards from Axn Metrics

Once you've wired up [`emit_metrics`](/reference/configuration#emit-metrics) and (optionally) [OpenTelemetry tracing](/reference/configuration#opentelemetry-tracing), every action execution is already emitting telemetry. This recipe is about the next step: turning that telemetry into dashboards you actually look at.

This is a **convention, not a framework requirement**. Axn deliberately doesn't ship dashboard tooling or couple itself to any metrics backend — `emit_metrics` is the seam, and what you build on top is yours. The examples below use Datadog because it's a common target, but the shape transfers to any provider.

## Start from a stable metric + tag schema

Dashboards are only as reusable as the metric they query. The single most useful decision is to emit **one count metric for all actions**, tagged by `resource` and `outcome`, rather than a differently-named metric per action:

```ruby
# config/initializers/axn.rb
Axn.configure do |c|
  c.emit_metrics = proc do |resource:, result:|
    StatsD.increment("axn.call", tags: { resource:, outcome: result.outcome.to_s })
  end
end
```

This gives you one metric (`axn.call`) tagged with `resource:` (the action class name) and `outcome:` (`success` / `failure` / `exception`). Because every action shares one metric name, a single dashboard can render the whole fleet, and drilling into one action is just adding a `resource:` filter — no per-action dashboard wiring required.

::: warning Keep tags bounded
Tag only with values from a known, finite set — `resource` (the set of action classes) and `outcome` (three values) are safe. Never tag with IDs, emails, or other per-call values: unbounded tag cardinality is what drives metrics cost and slows queries. See the [cardinality note](/reference/configuration#emit-metrics) on `emit_metrics`.
:::

If you also want latency, emit a distribution from `result.elapsed_time` under the same tag schema (e.g. `axn.call.duration`). Distributions cost more per series than counts, so confirm your `resource` set is bounded first — but at the scale of "number of action classes," it's negligible.

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
