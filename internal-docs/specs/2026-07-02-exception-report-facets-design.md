# PRO-2853: Attach tag/dimension facets to exception reports

Design doc — 2026-07-02

Linear: https://linear.app/teamshares/issue/PRO-2853/axn-attach-tagdimension-facets-to-exception-reports

## Summary

The `tag`/`dimension` facet system (PRO-2850 / PRO-2852, PR #140) resolves per-action observability facets once per execution and routes them, surface-neutrally, to the `axn.call` span, the notification payload, and `emit_metrics`. This adds one more sink: the **global exception report** dispatched via `Axn.config.on_exception`. Every reported exception is thereby pre-tagged with the action's domain context (`company_id`, record ids, plan tier, …) with zero per-call work at the report site.

## Goal

When an axn's exception is reported through `Axn.config.on_exception`, attach the resolved facets so the consumer's handler can route them:

- `tag` (high-cardinality) → the report's freeform context / "extra".
- `dimension` (bounded) → the report's indexed tags (e.g. Sentry/Honeybadger tags).

Axn itself stays surface-neutral: it hands the handler two structured maps; the handler decides how they map onto its specific reporter's APIs.

## Timing (confirmed during design)

The global report dispatches inside `Executor#with_exception_handling` (`trigger_on_exception` → `Internal::ExceptionContext.build` → `Axn.config.on_exception`), nested *below* `with_tracing`, so it fires **before** span close. That is fine: `resolved_tags`/`resolved_dimensions` are lazy and memoized on the Executor, and the result is already settled (`__record_exception` has run), so reading them at report-build time yields correct values. The anchor is "at report dispatch," not "at span close" — same values the span and `emit_metrics` observe.

## Design decision: namespaced keys in `context` (not separate kwargs)

`on_exception(e, action:, context:)` receives a single `context` hash; the consumer's handler routes it to the reporter. Two candidate shapes were considered:

1. **Namespaced in `context`** — `context[:tags]`, `context[:dimensions]`.
2. **Separate kwargs** — `on_exception(e, action:, context:, tags:, dimensions:)`, leaving `context` untouched.

**Chosen: namespaced in `context`.** The deciding factor is the real consumer. teamshares-rails (`config/initializers/axn.rb`) does:

```ruby
c.on_exception = proc do |e, action:, context:|
  hb_context = context.merge(axn: axn_name, exception: e)
  Honeybadger.notify(message, context: hb_context, ...)
end
```

Because it forwards `context` wholesale, namespacing the facets into `context` ships them to Honeybadger with **zero handler changes** the moment the gem bumps. Separate kwargs would require every consumer to edit their handler before any facet data appeared — and the same file's `emit_metrics` is still `proc { |resource:, result:| }` (never opted into the `dimensions:` kwarg), empirically showing consumers do not update handlers promptly. The ride-along is the point.

Collision surface is narrow and handled: exposed result fields live at `context[:outputs][:foo]`, not at the top level, so `exposes :tags` does **not** collide with a top-level `context[:tags]`. The only collision is a user's `set_execution_context(tags: …)` / hook returning `:tags`, closed by reserving the keys (below).

The dimension→*indexed*-tags refinement (e.g. `Honeybadger.notify(..., tags: context[:dimensions].values)`) still needs a one-line opt-in handler edit whenever a team wants it; until then the data flows into the report context for free.

## Changes

No new files. Two source edits plus reservation, docs, and tests.

### 1. `Executor#trigger_on_exception` (`lib/axn/executor.rb`)

Pass the memoized, dup'd facet maps into the context builder:

```ruby
context = Internal::ExceptionContext.build(
  action: @action,
  retry_context:,
  tags: Core::Tagging.dup_facets(resolved_tags),
  dimensions: Core::Tagging.dup_facets(resolved_dimensions),
)
```

Reuses the existing `resolved_tags`/`resolved_dimensions` memoization (same values the span and `emit_metrics` see) and `Core::Tagging.dup_facets` (same mutation-safety as `with_tracing`/`emit_metrics`). No re-resolution.

### 2. `Internal::ExceptionContext.build` (`lib/axn/internal/exception_context.rb`)

Accept `tags:`/`dimensions:` kwargs (default `{}`) and attach each **only when non-empty**, mirroring how `async`/`current_attributes`/`axn_stack` are conditionally added and assigned *after* the user extra-keys merge:

```ruby
def build(action:, retry_context: nil, tags: {}, dimensions: {})
  ...
  context[:tags] = tags if tags.any?
  context[:dimensions] = dimensions if dimensions.any?
  context
end
```

**Value shape:** facets are attached as-is — already coerced to legal scalars/arrays by `Tagging.coerce` at resolve time — and are **not** re-run through `format_hash_values`. This keeps them byte-identical to what the span and metrics observe (surface-neutral resolved map). They are the dup'd copy, so a handler mutating them cannot corrupt the memoized maps.

### 3. Reserved keys (`lib/axn/core/contract.rb`)

Add `:tags` and `:dimensions` to `RESERVED_EXECUTION_CONTEXT_KEYS` so `set_execution_context(tags: …)` / an `additional_execution_context` hook returning `:tags` cannot clobber the framework-populated facets. Extend the doc comment to name them. Minor breaking change for anyone currently using a `tags`/`dimensions` extra key — CHANGELOG note.

## Edge cases

- **Ordering:** `:tags`/`:dimensions` are assigned after the user extra-keys merge (like the other framework keys), so the reservation is belt-and-suspenders — the framework value wins at report time even if a stray key slipped through collection.
- **Failure-path partials:** no special handling. A facet resolver touching a not-yet-`expose`d output resolves to `nil` (omitted) or raises (swallowed, that facet skipped) inside `Tagging.resolve`, which has already run by report time. We just read the settled map.
- **No-facets case:** an action declaring no `tag`/`dimension` produces empty maps → both keys omitted → `context` byte-identical to today. Existing handlers/specs unchanged.
- **Failures don't report:** a `fail!` / user-facing / `fails_on` outcome never reaches `trigger_on_exception`, so no facet keys appear — existing behavior, guards against reporting failures.
- **Async:** `retry_context` and facets are independent kwargs; facets resolve on the worker where the exception fires, reflecting that attempt's domain context, and coexist with `context[:async]`.

## Documentation

`docs/reference/configuration.md`:
- Add `tags:` / `dimensions:` to the `on_exception` context-shape list, noting they appear only when the action declares facets.
- Update the cardinality-mapping note (currently "later ... exception detail" / "later Sentry/Sidekiq tags") to present tense, with a short worked example routing `context[:dimensions]` → indexed tags and `context[:tags]` → extra. Apply `[!code focus]` selectively per the repo rubric (full-config block teaching a couple lines).

CHANGELOG: new context keys + reserved-keys note.

## Tests

Following existing styles.

**Unit — `spec/axn/internal/exception_context_spec.rb`:**
- `build` with `tags:`/`dimensions:` populated → keys present with those exact values.
- Empty maps → keys omitted (byte-identical to today).
- Values pass through verbatim (no `format_hash_values` re-formatting) — a resolved integer stays an integer, not a GID string.

**Integration — new `spec/axn/core/` spec (mirroring `additional_execution_context_spec.rb`'s `on_exception` capture pattern):**
- Action declaring `tag`/`dimension` that raises → `on_exception` receives `context[:tags]`/`context[:dimensions]` with resolved values.
- Handler mutating `context[:tags]` does not corrupt what the span reads (dup is a real copy).
- `set_execution_context(tags: …)` stripped, framework facets win (reserved-key coverage).
- Failure path (`fail!` / user-facing) → no global report, no facet keys.
- Action with no facets → context unchanged.
- Async case: facets present alongside `context[:async]`.
