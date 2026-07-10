# DRY the tool concept into axn core — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Grow axn core so any Axn is "tool-shaped" — it can reflect its contract to JSON Schema, serialize its result, name and describe itself, declare semantic hints, carry ambient caller identity, and let adapters register transport-specific config — with no `axn-tool` middle gem.

**Architecture:** Add read-only reflection (`Axn::Reflection::Schema` + `Axn::Reflection::Values`) plus class-level DSL (`axn_name`, `description`, `semantic_hints`) and one runtime seam (`ambient_context`, built on existing subfields). The extension registry reuses the existing `Axn::Configurable#overrides` primitive and `Axn::ExtensionConfig`. Adapters (PRO-2844 axn-mcp, PRO-2845 axn-ruby_llm) are out of scope and consume this.

**Tech Stack:** Ruby, ActiveSupport (`class_attribute`, `CurrentAttributes`, `ParameterFilter`), RSpec, RuboCop (custom cops).

## Global Constraints

- **Must work outside Rails.** Every feature must pass in `spec/` (non-Rails). Guard any AR/Rails constant with `defined?()`. The Rails dummy app lives in `spec_rails/`.
- **Naming:** internal reflection code speaks `inbound`/`outbound`; the public/adapter surface speaks `input`/`output`. Never expose `inbound`/`outbound` in a public method name.
- **`sensitive: true` must have zero effect on schema output.** Pin with a test.
- **Reflection is read-only and off the execution path.** No reflection call may run during `.call`.
- **No manual line breaks in Markdown docs** (repo convention): one line per paragraph.
- **Do not commit** unless the human asks; branch is `kali/pro-2842-…` (not a gitbutler worktree). Commit steps below are the intended seams — the executor should still confirm per repo policy.
- Test runner: `bundle exec rspec <path>`. Full suite: `bundle exec rspec`.

## File Structure

- Create `lib/axn/core/naming.rb` — class-level `axn_name` + `description`.
- Create `lib/axn/core/semantic_hints.rb` — `semantic_hints` DSL + validation.
- Create `lib/axn/core/ambient_context.rb` — reserved `ambient_context` reader, resolution chain, declared-only filtering, and the default `CurrentAttributes`-reading source (`Axn::Core::AmbientContext.default_source`). This is the single `AmbientContext` constant; there is intentionally no separate `Axn::AmbientContext` module (a public composition namespace is deferred — see Deferred).
- Create `lib/axn/reflection.rb`, `lib/axn/reflection/schema.rb`, `lib/axn/reflection/values.rb` — the reflection layer (moved from axn-mcp).
- Create `lib/rubocop/cop/axn/ambient_context_bypass.rb` — opt-in cop (registered via `lib/axn/rubocop.rb`).
- Modify `lib/axn/core.rb` — require + include the new Core modules.
- Modify `lib/axn/core/logging.rb:39-44` — use resolved name.
- Modify `lib/axn/core/contract_for_subfields.rb:54-59` — allow `on: :ambient_context`.
- Modify `lib/axn/core/contract.rb` — reserve `ambient_context`; exclude it from `inputs`/logging slices; add reserved execution-context key swap.
- Modify `lib/axn/internal/exception_context.rb` — replace raw `current_attributes` with `ambient_context`.
- Modify `lib/axn/extension_config.rb` — semantic-hint vocab registry.
- Modify `lib/axn/configuration.rb` — `ambient_context_provider` setting.
- Modify `lib/axn.rb` — require reflection.
- Modify `lib/axn/rubocop.rb` — register the new cop.

**Natural PR seam:** Phases A–E (naming + reflection + hints + registry) are pure additive read-only surface and can land as one PR; Phase F (ambient_context + observability + cop) is a cohesive runtime subsystem and can land as a second PR. Landing all as one PR is also fine for an alpha.

---

## Phase A — Naming

### Task 1: `axn_name` (class-level, inherited) + logging fix

**Files:**
- Create: `lib/axn/core/naming.rb`
- Modify: `lib/axn/core.rb` (require + include), `lib/axn/core/logging.rb:39-44`
- Test: `spec/axn/core/naming_spec.rb`

**Interfaces:**
- Produces: `Klass.axn_name` (getter, returns String or nil), `Klass.axn_name("X")` (setter), `Klass.resolved_axn_name` (returns `axn_name || name || "Anonymous Axn"`). `resolved_axn_name` is what logging/inspect/adapters call.

- [ ] **Step 1: Write the failing test**

```ruby
# spec/axn/core/naming_spec.rb
require "spec_helper"

RSpec.describe "Axn axn_name" do
  it "defaults resolved_axn_name to the class name" do
    klass = Class.new { include Axn; def self.name = "MyAction" }
    expect(klass.axn_name).to be_nil
    expect(klass.resolved_axn_name).to eq("MyAction")
  end

  it "overrides the resolved name when axn_name is set" do
    klass = Class.new { include Axn; axn_name "custom_tool" }
    expect(klass.axn_name).to eq("custom_tool")
    expect(klass.resolved_axn_name).to eq("custom_tool")
  end

  it "falls back to 'Anonymous Axn' for a truly anonymous, unnamed class" do
    klass = Class.new { include Axn; def self.name = nil }
    expect(klass.resolved_axn_name).to eq("Anonymous Axn")
  end

  it "inherits axn_name but a subclass can override it" do
    parent = Class.new { include Axn; axn_name "parent_tool" }
    child = Class.new(parent)
    expect(child.resolved_axn_name).to eq("parent_tool")
    child.axn_name "child_tool"
    expect(child.resolved_axn_name).to eq("child_tool")
    expect(parent.resolved_axn_name).to eq("parent_tool")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/core/naming_spec.rb`
Expected: FAIL with `NoMethodError: undefined method 'axn_name'`.

- [ ] **Step 3: Write the module**

```ruby
# lib/axn/core/naming.rb
# frozen_string_literal: true

module Axn
  module Core
    module Naming
      ANONYMOUS = "Anonymous Axn"

      def self.included(base)
        base.class_eval do
          # instance_accessor: false — this is a class-level DSL, not per-instance state.
          class_attribute :_axn_name, instance_accessor: false, default: nil
          extend ClassMethods
        end
      end

      module ClassMethods
        NOT_SET = Object.new.freeze

        def axn_name(value = NOT_SET)
          return _axn_name if value.equal?(NOT_SET)

          self._axn_name = value
        end

        # The single canonical display name: explicit override, else Ruby's class name,
        # else a stable fallback (replaces the old literal "Anonymous Class").
        def resolved_axn_name
          axn_name.presence || name.presence || ANONYMOUS
        end
      end
    end
  end
end
```

- [ ] **Step 4: Wire it into Core and the logger**

In `lib/axn/core.rb`, add `require "axn/core/naming"` near the other core requires, and `include Core::Naming` in the `included` block (before `Core::Logging` so logging can call it).

In `lib/axn/core/logging.rb`, change `_log_prefix` (lines 39-44):

```ruby
def _log_prefix
  names = NestingTracking._current_axn_stack.map do |axn|
    axn.class.resolved_axn_name
  end
  "[#{names.join(' > ')}]"
end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bundle exec rspec spec/axn/core/naming_spec.rb`
Expected: PASS (4 examples).

- [ ] **Step 6: Commit**

```bash
git add lib/axn/core/naming.rb lib/axn/core.rb lib/axn/core/logging.rb spec/axn/core/naming_spec.rb
git commit -m "Add Axn.axn_name class-level name override (fixes 'Anonymous Class' in log stack)"
```

### Task 2: class-level `description`

**Files:**
- Modify: `lib/axn/core/naming.rb` (add to same module)
- Test: `spec/axn/core/naming_spec.rb` (extend)

**Interfaces:**
- Produces: `Klass.description` (getter, String or nil), `Klass.description("X")` (setter). Inherited by subclasses; independent of the field-level `description:` metadata key.

- [ ] **Step 1: Write the failing test**

Append to `spec/axn/core/naming_spec.rb`:

```ruby
RSpec.describe "Axn class-level description" do
  it "defaults to nil and stores a string" do
    klass = Class.new { include Axn }
    expect(klass.description).to be_nil
    klass.description "Does a thing."
    expect(klass.description).to eq("Does a thing.")
  end

  it "inherits and can be overridden" do
    parent = Class.new { include Axn; description "parent" }
    child = Class.new(parent)
    expect(child.description).to eq("parent")
    child.description "child"
    expect(child.description).to eq("child")
    expect(parent.description).to eq("parent")
  end

  it "does not collide with the field-level description: metadata key" do
    klass = Class.new do
      include Axn
      description "class desc"
      expects :foo, description: "field desc"
    end
    expect(klass.description).to eq("class desc")
    config = klass.internal_field_configs.find { |c| c.field == :foo }
    expect(config.description).to eq("field desc")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/core/naming_spec.rb -e "class-level description"`
Expected: FAIL with `NoMethodError: undefined method 'description'` (or wrong arity).

- [ ] **Step 3: Add `description` to the Naming module**

In `lib/axn/core/naming.rb`, add `:_axn_description` to the `class_attribute` line:

```ruby
class_attribute :_axn_name, :_axn_description, instance_accessor: false, default: nil
```

Add to `ClassMethods`:

```ruby
def description(value = NOT_SET)
  return _axn_description if value.equal?(NOT_SET)

  self._axn_description = value
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/axn/core/naming_spec.rb`
Expected: PASS (7 examples).

- [ ] **Step 5: Commit**

```bash
git add lib/axn/core/naming.rb spec/axn/core/naming_spec.rb
git commit -m "Add class-level Axn.description"
```

---

## Phase B — Extension registry primitives

### Task 3: semantic-hint vocab registry + per-adapter metadata bag

**Files:**
- Modify: `lib/axn/extension_config.rb`
- Create: `lib/axn/core/extension_metadata.rb`
- Modify: `lib/axn/core.rb` (require + include)
- Test: `spec/extension_config_spec.rb` (extend), `spec/axn/core/extension_metadata_spec.rb`

**Interfaces:**
- Produces: `Axn.extension_config.registered_semantic_hints` (Set, seeded `%i[read_only idempotent destructive]`), `Axn.extension_config.register_semantic_hint(*syms)`.
- Produces: `Klass.set_extension_metadata(:adapter, **kwargs)` and `Klass.extension_metadata(:adapter)` (returns Hash, `{}` if unset), inherited and copy-on-write.

- [ ] **Step 1: Write the failing tests**

Append to `spec/extension_config_spec.rb`:

```ruby
RSpec.describe "Axn::ExtensionConfig semantic hints" do
  after { Axn.instance_variable_set(:@extension_config, nil) }

  it "seeds the core semantic-hint vocabulary" do
    expect(Axn.extension_config.registered_semantic_hints).to include(:read_only, :idempotent, :destructive)
  end

  it "lets an adapter register additional vocabulary" do
    Axn.extension_config.register_semantic_hint(:open_world, :closed_world)
    expect(Axn.extension_config.registered_semantic_hints).to include(:open_world, :closed_world)
  end
end
```

Create `spec/axn/core/extension_metadata_spec.rb`:

```ruby
require "spec_helper"

RSpec.describe "Axn extension_metadata" do
  it "returns an empty hash when unset" do
    klass = Class.new { include Axn }
    expect(klass.extension_metadata(:mcp)).to eq({})
  end

  it "stores per-adapter metadata and merges on repeat" do
    klass = Class.new { include Axn }
    klass.set_extension_metadata(:mcp, title: "T")
    klass.set_extension_metadata(:mcp, annotations: { read_only_hint: true })
    expect(klass.extension_metadata(:mcp)).to eq(title: "T", annotations: { read_only_hint: true })
    expect(klass.extension_metadata(:ruby_llm)).to eq({})
  end

  it "inherits metadata without mutating the parent (copy-on-write)" do
    parent = Class.new { include Axn }
    parent.set_extension_metadata(:mcp, title: "parent")
    child = Class.new(parent)
    child.set_extension_metadata(:mcp, title: "child")
    expect(child.extension_metadata(:mcp)).to eq(title: "child")
    expect(parent.extension_metadata(:mcp)).to eq(title: "parent")
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/extension_config_spec.rb spec/axn/core/extension_metadata_spec.rb`
Expected: FAIL (`undefined method 'registered_semantic_hints'`, `undefined method 'extension_metadata'`).

- [ ] **Step 3: Extend `ExtensionConfig`**

In `lib/axn/extension_config.rb`, add inside the class:

```ruby
def registered_semantic_hints
  @registered_semantic_hints ||= Set.new(%i[read_only idempotent destructive])
end

def register_semantic_hint(*hints)
  registered_semantic_hints.merge(hints.map(&:to_sym))
end
```

- [ ] **Step 4: Create the metadata module**

```ruby
# lib/axn/core/extension_metadata.rb
# frozen_string_literal: true

module Axn
  module Core
    # A per-adapter, inherited, copy-on-write metadata bag. Adapters register transport-specific
    # DSL (via Axn::Configurable#overrides) and stash resolved config here for `wrap` to read.
    module ExtensionMetadata
      def self.included(base)
        base.class_eval do
          class_attribute :_axn_extension_metadata, instance_accessor: false, default: {}
          extend ClassMethods
        end
      end

      module ClassMethods
        def extension_metadata(adapter)
          _axn_extension_metadata[adapter.to_sym] || {}
        end

        # Copy-on-write: never mutate the inherited Hash in place (class_attribute shares the
        # object reference with the parent until reassigned) — merge into a fresh Hash and reassign.
        def set_extension_metadata(adapter, **kwargs)
          adapter = adapter.to_sym
          merged = (_axn_extension_metadata[adapter] || {}).merge(kwargs)
          self._axn_extension_metadata = _axn_extension_metadata.merge(adapter => merged)
        end
      end
    end
  end
end
```

- [ ] **Step 5: Wire into Core**

In `lib/axn/core.rb`, add `require "axn/core/extension_metadata"` and `include Core::ExtensionMetadata` in the `included` block.

- [ ] **Step 6: Run tests to verify they pass**

Run: `bundle exec rspec spec/extension_config_spec.rb spec/axn/core/extension_metadata_spec.rb`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/axn/extension_config.rb lib/axn/core/extension_metadata.rb lib/axn/core.rb spec/extension_config_spec.rb spec/axn/core/extension_metadata_spec.rb
git commit -m "Add extension registry primitives: semantic-hint vocab + per-adapter metadata bag"
```

---

## Phase C — semantic_hints

### Task 4: `semantic_hints` DSL

**Files:**
- Create: `lib/axn/core/semantic_hints.rb`
- Modify: `lib/axn/core.rb` (require + include)
- Test: `spec/axn/core/semantic_hints_spec.rb`

**Interfaces:**
- Consumes: `Axn.extension_config.registered_semantic_hints` (Task 3).
- Produces: `Klass.semantic_hints(*syms)` (setter, validates), `Klass.semantic_hints` (getter, returns frozen Array). Inherited.

- [ ] **Step 1: Write the failing test**

```ruby
# spec/axn/core/semantic_hints_spec.rb
require "spec_helper"

RSpec.describe "Axn semantic_hints" do
  after { Axn.instance_variable_set(:@extension_config, nil) }

  it "defaults to an empty array" do
    klass = Class.new { include Axn }
    expect(klass.semantic_hints).to eq([])
  end

  it "stores validated core-vocabulary hints" do
    klass = Class.new { include Axn; semantic_hints :read_only, :idempotent }
    expect(klass.semantic_hints).to contain_exactly(:read_only, :idempotent)
  end

  it "rejects unknown hints" do
    expect do
      Class.new { include Axn; semantic_hints :wat }
    end.to raise_error(ArgumentError, /unknown semantic hint.*:wat/i)
  end

  it "accepts adapter-registered vocabulary" do
    Axn.extension_config.register_semantic_hint(:open_world)
    klass = Class.new { include Axn; semantic_hints :open_world }
    expect(klass.semantic_hints).to eq([:open_world])
  end

  it "inherits hints and lets a subclass replace them" do
    parent = Class.new { include Axn; semantic_hints :read_only }
    child = Class.new(parent)
    expect(child.semantic_hints).to eq([:read_only])
    child.semantic_hints :destructive
    expect(child.semantic_hints).to eq([:destructive])
    expect(parent.semantic_hints).to eq([:read_only])
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/core/semantic_hints_spec.rb`
Expected: FAIL (`undefined method 'semantic_hints'`).

- [ ] **Step 3: Write the module**

```ruby
# lib/axn/core/semantic_hints.rb
# frozen_string_literal: true

module Axn
  module Core
    # Advisory-only side-effect / operational profile. Nothing enforces it (a read_only tool can
    # still fire a destructive call, especially `idempotent`) — the _hints suffix keeps that honest.
    # Core owns :read_only/:idempotent/:destructive; adapters extend the vocab via
    # Axn.extension_config.register_semantic_hint. Adapters interpret hints (MCP annotations,
    # REST verb, RubyLLM gating).
    module SemanticHints
      def self.included(base)
        base.class_eval do
          class_attribute :_semantic_hints, instance_accessor: false, default: [].freeze
          extend ClassMethods
        end
      end

      module ClassMethods
        def semantic_hints(*hints)
          return _semantic_hints if hints.empty?

          hints = hints.map(&:to_sym)
          vocab = Axn.extension_config.registered_semantic_hints
          unknown = hints.reject { |h| vocab.include?(h) }
          raise ArgumentError, "Unknown semantic hint(s): #{unknown.map(&:inspect).join(', ')}. Known: #{vocab.to_a.sort.join(', ')}" if unknown.any?

          self._semantic_hints = hints.freeze
        end
      end
    end
  end
end
```

- [ ] **Step 4: Wire into Core**

In `lib/axn/core.rb`, add `require "axn/core/semantic_hints"` and `include Core::SemanticHints` in the `included` block.

- [ ] **Step 5: Run tests to verify they pass**

Run: `bundle exec rspec spec/axn/core/semantic_hints_spec.rb`
Expected: PASS (5 examples).

- [ ] **Step 6: Commit**

```bash
git add lib/axn/core/semantic_hints.rb lib/axn/core.rb spec/axn/core/semantic_hints_spec.rb
git commit -m "Add Axn.semantic_hints DSL (validated, adapter-extensible vocabulary)"
```

---

## Phase D — Reflection: values

### Task 5: `Axn::Reflection::Values`

**Files:**
- Create: `lib/axn/reflection.rb`, `lib/axn/reflection/values.rb`
- Modify: `lib/axn.rb` (require)
- Test: `spec/axn/reflection/values_spec.rb`

**Interfaces:**
- Produces: `Axn::Reflection::Values.serialize_exposed(result, field_configs)` → `{ "field" => json_safe }`, and `Axn::Reflection::Values.serialize_value(value)` → JSON-safe scalar/Hash/Array.

- [ ] **Step 1: Write the failing test**

```ruby
# spec/axn/reflection/values_spec.rb
require "spec_helper"

RSpec.describe Axn::Reflection::Values do
  describe ".serialize_value" do
    it "passes through JSON scalars" do
      expect(described_class.serialize_value(1)).to eq(1)
      expect(described_class.serialize_value("x")).to eq("x")
      expect(described_class.serialize_value(true)).to eq(true)
      expect(described_class.serialize_value(nil)).to be_nil
    end

    it "stringifies hash keys recursively" do
      expect(described_class.serialize_value({ a: { b: 1 } })).to eq("a" => { "b" => 1 })
    end

    it "maps arrays" do
      expect(described_class.serialize_value([1, { a: 2 }])).to eq([1, { "a" => 2 }])
    end

    it "falls back to as_json, then to_h, then to_s" do
      as_json_obj = Object.new.tap { |o| def o.as_json(*) = { "k" => "v" }; }
      expect(described_class.serialize_value(as_json_obj)).to eq("k" => "v")
      to_s_obj = Object.new.tap { |o| def o.to_s = "S"; }
      expect(described_class.serialize_value(to_s_obj)).to eq("S")
    end
  end

  describe ".serialize_exposed" do
    it "serializes each declared field by wire key (string)" do
      klass = Class.new do
        include Axn
        exposes :count, type: Integer
        def call = expose(count: 3)
      end
      result = klass.call
      expect(described_class.serialize_exposed(result, klass.external_field_configs)).to eq("count" => 3)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/reflection/values_spec.rb`
Expected: FAIL (`uninitialized constant Axn::Reflection`).

- [ ] **Step 3: Write the modules** (move from `axn-mcp/lib/axn/mcp/serializer.rb`, transport-agnostic half only)

```ruby
# lib/axn/reflection.rb
# frozen_string_literal: true

require "axn/reflection/values"
require "axn/reflection/schema"

module Axn
  # Read-only reflection of an Axn's contract (Schema) and a Result's values (Values) into
  # transport-agnostic Hashes. Off the execution path; used by adapters (MCP/RubyLLM/REST) and docs.
  module Reflection
  end
end
```

```ruby
# lib/axn/reflection/values.rb
# frozen_string_literal: true

# NOTE: do NOT require "active_support/core_ext/object/json" here. Doing so makes EVERY object
# respond_to?(:as_json), which would short-circuit the to_h/to_s fallbacks below and change
# serialization behavior versus the axn-mcp original. Rely on objects that define as_json themselves
# (ActiveRecord models, etc.), exactly as the original did.

module Axn
  module Reflection
    module Values
      module_function

      # Result → JSON-safe Hash keyed by wire key (string), over declared outbound configs.
      def serialize_exposed(result, field_configs)
        field_configs.each_with_object({}) do |config, hash|
          hash[config.field.to_s] = serialize_value(result.public_send(config.field))
        end
      end

      def serialize_value(value)
        case value
        when nil, String, Integer, Float, TrueClass, FalseClass
          value
        when Hash
          value.transform_keys(&:to_s).transform_values { |v| serialize_value(v) }
        when Array
          value.map { |v| serialize_value(v) }
        else
          if value.respond_to?(:as_json)
            value.as_json
          elsif value.respond_to?(:to_h)
            serialize_value(value.to_h)
          else
            value.to_s
          end
        end
      end
    end
  end
end
```

Note: `require "axn/reflection/schema"` in `reflection.rb` depends on Task 6; if implementing Task 5 alone, temporarily drop that require line and restore it in Task 6.

- [ ] **Step 4: Require it**

In `lib/axn.rb`, add `require "axn/reflection"` after the `require "axn/executor"` line.

- [ ] **Step 5: Run tests to verify they pass**

Run: `bundle exec rspec spec/axn/reflection/values_spec.rb`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/axn/reflection.rb lib/axn/reflection/values.rb lib/axn.rb spec/axn/reflection/values_spec.rb
git commit -m "Add Axn::Reflection::Values (Result → JSON-safe Hash)"
```

---

## Phase E — Reflection: schema

### Task 6: `Axn::Reflection::Schema` (move `SchemaBuilder`)

**Files:**
- Create: `lib/axn/reflection/schema.rb`
- Test: `spec/axn/reflection/schema_spec.rb`

**Interfaces:**
- Consumes: `internal_field_configs`, `external_field_configs`, `subfield_configs` (each config responds to `.field`, `.validations`, `.description`, `.default`, `.on`), `Axn::Internal::FieldConfig.optional?`.
- Produces: `Axn::Reflection::Schema.build_input(field_configs, subfield_configs = [])` → Hash; `Axn::Reflection::Schema.build_output(field_configs)` → Hash. Excludes the `:ambient_context` parent from input.

- [ ] **Step 1: Write the failing test**

```ruby
# spec/axn/reflection/schema_spec.rb
require "spec_helper"

RSpec.describe Axn::Reflection::Schema do
  it "builds an input schema with required/optional and descriptions" do
    klass = Class.new do
      include Axn
      expects :name, type: String, description: "the name"
      expects :limit, type: Integer, default: 20, optional: true
    end
    schema = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)
    expect(schema[:type]).to eq("object")
    expect(schema[:properties][:name]).to include(type: "string", description: "the name")
    expect(schema[:properties][:limit]).to include(type: "integer", default: 20)
    expect(schema[:required]).to eq(["name"])
  end

  it "builds an output schema" do
    klass = Class.new do
      include Axn
      exposes :ok, type: :boolean
    end
    schema = described_class.build_output(klass.external_field_configs)
    expect(schema[:properties][:ok]).to include(type: "boolean")
  end

  it "excludes the ambient_context parent from the input schema" do
    # ambient_context becomes a valid `on:` parent in Phase F; here assert the exclusion constant.
    expect(described_class::EXCLUDED_FROM_INPUT_SCHEMA).to include(:ambient_context)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/reflection/schema_spec.rb`
Expected: FAIL (`uninitialized constant Axn::Reflection::Schema`).

- [ ] **Step 3: Create the module by moving `axn-mcp/lib/axn/mcp/schema_builder.rb`**

Copy that file verbatim into `lib/axn/reflection/schema.rb` with these exact changes:
- Wrap in `module Axn; module Reflection; module Schema` (rename `module MCP; module SchemaBuilder`).
- Rename the method-holding module to `Schema` and keep `module_function`.
- Rename `EXCLUDED_FROM_SCHEMA = %i[server_context].freeze` → `EXCLUDED_FROM_INPUT_SCHEMA = %i[ambient_context].freeze`, and update its one use in `build_input` (`next if EXCLUDED_FROM_INPUT_SCHEMA.include?(config.field)`).
- Rename `build_input`'s first-line comment to reference `ambient_context`.
- The `optional?` helper stays: `Axn::Internal::FieldConfig.optional?(config)`.

The body (TYPE_MAP/FORMAT_MAP, `build_input`, `build_output`, `build_property`, `apply_structured_schema!`, `items_schema_for`, `single_items_schema`, `member_properties`, `build_model_property`, `json_type_for`, `optional?`) is otherwise identical to the axn-mcp original — it already reads only core-owned config objects.

- [ ] **Step 4: Restore the require**

Ensure `lib/axn/reflection.rb` has `require "axn/reflection/schema"` (added/kept from Task 5).

- [ ] **Step 5: Run tests to verify they pass**

Run: `bundle exec rspec spec/axn/reflection/schema_spec.rb`
Expected: PASS (3 examples).

- [ ] **Step 6: Commit**

```bash
git add lib/axn/reflection/schema.rb lib/axn/reflection.rb spec/axn/reflection/schema_spec.rb
git commit -m "Add Axn::Reflection::Schema (contract → JSON Schema; moved from axn-mcp)"
```

### Task 7: `input_schema` / `output_schema` public surface + sensitive invariant

**Files:**
- Create: `lib/axn/core/schema_reflection.rb`
- Modify: `lib/axn/core.rb` (require + include)
- Test: `spec/axn/core/schema_reflection_spec.rb`

**Interfaces:**
- Consumes: `Axn::Reflection::Schema` (Task 6).
- Produces: `Klass.input_schema` → Hash (expects + subfields, minus ambient_context), `Klass.output_schema` → Hash (exposes). Recomputed on read (reflection is off the execution path; no memoization required).

- [ ] **Step 1: Write the failing test**

```ruby
# spec/axn/core/schema_reflection_spec.rb
require "spec_helper"

RSpec.describe "Axn class-level schema reflection" do
  let(:klass) do
    Class.new do
      include Axn
      expects :token, type: String, sensitive: true, description: "secret"
      exposes :status, type: String
      def call = expose(status: "ok")
    end
  end

  it "exposes input_schema over expects" do
    expect(klass.input_schema[:properties][:token]).to include(type: "string", description: "secret")
    expect(klass.input_schema[:required]).to eq(["token"])
  end

  it "exposes output_schema over exposes" do
    expect(klass.output_schema[:properties][:status]).to include(type: "string")
  end

  it "does NOT let sensitive: true change the input schema" do
    plain = Class.new do
      include Axn
      expects :token, type: String, description: "secret"
    end
    expect(klass.input_schema).to eq(plain.input_schema)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/core/schema_reflection_spec.rb`
Expected: FAIL (`undefined method 'input_schema'`).

- [ ] **Step 3: Write the module**

```ruby
# lib/axn/core/schema_reflection.rb
# frozen_string_literal: true

require "axn/reflection"

module Axn
  module Core
    # Public, transport-free schema export. Speaks input/output (the lingua franca of
    # JSON Schema / OpenAPI / MCP / LLM function calling); the internal builder speaks
    # inbound/outbound. Adapters wrap these Hashes into their transport objects.
    module SchemaReflection
      def self.included(base)
        base.extend ClassMethods
      end

      module ClassMethods
        def input_schema
          Axn::Reflection::Schema.build_input(internal_field_configs, subfield_configs)
        end

        def output_schema
          Axn::Reflection::Schema.build_output(external_field_configs)
        end
      end
    end
  end
end
```

- [ ] **Step 4: Wire into Core**

In `lib/axn/core.rb`, add `require "axn/core/schema_reflection"` and `include Core::SchemaReflection` in the `included` block.

- [ ] **Step 5: Run tests to verify they pass**

Run: `bundle exec rspec spec/axn/core/schema_reflection_spec.rb`
Expected: PASS (3 examples).

- [ ] **Step 6: Commit**

```bash
git add lib/axn/core/schema_reflection.rb lib/axn/core.rb spec/axn/core/schema_reflection_spec.rb
git commit -m "Add class-level input_schema/output_schema (transport-free schema export)"
```

---

## Phase F — ambient_context

### Task 8: reserved `ambient_context` parent reader + accept `on: :ambient_context`

**Files:**
- Create: `lib/axn/core/ambient_context.rb`
- Modify: `lib/axn/core.rb` (require + include), `lib/axn/core/contract_for_subfields.rb:54-59`, `lib/axn/core/contract.rb` (reserve name)
- Test: `spec/axn/core/ambient_context_spec.rb`

**Interfaces:**
- Produces: instance reader `#ambient_context` → Hash (`{}` by default), overridable value store `@__ambient_context`. `on: :ambient_context` is accepted even though `ambient_context` is not a declared field.
- Consumes: `Core::FieldResolvers` (subfield extraction), `ContractForSubfields.resolve_parent` (calls `#ambient_context`).

- [ ] **Step 1: Write the failing test**

```ruby
# spec/axn/core/ambient_context_spec.rb
require "spec_helper"

RSpec.describe "Axn ambient_context (reader + subfield parent)" do
  it "reads {} by default and does not appear in the input schema" do
    klass = Class.new { include Axn }
    expect(klass.input_schema[:properties]).not_to have_key(:ambient_context)
  end

  it "reads an explicitly-passed ambient_context subfield" do
    klass = Class.new do
      include Axn
      expects :company_id, on: :ambient_context, type: Integer
      exposes :cid
      def call = expose(cid: company_id)
    end
    result = klass.call(ambient_context: { company_id: 42 })
    expect(result).to be_ok
    expect(result.cid).to eq(42)
  end

  it "keeps ambient_context subfields out of the input schema (nested under excluded parent)" do
    klass = Class.new do
      include Axn
      expects :company_id, on: :ambient_context, type: Integer
      expects :limit, type: Integer, default: 5
    end
    props = klass.input_schema[:properties]
    expect(props).to have_key(:limit)
    expect(props).not_to have_key(:company_id)
    expect(props).not_to have_key(:ambient_context)
  end

  it "rejects a user-declared top-level ambient_context field" do
    expect do
      Class.new { include Axn; expects :ambient_context }
    end.to raise_error(Axn::ContractViolation::ReservedAttributeError)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/core/ambient_context_spec.rb`
Expected: FAIL — the explicit-pass example errors with `no such reader exists` for `on: :ambient_context`.

- [ ] **Step 3: Allow `on: :ambient_context` in the subfield root check**

In `lib/axn/core/contract_for_subfields.rb`, change the guard (lines 54-59):

```ruby
root = on.to_s.split(".").first.to_sym
unless root == Axn::Core::AmbientContext::PARENT || (internal_field_configs + subfield_configs).map(&:reader_as).include?(root)
  raise ArgumentError,
        "expects called with `on: #{on}`, but no such reader exists " \
        "(are you sure you've declared a field — or alias — named :#{root}?)"
end
```

- [ ] **Step 4: Reserve the name for top-level `expects`**

In `lib/axn/core/contract.rb`, add `ambient_context` to `RESERVED_FIELD_NAMES_FOR_EXPECTATIONS` (the frozen array around line 312).

- [ ] **Step 5: Write the ambient_context module (reader only for now)**

```ruby
# lib/axn/core/ambient_context.rb
# frozen_string_literal: true

module Axn
  module Core
    # `ambient_context` is a reserved, always-present parent on every Axn. Its reader returns a Hash
    # ({} by default) that subfields extract from via `expects :x, on: :ambient_context`. Reads are
    # declaration-gated (a reader exists only for declared subfields), and the hash is filtered to the
    # declared ambient keys (Task 9) so it never carries a merged dump of process-wide Current state.
    module AmbientContext
      PARENT = :ambient_context

      # Instance reader used by ContractForSubfields.resolve_parent (public_send(:ambient_context)).
      def ambient_context
        return @__ambient_context if defined?(@__ambient_context)

        @__ambient_context = _resolve_ambient_context
      end

      private

      # Overridden in Task 9 with the full explicit → provider → {} resolution + declared-only filter.
      def _resolve_ambient_context
        _explicit_ambient_context || {}
      end

      def _explicit_ambient_context
        raw = @__context.provided_data
        key = raw.respond_to?(:with_indifferent_access) ? raw.with_indifferent_access : raw
        key[PARENT]
      end
    end
  end
end
```

- [ ] **Step 6: Wire into Core**

In `lib/axn/core.rb`, add `require "axn/core/ambient_context"` and `include Core::AmbientContext` in the `included` block. Ensure it is required before `contract_for_subfields` references `Axn::Core::AmbientContext::PARENT` (put the `require` near the top of the core requires; the constant is resolved at call time so require-order only needs the constant defined before first `.call`).

- [ ] **Step 7: Run tests to verify they pass**

Run: `bundle exec rspec spec/axn/core/ambient_context_spec.rb`
Expected: PASS (4 examples).

- [ ] **Step 8: Commit**

```bash
git add lib/axn/core/ambient_context.rb lib/axn/core.rb lib/axn/core/contract_for_subfields.rb lib/axn/core/contract.rb spec/axn/core/ambient_context_spec.rb
git commit -m "Add reserved ambient_context parent reader + accept on: :ambient_context subfields"
```

### Task 9: resolution chain + `ambient_context_provider` + declared-only filter

**Files:**
- Modify: `lib/axn/configuration.rb` (setting), `lib/axn/core/ambient_context.rb` (full resolution + `default_source`)
- Test: `spec/axn/core/ambient_context_spec.rb` (extend)

**Interfaces:**
- Produces: `Axn.config.ambient_context_provider` (a callable returning a source Hash, or nil), `Axn::Core::AmbientContext.default_source` (module function returning a merged Hash of registered `CurrentAttributes`, `{}` when none).
- Behavior: resolved `#ambient_context` = (explicit `ambient_context:` kwarg, else provider result, else `default_source`) **filtered to declared ambient subfield keys**.

- [ ] **Step 1: Write the failing tests**

Append to `spec/axn/core/ambient_context_spec.rb`:

```ruby
RSpec.describe "Axn ambient_context resolution" do
  after { Axn.config.instance_variable_set(:@ambient_context_provider, nil) }

  let(:klass) do
    Class.new do
      include Axn
      expects :company_id, on: :ambient_context, type: Integer
      exposes :ctx, allow_blank: true
      def call = expose(ctx: ambient_context)
    end
  end

  it "filters the hash to declared ambient keys (explicit path)" do
    result = klass.call(ambient_context: { company_id: 7, secret: "leak" })
    expect(result.ctx).to eq(company_id: 7)
  end

  it "falls back to the configured provider, then filters to declared keys" do
    Axn.config.ambient_context_provider = -> { { company_id: 99, other: "x" } }
    result = klass.call
    expect(result.ctx).to eq(company_id: 99)
  end

  it "explicit REPLACES the provider (no silent merge)" do
    Axn.config.ambient_context_provider = -> { { company_id: 99 } }
    result = klass.call(ambient_context: { company_id: 1 })
    expect(result.ctx).to eq(company_id: 1)
  end

  it "fails inbound validation for a required ambient subfield when empty" do
    result = klass.call
    expect(result).not_to be_ok
  end
end
```

Also append a `default_source` example to `spec/axn/core/ambient_context_spec.rb`:

```ruby
RSpec.describe "Axn::Core::AmbientContext.default_source" do
  it "merges attributes across registered CurrentAttributes descendants" do
    skip "ActiveSupport::CurrentAttributes required" unless defined?(ActiveSupport::CurrentAttributes)

    current = Class.new(ActiveSupport::CurrentAttributes) { attribute :company_id }
    current.instance.company_id = 5
    merged = Axn::Core::AmbientContext.default_source
    expect(merged[:company_id]).to eq(5)
  ensure
    current&.reset
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/axn/core/ambient_context_spec.rb`
Expected: FAIL (secret not filtered; `ambient_context_provider` undefined; `default_source` undefined).

- [ ] **Step 3: Add the config setting**

In `lib/axn/configuration.rb`, add an accessor. In the `attr_writer` list add `:ambient_context_provider`, and add a reader:

```ruby
def ambient_context_provider = @ambient_context_provider
```

- [ ] **Step 4: Add `default_source` to the Core AmbientContext module**

In `lib/axn/core/ambient_context.rb`, add a module-level function (alongside `PARENT`, outside the instance methods). Default ambient-context source: a live view over every registered `ActiveSupport::CurrentAttributes`. Core filters the result down to each Axn's declared ambient keys, so returning everything here is safe — undeclared keys are never readable and never injected.

```ruby
module AmbientContext
  PARENT = :ambient_context

  module_function

  def default_source
    return {} unless defined?(ActiveSupport::CurrentAttributes)

    ActiveSupport::CurrentAttributes.descendants.each_with_object({}) do |klass, acc|
      acc.merge!(klass.instance.attributes)
    end
  end

  # ... instance methods below (see Task 8) ...
```

Keep the instance methods (`ambient_context`, `_resolve_ambient_context`, etc.) as instance methods of the same module — `module_function` only affects the methods declared under it, so declare `default_source` before the instance methods and leave the instance methods as ordinary `def`s after a plain `public`/section break, or define `default_source` via `def self.default_source`. Simplest and least error-prone: use `def self.default_source` and drop the `module_function` line so the instance methods stay instance methods.

- [ ] **Step 5: Complete the resolution in the Core module**

Replace `_resolve_ambient_context` in `lib/axn/core/ambient_context.rb`:

```ruby
def _resolve_ambient_context
  source = _explicit_ambient_context
  source = _provider_source if source.nil?
  source ||= {}
  _filter_to_declared(source)
end

def _provider_source
  provider = Axn.config.ambient_context_provider
  provider ? provider.call : Axn::Core::AmbientContext.default_source
end

# Only the declared ambient subfield keys survive — the hash never carries a process-wide dump.
def _filter_to_declared(source)
  indifferent = source.respond_to?(:with_indifferent_access) ? source.with_indifferent_access : source
  self.class.subfield_configs
      .select { |c| c.on.to_sym == PARENT }
      .each_with_object({}) { |c, acc| acc[c.field] = indifferent[c.field] if indifferent.key?(c.field) }
end
```

Note: subfield validation reads `ambient_context` via `resolve_parent` → the `#ambient_context` reader → this filtered hash, so required-but-absent declared keys fail inbound validation naturally.

- [ ] **Step 6: Run tests to verify they pass**

Run: `bundle exec rspec spec/axn/core/ambient_context_spec.rb`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/axn/configuration.rb lib/axn/core/ambient_context.rb spec/axn/core/ambient_context_spec.rb
git commit -m "Add ambient_context resolution chain + provider + declared-only filtering"
```

### Task 10: observability — replace `current_attributes` with `ambient_context`

**Files:**
- Modify: `lib/axn/core/contract.rb` (`RESERVED_EXECUTION_CONTEXT_KEYS`, `execution_context`, exclude parent from `inputs`), `lib/axn/internal/exception_context.rb`
- Test: `spec/axn/core/ambient_context_spec.rb` (extend), `spec/axn/internal/exception_context_spec.rb` (extend if present, else create)

**Interfaces:**
- Consumes: `#ambient_context` (Task 9), `inspection_filter` (existing sensitive filter).
- Produces: `execution_context` includes a framework-populated, sensitive-filtered `:ambient_context` key when non-empty; the raw `::Current.attributes` capture is removed; `ambient_context` never appears in `inputs`/logging.

- [ ] **Step 1: Write the failing tests**

Append to `spec/axn/core/ambient_context_spec.rb`:

```ruby
RSpec.describe "Axn ambient_context observability" do
  after { Axn.config.instance_variable_set(:@ambient_context_provider, nil) }

  let(:klass) do
    Class.new do
      include Axn
      expects :company_id, on: :ambient_context, type: Integer
      expects :secret_id, on: :ambient_context, type: Integer, sensitive: true
      def call = nil
    end
  end

  it "puts sensitive-filtered ambient_context into execution_context, not raw values" do
    instance = klass.send(:new, ambient_context: { company_id: 3, secret_id: 9 })
    instance._run
    ctx = instance.execution_context
    expect(ctx[:ambient_context][:company_id]).to eq(3)
    expect(ctx[:ambient_context][:secret_id]).to eq("[FILTERED]")
  end

  it "keeps ambient_context out of inputs" do
    instance = klass.send(:new, ambient_context: { company_id: 3, secret_id: 9 })
    instance._run
    expect(instance.inputs).not_to have_key(:ambient_context)
  end
end
```

(`new` is private; `send(:new, …)` is the sanctioned test entry for inspecting an instance, mirroring existing core specs.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/axn/core/ambient_context_spec.rb -e observability`
Expected: FAIL (`:ambient_context` not in execution_context).

- [ ] **Step 3: Swap the reserved key**

In `lib/axn/core/contract.rb`, change `RESERVED_EXECUTION_CONTEXT_KEYS` (line 557) from `%i[inputs outputs async current_attributes axn_stack]` to `%i[inputs outputs async ambient_context axn_stack]`.

- [ ] **Step 4: Add ambient_context to `execution_context`**

In `lib/axn/core/contract.rb`, update `execution_context` (around line 624) to append the filtered ambient hash when present:

```ruby
def execution_context
  explicit_context = @__additional_execution_context || {}
  hook_context = respond_to?(:additional_execution_context, true) ? additional_execution_context : {}
  extra_context = explicit_context.merge(hook_context).except(*RESERVED_EXECUTION_CONTEXT_KEYS)

  ctx = { inputs: inputs_for_logging, outputs: outputs_for_logging, **extra_context }
  ambient = self.class.inspection_filter.filter(ambient_context)
  ctx[:ambient_context] = ambient if ambient.present?
  ctx
end
```

Do NOT modify `inputs`/`inputs_for_logging`: `ambient_context` is never in `_declared_fields(:inbound)` (it is reserved from `expects`, and `on: :ambient_context` subfields live in `subfield_configs`, not `internal_field_configs`), so it is already absent from `inputs` and routine logging for free. The "keeps ambient_context out of inputs" test below is a regression guard for exactly this, not a signal to add a filter.

- [ ] **Step 5: Remove the raw `current_attributes` capture**

In `lib/axn/internal/exception_context.rb`, delete the block that adds `context[:current_attributes]` from the global `::Current` (the `if defined?(Current) && Current.respond_to?(:attributes)` block). The `ambient_context` key now flows through `action.execution_context` → `extra_keys` merge, so no special-casing is needed in `build`. Update the method's doc comment to reference `ambient_context` instead of `current_attributes`.

- [ ] **Step 6: Run tests to verify they pass**

Run: `bundle exec rspec spec/axn/core/ambient_context_spec.rb spec/axn/internal/exception_context_spec.rb`
Expected: PASS. Also run `bundle exec rspec spec/axn/internal` to catch any spec asserting the old `current_attributes` key (update those to `ambient_context`).

- [ ] **Step 7: Commit**

```bash
git add lib/axn/core/contract.rb lib/axn/internal/exception_context.rb spec/axn/core/ambient_context_spec.rb spec/axn/internal/exception_context_spec.rb
git commit -m "Replace raw current_attributes capture with sensitive-filtered ambient_context in exception context"
```

### Task 11: opt-in RuboCop cop `Axn/AmbientContextBypass`

**Files:**
- Create: `lib/rubocop/cop/axn/ambient_context_bypass.rb`
- Modify: `lib/axn/rubocop.rb` (register the cop), `lib/rubocop/cop/axn/README.md` (document it)
- Test: `spec_rubocop/rubocop/cop/axn/ambient_context_bypass_spec.rb`

**Interfaces:**
- Produces: a cop flagging `Current.<attr>` / `::Current.<attr>` reads, steering to `expects :x, on: :ambient_context`. It is opt-in the same way `Axn/UncheckedResult` is: axn ships no default config that enables it, so it only runs when a consumer both `require:`s `axn/rubocop` and sets `Enabled: true` in their `.rubocop.yml`.

Reference: `lib/rubocop/cop/axn/unchecked_result.rb` is the sole existing cop; it subclasses `RuboCop::Cop::Base`, is registered by a `require_relative` line in `lib/axn/rubocop.rb`, and its spec uses `require_relative` + `RuboCop::RSpec::ExpectOffense`.

- [ ] **Step 1: Write the failing test** (matches the repo's existing cop-spec style)

```ruby
# spec_rubocop/rubocop/cop/axn/ambient_context_bypass_spec.rb
# frozen_string_literal: true

require_relative "../../../spec_helper"
require_relative "../../../../lib/rubocop/cop/axn/ambient_context_bypass"

RSpec.describe RuboCop::Cop::Axn::AmbientContextBypass do
  include RuboCop::RSpec::ExpectOffense
  subject(:cop) { described_class.new }

  it "flags a direct Current attribute read" do
    expect_offense(<<~RUBY)
      do_thing(Current.company)
               ^^^^^^^^^^^^^^^ Read ambient state via `expects :company, on: :ambient_context` instead of `Current` directly.
    RUBY
  end

  it "flags a top-level ::Current read" do
    expect_offense(<<~RUBY)
      x = ::Current.user
          ^^^^^^^^^^^^^^ Read ambient state via `expects :user, on: :ambient_context` instead of `Current` directly.
    RUBY
  end

  it "does not flag unrelated receivers" do
    expect_no_offenses("x = Time.current")
  end

  it "does not flag a Current assignment (setup, not a bypass read)" do
    expect_no_offenses("Current.company = c")
  end
end
```

Note: `expect_offense` is strict about the caret span — it must exactly cover the flagged node (`Current.company` etc.). If the carets are off by a character, let the failing-test output show the exact range and adjust; do not change the cop to match sloppy carets.

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec_rubocop/rubocop/cop/axn/ambient_context_bypass_spec.rb`
Expected: FAIL (`uninitialized constant RuboCop::Cop::Axn::AmbientContextBypass`).

- [ ] **Step 3: Write the cop**

```ruby
# lib/rubocop/cop/axn/ambient_context_bypass.rb
# frozen_string_literal: true

module RuboCop
  module Cop
    module Axn
      # Flags direct reads of `Current.<attr>` and steers toward declaring the dependency
      # explicitly with `expects :<attr>, on: :ambient_context`. Opt-in (see README).
      #
      # @example
      #   # bad
      #   def call = do_thing(Current.company)
      #
      #   # good
      #   expects :company, on: :ambient_context
      #   def call = do_thing(company)
      class AmbientContextBypass < RuboCop::Cop::Base
        MSG = "Read ambient state via `expects :%<attr>s, on: :ambient_context` instead of `Current` directly."

        # Matches `Current.foo` and `::Current.foo`, capturing the attribute name.
        def_node_matcher :current_read, <<~PATTERN
          (send {(const nil? :Current) (const (cbase) :Current)} $_)
        PATTERN

        def on_send(node)
          # Reads only: skip `Current.foo(args)` and the setter `Current.foo = x`.
          return if node.arguments.any? || node.assignment_method?

          current_read(node) do |attr|
            add_offense(node, message: format(MSG, attr: attr))
          end
        end
      end
    end
  end
end
```

- [ ] **Step 4: Register the cop**

In `lib/axn/rubocop.rb`, add below the existing require:

```ruby
require_relative "../rubocop/cop/axn/ambient_context_bypass"
```

- [ ] **Step 5: Document it (opt-in, no default enable)**

Add a section to `lib/rubocop/cop/axn/README.md` describing `Axn/AmbientContextBypass`: what it flags, the good/bad example above, and that it is opt-in — enable it in `.rubocop.yml`:

```yaml
require:
  - ./lib/rubocop/cop/axn/ambient_context_bypass

Axn/AmbientContextBypass:
  Enabled: true
  Severity: warning
```

Do NOT add a default-config file that enables it — axn ships none (matching `Axn/UncheckedResult`), which is what keeps it opt-in.

- [ ] **Step 6: Run tests to verify they pass**

Run: `bundle exec rspec spec_rubocop/rubocop/cop/axn/ambient_context_bypass_spec.rb`
Expected: PASS (4 examples).

- [ ] **Step 7: Commit**

```bash
git add lib/rubocop/cop/axn/ambient_context_bypass.rb lib/axn/rubocop.rb lib/rubocop/cop/axn/README.md spec_rubocop/rubocop/cop/axn/ambient_context_bypass_spec.rb
git commit -m "Add opt-in Axn/AmbientContextBypass cop steering Current reads to ambient_context"
```

---

## Final verification

- [ ] **Run the full non-Rails suite:** `bundle exec rspec` — expect green.
- [ ] **Run the Rails suite:** `bundle exec rake spec_rails` — expect green (ambient_context provider reads real `CurrentAttributes`).
- [ ] **Run the cop suite:** `bundle exec rake spec_rubocop` — expect green.
- [ ] **RuboCop self-lint:** `bundle exec rubocop lib spec` — expect clean.
- [ ] **Update `CHANGELOG.md`** under `## Unreleased`: `axn_name`, class-level `description`, `semantic_hints`, `input_schema`/`output_schema` reflection, `Axn::Reflection`, `ambient_context` (+ **breaking:** exception reports now carry filtered `ambient_context` instead of raw `current_attributes`; `server_context` reservation replaced by `ambient_context`), extension registry primitives, opt-in `Axn/AmbientContextBypass` cop. Commit.

## Deferred (out of scope for this plan)

- **Public ambient-context composition namespace** (e.g. `Axn::AmbientContext.from_current_attributes.merge(extra)`): not built. Users who need "current attributes plus extra" write their own provider lambda for now. Add a dedicated public namespace only when a real compose-with-default need appears — building it now would reintroduce a second `AmbientContext` constant for no present benefit.
- `Factory.build` accepting `axn_name` / `description` / `semantic_hints` options.
- Any adapter code (axn-mcp adoption is PRO-2844; axn-ruby_llm is PRO-2845).

## Notes for the executor

- **Legacy `Axn::MCP::Tool` interaction (out of scope, PRO-2844):** core's new class-level `description` is extended into `Axn` and will take precedence over `::MCP::Tool`'s inherited `description` on the legacy base. Core's `description` is a plain string getter/setter, so it is behavior-compatible, but the axn-mcp adoption ticket owns final reconciliation (and switching axn-mcp to consume `Axn::Reflection::Schema`/`Values` + `extension_metadata`). Do not modify axn-mcp in this ticket.
- **`server_context`:** this ticket does not touch axn-mcp's `expects :server_context`; that migration to `ambient_context` is PRO-2844. Core only stops reserving `server_context` implicitly (it never did in core) and newly reserves `ambient_context`.
- **Reflection stays off the execution path:** `input_schema`/`output_schema`/`Values` must never be called during `.call`. They are class/result-level reflection only.
