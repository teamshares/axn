# Per-adapter Tool Roots + Union Membership Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rework tool registration so a tool's adapter membership is the union of a per-adapter directory grant and its `tool` declaration, minus a new per-adapter `except:` opt-out — replacing today's "any tool directory feeds every adapter" model.

**Architecture:** Directory→adapter mapping moves off the single global `Axn.config.tool_paths` list and onto each adapter's own global config as a validated `tool_roots` setting (a shared core concern). `register_tool_adapter` gains an optional config-source handle so the registry can read each adapter's roots lazily and compute, per class, the set of adapters whose roots contain it. `member?` becomes `(directory grant ∪ declaration grant) − except`; an explicit `tool :x` now *adds* to the directory grant instead of replacing it.

**Tech Stack:** Ruby, RSpec, ActiveSupport (`class_attribute`), Zeitwerk (Rails eager-load path). No new dependencies.

**Spec:** `internal-docs/specs/2026-07-17-per-adapter-tool-roots-design.md` (PRO-2948).

## Global Constraints

- Ruby style: `# frozen_string_literal: true` at the top of every new file; match surrounding code's comment density and idiom.
- Docs prose: one line per paragraph, no manual line breaks (repo convention).
- No historical comments ("used to X / now Y", "(PRO-2948)") in code — comments describe current behavior and intrinsic why only.
- axn is pre-alpha: **no migration shims or deprecation tombstones** — remove `tool_paths` outright.
- axn must run outside Rails: guard every `Rails`/AR constant with `defined?()`. `spec/` is non-Rails; `spec_rails/` is the Rails dummy app.
- Core stays adapter-agnostic: core never names `:mcp`/`:ruby_llm`/`:openapi` in library code (only in tests/docs as examples).
- Run core specs with `bundle exec rspec <path>`. Commit after each task's tests pass.

---

## File Structure

**Create:**
- `lib/axn/tools/adapter_roots.rb` — shared concern; extended onto an adapter's config module to declare a validated `tool_roots` setting reusing core's broad-path guard. One responsibility: the `tool_roots` setting + its validation.
- `spec/axn/tools/adapter_roots_spec.rb` — unit tests for that concern.
- `spec/support/tool_adapter_helpers.rb` — `register_tool_adapter_with_roots(key, roots:)` test helper (builds an anonymous config-source module and registers it). Shared by registry/tools specs.

**Modify:**
- `lib/axn/core/tools.rb` — `tool` DSL: add `except:`, store `_tool_except`, tri-state `_tool_declaration` (`:all` | `[]` | `Array`).
- `lib/axn/tools/registry.rb` — adapter-source storage; union `member?`; per-adapter directory grant; `ensure_loaded!` aggregates all adapters' roots; drop `_tool_dirs`/`_under_tool_path?`.
- `lib/axn.rb` — `register_tool_adapter(key, config_source = nil)`; require the new concern.
- `lib/axn/configuration.rb` — remove `setting :tool_paths` and `tool_paths=`; keep `broad_tool_path?`/`normalize_tool_path`/blocklist constants (now serving `tool_roots`).
- `spec/axn/core/tool_dsl_spec.rb` — `except:` DSL cases + tri-state declaration.
- `spec/axn/tools/registry_spec.rb` — retarget directory/membership tests onto per-adapter roots; add union + except coverage.
- `spec_rails/dummy_app/spec/axn/tools_eager_load_spec.rb` — register the dummy adapter with a config source carrying `tool_roots`.
- `docs/reference/configuration.md`, `docs/recipes/gem-configuration.md`, `CHANGELOG.md` — document the new surface.

---

## Task 1: `except:` DSL + tri-state declaration

Adds the per-adapter opt-out and the declaration tri-state to the `tool` DSL. Pure storage-level change (no `member?` behavior yet), independently testable through the stored class attributes.

**Files:**
- Modify: `lib/axn/core/tools.rb:13-18` (add `_tool_except` attribute), `lib/axn/core/tools.rb:44-101` (the `tool` method)
- Test: `spec/axn/core/tool_dsl_spec.rb`

**Interfaces:**
- Produces: `Klass._tool_except -> Array<Symbol>` (default `[]`, frozen); `Klass._tool_declaration -> :all | false | Array<Symbol>` where an empty `Array` (`[]`) now means "no declaration grant — directory grant only".

- [ ] **Step 1: Write the failing tests**

Append to `spec/axn/core/tool_dsl_spec.rb` (inside the top-level `describe`):

```ruby
describe "except: opt-out" do
  it "stores a single excepted adapter" do
    k = axn { tool except: :ruby_llm }
    expect(k._tool_except).to eq([:ruby_llm])
  end

  it "stores a list of excepted adapters" do
    k = axn { tool except: %i[ruby_llm openapi] }
    expect(k._tool_except).to eq(%i[ruby_llm openapi])
  end

  it "defaults _tool_except to an empty array when no except: is given" do
    expect(axn { tool :mcp }._tool_except).to eq([])
  end

  it "except:-only (no positional/bags) yields an empty-array declaration, not :all" do
    k = axn { tool except: :ruby_llm }
    expect(k._tool_declaration).to eq([])
  end

  it "bare `tool` is still :all (all adapters), distinct from except:-only" do
    expect(axn { tool }._tool_declaration).to eq(:all)
  end

  it "`tool name:` with no adapters is still :all" do
    expect(axn { tool name: "x" }._tool_declaration).to eq(:all)
  end

  it "composes positional adapters with except:" do
    k = axn { tool :mcp, :openapi, except: :openapi }
    expect(k._tool_declaration).to eq(%i[mcp openapi])
    expect(k._tool_except).to eq([:openapi])
  end

  it "rejects a non-Symbol except entry" do
    expect { axn { tool except: "mcp" } }.to raise_error(ArgumentError, /must be Symbols/)
  end

  it "rejects `tool false` combined with except:" do
    expect { axn { tool false, except: :mcp } }.to raise_error(ArgumentError, /opts out/)
  end

  it "clears an inherited _tool_except when a subclass redeclares tool" do
    parent = axn { tool except: :ruby_llm }
    child = Class.new(parent) { tool :mcp }
    expect(child._tool_except).to eq([])
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/axn/core/tool_dsl_spec.rb -e "except: opt-out"`
Expected: FAIL (`_tool_except` undefined method / `_tool_declaration` is `:all` not `[]`).

- [ ] **Step 3: Add the `_tool_except` class attribute**

In `lib/axn/core/tools.rb`, inside `self.included`'s `class_eval` block (after the `_tool_name_overrides` attribute at line 18), add:

```ruby
# Per-adapter opt-out ({adapter}), rebuilt fresh on each `tool` call. Subtracted from the
# union of directory + declaration grants at membership time. class_attribute so a subclass
# inherits until it redeclares; frozen default, never mutated in place.
class_attribute :_tool_except, instance_accessor: false, default: [].freeze
```

- [ ] **Step 4: Rewrite the `tool` method**

Replace the entire `def tool(...) ... end` (lines 44-101) with:

```ruby
def tool(*adapters, name: nil, except: nil, **bags)
  if instance_variable_defined?(:@__axn_tool_declared)
    raise ArgumentError, "`tool` was already declared on #{self}; declare all adapters, `name:`, `except:`, and " \
                         "per-adapter options in a single call (e.g. `tool :mcp, ruby_llm: { … }, name: \"...\"`)."
  end
  @__axn_tool_declared = true

  if adapters.include?(false)
    if adapters.length > 1 || !name.nil? || bags.any? || !except.nil?
      raise ArgumentError, "`tool false` opts out; it can't be combined with adapters, `name:`, `except:`, or per-adapter options"
    end

    self._tool_name_override = nil
    self._tool_name_overrides = {}.freeze
    self._tool_except = [].freeze
    self._tool_declaration = false
    return
  end

  except_list = Array(except).uniq

  # Adapter identity must be a Symbol everywhere it appears — positional, bag key, or except —
  # so membership stays Symbol-keyed end to end (a `**string_keyed` splat can smuggle a String).
  non_symbols = (adapters + bags.keys + except_list).reject { |a| a.is_a?(Symbol) }
  raise ArgumentError, "tool adapters must be Symbols (e.g. `tool :mcp`); got #{non_symbols.inspect}" if non_symbols.any?

  non_hash = bags.reject { |_adapter, opts| opts.is_a?(Hash) }
  unless non_hash.empty?
    raise ArgumentError,
          "tool per-adapter options must be Hashes (e.g. `tool mcp: { title: \"...\" }`); got #{non_hash.inspect}"
  end

  if !name.nil? && _tool_name_sanitize(name).empty?
    raise ArgumentError,
          "tool name: #{name.inspect} has no provider-safe characters ([a-z0-9_]); " \
          "provide a name containing at least one such character"
  end

  self._tool_name_override = name
  self._tool_except = except_list.freeze

  # Membership grant from the declaration: an explicit list unions positional adapters with
  # bag keys; bare `tool` (nothing at all) grants every registered adapter; `except:` with no
  # positional/bags is pure narrowing, so it grants nothing itself and relies on the directory
  # grant (an empty Array — NOT :all, which would re-expose the tool to every adapter but the
  # excepted one, defeating directory scoping).
  declared = (adapters + bags.keys).uniq
  self._tool_declaration =
    if declared.any?
      declared
    elsif except.nil?
      :all
    else
      []
    end

  _apply_tool_bags!(bags)

  nil
end
```

- [ ] **Step 5: Update the DSL doc comment**

Replace the comment block above `def tool` (lines 35-43) with:

```ruby
# Declares tool membership. Final membership is (directory grant ∪ this declaration) − except.
#   tool                  -> grant every registered adapter (regardless of directory)
#   tool :mcp, :ruby_llm  -> add these adapters to the directory grant
#   tool false            -> opt out of every adapter (a helper Axn living under a tool root)
#   tool except: :ruby_llm-> directory grant, minus :ruby_llm (pure narrowing; grants nothing itself)
#   tool name: "…"        -> grant all adapters, with a provider-name override
#   tool mcp: { title: "…" } -> add :mcp with per-adapter config (sugar over configure(:mcp));
#     a bag `name:` overrides the provider name for that adapter only
# Unknown adapter symbols are stored as-is (adapters self-register at load; a hard check here
# would be load-order-hostile) and simply never match tools_for.
```

- [ ] **Step 6: Run tests to verify they pass (and no regression)**

Run: `bundle exec rspec spec/axn/core/tool_dsl_spec.rb spec/axn/core/tool_name_spec.rb`
Expected: PASS (all, including the pre-existing DSL cases).

- [ ] **Step 7: Commit**

```bash
git add lib/axn/core/tools.rb spec/axn/core/tool_dsl_spec.rb
git commit -m "PRO-2948: tool DSL gains except: and tri-state declaration"
```

---

## Task 2: Shared `tool_roots` adapter concern

Provides the validated `tool_roots` setting every adapter's config module declares, so all adapters validate directory roots through core's single broad-path guard.

**Files:**
- Create: `lib/axn/tools/adapter_roots.rb`
- Modify: `lib/axn.rb:19` (require the concern after the registry require)
- Test: `spec/axn/tools/adapter_roots_spec.rb`

**Interfaces:**
- Produces: `Axn::Tools::AdapterRoots` — a module. An adapter module does `extend Axn::Configurable` then `extend Axn::Tools::AdapterRoots`, gaining `config.tool_roots` (default `[]`, an Array of Strings) with broad-path rejection at assignment.

- [ ] **Step 1: Write the failing tests**

Create `spec/axn/tools/adapter_roots_spec.rb`:

```ruby
# frozen_string_literal: true

RSpec.describe Axn::Tools::AdapterRoots do
  def build_source
    Module.new do
      extend Axn::Configurable
      extend Axn::Tools::AdapterRoots
    end
  end

  it "defaults tool_roots to an empty array" do
    expect(build_source.config.tool_roots).to eq([])
  end

  it "accepts a narrow list of string roots" do
    source = build_source
    source.config.tool_roots = %w[agent_tools actions/tools]
    expect(source.config.tool_roots).to eq(%w[agent_tools actions/tools])
  end

  it "rejects a non-array value" do
    expect { build_source.config.tool_roots = "agent_tools" }
      .to raise_error(ArgumentError, /must be an Array of Strings/)
  end

  it "rejects a non-string entry" do
    expect { build_source.config.tool_roots = [:agent_tools] }
      .to raise_error(ArgumentError, /must be an Array of Strings/)
  end

  it "rejects a broad entry (bare actions dir)" do
    expect { build_source.config.tool_roots = %w[actions] }
      .to raise_error(ArgumentError, /too broad/)
  end

  it "rejects a `..` traversal entry" do
    expect { build_source.config.tool_roots = %w[../secrets] }
      .to raise_error(ArgumentError, /too broad/)
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/axn/tools/adapter_roots_spec.rb`
Expected: FAIL (`uninitialized constant Axn::Tools::AdapterRoots`).

- [ ] **Step 3: Create the concern**

Create `lib/axn/tools/adapter_roots.rb`:

```ruby
# frozen_string_literal: true

module Axn
  module Tools
    # Mixed into an adapter's config module (which already `extend Axn::Configurable`) to declare
    # a validated `tool_roots` directory list. Each adapter names the directories it consumes; the
    # registry reads `<adapter>.config.tool_roots` to compute directory-based membership. Validation
    # reuses core's single broad-path guard so no adapter can widen a root to `app/`, `.`, `actions`,
    # or a `..` traversal that would bulk-expose every business action.
    module AdapterRoots
      def self.extended(base)
        base.setting :tool_roots, default: [], validate: ->(value) { AdapterRoots.validate!(value) }
      end

      # Returns true when valid; raises ArgumentError with a specific message otherwise. Raising from
      # a `validate:` lambda propagates through Setting#validate! (Axn::Configurable), so a bad root
      # fails at assignment rather than with the generic "got invalid value".
      def self.validate!(value)
        unless value.is_a?(Array) && value.all? { |entry| entry.is_a?(String) }
          raise ArgumentError, "tool_roots must be an Array of Strings; got #{value.inspect}"
        end

        value.each do |entry|
          next unless Axn::Configuration.broad_tool_path?(entry)

          raise ArgumentError,
                "tool_roots entry #{entry.inspect} is too broad: it resolves to the project root, escapes " \
                "via `..`, or ends in a broad directory (`actions`/`app`) that would auto-expose every " \
                "business action. Use a dedicated narrow subdir such as `agent_tools` or `actions/tools`."
        end

        true
      end
    end
  end
end
```

- [ ] **Step 4: Require the concern**

In `lib/axn.rb`, immediately after line 19 (`require "axn/tools/registry"`), add:

```ruby
require "axn/tools/adapter_roots"
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bundle exec rspec spec/axn/tools/adapter_roots_spec.rb`
Expected: PASS (all 6).

- [ ] **Step 6: Commit**

```bash
git add lib/axn/tools/adapter_roots.rb lib/axn.rb spec/axn/tools/adapter_roots_spec.rb
git commit -m "PRO-2948: shared AdapterRoots concern (validated tool_roots setting)"
```

---

## Task 3: `register_tool_adapter` config source + registry adapter-source storage

Lets an adapter register itself with a config source (`self`) so the registry can look up its roots. Storage flips from a `Set` of symbols to a `Hash` of `symbol => source`.

**Files:**
- Modify: `lib/axn.rb:58-60` (`register_tool_adapter`), `lib/axn/tools/registry.rb:11-21` (`register_adapter`/`adapters`/`reset_adapters!`), `lib/axn/tools/registry.rb:228-240` (`_declares_adapter_config?`)
- Test: `spec/axn/tools/registry_spec.rb` (the "adapter registration" describe block)

**Interfaces:**
- Produces: `Axn.register_tool_adapter(key, config_source = nil)`; `Registry.register_adapter(key, config_source = nil)`; `Registry.adapters -> Set<Symbol>` (keys, unchanged shape); `Registry.adapter_config_source(sym) -> source | nil`.

- [ ] **Step 1: Write the failing tests**

In `spec/axn/tools/registry_spec.rb`, inside the existing `describe "adapter registration"` block, add:

```ruby
it "stores an optional config source and exposes it" do
  source = Module.new
  Axn.register_tool_adapter(:mcp, source)
  expect(described_class.adapter_config_source(:mcp)).to be(source)
end

it "defaults the config source to nil" do
  Axn.register_tool_adapter(:mcp)
  expect(described_class.adapter_config_source(:mcp)).to be_nil
end

it "last registration wins for the same key" do
  first = Module.new
  second = Module.new
  Axn.register_tool_adapter(:mcp, first)
  Axn.register_tool_adapter(:mcp, second)
  expect(described_class.adapters.to_a).to eq([:mcp])
  expect(described_class.adapter_config_source(:mcp)).to be(second)
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/axn/tools/registry_spec.rb -e "adapter registration"`
Expected: FAIL (`adapter_config_source` undefined).

- [ ] **Step 3: Update `lib/axn.rb`**

Replace lines 58-60:

```ruby
def self.register_tool_adapter(key, config_source = nil)
  Axn::Tools::Registry.register_adapter(key, config_source)
end
```

- [ ] **Step 4: Update the registry storage**

In `lib/axn/tools/registry.rb`, replace lines 11-21 (`register_adapter`, `adapters`, `reset_adapters!`) with:

```ruby
def register_adapter(key, config_source = nil)
  _adapter_sources[key.to_sym] = config_source
end

def adapters
  _adapter_sources.keys.to_set
end

def adapter_config_source(adapter)
  _adapter_sources[adapter.to_sym]
end

def reset_adapters!
  @adapter_sources = {}
end
```

Then add, in the `private` section (e.g. next to `_classes` at line 282), the backing store:

```ruby
def _adapter_sources
  @adapter_sources ||= {}
end
```

- [ ] **Step 5: Point `_declares_adapter_config?` at the new store**

In `lib/axn/tools/registry.rb`, change the guard at line 229 from `return false unless adapters.include?(adapter)` to:

```ruby
return false unless _adapter_sources.key?(adapter)
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `bundle exec rspec spec/axn/tools/registry_spec.rb -e "adapter registration"`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/axn.rb lib/axn/tools/registry.rb spec/axn/tools/registry_spec.rb
git commit -m "PRO-2948: register_tool_adapter takes optional config source"
```

---

## Task 4: Registry membership rework — union + except + per-adapter roots

The core change. `member?` becomes `(directory grant ∪ declaration grant) − except`, directory grant is computed per adapter from `source.config.tool_roots`, and `ensure_loaded!` eager-loads the union of all adapters' roots. Removes the global `_tool_dirs`/`_under_tool_path?` (which depended on `Axn.config.tool_paths`).

**Files:**
- Create: `spec/support/tool_adapter_helpers.rb`
- Modify: `lib/axn/tools/registry.rb` — `member?` (124-134), `ensure_loaded!` (74-76 dir source), `_under_tool_path?`→`_under_adapter_root?` (214-224), `_tool_dirs`→`_adapter_dirs`/`_all_adapter_dirs` (249-258)
- Test: `spec/axn/tools/registry_spec.rb`

**Interfaces:**
- Consumes: `Registry.adapter_config_source` (Task 3); `AdapterRoots` config sources (Task 2); `Klass._tool_except` / tri-state `_tool_declaration` (Task 1).
- Produces: `Registry.member?(klass, adapter)` union semantics; helper `register_tool_adapter_with_roots(key, roots:)`.

- [ ] **Step 1: Write the test helper**

Create `spec/support/tool_adapter_helpers.rb`:

```ruby
# frozen_string_literal: true

module ToolAdapterHelpers
  # Registers `key` with a real config source (an anonymous module carrying a validated
  # `tool_roots` list), so registry directory-grant tests exercise the production read path
  # (`source.config.tool_roots`) rather than stubbing it.
  def register_tool_adapter_with_roots(key, roots: [])
    source = Module.new do
      extend Axn::Configurable
      extend Axn::Tools::AdapterRoots
    end
    source.config.tool_roots = roots
    Axn.register_tool_adapter(key, source)
    source
  end
end

RSpec.configure { |config| config.include ToolAdapterHelpers }
```

- [ ] **Step 2: Write the failing membership tests**

At the top of `spec/axn/tools/registry_spec.rb` (below `# frozen_string_literal: true`), add:

```ruby
require "support/tool_adapter_helpers"
```

Then add a new describe block (anywhere inside the top-level `describe`):

```ruby
describe ".member? (union of directory + declaration grants, minus except)" do
  # A class whose source file we pin under a chosen directory via const_source_location,
  # matching the existing member? tests' stubbing style.
  def klass_at(name, source_path, &blk)
    k = stub_const(name, Class.new { include Axn })
    k.class_eval(&blk) if blk
    allow(Object).to receive(:const_source_location).and_call_original
    allow(Object).to receive(:const_source_location).with(name).and_return([source_path, 1])
    k
  end

  let(:shared_dir) { File.expand_path("agent_tools") }

  it "grants every adapter whose roots contain the class (directory grant)" do
    register_tool_adapter_with_roots(:mcp, roots: %w[agent_tools])
    register_tool_adapter_with_roots(:ruby_llm, roots: %w[agent_tools])
    k = klass_at("MemberUnion::Shared", File.join(shared_dir, "shared.rb"))

    expect(described_class.member?(k, :mcp)).to be(true)
    expect(described_class.member?(k, :ruby_llm)).to be(true)
  end

  it "does NOT grant an adapter whose roots exclude the class" do
    register_tool_adapter_with_roots(:mcp, roots: %w[agent_tools])
    register_tool_adapter_with_roots(:openapi, roots: %w[http_tools])
    k = klass_at("MemberUnion::SharedOnly", File.join(shared_dir, "shared.rb"))

    expect(described_class.member?(k, :openapi)).to be(false)
  end

  it "adds a declared adapter on top of the directory grant (union, not replace)" do
    register_tool_adapter_with_roots(:mcp, roots: %w[agent_tools])
    register_tool_adapter_with_roots(:ruby_llm, roots: %w[agent_tools])
    register_tool_adapter_with_roots(:openapi, roots: %w[http_tools])
    k = klass_at("MemberUnion::PlusOpenapi", File.join(shared_dir, "shared.rb")) { tool :openapi }

    expect(described_class.member?(k, :mcp)).to be(true)      # still from directory
    expect(described_class.member?(k, :ruby_llm)).to be(true) # still from directory
    expect(described_class.member?(k, :openapi)).to be(true)  # added by declaration
  end

  it "subtracts an excepted adapter from the directory grant (all-but-a-few)" do
    register_tool_adapter_with_roots(:mcp, roots: %w[agent_tools])
    register_tool_adapter_with_roots(:openapi, roots: %w[agent_tools])
    k = klass_at("MemberUnion::AllBut", File.join(shared_dir, "shared.rb")) { tool except: :openapi }

    expect(described_class.member?(k, :mcp)).to be(true)
    expect(described_class.member?(k, :openapi)).to be(false)
  end

  it "except:-only does not re-expose the class to an adapter its directory never granted" do
    register_tool_adapter_with_roots(:mcp, roots: %w[agent_tools])
    register_tool_adapter_with_roots(:data_shifter_web, roots: %w[support_tools])
    k = klass_at("MemberUnion::NoLeak", File.join(shared_dir, "shared.rb")) { tool except: :mcp }

    expect(described_class.member?(k, :mcp)).to be(false)             # excepted
    expect(described_class.member?(k, :data_shifter_web)).to be(false) # never granted, not :all
  end

  it "`tool false` opts out of every adapter regardless of directory" do
    register_tool_adapter_with_roots(:mcp, roots: %w[agent_tools])
    k = klass_at("MemberUnion::OptOut", File.join(shared_dir, "shared.rb")) { tool false }

    expect(described_class.member?(k, :mcp)).to be(false)
  end

  it "bare `tool` grants every registered adapter even with no matching root" do
    register_tool_adapter_with_roots(:mcp, roots: [])
    register_tool_adapter_with_roots(:openapi, roots: [])
    k = klass_at("MemberUnion::All", "/somewhere/else/thing.rb") { tool }

    expect(described_class.member?(k, :mcp)).to be(true)
    expect(described_class.member?(k, :openapi)).to be(true)
  end

  it "an adapter with no config source has an empty directory grant" do
    Axn.register_tool_adapter(:mcp) # no source
    k = klass_at("MemberUnion::NoSource", File.join(shared_dir, "shared.rb"))

    expect(described_class.member?(k, :mcp)).to be(false)
  end
end
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `bundle exec rspec spec/axn/tools/registry_spec.rb -e "union of directory"`
Expected: FAIL (union not implemented; `tool :openapi` still replaces, `except` ignored, roots not read).

- [ ] **Step 4: Rewrite `member?`**

In `lib/axn/tools/registry.rb`, replace `member?` (lines 121-134, including its comment) with:

```ruby
# Membership = (directory grant ∪ declaration grant) − except. Directory grant: adapters whose
# configured tool_roots contain the class's source file. Declaration grant: :all (every adapter),
# or the explicit adapter list, or a tolerant configure(<adapter>) bag. `tool false` and an
# excepted adapter both short-circuit to non-membership.
def member?(klass, adapter)
  return false unless klass.respond_to?(:_tool_declaration)

  decl = klass._tool_declaration
  return false if decl == false
  return false if klass._tool_except.include?(adapter)

  declared_grant = decl == :all || (decl.is_a?(Array) && decl.include?(adapter))
  declared_grant || _under_adapter_root?(klass, adapter) || _declares_adapter_config?(klass, adapter)
end
```

- [ ] **Step 5: Replace the directory-resolution helpers**

In `lib/axn/tools/registry.rb`, replace `_under_tool_path?` (lines 214-224) and `_tool_dirs` (lines 242-258) with the per-adapter versions below. (Keep `_resolve_tool_dir` at 266-280 unchanged — it is reused.)

```ruby
# True when the class's source file lives under one of `adapter`'s resolved tool_roots.
def _under_adapter_root?(klass, adapter)
  return false unless klass.name

  dirs = _adapter_dirs(adapter)
  return false if dirs.empty?

  path = Object.const_source_location(klass.name)&.first
  return false unless path

  expanded = File.expand_path(path)
  dirs.any? { |dir| expanded == dir || expanded.start_with?(dir + File::SEPARATOR) }
rescue StandardError
  false
end

# Resolved, canonical tool directories for one adapter. Re-checks each root against the broad-path
# guard (the same fail-safe the old global list had): a broad root reaching config via in-place
# mutation is skipped + warned rather than bulk-exposing every business action.
def _adapter_dirs(adapter)
  _adapter_roots(adapter).filter_map do |path|
    if Axn::Configuration.broad_tool_path?(path)
      Axn.config.logger.warn { "[Axn] tool_roots entry #{path.inspect} for adapter #{adapter.inspect} is too broad; skipping (see Axn::Configuration::BROAD_TOOL_PATH_LEAVES)" }
      next
    end

    _resolve_tool_dir(path)
  end
end

# The raw tool_roots array declared on an adapter's config source, or [] when the adapter has no
# source or the read fails. Defensive: an adapter may register before its config is set, or with a
# source that doesn't follow the AdapterRoots contract.
def _adapter_roots(adapter)
  source = _adapter_sources[adapter]
  return [] unless source.respond_to?(:config)

  roots = source.config.tool_roots
  roots.is_a?(Array) ? roots : []
rescue StandardError
  []
end

# Union of every registered adapter's resolved dirs — the set ensure_loaded! must load before
# enumeration, since a class in any adapter's root (or declared for any adapter) may surface.
def _all_adapter_dirs
  adapters.flat_map { |adapter| _adapter_dirs(adapter) }.uniq
end
```

Also update two now-stale in-code comments (repo forbids stale/historical comments): in `ensure_loaded!` (lines ~61-73) change wording from "configured tool_paths" / "tool_paths directory" to "each adapter's tool roots" / "tool root directory"; in `_resolve_tool_dir` (lines ~264-265) change the reference "matching how `_under_tool_path?` expands" to "matching how `_under_adapter_root?` expands". These are wording-only; do not change behavior.

- [ ] **Step 6: Point `ensure_loaded!` at the aggregated dirs**

In `lib/axn/tools/registry.rb`, change the first line of `ensure_loaded!` (line 75) from `dirs = _tool_dirs.select { |dir| File.directory?(dir) }` to:

```ruby
dirs = _all_adapter_dirs.select { |dir| File.directory?(dir) }
```

- [ ] **Step 7: Run the new tests to verify they pass**

Run: `bundle exec rspec spec/axn/tools/registry_spec.rb -e "union of directory"`
Expected: PASS (all 8).

- [ ] **Step 8: Fix the pre-existing registry tests that assumed the old model**

The old directory/eager-load tests stub `Axn.config.tool_paths`, which no longer feeds membership. Retarget each to register an adapter with roots. Concretely, in `spec/axn/tools/registry_spec.rb`, for every occurrence of:

```ruby
Axn.register_tool_adapter(:mcp)
allow(Axn.config).to receive(:tool_paths).and_return([fixture_dir])
```

replace the pair with:

```ruby
register_tool_adapter_with_roots(:mcp, roots: [fixture_dir])
```

For the "skips a broad entry that reached tool_paths via in-place mutation" test (line ~293), the broad entry can no longer be assigned through `tool_roots=` (validation rejects it), so it can only arrive by mutating the stored array in place. Replace its setup with:

```ruby
source = register_tool_adapter_with_roots(:mcp, roots: %w[agent_tools])
source.config.tool_roots << "actions" # in-place mutation bypasses the setter's guard
```

and keep the existing assertion that the resolved dirs include `agent_tools` but not `actions`, and that a warning is emitted. Update its `dirs = ...` line to read `dirs = described_class.send(:_adapter_dirs, :mcp)`.

For the member?-specific tests at lines ~619-662 that stub `Axn.config.tool_paths` + `Object.const_source_location`: replace the `tool_paths` stub with `register_tool_adapter_with_roots(:mcp, roots: [<same dir>])` and keep the `const_source_location` stub. (These now overlap the new union block; where a case is fully duplicated by Step 2's tests, delete the stale one rather than keep both.)

- [ ] **Step 9: Run the whole registry spec**

Run: `bundle exec rspec spec/axn/tools/registry_spec.rb`
Expected: PASS. If any example still references `_tool_dirs`, `_under_tool_path?`, or `Axn.config.tool_paths`, update it to the per-adapter equivalent (`_adapter_dirs(:mcp)` / `_under_adapter_root?` / `register_tool_adapter_with_roots`).

- [ ] **Step 10: Commit**

```bash
git add lib/axn/tools/registry.rb spec/axn/tools/registry_spec.rb spec/support/tool_adapter_helpers.rb
git commit -m "PRO-2948: union membership + per-adapter directory grants in registry"
```

---

## Task 5: Remove the global `tool_paths` setting

With the registry off `Axn.config.tool_paths`, delete the setting and its writer. Keep the broad-path predicate/normalizer/constants — they now back `AdapterRoots.validate!` and `_adapter_dirs`.

**Files:**
- Modify: `lib/axn/configuration.rb` — remove `setting :tool_paths` (66-67) and `def tool_paths=` (121-144)
- Test: `spec/axn/core/configuration_spec.rb`

**Interfaces:**
- Removed: `Axn.config.tool_paths`, `Axn.config.tool_paths=`.
- Retained (unchanged): `Axn::Configuration.broad_tool_path?`, `.normalize_tool_path`, `TOOL_PATHS_BLOCKLIST`, `BROAD_TOOL_PATH_LEAVES`.

- [ ] **Step 1: Write the failing tests**

Add to `spec/axn/core/configuration_spec.rb`:

```ruby
describe "tool_paths removal (PRO-2948)" do
  it "no longer exposes a global tool_paths setting" do
    expect(Axn.config).not_to respond_to(:tool_paths)
  end

  it "still exposes the broad-path guard used by adapter tool_roots" do
    expect(Axn::Configuration.broad_tool_path?("actions")).to be(true)
    expect(Axn::Configuration.broad_tool_path?("agent_tools")).to be(false)
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/axn/core/configuration_spec.rb -e "tool_paths removal"`
Expected: FAIL (`Axn.config` still responds to `tool_paths`).

- [ ] **Step 3: Remove the setting and writer**

In `lib/axn/configuration.rb`, delete the `setting :tool_paths, default: %w[agent_tools actions/tools]` declaration (lines 66-67, including its comment at 59-65) and the entire `def tool_paths=(value) ... end` writer (lines 121-144, including its comment). Leave the `TOOL_PATHS_BLOCKLIST`/`BROAD_TOOL_PATH_LEAVES` constants and the `broad_tool_path?`/`normalize_tool_path`/`_broad_tool_path_reason` methods in place.

- [ ] **Step 4: Remove now-dead tool_paths tests**

In `spec/axn/core/configuration_spec.rb`, delete any pre-existing examples asserting on `tool_paths=` acceptance/rejection (their coverage now lives in `adapter_roots_spec.rb`). Grep to confirm none remain:

Run: `grep -rni "tool_paths" spec/ lib/`
Expected: only the `TOOL_PATHS_BLOCKLIST` / `BROAD_TOOL_PATH_LEAVES` constant names — no `Axn.config.tool_paths` reads and no `tool_paths=` writes/definitions anywhere.

- [ ] **Step 5: Run tests to verify they pass**

Run: `bundle exec rspec spec/axn/core/configuration_spec.rb`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/axn/configuration.rb spec/axn/core/configuration_spec.rb
git commit -m "PRO-2948: remove global tool_paths setting (roots now per-adapter)"
```

---

## Task 6: Update the Rails eager-load spec

The dummy-app eager-load spec must register its adapter with a config source carrying `tool_roots`, since directory discovery no longer reads `Axn.config.tool_paths`.

**Files:**
- Modify: `spec_rails/dummy_app/spec/axn/tools_eager_load_spec.rb`

**Interfaces:**
- Consumes: `register_tool_adapter` with a config source; `AdapterRoots`.

- [ ] **Step 1: Read the current spec and its setup**

Run: `sed -n '1,60p' spec_rails/dummy_app/spec/axn/tools_eager_load_spec.rb`
Note how it currently sets the tool dir (a `tool_paths` stub or the config default) and which adapter key it registers.

- [ ] **Step 2: Register the adapter with roots instead of relying on tool_paths**

Replace the adapter setup so the dummy app's tool directory is supplied via a config source. If the spec previously relied on the `%w[agent_tools actions/tools]` default or a `tool_paths` stub, add an explicit source. Insert near the top of the spec's setup:

```ruby
before do
  Axn::Tools::Registry.reset_adapters!
  source = Module.new do
    extend Axn::Configurable
    extend Axn::Tools::AdapterRoots
  end
  # The dummy app keeps its tools under app/actions/tools (Zeitwerk-managed).
  source.config.tool_roots = %w[actions/tools]
  Axn.register_tool_adapter(:mcp, source)
end
```

Adjust the root string to match the dummy app's actual tool directory (whatever the existing spec expects Zeitwerk to eager-load), and remove any `allow(Axn.config).to receive(:tool_paths)` stub.

- [ ] **Step 3: Run the Rails spec with the dummy-app bundle**

Run: `BUNDLE_GEMFILE=spec_rails/dummy_app/Gemfile bundle exec rspec spec_rails/dummy_app/spec/axn/tools_eager_load_spec.rb`
Expected: PASS. (The dummy_app bundle is required — the root rspec run misses it.)

- [ ] **Step 4: Commit**

```bash
git add spec_rails/dummy_app/spec/axn/tools_eager_load_spec.rb
git commit -m "PRO-2948: dummy-app eager-load spec registers adapter with tool_roots"
```

---

## Task 7: Documentation + CHANGELOG

Document the new membership model and the removal of `tool_paths`.

**Files:**
- Modify: `docs/reference/configuration.md`, `docs/recipes/gem-configuration.md`, `CHANGELOG.md`

- [ ] **Step 1: Update `docs/reference/configuration.md`**

Find the section describing `tool_paths` (search for `tool_paths`). Replace it with a description of per-adapter `tool_roots` and the union model. Add (one line per paragraph, matching house style):

```markdown
### Tool directories are declared per adapter

Each tool adapter names the directories it consumes, on its own global config, via `tool_roots`. A directory listed by more than one adapter is a shared population; an adapter with empty `tool_roots` is purely declaration-driven.

​```ruby
Axn::MCP.configure            { |c| c.tool_roots = %w[agent_tools] }
Axn::RubyLLM.configure        { |c| c.tool_roots = %w[agent_tools] }
Axn::OpenAPI.configure        { |c| c.tool_roots = %w[agent_tools http_tools] }
​```

A tool's final adapter membership is the union of its directory grant (adapters whose `tool_roots` contain its file) and its `tool` declaration, minus any `except:` opt-out. An explicit `tool :openapi` *adds* openapi on top of the directory grant; `tool except: :ruby_llm` subtracts; `tool false` opts out entirely. `tool_roots` rejects broad entries (`actions`, `app`, `.`, `..`) exactly as the old `tool_paths` did.

An adapter registers itself, passing its own module as the config source the registry reads roots from:

​```ruby
Axn.register_tool_adapter(:openapi, self) # inside Axn::OpenAPI
​```
```

(Replace the backtick-guarded fences' zero-width markers with real triple backticks when editing.)

- [ ] **Step 2: Update `docs/recipes/gem-configuration.md`**

In the tool-declaration section, ensure the examples reflect union semantics and add an `except:` example. Verify no remaining prose claims a directory feeds "every adapter" or that `tool :mcp` "replaces" a directory grant.

- [ ] **Step 3: Add CHANGELOG entries**

In `CHANGELOG.md`, under `## Unreleased`, add a `### Tools & adapters` section (or append to an existing tools section) with:

```markdown
* [BREAKING] Tool adapter membership is now the union of a per-adapter directory grant and the `tool` declaration, minus a new `except:` opt-out. An explicit `tool :openapi` now *adds* that adapter on top of the tool's directory grant instead of replacing it. `tool except: :ruby_llm` removes a single adapter; `tool false` still opts out of all.
* [BREAKING] The global `Axn.config.tool_paths` setting is removed. Each adapter declares the directories it serves via `tool_roots` on its own config (`Axn::MCP.configure { |c| c.tool_roots = %w[agent_tools] }`); a directory shared by several adapters is listed under each. The same broad-path guard (`actions`/`app`/`.`/`..` rejected) applies.
* [BREAKING] `register_tool_adapter` takes an optional config source (`Axn.register_tool_adapter(:mcp, self)`) so the registry can read that adapter's `tool_roots`. Adapters with no directory roots may omit it.
```

- [ ] **Step 4: Verify docs build / no broken references**

Run: `grep -rn "tool_paths" docs/`
Expected: no stale references implying a global setting (any remaining mention should be historical-free and correct).

- [ ] **Step 5: Commit**

```bash
git add docs/reference/configuration.md docs/recipes/gem-configuration.md CHANGELOG.md
git commit -m "PRO-2948: document per-adapter tool_roots + union membership"
```

---

## Full-suite gate (after Task 7)

- [ ] Run the whole non-Rails suite: `bundle exec rspec spec/` — expected PASS.
- [ ] Run the Rails suite: `BUNDLE_GEMFILE=spec_rails/dummy_app/Gemfile bundle exec rspec spec_rails/` — expected PASS.
- [ ] Run RuboCop: `bundle exec rubocop lib/axn/tools/adapter_roots.rb lib/axn/tools/registry.rb lib/axn/core/tools.rb lib/axn/configuration.rb lib/axn.rb` — expected clean.

---

## Out of scope (follow-up, tracked separately)

- **Downstream gem updates** (axn-mcp, axn-ruby_llm): each must `extend Axn::Tools::AdapterRoots`, ship a default `tool_roots`, and register itself with `self`. These live in separate repos and land in sync with this release (see spec "Downstream impact").
- **os-app**: point mcp/ruby_llm `tool_roots` at the real shared-tools directory.
- **Future adapters** (PRO-2936 openapi, PRO-2937 data_shifter_web).
- The `lib/` autoload resolution bug is orthogonal and not addressed here.
```