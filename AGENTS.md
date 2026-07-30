# AGENTS.md

Guidance for agents working in **Axn**. Read before writing code.

## The bar

Axn is the base layer for service objects — the `expects` / `exposes` / `call` contract that
business logic is written against. It's infrastructure, not app code: a subtle bug here is a bug
everywhere.

North star: **Axn should be good enough to belong in Rails itself** — the obvious default for
service objects, the way `ActiveRecord` is for persistence. Write every line as if headed for
`rails/rails` as an `ActiveAction`. In priority order:

1. **Correctness** — prove behavior with tests; reason about edges explicitly.
2. **A predictable base layer** — surprising behavior is a defect even when "working as coded."
3. **An interface that feels inevitable** — optimize for the reader of the *calling* code, then for
   clear failure messages, then for our own convenience — in that order.

Concise, elegant Ruby is the means; cleverness that costs clarity or predictability is not elegant.

We're in **alpha with internal (Teamshares) users only**, iterating deliberately *so that* we can
cut a stable mainline release. So: breaking changes are acceptable now but never casual — make them
on purpose, document them, and prefer additive designs that won't need breaking later. The habits
that earn a stable base (backward-compatible seams, deprecation over removal) start now.

## Non-negotiables

- **Works outside Rails.** No hard dependency on Rails being loaded — guard every Rails/ActiveRecord
  reference with `defined?(...)`. `spec/` runs without Rails; `spec_rails/dummy_app/` is the Rails
  app. Rails-adjacent changes are tested in **both**.
- **TDD** (`CONTRIBUTING.md`): failing test first, then implementation. Bugfixes start with a
  reproducing test.
- **Reuse the seams** — `FieldResolvers` (`:extract`/`:model`), the memoization helpers,
  `resolve_parent`, the `*_field_configs` collections. A parallel path is a new thing to keep
  consistent forever.
- **Tool registry** — `tool` DSL / `Axn.tools_for(:adapter)` / `tool_name` (`Axn::Core::Tools`, `Axn::Tools::Registry`) own tool membership and naming; adapters consume them, never re-derive names or re-list members.
- **Additive at the seam.** Extending a config/option keeps the existing canonical key/behavior
  identical and adds the new axis alongside, so existing consumers are untouched.

## Ruby style (the conventions a linter won't catch)

Formatting is enforced in CI — match the surrounding code and don't spend effort on it. Beyond that:

- Endless methods for one-liners (`def call = expose(...)`); `Data.define` for value objects.
- Internal helpers prefixed `_`; framework state double-underscored (`@__context`) so user actions
  can't clobber it; internal-only classes under `Axn::Internal`.
- Refactor before exceeding a metric limit; if genuinely unavoidable, add a **scoped**
  `# rubocop:disable <Cop>`, never a blanket one.

## Namespace policy

Sibling gems own their own `Axn::<GemName>` namespace (`Axn::Webhooks`, `Axn::MCP`, `Axn::RubyLLM`) — core never defines constants there.

axn-core reserves the top-level public constants (`Result`, `Failure`, `Factory`, `FormObject`, `Configuration`, `RailsConfiguration`, `Strategies`, and the exception classes) plus the module namespaces `Core`, `Internal`, `Async`, `Extensions`, `Tools`, `Reflection`, `Validation`, `Configurable`, `Mountable`, `Extras`, `FieldDeclarations`, `Testing`, `Util`.

`Axn::Extensions` is the extension-author surface (for gems building on axn — e.g. `Axn::Extensions.best_effort`, `Axn::Extensions.config`, `Axn::Extensions::Serialization.render`), distinct from `Axn::Internal` (private) and the user-facing DSL. `Axn::Core` holds action-assembly and runtime machinery (`Executor`, the context-facade family); it is not a public surface.

## DSL & API patterns

- **Fail at declaration, not runtime.** DSL misuse (bad option combos, reserved names, collisions)
  `raise`s when the class is *defined*, with a message saying how to fix it. Never silently ignore
  an option.
- **Programmer error vs bad data.** Impossible declarations / contradictory calls → `ArgumentError`
  or `InboundValidationError` (dev-facing). Malformed runtime input a caller could legitimately send
  → contract validation. Pick the error by who's at fault.
- **Inferred behavior defers; explicit conflicts raise.** Anything Axn generates automatically (a
  derived reader, an applied default) yields to a same-named thing the user wrote, leaving a `debug`
  breadcrumb — it never clobbers silently. A conflict between two things the user *explicitly*
  declared raises loudly.
- **Don't force false uniformity, but do fix real inconsistency.** Paths may differ when inputs
  differ (symbol-keyed kwargs vs indifferent-access nested data). But a value with a uniform
  *meaning* (`<field>_id` is always the primary key) must be honored on every path, blank/edge
  inputs included.
- **A guard derives from what its consumer emits; it never predicts it.** When a check must agree
  with a projection — the property-name rules against `Reflection::Schema`'s emitted properties, say
  — read the consumer's own output or call the consumer's own decision (`Schema.shape_property_plan`,
  `Schema.build_input_for`), rather than re-deriving the answer beside it. A predictor is wrong in two
  directions at once and both are worse than a late diagnosis: it misses what the consumer emits by a
  path the predictor doesn't know, and it *rejects legal declarations* the consumer would never emit
  at all. Five separate defects on one PR shared that root, and each seam-by-seam fix generated the
  next one until the predictor was deleted. This is also why a check may legitimately fire later than
  declaration: if only the emitted schema reveals a collision, the honest promise is "before anything
  can consume it" (at app setup for tools, via `Axn.validate_tool_contracts!`), not "at declaration".
- **Canonicalizing a value obliges you to re-audit every guard that read the raw form.** Symbolizing
  keys, defaulting an absent list to `[]`, normalizing a name — each silently disarms any downstream
  check that distinguished what you just erased. Three regressions on one PR: `[]`-for-absent hid
  `ShapeValidator`'s "must supply :members"; String-keyed option bags hid `_reject_model_transform!`
  and made `FieldOptionality#optional?` answer `false` for a declared `allow_blank`, publishing a
  wrong `required` list that adapters build tool definitions from. Enumerate the consumers of both
  forms in the same commit, and say which still fire.
- **An optimization that returns the caller's object unchanged is an aliasing bug.** A fast path
  skipping work because "nothing needs changing" answers a different question than "nothing needs
  copying" — a declared contract must be axn's own, so mutating what the caller still holds cannot
  change it retroactively.

## Errors

Reuse the hierarchy in `lib/axn/exceptions.rb`; don't invent ad-hoc classes. Every `message`
explains the problem **and** the fix (see `UnknownExposure`). New messages meet that bar.

`Axn::Extensions.best_effort` guards a **side channel** — a log line, a span update, a metrics block, an error report — and swallows `StandardError` plus `SWALLOWABLE_BEYOND_STANDARD_ERROR`, so nothing in it can take down the call it observes. Pass `standard_errors_only: true` only when letting a non-`StandardError` escape is genuinely better than swallowing it — which requires BOTH that no side effect is already committed at that point AND that an executor boundary will settle the escape into a reported result rather than re-raising. Resolving a `model:` record qualifies: it runs inside its own action's validation, so a runaway finder surfaces as a reported exception result naming the real stack instead of a misleading "can't be blank". A post-fan-out `on_enqueue_all` callback does not: jobs are already enqueued and the orchestrator is itself an async job whose adapter re-raises an exception outcome, so an escape gets the batch enqueued twice. Two further rules keep this from going wrong: apply the flag at exactly ONE layer per callable, the layer that invokes it (`Handlers::Invoker` owns the policy for everything it dispatches, so callbacks/matchers/messages must not re-guard on top of it); and never let a site's behavior depend on which error class a callable raised — if `StandardError` is swallowed and skipped there, a `SystemStackError` must be too. `SWALLOWABLE_BEYOND_STANDARD_ERROR` is also what `Core::Executor` may settle onto a result (via `Extensions.swallowable?`), so it is the single answer to "what will axn ever swallow". Keep it an allowlist and widen it only for a class that is unambiguously a fault in the code being run: the non-`StandardError` set is open-ended (any gem can define a direct `Exception` subclass), and members like `Timeout::ExitException` and `ActiveSupport::ErrorReporter::UnexpectedError` exist precisely so nothing swallows them. Absorbing one silently breaks whatever it signals, which is far harder to trace than an unrecognized bug escaping `.call`.

Separate the caller code a walk **requires** from caller code invoked while **reporting** a failure. The first is unavoidable — rendering a value calls its `to_s`/`as_json`, walking a container calls its `each` — and a value that lies there changes what we decide, which is the caller's own problem. The second is different in kind: an `inspect`, a `class`, an `is_a?`, or a `-@` called to build the message can raise and *replace* the failure with the caller's exception, and if that exception is outside `StandardError` it escapes the adapter's `rescue` — reinstating exactly what the error existed to prevent. So in a serialization or reflection error path, derive what the message needs without dispatching: describe a value by `Object.instance_method(:class).bind_call(it)` rather than `it.class` or `it.inspect`, and write type tests as `case`/`when` (`Module#===` is a C-level check) rather than `is_a?`, which a value can override to route around a guard. A fast path that adds a dispatch the work does not require — skipping an allocation by asking a key what class it is — is not worth it. Four layers hold this property: `Reflection::Values`, `Reflection::PropertyNames`, `Internal::ShapeGraph`, and the contract's declaration walk — including the option-container copy, where `Kernel#dup`, `Hash#each` and the copy's own element reads are BOUND rather than dispatched, so simplifying one back to a plain `.dup`/`.each` reopens an aliased contract. Separately, every layer that writes a declared NAME into prose routes it through `PropertyNames.inspect_field_name`/`renderable_label` — the contract's declaration errors, `shape_validator`, `subfield_contradictions`, `call_logger` — so no message renders a name by running the name's own code. Four dispatches were examined and deliberately left: the runtime redaction walk type-tests caller DATA (`is_a?`, `dup`) on every logged call, `Array(klass)` dispatches `to_a` on a caller value, `shape_validator` reports `got #{source.class}`, and `subfield_contradictions` lists declared type branches with `#inspect`. Caller data is a different category from an error path: there the dispatch IS the work (rendering a value requires its `to_s`), it runs per call inside `best_effort`/`CycleGuard`, and a value that lies degrades a log line or masks more than necessary — it does not replace a verdict with an exception that escapes the rescue meant to settle it.

Any code that recurses through caller-supplied Hash/Array values must cycle-guard with `Axn::Internal::CycleGuard.guard` (a self-referential value is a `SystemStackError`, which is outside `StandardError` and so escapes the whole result path). For third-party code that recurses and can't be guarded from inside — `ActiveSupport::ParameterFilter` — rescue `SystemStackError` and retry on `CycleGuard.decycle(data)`, so acyclic data pays for neither the extra walk nor the copy.

## Testing

- Cover happy path, guard/raise paths, and awkward edges (blank vs nil vs absent, aliasing, nesting,
  both-supplied conflicts) — that's where base-layer bugs hide.
- Use `Axn::Testing::SpecHelpers`' `build_axn { ... }`. Non-Rails specs use plain POROs with a
  finder for `model:` behavior; mirror Rails-specific behavior in `spec_rails/dummy_app/`.
- Run `bundle exec rspec` and the relevant `spec_rails` specs; verify against real output before
  claiming done.

## Changes & compatibility

- **CHANGELOG every user-visible change** under `## Unreleased`, tagged `[FEAT]` / `[BREAKING]` /
  `[BUGFIX]` / `[INTERNAL]` — dense and specific (what, why, edge behavior), matching the prevailing
  detail level.
- **`[BREAKING]`**: state old vs new explicitly; if a silent old behavior becomes a raise, say so
  loudly. Prefer a non-breaking design when one exists.
- **Pre-alpha: remove dead kwargs outright, no tombstone.** A removed option is simply *gone* from
  the signature — passing it yields a plain unknown-key/option `ArgumentError`, not a curated "has
  been removed" message. A tombstone (a removed kwarg kept solely to raise a helpful upgrade error)
  earns its keep only *after* a public/stable release, when a user might carry an old kwarg across an
  upgrade; reintroduce deprecation tombstones then. This is distinct from **misuse guards**
  (`method_call: true` without `on:`, dotted-name rejections, reserved-name/collision checks), which
  guard *live* behavior over current options and always stay ("fail at declaration, with a fix").
- **Comments explain *why*, not *what*** — justify the non-obvious choice; skip comments that restate
  the code.

## Docs & planning artifacts

`docs/` is the **published VitePress site** (CI deploys it — see `.github/workflows/docs.yml`), so
nothing internal belongs there. Brainstorming specs and implementation plans — including anything the
`superpowers` skills generate — go in `internal-docs/specs/` and `internal-docs/plans/`, **never**
under `docs/`. (This is the location preference the `writing-plans` / `brainstorming` skills defer to.)

## Creating a downstream gem

Scaffold a new axn-consuming gem with `bin/new-gem NAME` (dev-only, run from a checkout) rather than
copying an existing gem — it lays down the canonical, drift-free boilerplate (`bin/refresh`/`bin/setup`,
release-gated `Rakefile`, CI, gemspec, `Axn::Configurable` config stub + `deprecator`, `AGENTS.md`).
Defaults to axn's works-with-and-without-Rails shape (non-Rails `spec/` + a `spec_rails/dummy_app`
suite; `--rails-only` / `--no-rails` for the other topologies). Generated gems `inherit_gem` core's
`.rubocop.yml` (internal convention, not a documented public API). Any gem it creates as a sibling of
this checkout is auto-picked-up by `rake downstream:check`.

Core's `.rubocop.yml` declares `inherit_mode: merge: Exclude` on behalf of those gems, not for itself:
an `AllCops/Exclude` array replaces RuboCop's built-in one, and inherited globs resolve relative to the
axn gem dir, so without the merge every consuming gem loses the built-in excludes that pointed at its
own tree — and CI lints its vendored bundle, dying on plugins a dependency's `.rubocop.yml` requires.
`spec_rubocop/shared_config_spec.rb` guards this end-to-end; don't remove the merge to tidy the config.

## Review feedback

Fresh-context, adversarial review catches real base-layer bugs. Verify each point against the code —
don't reflexively agree or dismiss. Disagree with evidence; when a reviewer is right, fix it and add
the regression test. "Fixed" is true only once that test passes.
