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

## Errors

Reuse the hierarchy in `lib/axn/exceptions.rb`; don't invent ad-hoc classes. Every `message`
explains the problem **and** the fix (see `UnknownExposure`). New messages meet that bar.

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

## Review feedback

Fresh-context, adversarial review catches real base-layer bugs. Verify each point against the code —
don't reflexively agree or dismiss. Disagree with evidence; when a reviewer is right, fix it and add
the regression test. "Fixed" is true only once that test passes.
