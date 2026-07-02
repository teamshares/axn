# Axn tagging (`tag` + `dimension`) — design

**Tickets:** [PRO-2850 — \[Axn\] Support tagging](https://linear.app/teamshares/issue/PRO-2850/axn-support-tagging) (`tag`), [PRO-2852 — \[Axn\] Add `dimension` support for bounded tags](https://linear.app/teamshares/issue/PRO-2852/axn-add-dimension-support-for-bounded-tags) (`dimension`)

**Branch:** `kali/brainstorm-semantic-logging` (off `main` @ #138)

## Problem

os-app once tried to auto-tag its telemetry with domain context and it rotted. `EventHandlers::Base#log` wrapped every log line in `SemanticLogger.tagged({ ddtags: "company_name:…,event:…" })`, intending to correlate event-handler logs with a company/event in Datadog. It never worked — production logged in plain text (nothing parsed the `ddtags`), the parallel `tags:` key written onto `Events::Error` was read by no subscriber, and the whole thing was hand-wired at one call site. [os-app#4976](https://github.com/teamshares/os-app/pull/4976) (PRO-2836) ripped it out as pure cost.

The reusable idea underneath: **an action knows things about its own domain context (which company, which record) that would be valuable as a facet on the telemetry Axn already emits for it** — but wiring that up per-call is exactly what made it rot. Axn is the right layer because it already owns the observability seams (the `axn.call` OpenTelemetry span, the `axn.call` `ActiveSupport::Notifications` event, the `emit_metrics` hook) and can resolve declared facets automatically on every run, including runs inside shared concerns and base classes that no call site touches.

## Decision

Add two class-level macros — **`tag`** and **`dimension`** — that declare domain facets an action contributes to its own observability. Both resolve once per execution and attach to the observability Axn already emits. They differ only in cardinality (and therefore in which sinks they feed):

```ruby
class ChargeCompany
  include Axn
  expects :company

  tag :company_id, -> { company.id }          # high-cardinality → span + payload
  tag(:region) { company.region }             # name + block
  tag company_id: -> { company.id },          # hash: many at once
      plan:       -> { company.plan_tier }

  dimension :plan_tier, -> { company.plan_tier }   # bounded → span + payload + emit_metrics
  dimension environment: -> { Rails.env }
end
```

**Surface-neutral by design.** The resolved key→value maps are not span-specific. This release consumes them at the span, the notification payload, and (for `dimension`) `emit_metrics`, but the maps are the seam for follow-on sinks we intend to build — exception-report context/extra, log annotations (and semantic-logger tagged context *if* it happens to be loaded, without Axn taking a dependency), and Sidekiq job tags. `result.tags` is deliberately **not** a sink: it would collide with a user's `exposes :tags`.

### Naming: `tag` (many) and `dimension` (few)

The bounded-vs-unbounded split is intrinsic, not a metrics quirk: every sink that *indexes* a facet (metric tags, Sentry tags, Sidekiq tags, Datadog log facets) needs bounded values, while sinks that only *attach* a facet (span attributes, Sentry extra, log fields) accept unbounded ones. So there are two populations, and they get two metadata-free macros:

- **`tag`** — high-cardinality / many-valued (`company_id`, record ids). Feeds attach-only sinks (span + payload now; logs and exception extra later).
- **`dimension`** — bounded / few-valued (`plan_tier`, `environment`, `outcome`-like facets). Feeds indexing sinks (`emit_metrics` now; Sentry tags, Sidekiq tags later) *and* the attach-only sinks. The cardinality contract lives in the verb, so no per-tag `metric: true` flag is needed — which is what lets both macros keep the clean multi-key hash form (a per-tag flag would have nowhere to live in the hash form and would be a one-word cardinality footgun).

This means `tag` is high-cardinality, which is the *opposite* of what "tag" denotes in Datadog/Sentry/Sidekiq (where a tag is bounded). We accept that: `tag` (many) / `dimension` (few) reads correctly on its own without anyone needing those tools' vocabulary. The docs neutralize the reversal with an explicit mapping (see Docs).

Boundedness is a *discipline, not an enforced constraint* — Axn cannot know at runtime whether a value is bounded, so `dimension` documents intent and routes to indexing sinks; the user is responsible for only declaring genuinely bounded values as dimensions (the docs carry the cardinality warning that already lives on `emit_metrics`).

## DSL semantics

Both macros share identical parsing and resolution machinery; only the sink routing differs.

**Dual form, mirroring `expose`.** `tag(name, resolver)` (positional pair), `tag(name) { … }` (name + block; block only valid with the single-name form), or `tag(k1: r1, k2: r2)` (hash, many at once) — and the same three forms for `dimension`. Parsing mirrors `Contract#expose` (contract.rb:582): if positional args are present require exactly two and merge `args.first => args.last` into the kwargs hash, then iterate.

**Resolver shapes.** A **proc** (arity 0, `instance_exec`'d on the action so `expects`/`exposes` readers and `result` are in scope), a **symbol** (an action method name), or a **literal** (a static value, e.g. `dimension :region, "us5"`).

**Symbolized keys.** Names are symbolized at declaration (matching the symbol-canonical contract, PRO-2790).

**Inheritance / mixin merge.** Declarations accumulate down the inheritance chain and across included modules; a later declaration of the same key overrides an earlier one. Stored in two separate `class_attribute`s (`_tags`, `_dimensions`) so subclasses inherit and can extend without mutating the parent. This is the property that lets a shared concern or base class contribute a facet with zero call-site wiring — the reuse the os-app approach lacked.

**Same name across both macros is independent.** Because `tag` and `dimension` land in distinct namespaces at every sink (below), declaring `tag :x` and `dimension :x` on the same action is legal and produces two independent facets (`axn.tag.x` and `axn.dimension.x`). No collision guard is needed.

## Resolution and attachment

**Single evaluation point, at span close.** Resolvers (both maps) run in `Executor#with_tracing`'s `ensure`, at the same instant `axn.outcome` is set today (executor.rb:80–94). An OpenTelemetry span is held open for its whole duration and only exported when it ends, and `in_span` does not finish the span until after its block returns — so setting attributes in that `ensure` is exactly how `axn.outcome`/`record_exception` already work. At that instant everything is available at once: inbound readers, outbound readers, `result.outcome`, `result.elapsed_time`, and any exception. So input-derived (`company.abbreviation`) and result-derived (`charge.id`) facets resolve identically — the DSL needs no "when" knob. (Same caveat as `axn.outcome` today: a hard process crash mid-`call` may prevent export.)

**Resolve only when declared.** An action with no `tag`/`dimension` declarations does zero extra work and sets no `payload[:tags]`/`payload[:dimensions]` key at all (the keys are absent, not empty hashes). An action with declarations resolves the relevant map(s) once and feeds every live sink — so the feature is useful even without OpenTelemetry loaded (a plain `ActiveSupport::Notifications` subscriber, or the `emit_metrics` hook, can read the maps).

**Span attribute mapping.** Each facet becomes a span attribute under a namespace matching its macro: `axn.tag.<name>` (e.g. `axn.tag.company_id`) and `axn.dimension.<name>` (e.g. `axn.dimension.plan_tier`). Distinct namespaces prevent collision with framework attributes (`axn.resource`, `axn.outcome`) and let a trace query select exactly the safe-to-group-by set (`axn.dimension.*`).

**Notification payload.** The resolved maps are added to the `axn.call` payload as `payload[:tags]` and `payload[:dimensions]` (plain `{name => value}` hashes, unnamespaced), kept separate so a subscriber can respect the cardinality difference (the span does not care, but an indexing subscriber does).

**`emit_metrics` (dimensions only).** `emit_metrics` is invoked via `call_with_desired_shape` (executor.rb:103), which passes only the kwargs the block declares — so we add a `dimensions:` kwarg (the resolved bounded map) **backward-compatibly**: existing `proc { |resource:, result:| }` blocks are unaffected; a block opts in with `proc { |resource:, result:, dimensions:| }` and decides whether to merge them into its metric tags. `tag`s are **not** passed to `emit_metrics` (they are high-cardinality by definition).

**Value coercion.** OpenTelemetry attributes accept only `String` / `Boolean` / `Integer` / `Float` / arrays of those. Policy applies to both maps: `nil` → skip the facet entirely (this is the conditional-facet escape hatch — a resolver that returns `nil` opts it out for the call, so no `if:` metadata is needed); native types → passed through; anything else → `to_s`. The payload/`emit_metrics` maps carry the same coerced values, for consistency across sinks. Docs will steer users to return primitives (`company.id`, not `company`); `to_s` on a record is useless output but never raises.

**Per-facet isolation / raise-safety.** Each resolver is invoked independently. One that raises is swallowed via `Internal::PipingError.swallow` and skipped; the remaining facets still land. This is why per-facet declaration beats a single block-returning-a-hash: one bad resolver can't nuke the whole set for telemetry nobody is watching closely. Resolution is on the settled-result (outside) path and must never itself raise.

## Scope / non-goals

- **Exception-report, logging, and Sidekiq-tag sinks are not built here.** They are the reason the resolved maps are surface-neutral, but each is its own follow-up. So `dimension`'s indexing-sink set is `emit_metrics` only for now; Sentry/Sidekiq tags come later, additively. Notably, ActiveJob has no native tag concept — for pure-ActiveJob the span-attribute path already covers APM job spans; the dedicated Sidekiq-tags sink is Sidekiq-only.
- **No `expects … tag:` sugar.** It would only cover input-derived facets, couple the contract to observability, and introduce an arity-1 resolver shape inconsistent with the arity-0 block form. The hash form already makes the common case a one-liner.
- **No `result.tags` accessor** (collides with `exposes :tags`).
- **Boundedness is not enforced** for `dimension` — it is a documented discipline (see Naming).

## Implementation surface

- New `lib/axn/core/tagging.rb` (module `Axn::Core::Tagging`): `included` hook defines the `_tags` and `_dimensions` `class_attribute`s (default `{}` each); `ClassMethods#tag` and `#dimension` parse the shared dual form and merge into the respective attribute. Included into the action base alongside the other `Core::*` concerns. The resolution helper (instance_exec / symbol / literal, per-facet rescue, nil-skip, coercion) lives here, parameterized by which map, not inlined in the executor.
- `lib/axn/executor.rb` — in `with_tracing`, resolve `_tags` and `_dimensions` once each (guarded on "any declared"), coerce, set `axn.tag.<name>` / `axn.dimension.<name>` span attributes in the existing `ensure`, add `payload[:tags]` / `payload[:dimensions]`, and pass `dimensions:` into the `emit_metrics` `call_with_desired_shape` kwargs.
- Docs (below).

## Testing

Specs in `spec/` (non-Rails) using an in-memory OpenTelemetry span exporter (follow the existing tracing specs' harness). Cover both macros:

- **Resolution + mapping:** declared `tag`s → `axn.tag.<name>` span attributes + `payload[:tags]`; declared `dimension`s → `axn.dimension.<name>` span attributes + `payload[:dimensions]` + the `emit_metrics` `dimensions:` kwarg. proc/symbol/literal/block forms all work.
- **Dual form:** positional pair, single-name-with-block, and hash-of-many declare the same way, for both macros.
- **Independent namespaces:** `tag :x` and `dimension :x` on one action produce both `axn.tag.x` and `axn.dimension.x` without collision.
- **`emit_metrics` backward compat:** a `proc { |resource:, result:| }` block still works untouched; a `proc { |resource:, result:, dimensions:| }` block receives the bounded map; `tag`s are never passed to `emit_metrics`.
- **nil-skip:** a resolver returning `nil` omits that facet (attribute, payload key, and — for a dimension — the `emit_metrics` entry) without error.
- **Per-facet isolation:** a resolver that raises is swallowed and skipped; sibling facets still land; the call's result is unaffected.
- **Inheritance/mixin merge:** subclass and included-module facets accumulate; same-key override wins (independently for tags and dimensions).
- **Coercion:** `Integer`/`Float`/`Boolean`/`String` pass through; other objects `to_s`.
- **No-OpenTelemetry path:** with OpenTelemetry absent, `payload[:tags]`/`payload[:dimensions]` and the `emit_metrics` `dimensions:` kwarg are still populated and nothing raises.
- **Zero-overhead path:** an action with no declarations resolves nothing and sets no `payload[:tags]`/`payload[:dimensions]` keys (assert the keys are absent).

## Docs

- `docs/reference/configuration.md` — in the OpenTelemetry Tracing section, document `tag` and `dimension`, the `axn.tag.<name>` / `axn.dimension.<name>` attribute mappings, the `payload[:tags]` / `payload[:dimensions]` seams, and the resolver/coercion/nil-skip rules. In the `emit_metrics` section, document the new `dimensions:` kwarg with an updated example merging it into metric tags. Include the cardinality mapping note: *an Axn `tag` becomes a span attribute / log field / exception detail (high-cardinality OK); an Axn `dimension` becomes a metric tag / Sentry tag / Sidekiq tag (must be bounded)*.
- `docs/recipes/datadog-dashboards.md` — mention that `dimension` lets an action contribute its own bounded metric tags (feeding the `emit_metrics` schema the recipe already builds on), and that `tag` adds high-cardinality per-call span facets to filter traces by.
- `CHANGELOG.md` — Unreleased entry for `tag` and `dimension`.
