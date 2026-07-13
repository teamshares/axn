# Config Predicate Readers + Override-Accessor Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add generated `name?` predicate readers to the config DSL (class flavor + per-class override accessors), remove the redundant `resolved_<name>` accessor, and rename `raw_<name>` to `<name>_override`.

**Architecture:** All production changes live in `lib/axn/configurable.rb` — the `Settings` class flavor's `setting` method and the shared `PerClassOverrides#_define_override_methods` generator (which serves both config flavors). Comment/doc touch-ups ripple to `lib/axn/core.rb`, `lib/axn/async/adapters/sidekiq.rb`, two docs pages, and the CHANGELOG.

**Tech Stack:** Ruby gem (axn), RSpec. No new dependencies.

**Spec:** `internal-docs/specs/2026-07-13-config-predicate-readers-and-accessor-cleanup-design.md`

## Global Constraints

- axn must work outside Rails; nothing here may reference Rails constants unguarded (no new env access is needed).
- Predicates are generated **unconditionally** for every setting — no `predicate:` opt-in knob (parity with the module flavor's `Config#method_missing`, which already answers `?`).
- Framework code keeps resolving through `resolve_override_for`; no `resolve_predicate_for` variant.
- `<name>_override` keeps returning the `Axn::Configurable::UNSET` sentinel when no override is set (never collapse to nil).
- Docs prose: no manual line breaks — one line per paragraph.
- Run specs with `bundle exec rspec <path>` from the repo root. The `spec_rails` suite needs the dummy-app bundle: `cd spec_rails/dummy_app && BUNDLE_GEMFILE=Gemfile bundle exec rspec <path relative to dummy_app>`.
- Run `bundle exec rubocop <changed files>` before each commit; fix offenses.
- End every commit message with a blank line then `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` (omitted from the inline `git commit -m` examples below for brevity — add it).
- Line numbers below are from the state at plan-writing time and shift as tasks land — match on content.

---

### Task 1: Predicate readers on the class flavor (`Settings#setting`)

**Files:**
- Modify: `lib/axn/configurable.rb` (the `Settings#setting` method, currently lines 461–481)
- Test: `spec/axn/configurable_spec.rb`

**Interfaces:**
- Produces: instance method `#{name}?` on any class extending `Axn::Configurable::Settings`, for every declared setting — returns `!!` of the same resolved read as the bare `name` reader. Task 5's docs describe this.

- [ ] **Step 1: Write the failing tests**

In `spec/axn/configurable_spec.rb`, inside the top-level `RSpec.describe Axn::Configurable::Settings` block (after the `it "gives each instance its own copy of a mutable default"` example, before `describe "overridable: settings"`), add:

```ruby
  describe "predicate readers" do
    let(:klass) do
      Class.new do
        extend Axn::Configurable::Settings

        setting :sandbox_mode, default: -> { true }, callable: true
        setting :emit_metrics
      end
    end

    it "returns true for a truthy resolved value (callable default)" do
      expect(instance.sandbox_mode?).to be(true)
    end

    it "returns false for an explicitly-assigned false" do
      instance.sandbox_mode = false
      expect(instance.sandbox_mode?).to be(false)
    end

    it "returns false when the setting resolves to nil" do
      expect(instance.emit_metrics?).to be(false)
    end
  end
```

(The outer block's `subject(:instance) { klass.new }` picks up the nested `let(:klass)` override.)

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec rspec spec/axn/configurable_spec.rb -e "predicate readers"`
Expected: 3 failures, each `NoMethodError` (`sandbox_mode?` / `emit_metrics?` undefined).

- [ ] **Step 3: Implement**

In `lib/axn/configurable.rb`, in `Settings#setting`, add the predicate right after the existing reader definition:

```ruby
        define_method(name) do
          instance_variable_set(ivar, setting.dup_default) unless instance_variable_defined?(ivar)
          setting.resolve(instance_variable_get(ivar))
        end

        define_method(:"#{name}?") { !!public_send(name) }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bundle exec rspec spec/axn/configurable_spec.rb`
Expected: all green (new predicates pass, nothing else disturbed).

- [ ] **Step 5: Commit**

```bash
bundle exec rubocop lib/axn/configurable.rb spec/axn/configurable_spec.rb
git add lib/axn/configurable.rb spec/axn/configurable_spec.rb
git commit -m "Add <name>? predicate readers to the Settings config flavor"
```

---

### Task 2: Predicate readers on the per-class override accessors

**Files:**
- Modify: `lib/axn/configurable.rb` (`_define_override_methods`, currently lines 253–304; `_warn_on_shadowed_overrides`, currently lines 160–172)
- Test: `spec/axn/configurable_spec.rb`, `spec/axn/core/configuration_spec.rb`

**Interfaces:**
- Consumes: nothing from Task 1 (independent code paths; both flavors share `_define_override_methods`).
- Produces: class method `#{name}?` on any class that includes a source's `overrides` module, for every `overridable: true` setting — returns `!!resolve_override.call(self)` (full chain: per-class override → ancestry → library fallback → callable resolution). Shadow warnings now fire for the `?` name too. Task 4 appends `:"#{name}_override"` to the same warn list; Task 5 documents the accessor.

- [ ] **Step 1: Write the failing tests**

In `spec/axn/configurable_spec.rb`, inside `RSpec.describe Axn::Configurable` → `describe "overridable: settings"` (after the `it "picks up overridable settings declared after..."` example, before `describe "raw_<name>..."`), add:

```ruby
    describe "<name>?: boolean read of the resolved value" do
      let(:boolean_mod) do
        Module.new do
          extend Axn::Configurable
          setting :enabled, default: true, callable: true, overridable: true
        end
      end

      let(:boolean_class) do
        mod = boolean_mod.overrides
        Class.new { include mod }
      end

      it "reflects the library default when no override is set" do
        expect(boolean_class.enabled?).to be(true)
      end

      it "reflects a falsey per-class override" do
        boolean_class.enabled(false)
        expect(boolean_class.enabled?).to be(false)
      end

      it "resolves a callable default at read time" do
        boolean_mod.config.enabled = -> { false }
        expect(boolean_class.enabled?).to be(false)
      end

      it "inherits a parent's override" do
        boolean_class.enabled(false)
        expect(Class.new(boolean_class).enabled?).to be(false)
      end

      it "is not generated for non-overridable settings" do
        plain = Module.new do
          extend Axn::Configurable
          setting :default_model, default: "x"
        end
        klass = Class.new { include plain.overrides }
        expect(klass).not_to respond_to(:default_model?)
      end
    end
```

In the same file, inside `RSpec.describe Axn::Configurable::Settings` → `describe "overridable: settings"` (after the `it "inherits an override from a parent class"` example), add:

```ruby
    it "exposes <name>? resolving override then live singleton" do
      expect(action_class.mode?).to be(true) # :a is truthy
    end
```

In `spec/axn/core/configuration_spec.rb`, inside `describe "collision with a non-axn ancestor's same-named class method"`, add:

```ruby
    it "leaves a breadcrumb when the predicate name collides" do
      predicate_base = Class.new { def self.sidekiq_job_tag_sources? = :base_value }
      messages = []
      allow(Axn.config.logger).to receive(:debug) { |*args, &block| messages << (block ? block.call : args.first) }
      Class.new(predicate_base) { include Axn }
      expect(messages).to include(a_string_matching(/override accessor `sidekiq_job_tag_sources\?` collides/))
    end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec rspec spec/axn/configurable_spec.rb spec/axn/core/configuration_spec.rb`
Expected: the new examples fail (`NoMethodError: enabled?` / `mode?`; breadcrumb example finds no matching message). Everything pre-existing passes.

- [ ] **Step 3: Implement**

In `lib/axn/configurable.rb`, in `_define_override_methods`, add the predicate inside the `module_eval` block (after the `define_method(name)` block):

```ruby
          define_method(:"#{name}?") { !!resolve_override.call(self) }
```

In `_warn_on_shadowed_overrides`, wrap the check so each generated name is checked (structure Task 4 will extend):

```ruby
        _override_resolvers.each_key do |name|
          [name, :"#{name}?"].each do |accessor|
            next unless Axn::Core::MethodShadowing.externally_defined?(base, accessor)

            Axn.config.logger.debug do
              "[Axn] #{base.name || 'Action'}: per-class override accessor `#{accessor}` collides with a same-named " \
                "class method from a non-axn ancestor (axn installs the accessor anyway; reads route through " \
                "resolve_override_for). See PRO-2856."
            end
          end
        end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bundle exec rspec spec/axn/configurable_spec.rb spec/axn/core/configuration_spec.rb`
Expected: all green.

- [ ] **Step 5: Commit**

```bash
bundle exec rubocop lib/axn/configurable.rb spec/axn/configurable_spec.rb spec/axn/core/configuration_spec.rb
git add lib/axn/configurable.rb spec/axn/configurable_spec.rb spec/axn/core/configuration_spec.rb
git commit -m "Add <name>? predicate to per-class override accessors"
```

---

### Task 3: Remove `resolved_<name>`

**Files:**
- Modify: `lib/axn/configurable.rb`, `lib/axn/core.rb:84-86` (comment), `lib/axn/async/adapters/sidekiq.rb:137-146` (comment)
- Test: `spec/axn/configurable_spec.rb`, `spec/axn/core/configuration_spec.rb`, `spec_rails/dummy_app/spec/axn/async/adapters/sidekiq_spec.rb`

**Interfaces:**
- Consumes: the bare `name` reader (unchanged) — every `resolved_<name>` call site becomes a no-arg `name` call, which routes through the identical `resolve_override` closure.
- Produces: `resolved_<name>` no longer defined anywhere; a `not_to respond_to(:resolved_...)` regression test pins the removal.

- [ ] **Step 1: Update the specs (red)**

In `spec/axn/configurable_spec.rb`:

1. Replace every read of `resolved_mcp_text_content` with `mcp_text_content` (currently lines 88, 93, 98, 108, 115), `resolved_enabled` → `enabled` (line 137), `resolved_late` → `late` (lines 147, 149), `resolved_mode` → `mode` (lines 265, 269, 271, 276, 285), and `single.resolved_shared` → `single.shared` (line 417). Example shape after the change:

```ruby
    it "resolves to the library default when no override is set" do
      expect(action_class.mcp_text_content).to eq(:structured)
    end
```

2. In `it "does not generate override accessors for non-overridable settings"` (line 124), change the assertion to the bare name (non-overridable settings generate no accessors at all):

```ruby
      expect(klass).not_to respond_to(:default_model)
```

3. In the module-flavor `describe "consumer-defined accessor collisions"`: in the first example (shadows `raw_mcp_text_content`), delete the `expect(action_class.resolved_mcp_text_content).to eq(:message)` line (keep the bare-reader assertion). Replace the second example (`it "reads via Axn's resolution even when the class shadows resolved_<name>"`) entirely with a removal pin:

```ruby
      it "does not define a resolved_<name> alias (removed; use the bare reader)" do
        expect(action_class).not_to respond_to(:resolved_mcp_text_content)
      end
```

4. In the Settings-flavor collision example (line 308), delete the `expect(action_class.resolved_mode).to eq(:b)` line (keep `expect(action_class.mode).to eq(:b)`).

5. In `.resolve_override_for` → `it "resolves the override even when the class shadows every generated accessor"` (line 317), replace the `resolved_mode` shadow line with the predicate (the current generated set):

```ruby
        action_class.define_singleton_method(:mode) { |*| :hijacked }
        action_class.define_singleton_method(:mode?) { :hijacked }
        action_class.define_singleton_method(:raw_mode) { :hijacked }
```

In `spec/axn/core/configuration_spec.rb`:

6. Replace every `resolved_sidekiq_job_tag_sources` read with the bare `sidekiq_job_tag_sources` (currently lines 235, 242, 246, 257, 266, 271, 276, 281, and in the collision `it "still installs the opt-in accessor (does not defer)"` example).

7. Rewrite the accessor-surface test (line 229):

```ruby
  it "gives every action the override accessors for sidekiq_job_tag_sources" do
    expect(action).to respond_to(:sidekiq_job_tag_sources)
    expect(action).to respond_to(:sidekiq_job_tag_sources?)
    expect(action).to respond_to(:raw_sidekiq_job_tag_sources)
    expect(action).not_to respond_to(:resolved_sidekiq_job_tag_sources)
  end
```

In `spec_rails/dummy_app/spec/axn/async/adapters/sidekiq_spec.rb` (line 413), retarget the shadow from the removed alias to the bare generated reader — the DSL setter call must come before the shadow `def`, which replaces the generated method on the singleton:

```ruby
    it "honors the override even when the action shadows the generated reader" do
      # The adapter resolves through Axn's override store (Configuration.resolve_override_for), not
      # the shadowable generated reader. Here the shadow claims both sources, but the real per-class
      # override is bounded-only — so honoring the override (not the shadow) yields just the dimension tag.
      action = stub_const("ShadowedTagSourcesReader", Class.new do
        include Axn
        async :sidekiq
        expects :company_id
        expects :plan, default: "free"
        tag(:company_id) { company_id }
        dimension(:plan) { plan }
        sidekiq_job_tag_sources %i[dimension]
        def self.sidekiq_job_tag_sources(*) = %i[tag dimension]
        def call; end
      end)

      action.call_async(company_id: 42, plan: "pro")
      expect(last_job_tags.call).to contain_exactly("plan:pro")
    end
```

- [ ] **Step 2: Run the specs to verify the new expectations fail**

Run: `bundle exec rspec spec/axn/configurable_spec.rb spec/axn/core/configuration_spec.rb`
Expected: the two `not_to respond_to(:resolved_...)` pins FAIL (method still exists); everything else passes (bare reader already behaves identically).

- [ ] **Step 3: Implement the removal**

In `lib/axn/configurable.rb`:

1. In `_define_override_methods`'s `module_eval` block, delete the line:

```ruby
          define_method(:"resolved_#{name}") { resolve_override.call(self) }
```

2. Update the `resolve_override_for` docstring (currently lines 129–135): change "the generated `<name>` / `resolved_<name>` readers are all shadowable" to "the generated `<name>` / `<name>?` readers are all shadowable".

3. Update the `_define_override_methods` docstring (currently lines 244–252): change "Generates `<name>(value = UNSET)` / `raw_<name>` / `resolved_<name>` on the shared methods module" to "Generates `<name>(value = UNSET)` / `<name>?` / `raw_<name>` on the shared methods module", and in the closure-captured-helpers paragraph change "a consumer class that happens to define its own `raw_<name>`/`resolved_<name>` class method" to "a consumer class that happens to define its own same-named class method".

In `lib/axn/core.rb` (lines 84–86), update the comment:

```ruby
        # Per-class config overrides: gives the action class-level accessors
        # (`<name>` setter/reader, `<name>?`, `raw_<name>`) for every
        # `overridable: true` setting on Axn.config. See Axn::Configurable.
```

In `lib/axn/async/adapters/sidekiq.rb` (comment above `_resolve_sidekiq_job_tags`), change "rather than the action's generated `sidekiq_job_tag_sources`/`resolved_…` reader: those are class methods" to "rather than the action's generated `sidekiq_job_tag_sources` reader: that is a class method".

- [ ] **Step 4: Run the full suites to verify green**

Run: `bundle exec rspec`
Expected: all green.
Run: `cd spec_rails/dummy_app && BUNDLE_GEMFILE=Gemfile bundle exec rspec spec/axn/async/adapters/sidekiq_spec.rb; cd ../..`
Expected: all green, including the retargeted shadow test.

- [ ] **Step 5: Commit**

```bash
bundle exec rubocop lib/axn/configurable.rb lib/axn/core.rb lib/axn/async/adapters/sidekiq.rb spec/axn/configurable_spec.rb spec/axn/core/configuration_spec.rb
git add -A lib spec spec_rails
git commit -m "Remove redundant resolved_<name> override accessor"
```

---

### Task 4: Rename `raw_<name>` → `<name>_override`

**Files:**
- Modify: `lib/axn/configurable.rb`
- Test: `spec/axn/configurable_spec.rb`, `spec/axn/core/configuration_spec.rb`

**Interfaces:**
- Consumes: Task 2's `[name, :"#{name}?"]` warn-list structure; Task 3's final generated set (`name`, `name?`, `raw_name`).
- Produces: `#{name}_override` (same semantics as old `raw_#{name}`: nearest override in the ancestry or `Axn::Configurable::UNSET`, no fallback, no `Setting#resolve`). `raw_#{name}` no longer defined. Final accessor family: `name`, `name?`, `name_override` + framework `resolve_override_for`.

- [ ] **Step 1: Update the specs (red)**

In `spec/axn/configurable_spec.rb`:

1. Retitle the describe block (line 152): `describe "<name>_override: the override with no config fallback"` and replace every `raw_mcp_text_content` inside it with `mcp_text_content_override` (lines 154, 161, 168, 176). Update the non-generation example (line 179):

```ruby
      it "does not generate <name>_override for non-overridable settings" do
        plain = Module.new do
          extend Axn::Configurable
          setting :default_model, default: "x"
        end
        klass = Class.new { include plain.overrides }

        expect(klass).not_to respond_to(:default_model_override)
      end
```

2. Add a removal pin inside the same describe block:

```ruby
      it "does not define a raw_<name> alias (renamed to <name>_override)" do
        expect(action_class).not_to respond_to(:raw_mcp_text_content)
      end
```

3. Module-flavor collision test (line 191): retitle to `"resolves via Axn's override store even when the class shadows <name>_override"` and shadow `:mcp_text_content_override` instead of `:raw_mcp_text_content`.

4. Settings-flavor: `raw_mode` → `mode_override` in the `exposes raw_<name>...` example (retitle to `"exposes <name>_override as the override with no singleton fallback"`, lines 288–292), the collision example (lines 304–310, retitle likewise), and the shadows-every-accessor example (line 318: `define_singleton_method(:mode_override) { :hijacked }`).

In `spec/axn/core/configuration_spec.rb`: replace `raw_sidekiq_job_tag_sources` with `sidekiq_job_tag_sources_override` everywhere (the respond_to surface test from Task 3 and the UNSET assertion at line ~236).

- [ ] **Step 2: Run the specs to verify they fail**

Run: `bundle exec rspec spec/axn/configurable_spec.rb spec/axn/core/configuration_spec.rb`
Expected: renamed examples FAIL with `NoMethodError` (`..._override` undefined); the removal pin fails (`raw_...` still defined).

- [ ] **Step 3: Implement the rename**

In `lib/axn/configurable.rb`, in `_define_override_methods`:

1. Rename the generated method:

```ruby
          define_method(:"#{name}_override") { raw_lookup.call(self) }
```

2. Rename the local closure `raw_lookup` → `override_lookup` (declaration and both call sites: the `define_method(:"#{name}_override")` body and the first line of the `resolve_override` lambda).

3. In `_warn_on_shadowed_overrides`, extend the per-setting name list from Task 2 to `[name, :"#{name}?", :"#{name}_override"]`.

4. Update the `_define_override_methods` docstring again: "Generates `<name>(value = UNSET)` / `<name>?` / `<name>_override` on the shared methods module".

- [ ] **Step 4: Run the full suite to verify green**

Run: `bundle exec rspec`
Expected: all green. (`spec_rails` is untouched by this task — the sidekiq spec references neither accessor after Task 3.)

- [ ] **Step 5: Commit**

```bash
bundle exec rubocop lib/axn/configurable.rb spec/axn/configurable_spec.rb spec/axn/core/configuration_spec.rb
git add lib/axn/configurable.rb spec/axn/configurable_spec.rb spec/axn/core/configuration_spec.rb
git commit -m "Rename raw_<name> override accessor to <name>_override"
```

---

### Task 5: Documentation + CHANGELOG

**Files:**
- Modify: `docs/reference/configuration.md`, `docs/recipes/gem-configuration.md`, `CHANGELOG.md`

**Interfaces:**
- Consumes: the final accessor family from Tasks 1–4 (`name`, `name?`, `name_override`, `resolve_override_for`).
- Produces: user-facing docs matching the shipped surface; no code.

- [ ] **Step 1: Update `docs/reference/configuration.md`**

Replace the accessor block + bullets (lines 23–39) with:

````markdown
For each overridable setting, every action gets three class-level accessors:

```ruby
class ChargeCompany
  include Axn

  sidekiq_job_tag_sources %i[dimension]   # set this class's override

  # sidekiq_job_tag_sources               # → resolved value (override → Axn.config fallback)
  # sidekiq_job_tag_sources?              # → same resolved value, as a boolean
  # sidekiq_job_tag_sources_override      # → this class's override, or unset (no fallback)
end
```

- The bare `name` reads the **resolved** value: the nearest override up the class ancestry, or `Axn.config`'s value if none is set. `name?` is the same read, coerced to a boolean.
- `name_override` returns only an override (the class's own or an inherited one); it does **not** fall back to `Axn.config`, so a caller can tell "no override" from "resolves to the global default".
- Overrides are inherited by subclasses and never leak to siblings. Setting one leaves `Axn.config` untouched.
````

At line ~362, change "The Sidekiq adapter reads `resolved_sidekiq_job_tag_sources` at enqueue" to "The Sidekiq adapter reads the resolved `sidekiq_job_tag_sources` at enqueue".

- [ ] **Step 2: Update `docs/recipes/gem-configuration.md`**

1. In the options table, extend two rows:

```markdown
| `validate:` | A callable returning truthy for valid values; anything else raises `ArgumentError`. The callable may instead raise its own `ArgumentError` for a custom message. |
| `callable:` | When `true`, a proc value is resolved (called) at read time — useful for a setting like `enabled` that may be a static boolean or a dynamic check. A callable **default** is re-evaluated on every read, so "unset ⇒ derive from the environment now" is expressible: `setting :sandbox_mode, default: -> { defined?(Rails) ? !Rails.env.production? : true }, callable: true`. |
```

2. Update the example reads (lines 59–60):

```ruby
MyTool.mcp_text_content    # => :message
PlainTool.mcp_text_content # => :structured (falls back to Axn::MCP.config)
```

3. Replace the stale closing paragraph (line 65 — it claims there is no raw-override accessor) with:

```markdown
The no-argument `<name>` reader is the supported way to read an overridable setting — it always returns the effective value (`<name>?` is the same read as a boolean). When a caller needs to distinguish "no override anywhere in the ancestry" from "resolves to the library default", `<name>_override` returns the stored override with no config fallback, or the `Axn::Configurable::UNSET` sentinel when none is set. The internal storage where overrides are kept is private — don't reach into it.
```

- [ ] **Step 3: Update `CHANGELOG.md`**

1. Add a new entry at the top of `## Unreleased`:

```markdown
* [BREAKING] Per-class override accessors cleaned up: every setting (both config flavors) now also generates a `<name>?` predicate reading the same resolved value as a boolean, the redundant `resolved_<name>` alias is removed (it was byte-for-byte the no-arg `<name>` read — use that), and `raw_<name>` is renamed `<name>_override` (same semantics: the stored override or the `Axn::Configurable::UNSET` sentinel, no config fallback, no callable resolution). Breaking only within unreleased pre-1.0 surface; known internal consumers (data_shifter's `raw_progress_enabled`/`resolved_*`, axn-mcp's `resolved_mcp_text_content`) migrate with the version bump.
```

2. In the existing unreleased PRO-2856 entry, update the accessor description so the changelog doesn't document never-released methods: change "`resolved_<name>` (or the bare `<name>` reader) resolves the nearest override up the class ancestry and falls back to `Axn.config` when none is set, and `raw_<name>` returns the override or the `Axn::Configurable::UNSET` sentinel with no fallback" to "the bare `<name>` reader (and its `<name>?` boolean form) resolves the nearest override up the class ancestry and falls back to `Axn.config` when none is set, and `<name>_override` returns the override or the `Axn::Configurable::UNSET` sentinel with no fallback", and at the end of that entry change "the Sidekiq adapter reads `resolved_sidekiq_job_tag_sources` at enqueue" to "the Sidekiq adapter resolves `sidekiq_job_tag_sources` through the override store at enqueue".

- [ ] **Step 4: Verify docs build cleanly and the suite is still green**

Run: `bundle exec rspec`
Expected: all green (docs-only change; this is the final full-suite gate).
Run: `grep -rn "resolved_\|raw_" docs/reference/configuration.md docs/recipes/gem-configuration.md | grep -v "resolved_axn_name"`
Expected: no hits referencing the removed/renamed config accessors.

- [ ] **Step 5: Commit**

```bash
git add docs/reference/configuration.md docs/recipes/gem-configuration.md CHANGELOG.md
git commit -m "Document <name>? predicates and <name>_override; update CHANGELOG"
```

---

## Out of scope (follow-up PRs in sibling repos, after the axn bump)

- **data_shifter:** `resolved_progress_enabled`/`resolved_suppress_repeated_logs` → bare getters; `raw_progress_enabled` → `progress_enabled_override`; update the `shift.rb` comments describing the accessor pair.
- **axn-mcp:** `resolved_mcp_text_content` → `mcp_text_content` (`tool.rb`, `wrap.rb`, specs).
- **slack_sender:** convert `sandbox_mode` (callable default, `overridable: true`), `async_backend` (callable default, `one_of: [*SUPPORTED_ASYNC_BACKENDS, nil]`), `max_async_file_upload_size` (raising `validate:`) to `setting`; keep `async_backend_available?` hand-written.
