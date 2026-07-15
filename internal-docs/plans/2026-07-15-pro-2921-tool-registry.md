# PRO-2921 — Tool support: registry + canonical `tool_name` — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give axn core one canonical, provider-safe `tool_name` derivation plus a shared tool registry (`tool` DSL + adapter self-registration + `Axn.tools_for`), so a tool is declared once and every adapter (axn-mcp, axn-ruby_llm) sees the same membership and name.

**Architecture:** A new `Axn::Core::Tools` mixin (included into every Axn) adds the `tool` class-DSL, per-class membership/name storage, and the `tool_name` derivation. A separate `Axn::Tools::Registry` singleton module holds process-global state: registered adapter keys, the set of every `include Axn` class, membership resolution, and on-demand eager-loading of the configured tool directories. `Axn.register_tool_adapter` / `Axn.tools_for` are thin facades over the registry. Two new `Axn.config` settings (`tool_paths`, `tool_name_stripped_prefixes`) drive discovery and naming respectively.

**Tech Stack:** Ruby, ActiveSupport (`String#underscore`/`#camelize`, `String#safe_constantize`), Zeitwerk 2.7.x (`eager_load_dir`), RSpec. Must run **outside Rails** (`spec/`) and **inside Rails** (`spec_rails/dummy_app`).

## Global Constraints

- **Works outside Rails.** No hard dependency on Rails/ActiveRecord being loaded — guard every `Rails`/`ActiveRecord` reference with `defined?(...)`. `spec/` runs without Rails; `spec_rails/dummy_app/` is the Rails app. Rails-adjacent changes are tested in **both**. (from AGENTS.md)
- **TDD.** Failing test first, then implementation. (from AGENTS.md / CONTRIBUTING.md)
- **Fail at declaration, not runtime.** DSL misuse (`tool false, name:`, non-Symbol adapters) raises `ArgumentError` when the class is *defined*, with a message saying how to fix it. (from AGENTS.md)
- **Programmer error vs bad data.** `Axn.tools_for(:unregistered)` (a caller asking for an unknown adapter) → `ArgumentError`. A `tool :typo` *declaration* is stored tolerantly (adapters self-register at load; a hard declaration-time check is load-order-hostile in multi-process setups) and simply never matches any `tools_for` — the fail-safe direction. (ticket "Decisions locked"; mirrors PRO-2880 namespaced-config validate-on-read)
- **Membership is fail-safe, never fail-open.** Only dedicated `tool_paths` dirs auto-register. `tool_paths` MUST NOT include bare `actions`. A forgotten marker means "not exposed." (ticket)
- **No historical comments.** Comments describe current behavior + intrinsic why, never "used to X / now Y" or ticket-review notes. (user memory)
- **No manual line breaks in Markdown prose** in any docs touched — one line per paragraph. (user memory)
- Default `tool_paths`: `%w[agent_tools actions/tools]`. Default `tool_name_stripped_prefixes`: `%w[actions tools agent_tools]`. (ticket §D — copy verbatim)

## Design decisions locked for this plan (beyond the ticket)

- **Directory-authoritative auto-registration.** Membership resolution step 2 ("Axn under a configured tool path auto-registers") is decided by `Object.const_source_location(klass.name)&.first` landing under a resolved `tool_path` directory — NOT by module-prefix match. Rationale: default Rails autoload roots strip the root segment from the module path (`app/actions` root ⇒ `app/actions/tools/foo.rb` → `Tools::Foo`), so a folder-path string cannot reliably double as a module prefix; directory-based membership stays consistent with the directory-based eager-loader and needs no folder↔module coincidence. This supersedes the ticket's tentative module-prefix suggestion (which it explicitly left to "confirm during implementation").
- **`tool_paths` entries resolve to `Rails.root/app/<path>` under Rails**, and to `File.expand_path(<path>)` (cwd- or absolute) outside Rails. The camelized form is never used for membership.
- **`tool_name` is a class method on every Axn** (derives from `resolved_axn_name`); it does not require registry membership, so `extras/strategies/vernier.rb` can reuse it directly.
- **Registry filters to currently-defined named classes at read time** (`klass.name` present and `klass.name.safe_constantize.equal?(klass)`), which drops anonymous classes and stale reloaded-class references without a reload hook.

## File Structure

**Create:**
- `lib/axn/core/tools.rb` — `Axn::Core::Tools`: the `tool` DSL, `_tool_declaration` / `_tool_name_override` storage, and `tool_name` derivation. Included into `Axn::Core`.
- `lib/axn/tools/registry.rb` — `Axn::Tools::Registry`: adapter-key set, global class set, membership resolution, `tools_for`, eager-loading.
- `spec/axn/core/tool_name_spec.rb` — `tool_name` derivation unit tests.
- `spec/axn/core/tool_dsl_spec.rb` — `tool` DSL storage + validation tests.
- `spec/axn/tools/registry_spec.rb` — adapters, class tracking, membership, `tools_for` (non-Rails).
- `spec/support/fixtures/registry_tools/lazy_registry_tool.rb` — fixture for the non-Rails require-fallback test.
- `spec_rails/dummy_app/app/actions/tools/sample_widget.rb` — fixture tool for the Rails `eager_load_dir` test.
- `spec_rails/dummy_app/spec/axn/tools_eager_load_spec.rb` — Rails on-demand eager-load test.

**Modify:**
- `lib/axn/configuration.rb` — add `tool_paths` and `tool_name_stripped_prefixes` settings.
- `lib/axn/core.rb` — `require "axn/core/tools"` and `include Core::Tools`.
- `lib/axn.rb` — `require "axn/tools/registry"`; register every `include Axn` class; add `Axn.register_tool_adapter` / `Axn.tools_for`.
- `lib/axn/extras/strategies/vernier.rb` — replace the ad-hoc `resolved_axn_name.gsub(...)` with `self.class.tool_name`.
- `spec/axn/core/configuration_spec.rb` — defaults + override tests for the two new settings.
- `spec/axn/extras/strategies/vernier_spec.rb` — assert the profile filename uses `tool_name`.
- `spec/spec_helper.rb` (or `spec/support/*`) — reset registry adapter state between examples.
- `CHANGELOG.md` — `[FEAT]` entry.
- `AGENTS.md` — one-line note on the tool registry seam (optional, see Task 9).

---

## Task 1: Config settings — `tool_paths` and `tool_name_stripped_prefixes`

**Files:**
- Modify: `lib/axn/configuration.rb` (add two `setting` declarations alongside `coerce_input_types`, ~line 57)
- Test: `spec/axn/core/configuration_spec.rb`

**Interfaces:**
- Produces: `Axn.config.tool_paths : Array(String)` (default `%w[agent_tools actions/tools]`), `Axn.config.tool_name_stripped_prefixes : Array(String)` (default `%w[actions tools agent_tools]`, `overridable: true`). Per-class override accessor `tool_name_stripped_prefixes` is minted on every Axn via the existing `Axn::Configuration.overrides`.

- [ ] **Step 1: Write the failing test**

Add to `spec/axn/core/configuration_spec.rb`, inside the `RSpec.describe Axn::Configuration` block's `"defaults (in test mode)"` example group:

```ruby
it { expect(config.tool_paths).to eq(%w[agent_tools actions/tools]) }
it { expect(config.tool_name_stripped_prefixes).to eq(%w[actions tools agent_tools]) }

describe "#tool_paths=" do
  it "accepts an array of strings" do
    config.tool_paths = %w[agent_tools]
    expect(config.tool_paths).to eq(%w[agent_tools])
  end

  it "rejects a non-array" do
    expect { config.tool_paths = "agent_tools" }.to raise_error(ArgumentError)
  end
end

describe "#tool_name_stripped_prefixes=" do
  it "accepts an array of strings" do
    config.tool_name_stripped_prefixes = %w[actions]
    expect(config.tool_name_stripped_prefixes).to eq(%w[actions])
  end

  it "rejects a non-array" do
    expect { config.tool_name_stripped_prefixes = :actions }.to raise_error(ArgumentError)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/core/configuration_spec.rb`
Expected: FAIL — `NoMethodError`/undefined `tool_paths`.

- [ ] **Step 3: Write minimal implementation**

In `lib/axn/configuration.rb`, after the `coerce_input_types` setting (line ~56), add:

```ruby
    # Dedicated directories whose Axns auto-register as tools (membership) and which core
    # eager-loads on demand to populate the registry. Security-sensitive and deliberately
    # narrow: it must never include a broad dir like bare `actions`, which would auto-expose
    # every business action. Resolved to `Rails.root/app/<path>` under Rails, else
    # `File.expand_path(<path>)`. Distinct from tool_name_stripped_prefixes (naming, cosmetic).
    setting :tool_paths,
            default: %w[agent_tools actions/tools],
            validate: ->(v) { v.is_a?(Array) && v.all? { |s| s.is_a?(String) } }

    # Leading namespace segments stripped when deriving a tool's `tool_name` from its
    # class name. Cosmetic and broad (may safely include `actions`). Global by default,
    # per-class overridable (a class can narrow/replace the set it derives against).
    setting :tool_name_stripped_prefixes,
            default: %w[actions tools agent_tools],
            overridable: true,
            validate: ->(v) { v.is_a?(Array) && v.all? { |s| s.is_a?(String) } }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/axn/core/configuration_spec.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/axn/configuration.rb spec/axn/core/configuration_spec.rb
git commit -m "PRO-2921: add tool_paths + tool_name_stripped_prefixes config settings"
```

---

## Task 2: `tool_name` derivation + `Axn::Core::Tools` skeleton

**Files:**
- Create: `lib/axn/core/tools.rb`
- Modify: `lib/axn/core.rb` (add `require` at ~line 21 and `include Core::Tools` at ~line 82)
- Test: `spec/axn/core/tool_name_spec.rb`

**Interfaces:**
- Produces (class methods on every Axn): `tool_name -> String` (provider-safe `[a-z0-9_]`, never empty); `_tool_name_override` / `_tool_declaration` class_attributes (default `nil`), read by later tasks.
- Consumes: `resolved_axn_name` (Core::Naming); `Axn::Configuration.resolve_override_for(self, :tool_name_stripped_prefixes)` (Task 1).

- [ ] **Step 1: Write the failing test**

Create `spec/axn/core/tool_name_spec.rb`:

```ruby
# frozen_string_literal: true

RSpec.describe "Axn tool_name derivation" do
  def tool_klass(name)
    Class.new do
      include Axn
      define_singleton_method(:name) { name }
    end
  end

  it "snake_cases a single leaf" do
    expect(tool_klass("AgentTools::ListCompanies").tool_name).to eq("list_companies")
  end

  it "keeps non-prefix intermediate segments" do
    expect(tool_klass("AgentTools::Users::ListCompanies").tool_name).to eq("users_list_companies")
  end

  it "strips a leading `actions` prefix" do
    expect(tool_klass("Actions::Company::DoThing").tool_name).to eq("company_do_thing")
  end

  it "strips a leading run of prefixes only (stops at first non-match)" do
    expect(tool_klass("Actions::Tools::Foo::BarTool").tool_name).to eq("foo_bar_tool")
  end

  it "does not strip a deeper `tools` segment (prefix/leading-run semantics)" do
    expect(tool_klass("AgentTools::Tools::Foo").tool_name).to eq("tools_foo")
  end

  it "restricts to a provider-safe charset and collapses separators" do
    expect(tool_klass("Weird::Na me!!Thing").tool_name).to eq("weird_na_me_thing")
  end

  it "falls back to `tool` when derivation is empty" do
    k = tool_klass("Actions::Tools") # every segment is a stripped prefix
    expect(k.tool_name).to eq("tools") # last segment fallback
  end

  it "honors a per-class stripped-prefix override" do
    k = tool_klass("AgentTools::ListCompanies")
    k.tool_name_stripped_prefixes(%w[]) # no stripping
    expect(k.tool_name).to eq("agent_tools_list_companies")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/core/tool_name_spec.rb`
Expected: FAIL — undefined method `tool_name`.

- [ ] **Step 3: Write minimal implementation**

Create `lib/axn/core/tools.rb`:

```ruby
# frozen_string_literal: true

module Axn
  module Core
    # Tool membership (the `tool` DSL) and the canonical, provider-safe `tool_name`
    # derivation. Every Axn is a potential tool; the registry (Axn::Tools::Registry)
    # decides which classes an adapter actually exposes, reading the storage declared here.
    module Tools
      def self.included(base)
        base.class_eval do
          # instance_accessor: false — class-level DSL, not per-instance state.
          # _tool_declaration: nil (undeclared) | :all | false | Array<Symbol> (explicit adapters).
          class_attribute :_tool_declaration, :_tool_name_override, instance_accessor: false, default: nil
          extend ClassMethods
        end
      end

      module ClassMethods
        # The provider-facing tool name (distinct from resolved_axn_name, the free-form display
        # name). An explicit `tool name:` override wins; otherwise derive from the class name by
        # stripping the leading run of configured prefixes, snake_casing the rest, and restricting
        # to [a-z0-9_]. Never blank.
        def tool_name
          override = _tool_name_override
          return _tool_name_sanitize(override) if override && !override.to_s.strip.empty?

          segments = resolved_axn_name.split("::")
          kept = _tool_name_strip_leading_prefixes(segments)
          derived = _tool_name_sanitize(kept.map(&:underscore).join("_"))
          return derived unless derived.empty?

          last = _tool_name_sanitize(segments.last.to_s.underscore)
          last.empty? ? "tool" : last
        end

        private

        def _tool_name_strip_leading_prefixes(segments)
          prefixes = _tool_name_stripped_prefixes.map(&:to_s)
          index = 0
          index += 1 while index < segments.length && prefixes.include?(segments[index].underscore)
          segments[index..] || []
        end

        def _tool_name_stripped_prefixes
          Axn::Configuration.resolve_override_for(self, :tool_name_stripped_prefixes)
        end

        def _tool_name_sanitize(value)
          value.to_s.downcase.gsub(/[^a-z0-9_]+/, "_").gsub(/_+/, "_").gsub(/\A_+|_+\z/, "")
        end
      end
    end
  end
end
```

In `lib/axn/core.rb`, add the require near the other core DSL requires (after `require "axn/core/naming"`, line ~11):

```ruby
require "axn/core/tools"
```

And add to the `include` list in `Core.included` (after `include Core::Naming`, line ~72):

```ruby
        include Core::Tools
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/axn/core/tool_name_spec.rb`
Expected: PASS.

- [ ] **Step 5: Run the full unit suite to check nothing regressed**

Run: `bundle exec rspec spec`
Expected: PASS (green).

- [ ] **Step 6: Commit**

```bash
git add lib/axn/core/tools.rb lib/axn/core.rb spec/axn/core/tool_name_spec.rb
git commit -m "PRO-2921: canonical tool_name derivation on Axn::Core::Tools"
```

---

## Task 3: `tool` DSL — membership + name override storage

**Files:**
- Modify: `lib/axn/core/tools.rb` (add the `tool` class method to `ClassMethods`)
- Test: `spec/axn/core/tool_dsl_spec.rb`

**Interfaces:**
- Produces: `tool(*adapters, name: nil)` class method. Sets `_tool_declaration` to `:all` (bare `tool` or `tool name:`), `false` (`tool false`), or `Array<Symbol>` (`tool :mcp, :ruby_llm`); sets `_tool_name_override` from `name:`. Raises `ArgumentError` on `tool false` combined with adapters/`name:`, or non-Symbol adapters.

- [ ] **Step 1: Write the failing test**

Create `spec/axn/core/tool_dsl_spec.rb`:

```ruby
# frozen_string_literal: true

RSpec.describe "Axn `tool` DSL" do
  def axn(&blk) = Class.new { include Axn }.tap { |k| k.class_eval(&blk) if blk }

  it "bare `tool` declares membership in all adapters" do
    expect(axn { tool }._tool_declaration).to eq(:all)
  end

  it "`tool false` opts out" do
    expect(axn { tool false }._tool_declaration).to eq(false)
  end

  it "`tool :mcp` declares an explicit single-adapter set" do
    expect(axn { tool :mcp }._tool_declaration).to eq([:mcp])
  end

  it "`tool :mcp, :ruby_llm` declares an explicit multi-adapter set" do
    expect(axn { tool :mcp, :ruby_llm }._tool_declaration).to eq(%i[mcp ruby_llm])
  end

  it "`tool name:` sets the override and declares all adapters" do
    k = axn { tool name: "custom_name" }
    expect(k._tool_declaration).to eq(:all)
    expect(k.tool_name).to eq("custom_name")
  end

  it "`tool :mcp, name:` composes an adapter set with a name override" do
    k = axn { tool :mcp, name: "custom_name" }
    expect(k._tool_declaration).to eq([:mcp])
    expect(k.tool_name).to eq("custom_name")
  end

  it "rejects `tool false` combined with a name override" do
    expect { axn { tool false, name: "x" } }.to raise_error(ArgumentError, /opts out/)
  end

  it "rejects `tool false` combined with an adapter" do
    expect { axn { tool :mcp, false } }.to raise_error(ArgumentError, /opts out/)
  end

  it "rejects a non-Symbol adapter" do
    expect { axn { tool "mcp" } }.to raise_error(ArgumentError, /must be Symbols/)
  end

  it "inherits the declaration to subclasses" do
    parent = axn { tool :mcp }
    expect(Class.new(parent)._tool_declaration).to eq([:mcp])
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/core/tool_dsl_spec.rb`
Expected: FAIL — undefined method `tool`.

- [ ] **Step 3: Write minimal implementation**

In `lib/axn/core/tools.rb`, add to `ClassMethods` (above `tool_name`):

```ruby
        # Declares tool membership.
        #   tool                  -> member of every registered adapter (the common case)
        #   tool :mcp, :ruby_llm  -> explicit per-adapter set
        #   tool false            -> opt out (a helper Axn living under a tool_path)
        #   tool name: "…"        -> membership in all adapters, with a provider-name override
        # Unknown adapter symbols are stored as-is (adapters self-register at load; a hard check
        # here would be load-order-hostile) and simply never match tools_for.
        def tool(*adapters, name: nil)
          if adapters.include?(false)
            raise ArgumentError, "`tool false` opts out; it can't be combined with adapters or `name:`" if adapters.length > 1 || !name.nil?

            self._tool_declaration = false
            return
          end

          non_symbols = adapters.reject { |a| a.is_a?(Symbol) }
          raise ArgumentError, "tool adapters must be Symbols (e.g. `tool :mcp`); got #{non_symbols.inspect}" if non_symbols.any?

          self._tool_name_override = name unless name.nil?
          self._tool_declaration = adapters.empty? ? :all : adapters
          nil
        end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/axn/core/tool_dsl_spec.rb spec/axn/core/tool_name_spec.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/axn/core/tools.rb spec/axn/core/tool_dsl_spec.rb
git commit -m "PRO-2921: `tool` DSL for per-class tool membership + name override"
```

---

## Task 4: Registry — adapter self-registration + global class tracking

**Files:**
- Create: `lib/axn/tools/registry.rb`
- Modify: `lib/axn.rb` (require the registry; register each `include Axn` class; add `Axn.register_tool_adapter` / `Axn.tools_for` facades)
- Modify: `spec/spec_helper.rb` (reset registry adapters between examples)
- Test: `spec/axn/tools/registry_spec.rb`

**Interfaces:**
- Produces: `Axn::Tools::Registry.register_adapter(sym)`, `.adapters -> Set<Symbol>`, `.register_class(klass)`, `.all_classes -> Array<Class>` (only currently-defined named Axns), `.reset_adapters!`. `Axn.register_tool_adapter(sym)`. `Axn.tools_for(sym)` (stubbed here to raise on unknown adapter; full impl in Task 6).

- [ ] **Step 1: Write the failing test**

Create `spec/axn/tools/registry_spec.rb`:

```ruby
# frozen_string_literal: true

RSpec.describe Axn::Tools::Registry do
  before { described_class.reset_adapters! }
  after { described_class.reset_adapters! }

  describe "adapter registration" do
    it "registers and reports adapter keys" do
      Axn.register_tool_adapter(:mcp)
      Axn.register_tool_adapter(:ruby_llm)
      expect(described_class.adapters).to contain_exactly(:mcp, :ruby_llm)
    end

    it "is idempotent" do
      Axn.register_tool_adapter(:mcp)
      Axn.register_tool_adapter(:mcp)
      expect(described_class.adapters.to_a).to eq([:mcp])
    end

    it "coerces string keys to symbols" do
      Axn.register_tool_adapter("mcp")
      expect(described_class.adapters).to include(:mcp)
    end
  end

  describe "global class tracking" do
    it "records every include-Axn class" do
      klass = stub_const("RegistrySpec::Recorded", Class.new { include Axn })
      expect(described_class.all_classes).to include(klass)
    end

    it "excludes anonymous classes" do
      anon = Class.new { include Axn }
      expect(described_class.all_classes).not_to include(anon)
    end
  end

  describe "Axn.tools_for validation" do
    it "raises for an unregistered adapter" do
      expect { Axn.tools_for(:nope) }.to raise_error(ArgumentError, /not a registered tool adapter/)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/tools/registry_spec.rb`
Expected: FAIL — uninitialized constant `Axn::Tools::Registry`.

- [ ] **Step 3: Write minimal implementation**

Create `lib/axn/tools/registry.rb`:

```ruby
# frozen_string_literal: true

require "set"

module Axn
  module Tools
    # Process-global tool registry: the registered adapter keys, every include-Axn class,
    # membership resolution, and on-demand loading of the configured tool directories.
    module Registry
      extend self

      def register_adapter(key)
        adapters << key.to_sym
      end

      def adapters
        @adapters ||= Set.new
      end

      def reset_adapters!
        @adapters = Set.new
      end

      # Called at include-Axn time for every action class.
      def register_class(klass)
        _classes << klass
      end

      # Only currently-defined, named classes: drops anonymous classes and stale references
      # left behind by a Zeitwerk reload (the reloaded constant points at a fresh object).
      def all_classes
        _classes.select { |k| _currently_defined?(k) }
      end

      private

      def _classes
        @classes ||= []
      end

      def _currently_defined?(klass)
        name = klass.name
        return false if name.nil? || name.empty?

        klass.name.safe_constantize.equal?(klass)
      rescue StandardError
        false
      end
    end
  end
end
```

In `lib/axn.rb`, add the require after `require "axn/reflection"` (line ~17):

```ruby
require "axn/tools/registry"
```

In `lib/axn.rb`'s `Axn.included(base)`, register the class after the `class_eval` block (before the method's implicit end, after the `Array(Axn.config.additional_includes)...` block closes — i.e. after the `end` of `base.class_eval`):

```ruby
    Axn::Tools::Registry.register_class(base)
```

Add the two facades to `module Axn` (next to `owns_failure_exception?`, ~line 50):

```ruby
  def self.register_tool_adapter(key)
    Axn::Tools::Registry.register_adapter(key)
  end

  def self.tools_for(adapter)
    adapter = adapter.to_sym
    unless Axn::Tools::Registry.adapters.include?(adapter)
      raise ArgumentError, "#{adapter.inspect} is not a registered tool adapter (registered: #{Axn::Tools::Registry.adapters.to_a.inspect})"
    end

    Axn::Tools::Registry.tools_for(adapter)
  end
```

Add a placeholder `tools_for` to the registry so the facade resolves (Task 6 fills it in):

```ruby
      def tools_for(_adapter)
        [] # membership resolution added in a later step
      end
```

In `spec/spec_helper.rb`, add registry reset (inside the existing `RSpec.configure do |config|` block):

```ruby
  config.before { Axn::Tools::Registry.reset_adapters! }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/axn/tools/registry_spec.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/axn/tools/registry.rb lib/axn.rb spec/axn/tools/registry_spec.rb spec/spec_helper.rb
git commit -m "PRO-2921: tool registry — adapter self-registration + include-Axn class tracking"
```

---

## Task 5: Membership resolution

**Files:**
- Modify: `lib/axn/tools/registry.rb` (add `member?` + directory/config-namespace helpers)
- Test: `spec/axn/tools/registry_spec.rb` (add a `member?` describe block)

**Interfaces:**
- Produces: `Axn::Tools::Registry.member?(klass, adapter) -> Boolean`. Resolution order: explicit `_tool_declaration` (`false`→no, `:all`→yes, `Array`→includes adapter); else source file under a resolved `tool_path` dir → yes (all adapters); else a `configure(<adapter>)` bag present for a registered adapter key → yes (that adapter); else no.
- Consumes: `Axn.config.tool_paths` (Task 1), `klass._tool_declaration` (Task 3), `Object.const_source_location`, the tolerant config bag ivar `@_axn_config_overrides`.

- [ ] **Step 1: Write the failing test**

Add to `spec/axn/tools/registry_spec.rb`:

```ruby
  describe ".member?" do
    before { Axn.register_tool_adapter(:mcp) }

    it "explicit `tool :mcp` is a member for :mcp but not :ruby_llm" do
      Axn.register_tool_adapter(:ruby_llm)
      k = stub_const("MemberSpec::Explicit", Class.new { include Axn; tool :mcp })
      expect(described_class.member?(k, :mcp)).to be(true)
      expect(described_class.member?(k, :ruby_llm)).to be(false)
    end

    it "bare `tool` is a member for every adapter" do
      Axn.register_tool_adapter(:ruby_llm)
      k = stub_const("MemberSpec::All", Class.new { include Axn; tool })
      expect(described_class.member?(k, :mcp)).to be(true)
      expect(described_class.member?(k, :ruby_llm)).to be(true)
    end

    it "`tool false` is never a member, even under a tool path" do
      allow(Axn.config).to receive(:tool_paths).and_return([File.expand_path("spec")])
      k = stub_const("MemberSpec::OptOut", Class.new { include Axn; tool false })
      allow(Object).to receive(:const_source_location).with("MemberSpec::OptOut")
                                                      .and_return([File.expand_path("spec/dummy.rb"), 1])
      expect(described_class.member?(k, :mcp)).to be(false)
    end

    it "an undeclared class whose source is under a tool_path auto-registers for all adapters" do
      Axn.register_tool_adapter(:ruby_llm)
      allow(Axn.config).to receive(:tool_paths).and_return([File.expand_path("spec")])
      k = stub_const("MemberSpec::AutoReg", Class.new { include Axn })
      allow(Object).to receive(:const_source_location).with("MemberSpec::AutoReg")
                                                      .and_return([File.expand_path("spec/some_tool.rb"), 1])
      expect(described_class.member?(k, :mcp)).to be(true)
      expect(described_class.member?(k, :ruby_llm)).to be(true)
    end

    it "an undeclared class outside every tool_path is not a member" do
      allow(Axn.config).to receive(:tool_paths).and_return([File.expand_path("spec")])
      k = stub_const("MemberSpec::Outside", Class.new { include Axn })
      allow(Object).to receive(:const_source_location).with("MemberSpec::Outside")
                                                      .and_return(["/somewhere/else/x.rb", 1])
      expect(described_class.member?(k, :mcp)).to be(false)
    end

    it "a class with `configure(:mcp)` is an implicit member for :mcp only" do
      Axn.register_tool_adapter(:ruby_llm)
      allow(Axn.config).to receive(:tool_paths).and_return([])
      k = stub_const("MemberSpec::ConfigNS", Class.new do
        include Axn
        configure(:mcp) { |c| c.some_setting = 1 }
      end)
      allow(Object).to receive(:const_source_location).and_return(nil)
      expect(described_class.member?(k, :mcp)).to be(true)
      expect(described_class.member?(k, :ruby_llm)).to be(false)
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/tools/registry_spec.rb -e member?`
Expected: FAIL — undefined method `member?`.

- [ ] **Step 3: Write minimal implementation**

In `lib/axn/tools/registry.rb`, add to the public section:

```ruby
      # Fail-safe membership: an explicit declaration wins; else auto-register when the class's
      # source file lives under a configured tool_path dir; else treat a configure(<adapter>) bag
      # for a registered adapter key as implicit membership for that adapter; else not a tool.
      def member?(klass, adapter)
        return false unless klass.respond_to?(:_tool_declaration)

        case (decl = klass._tool_declaration)
        when false then false
        when :all then true
        when Array then decl.include?(adapter)
        else
          _under_tool_path?(klass) || _declares_adapter_config?(klass, adapter)
        end
      end
```

And to the private section:

```ruby
      def _under_tool_path?(klass)
        return false unless klass.name

        path = Object.const_source_location(klass.name)&.first
        return false unless path

        expanded = File.expand_path(path)
        _tool_dirs.any? { |dir| expanded == dir || expanded.start_with?(dir + File::SEPARATOR) }
      rescue StandardError
        false
      end

      # A tolerant configure(<adapter>) write lands in @_axn_config_overrides keyed by the
      # namespace symbol; a registered adapter key there signals implicit membership.
      def _declares_adapter_config?(klass, adapter)
        return false unless adapters.include?(adapter)

        node = klass
        while node.is_a?(Module)
          store = node.instance_variable_get(:@_axn_config_overrides)
          return true if store.is_a?(Hash) && store.key?(adapter)
          break unless node.is_a?(Class) && node.superclass

          node = node.superclass
        end
        false
      end

      def _tool_dirs
        Array(Axn.config.tool_paths).map { |path| _resolve_tool_dir(path) }.compact
      end

      def _resolve_tool_dir(path)
        if defined?(Rails) && Rails.respond_to?(:root) && Rails.root
          Rails.root.join("app", path).to_s
        else
          File.expand_path(path)
        end
      end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/axn/tools/registry_spec.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/axn/tools/registry.rb spec/axn/tools/registry_spec.rb
git commit -m "PRO-2921: fail-safe tool membership resolution"
```

---

## Task 6: `tools_for` — filter the registry by membership

**Files:**
- Modify: `lib/axn/tools/registry.rb` (replace the placeholder `tools_for` with the real filter; add a no-op `ensure_loaded!` that Task 7 fleshes out)
- Test: `spec/axn/tools/registry_spec.rb` (add a `tools_for` describe block)

**Interfaces:**
- Produces: `Axn::Tools::Registry.tools_for(adapter) -> Array<Class>` = currently-defined member classes for the adapter. Calls `ensure_loaded!` first (no-op stub until Task 7).

- [ ] **Step 1: Write the failing test**

Add to `spec/axn/tools/registry_spec.rb`:

```ruby
  describe ".tools_for" do
    before do
      Axn.register_tool_adapter(:mcp)
      Axn.register_tool_adapter(:ruby_llm)
    end

    it "returns only member classes for the adapter" do
      mcp_only = stub_const("ToolsForSpec::McpOnly", Class.new { include Axn; tool :mcp })
      both = stub_const("ToolsForSpec::Both", Class.new { include Axn; tool })
      stub_const("ToolsForSpec::NotATool", Class.new { include Axn })

      expect(Axn.tools_for(:mcp)).to include(mcp_only, both)
      expect(Axn.tools_for(:ruby_llm)).to include(both)
      expect(Axn.tools_for(:ruby_llm)).not_to include(mcp_only)
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/tools/registry_spec.rb -e tools_for`
Expected: FAIL — `tools_for` returns `[]`.

- [ ] **Step 3: Write minimal implementation**

In `lib/axn/tools/registry.rb`, replace the placeholder `tools_for` with:

```ruby
      def tools_for(adapter)
        ensure_loaded!
        all_classes.select { |klass| member?(klass, adapter) }
      end

      # Ensures tool classes under the configured tool_paths are loaded before enumeration.
      # Filled in per environment in a later step; a no-op is correct when everything is
      # already required (production eager_load, or a test that defines classes inline).
      def ensure_loaded!
        nil
      end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/axn/tools/registry_spec.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/axn/tools/registry.rb spec/axn/tools/registry_spec.rb
git commit -m "PRO-2921: Axn.tools_for filters the registry by adapter membership"
```

---

## Task 7: On-demand eager-loading (Rails `eager_load_dir` + non-Rails `require` fallback)

**Files:**
- Modify: `lib/axn/tools/registry.rb` (real `ensure_loaded!`)
- Create: `spec/support/fixtures/registry_tools/lazy_registry_tool.rb`
- Test: `spec/axn/tools/registry_spec.rb` (non-Rails require-fallback example)

**Interfaces:**
- Produces: `ensure_loaded!` — under Rails with `eager_load` off, calls `Rails.autoloaders.main.eager_load_dir(dir)` for each existing tool dir; outside Rails, `require`s every `.rb` under each existing tool dir. Errors are swallowed to a debug log (loading is best-effort).

- [ ] **Step 1: Create the fixture (not auto-loaded elsewhere)**

Create `spec/support/fixtures/registry_tools/lazy_registry_tool.rb`:

```ruby
# frozen_string_literal: true

# Loaded only via Axn::Tools::Registry.ensure_loaded! in the require-fallback test.
module RegistryFixtures
  class LazyRegistryTool
    include Axn
    tool

    def call = nil
  end
end
```

Ensure `spec/spec_helper.rb` does NOT auto-require this path. If `spec/support/**/*.rb` is globbed by the helper, move the fixture under `spec/fixtures/registry_tools/` instead and adjust the path in the test below. (Check with: `grep -n "support" spec/spec_helper.rb`.)

- [ ] **Step 2: Write the failing test**

Add to `spec/axn/tools/registry_spec.rb`:

```ruby
  describe ".ensure_loaded! (non-Rails require fallback)", :aggregate_failures do
    let(:fixture_dir) { File.expand_path("../../support/fixtures/registry_tools", __dir__) }

    before do
      Axn.register_tool_adapter(:mcp)
      allow(Axn.config).to receive(:tool_paths).and_return([fixture_dir])
    end

    it "requires .rb files under a configured tool dir and exposes them as tools" do
      skip "fixture already loaded" if Object.const_defined?("RegistryFixtures::LazyRegistryTool")

      tools = Axn.tools_for(:mcp)
      expect(Object.const_defined?("RegistryFixtures::LazyRegistryTool")).to be(true)
      expect(tools).to include(RegistryFixtures::LazyRegistryTool)
      expect(RegistryFixtures::LazyRegistryTool.tool_name).to eq("lazy_registry_tool")
    end
  end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/tools/registry_spec.rb -e "require fallback"`
Expected: FAIL — constant not defined (fallback not implemented).

- [ ] **Step 4: Write minimal implementation**

In `lib/axn/tools/registry.rb`, replace the no-op `ensure_loaded!` with:

```ruby
      def ensure_loaded!
        dirs = _tool_dirs.select { |dir| File.directory?(dir) }
        return if dirs.empty?

        if _rails_app?
          return if Rails.application.config.eager_load

          loader = Rails.autoloaders.main
          dirs.each { |dir| loader.eager_load_dir(dir) if loader.respond_to?(:eager_load_dir) }
        else
          dirs.each do |dir|
            Dir.glob(File.join(dir, "**", "*.rb")).sort.each { |file| require file }
          end
        end
      rescue StandardError => e
        Axn.config.logger.debug { "[Axn] tool eager-load skipped: #{e.class}: #{e.message}" }
      end
```

And add the private helper:

```ruby
      def _rails_app?
        defined?(Rails) && Rails.respond_to?(:application) && Rails.application
      end
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bundle exec rspec spec/axn/tools/registry_spec.rb`
Expected: PASS. Then run the full non-Rails suite: `bundle exec rspec spec` — Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/axn/tools/registry.rb spec/support/fixtures/registry_tools/lazy_registry_tool.rb spec/axn/tools/registry_spec.rb
git commit -m "PRO-2921: on-demand tool loading (Rails eager_load_dir + non-Rails require)"
```

---

## Task 8: Rails on-demand eager-load integration test

**Files:**
- Create: `spec_rails/dummy_app/app/actions/tools/sample_widget.rb`
- Create: `spec_rails/dummy_app/spec/axn/tools_eager_load_spec.rb`

**Interfaces:**
- Consumes: `Axn.tools_for(:mcp)`, `Axn.config.tool_paths`, `Rails.autoloaders.main.eager_load_dir` (Task 7). The dummy app's test env has `eager_load = false`, so this exercises the real on-demand `eager_load_dir` path.

- [ ] **Step 1: Create the fixture tool (lazily autoloadable, unreferenced elsewhere)**

Create `spec_rails/dummy_app/app/actions/tools/sample_widget.rb`:

```ruby
# frozen_string_literal: true

# Under the app/actions autoload root this defines Tools::SampleWidget.
# Deliberately unreferenced elsewhere so the eager-load test proves on-demand loading.
module Tools
  class SampleWidget
    include Axn
    tool

    def call = nil
  end
end
```

- [ ] **Step 2: Write the failing test**

Create `spec_rails/dummy_app/spec/axn/tools_eager_load_spec.rb`:

```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Axn tool registry under Rails" do
  around do |example|
    original = Axn.config.tool_paths
    Axn.config.tool_paths = %w[actions/tools]
    Axn::Tools::Registry.reset_adapters!
    Axn.register_tool_adapter(:mcp)
    example.run
  ensure
    Axn.config.tool_paths = original
    Axn::Tools::Registry.reset_adapters!
  end

  it "eager-loads the tool_paths dir on demand and finds the tool without referencing it first" do
    tools = Axn.tools_for(:mcp)

    expect(defined?(Tools::SampleWidget)).to eq("constant")
    expect(tools).to include(Tools::SampleWidget)
  end

  it "derives a clean tool_name (stripping the `tools` namespace)" do
    Axn.tools_for(:mcp)
    expect(Tools::SampleWidget.tool_name).to eq("sample_widget")
  end
end
```

- [ ] **Step 3: Run test to verify it fails, then passes**

Run (from the dummy app bundle — see user memory "Running axn spec_rails"):

```bash
BUNDLE_GEMFILE=spec_rails/dummy_app/Gemfile bundle exec rspec spec_rails/dummy_app/spec/axn/tools_eager_load_spec.rb
```

Expected: PASS. (If `eager_load_dir` raises `Zeitwerk::Error` because `app/actions/tools` is not a managed subdir, confirm the dummy app autoloads `app/actions` — it does via the engine initializer — and that the dir exists. The rescue in `ensure_loaded!` logs and continues; the fixture is under the managed `app/actions` root so `eager_load_dir` should accept it.)

- [ ] **Step 4: Commit**

```bash
git add spec_rails/dummy_app/app/actions/tools/sample_widget.rb spec_rails/dummy_app/spec/axn/tools_eager_load_spec.rb
git commit -m "PRO-2921: Rails on-demand tool eager-load integration test"
```

---

## Task 9: Vernier dedup + CHANGELOG + AGENTS note

**Files:**
- Modify: `lib/axn/extras/strategies/vernier.rb:43`
- Modify: `spec/axn/extras/strategies/vernier_spec.rb`
- Modify: `CHANGELOG.md`
- Modify: `AGENTS.md` (one-line seam note)

**Interfaces:**
- Consumes: `self.class.tool_name` (Task 2) in place of the ad-hoc `resolved_axn_name.gsub(...)`.

- [ ] **Step 1: Write/adjust the failing test**

Inspect `spec/axn/extras/strategies/vernier_spec.rb` for the example asserting the profile filename. Add or adjust an example so a class named `AgentTools::ListCompanies` profiles to a file containing `list_companies` (the canonical `tool_name`), not `AgentTools__ListCompanies`:

```ruby
it "uses the canonical tool_name in the profile filename" do
  klass = Class.new do
    include Axn
    define_singleton_method(:name) { "AgentTools::ListCompanies" }
    use :vernier, if: -> { true }
    def call = nil
  end

  captured = nil
  allow(::Vernier).to receive(:profile) do |**opts, &blk|
    captured = opts[:out]
    blk.call
  end

  klass.call
  expect(captured).to include("axn_list_companies_")
end
```

(Match the surrounding spec's existing `::Vernier` stubbing style; reuse its helpers if present.)

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/extras/strategies/vernier_spec.rb`
Expected: FAIL — filename contains `AgentTools__ListCompanies`.

- [ ] **Step 3: Write minimal implementation**

In `lib/axn/extras/strategies/vernier.rb`, replace line 43:

```ruby
              class_name = self.class.resolved_axn_name.gsub(/[^A-Za-z0-9]+/, "_")
```

with:

```ruby
              class_name = self.class.tool_name
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/axn/extras/strategies/vernier_spec.rb`
Expected: PASS.

- [ ] **Step 5: Add the CHANGELOG entry**

In `CHANGELOG.md`, under `## Unreleased`, add a `[FEAT]` bullet (one line, no manual wrapping):

```markdown
* [FEAT] Tool support: a canonical `tool_name` and a shared tool registry (PRO-2921). Every Axn now derives one provider-safe `tool_name` from its class name (leading `tool_name_stripped_prefixes` segments dropped, remainder snake_cased and restricted to `[a-z0-9_]`), replacing the three divergent names adapters used to derive for the same class. A new `tool` class-DSL declares membership — bare `tool` (every registered adapter), `tool :mcp, :ruby_llm` (explicit set), `tool false` (opt out), `tool name: "…"` (name override) — and adapters self-register their key via `Axn.register_tool_adapter(:mcp)`. `Axn.tools_for(:mcp)` returns the member classes for an adapter, so a tool is declared once and every adapter sees the same set. Membership is fail-safe: only classes explicitly marked, or living under a configured `Axn.config.tool_paths` dir, or carrying a `configure(<adapter>)` bag for a registered adapter, are exposed — nothing under broad `app/actions/` is bulk-exposed. Two settings drive this: `tool_paths` (dedicated dirs to eager-load and auto-register; narrow/security-sensitive; default `%w[agent_tools actions/tools]`) and `tool_name_stripped_prefixes` (cosmetic naming; per-class overridable; default `%w[actions tools agent_tools]`). Under Zeitwerk the registry eager-loads the tool dirs on demand (production eager-load fills it automatically). The `vernier` profiling strategy now names profile files by `tool_name` (in-repo dedup of the old ad-hoc derivation).
```

- [ ] **Step 6: Add the AGENTS seam note**

In `AGENTS.md`, add one line under the "Reuse the seams" area noting the tool registry seam (match the surrounding bullet style, one line, no wrapping):

```markdown
- **Tool registry** — `tool` DSL / `Axn.tools_for(:adapter)` / `tool_name` (`Axn::Core::Tools`, `Axn::Tools::Registry`) own tool membership and naming; adapters consume them, never re-derive names or re-list members.
```

- [ ] **Step 7: Run the whole suite (both harnesses)**

Run: `bundle exec rspec spec`
Then: `BUNDLE_GEMFILE=spec_rails/dummy_app/Gemfile bundle exec rspec spec_rails`
Expected: PASS (green) in both.

- [ ] **Step 8: Commit**

```bash
git add lib/axn/extras/strategies/vernier.rb spec/axn/extras/strategies/vernier_spec.rb CHANGELOG.md AGENTS.md
git commit -m "PRO-2921: dedup vernier naming via tool_name; CHANGELOG + AGENTS"
```

---

## Self-Review — spec coverage map

- Problem 1 (canonical `tool_name`): Tasks 2, 9 (vernier dedup). ✓
- Problem 2 (tool registry): Tasks 3–8. ✓
- Design A (`tool` DSL + fail-safe resolution): Tasks 3, 5. ✓ (all four resolution steps in Task 5: explicit → tool_path → config-namespace → not-a-tool)
- Design B (adapter self-registration + `tools_for`): Tasks 4, 6. ✓
- Design C (`tool_name` derivation, prefix/leading-run semantics, fallbacks): Task 2. ✓
- Design D (two configs, distinct concerns, `tool_name_stripped_prefixes` overridable): Task 1. ✓
- Design E (Zeitwerk enumeration, eager-load, global include registry, currently-defined filtering): Tasks 4, 7, 8. ✓ (module-prefix superseded by directory-authoritative `const_source_location` — documented above)
- Core cleanup (vernier): Task 9. ✓
- Downstream (axn-mcp / axn-ruby_llm consumption): **out of scope** — separate tickets/repos, same release. Not in this plan.

**Open verification note for the implementer:** Task 8's Rails `eager_load_dir` call depends on the dummy app autoloading `app/actions` (it does, via the engine initializer) and on Zeitwerk accepting `app/actions/tools` as a managed subdir. If `eager_load_dir` rejects it, the fallback rescue logs and the test would fail on the membership assertion — at that point confirm the dir is managed (`Rails.autoloaders.main.dirs`) and adjust the fixture location, not the mechanism.
```
