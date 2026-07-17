# Per-adapter tool option bags (PRO-2942) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the `tool` DSL accept per-adapter option bags (`tool mcp: { title: "Search" }`) that are sugar over `configure(<adapter>)`, with `name` inside a bag overriding the provider name for that adapter only.

**Architecture:** `tool(*adapters, name: nil, **bags)` unions positional adapters with bag keys for membership, routes each bag's non-`name` keys through the existing `axn_configure(<adapter>)`/`NamespaceWriter` (same store, same eager/tolerant validation), and intercepts `name` into a new `_tool_name_overrides` class attribute read by a per-adapter-aware `tool_name(adapter = nil)`. The registry's uniqueness and enumeration switch to `tool_name(adapter)` so per-adapter names stay honest.

**Tech Stack:** Ruby, RSpec. Files: `lib/axn/core/tools.rb`, `lib/axn/tools/registry.rb`, specs under `spec/axn/`, `CHANGELOG.md`, `docs/recipes/gem-configuration.md`.

## Global Constraints

- **Works outside Rails.** No hard dependency on Rails; guard any Rails/AR reference with `defined?(...)`. Specs here run under `spec/` (non-Rails). No Rails-specific behavior is added by this work.
- **Additive at the seam.** Every existing `tool …` spelling and zero-arg `tool_name` must resolve identically after this change.
- **Reuse the seams.** Bag config MUST write through `axn_configure`/`NamespaceWriter` — do not add a second write path into `@_axn_config_overrides`. Per-adapter names live in a dedicated core attribute, NOT the config store.
- **TDD.** Failing test first, then implementation. Formatting is enforced in CI (RuboCop) — match surrounding style.
- **Design reference:** `internal-docs/specs/2026-07-17-tool-per-adapter-bags-design.md`.

Run the full tool/config suite with:
`bundle exec rspec spec/axn/core/tool_dsl_spec.rb spec/axn/core/tool_name_spec.rb spec/axn/tools/registry_spec.rb spec/axn/configurable_spec.rb`

---

### Task 1: `tool` accepts per-adapter bags (membership + config write)

Rewrite `tool` to accept `**bags`, union bag keys into membership, validate bag values are Hashes, route bag contents through `axn_configure`, and extend the `tool false` guard. `name` inside a bag is NOT yet special (it flows to the config writer like any key) — that is Task 2. The shared `name:` kwarg is unchanged.

**Files:**
- Modify: `lib/axn/core/tools.rb:37-77` (the `tool` method)
- Test: `spec/axn/core/tool_dsl_spec.rb`

**Interfaces:**
- Consumes: `axn_configure(namespace) { |writer| writer.<key> = value }` (from `Axn::Configurable::ClassConfigWriter`, already extended onto every Axn class); `_tool_name_sanitize` (private helper in this module); `_tool_declaration=`/`_tool_name_override=` (class attributes).
- Produces: `def tool(*adapters, name: nil, **bags)` — sets `_tool_declaration` to `(adapters + bags.keys).uniq` (or `:all` when both empty), writes each bag's keys into `@_axn_config_overrides[adapter]` via `axn_configure`.

- [ ] **Step 1: Write the failing tests**

Append this block to `spec/axn/core/tool_dsl_spec.rb`, inside the top-level `RSpec.describe "Axn `tool` DSL"` block (before its final `end`):

```ruby
  describe "per-adapter option bags" do
    it "`tool mcp: {}` declares membership in that adapter" do
      expect(axn { tool mcp: {} }._tool_declaration).to eq([:mcp])
    end

    it "unions positional adapters and bag keys for membership" do
      k = axn { tool :ruby_llm, mcp: { present_as: :message } }
      expect(k._tool_declaration).to eq(%i[ruby_llm mcp])
    end

    it "allows a redundant positional adapter and bag for the same key" do
      expect(axn { tool :mcp, mcp: { present_as: :message } }._tool_declaration).to eq([:mcp])
    end

    it "rejects a non-Hash bag value" do
      expect { axn { tool mcp: :message } }.to raise_error(ArgumentError, /must be Hashes/)
    end

    it "rejects `tool false` combined with a per-adapter bag" do
      expect { axn { tool false, mcp: { present_as: :message } } }.to raise_error(ArgumentError, /opts out/)
    end

    it "extends the repeated-`tool` guard to the bag form" do
      expect do
        axn do
          tool :mcp
          tool ruby_llm: {}
        end
      end.to raise_error(ArgumentError, /already declared/)
    end

    it "stores config tolerantly for an unregistered adapter and still declares membership" do
      k = axn { tool not_loaded: { anything: :x } }
      expect(k._tool_declaration).to eq([:not_loaded])
      slot = k.instance_variable_get(:@_axn_config_overrides)[:not_loaded]
      expect(slot).to eq(anything: :x)
    end
  end
```

Then append this new top-level describe block at the end of the file (after the outer `RSpec.describe`'s `end`), for the registered-adapter integration cases:

```ruby
RSpec.describe "Axn `tool` DSL — per-adapter bags write into the config store" do
  let(:mcp) do
    Module.new do
      extend Axn::Configurable
      config_namespace :mcp
      setting :present_as, default: :structured, one_of: %i[structured message], overridable: true
    end
  end

  def tool_class(overrides, &blk)
    Class.new do
      include Axn
      include overrides
      class_eval(&blk)
    end
  end

  it "resolves a bag key identically to configure(:mcp)" do
    klass = tool_class(mcp.overrides) { tool mcp: { present_as: :message } }
    expect(mcp.resolve_override_for(klass, :present_as)).to eq(:message)
  end

  it "validates an unknown key eagerly when the adapter's source is registered" do
    expect { tool_class(mcp.overrides) { tool mcp: { bogus: :x } } }
      .to raise_error(ArgumentError, /unknown overridable setting/)
  end

  it "validates a bad value eagerly when the adapter's source is registered" do
    expect { tool_class(mcp.overrides) { tool mcp: { present_as: :nonsense } } }
      .to raise_error(ArgumentError, /present_as/)
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec rspec spec/axn/core/tool_dsl_spec.rb`
Expected: FAIL — the new examples raise `ArgumentError: unknown keyword: :mcp` (current `tool` signature rejects unknown keywords).

- [ ] **Step 3: Rewrite the `tool` method**

In `lib/axn/core/tools.rb`, replace the entire `tool` method (currently lines 37-77, from `def tool(*adapters, name: nil)` through its closing `end`) with:

```ruby
        def tool(*adapters, name: nil, **bags)
          # Per-class guard (a plain ivar on the class object, which subclasses do NOT inherit):
          # a second `tool` on the SAME class would silently overwrite _tool_declaration (last-wins),
          # changing membership at tools_for time instead of failing here. Per axn's fail-at-declaration
          # doctrine, reject the repeat. A subclass declaring its own `tool` is a fresh first call
          # (fresh object, no ivar) and is fine.
          if instance_variable_defined?(:@__axn_tool_declared)
            raise ArgumentError, "`tool` was already declared on #{self}; declare all adapters, `name:`, and " \
                                 "per-adapter options in a single call (e.g. `tool :mcp, ruby_llm: { … }, name: \"...\"`)."
          end
          @__axn_tool_declared = true

          if adapters.include?(false)
            if adapters.length > 1 || !name.nil? || bags.any?
              raise ArgumentError, "`tool false` opts out; it can't be combined with adapters, `name:`, or per-adapter options"
            end

            self._tool_name_override = nil # a subclass opting out reports its OWN tool_name, not an inherited `tool name:` override
            self._tool_declaration = false
            return
          end

          non_symbols = adapters.reject { |a| a.is_a?(Symbol) }
          raise ArgumentError, "tool adapters must be Symbols (e.g. `tool :mcp`); got #{non_symbols.inspect}" if non_symbols.any?

          non_hash = bags.reject { |_adapter, opts| opts.is_a?(Hash) }
          unless non_hash.empty?
            raise ArgumentError, "tool per-adapter options must be Hashes (e.g. `tool mcp: { title: \"...\" }`); got #{non_hash.inspect}"
          end

          # A shared `name:` that sanitizes away entirely (e.g. "!!!" or whitespace-only) would yield a
          # blank tool_name, violating the never-blank contract. Fail at declaration. A nil name is not an error.
          if !name.nil? && _tool_name_sanitize(name).empty?
            raise ArgumentError,
                  "tool name: #{name.inspect} has no provider-safe characters ([a-z0-9_]); " \
                  "provide a name containing at least one such character"
          end

          # Always assign (even when name is nil): `_tool_name_override` is a class_attribute, so a fresh
          # `tool` without `name:` must clear an inherited override rather than let the parent's leak through.
          self._tool_name_override = name

          # Membership is the union of positional adapters and per-adapter bag keys; a bag key implies
          # membership in that adapter. Bare `tool` (no adapters, no bags) means every registered adapter.
          declared = (adapters + bags.keys).uniq
          self._tool_declaration = declared.empty? ? :all : declared

          # A per-adapter bag is sugar over `configure(<adapter>)`: route every key through the same
          # NamespaceWriter so it lands in the same @_axn_config_overrides[adapter] slot with the same
          # eager (source registered) / tolerant (not) validation — no second write path.
          bags.each do |adapter, opts|
            next if opts.empty?

            axn_configure(adapter) do |writer|
              opts.each { |key, value| writer.public_send("#{key}=", value) }
            end
          end

          nil
        end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bundle exec rspec spec/axn/core/tool_dsl_spec.rb`
Expected: PASS (all existing and new examples).

- [ ] **Step 5: Commit**

```bash
git add lib/axn/core/tools.rb spec/axn/core/tool_dsl_spec.rb
git commit -m "PRO-2942: tool DSL accepts per-adapter option bags (membership + config)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: `name` inside a bag overrides the provider name per-adapter

Intercept a `name` key out of each bag (so it is never written to the opaque config store) and record it per-adapter; add `tool_name(adapter = nil)` resolving per-adapter name → shared name → derivation. Zero-arg `tool_name` behavior is unchanged.

**Files:**
- Modify: `lib/axn/core/tools.rb` — the `class_attribute` declaration (line 13), the `bags.each` loop inside `tool` (added in Task 1), and the `tool_name` method (currently lines 85-108).
- Test: `spec/axn/core/tool_dsl_spec.rb`

**Interfaces:**
- Consumes: `_tool_name_sanitize`, `_tool_name_strip_leading_prefixes`, `axn_name`, `name` (all present in this module).
- Produces: `_tool_name_overrides` class attribute (`Hash{Symbol => String}` of raw per-adapter names, default `{}`); `def tool_name(adapter = nil)`.

- [ ] **Step 1: Write the failing tests**

Append to the `describe "per-adapter option bags"` block in `spec/axn/core/tool_dsl_spec.rb`:

```ruby
    describe "per-adapter name override" do
      it "overrides tool_name for that adapter only" do
        k = axn { tool mcp: { name: "search" }, ruby_llm: {} }
        expect(k.tool_name(:mcp)).to eq("search")
        expect(k.tool_name(:ruby_llm)).not_to eq("search")
      end

      it "falls back to the shared `tool name:` for an adapter without a per-adapter name" do
        k = axn { tool name: "shared", mcp: {} }
        expect(k.tool_name(:mcp)).to eq("shared")
      end

      it "leaves zero-arg tool_name (shared/derived) unaffected by a per-adapter name" do
        k = axn { tool mcp: { name: "search" } }
        expect(k.tool_name).to eq("tool") # anonymous class, no shared name -> derived default
      end

      it "rejects a per-adapter name that sanitizes to empty" do
        expect { axn { tool mcp: { name: "!!!" } } }.to raise_error(ArgumentError, /provider-safe/)
      end

      it "does not write the intercepted name into the config store" do
        k = axn { tool custom_adapter: { name: "search", foo: :bar } }
        slot = k.instance_variable_get(:@_axn_config_overrides)[:custom_adapter]
        expect(slot).to include(foo: :bar)
        expect(slot).not_to have_key(:name)
      end
    end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec rspec spec/axn/core/tool_dsl_spec.rb -e "per-adapter name override"`
Expected: FAIL — `tool_name` does not accept an argument (`wrong number of arguments`), and `tool mcp: { name: "search" }` writes `name` as a config key rather than intercepting it.

- [ ] **Step 3: Add the `_tool_name_overrides` attribute**

In `lib/axn/core/tools.rb`, immediately after the existing `class_attribute :_tool_declaration, :_tool_name_override, instance_accessor: false, default: nil` line (line 13), add:

```ruby
          # Per-adapter provider-name overrides ({adapter => raw_name}), rebuilt fresh on each `tool`
          # call. A class_attribute so a subclass inherits the parent's tool identity until it redeclares
          # `tool`. Frozen default: never mutate in place, always assign a fresh hash.
          class_attribute :_tool_name_overrides, instance_accessor: false, default: {}.freeze
```

- [ ] **Step 4: Intercept `name` in the bag loop**

In `lib/axn/core/tools.rb`, replace the `bags.each do |adapter, opts| … end` block inside `tool` (added in Task 1) with:

```ruby
          # A per-adapter bag is sugar over `configure(<adapter>)` for opaque config; the `name` key is
          # the one exception — it is core-owned (feeds tool_name), so it is intercepted here and never
          # written to the config store. Everything else routes through the same NamespaceWriter.
          per_adapter_names = {}
          bags.each do |adapter, opts|
            opts = opts.dup
            if opts.key?(:name)
              adapter_name = opts.delete(:name)
              if !adapter_name.nil? && _tool_name_sanitize(adapter_name).empty?
                raise ArgumentError,
                      "tool #{adapter.inspect} name: #{adapter_name.inspect} has no provider-safe characters " \
                      "([a-z0-9_]); provide a name containing at least one such character"
              end
              per_adapter_names[adapter] = adapter_name unless adapter_name.nil?
            end

            next if opts.empty?

            axn_configure(adapter) do |writer|
              opts.each { |key, value| writer.public_send("#{key}=", value) }
            end
          end
          self._tool_name_overrides = per_adapter_names.freeze
```

- [ ] **Step 5: Make `tool_name` per-adapter-aware**

In `lib/axn/core/tools.rb`, replace the `tool_name` method (currently `def tool_name` through its closing `end`, lines 85-108) with:

```ruby
        # The provider-facing tool name. With an `adapter`, a per-adapter `tool <adapter>: { name: }`
        # override wins first; then an explicit shared `tool name:`; then derivation from `axn_name`/class
        # name (strip configured prefixes, snake_case, restrict to [a-z0-9_], never blank). Zero-arg
        # `tool_name` skips the per-adapter tier and is unchanged. The `adapter` arg is consumed internally
        # by the registry; users never pass it.
        def tool_name(adapter = nil)
          if adapter && (raw = _tool_name_overrides[adapter])
            sanitized = _tool_name_sanitize(raw)
            return sanitized unless sanitized.empty?
          end

          # Defense-in-depth: the `tool` DSL rejects an override that sanitizes to empty, but an override
          # set through some other path must still never produce a blank name — sanitize and fall through.
          override = _tool_name_override
          if override
            sanitized_override = _tool_name_sanitize(override)
            return sanitized_override unless sanitized_override.empty?
          end

          # `axn_name.presence || name.presence` — NOT `resolved_axn_name` — so a truly nameless class
          # falls back to "tool" below rather than deriving from the "Anonymous Axn" sentinel.
          source = axn_name.presence || name.presence
          return "tool" if source.nil? || source.strip.empty?

          segments = source.split("::")
          kept = _tool_name_strip_leading_prefixes(segments)
          derived = _tool_name_sanitize(kept.map(&:underscore).join("_"))
          return derived unless derived.empty?

          last = _tool_name_sanitize(segments.last.to_s.underscore)
          last.empty? ? "tool" : last
        end
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bundle exec rspec spec/axn/core/tool_dsl_spec.rb spec/axn/core/tool_name_spec.rb`
Expected: PASS (new per-adapter-name examples plus all existing `tool_name` derivation examples, confirming zero-arg is unchanged).

- [ ] **Step 7: Commit**

```bash
git add lib/axn/core/tools.rb spec/axn/core/tool_dsl_spec.rb
git commit -m "PRO-2942: per-adapter tool name override via bag name key

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Registry honors per-adapter names in uniqueness and ordering

Switch the registry's duplicate detection and deterministic ordering from `&:tool_name` (zero-arg) to `tool_name(adapter)`, so a per-adapter bag name is respected — a within-adapter collision on an overriding name is caught, and enumeration sorts by the per-adapter name.

**Files:**
- Modify: `lib/axn/tools/registry.rb:58` (sort in `tools_for`) and `lib/axn/tools/registry.rb:145` (group in `_assert_unique_tool_names!`)
- Test: `spec/axn/tools/registry_spec.rb`

**Interfaces:**
- Consumes: `klass.tool_name(adapter)` (from Task 2).
- Produces: no new public interface; behavior change only.

- [ ] **Step 1: Write the failing tests**

Append to `spec/axn/tools/registry_spec.rb`, inside the `describe ".tools_for (duplicate tool_name detection)"` block (which already has `before { Axn.register_tool_adapter(:mcp) }`), before its closing `end`:

```ruby
    it "detects a within-adapter collision produced by a per-adapter bag name" do
      stub_const("PerAdapterDup::First", Class.new do
        include Axn
        tool mcp: { name: "search" }
      end)
      stub_const("PerAdapterDup::Second", Class.new do
        include Axn
        tool mcp: { name: "search" }
      end)

      expect { Axn.tools_for(:mcp) }.to raise_error(ArgumentError, /search/)
    end

    it "does not collide when the shared derived names differ but only one adapter is overridden" do
      Axn.register_tool_adapter(:ruby_llm)
      a = stub_const("PerAdapterName::Alpha", Class.new do
        include Axn
        tool mcp: { name: "shared" }, ruby_llm: {}
      end)
      b = stub_const("PerAdapterName::Beta", Class.new do
        include Axn
        tool ruby_llm: { name: "shared" }
      end)

      # "shared" is the mcp name of Alpha and the ruby_llm name of Beta — different adapters, no clash.
      expect(Axn.tools_for(:mcp)).to contain_exactly(a)
      expect(Axn.tools_for(:ruby_llm)).to contain_exactly(a, b)
    end

    it "sorts members by the per-adapter name" do
      z = stub_const("PerAdapterSort::Zebra", Class.new do
        include Axn
        tool mcp: { name: "zzz" }
      end)
      a = stub_const("PerAdapterSort::Antelope", Class.new do
        include Axn
        tool mcp: { name: "aaa" }
      end)

      expect(Axn.tools_for(:mcp)).to eq([a, z])
    end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec rspec spec/axn/tools/registry_spec.rb -e "per-adapter"`
Expected: FAIL — the collision example does not raise (both classes derive distinct class-name-based `tool_name`s under zero-arg lookup, so the override is invisible), and the sort example returns the wrong order.

- [ ] **Step 3: Use `tool_name(adapter)` in enumeration**

In `lib/axn/tools/registry.rb`, in `tools_for`, replace `members.sort_by(&:tool_name)` (line 58) with:

```ruby
        members.sort_by { |klass| klass.tool_name(adapter) }
```

- [ ] **Step 4: Use `tool_name(adapter)` in the uniqueness check**

In `lib/axn/tools/registry.rb`, in `_assert_unique_tool_names!`, replace `collisions = members.group_by(&:tool_name).select { |_name, klasses| klasses.length > 1 }` (line 145) with:

```ruby
        collisions = members.group_by { |klass| klass.tool_name(adapter) }.select { |_name, klasses| klasses.length > 1 }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bundle exec rspec spec/axn/tools/registry_spec.rb`
Expected: PASS (new per-adapter examples plus all existing registry examples).

- [ ] **Step 6: Commit**

```bash
git add lib/axn/tools/registry.rb spec/axn/tools/registry_spec.rb
git commit -m "PRO-2942: registry uniqueness/ordering honor per-adapter tool names

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Documentation and CHANGELOG

Document the bag form as sugar over `configure(<adapter>)` and add a CHANGELOG entry. No code or tests.

**Files:**
- Modify: `CHANGELOG.md` (the `### Tools & adapters` section under `## Unreleased`, around line 80-85)
- Modify: `docs/recipes/gem-configuration.md` (after the `## Per-action overrides` section, ending around line 71)

- [ ] **Step 1: Add the CHANGELOG entry**

In `CHANGELOG.md`, under `### Tools & adapters` (in `## Unreleased`), append this bullet after the existing `tool` DSL bullet (the one starting "Tool support: every Axn derives one provider-safe `tool_name`…"):

```markdown
* [FEAT] The `tool` DSL accepts per-adapter option bags — `tool mcp: { title: "Search", present_as: :message }, ruby_llm: { halt_after: true }` — as sugar over `configure(<adapter>)`: each key lands in the same per-class override store and resolves the same way, and a bag key implies membership in that adapter. `name:` inside a bag overrides the provider name for that adapter only (bare `tool name:` stays shared across adapters); a per-adapter name is honored by `Axn.tools_for`'s ordering and duplicate detection. Bag keys are validated eagerly when the adapter is loaded and tolerantly otherwise, exactly like `configure`.
```

- [ ] **Step 2: Add the recipe documentation**

In `docs/recipes/gem-configuration.md`, after the `## Per-action overrides` section (immediately before the `## Declaring validated settings on a class` heading, around line 73), insert:

```markdown
## Declaring per-adapter tool config inline

An action that participates as a tool can declare its per-adapter config right on the `tool` line instead of a detached `configure` block. `tool <adapter>: { … }` is sugar over `configure(<adapter>) { … }` — each key/value lands in the same per-class override store and resolves through the same path, and naming an adapter in the bag implies membership in it:

```ruby
class SearchTool < Axn::MCP::Tool
  tool mcp: { present_as: :message, title: "Search" },
       ruby_llm: { halt_after: true }
end
```

is equivalent to:

```ruby
class SearchTool < Axn::MCP::Tool
  tool :mcp, :ruby_llm
  configure(:mcp)      { |c| c.present_as = :message; c.title = "Search" }
  configure(:ruby_llm) { |c| c.halt_after = true }
end
```

Keys are validated eagerly when the adapter's settings are loaded in this process and stored tolerantly (validated on first read) otherwise, exactly like `configure`. If both spellings write the same key, last-writer-wins into the shared slot.

The one reserved key is `name`: `tool name: "…"` sets the provider-facing [`tool_name`](/reference/class) shared across every adapter, while `name:` inside a bag overrides it for that adapter only (`tool mcp: { name: "search" }`). Everything else in a bag is opaque to core and belongs to the adapter.
```

- [ ] **Step 3: Verify docs build / no broken references**

Run: `bundle exec rspec spec/axn/core/tool_dsl_spec.rb spec/axn/tools/registry_spec.rb spec/axn/configurable_spec.rb spec/axn/core/tool_name_spec.rb`
Expected: PASS (confirms the whole feature is green together before committing docs).

- [ ] **Step 4: Commit**

```bash
git add CHANGELOG.md docs/recipes/gem-configuration.md
git commit -m "PRO-2942: document per-adapter tool option bags

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage** (against `internal-docs/specs/2026-07-17-tool-per-adapter-bags-design.md`):
- Signature `tool(*adapters, name: nil, **bags)` → Task 1 Step 3.
- Membership union → Task 1 (tests + `declared = (adapters + bags.keys).uniq`).
- Bag value must be Hash → Task 1.
- Empty bag = membership only → Task 1 (`tool mcp: {}` test; `next if opts.empty?`).
- Config write via `axn_configure`, eager/tolerant validation → Task 1 (integration describe block).
- `tool false` forbids bags → Task 1.
- Repeat-`tool` guard covers bag form → Task 1.
- `name` interception (shared + per-adapter), never written to store → Task 2.
- `_tool_name_overrides` storage, rebuilt fresh, inherited → Task 2 (attribute + assignment).
- `tool_name(adapter = nil)` resolution order; zero-arg unchanged → Task 2.
- Per-adapter name sanitize-empty rejection → Task 2.
- Registry uniqueness + ordering on `tool_name(adapter)` → Task 3.
- Cross-adapter divergence allowed; within-adapter collision caught → Task 3.
- Docs + CHANGELOG → Task 4.

**Placeholder scan:** none — every step shows exact code, exact paths, exact commands.

**Type consistency:** `_tool_name_overrides` is a `Hash{Symbol => String}` written in Task 2's loop and read in Task 2's `tool_name` and Task 3's registry calls. `tool_name(adapter = nil)` signature is consistent across Task 2 (definition) and Task 3 (callers `klass.tool_name(adapter)`). `_tool_declaration` remains `nil | :all | false | Array<Symbol>`.
