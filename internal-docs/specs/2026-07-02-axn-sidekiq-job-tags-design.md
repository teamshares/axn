# Axn — surface facets as Sidekiq job tags — design

**Ticket:** [PRO-2855 — \[Axn\] Surface bounded dimensions as Sidekiq job tags](https://linear.app/teamshares/issue/PRO-2855/axn-surface-bounded-dimensions-as-sidekiq-job-tags)

**Branch:** `kali/pro-2855-axn-surface-bounded-dimensions-as-sidekiq-job-tags` (off `main` @ #140)

**Foundation:** the `tag`/`dimension` facet system from [PRO-2850](https://linear.app/teamshares/issue/PRO-2850/axn-support-tagging) / [PRO-2852](https://linear.app/teamshares/issue/PRO-2852/axn-add-dimension-support-for-bounded-tags) (PR #140). See `2026-07-02-axn-tagging-design.md`.

## Problem

An action declares domain facets (`tag`/`dimension`) that today attach to the `axn.call` span, the notification payload, and (for `dimension`) `emit_metrics`. When an action runs as a Sidekiq job, those facets are exactly the labels that would make the job findable in the Sidekiq web UI — "show me every job for company X". Sidekiq supports per-job `tags` (a string array on the job payload, shown as labels and, in Pro/Enterprise, searchable), but nothing wires an action's facets into them.

## Two decisions that shaped this

**1. Both `tag` and `dimension` surface — not just `dimension`.** The ticket's original scope was `dimension`-only, on the theory that high-cardinality `tag`s would bloat the UI. But the motivating use case — *filter Sidekiq jobs by company* — keys on `company_id`, which is **high-cardinality and therefore a `tag`**, not a `dimension`. Restricting to `dimension` would exclude the exact facet the feature exists to surface. The cardinality split was driven by **Datadog metrics billing** (each unique metric-tag value mints a new time series), and that pressure has *no analog* in Sidekiq: job tags are ephemeral strings in the job's Redis payload (gone when the job finishes), with no per-value cost. So both facet types are appropriate here; identifiers (`tag`s) are in fact the more useful ones for finding a specific job.

**2. Enqueue-time resolution, inputs only.** Unlike the span/log/`emit_metrics` sinks — which resolve at completion, when inputs *and* results are settled — Sidekiq `tags` are an **enqueue-time** property, evaluated before the job runs, in a different process and Executor. Consequences:

* Only **input-derived** facets (from `expects`) can resolve at enqueue. **Result-derived** facets (`exposes`, `result.outcome`) fundamentally cannot become job tags — the run hasn't happened. They drop out automatically (see below); no new DSL knob.
* This is a **separate inputs-only resolution pass**, distinct from the completion-time pass the other sinks share. There's no settled result or execution Executor to memoize on.

Note: **ActiveJob has no native tag concept** — this sink is Sidekiq-specific. For pure-ActiveJob, the `axn.call` span attributes already carry per-execution facets on the job's APM span; no work there.

## Design

### Config knob (global-only for now)

```ruby
Axn.config.sidekiq_job_tag_sources   # default: %i[tag dimension]
#   %i[dimension]  → bounded facets only (the ticket's original scope)
#   %i[tag]        → high-card facets only
#   []             → disable the Sidekiq-tag sink entirely
```

A single global setting on `Axn::Configuration`, validated to a subset of `%i[tag dimension]`. Default is **both**, so the flagship use case works out of the box; an app with pathological high-card tags can dial back to `%i[dimension]` or `[]`.

**Per-axn override is deliberately deferred to [PRO-2856](https://linear.app/teamshares/issue/PRO-2856).** The `Axn::Configurable` per-class override machinery (`overridable: true` → `resolved_<name>`/`raw_<name>`) exists and is hardened, but is not yet wired into the action lifecycle, and lives in a different config namespace from `Axn.config`. Wiring it deserves a deliberate, uniform pass rather than being smuggled in here. The design keeps the future swap a one-liner: when PRO-2856 lands, this setting flips to `overridable: true` and the adapter reads `resolved_sidekiq_job_tag_sources` instead of `Axn.config.sidekiq_job_tag_sources`.

### Enqueue hook + resolution

The hook point is `Axn::Async::Adapters::Sidekiq#_enqueue_async_job(kwargs)` (`sidekiq.rb`), which already runs in the **class** context (so `_tags`/`_dimensions` and config are reachable), cleans `_async` options out of `kwargs`, and calls `.set(display_class: name)` on the resolved worker before `perform_async`/`perform_at`/`perform_in`. Job tags ride along that same `.set`.

Flow, gated cheaply:

1. `sources = Axn.config.sidekiq_job_tag_sources`. **Skip entirely** if `sources` is empty, or if the action declares no facets for the enabled sources (`_tags`/`_dimensions` empty). Actions without facets — the overwhelming majority — pay nothing.
2. Build a throwaway, **non-run** action instance seeded with the cleaned kwargs: `send(:new, **clean_kwargs)`. `initialize` only sets `@__context = Axn::Context.new(**)` — cheap, no hooks, no `call`. `expects` readers work because they read straight from context.
3. Run the **inbound coercion phase only** — `apply_inbound_preprocessing!`, `apply_defaults!(:inbound)`, `validate_contract!(:inbound)` — wrapped in `PipingError.swallow`, so an invalid-input enqueue still succeeds (we resolve best-effort against whatever coerced cleanly). This applies `preprocess:` transforms and inbound `default:`s before resolution — the one thing the coercion pass buys over a bare instance. `model:` records resolve **lazily on read** (facade.rb), so a model-derived facet triggers its lookup only if a resolver actually reads it — under any approach; running validation doesn't add cost there.
4. Resolve the enabled facet maps via the existing `Core::Tagging.resolve(map, action:)`, which already runs each resolver independently, swallows per-facet errors, and drops `nil` results. **Result-derived resolvers fall out here automatically** — reading `result.outcome` / an unexposed field raises or returns nil, and gets skipped.

The coercion+resolve seam lives on `Axn::Executor` (which already owns both the coercion phase methods and `resolved_tags`/`resolved_dimensions`) as a new inputs-only entry point — e.g. `#resolve_inbound_facets(sources)`. The Sidekiq-specific formatting and attachment live in the adapter.

### Format + attach

Resolved facets (`name => scalar-or-array`, already coerced to legal scalars by `Tagging.coerce`) become Sidekiq tag strings in `name:value` form — matching the Datadog/Sentry/Sidekiq bounded-tag convention and the mapping note from the tagging design. Array-valued facets fan out to one tag per element:

```
company_id:12345
plan:trial
plan:paid        # from dimension plan: [:trial, :paid]
```

These **merge** (union, deduped) with any static `sidekiq_options tags:` already configured on the worker — never clobber — and attach via the existing `.set(display_class: name, tags: [...])`. The whole helper is guarded so a failure never breaks the enqueue.

`tag` and `dimension` share a formatting namespace here (both → `name:value`); a name declared as both collapses to the same string and dedups harmlessly.

## Non-goals

* **Per-axn override** of `sidekiq_job_tag_sources` — deferred to PRO-2856 (see above).
* **Result-derived facets as job tags** — impossible at enqueue by construction; they remain on the span/payload/metrics sinks.
* **ActiveJob tags** — no native concept; the span-attribute path already covers pure-ActiveJob APM job spans.
* **A "when" knob on the DSL** — not needed; inputs-only resolution + per-facet swallow makes result-derived facets self-select out.

## Testing

* **Unit (`spec/`, non-Rails):** inputs-only resolution of scalar / proc / symbol input facets; a result-derived resolver is omitted (returns nil / raises → swallowed); `sidekiq_job_tag_sources` gating (`[]` → none, `%i[dimension]` → dimensions only, etc.); `name:value` formatting incl. array fan-out and merge-with-static dedup.
* **Sidekiq adapter (`spec/axn/async/adapters/sidekiq`, under `Sidekiq::Testing`):** enqueue asserts the job's `tags` — present with facets, absent without, `tag` excluded when sources = `%i[dimension]`, and enqueue survives a resolver that raises.
* **Rails dummy app (`spec_rails/`):** a `model:`-derived facet resolves to a tag via a real AR lookup; `preprocess`/`default` applied before resolution.

## Docs

* `docs/reference/configuration.md` — in the tagging section, document that facets surface as Sidekiq job tags at enqueue: the `sidekiq_job_tag_sources` knob and default, input-derived-only with the enqueue-time lifecycle limitation stated plainly, the `name:value` format, and that it's Sidekiq-specific (ActiveJob uses span attributes).
* Refine the existing cardinality mapping note (was "an Axn `dimension` becomes a … Sidekiq tag (bounded)") to reflect that **both** `tag` and `dimension` surface as Sidekiq tags by default, since Sidekiq tags carry no metrics-billing cost.

## Follow-ups

* [PRO-2856](https://linear.app/teamshares/issue/PRO-2856) — wire the Configurable per-class override system into the action lifecycle, then flip `sidekiq_job_tag_sources` to `overridable: true`.
