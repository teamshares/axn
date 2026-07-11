# Wire Per-Class Config Overrides Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire the existing per-class config-override machinery into the action lifecycle so a setting on `Axn.config` can be declared `overridable: true` and read per-axn via `resolved_<name>`, and flip `sidekiq_job_tag_sources` as the first live consumer.

**Architecture:** Bridge, not migrate. Extract the override-accessor generator out of `Axn::Configurable` into a shared mixin (`PerClassOverrides`) included by both config flavors. Teach the class flavor (`Axn::Configurable::Settings`, which `Axn::Configuration` uses) to accept `overridable:` and resolve its library-level fallback from the live `Axn.config` singleton. Have the action base `include Axn::Configuration.overrides`. Flip `sidekiq_job_tag_sources` and swap its one read site.

**Tech Stack:** Ruby, RSpec. Two suites: `spec/` (no Rails) and `spec_rails/dummy_app/` (Rails dummy app).

## Global Constraints

- Works outside Rails: no hard dependency on Rails; guard Rails/AR refs with `defined?(...)`. The override mechanism is tested in `spec/`; the Sidekiq consumer in `spec_rails/dummy_app/`.
- TDD: failing test first, then implementation.
- Fail at declaration, not runtime: DSL misuse `raise`s when the class is defined, with a message saying how to fix it.
- Additive at the seam: existing canonical behavior stays identical; the new axis is added alongside. The module-singleton flavor's observable behavior must not change.
- Comments describe current behavior + intrinsic why — never "used to X / now Y".
- Branch is `kali/pro-2856-...` (not `gitbutler/worktree`), so `git commit` is used directly.
- Run non-Rails specs with `bundle exec rspec <path>`. Run Rails specs from `spec_rails/dummy_app` with `BUNDLE_GEMFILE=Gemfile bundle exec rspec <path>`.

---

## File Structure

- `lib/axn/configurable.rb` — MODIFY. Extract `overrides` / `_override_methods_module` / `_define_override_methods` into a new nested `PerClassOverrides` mixin; `_define_override_methods` gains a `fallback` param. `Configurable` and `Configurable::Settings` both `include` it. `Settings` gains `overridable:` + `overridable_config_source`.
- `lib/axn/configuration.rb` — MODIFY. Declare `overridable_config_source { Axn.config }`; flip `sidekiq_job_tag_sources` to `overridable: true`.
- `lib/axn/core.rb` — MODIFY. `include Axn::Configuration.overrides` in `Core.included`.
- `lib/axn/async/adapters/sidekiq.rb` — MODIFY. Swap `Axn.config.sidekiq_job_tag_sources` → `resolved_sidekiq_job_tag_sources` (one line + neighboring comment).
- `spec/axn/configurable_spec.rb` — MODIFY. Add `Settings` override specs + fail-at-declaration.
- `spec/axn/core/configuration_spec.rb` — MODIFY. Add wire-level specs (bare `include Axn` action gets the accessors and resolves against `Axn.config`).
- `spec_rails/dummy_app/spec/axn/async/adapters/sidekiq_spec.rb` — MODIFY. Add a per-action override test.
- `docs/reference/configuration.md` — MODIFY. Document the per-class override API + per-action `sidekiq_job_tag_sources`.

---

## Task 1: Extract the shared `PerClassOverrides` mixin (behavior-preserving)

Move the override machinery out of `Axn::Configurable` into a nested mixin and route the config fallback through a lambda. The module-singleton flavor's behavior must stay identical — the existing `spec/axn/configurable_spec.rb` is the regression gate.

**Files:**
- Modify: `lib/axn/configurable.rb`
- Test: `spec/axn/configurable_spec.rb` (existing — no new tests here; it guards behavior preservation)

**Interfaces:**
- Produces: `Axn::Configurable::PerClassOverrides` mixin with public `overrides` and private `_override_methods_module`, `_define_override_methods(setting, fallback)` where `fallback` is a zero-arg lambda returning the current library-level value for `setting.name`.

- [ ] **Step 1: Run the existing spec to capture the green baseline**

Run: `bundle exec rspec spec/axn/configurable_spec.rb`
Expected: PASS (all examples green — this is the baseline the refactor must preserve).

- [ ] **Step 2: Add the `PerClassOverrides` mixin and route `Configurable` through it**

In `lib/axn/configurable.rb`, delete the current `overrides` method and the two private methods `_override_methods_module` and `_define_override_methods` from `Configurable`, and replace them with an `include` of a new nested mixin. The mixin holds the same logic, but `_define_override_methods` now takes a `fallback` lambda instead of closing over `config_source`.

Change `Configurable#setting` to pass the fallback:

```ruby
def setting(name, default: nil, one_of: nil, validate: nil, callable: false, overridable: false)
  name = name.to_sym
  setting = Setting.new(name:, default:, one_of:, validate:, callable:, overridable:)
  _axn_config_settings[name] = setting
  _define_override_methods(setting, -> { config.public_send(setting.name) }) if overridable
  nil
end
```

Add `include PerClassOverrides` to `Configurable` (immediately after the `Setting` struct definition), and define the mixin inside `module Configurable`:

```ruby
# Per-class override accessors, shared by both config flavors (the
# module-singleton `Configurable` and the class-level `Settings`). Included
# into each, so its methods become singleton methods of whatever module/class
# extends that flavor. The only per-flavor difference is where the resolution
# fallback reads the library-level value, so `_define_override_methods` takes
# that as a lambda.
module PerClassOverrides
  # Returns a module that, when included in an action class, extends it with the
  # per-class override accessors for each overridable setting. `setting` adds to
  # a shared methods module as overridable settings are declared, and Ruby
  # reflects those additions on already-extended classes — so it's insensitive
  # to load order.
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

  # Generates `<name>(value = UNSET)` / `raw_<name>` / `resolved_<name>` on the
  # shared methods module. `fallback` is a zero-arg lambda returning the current
  # library-level value for this setting (its own `config` bag for the
  # module-singleton flavor; the live singleton instance for the class flavor).
  #
  # Closure-captured helpers so the generated accessors reference each other
  # through these lambdas rather than public method dispatch — a consumer class
  # that happens to define its own `raw_<name>`/`resolved_<name>` class method
  # can't shadow the internals the other accessors rely on.
  def _define_override_methods(setting, fallback)
    name = setting.name

    raw_lookup = lambda do |start|
      klass = start
      while klass.is_a?(Module)
        if klass.instance_variable_defined?(:@_axn_config_overrides)
          store = klass.instance_variable_get(:@_axn_config_overrides)
          return store[name] if store.key?(name)
        end
        break unless klass.is_a?(Class) && klass.superclass

        klass = klass.superclass
      end
      UNSET
    end

    resolve_override = lambda do |start|
      found = raw_lookup.call(start)
      UNSET.equal?(found) ? fallback.call : setting.resolve(found)
    end

    _override_methods_module.module_eval do
      define_method(name) do |value = UNSET|
        if UNSET.equal?(value)
          resolve_override.call(self)
        else
          setting.validate!(value)
          (@_axn_config_overrides ||= {})[name] = value
        end
      end

      define_method(:"raw_#{name}") { raw_lookup.call(self) }

      define_method(:"resolved_#{name}") { resolve_override.call(self) }
    end
  end
end
```

Leave `UNSET`, `Setting`, `config`, `configure`, `reset_config!`, `_axn_config_settings`, and `Config` unchanged. `include PerClassOverrides` must appear after the mixin is defined.

- [ ] **Step 3: Run the spec to verify behavior is preserved**

Run: `bundle exec rspec spec/axn/configurable_spec.rb`
Expected: PASS (same green as the baseline — no examples changed).

- [ ] **Step 4: Run rubocop on the changed file**

Run: `bundle exec rubocop lib/axn/configurable.rb`
Expected: no offenses (add a scoped `# rubocop:disable` only if a metric limit is genuinely unavoidable).

- [ ] **Step 5: Commit**

```bash
git add lib/axn/configurable.rb
git commit -m "PRO-2856: Extract shared PerClassOverrides mixin from Configurable

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Add `overridable:` to the class flavor (`Settings`)

Teach `Axn::Configurable::Settings` to mint the override accessors, resolving the library fallback from a live singleton the extending class registers via `overridable_config_source`.

**Files:**
- Modify: `lib/axn/configurable.rb` (the `Settings` submodule)
- Test: `spec/axn/configurable_spec.rb`

**Interfaces:**
- Consumes: `PerClassOverrides#_define_override_methods(setting, fallback)` from Task 1.
- Produces: `Settings#overridable_config_source(&block)` (registers the live singleton) and `Settings#setting(..., overridable: false)`. When `overridable: true`, the extending class gains `overrides` (from the mixin) plus per-setting accessors whose `resolved_<name>` falls back to `<registered singleton>.public_send(name)`. Declaring `overridable: true` with no source registered raises `ArgumentError` at declaration.

- [ ] **Step 1: Write the failing tests**

Append to the `RSpec.describe Axn::Configurable::Settings do` block in `spec/axn/configurable_spec.rb` (before its final `end`):

```ruby
  describe "overridable: settings" do
    # A stand-in for a live config singleton (what Axn.config is for Axn::Configuration).
    let(:singleton) { klass.new }

    let(:klass) do
      captured = -> { singleton }
      Class.new do
        extend Axn::Configurable::Settings
        overridable_config_source { captured.call }
        setting :mode, default: :a, one_of: %i[a b], overridable: true
      end
    end

    let(:action_class) { Class.new { include klass.overrides } }

    it "resolves to the live singleton value when no override is set" do
      singleton.mode = :b
      expect(action_class.resolved_mode).to eq(:b)
    end

    it "reads the singleton value at resolution time, not at declaration (late-bound)" do
      expect(action_class.resolved_mode).to eq(:a) # singleton's default
      singleton.mode = :b
      expect(action_class.resolved_mode).to eq(:b) # picked up without redefining accessors
    end

    it "resolves to the class-level override when set" do
      action_class.mode :b
      expect(action_class.resolved_mode).to eq(:b)
    end

    it "validates the override value at set time" do
      expect { action_class.mode :z }.to raise_error(ArgumentError, /mode/)
    end

    it "inherits an override from a parent class" do
      action_class.mode :b
      expect(Class.new(action_class).resolved_mode).to eq(:b)
    end

    it "exposes raw_<name> as the override with no singleton fallback" do
      expect(action_class.raw_mode).to equal(Axn::Configurable::UNSET)
      action_class.mode :b
      expect(action_class.raw_mode).to eq(:b)
    end

    it "raises at declaration when overridable: true without a registered source" do
      expect do
        Class.new do
          extend Axn::Configurable::Settings
          setting :mode, default: :a, overridable: true
        end
      end.to raise_error(ArgumentError, /overridable_config_source/)
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec rspec spec/axn/configurable_spec.rb -e "overridable: settings"`
Expected: FAIL (e.g. `NoMethodError: undefined method 'overridable_config_source'` / `undefined method 'overrides'` for the `Settings`-extended class).

- [ ] **Step 3: Implement `overridable_config_source` + `overridable:` in `Settings`**

Replace the `Settings` module body in `lib/axn/configurable.rb` with:

```ruby
    # Class-level flavor: declare validated *instance* settings on a class,
    # reusing the same Setting kernel (defaults, one_of:/validate:, callable:).
    # Used to dogfood Axn's own Configuration without contorting the
    # module-singleton DSL above. `overridable: true` mints the same per-class
    # override accessors (via PerClassOverrides), resolving their library-level
    # fallback from a live singleton the extending class registers.
    #
    #   class Configuration
    #     extend Axn::Configurable::Settings
    #     overridable_config_source { Axn.config }
    #     setting :log_level, default: :info
    #     setting :sidekiq_job_tag_sources, default: [...], overridable: true
    #   end
    module Settings
      include PerClassOverrides

      # Registers the live singleton whose values are the library-level fallback
      # for per-class overrides (e.g. `Axn.config`). Read lazily on each
      # resolution, so a swapped singleton is picked up. Must be declared before
      # any `overridable: true` setting.
      def overridable_config_source(&block)
        @_overridable_config_source = block
      end

      def setting(name, default: nil, one_of: nil, validate: nil, callable: false, overridable: false)
        setting = Setting.new(name: name.to_sym, default:, one_of:, validate:, callable:, overridable:)
        ivar = :"@#{name}"

        define_method(name) do
          instance_variable_set(ivar, setting.dup_default) unless instance_variable_defined?(ivar)
          setting.resolve(instance_variable_get(ivar))
        end

        define_method(:"#{name}=") do |value|
          setting.validate!(value)
          instance_variable_set(ivar, value)
        end

        return unless overridable

        unless @_overridable_config_source
          raise ArgumentError, "setting #{name}: overridable: true requires overridable_config_source to be declared first"
        end

        source = @_overridable_config_source
        _define_override_methods(setting, -> { source.call.public_send(setting.name) })
      end
    end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bundle exec rspec spec/axn/configurable_spec.rb`
Expected: PASS (new `overridable: settings` examples green; all prior examples still green).

- [ ] **Step 5: Run rubocop**

Run: `bundle exec rubocop lib/axn/configurable.rb spec/axn/configurable_spec.rb`
Expected: no offenses.

- [ ] **Step 6: Commit**

```bash
git add lib/axn/configurable.rb spec/axn/configurable_spec.rb
git commit -m "PRO-2856: Add overridable: support to the class-level Settings flavor

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Wire `Axn.config` and the action base; flip `sidekiq_job_tag_sources`

Register the singleton on `Axn::Configuration`, flip the one setting to `overridable: true`, and include the generated overrides module into the action base so every `include Axn` action gets the accessors.

**Files:**
- Modify: `lib/axn/configuration.rb`
- Modify: `lib/axn/core.rb`
- Test: `spec/axn/core/configuration_spec.rb`

**Interfaces:**
- Consumes: `Settings#overridable_config_source` and `overridable:` from Task 2; `Configuration.overrides` (from the mixin).
- Produces: every class that does `include Axn` responds to `sidekiq_job_tag_sources(value = UNSET)`, `resolved_sidekiq_job_tag_sources`, and `raw_sidekiq_job_tag_sources`, with `resolved_` falling back to `Axn.config.sidekiq_job_tag_sources`.

- [ ] **Step 1: Write the failing wire-level tests**

Append to `spec/axn/core/configuration_spec.rb` (before its final `end`) a new top-level describe:

```ruby
RSpec.describe "per-class config overrides on actions" do
  let(:action) { Class.new { include Axn } }

  after { Axn.config.instance_variable_set(:@sidekiq_job_tag_sources, nil) }

  it "gives every action the override accessors for sidekiq_job_tag_sources" do
    expect(action).to respond_to(:sidekiq_job_tag_sources)
    expect(action).to respond_to(:resolved_sidekiq_job_tag_sources)
    expect(action).to respond_to(:raw_sidekiq_job_tag_sources)
  end

  it "resolves to Axn.config by default (no per-class override)" do
    expect(action.resolved_sidekiq_job_tag_sources).to eq(%i[tag dimension])
    expect(action.raw_sidekiq_job_tag_sources).to equal(Axn::Configurable::UNSET)
  end

  it "tracks a change to the library-level value" do
    Axn.config.sidekiq_job_tag_sources = %i[dimension]
    expect(action.resolved_sidekiq_job_tag_sources).to eq(%i[dimension])
  end

  it "resolves to the per-class override when set, leaving Axn.config untouched" do
    action.sidekiq_job_tag_sources %i[dimension]
    expect(action.resolved_sidekiq_job_tag_sources).to eq(%i[dimension])
    expect(Axn.config.sidekiq_job_tag_sources).to eq(%i[tag dimension])
  end

  it "validates a per-class override at set time" do
    expect { action.sidekiq_job_tag_sources %i[bogus] }.to raise_error(ArgumentError)
  end

  it "inherits a per-class override into subclasses" do
    action.sidekiq_job_tag_sources %i[dimension]
    expect(Class.new(action).resolved_sidekiq_job_tag_sources).to eq(%i[dimension])
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `bundle exec rspec spec/axn/core/configuration_spec.rb -e "per-class config overrides on actions"`
Expected: FAIL (`NoMethodError: undefined method 'sidekiq_job_tag_sources'` — the action base doesn't include the overrides yet).

- [ ] **Step 3: Register the singleton and flip the setting in `Configuration`**

In `lib/axn/configuration.rb`, immediately after `extend Axn::Configurable::Settings` (line 11), add:

```ruby
    # The live singleton whose values are the library-level fallback for any
    # `overridable: true` setting's per-class override accessors.
    overridable_config_source { Axn.config }
```

Then change the `sidekiq_job_tag_sources` declaration (currently lines 32-34) to add `overridable: true`:

```ruby
    setting :sidekiq_job_tag_sources,
            default: %i[tag dimension],
            overridable: true,
            validate: ->(v) { v.is_a?(Array) && v.all? { |s| SIDEKIQ_JOB_TAG_SOURCES.include?(s) } }
```

- [ ] **Step 4: Include the overrides module in the action base**

In `lib/axn/core.rb`, inside the `base.class_eval do ... end` block in `Core.included`, add after `include Core::SchemaReflection` (line 81):

```ruby
        # Per-class config overrides: gives the action class-level accessors
        # (`<name>` setter, `resolved_<name>`, `raw_<name>`) for every
        # `overridable: true` setting on Axn.config. See Axn::Configurable.
        include Axn::Configuration.overrides
```

- [ ] **Step 5: Run the wire-level tests to verify they pass**

Run: `bundle exec rspec spec/axn/core/configuration_spec.rb`
Expected: PASS.

- [ ] **Step 6: Run the full non-Rails suite to catch regressions from the action-base include**

Run: `bundle exec rspec spec`
Expected: PASS (the new include must not perturb existing actions).

- [ ] **Step 7: Rubocop**

Run: `bundle exec rubocop lib/axn/configuration.rb lib/axn/core.rb spec/axn/core/configuration_spec.rb`
Expected: no offenses.

- [ ] **Step 8: Commit**

```bash
git add lib/axn/configuration.rb lib/axn/core.rb spec/axn/core/configuration_spec.rb
git commit -m "PRO-2856: Wire config overrides into the action base; make sidekiq_job_tag_sources overridable

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Swap the Sidekiq consumer to `resolved_sidekiq_job_tag_sources`

Read the per-class value at enqueue instead of the global. `self` in `_resolve_sidekiq_job_tags` is the action class, which now carries the accessor.

**Files:**
- Modify: `lib/axn/async/adapters/sidekiq.rb`
- Test: `spec_rails/dummy_app/spec/axn/async/adapters/sidekiq_spec.rb`

**Interfaces:**
- Consumes: `resolved_sidekiq_job_tag_sources` on the action class (from Task 3).

- [ ] **Step 1: Write the failing Rails test**

In `spec_rails/dummy_app/spec/axn/async/adapters/sidekiq_spec.rb`, inside the `describe "job tags from facets (PRO-2855)"` block (after the existing `honors sidekiq_job_tag_sources = [:dimension]` example around line 393), add:

```ruby
    it "honors a per-action sidekiq_job_tag_sources override, independent of the global" do
      # Global default is %i[tag dimension]; this action opts to bounded-only for its own jobs.
      action = stub_const("PerActionBoundedTags", Class.new do
        include Axn
        async :sidekiq
        expects :company_id
        expects :plan, default: "free"
        tag(:company_id) { company_id }
        dimension(:plan) { plan }
        sidekiq_job_tag_sources %i[dimension]
        def call; end
      end)

      action.call_async(company_id: 42, plan: "pro")
      expect(last_job_tags.call).to contain_exactly("plan:pro")
      expect(Axn.config.sidekiq_job_tag_sources).to eq(%i[tag dimension])
    end
```

- [ ] **Step 2: Run to verify failure**

Run (from repo root): `cd spec_rails/dummy_app && BUNDLE_GEMFILE=Gemfile bundle exec rspec spec/axn/async/adapters/sidekiq_spec.rb -e "per-action sidekiq_job_tag_sources override"`
Expected: FAIL — the adapter still reads the global `Axn.config.sidekiq_job_tag_sources` (`%i[tag dimension]`), so `company_id:42` also surfaces and the `contain_exactly("plan:pro")` expectation fails.

- [ ] **Step 3: Swap the read site**

In `lib/axn/async/adapters/sidekiq.rb`, in `_resolve_sidekiq_job_tags` change:

```ruby
            sources = Axn.config.sidekiq_job_tag_sources
```
to:
```ruby
            sources = resolved_sidekiq_job_tag_sources
```

And update the neighboring comment (the sentence ending `for the sources enabled by Axn.config.sidekiq_job_tag_sources.`) to read `for the sources enabled by resolved_sidekiq_job_tag_sources (per-class override → Axn.config fallback).`

- [ ] **Step 4: Run the per-action test to verify it passes**

Run (from `spec_rails/dummy_app`): `BUNDLE_GEMFILE=Gemfile bundle exec rspec spec/axn/async/adapters/sidekiq_spec.rb -e "per-action sidekiq_job_tag_sources override"`
Expected: PASS.

- [ ] **Step 5: Run the whole job-tags describe block to confirm no regression**

Run (from `spec_rails/dummy_app`): `BUNDLE_GEMFILE=Gemfile bundle exec rspec spec/axn/async/adapters/sidekiq_spec.rb -e "job tags from facets"`
Expected: PASS (existing global-stub test still green — stubbing `Axn.config.sidekiq_job_tag_sources` flows through `resolved_` as the fallback when no per-class override is set).

- [ ] **Step 6: Rubocop**

Run (from repo root): `bundle exec rubocop lib/axn/async/adapters/sidekiq.rb`
Expected: no offenses.

- [ ] **Step 7: Commit**

```bash
git add lib/axn/async/adapters/sidekiq.rb spec_rails/dummy_app/spec/axn/async/adapters/sidekiq_spec.rb
git commit -m "PRO-2856: Read per-class sidekiq_job_tag_sources at enqueue

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: Document the per-class override API

Add a general "Per-Class Overrides" section and show the per-action `sidekiq_job_tag_sources` example.

**Files:**
- Modify: `docs/reference/configuration.md`

- [ ] **Step 1: Add a "Per-Class Overrides" section**

In `docs/reference/configuration.md`, after the opening `Axn.configure` example (after line 17, before `## on_exception`), insert:

````markdown
## Per-Class Overrides

Most settings are global — one value for every action. A few are also **per-axn overridable**: an individual action can override the library-level value for its own runs (and its subclasses'), falling back to `Axn.config` when it doesn't. Currently `sidekiq_job_tag_sources` is the overridable setting.

For each overridable setting, every action gets three class-level accessors:

```ruby
class ChargeCompany
  include Axn

  sidekiq_job_tag_sources %i[dimension]   # set this class's override

  # sidekiq_job_tag_sources               # → resolved value (override → Axn.config fallback)
  # resolved_sidekiq_job_tag_sources      # → same resolved value, explicit name
  # raw_sidekiq_job_tag_sources           # → this class's override, or unset (no fallback)
end
```

- The bare `name`/`resolved_name` read the **resolved** value: the nearest override up the class ancestry, or `Axn.config`'s value if none is set.
- `raw_name` returns only an override (the class's own or an inherited one); it does **not** fall back to `Axn.config`, so a caller can tell "no override" from "resolves to the global default".
- Overrides are inherited by subclasses and never leak to siblings. Setting one leaves `Axn.config` untouched.
````

- [ ] **Step 2: Update the `sidekiq_job_tag_sources` docs to show the per-action override**

In the "Surfacing facets as Sidekiq job tags" subsection, after the existing block showing `Axn.config.sidekiq_job_tag_sources # => default %i[tag dimension]` (around line 291), add:

````markdown
This is per-axn overridable — an individual action can narrow (or disable) its own job tags without changing the global:

```ruby
class ChargeCompany
  include Axn
  async :sidekiq

  sidekiq_job_tag_sources %i[dimension]   # this action's jobs carry bounded tags only
end
```

The Sidekiq adapter reads `resolved_sidekiq_job_tag_sources` at enqueue, so the per-class value wins with the global as fallback. See [Per-Class Overrides](#per-class-overrides).
````

- [ ] **Step 3: Verify the docs build (if the docs toolchain is set up locally)**

Run: `grep -n "Per-Class Overrides" docs/reference/configuration.md`
Expected: two matches (the section heading and the cross-link), confirming the anchor and reference are present. (A full VitePress build is optional; CI covers it.)

- [ ] **Step 4: Commit**

```bash
git add docs/reference/configuration.md
git commit -m "PRO-2856: Document per-class config overrides

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Final verification

- [ ] **Run the full verification suite**

Run (from repo root): `bundle exec rake verify`
Expected: PASS (`spec`, `spec_rubocop`, `spec_rails`, `rubocop`, `verify_async` all green).

If `rake verify` is too heavy for a quick loop, the equivalent pieces are:
- `bundle exec rspec spec`
- `cd spec_rails/dummy_app && BUNDLE_GEMFILE=Gemfile bundle exec rspec spec/`
- `bundle exec rubocop`
