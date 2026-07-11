# Wire the configurable per-class override system into the action lifecycle (PRO-2856)

## Problem

Two parallel config systems exist and don't meet:

- **`Axn::Configurable`** (module-singleton flavor, `extend`ed onto a namespace module) carries the full per-class override machinery: `setting :x, overridable: true`, an `overrides` module that adds `x(value)` / `resolved_x` / `raw_x` class accessors when included in an action, hardened against consumer method collisions (#135, #138).
- **`Axn::Configurable::Settings`** (class flavor, `extend`ed onto `Axn::Configuration`, which `Axn.config` instantiates) is where every real setting actually lives — and it has **no** override support.

So the override accessors are complete and tested, but the config namespace apps actually use (`Axn.config`) is the one flavor without them, and nothing includes an `overrides` module into the action base. No setting can currently be overridden per-axn.

## Goal

Wire the override system into the action lifecycle so a `Settings`-declared setting can be marked `overridable: true` and read via `resolved_<name>` from a running/enqueuing action — without introducing a second config entry point alongside `Axn.config`.

## Approach: bridge (not migrate)

The ticket floats two options. **Full migration of `Axn.config` onto the module-singleton DSL is rejected**: `Axn::Configuration` carries hand-written instance methods and state (`logger`, `env`, `on_exception`, `set_default_async` and the async accessors, `rails`) that don't fit the module-singleton `Config` method_missing bag. The `Settings` flavor exists precisely to "dogfood Axn's own Configuration without contorting the module-singleton DSL." So we **bridge**: teach `Settings` the override capability, reusing the existing generator.

### 1. Extract a shared override-accessor generator

Today the override machinery lives entirely in `Axn::Configurable` (`overrides`, `_override_methods_module`, `_define_override_methods`). Duplicating it into `Settings` would create a parallel path to keep consistent forever — exactly what AGENTS.md warns against ("a parallel path is a new thing to keep consistent forever").

Extract that machinery into a shared mixin, `Axn::Configurable::PerClassOverrides`, `include`d into **both** `Configurable` and `Configurable::Settings`. Its methods become singleton methods of whatever module/class extends those flavors.

The **only** per-flavor difference is where the resolution fallback reads the library-level value:

- module-singleton: `config.public_send(name)` — its own memoized `Config` bag
- class flavor: the live `Axn.config` singleton's `public_send(name)`

So the generator takes a `fallback` lambda; each flavor supplies its own. The fallback is **late-bound** (evaluated fresh on each `resolved_<name>` call, calling `Axn.config` anew) so specs that swap the singleton instance still resolve correctly.

Shared mixin surface (behavior identical to today's `Configurable` internals):

```ruby
module Axn::Configurable
  module PerClassOverrides
    # Returns a module that, when included in an action class, extends it with the
    # per-class override accessors. Reflects settings declared later.
    def overrides
      @overrides ||= begin
        methods_module = _override_methods_module
        Module.new do
          define_singleton_method(:included) { |base| base.extend(methods_module) }
        end
      end
    end

    private

    def _override_methods_module
      @_override_methods_module ||= Module.new
    end

    # fallback: a zero-arg lambda returning the current library-level value for setting.name
    def _define_override_methods(setting, fallback)
      name = setting.name
      raw_lookup = lambda do |start| ... end          # unchanged ancestry walk
      resolve_override = lambda do |start|
        found = raw_lookup.call(start)
        UNSET.equal?(found) ? fallback.call : setting.resolve(found)
      end
      _override_methods_module.module_eval do
        define_method(name) { |value = UNSET| ... }    # unchanged
        define_method(:"raw_#{name}") { raw_lookup.call(self) }
        define_method(:"resolved_#{name}") { resolve_override.call(self) }
      end
    end
  end
end
```

`Configurable#setting` then calls `_define_override_methods(setting, -> { config.public_send(setting.name) }) if overridable`. Its `self` inside the lambda is the extended module, so `config` is the module's own bag. No behavior change for existing module-singleton consumers.

### 2. `Settings` gains `overridable:` and a singleton seam

`Settings.setting` gains the `overridable:` keyword (threaded into the `Setting` struct, same as `callable:` already is) and, when `true`, calls the shared generator with a fallback that reads the live singleton.

The class flavor is generic — it must not hardcode `Axn.config`. The extending class declares its live singleton once:

```ruby
module Axn::Configurable::Settings
  include PerClassOverrides

  # The extending class registers the live singleton whose values are the
  # library-level fallback for per-class overrides.
  def overridable_config_source(&block)
    @_overridable_config_source = block
  end

  def setting(name, default: nil, one_of: nil, validate: nil, callable: false, overridable: false)
    setting = Setting.new(name: name.to_sym, default:, one_of:, validate:, callable:, overridable:)
    # ... existing define_method getter/setter ...
    return unless overridable

    unless @_overridable_config_source
      raise ArgumentError, "setting #{name} is overridable: true but no overridable_config_source is declared"
    end
    source = @_overridable_config_source
    _define_override_methods(setting, -> { source.call.public_send(setting.name) })
  end
end
```

`Axn::Configuration` declares the seam once:

```ruby
class Axn::Configuration
  extend Axn::Configurable::Settings
  overridable_config_source { Axn.config }
  ...
end
```

Fail-at-declaration (per AGENTS.md DSL rules): declaring a setting `overridable: true` with no source registered raises immediately.

### 3. Wire the action base

In `Axn::Core.included` (the action base setup), add alongside the other DSL includes:

```ruby
include Axn::Configuration.overrides
```

`Axn::Configuration` is required before `axn/core`, and the generated `overrides` module reflects settings declared later, so load order is safe. Every `include Axn` action then gains the accessors for each `overridable: true` setting; subclasses inherit them (class-method inheritance + the ancestry-walking override store, already covered by existing specs).

### 4. Flip `sidekiq_job_tag_sources` and swap the adapter

Mark the one setting `overridable: true`:

```ruby
setting :sidekiq_job_tag_sources,
        default: %i[tag dimension],
        overridable: true,
        validate: ->(v) { v.is_a?(Array) && v.all? { |s| SIDEKIQ_JOB_TAG_SOURCES.include?(s) } }
```

Swap the one consumer (`lib/axn/async/adapters/sidekiq.rb`, in the `class_methods` block where `self` is the action class):

```ruby
sources = resolved_sidekiq_job_tag_sources   # was: Axn.config.sidekiq_job_tag_sources
```

Update the neighboring comment that references `Axn.config.sidekiq_job_tag_sources`. This proves the wiring end-to-end rather than shipping a mechanism with no live consumer.

## Which settings become overridable

Only **`sidekiq_job_tag_sources`**. Scan of the rest:

| Setting | Overridable now? | Why |
| --- | --- | --- |
| `sidekiq_job_tag_sources` | **Yes** | The motivating consumer; natural per-axn ("this action's jobs shouldn't carry high-card tags"). |
| `log_level` | No | Already has its own hand-rolled per-class story (`def log_level = Axn.config.log_level`, redefine-to-override) that's separately documented. Folding it into the override system is a distinct, behavior-changing concern. |
| `emit_metrics` | No | A global side-effect proc wired once to the metrics provider; per-action variation is already served by `tag`/`dimension` facets. |
| `additional_includes` | No | Applied globally at include time; per-action equivalent is just `include SomeModule` in that action. No override use case. |
| `raise_piping_errors_in_dev` | No | Dev-only global diagnostic toggle; no per-action use case. |
| `async_max_retries` | No | Governs retry-context reporting; per-action retry behavior is already expressed through the `async` DSL. A second axis here would duplicate that. |
| `logger` / `env` / `on_exception` / `ambient_context_provider` / `async_exception_reporting` / `set_default_async` / `rails` | No | Not `Settings`-declared (hand-written), and inherently global or already per-action (`on_exception do … end`). |

The mechanism makes any future opt-in a one-liner (`overridable: true` + swap the read site), so YAGNI on the rest.

## Testing

- **`spec/axn/configurable_spec.rb`** — extend the `Axn::Configurable::Settings` describe block to mirror the module-singleton override specs: setter stores per-class, `resolved_<name>` falls back to the **live singleton** (and tracks a swapped singleton), `raw_<name>` returns `UNSET`/override with no fallback, subclass inheritance, consumer-collision hardening, and the fail-at-declaration error when `overridable: true` without `overridable_config_source`.
- **Wire-level (non-Rails, `spec/`)** — a bare `include Axn` action responds to `sidekiq_job_tag_sources` / `resolved_sidekiq_job_tag_sources` / `raw_sidekiq_job_tag_sources`, resolving to `Axn.config`'s value by default and to the per-class value once set.
- **Sidekiq adapter (`spec_rails/dummy_app/spec/axn/async/adapters/sidekiq_spec.rb`)** — a per-action `sidekiq_job_tag_sources %i[dimension]` override changes which facets become job tags at enqueue, independent of the global `Axn.config` value. Keep the existing global-stub test.

Both trees per the "works outside Rails" rule: the override mechanism itself is non-Rails (`spec/`); the Sidekiq consumer is in the dummy app (`spec_rails/`).

## Docs

`docs/reference/configuration.md`:

- Add a section documenting the **per-class override API** in general: for any setting declared `overridable: true`, an action gets `<name>(value)` (class-level setter), `resolved_<name>` (nearest ancestry override → `Axn.config` fallback), and `raw_<name>` (override or unset, no fallback). Note override inheritance by subclasses.
- Update the `sidekiq_job_tag_sources` subsection to show a per-action override, e.g. `sidekiq_job_tag_sources %i[dimension]` inside an action, alongside the existing global example.

## Out of scope

- Migrating `log_level` (or any other setting) onto the override system.
- The full-migration approach (rejected above).
- Any change to the module-singleton flavor's public behavior — its internals move into the shared mixin, but observable behavior is identical.
