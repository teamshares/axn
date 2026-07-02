# Axn tagging (`tag`) — design

**Ticket:** [PRO-2850 — \[Axn\] Support tagging](https://linear.app/teamshares/issue/PRO-2850/axn-support-tagging)

**Follow-up ticket (out of scope here):** [PRO-2852 — \[Axn\] Add `dimension` support for bounded tags](https://linear.app/teamshares/issue/PRO-2852/axn-add-dimension-support-for-bounded-tags)

**Branch:** `kali/brainstorm-semantic-logging` (off `main` @ #138)

## Problem

os-app once tried to auto-tag its telemetry with domain context and it rotted. `EventHandlers::Base#log` wrapped every log line in `SemanticLogger.tagged({ ddtags: "company_name:…,event:…" })`, intending to correlate event-handler logs with a company/event in Datadog. It never worked — production logged in plain text (nothing parsed the `ddtags`), the parallel `tags:` key written onto `Events::Error` was read by no subscriber, and the whole thing was hand-wired at one call site. [os-app#4976](https://github.com/teamshares/os-app/pull/4976) (PRO-2836) ripped it out as pure cost.

The reusable idea underneath: **an action knows things about its own domain context (which company, which record) that would be valuable as a facet on the telemetry Axn already emits for it** — but wiring that up per-call is exactly what made it rot. Axn is the right layer because it already owns the observability seams (the `axn.call` OpenTelemetry span, the `axn.call` `ActiveSupport::Notifications` event, the `emit_metrics` hook) and can resolve declared facets automatically on every run, including runs inside shared concerns and base classes that no call site touches.

## Decision

Add a class-level **`tag`** macro that declares domain facets an action contributes to its own observability. Tags are resolved once per execution and attached to the `axn.call` OpenTelemetry span (as attributes) and to the `axn.call` `ActiveSupport::Notifications` payload. High-cardinality values (`company_id`, record ids) are expected and fine — a span attribute is designed to be a per-call search facet.

```ruby
class ChargeCompany
  include Axn
  expects :company

  tag :company_id, -> { company.id }          # name + resolver
  tag(:region) { company.region }             # name + block
  tag company_id: -> { company.id },          # hash: many at once
      plan:       -> { company.plan_tier }
end
```

**Surface-neutral by design.** The resolved key→value map is not span-specific. This release consumes it at two sinks (span attributes + notification payload), but the map is the seam for a set of follow-on sinks we intend to build — exception-report context/extra, log annotations (and semantic-logger tagged context *if* it happens to be loaded, without Axn taking a dependency), and Sidekiq job tags. `result.tags` is deliberately **not** a sink: it would collide with a user's `exposes :tags`.

### Naming: `tag` (many) now, `dimension` (few) reserved

The bounded-vs-unbounded split is intrinsic, not a metrics quirk: every sink that *indexes* a facet (metric tags, Sentry tags, Sidekiq tags, Datadog log facets) needs bounded values, while sinks that only *attach* a facet (span attributes, Sentry extra, log fields) accept unbounded ones. So there are two populations, and they get two metadata-free macros:

- **`tag`** (this release) — high-cardinality / many-valued. Feeds attach-only sinks (span attributes now; logs and exception extra later).
- **`dimension`** (reserved, PRO-2852) — bounded / few-valued. Feeds indexing sinks (`emit_metrics`, Sentry tags, Sidekiq tags) *and* attach-only sinks. The cardinality contract lives in the verb, so no per-tag `metric: true` flag is needed — which is what lets both macros keep the clean multi-key hash form (a per-tag flag would have nowhere to live in the hash form and would be a one-word cardinality footgun).

This means `tag` is high-cardinality, which is the *opposite* of what "tag" denotes in Datadog/Sentry/Sidekiq (where a tag is bounded). We accept that: `tag` (many) / `dimension` (few) reads correctly on its own without anyone needing those tools' vocabulary. The docs neutralize the reversal with an explicit mapping (see Docs).

## DSL semantics

**Dual form, mirroring `expose`.** `tag(name, resolver)` (positional pair), `tag(name) { … }` (name + block; block only valid with the single-name form), or `tag(k1: r1, k2: r2)` (hash, many at once). Parsing mirrors `Contract#expose` (contract.rb:582): if positional args are present require exactly two and merge `args.first => args.last` into the kwargs hash, then iterate.

**Resolver shapes.** A **proc** (arity 0, `instance_exec`'d on the action so `expects`/`exposes` readers and `result` are in scope), a **symbol** (an action method name), or a **literal** (a static value, e.g. `tag :region, "us5"`).

**Symbolized keys.** Tag names are symbolized at declaration (matching the symbol-canonical contract, PRO-2790).

**Inheritance / mixin merge.** Declarations accumulate down the inheritance chain and across included modules; a later declaration of the same key overrides an earlier one. Stored in a `class_attribute` so subclasses inherit and can extend without mutating the parent. This is the property that lets a shared concern or base class contribute a tag with zero call-site wiring — the reuse the os-app approach lacked.

## Resolution and attachment

**Single evaluation point, at span close.** Resolvers run in `Executor#with_tracing`'s `ensure`, at the same instant `axn.outcome` is set today (executor.rb:80–94). An OpenTelemetry span is held open for its whole duration and only exported when it ends, and `in_span` does not finish the span until after its block returns — so setting attributes in that `ensure` is exactly how `axn.outcome`/`record_exception` already work. At that instant everything is available at once: inbound readers, outbound readers, `result.outcome`, `result.elapsed_time`, and any exception. So input-derived (`company.abbreviation`) and result-derived (`charge.id`) tags resolve identically — the DSL needs no "when" knob. (Same caveat as `axn.outcome` today: a hard process crash mid-`call` may prevent export.)

**Resolve only when tags are declared.** An action with no `tag` declarations does zero extra work and sets no `payload[:tags]` key at all (the key is absent, not an empty hash). An action with tags resolves the map once and feeds both live sinks — so the feature is useful even without OpenTelemetry loaded (a plain `ActiveSupport::Notifications` subscriber can read `payload[:tags]`).

**Span attribute mapping.** Each tag becomes a span attribute keyed `axn.tag.<name>` (e.g. `axn.tag.company_id`). The `axn.tag.` namespace prevents collision with framework attributes (`axn.resource`, `axn.outcome`) and with other instrumentation, and makes the origin self-evident in the trace UI.

**Notification payload.** The resolved map is added to the `axn.call` payload as `payload[:tags]` (a plain `{name => value}` hash, unnamespaced), consumable by any `ActiveSupport::Notifications` subscriber and by the future metrics/logging sinks.

**Value coercion.** OpenTelemetry attributes accept only `String` / `Boolean` / `Integer` / `Float` / arrays of those. Policy: `nil` → skip the attribute entirely (this is the conditional-tag escape hatch — a resolver that returns `nil` opts that tag out for the call, so no `if:` metadata is needed); native types → passed through; anything else → `to_s`. The payload hash carries the same coerced values, for consistency across sinks. Docs will steer users to return primitives (`company.id`, not `company`); `to_s` on a record is useless output but never raises.

**Per-tag isolation / raise-safety.** Each resolver is invoked independently. One that raises is swallowed via `Internal::PipingError.swallow` and skipped; the remaining tags still land. This is why per-tag declaration beats a single block-returning-a-hash: one bad resolver can't nuke the whole set for telemetry nobody is watching closely. Resolution is on the settled-result (outside) path and must never itself raise.

## Scope / non-goals

- **`dimension` (PRO-2852) is not built here.** Only the metadata-free naming rule and the reserved verb are established. `emit_metrics` is a global-config proc that does not currently receive per-action tags; wiring a bounded sink into it is separable plumbing.
- **Exception-report, logging, and Sidekiq-tag sinks are not built here.** They are the reason the resolved map is surface-neutral, but each is its own follow-up. Notably, ActiveJob has no native tag concept — for pure-ActiveJob the span-attribute path already covers APM job spans; the dedicated Sidekiq-tags sink is Sidekiq-only.
- **No `expects … tag:` sugar.** It would only cover input-derived tags, couple the contract to observability, and introduce an arity-1 resolver shape inconsistent with the arity-0 block form. The hash form already makes the common case a one-liner.
- **No `result.tags` accessor** (collides with `exposes :tags`).

## Implementation surface

- New `lib/axn/core/tagging.rb` (module `Axn::Core::Tagging`): `included` hook defines the `_tags` `class_attribute` (default `{}`); `ClassMethods#tag` parses the dual form and merges into `_tags`. Included into the action base alongside the other `Core::*` concerns.
- `lib/axn/executor.rb` — in `with_tracing`, resolve `@action_class._tags` once (guarded on "any declared"), coerce, set `axn.tag.<name>` span attributes in the existing `ensure`, and add `payload[:tags]`. Resolution helper (instance_exec / symbol / literal, per-tag rescue, nil-skip, coercion) lives with the tagging code, not inlined in the executor.
- Docs (below).

## Testing

Specs in `spec/` (non-Rails) using an in-memory OpenTelemetry span exporter (follow the existing tracing specs' harness):

- **Resolution + mapping:** declared tags appear as `axn.tag.<name>` span attributes and in `payload[:tags]`; proc/symbol/literal resolver forms all work; block form works.
- **Dual form:** positional pair, single-name-with-block, and hash-of-many all declare the same way.
- **nil-skip:** a resolver returning `nil` omits that attribute (and payload key) without error.
- **Per-tag isolation:** a resolver that raises is swallowed and skipped; sibling tags still land; the call's result is unaffected.
- **Inheritance/mixin merge:** subclass and included-module tags accumulate; same-key override wins.
- **Coercion:** `Integer`/`Float`/`Boolean`/`String` pass through; other objects `to_s`.
- **No-OpenTelemetry path:** with OpenTelemetry absent, `payload[:tags]` is still populated and nothing raises.
- **Zero-overhead path:** an action with no `tag` declarations resolves nothing and sets no `payload[:tags]` key (assert the key is absent).

## Docs

- `docs/reference/configuration.md` — in the OpenTelemetry Tracing section, document `tag`, the `axn.tag.<name>` attribute mapping, the `payload[:tags]` seam, and the resolver/coercion/nil-skip rules. Include the cardinality mapping note: *an Axn `tag` becomes a span attribute / log field / exception detail (high-cardinality OK); a future Axn `dimension` becomes a metric tag / Sentry tag / Sidekiq tag (must be bounded)*.
- `docs/recipes/datadog-dashboards.md` — mention that `tag` adds per-call span facets you can filter traces by (distinct from the bounded metric tags that recipe already covers).
- `CHANGELOG.md` — Unreleased entry for `tag`.
