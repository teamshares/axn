# Namespaced per-class config — Design

**Date:** 2026-07-12
**Ticket:** [PRO-2880](https://linear.app/teamshares/issue/PRO-2880) (follow-up to PRO-2856 / the `Axn::Configurable` line of work)
**Builds on:** PRO-2769 (`Axn::Configurable`), PRO-2846 (`raw_<name>`), PRO-2856 (wired per-class overrides into the action lifecycle, PR #151)
**Compatibility set:** axn-mcp (#7), axn-ruby_llm (#7), slack_sender (#16), data_shifter (#15) — the four gems currently adopting `Axn::Configurable`. None has shipped against a *released* axn carrying `Axn::Configurable`, so this surface is greenfield: no backward-compat obligation, only forward-fit with these four.

## Context

`Axn::Configurable` gives a module the config machinery — `setting :x`, defaults/validation, `.config`/`.configure`, and (for `overridable: true` settings) an `overrides` mixin that installs per-class `x(value)` / `resolved_x` / `raw_x` accessors on an action. PR #151 wired core's own single overridable setting (`sidekiq_job_tag_sources`) through this path.

Four downstream gems are now adopting the DSL, and they split into two distinct topologies:

- **Peer Configurable modules.** `Axn::MCP`, `Axn::RubyLLM`, `DataShifter`, `SlackSender` each `extend Axn::Configurable` (or its `Settings` class-flavor) as an *independent* module with its own `.config`/`.configure`. There is no core-owned registry they push into; each is a peer, and a per-class override falls back to *that module's* global config, not core's.
- **A shared "tool" concept.** PRO-2844/PRO-2845 added `Axn::MCP.wrap(any_axn)` and `Axn::RubyLLM.wrap(any_axn)`: a single plain Axn, authored once, exposed through *multiple* transports. As core makes actions "tool-able" directly, one Axn class can simultaneously be an MCP tool, a ruby_llm tool, and a future restful-api tool.

These two topologies want different config surfaces, and the current mechanism serves only the first.

## Problem

**1. The per-class override store collides across modules.** `_define_override_methods` (`lib/axn/configurable.rb:126-162`) keys the override store as a single flat hash on the consumer class, by *bare setting name*: `raw_lookup` reads `store[name]`, the setter writes `(@_axn_config_overrides ||= {})[name] = value`. Each Configurable module owns its own `_override_methods_module` (so *method definitions* don't collide), but every generated accessor reads and writes the one shared `@_axn_config_overrides` ivar. The instant a class composes two modules' overrides — `include Axn::MCP.overrides` **and** `include Axn::RubyLLM.overrides` — any setting name they share (`enabled`, `text_content`, …) stomps the same slot. This is not hypothetical proliferation; it is the exact shape of the "author once, wrap for many transports" tool, and it is a correctness bug the moment two adapters overlap a name.

**2. Namespace hygiene / method proliferation.** Every `overridable: true` setting installs three public class methods (`<name>`, `raw_<name>`, `resolved_<name>`) onto the action. The `_warn_on_shadowed_overrides` machinery (`configurable.rb:90-102`) exists precisely because these collide with consumer-defined and inherited methods. A tool composing N adapters inherits N×3 such methods, each shadowable, with no namespace to disambiguate whose `text_content` is whose.

**3. No surface for unloaded adapters.** A reusable tool built *in a library* may want to declare "when used as MCP do X, when used as ruby_llm do Y" without hard-depending on axn-mcp or axn-ruby_llm. There is currently no way to set adapter config for an adapter that may not be loaded in the current process.

## The topology distinction (the organizing principle)

The two surfaces are not competing styles to choose between globally — they fit two different consumer topologies:

- **Subclass-based, single-adapter** (data_shifter: `class MyShift < DataShifter::Shift`). Exactly one namespace is ever in play; the class IS-A shift. Flat class methods (`progress true`) are unambiguous and ergonomic, no collision is even *possible* (a shift includes only `DataShifter.overrides`), and forcing a namespace here would be ceremony for nothing.
- **Composed, multi-adapter** (the tool: one plain Axn wrapped as MCP *and* ruby_llm *and* restful). No single base class; several orthogonal adapter concerns on one class. This is the *only* place the store collision bites and the only place "whose `text_content`?" is a real question.

So flat accessors remain the surface for single-adapter subclass gems, and a namespaced `configure(:ns)` form is the surface for composed tools — **both over one uniform namespaced store.** The gem author picks the surface that fits their topology; the mechanism underneath is uniform.

## Goals

- Namespace the per-class override store so composing multiple adapters' overrides on one class cannot collide.
- Give each Configurable module a namespace identity; core's own settings live under `:core`.
- Preserve flat accessors (`progress true`, `resolved_progress_enabled`) as ergonomic sugar for single-adapter gems, now implicitly namespace-scoped.
- Add a core-level, always-present `configure(namespace = :core) { |c| … }` writer for the composed-tool topology, tolerant of namespaces whose adapter is not loaded.
- Keep the resolution path collision-proof (`resolve_override_for`), extended by namespace.
- Keep global config a per-module concern (core via `Axn.configure`, each gem via its own `.configure`); the per-class override's global fallback resolves to the owning module's bag at read time. No unified global entry point.

## Non-goals

- **Backward compatibility for the override surface.** Nothing has shipped against a released `Axn::Configurable`; the four gems re-adopt whatever the released axn provides. Free to re-key the store and reshape accessors.
- **A core registry of adapters.** Core does not learn which gems exist or what settings they own. Namespace identity lives on each peer module; `configure`'s namespace argument is plain data.
- **Changing the module-singleton flavor's observable global behavior** (`Axn::MCP.config.*` etc.). This design adds per-class namespacing; the global bags are unchanged.
- **Migrating additional core settings** to overridable. Still just `sidekiq_job_tag_sources`; the mechanism keeps any future opt-in a one-liner.

## Design

### 1. Namespace identity on each Configurable module

Each module that carries overridable settings declares its namespace once:

```ruby
module Axn::MCP
  extend Axn::Configurable
  config_namespace :mcp
  setting :text_content, default: :structured, one_of: %i[structured message], overridable: true
end

class Axn::Configuration
  extend Axn::Configurable::Settings
  config_namespace :core
  overridable_config_source { Axn.config }
  setting :sidekiq_job_tag_sources, ..., overridable: true
end
```

`config_namespace` is declared on both flavors (it lives in the shared `PerClassOverrides` mixin, alongside `overrides`). It must precede any `overridable: true` setting; declaring an overridable setting with no namespace raises at declaration (same fail-fast posture as `overridable_config_source`). The class flavor used by core defaults to `:core` if left undeclared, so core need not special-case; peer gems declare explicitly.

### 2. Namespaced override store

The consumer-class store becomes nested by namespace: `@_axn_config_overrides[namespace][name]`. Every generated accessor closes over `(namespace, name)` — `namespace` is the declaring module's `config_namespace` — and reads/writes `store.dig(namespace, name)` / `(store[namespace] ||= {})[name] = value`. `raw_lookup` walks the superclass chain exactly as today, but reads the namespaced slot. `resolve_override_for` gains a namespace argument: `resolve_override_for(klass, namespace, name)`.

This single change fixes problem 1: `Axn::MCP`'s `text_content` writes `[:mcp][:text_content]`, `DataShifter`'s `progress_enabled` writes `[:data_shifter][:progress_enabled]`, and a class composing both never shares a slot even on a name clash.

### 3. Flat accessors as namespace-scoped sugar

No change to the *ergonomics* of the single-adapter surface. `DataShifter`'s `setting :progress_enabled, overridable: true` still generates flat `progress_enabled(value)` / `resolved_progress_enabled` / `raw_progress_enabled` on a shift. They now carry `:data_shifter` implicitly (the accessor closes over the declaring module's namespace), so they write and read the `[:data_shifter]` slot and validate eagerly at write against the gem's own schema — exactly the eager validation a subclass gem wants. data_shifter's existing specs assert *behavior* (`progress true` → `resolved_progress_enabled` true), not ivar shape, so re-keying is transparent to it.

### 4. Core-level tolerant `configure(namespace = :core)`

A single class method, defined by core on every `include Axn` action (via `Axn::Configuration.overrides`, which the action base already includes — PR #151), is the composed-tool surface:

```ruby
class QuoteLookup
  include Axn
  configure(:mcp)      { |c| c.text_content = :structured }   # adapter namespace
  configure(:restful)  { |c| c.status = 201 }                 # adapter may not be loaded
  configure            { |c| c.sidekiq_job_tag_sources = %i[dimension] }  # no-arg ⇒ :core
end
```

`configure` yields a **namespace writer** — a small object holding `(action_class, namespace)` whose `<setting>=` stores into `store[namespace][setting]`. It is a *dumb, tolerant bag*: it accepts any key and stores it blindly, whether or not an adapter for that namespace is loaded. This is what lets a library pre-declare `configure(:restful) { … }` for an adapter absent from the current process — the value sits inert until the adapter reads it. Yielded-receiver + assignment style keeps symmetry with the existing `Axn.configure { |c| … }` and lets the block reference the surrounding class's constants/methods (which `instance_eval` + `method_missing` would not).

`configure` is core-provided and namespace-agnostic, so it is present on any action regardless of which (if any) `.overrides` are included — which is exactly what the pure `wrap`-a-plain-Axn tool needs.

### 5. Validation: eager at the flat accessor, deferred at the tolerant bag

Two write paths, two validation moments — chosen to avoid a core registry (rejected alternative below):

- **Flat accessor** (subclass gem): the accessor is generated by the gem's `setting`, so it knows the schema and validates at write, raising immediately on a bad value. Unchanged from today.
- **`configure(:ns)` writer** (tolerant bag): core does not know namespace `:ns`'s schema (no registry), so it stores blindly. The owning adapter validates its slice when it *reads* — `resolve_override_for(klass, :ns, name)` runs `setting.validate!` on the resolved override before returning, so a bad value or unknown key surfaces at wrap/invocation time. For a loaded adapter that value is caught the first time the tool is exercised; for an unloaded adapter the value simply never resolves.

The layering is clean: include an adapter's `.overrides` → flat accessors, eager validation; don't → `configure` bag, deferred validation. Anyone wanting eager validation for a loaded adapter uses that adapter's flat accessors.

### 6. Global config stays per-module (no unified entry point)

Global config remains a per-module concern: `Axn.configure { … }` for core, `Axn::MCP.configure { … }` for MCP, and so on. There is deliberately **no** `Axn.configure(:mcp)` global entry point, because the global bag for `:mcp` *is* `Axn::MCP.config` — routing a core-level `Axn.configure(:mcp)` to it would require core to map `:mcp → Axn::MCP.config` (the rejected registry), and a separate core-owned `:mcp` bag would be silently ignored by the per-class fallback (which reads `Axn::MCP.config`). Namespacing is a per-class concern only: one action composing many adapters needs to disambiguate; globally each gem already owns its bag, so the namespace *is* the module you call. An app can still keep every module's `configure` call in one `config/initializers/axn.rb` file — that is ordinary Ruby, not a new mechanism.

The class↔global fallback is unchanged and selected by the *reading adapter*, not by any core global writer: a per-class `[:mcp][:text_content]` override resolves to `Axn::MCP.config` when unset (module-singleton flavor) or to the live singleton (class flavor, e.g. `Axn.config` for `:core`), per the existing `fallback` lambda. So the real symmetry is: core's per-class `configure { … }` ↔ global `Axn.configure { … }`; a gem's per-class `configure(:mcp) { … }` ↔ global `Axn::MCP.configure { … }`. The per-class form carries the namespace as an argument only because the action is namespace-agnostic core code; the global form already sits on the namespaced module.

## Rejected alternative: register-on-load (eager validation everywhere)

An adapter could register its namespace + schema with core on load, so `configure(:mcp)` validates eagerly when axn-mcp is present and tolerantly when absent. Rejected: it reintroduces a core-owned registry that must track which gems exist, coupling core to its satellites and adding a load-order surface. The deferred-validation cost is small — the topology that *wants* eager validation (subclass gems) keeps its flat accessors, which validate at write. The tolerant path is tolerant by nature.

## Testing

- **`spec/axn/configurable_spec.rb`** — namespaced store: two modules with the same overridable setting name, both `.overrides` included on one class, write disjoint slots and resolve independently; `resolve_override_for(klass, ns, name)` reads the namespaced slot; subclass inheritance walks per-namespace; `config_namespace` fail-fast when an overridable setting is declared with no namespace.
- **`configure` writer (non-Rails, `spec/`)** — `configure(:ns) { |c| c.x = v }` on a bare `include Axn` action stores under `[:ns][:x]`; no-arg targets `:core`; a namespace with no loaded adapter stores inertly and never raises at the call site; a bad value surfaces when resolved through `resolve_override_for` (deferred validation).
- **Core round-trip** — `configure { |c| c.sidekiq_job_tag_sources = %i[dimension] }` and the flat `sidekiq_job_tag_sources %i[dimension]` write the same `[:core]` slot and both drive the Sidekiq adapter's tag selection (extend the existing `spec_rails/dummy_app/spec/axn/async/adapters/sidekiq_spec.rb`).
- **Composition** — a class using a flat single-adapter accessor *and* `configure(:other)` shows the two writing disjoint namespaces without interference.

Both trees per the "works outside Rails" rule: the mechanism is non-Rails (`spec/`); the Sidekiq consumer lives in the dummy app (`spec_rails/`).

## Docs

`docs/reference/configuration.md`:

- Document namespace identity (`config_namespace`) and the namespaced override store.
- Document the two per-class surfaces and when each fits: flat accessors for single-adapter/subclass gems; `configure(namespace) { |c| … }` for composed tools, including the tolerant-when-unloaded semantics and the deferred-validation trade-off.
- Show the global/per-class symmetry (`Axn.configure(:ns)` ↔ `configure(:ns)`), and the no-arg ⇒ `:core` default.

## Out of scope

- A public per-class *reader* for `configure`-set values (e.g. `configured(:mcp).text_content`). Adapters read via `resolve_override_for`; a public reader can follow if a use case appears. YAGNI for now.
- Migrating any additional core setting to overridable.
- Any change to the module-singleton flavor's global public behavior.
- The register-on-load registry (rejected above).
