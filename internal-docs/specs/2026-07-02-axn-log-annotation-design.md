# Axn log annotation (`tag` / `dimension` on auto-log lines) — design

**Ticket:** [PRO-2854 — \[Axn\] Annotate log lines with tag/dimension facets](https://linear.app/teamshares/issue/PRO-2854/axn-annotate-log-lines-with-tagdimension-facets)

**Foundation:** [PR #140](https://github.com/teamshares/axn/pull/140) (merged) — the `tag`/`dimension` facet system ([PRO-2850](https://linear.app/teamshares/issue/PRO-2850/axn-support-tagging) / [PRO-2852](https://linear.app/teamshares/issue/PRO-2852/axn-add-dimension-support-for-bounded-tags)). Predecessor: [os-app#4976](https://github.com/teamshares/os-app/pull/4976).

## Problem

PR #140 landed `tag` (high-cardinality) and `dimension` (bounded) as declarative observability facets and wired them into three sinks: the `axn.call` OpenTelemetry span (`axn.tag.<name>` / `axn.dimension.<name>` attributes), the `axn.call` notification payload (`payload[:tags]` / `payload[:dimensions]`), and — for `dimension` — the `emit_metrics` hook. The resolved key→value maps were deliberately made surface-neutral so follow-on sinks could consume them without re-resolving.

Log annotation is the next such sink, and the original os-app goal. `EventHandlers::Base#log` once wrapped every log line in `SemanticLogger.tagged({ ddtags: "company_name:…,event:…" })` to correlate event-handler logs with a company/event in Datadog; it was hand-wired at one call site, never consumed, and os-app#4976 removed it. This does the same idea at the framework layer: axn's own `auto_log` output should carry the facets the action already declares, with no per-call wiring.

## Decision

Annotate the `auto_log` **after-line** (the `Execution completed …` line emitted by `Internal::CallLogger`, driven by `auto_log`) with the resolved `tag`/`dimension` facets.

Only the after-line is annotated. Facets resolve at the settled-result point (`Executor#with_logging`'s `ensure` calls `log_after` after `elapsed_time` is settled and before span close), reading the same lazy/memoized `resolved_tags` / `resolved_dimensions` that the span and payload sinks read. The before-line (`About to execute`) runs before resolution, so it carries no facets and is unchanged.

Routing depends on whether the configured logger is a `SemanticLogger` (or `rails_semantic_logger`, which is built on it):

- **Configured logger is a `SemanticLogger`** → forward the facets to its tagged context as **named tags**, so they land as structured log fields (and, for `dimension`, legible Datadog log facets). The plain message is not decorated with a suffix — semantic_logger's own formatter renders named tags.
- **Otherwise** (plain `Logger`, or any non-semantic logger) → append a readable, labeled suffix to the plain message line.

Axn takes **no dependency** on `semantic_logger`. The gem is used only if the *configured logger* is already an instance of it.

### Why gate on the configured logger, not `defined?(SemanticLogger)`

`SemanticLogger.tagged` sets a thread-local context that only a `SemanticLogger` *consumes*. If we gated on the constant merely being defined, an app that loads semantic_logger as a transitive dependency but configures `Axn.config.logger` to a plain `Logger` would set a tagged context nothing reads — the facets would vanish from that line, with no readable suffix to fall back on. Gating on `Axn.config.logger.is_a?(SemanticLogger::Logger)` makes the two paths mutually exclusive and guarantees every annotated line carries the facets somewhere. (If `Rails.logger` is an `ActiveSupport::BroadcastLogger` wrapping a semantic logger, `is_a?` is false and we fall back to the suffix — correct, just not structured.)

## Mechanism

### Executor

`Executor#log_after_at_level` already calls `Internal::CallLogger.log_at_level` and already owns the memoized `resolved_tags` / `resolved_dimensions`. It passes them in via a new `facets:` kwarg, handing **copies** (per constraint) so the log sink can never mutate what the span/payload/`emit_metrics` sinks share:

```ruby
facets: {
  tags: Core::Tagging.dup_facets(resolved_tags),
  dimensions: Core::Tagging.dup_facets(resolved_dimensions),
}
```

Only the after-line passes `facets:`. `log_before` and the class-level async-invocation logging path leave it defaulted (nil/empty), so they are unchanged.

### CallLogger

`log_at_level` gains a `facets:` keyword (default `nil`). When present and non-empty, after the message is assembled but before emit:

1. Build `named_tags`, the namespaced flat merge of both maps — keys mirror the span-attribute convention for cross-sink parity:
   - `tags[:company_id] = 5` → `"axn.tag.company_id" => 5`
   - `dimensions[:plan] = "trial"` → `"axn.dimension.plan" => "trial"`

   Distinct namespaces mean `tag :x` and `dimension :x` coexist without collision (same as the span sink). Values are already coerced to OTLP-legal scalars/arrays by `Core::Tagging.coerce`, so no formatting is needed for the structured path.

2. Route:
   - **Semantic logger** (`defined?(SemanticLogger::Logger) && Axn.config.logger.is_a?(SemanticLogger::Logger)`): wrap the existing emit in `SemanticLogger.tagged(**named_tags) { … }`. The wrapped `action_class.public_send(level, …)` emits inside that thread-local context, so the after-line carries the named tags.
   - **Otherwise**: append a labeled suffix to the message string. Each group is rendered with the existing `format_object` + `MAX_CONTEXT_LENGTH` truncation (reusing `format_context`), and a group is omitted entirely when its map is empty:

     ```
     Execution completed (with outcome: success) in 1.2 milliseconds. Set: {…} [tags: {company_id: 5}] [dimensions: {plan: trial}]
     ```

   The suffix attaches to `message` before the `after:` separator (which `Core::Logging#log` appends), so the `\n------\n` top-level separator still trails the whole line.

When `facets:` is nil or both maps are empty, behavior is byte-for-byte identical to today — no suffix, no wrapper, no `SemanticLogger` reference touched.

## Constraints (from ticket)

- **No `semantic_logger` dependency.** Used only via `is_a?`, guarded by `defined?(SemanticLogger::Logger)`.
- **Respect `MAX_CONTEXT_LENGTH` / formatting.** The readable suffix reuses `format_object` + the existing truncation path per facet group.
- **Hand a copy.** The Executor passes `Core::Tagging.dup_facets(...)`, never the memoized map.

## Non-goals

- Before-line annotation (facets aren't resolved yet at before-time).
- Threading a structured payload through `Core::Logging#log` (would break the plain `Logger` path, which treats a second positional arg differently). The `SemanticLogger.tagged` block leaves `Core::Logging` untouched.
- The remaining deferred sinks from PR #140 (exception-report context/extra, Sidekiq job tags) — separate follow-ups.

## Testing

- **Non-Rails (`spec/`):** with a plain `Logger`, assert the after-line carries `[tags: {…}]` / `[dimensions: {…}]`; empty groups omitted; before-line unchanged; no facets declared → no suffix; truncation honored for oversized values.
- **Semantic-logger path:** with `Axn.config.logger` stubbed to a `SemanticLogger::Logger` double, assert `SemanticLogger.tagged` receives the namespaced named-tags hash and no suffix is appended. If exercising the real gem is warranted, the Rails dummy app (`spec_rails/`) is the place.
- Reuse the `automatic_logging_spec.rb` capture harness for message assertions.

## Docs / CHANGELOG

- `docs/reference/configuration.md` — in the logging / `auto_log` section (and cross-referenced from the tag/dimension docs added in PR #140), note that declared facets annotate the after-line: named tags when the logger is a `SemanticLogger`, a labeled suffix otherwise.
- `CHANGELOG.md` — Unreleased `[FEAT]` entry for auto-log facet annotation.
