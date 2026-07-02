# Axn log annotation + facet resolution phases — design

**Ticket:** [PRO-2854 — \[Axn\] Annotate log lines with tag/dimension facets](https://linear.app/teamshares/issue/PRO-2854/axn-annotate-log-lines-with-tagdimension-facets)

**Foundation:** [PR #140](https://github.com/teamshares/axn/pull/140) (merged, unreleased) — the `tag`/`dimension` facet system ([PRO-2850](https://linear.app/teamshares/issue/PRO-2850/axn-support-tagging) / [PRO-2852](https://linear.app/teamshares/issue/PRO-2852/axn-add-dimension-support-for-bounded-tags)). This design **revises #140's resolution timing and DSL** (safe: nothing is released yet). Predecessor: [os-app#4976](https://github.com/teamshares/os-app/pull/4976).

## Problem

PR #140 resolved every `tag`/`dimension` facet once, at settle-time, so resolvers could read the settled result. That was the right call for the span / payload / `emit_metrics` sinks, but it permanently forecloses the original os-app goal: tagging an action's **in-flight log lines** with its domain context (so every `log`/`info` during `call` carries `company_id` etc.). In-flight tagging needs the facets resolved *before* the body runs — which settle-time resolution can't provide.

Since most facets are input-derived in practice (`company.id`, record ids), and since result-derived resolution can't reach in-flight logs, defaulting to settle-time backs us into a corner we can't leave without a breaking change. This design introduces a per-facet **resolution phase** so the common case (input-derived) resolves early and the rare case (result-derived) opts in — decided now, while unreleased.

## Two orthogonal axes

A facet is described by two independent choices:

- **Cardinality** (`tag` vs `dimension`, from #140): governs sink routing. `dimension` is bounded and additionally feeds `emit_metrics`. Unchanged.
- **Resolution phase** (`:input` default, `:result` opt-in, new): governs *when* the resolver runs and whether it can reach in-flight logs.

Any facet is one of {tag, dimension} × {input, result}.

## DSL

Drop the multi-key hash form (`tag a: ->{}, b: ->{}`). Keep name+resolver and name+block; add a per-facet `result:` flag. With the hash form gone, keyword args unambiguously mean modifiers, and the parser simplifies.

```ruby
tag :company_id, -> { company.id }                     # input phase (default)
dimension(:plan_tier) { company.plan_tier }            # input phase (default)
tag :charged_cents, -> { charged_cents }, result: true # result phase (reads a settled output)
```

Each `tag`/`dimension` call now declares exactly one facet. The removed hash form (both `a: ->{}` symbol-key and `"a" => ->{}` hashrocket) now raises `ArgumentError`.

## Resolution timing

- **Input facets** resolve eagerly, right after inbound validation/defaults (inputs are canonical), lazily memoized. If the body never runs (inbound validation failure), they resolve lazily at settle instead — inputs are present either way.
- **Result facets** resolve at settle (today's timing).
- Each facet resolves **exactly once** — its phase selects the single pass it runs in. No double-resolution.

Storage: `_tags` / `_dimensions` map `name → Facet(resolver:, result:)` (a `Data`). `Core::Tagging.resolve(facets, action:, phase:)` filters by phase and returns the coerced `name → value` map for that phase.

## Sink routing

| Sink | Input facets | Result facets |
|---|---|---|
| Span attrs / payload / `emit_metrics` | ✓ | ✓ |
| Auto-log **completion line** | ✓ | ✓ |
| **In-flight logs** during `call` (semantic_logger only) | ✓ | ✗ (unresolved when the line fires) |

The span, payload, `emit_metrics`, and completion line all read the **merged** (input+result) maps at settle — the same read sites as #140, now unioning both phases. `resolved_tags` = `resolved_input_tags.merge(resolved_result_tags)` (and likewise dimensions).

The new capability is **in-flight tagging**: when the configured logger is a `SemanticLogger`, the executor wraps the body (`with_hooks { call }`) in `SemanticLogger.tagged(**input_named_tags)`, so every log line emitted during `call` inherits the input-phase facets as named tags (`axn.tag.<name>` / `axn.dimension.<name>`). Result facets can't reach those lines — they don't exist yet when the lines fire.

The completion line gets its own tagged context (all facets) at emit time in `CallLogger`; the body context has already closed by then, so there's no double-nesting.

## Footgun (documented, non-crashing)

Default input means a resolver reading a settled output without `result: true` resolves early and yields `nil` → the facet is silently omitted (per-facet swallow via `PipingError`, no crash). Docs steer: "reads only inputs? leave it; reads an exposed/result value? mark `result: true`."

## Mechanism

- **`Core::Tagging`**: `Facet` data type; single-facet parser (no hash form) with `result:`; `resolve(..., phase:)`; `namespaced(tags:, dimensions:)` builds the symbol-keyed `axn.tag.*` / `axn.dimension.*` named-tags hash (shared by the body context and the completion line).
- **`Executor`**: split `resolved_input_tags` / `resolved_result_tags` (+ dimensions), memoized; `resolved_tags` / `resolved_dimensions` return the merge (unchanged read sites). New `with_facet_log_context` wraps the body invocation inside `with_contract` (after inbound validation) in `SemanticLogger.tagged` when the logger is semantic and input facets exist. `log_facets` (for the completion line) hands `dup_facets` copies of the merged maps.
- **`Internal::CallLogger`**: `semantic_logger?` made public (executor reuses it); completion-line annotation uses `Core::Tagging.namespaced`; unchanged otherwise (named tags under a SemanticLogger, labeled suffix respecting `MAX_CONTEXT_LENGTH` otherwise).

## Constraints (from ticket, still honored)

- No `semantic_logger` dependency — used only via `is_a?`, guarded by `defined?`.
- Readable suffix reuses `format_object` + `MAX_CONTEXT_LENGTH` truncation.
- Copies (`Core::Tagging.dup_facets`), never the memoized maps, cross the sink boundary.

## Testing

- **DSL** (`spec/axn/core/tagging_spec.rb`): new single-facet forms; `result:` default/override; removed hash form raises.
- **Resolution phase** (`spec/axn/internal/tracing/tagging_spec.rb` + a new phase spec): input facet resolved from inputs; result facet reads a settled output; an unmarked result-reading resolver yields nil.
- **In-flight + completion-line logs** (`spec/axn/internal/call_logger_facets_spec.rb`, stubbed): input facets tag in-flight lines; result facets only the completion line; suffix path unaffected.
- **Real SemanticLogger** (`spec_rails/dummy_app/.../call_logger_facets_spec.rb`): real `SemanticLogger::Logger`, capture in-flight + completion events, assert phase routing.

## Docs / CHANGELOG

- `docs/reference/configuration.md` — drop the hash form; document the `result:` flag, the phase/timing model, in-flight vs completion-line tagging, and the nil-on-early footgun.
- `CHANGELOG.md` — update the #140 Unreleased entry (DSL/timing revised) and the facet-log-annotation entry.

## Scope note

The phase axis is broader than PRO-2854's "annotate log lines" title. It's landed here because in-flight tagging is what motivates it and it revises the same just-merged code; flag whether it warrants a companion ticket for tracking.
