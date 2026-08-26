# AGENTS.md

Guidance for agents working in **Axn**. Read before writing code.

This file governs axn-core itself. Two siblings cover adjacent work: read `AGENTS-consuming.md`
before building or maintaining a gem that depends on axn; read `AGENTS-tool-adapters.md` before
touching a tool adapter (`Axn::Tools`, `tool_roots`, `Invoker`/`Axn::Extensions.owned_failure?`).

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
- **Tool registry** — `tool` DSL / `Axn::Tools.for(:adapter)` / `tool_name` (`Axn::Core::ToolDeclaration`, `Axn::Tools::Registry`) own tool membership and naming; adapters consume them, never re-derive names or re-list members.
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

axn-core reserves the top-level public constants (`Result`, `Failure`, `Factory`, `FormObject`, `Configuration`, `RailsConfiguration`, `Strategies`, and the exception classes) plus the module namespaces `Core`, `Internal`, `Async`, `Extensions`, `Tools`, `Validation`, `Configurable`, `Mountable`, `Extras`, `FieldDeclarations`, `Testing`, `Util`.

`Axn::Reflection` is **deliberately unclaimed** — do not define anything there. It held seven internal modules until the name was vacated before release (`Axn::Internal::Reflection`), because a public-looking namespace occupied entirely by implementation detail is a name we can't later use for the thing it advertises. What a user reflects with today is `input_schema`/`output_schema` on the action class; `Axn::Reflection` stays free for a reflection API we'd be willing to support as public. `spec/axn/namespace_policy_spec.rb` fails if anything re-occupies it.

`Axn::Extensions` is the extension-author surface (for gems building on axn — e.g. `Axn::Extensions.best_effort`, `Axn::Extensions.config`, `Axn::Extensions::Serialization.render`), distinct from `Axn::Internal` (private) and the user-facing DSL. `Axn::Core` holds action-assembly and runtime machinery (`Executor`, the context-facade family); it is not a public surface.

Which namespace a new constant belongs in, so the next addition follows a rule instead of copying a precedent:

- `Internal::X` — internal **and generically useful**: a value-level mechanism any layer can use, with no presence in the action's surface. `CycleGuard`, `ShapeGraph`, `NativeMethods`, `Timing`, `Callable`, `ClassName`, `Text`, `Rendering`.
- `Internal::Reflection::X` — the layer that derives a JSON view of a contract, and only that: `Schema`, `Values`, `PropertyNames`. Nothing outside axn names it; what a gem consumes are the projections — `input_schema`/`output_schema` on the action class, and `Extensions::Serialization.render` for a result. Anything that runs during validation or at declaration belongs at `Internal::X` (`Coercion`, `SubfieldTree`, `ResolvedSubfields`) or in the layer it serves (`Core::Contract::SubfieldContradictions`). Deciding whether a specific runtime foothold still counts as membership? Read `internal-docs/agent-notes/namespaces.md` first.
- `Core::X` — internal **and contextual to one topic**: a layer extended onto the action class, named for what the *author* writes. `Contract`, `Hooks`, `Tagging`, `Logging`, `AmbientContext`, `ToolDeclaration`.
- `Core::Contract::X` — machinery one layer owns and that is meaningless outside it. `FieldConfig` (the contract's config object — the same-named `Internal::FieldConfig` is the field-name convention helper), `ShapeConfig`, `ShapeDeclaration`, `Redaction`.
- `Extensions::X` — axn **or downstream gems**. The only namespace a gem should add constants to, and adding one is adding to the public API.
- `Tools::X` — the tool surface: its calls (`Axn::Tools.for`) *and* its exceptions (`Axn::Tools::InvalidContract`).

A namespace is not a substitute for `private`. `Axn::Configurable` is `extend`ed onto each consuming gem's own module, so an underscore-named method there is a public method of `Axn::MCP` / `Axn::OpenAPI` / `DataShifter` — "internal by namespace" guarantees nothing. Underscore-name AND `private` unless a cross-file caller with an explicit receiver needs it, and record why when one does.

`Axn::Error` is the public-error boundary and a **module**, not a base class: `rescue` matches by
`is_a?`, so tagging a class costs it no ancestry. Including it is the boundary DECLARATION, not a
blanket sweep — a class that includes it is public, documented, rescuable and breaking to remove;
`spec/axn/error_policy_spec.rb` pins the exact set of untagged classes, so neither an untagged
public error nor a tagged internal one can land. `Axn::Failure` is the one deliberate public
exclusion: it's a control-flow signal from `call!`, not a fault. No public exception class inherits
out of `Axn::Internal`. Adding a new error class, or deciding whether it should include
`Axn::Error`? Read `internal-docs/agent-notes/namespaces.md` first.

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
  declared raises loudly. The breadcrumb's LEVEL follows where the collision came from: `debug` when
  both sides are in the file being read, so the author is looking at the answer already; `warn` when
  axn declines to define something because a name is owned somewhere the author may never look — a
  superclass in another file, an adapter base in another gem (`description` deferring to
  `Axn::MCP::Tool`, an instance helper deferring to `ApplicationService#log`). A `debug` line nobody
  greps for is indistinguishable from silence, and silence is the whole defect those deferrals exist
  to remove. Keep such a warning once per colliding definition per process, never per call.
- **Don't force false uniformity, but do fix real inconsistency.** Paths may differ when inputs
  differ (symbol-keyed kwargs vs indifferent-access nested data). But a value with a uniform
  *meaning* (`<field>_id` is always the primary key) must be honored on every path, blank/edge
  inputs included.
- **A validator constrains the value at the position it is declared at.** `expects` names the field's own
  value; `of:` descends a level (an Array's element, a map's `keys:`/`values:` axis); each rung of a nested
  bag names its own. So `inclusion:` on a `type: Array` field constrains the ARRAY, and a constraint on the
  elements goes in `of:` — which carries the value validators for its position (PRO-3193), derived as
  `POSITIONAL_VALIDATOR_KEYS` rather than listed: a position offers a VALUE and nothing else, so what it
  refuses is exactly what reads something it has not got (`type:`, whose role `klass:` plays; `model:` and
  `confirmation:`, which resolve against readers; `coerce:`, a transform; `uniqueness:`, which needs a
  record). The same two guards judge a bag position as judge a field, reached with `klass:` in `type:`'s
  role, so one rule covers all four positions rather than a second table that can drift. ActiveModel's `Clusivity` special-cases an Array value and distributes the set over
  its elements; axn's own `InclusionValidator`/`ExclusionValidator` (constants on `Validation::Base`) drop that branch,
  because the distributing reading has no schema spelling, inverts to nonsense under exclusion, and stops at
  depth 1. A validator with no reading at a container position is refused at declaration
  (`_reject_container_position_validators!`), never left enforcing something no rule states. The rule governs
  axn CONTRACTS: a consuming app's own `validates` is untouched, and so is `Axn::FormObject`, which is an
  ActiveModel model whose `validates` axn only wraps to auto-add `attr_accessor`s — the same boundary, stated
  because the class ships with axn and the difference would otherwise be discovered rather than read.
- **A guard derives from what its consumer emits; it never predicts it.** When a check must agree
  with a projection, read the consumer's own output or call its own decision
  (`Schema.shape_property_plan`, `Schema.build_input_for`) rather than re-deriving the answer beside
  it — a predictor both misses what the consumer emits by an unknown path AND rejects legal
  declarations the consumer would never emit. When a charge can't be exact, know which way it errs:
  UNDER-counting only loosens a bound, OVER-counting rejects a legal declaration. A check may
  legitimately fire later than declaration — "before anything can consume it," not "at
  declaration" — if only the emitted schema reveals the problem. Before writing a guard or size
  budget against a projection, read `internal-docs/agent-notes/guards-and-projections.md` first.
  The projection of a satisfiable contract must itself be satisfiable: "biased stricter" (see
  `docs/reference/class.md`) licenses a node admitting FEWER values, never one admitting NONE — an
  unsatisfiable node is the signature of the runtime and the emitter disagreeing about what a validator
  targets, and it satisfies a directional invariant vacuously. And a contract that admits nothing has no
  honest projection at all, so refuse it at declaration rather than teaching the emitter to paper over it.
- **Canonicalizing a value obliges you to re-audit every guard that read the raw form.** Symbolizing
  keys, defaulting an absent list to `[]`, normalizing a name — each silently disarms any downstream
  check that distinguished what you just erased. Enumerate the consumers of both forms in the same
  commit, and say which still fire. (Case studies: `internal-docs/agent-notes/guards-and-projections.md`.)
- **An optimization that returns the caller's object unchanged is an aliasing bug.** A fast path
  skipping work because "nothing needs changing" answers a different question than "nothing needs
  copying" — a declared contract must be axn's own, so mutating what the caller still holds cannot
  change it retroactively. One exception: an already-FROZEN container is stored as the caller's
  object (`Internal::ShapeGraph.detached_option_array`), since "nothing can change it afterwards" is
  the same property a copy would buy. Before writing a fast path over a caller-supplied container,
  read `internal-docs/agent-notes/guards-and-projections.md` first — a copy detaches only what it
  actually copies, and getting that wrong is the recurring bug there.
- **Internals never dispatch a name a user can take.** `include Axn` puts helpers on the user's
  class, and a field declaration's reader lands there too — so `action.result` reaches whatever
  currently answers to `result`. Read action state through `Axn::Internal::ActionState`, which holds
  each implementation as an `UnboundMethod` and `bind_call`s it, so the invocation names a specific
  method object rather than a name the receiver can intercept. `@action.call` in
  `lib/axn/core/executor.rb` is the one exception, and it is the reason `call` is unsurrenderable.
  New user-facing sugar goes in an included module (never `class_eval`'d onto the class) so a user
  can wrap it with `super`; new `class_attribute`s take `instance_accessor: false`. Two things
  enforce this, and they catch different shapes: `spec/axn/internal/no_shadowable_dispatch_spec.rb`
  greps `lib/` for a sugar name reached on a receiver that holds an action instance — directly or
  through `send`/`respond_to?`, which is worse, since a shadow answers the probe as truthfully as the
  real method — and cannot see a bare self-send (`result.respond_to?(:x)` is indistinguishable from a
  local variable);
  `spec/axn/core/method_shadowing_integrity_spec.rb` carries the behavioural matrix that catches
  those — shadow each sugar name in turn and assert every other sugar path still works.
- **Reserved names are derived from ownership, never listed.** Whether a declaration may take a name
  is `Axn::Internal::NameOwnership`'s question, asked once per name a declaration lands, at the
  receiver that name lands on: for `expects`, the resolved reader against the action class and the
  wire key against `Axn::Core::InternalContext` (`as:`/`prefix:` pull the two apart, so one answer
  cannot stand for both); for `exposes`, where the wire key IS the reader, `Axn::Result` and that
  same facade, which carries every exposure as an implicitly-allowed field. Axn's own
  sugar modules are surrenderable; Ruby's methods, the user's own code, and `call`/`_run` are not.
  Ownership alone cannot see a non-method collision — a key a consumer's `deconstruct_keys` emits, a
  control kwarg `fail!`/`done!` reads ahead of exposures — so those are guarded separately, derived
  from the consumer's own output rather than hand-listed alongside it. To make a new helper
  surrenderable, add its MODULE to `SURRENDERABLE_OWNERS` — never a bare name.
- **Whether axn may DEFINE a name is one question asked at two receivers.**
  `Axn::Core::MethodShadowing` answers it for the class-method DSL and for the instance helpers, and
  both answers skip `Axn::Core::*` owners *only*, so a satellite adapter's module (`Axn::MCP::*`)
  counts as external and axn steps aside for it. Class side (`externally_defined?`) walks
  `base.singleton_class`'s ancestors comparing own method tables, untruncated, `base` itself
  included — an explicit `def self.x` defers — after one live reachability read, since it is asked
  before axn extends the name. Instance side (`inherited_definer`) does not walk `ancestors` at all:
  it steps the DECLARATION CHAIN, `declared_instance_method(base, name)` then
  `shadowed_instance_method` repeatedly, which is Ruby's own resolver answering in dispatch order.
  That is load-bearing rather than stylistic — the chain stops at an `undef_method` entry, which no
  own-table read reports and which effective lookup can only report for the class as a whole, so it
  is the only reader that sees a barrier hosted BEHIND the modules axn included in front of it, and
  it sees one written after `include Axn` as readily as before. Nothing in this area caches a
  per-name verdict as a result; the one thing still captured at include time is the deferral shim's
  UnboundMethod, on purpose. What the instance side does not count as the user's own: `base` and its
  prepends (a `def` in the class body wins on its own terms with `super` reaching axn's, so treating
  it as a deferral target would point the deferral at the method deferring to it), and `::Object`
  with its own ancestors — `Kernel` owns `warn`/`inspect`/`hash`/`then`/`tap`, and deferring to
  those would silently redirect `warn("msg")` inside every action to stderr. The deferrable surface
  is `DEFERRAL_SOURCES`' public instance methods minus `internal_name?`, derived exactly like
  the reserved names above. `DEFERRAL_SOURCES` is `SURRENDERABLE_OWNERS` plus
  `Axn::Core::AmbientContext` alone — deferring an inherited `ambient_context` costs axn nothing
  (internals bind that reader rather than dispatch it), which is a different question from whether a
  *field* may take the name, so the two lists diverge for that one module on purpose. Nowhere else
  should they. `UNSURRENDERABLE` (`call`/`_run`/`initialize`) cannot be deferred and is
  refused at the execution funnel rather than at include time, because only the finished class
  answers it — and on EVERY call rather than once per class, because the hierarchy it asks about
  stays mutable for as long as the process runs and Ruby offers no hook for "an ancestor was
  reopened"; that refusal asks TWO questions in one pass over the chain (`core_shadowed_definer`) —
  axn's own definition is what a dispatch reaches AND something behind it declares the name — so a
  class that defines the name itself, as `Axn::Factory`-built classes do after the include, is never
  refused. A `prefer_inherited`/`prefer_axn` declaration only ever adds a wrapper to the DECLARING
  class's own module and never edits an inherited one, which is what stops a subclass changing its
  parent's and siblings' behaviour. That narrowness cuts against axn as well: an instance name
  declared in an axn module OUTSIDE `Axn::Core` is external by this rule — `Axn::Async`,
  `Axn::Async::BatchEnqueue`, `Axn::Mountable` and the anonymous `Axn::Configuration.overrides`
  module sit ahead of `Axn::Core` in every action's ancestry, `Axn` itself behind it. One of the
  deferrable names there makes every action in every app defer to that module and warn its author to
  declare `prefer_inherited`; `call`/`_run`/`initialize` there either bypasses the unsurrenderable
  guard silently (ahead) or makes every action raise (behind). Such a name belongs under
  `Axn::Core`, or in `_axn_core_owned?`. New user-facing sugar needs no edit here; adding a whole
  new sugar module does.

## Errors

Reuse the hierarchy in `lib/axn/exceptions.rb`; don't invent ad-hoc classes. Every `message`
explains the problem **and** the fix (see `UnknownExposure`). New messages meet that bar.

Before touching anything on the failure-settlement or error-reporting path — `_settle_exception!`,
any `Axn::Extensions` method (not just `best_effort`), a message resolver,
`Internal::Rendering`/`Internal::Text`/`Internal::NativeMethods`, `Internal::ShapeGraph`'s
option-container copy, the contract's declaration walk, any serialization or reflection error
path, or a `rescue` on the result path — read `internal-docs/agent-notes/error-paths.md` first.
The rules it backs:

- `Axn::Extensions.best_effort` guards a side channel and swallows `StandardError` plus
  `SWALLOWABLE_BEYOND_STANDARD_ERROR`. Pass `standard_errors_only: true` only when no side effect is
  committed yet AND an executor boundary will settle the escape into a reported result. Apply the
  flag at exactly one layer per callable — the layer that invokes it — and never let behavior depend
  on which error class was raised. Widen `SWALLOWABLE_BEYOND_STANDARD_ERROR` only for a class that's
  unambiguously a fault in the code being run.
- In an error-reporting or serialization path, derive message content without dispatching to the
  caller's own methods — bound methods (`Object.instance_method(:class).bind_call`) instead of
  `.class`/`.inspect`, `case`/`when` instead of `is_a?`. Dispatch on caller *data* is a different
  question and is fine when the dispatch **is** the work (normal rendering, validation) — this rule
  is only about the reporting path itself.
- Don't build a guard that depends on foreign behaviour being honest — verifying that an object
  BEHAVES is unbounded. Ask ownership (`Internal::NativeMethods`) instead, and refuse (`freeze` is
  the documented escape) when the object isn't native.
- The bound readers to reach for, so a guard never asks a caller's class about itself. Each of the
  `NativeMethods` module readers requires the caller to have established that the receiver IS a Module
  first, via `Internal::Identity.kind?(mod, ::Module)` (`Module#===` is C-level and runs none of the
  object's code) — binding one to anything else is a `TypeError`, i.e. the replaced-verdict failure
  they exist to prevent. `spec/axn/internal/no_unbound_module_reflection_spec.rb` enforces the
  method-table half of this; the naming half is carried by review.
  - `Internal::NativeMethods.declared_instance_method(mod, name)` — bound `Module#instance_method`,
    any visibility, nil on `NameError`. One call replaces a `method_defined? ||
    private_method_defined?` pair AND the follow-up `instance_method(name)`.
  - `Internal::NativeMethods.declares_own_instance_method?(mod, name)` — the module's OWN table, which
    is a different question from `declared_instance_method(...)&.owner == mod`. Effective lookup answers
    what a call would REACH, and a PREPENDED module changes that: a class defining `#call` that also
    prepends a module defining `#call` resolves to the prepend, so an owner comparison calls the class's
    own definition absent while it sits in its own table waiting to be overwritten. A guard deciding
    whether it may DEFINE a name wants the table; one asking what a dispatch reaches wants the lookup.
  - `Internal::NativeMethods.public_instance_method?(mod, name)` — when the question is "could a
    consumer dispatch this?" rather than "does the module declare it?"
  - `Internal::NativeMethods.module_ancestors`, `.includes_module?`, `.module_singleton_class` — the
    last for INSTALLING onto a module's singleton class, where a misdirected read lands the
    installation somewhere else entirely rather than merely inverting a verdict.
  - `Internal::Rendering.module_name(mod)` for a class or module named in prose,
    `Internal::Rendering.class_name(value)` for a value's class, `Internal::Text.renderable` for
    caller bytes — and in `axn/exceptions.rb`, `Text.renderable`/`RenderedClassName` only, since
    reaching up to the reflection layer would close a require cycle
    (`spec/axn/standalone_require_spec.rb` catches it).
  - `Internal::Identity.kind?` instead of `is_a?`, and `Internal::Identity.same?` instead of `==`
    when comparing modules — a `Module#==` of the class's own is as overridable as the rest.
- A class or module NAME is the exception to all of the above: read it by DISPATCH. Axn installs a `name`
  of its own on the classes it builds (`Mountable::Helpers::ClassBuilder#configure_class_name`,
  `Strategies::Form.resolve_type`), so on an action class or a mounted axn a bound `Module#name`/`#to_s`
  answers `#<Class:0x…>::Axns::Inner` where axn intends `AnonymousClient_2980::Axns::Inner` — the
  override is axn's naming mechanism, not a caller's lie, and binding it substitutes an object address
  for prose. Reach for `Rendering.module_name` only where the receiver is a class axn never renames: a
  caller's exception class, a config source module. Keep the `|| "Action"` fallbacks — a bound read
  replaces them too, and an anonymous action class is the common case in tests.
- Every declared name written into prose routes through `PropertyNames`'s renderers — never render a
  name by running the name's own code — and a name is canonicalized exactly once per verdict, never
  re-canonicalized inside a nested check.
- Render a composed message at the join, never operand by operand: half-rendering breaks encoding
  compatibility that would otherwise hold.
- A finding reachable only by an adversarial/hostile object earns an audit of the area, not an
  exhaustive fix — justified by completing an invariant, closing the last unguarded instance in a
  guard-purpose module, or failing safe at equal cost. Report what you examined even when declining
  the patch.
- Cycle-guard any recursion through caller-supplied Hash/Array with `Axn::Internal::CycleGuard.guard`.
  A walk descending in lockstep with a shape graph guards on the pair (`guard_pair`) plus
  `ShapeGraph::MAX_NESTING`. For third-party recursion that can't be guarded from inside, rescue
  `SystemStackError` and retry on `CycleGuard.decycle(data)`.

## Testing

- Cover happy path, guard/raise paths, and awkward edges (blank vs nil vs absent, aliasing, nesting,
  both-supplied conflicts) — that's where base-layer bugs hide.
- Use `Axn::Testing::SpecHelpers`' `build_axn { ... }`. Non-Rails specs use plain POROs with a
  finder for `model:` behavior; mirror Rails-specific behavior in `spec_rails/dummy_app/`.
- Run `bundle exec rspec` and the relevant `spec_rails` specs; verify against real output before
  claiming done.
- **Auditing a guard's coverage: mutate it.** Remove or invert the guard, re-run the suite, and if it stays
  green the guard is unguarded. Note what this *cannot* find: removing a guard makes a legal-behaviour
  assertion pass more easily, never fail, so mutation says nothing about the **controls** — the examples
  pinning what a guard must keep ACCEPTING. Over-rejection is the recurring failure mode when a guard is
  tightened, so audit controls by **inverse** mutation instead: introduce an over-eager guard and confirm a
  control fails.
- **Changing a guard? A/B the spec against the prior commit.** An example that fails in BOTH trees
  is a broken fixture, not a finding — only the examples whose behaviour the change actually moved
  flip. Read `internal-docs/agent-notes/ab-testing-guards.md` for the exact procedure and its
  pitfalls (stale lockfiles, `$LOAD_PATH` cross-tree contamination) before running one.

## Changes & compatibility

- **CHANGELOG every user-visible change** under `## Unreleased`, tagged `[FEAT]` / `[BREAKING]` /
  `[BUGFIX]` / `[INTERNAL]` — dense and specific (what, why, edge behavior), matching the prevailing
  detail level. Release prep renames that heading to the version, so between the rename and the tag
  the TOP VERSION HEADING is the unreleased section and entries belong there — do not open a second
  `## Unreleased` above it, or the release has two sections to reconcile. Decide which state you are
  in from `git tag` and rubygems, never from which heading is on top: a version heading with no
  matching tag has not shipped.
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
