# Tool Surface Namespace Implementation Plan (PRO-3005)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move every tool-specific method and constant off the top-level `Axn` module and behind `Axn::Tools`, move the two implementor-facing predicates to `Axn::Extensions`, and correct three stale vocabulary clusters — so the public surface frozen by `0.1.0-alpha.5` is the one axn means to publish.

**Architecture:** A new `lib/axn/tools.rb` holds the tool call surface as a thin, validating facade over `Axn::Tools::Registry` (which is renamed to speak membership rather than the old public vocabulary). `Axn::Extensions` gains the two predicates a gem legitimately asks. `Axn::Internal::ExceptionMessage` receives the hostile-safe message-degradation chain, mirroring the `Internal::ClassName` that already sits beside it in `exceptions.rb`. Everything is a rename: no behavior changes except one new predicate (`Axn.config.default_async?`).

**Tech Stack:** Ruby 3.2+ (repo pins 3.3.6), RSpec, RuboCop, ActiveSupport. Two suites: `spec/` runs without Rails, `spec_rails/dummy_app/` is the Rails dummy app.

**Spec:** `internal-docs/specs/2026-07-30-tool-surface-namespace-design.md`

## Global Constraints

- **No aliases, no delegating shims, no tombstones.** Nothing is released; move each method and constant outright. A pre-alpha rename gets no compatibility layer.
- **No behavior changes, with two named exceptions.** Every task is a rename except: Task 3 adds `Axn::Tools.adapters` (a pure delegation to `Registry.adapters`, which already returns a fresh Set) and Task 7 adds `Axn.config.default_async?`. Outside those two additions, a test needing new expectations about *behavior* means something is wrong — stop and re-read the spec.
- **CHANGELOG entries are edited in place** under the existing unreleased `## 0.1.0-alpha.5` heading. Never add a `[BREAKING]` entry for these renames — an unreleased changelog describes the release being assembled, not how it was assembled.
- **No historical comments.** Comments describe current behavior and intrinsic why. Never "used to be X", "renamed from Y", or "(PRO-3005)" as a justification. The one exception already in the tree (`lib/axn.rb:212`'s "PRO-3005 re-homes them all") is deleted by Task 3, not preserved.
- **Docs prose is not hard-wrapped.** One line per paragraph in Markdown.
- **Guard Rails constants with `defined?()`.** `spec/` must pass with no Rails loaded.
- **Full verification command set:** `bundle exec rspec`, `bundle exec rake spec_rails`, `bundle exec rubocop`. `bundle exec rake all_specs` runs all three.
- **`for` is a keyword in statement position.** `Axn::Tools.for(...)` and `def for(...)` both parse (verified), but a receiverless `for(...)` inside the module does not. Every internal call site writes the receiver.

---

## File Structure

**Created**

- `lib/axn/tools.rb` — the tool call surface: `register_adapter`, `adapters`, `for`, `versions`, `validate_contracts!`, plus the two private tool-specific helpers. The only file adapters' calls land in.
- `lib/axn/internal/exception_message.rb` — `Internal::ExceptionMessage.of(error)`: an exception's own message rendered as UTF-8 text axn owns, for a message built *about* that exception.
- `spec/axn/tools_spec.rb` — the facade's own spec (guard behavior, delegation, `adapters`).
- `spec/axn/internal/exception_message_spec.rb` — the degradation ladder, tested directly instead of only through tool-contract validation.

**Renamed**

- `lib/axn/core/tools.rb` → `lib/axn/core/tool_declaration.rb` (`Axn::Core::Tools` → `Axn::Core::ToolDeclaration`).
- `spec/axn/tools/validate_tool_contracts_spec.rb` → `spec/axn/tools/validate_contracts_spec.rb`.

**Modified**

- `lib/axn.rb` — loses five public methods and four private ones; keeps `config`, `configure`, `included`. Gains two requires.
- `lib/axn/tools/registry.rb` — `tools_for` → `members`, `versions_for` → `version_group`; `tool_root` vocabulary at its three `Configuration` call sites.
- `lib/axn/extensions.rb` — gains `owned_failure?`.
- `lib/axn/exceptions.rb` — `InvalidToolContract` → `Tools::InvalidContract`; `Reflection::UnserializableValue` → `Extensions::Serialization::UnserializableValue`.
- `lib/axn/configuration.rb` — `tool_path` → `tool_root` names and constants; gains `default_async?`.
- `lib/axn/tools/adapter_roots.rb`, `lib/axn/core/executor.rb`, `lib/axn/core.rb`, `lib/axn/rails/engine.rb`, `lib/axn/reflection/values.rb`, `lib/axn/reflection/schema.rb`, `lib/axn/extensions/serialization.rb` — call sites.
- Specs, docs, `AGENTS.md`, `AGENTS-tool-adapters.md`, `CHANGELOG.md` — per task.

---

## Task 1: `Axn::Internal::ExceptionMessage`

Extract the message-degradation chain off `Axn`. It is a general mechanism with no tool concern, and it must move as a unit: `_reported_message` is called only by `_named_invalid_tool_contract`, and `_raw_reported_message` only by `_reported_message`.

**Files:**
- Create: `lib/axn/internal/exception_message.rb`
- Create: `spec/axn/internal/exception_message_spec.rb`
- Modify: `lib/axn.rb` (delete `_reported_message` / `_raw_reported_message` / the `EXCEPTION_TO_S` constant; update the one caller and the `private_class_method` list; add the require)

**Interfaces:**
- Produces: `Axn::Internal::ExceptionMessage.of(error) -> String` (always a UTF-8 String; never raises; never dispatches an unguarded method on `error`).
- Consumes: `Axn::Reflection::PropertyNames.renderable_label`, `Axn::Internal::ClassName.of` — both already present.

**Constraint:** require this file from `lib/axn.rb` only. Do **not** require it from `lib/axn/exceptions.rb` or anything an entry point loads: it references `Axn::Reflection::PropertyNames` at call time, and `spec/axn/standalone_require_spec.rb`'s `upward_references` allowlist may only shrink.

- [ ] **Step 1: Write the failing spec**

Create `spec/axn/internal/exception_message_spec.rb`:

```ruby
# frozen_string_literal: true

RSpec.describe Axn::Internal::ExceptionMessage do
  it "returns an ordinary message unchanged" do
    expect(described_class.of(ArgumentError.new("boom"))).to eq("boom")
  end

  it "renders bytes with no UTF-8 rendering into text that can be interpolated" do
    error = ArgumentError.new("caf\xE9".dup.force_encoding(Encoding::ASCII_8BIT))

    rendered = described_class.of(error)
    expect(rendered.encoding).to eq(Encoding::UTF_8)
    expect { "prose: #{rendered}" }.not_to raise_error
  end

  it "falls back to Exception#to_s when #message returns a non-String" do
    klass = Class.new(StandardError) do
      def message = :not_a_string
    end

    expect(described_class.of(klass.new("stored"))).to eq("stored")
  end

  it "falls back to Exception#to_s when #message raises" do
    klass = Class.new(StandardError) do
      def message = raise(NotImplementedError, "hostile reader")
    end

    expect(described_class.of(klass.new("stored"))).to eq("stored")
  end

  it "falls back to the class name when even Exception#to_s cannot answer" do
    hostile = Object.new
    hostile.define_singleton_method(:to_s) { raise(NotImplementedError, "hostile message object") }
    error = Class.new(StandardError).new(hostile)

    expect(described_class.of(error)).to eq(Axn::Internal::ClassName.of(error))
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bundle exec rspec spec/axn/internal/exception_message_spec.rb`
Expected: FAIL — `uninitialized constant Axn::Internal::ExceptionMessage`.

- [ ] **Step 3: Create the module**

Create `lib/axn/internal/exception_message.rb`. Move the two docstrings currently above `Axn._reported_message` and `Axn._raw_reported_message` in `lib/axn.rb` verbatim, adjusting only the method names they mention:

```ruby
# frozen_string_literal: true

module Axn
  module Internal
    # An exception's own message, for a message being built ABOUT it, as a UTF-8 String this module owns.
    #
    # RENDERED rather than returned as it came, because what an exception's message HOLDS is foreign too, not
    # just the code that answers it: a String whose bytes are not UTF-8-compatible cannot be joined to axn's own
    # UTF-8 prose at all (Encoding::CompatibilityError from the interpolation), and one merely in another
    # encoding, or holding invalid bytes, silently poisons the message it lands in. Neither needs an override to
    # reach here — the STORED message of an ordinary ArgumentError is a String the raiser chose.
    # `renderable_label` is the one path axn renders foreign text with (a name in a message, a Hash key in a log
    # line, this): an ASCII message is byte-identical, a legitimate multibyte one reads as its text, and bytes
    # with no UTF-8 rendering come back escaped rather than taking the report with them. Rendering dispatches
    # nothing here — every branch below yields a genuine String, and a String is rendered through bound String
    # methods.
    #
    # The sibling of `Internal::ClassName`: both answer a question about a hostile object while a failure is
    # being reported, and neither runs code that object supplies.
    module ExceptionMessage
      # `Exception`'s own implementation, for a reporting path that must not run an exception's override of it.
      # `to_s` renders the message object the exception was raised with.
      EXCEPTION_TO_S = ::Exception.instance_method(:to_s)
      private_constant :EXCEPTION_TO_S

      def self.of(error) = Axn::Reflection::PropertyNames.renderable_label(_raw(error))

      # The message bytes, before rendering.
      #
      # Dispatched deliberately — an exception that derives its message from its state
      # (`Extensions::Serialization::UnserializableValue`) has no other way to be reported richly — but behind a
      # guard, because that is caller code in an error path, and the guard has to cover an ordinary class too:
      # `Exception#to_s` renders the message OBJECT the exception was raised with (`rb_String`), so a plain
      # ArgumentError carrying a value whose `to_s` raises raises here.
      #
      # The result is type-tested rather than returned as-is, because an owned `#message` may return anything,
      # and rendering a non-String dispatches its `to_s` — outside the guard, which is the escape this exists to
      # prevent. (A String SUBCLASS is safe: it is type-tested and rendered through bound String methods, and the
      # renderer hands back a plain String either way.) `Exception#to_s` is the non-dispatching second choice,
      # and the class is what is left when even that will not answer.
      def self._raw(error)
        case (reported = error.message)
        when ::String then reported
        else EXCEPTION_TO_S.bind_call(error)
        end
      rescue ::Exception # rubocop:disable Lint/RescueException
        begin
          EXCEPTION_TO_S.bind_call(error)
        rescue ::Exception # rubocop:disable Lint/RescueException
          Axn::Internal::ClassName.of(error)
        end
      end

      private_class_method :_raw
    end
  end
end
```

Note: the `UnserializableValue` mention in that comment is written in its **post-Task-6** namespace deliberately, so no follow-up edit is needed.

- [ ] **Step 4: Wire the require and delete the old methods**

In `lib/axn.rb`, add to the "Internal utilities" require block, after `require "axn/internal/exception_context"`:

```ruby
require "axn/internal/exception_message"
```

Delete `def self._reported_message`, `def self._raw_reported_message`, and both of their docstrings. Delete the `EXCEPTION_TO_S` constant and drop it from the `private_constant` line, leaving:

```ruby
  # `Exception`'s own implementation, for a reporting path that must not run an exception's override of it
  # (see `_named_invalid_tool_contract`). `exception` clones and sets a message without running an initializer.
  EXCEPTION_EXCEPTION = ::Exception.instance_method(:exception)
  private_constant :EXCEPTION_EXCEPTION
```

In `_named_invalid_tool_contract`, change the `reason` line to:

```ruby
    reason = Axn::Internal::ExceptionMessage.of(error)
```

Update the `private_class_method` line to drop the two removed names:

```ruby
  private_class_method :_registered_tool_adapter!, :_named_invalid_tool_contract
```

- [ ] **Step 5: Run the new spec and the tool-contract suite**

Run: `bundle exec rspec spec/axn/internal/exception_message_spec.rb spec/axn/tools/validate_tool_contracts_spec.rb`
Expected: PASS. The existing degraded-reporting examples (`validate_tool_contracts_spec.rb:230-410`) exercise the same ladder through its new home, unchanged.

- [ ] **Step 6: Run the full non-Rails suite and RuboCop**

Run: `bundle exec rspec && bundle exec rubocop`
Expected: PASS both.

- [ ] **Step 7: Commit**

```bash
git add lib/axn.rb lib/axn/internal/exception_message.rb spec/axn/internal/exception_message_spec.rb
git commit -m "PRO-3005: Internal::ExceptionMessage owns the hostile-safe message read"
```

---

## Task 2: `Axn::Tools::InvalidContract`

Rename the public exception class into the namespace that owns the surface raising it. It stays *defined* in `exceptions.rb` with every other exception class, namespaced in place, exactly as `Reflection::UnserializableValue` already is.

**Files:**
- Modify: `lib/axn/exceptions.rb:168` (the class and its docstring)
- Modify: `lib/axn.rb` (the one construction site and two comment mentions)
- Modify: `spec/axn/tools/validate_tool_contracts_spec.rb` (9 references)

**Interfaces:**
- Produces: `Axn::Tools::InvalidContract.new(tool:, reason:, original_class:)` — the same keyword signature, under a new constant path.

- [ ] **Step 1: Update the spec first**

In `spec/axn/tools/validate_tool_contracts_spec.rb`, replace every `Axn::InvalidToolContract` with `Axn::Tools::InvalidContract`:

```bash
sed -i '' 's/Axn::InvalidToolContract/Axn::Tools::InvalidContract/g' spec/axn/tools/validate_tool_contracts_spec.rb
```

Then read line 343 and line 361's descriptions and fix the prose so it names the new class (`"renders them on the InvalidContract branch too"`, `"renders its inputs when Axn::Tools::InvalidContract is built directly"`).

- [ ] **Step 2: Run it to verify it fails**

Run: `bundle exec rspec spec/axn/tools/validate_tool_contracts_spec.rb`
Expected: FAIL — `uninitialized constant Axn::Tools::InvalidContract`.

- [ ] **Step 3: Re-nest the class**

In `lib/axn/exceptions.rb`, wrap the class (currently `class InvalidToolContract < ContractViolation` at line 168, together with its docstring) in a `module Tools`, rename it, and update the docstring's mention of the validator:

```ruby
  module Tools
    # <existing docstring, verbatim except:>
    #   * `Axn.validate_tool_contracts!` becomes `Axn::Tools.validate_contracts!`
    class InvalidContract < ContractViolation
      def initialize(tool:, reason:, original_class:)
        # ... body unchanged ...
      end
    end
  end
```

Keep the body byte-identical — including the `"(raised as #{self.class}, …)"` interpolation, which now renders the new constant path on its own.

- [ ] **Step 4: Update the construction site**

In `lib/axn.rb`'s `_named_invalid_tool_contract`:

```ruby
      return Tools::InvalidContract.new(tool:, reason:, original_class: Axn::Internal::ClassName.of(error))
```

Also update the two comment mentions of `Axn::InvalidToolContract` (in `validate_tool_contracts!`'s rescue comment and in `_named_invalid_tool_contract`'s docstring) to `Axn::Tools::InvalidContract`.

- [ ] **Step 5: Run the suite**

Run: `bundle exec rspec spec/axn/tools/ && bundle exec rspec`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/axn/exceptions.rb lib/axn.rb spec/axn/tools/validate_tool_contracts_spec.rb
git commit -m "PRO-3005: Axn::InvalidToolContract becomes Axn::Tools::InvalidContract"
```

---

## Task 3: The `Axn::Tools` facade — enumeration and registration

Create the facade and move the three enumeration/registration methods plus the adapter guard onto it. Rename `Registry`'s two public methods in the same task, because the facade *is* that delegation edge — writing `Registry.tools_for` and renaming it a task later would be churn a reviewer has to read twice.

**Files:**
- Create: `lib/axn/tools.rb`
- Create: `spec/axn/tools_spec.rb`
- Modify: `lib/axn.rb` (delete `register_tool_adapter`, `tools_for`, `versions_for`, `_registered_tool_adapter!`; add the require)
- Modify: `lib/axn/tools/registry.rb` (`tools_for` → `members`, `versions_for` → `version_group`, and the comments naming them)
- Modify: `spec/axn/tools/registry_spec.rb`, `spec/support/tool_adapter_helpers.rb`, `spec_rails/dummy_app/spec/axn/tools_eager_load_spec.rb`

**Interfaces:**
- Consumes: `Axn::Tools::Registry.register_adapter`, `.adapters` (unchanged).
- Produces:
  - `Axn::Tools.register_adapter(key, config_source = nil) -> void`
  - `Axn::Tools.adapters -> Set<Symbol>`
  - `Axn::Tools.for(adapter, all_versions: false) -> Array<Class>`
  - `Axn::Tools.versions(adapter, tool_name) -> Axn::Tools::VersionGroup | nil`
  - `Axn::Tools::Registry.members(adapter, all_versions: false) -> Array<Class>`
  - `Axn::Tools::Registry.version_group(adapter, tool_name) -> VersionGroup | nil`
  - private `Axn::Tools._registered_adapter!(adapter) -> Symbol` (raises `ArgumentError` for an unregistered key)

- [ ] **Step 1: Write the failing facade spec**

Create `spec/axn/tools_spec.rb`:

```ruby
# frozen_string_literal: true

require "support/tool_adapter_helpers"

RSpec.describe Axn::Tools do
  before { Axn::Tools::Registry.reset_adapters! }
  after { Axn::Tools::Registry.reset_adapters! }

  describe ".register_adapter / .adapters" do
    it "registers keys and reports them" do
      described_class.register_adapter(:mcp)
      described_class.register_adapter(:ruby_llm)

      expect(described_class.adapters).to contain_exactly(:mcp, :ruby_llm)
    end

    it "keeps an already-supplied config source on a re-registration with no source" do
      source = register_tool_adapter_with_roots(:mcp, roots: ["agent_tools"])
      described_class.register_adapter(:mcp)

      expect(Axn::Tools::Registry.adapter_config_source(:mcp)).to eq(source)
    end
  end

  describe ".for" do
    it "returns the adapter's member classes" do
      described_class.register_adapter(:mcp)
      tool = stub_const("ToolsFacadeSpec::Member", Class.new do
        include Axn
        tool :mcp
      end)

      expect(described_class.for(:mcp)).to include(tool)
    end

    it "accepts a String adapter key" do
      described_class.register_adapter(:mcp)

      expect { described_class.for("mcp") }.not_to raise_error
    end

    it "raises for an unregistered adapter, naming what is registered" do
      described_class.register_adapter(:mcp)

      expect { described_class.for(:nope) }
        .to raise_error(ArgumentError, /:nope is not a registered tool adapter \(registered: \[:mcp\]\)/)
    end

    it "forwards all_versions: to the registry" do
      described_class.register_adapter(:mcp)
      allow(Axn::Tools::Registry).to receive(:members).and_return([])

      described_class.for(:mcp, all_versions: true)

      expect(Axn::Tools::Registry).to have_received(:members).with(:mcp, all_versions: true)
    end
  end

  describe ".versions" do
    it "returns the version group for a tool_name" do
      described_class.register_adapter(:mcp)
      solo = stub_const("ToolsFacadeSpec::Solo", Class.new do
        include Axn
        tool :mcp
      end)

      expect(described_class.versions(:mcp, solo.tool_name(:mcp)).all).to eq([solo])
    end

    it "returns nil for an unknown tool_name" do
      described_class.register_adapter(:mcp)

      expect(described_class.versions(:mcp, "nope")).to be_nil
    end

    it "raises for an unregistered adapter" do
      expect { described_class.versions(:nope, "x") }.to raise_error(ArgumentError, /not a registered tool adapter/)
    end
  end

  it "keeps the adapter guard private" do
    expect(described_class).not_to respond_to(:_registered_adapter!)
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bundle exec rspec spec/axn/tools_spec.rb`
Expected: FAIL — `undefined method 'register_adapter' for Axn::Tools`.

- [ ] **Step 3: Create the facade**

Create `lib/axn/tools.rb`:

```ruby
# frozen_string_literal: true

module Axn
  # The tool surface: registering an adapter, enumerating its tools, and validating their contracts.
  #
  # This module is what an adapter gem names. `Registry`, `Invoker`, `AdapterRoots` and `VersionGroup`
  # beneath it are implementation constants an adapter reaches through these methods rather than
  # calling directly — the registry in particular is free to change how membership is stored.
  #
  # `for` is a keyword in statement position, so every call inside axn writes the receiver
  # (`Axn::Tools.for(...)`); a receiverless `for(...)` would parse as a loop.
  module Tools
    class << self
      # Registers an adapter key, optionally with the config source the registry reads `tool_roots`
      # from. Idempotent, and a source-less re-registration never wipes a source already supplied
      # (see Registry#register_adapter).
      def register_adapter(key, config_source = nil)
        Registry.register_adapter(key, config_source)
      end

      # The registered adapter keys. The read-companion to `register_adapter`, and the set every
      # method here validates against.
      def adapters = Registry.adapters

      # An adapter's tools: the latest version per `tool_name` by default, sorted by `tool_name`;
      # every version (by name, then ascending version) with `all_versions: true`.
      def for(adapter, all_versions: false)
        Registry.members(_registered_adapter!(adapter), all_versions:)
      end

      # One logical tool's version group under `adapter` (`.all` ascending, `.latest`), or nil when
      # nothing matches — for an adapter resolving a single name rather than walking the enumeration.
      def versions(adapter, tool_name)
        Registry.version_group(_registered_adapter!(adapter), tool_name)
      end

      private

      # Symbolizes and vets the adapter key, so a typo names the mistake instead of quietly
      # enumerating nothing.
      def _registered_adapter!(adapter)
        adapter = adapter.to_sym
        unless Registry.adapters.include?(adapter)
          raise ArgumentError, "#{adapter.inspect} is not a registered tool adapter (registered: #{Registry.adapters.to_a.inspect})"
        end

        adapter
      end
    end
  end
end
```

- [ ] **Step 4: Rename the registry's two public methods**

In `lib/axn/tools/registry.rb`:

- `def tools_for(adapter, all_versions: false)` → `def members(adapter, all_versions: false)`.
- `def versions_for(adapter, tool_name)` → `def version_group(adapter, tool_name)`.
- Inside `version_group`, update the comment that says "so this lookup never disagrees with tools_for … exactly as it would in tools_for" to name `members`.
- In `tool_classes`' docstring, "Separate from `tools_for`" → "Separate from `members`".
- In `register_class`' docstring, "never enumerated twice by tools_for" → "by `members`".
- In `all_classes`' docstring, "tools_for runs at adapter setup" → "`members` runs at adapter setup".

- [ ] **Step 5: Strip the moved methods off `Axn`**

In `lib/axn.rb`, delete `self.register_tool_adapter`, `self.tools_for`, `self.versions_for`, and `self._registered_tool_adapter!`. Update the `private_class_method` line, deleting the comment above it (which describes a four-method arrangement that no longer exists):

```ruby
  private_class_method :_named_invalid_tool_contract
```

Add the require after the existing `axn/tools/*` requires:

```ruby
require "axn/tools/invoker"
require "axn/tools"
```

- [ ] **Step 6: Migrate the in-repo callers**

```bash
sed -i '' 's/Axn\.register_tool_adapter(/Axn::Tools.register_adapter(/g' \
  spec/support/tool_adapter_helpers.rb \
  spec/axn/tools/registry_spec.rb \
  spec/axn/tools/validate_tool_contracts_spec.rb \
  spec_rails/dummy_app/spec/axn/tools_eager_load_spec.rb
sed -i '' -e 's/Axn\.tools_for(/Axn::Tools.for(/g' -e 's/Axn\.versions_for(/Axn::Tools.versions(/g' \
  spec/axn/tools/registry_spec.rb \
  spec_rails/dummy_app/spec/axn/tools_eager_load_spec.rb
```

Then grep the same files for `described_class.tools_for` / `described_class.versions_for` (they describe `Axn::Tools::Registry`) and rename those to `members` / `version_group`, including the `describe ".tools_for …"` block titles:

```bash
grep -rn "tools_for\|versions_for\|register_tool_adapter" spec/ spec_rails/ lib/
```

Expected after this step: no hits outside `CHANGELOG.md` and `docs/` (Task 10 handles prose).

- [ ] **Step 7: Run both suites and RuboCop**

Run: `bundle exec rspec && bundle exec rake spec_rails && bundle exec rubocop`
Expected: PASS all three.

- [ ] **Step 8: Commit**

```bash
git add lib/axn.rb lib/axn/tools.rb lib/axn/tools/registry.rb spec/axn/tools_spec.rb spec/axn/tools/registry_spec.rb spec/support/tool_adapter_helpers.rb spec/axn/tools/validate_tool_contracts_spec.rb spec_rails/dummy_app/spec/axn/tools_eager_load_spec.rb
git commit -m "PRO-3005: Axn::Tools.for/.versions/.register_adapter/.adapters replace the Axn. tool methods"
```

---

## Task 4: `Axn::Tools.validate_contracts!`

Move the contract validator and its private naming helper onto the facade, and update the Rails engine's two hooks.

**Files:**
- Modify: `lib/axn/tools.rb` (gains `validate_contracts!`, `_named_invalid_contract`, the `EXCEPTION_EXCEPTION` constant)
- Modify: `lib/axn.rb` (loses all three; the module is left with `owns_failure_exception?` and `included`)
- Modify: `lib/axn/rails/engine.rb` (both hooks)
- Rename: `spec/axn/tools/validate_tool_contracts_spec.rb` → `spec/axn/tools/validate_contracts_spec.rb`
- Modify: `spec_rails/dummy_app/spec/axn/tool_contract_validation_spec.rb`

**Interfaces:**
- Consumes: `Axn::Tools::Registry.tool_classes`, `Axn::Reflection::PropertyNames.validate_inbound!/validate_outbound!/renderable_module_name`, `Axn::Internal::NativeMethods.native_exception_reporting?`, `Axn::Internal::ClassName.of`, `Axn::Internal::ExceptionMessage.of` (Task 1), `Axn::Tools::InvalidContract` (Task 2).
- Produces: `Axn::Tools.validate_contracts! -> nil` (raises on the first invalid tool contract).

- [ ] **Step 1: Rename the spec file and its call sites**

```bash
git mv spec/axn/tools/validate_tool_contracts_spec.rb spec/axn/tools/validate_contracts_spec.rb
sed -i '' 's/Axn\.validate_tool_contracts!/Axn::Tools.validate_contracts!/g' \
  spec/axn/tools/validate_contracts_spec.rb \
  spec_rails/dummy_app/spec/axn/tool_contract_validation_spec.rb
```

Update the top-level description on line 4 of the renamed file to `RSpec.describe "Axn::Tools.validate_contracts!" do`, and read the file's comments for prose mentions of the old name (there is one near the end explaining that `validate_tool_contracts!` would validate nothing without a registered adapter).

- [ ] **Step 2: Run it to verify it fails**

Run: `bundle exec rspec spec/axn/tools/validate_contracts_spec.rb`
Expected: FAIL — `undefined method 'validate_contracts!' for Axn::Tools`.

- [ ] **Step 3: Move the two methods and the constant**

Cut `EXCEPTION_EXCEPTION` (and its `private_constant` line and docstring), `self.validate_tool_contracts!`, and `self._named_invalid_tool_contract` out of `lib/axn.rb`, and paste them into `lib/axn/tools.rb` inside `class << self`, with these edits and no others:

- `validate_tool_contracts!` → `validate_contracts!`; in its docstring, "Under Rails this runs automatically" keeps its text, and the sentence naming the method itself now reads `Axn::Tools.validate_contracts!`.
- `_named_invalid_tool_contract` → `_named_invalid_contract`; every comment cross-reference to it updates to the new name.
- `Axn::Tools::Registry.tool_classes` → `Registry.tool_classes`.
- `Tools::InvalidContract.new(...)` → `InvalidContract.new(...)` (the enclosing namespace now resolves it).
- `_named_invalid_contract` joins the `private` section below `_registered_adapter!`.

The `EXCEPTION_EXCEPTION` constant is declared at the top of `module Tools`, above `class << self`:

```ruby
  module Tools
    # `Exception`'s own implementation, for a reporting path that must not run an exception's override of it
    # (see `_named_invalid_contract`). `exception` clones and sets a message without running an initializer.
    EXCEPTION_EXCEPTION = ::Exception.instance_method(:exception)
    private_constant :EXCEPTION_EXCEPTION
```

- [ ] **Step 4: Update the Rails engine**

In `lib/axn/rails/engine.rb`, replace both hook bodies:

```ruby
        config.after_initialize { Axn::Tools.validate_contracts! }
        config.to_prepare { Axn::Tools.validate_contracts! }
```

The comment block above them keeps its reasoning; update only its reference to `Axn::Tools::Registry#ensure_loaded!`, which is already correct, and leave the rest verbatim.

- [ ] **Step 5: Run both suites**

Run: `bundle exec rspec spec/axn/tools/validate_contracts_spec.rb && bundle exec rspec && bundle exec rake spec_rails`
Expected: PASS. The Rails run is the one that proves the engine hooks still fire.

- [ ] **Step 6: Verify `Axn` is down to its intended surface**

Run:

```bash
ruby -Ilib -e 'require "axn"; puts Axn.singleton_methods(false).sort.inspect'
```

Expected: `[:config, :configure, :included, :owns_failure_exception?]`. `included` is a public singleton method (Ruby's hook, not privatized here) and `config`/`configure` are defined directly on the singleton, so both appear — measured on `main` before this work, where the same call returns all eight names. `owns_failure_exception?` leaves in Task 5.

- [ ] **Step 7: Commit**

```bash
git add lib/axn.rb lib/axn/tools.rb lib/axn/rails/engine.rb spec/axn/tools/validate_contracts_spec.rb spec_rails/dummy_app/spec/axn/tool_contract_validation_spec.rb
git commit -m "PRO-3005: Axn::Tools.validate_contracts! owns tool-contract validation"
```

---

## Task 5: `Axn::Extensions.owned_failure?`

**Files:**
- Modify: `lib/axn/extensions.rb` (gains the predicate)
- Modify: `lib/axn.rb` (loses `owns_failure_exception?`; `module Axn` is now `included` only)
- Modify: `lib/axn/core/executor.rb:390`
- Modify: `spec/axn/extensions_spec.rb` (new examples)

**Interfaces:**
- Produces: `Axn::Extensions.owned_failure?(exception) -> Boolean`.

- [ ] **Step 1: Write the failing spec**

Append to `spec/axn/extensions_spec.rb`, inside the top-level `RSpec.describe Axn::Extensions` block:

```ruby
  describe ".owned_failure?" do
    it "is true for an Axn::Failure" do
      expect(described_class.owned_failure?(Axn::Failure.new("nope"))).to be(true)
    end

    it "is true for a user-facing validation error" do
      action = build_axn { expects :name }
      result = action.call

      expect(result.exception).to be_a(Axn::InboundValidationError)
      expect(described_class.owned_failure?(result.exception)).to be(true)
    end

    it "is false for a foreign exception" do
      expect(described_class.owned_failure?(ArgumentError.new("boom"))).to be(false)
    end
  end
```

`build_axn` comes from `axn/testing/spec_helpers`, already loaded by `spec_helper`.

- [ ] **Step 2: Run it to verify it fails**

Run: `bundle exec rspec spec/axn/extensions_spec.rb -e "owned_failure?"`
Expected: FAIL — `undefined method 'owned_failure?'`.

- [ ] **Step 3: Add the predicate**

In `lib/axn/extensions.rb`, inside `class << self`, directly below `swallowable?` (its nearest sibling in kind):

```ruby
      # True when axn owns this exception's #message — an Axn::Failure, or a user-facing validation error —
      # so the message is meant for the client and may carry a resolved presentation. A FOREIGN exception
      # reclassified via `fails_on` is not owned: it travels axn's failure path, but its #message is a
      # technical cause, and an adapter surfacing it would leak internals to a caller.
      def owned_failure?(exception)
        exception.is_a?(Axn::Failure) || Axn::ValidationError.user_facing?(exception)
      end
```

- [ ] **Step 4: Delete the old method and update its caller**

Delete `self.owns_failure_exception?` and its docstring from `lib/axn.rb`. In `lib/axn/core/executor.rb`, line 390:

```ruby
        return unless resolved && Axn::Extensions.owned_failure?(exception) && exception.respond_to?(:__present_as)
```

- [ ] **Step 5: Run the suites**

Run: `bundle exec rspec && bundle exec rake spec_rails && bundle exec rubocop`
Expected: PASS all three.

- [ ] **Step 6: Verify the top-level surface is final**

Run:

```bash
ruby -Ilib -e 'require "axn"; puts Axn.singleton_methods(false).sort.inspect'
ruby -Ilib -e 'require "axn"; puts Axn.singleton_class.private_instance_methods(false).sort.inspect'
```

Expected: `[:config, :configure, :included]`, and an empty private list — every private helper has moved.

- [ ] **Step 7: Commit**

```bash
git add lib/axn.rb lib/axn/extensions.rb lib/axn/core/executor.rb spec/axn/extensions_spec.rb
git commit -m "PRO-3005: owns_failure_exception? becomes Axn::Extensions.owned_failure?"
```

---

## Task 6: `Axn::Extensions::Serialization::UnserializableValue`

Move the one exception class downstream gems actually name into the only namespace a gem should name.

**Files:**
- Modify: `lib/axn/exceptions.rb` (re-nest the class; the `module Reflection` wrapper there becomes empty and is deleted)
- Modify: `lib/axn/reflection/values.rb` (13 references), `lib/axn/reflection/schema.rb` (1), `lib/axn/extensions/serialization.rb` (1 comment), `lib/axn/internal/exception_message.rb` (already written in the new form by Task 1 — verify only)
- Modify: `spec/axn/reflection/values_spec.rb` (61), `spec/axn/extensions/serialization_spec.rb` (1), `spec_rails/dummy_app/spec/axn/reflection/values_spec.rb` (3)

**Interfaces:**
- Produces: `Axn::Extensions::Serialization::UnserializableValue.new(path:, value:, reason: nil)` — same signature, new constant path.

- [ ] **Step 1: Update the specs first**

```bash
sed -i '' 's/Axn::Reflection::UnserializableValue/Axn::Extensions::Serialization::UnserializableValue/g' \
  spec/axn/reflection/values_spec.rb \
  spec/axn/extensions/serialization_spec.rb \
  spec_rails/dummy_app/spec/axn/reflection/values_spec.rb
grep -rn "UnserializableValue" spec/ spec_rails/ | grep -v "Extensions::Serialization::UnserializableValue"
```

The grep catches bare `UnserializableValue` references written without a namespace (inside `describe Axn::Reflection::Values` blocks, a bare constant resolves lexically) — qualify each one fully.

- [ ] **Step 2: Run to verify it fails**

Run: `bundle exec rspec spec/axn/reflection/values_spec.rb`
Expected: FAIL — `uninitialized constant Axn::Extensions::Serialization::UnserializableValue`.

- [ ] **Step 3: Re-nest the class**

In `lib/axn/exceptions.rb`, change the wrapper around the class (currently `module Reflection` at line 227) to the nested pair, keeping the class body and docstring byte-identical:

```ruby
  module Extensions
    module Serialization
      # <existing docstring, verbatim>
      class UnserializableValue < ArgumentError
        # ... body unchanged ...
      end
    end
  end
```

Opening `Extensions::Serialization` here is load-order safe: it only creates the modules, and `lib/axn/extensions/serialization.rb` reopens the same namespace later to define `render`.

- [ ] **Step 4: Update the raising sites**

```bash
sed -i '' 's/Axn::Reflection::UnserializableValue/Axn::Extensions::Serialization::UnserializableValue/g' \
  lib/axn/reflection/values.rb lib/axn/reflection/schema.rb lib/axn/extensions/serialization.rb
grep -rn "UnserializableValue" lib/ | grep -v "Extensions::Serialization::UnserializableValue"
```

The grep catches comment-only mentions of the bare name (`values.rb:9`, `values.rb:184`) — reword those to name the class in its new home. `values.rb` already requires `axn/exceptions`, so nothing changes about its requires.

- [ ] **Step 5: Run every suite, including the standalone-require guard**

Run: `bundle exec rspec spec/axn/standalone_require_spec.rb && bundle exec rspec && bundle exec rake spec_rails`
Expected: PASS. `standalone_require_spec` is the one that proves an adapter loading `axn/extensions/serialization` or `axn/reflection/values` alone still resolves the exception.

- [ ] **Step 6: Commit**

```bash
git add lib/axn/exceptions.rb lib/axn/reflection/values.rb lib/axn/reflection/schema.rb lib/axn/extensions/serialization.rb spec/axn/reflection/values_spec.rb spec/axn/extensions/serialization_spec.rb spec_rails/dummy_app/spec/axn/reflection/values_spec.rb
git commit -m "PRO-3005: UnserializableValue moves to Axn::Extensions::Serialization"
```

---

## Task 7: `Axn.config.default_async?`

The one new method in this PR. axn-webhooks reads `_default_async_adapter` three times, always as `!!…` — so publish the question instead of the internals.

**Files:**
- Modify: `lib/axn/configuration.rb` (add the predicate beside the `_default_async_*` trio)
- Modify: `spec/axn/core/configuration_spec.rb` (new examples in the existing `set_default_async` describe block)

**Interfaces:**
- Produces: `Axn.config.default_async? -> Boolean`.

- [ ] **Step 1: Write the failing spec**

In `spec/axn/core/configuration_spec.rb`, inside the existing `describe "set_default_async …"` block (the one whose "defaults to disabled" example is at line 150), append:

```ruby
    describe "#default_async?" do
      it "is false by default" do
        expect(config.default_async?).to be(false)
      end

      it "is false when only config or a block is set" do
        config.set_default_async(false, queue: "low")

        expect(config.default_async?).to be(false)
      end

      it "is true once an adapter is set" do
        allow(config).to receive(:_ensure_async_exception_reporting_registered_for_adapter)
        allow(config).to receive(:_apply_async_to_enqueue_all_orchestrator)

        config.set_default_async(:sidekiq, queue: "default")

        expect(config.default_async?).to be(true)
      end
    end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bundle exec rspec spec/axn/core/configuration_spec.rb -e "default_async?"`
Expected: FAIL — `undefined method 'default_async?'`.

- [ ] **Step 3: Add the predicate**

In `lib/axn/configuration.rb`, directly above the `_default_async_*` trio at line 149:

```ruby
    # Whether a default async adapter is configured — the only thing a gem needs to know about the
    # `_default_async_*` trio below, which stays underscored because core reads all three of them
    # across files. `present?` rather than `!!`, matching how `Axn::Async` itself tests the adapter.
    def default_async? = _default_async_adapter.present?
```

Then extend the comment above the `private :_enqueue_all_async_*` line (currently at line 176) so it explains the split rather than only the trio's publicness:

```ruby
    # Read only by `_apply_async_to_enqueue_all_orchestrator` below. The `_default_async_*` trio above
    # is public for the opposite reason: `Axn.async` and the Sidekiq adapter read it off `Axn.config`
    # across files, so it cannot be private. A gem asking only "is async on?" uses `default_async?`.
```

- [ ] **Step 4: Run the suite and RuboCop**

Run: `bundle exec rspec spec/axn/core/configuration_spec.rb && bundle exec rspec && bundle exec rubocop`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/axn/configuration.rb spec/axn/core/configuration_spec.rb
git commit -m "PRO-3005: publish Axn.config.default_async? so no gem reads the underscored trio"
```

---

## Task 8: `tool_path` → `tool_root` in `Axn::Configuration`

The `tool_paths` setting was removed by PRO-2948; its name survives in the guard that now validates `tool_roots` entries, in two public constants, and in comments describing a setting a reader cannot find.

**Files:**
- Modify: `lib/axn/configuration.rb` (2 constants, 3 methods, their comments)
- Modify: `lib/axn/tools/adapter_roots.rb:24`, `lib/axn/tools/registry.rb` (3 call sites plus a warn message that names a constant)
- Modify: `spec/axn/core/configuration_spec.rb` (two `describe` blocks and their examples)

**Interfaces:**
- Produces: `Axn::Configuration.broad_tool_root?(entry) -> Boolean`, `Axn::Configuration.normalize_tool_root(entry) -> String`, `Axn::Configuration::TOOL_ROOTS_BLOCKLIST`, `Axn::Configuration::BROAD_TOOL_ROOT_LEAVES`.

- [ ] **Step 1: Rename in the spec first**

```bash
sed -i '' -e 's/normalize_tool_path/normalize_tool_root/g' -e 's/broad_tool_path?/broad_tool_root?/g' \
  spec/axn/core/configuration_spec.rb
```

Also update the two `describe` titles (`".normalize_tool_root"`, `".broad_tool_root?"`), and grep the file for prose mentioning `tool_paths`.

- [ ] **Step 2: Run it to verify it fails**

Run: `bundle exec rspec spec/axn/core/configuration_spec.rb`
Expected: FAIL — `undefined method 'normalize_tool_root' for Axn::Configuration`.

- [ ] **Step 3: Rename in `lib/`**

```bash
sed -i '' \
  -e 's/normalize_tool_path/normalize_tool_root/g' \
  -e 's/broad_tool_path?/broad_tool_root?/g' \
  -e 's/_broad_tool_path_reason/_broad_tool_root_reason/g' \
  -e 's/TOOL_PATHS_BLOCKLIST/TOOL_ROOTS_BLOCKLIST/g' \
  -e 's/BROAD_TOOL_PATH_LEAVES/BROAD_TOOL_ROOT_LEAVES/g' \
  lib/axn/configuration.rb lib/axn/tools/adapter_roots.rb lib/axn/tools/registry.rb
grep -rn "tool_path\|TOOL_PATH" lib/
```

- [ ] **Step 4: Fix the comments the rename cannot reach**

The `sed` leaves prose that still describes a removed setting. Rewrite each to name what the code actually validates — an adapter's `tool_roots` entry:

- `lib/axn/configuration.rb:59` — "Root-ish tool_path entries that must never be accepted" → "Root-ish `tool_roots` entries …", and its "(see .normalize_tool_root)" reference is already correct after the sed.
- `lib/axn/configuration.rb:67` — "Leaf (final path segment) names that make a tool_paths entry broad" → "… that make a `tool_roots` entry broad".
- `lib/axn/configuration.rb:76` — "is this tool_paths entry too broad to allow" → "is this `tool_roots` entry too broad to allow".
- `lib/axn/configuration.rb:84` — "Normalizes a tool_paths entry for BOTH" → "Normalizes a `tool_roots` entry for BOTH".
- `lib/axn/configuration.rb:85` — the `Tools::Registry#_resolve_tool_dir` cross-reference stays as-is (that method keeps its name).

Then confirm the registry's warn message reads `(see Axn::Configuration::BROAD_TOOL_ROOT_LEAVES)`.

- [ ] **Step 5: Run everything**

Run: `bundle exec rspec && bundle exec rake spec_rails && bundle exec rubocop`
Expected: PASS all three.

- [ ] **Step 6: Commit**

```bash
git add lib/axn/configuration.rb lib/axn/tools/adapter_roots.rb lib/axn/tools/registry.rb spec/axn/core/configuration_spec.rb
git commit -m "PRO-3005: the broad-path guard speaks tool_roots, the setting it actually validates"
```

---

## Task 9: `Axn::Core::Tools` → `Axn::Core::ToolDeclaration`

The namespace policy makes `Tools::X` the tool surface, so a second `Tools` holding the author-facing DSL contradicts it.

**Files:**
- Rename: `lib/axn/core/tools.rb` → `lib/axn/core/tool_declaration.rb`
- Modify: `lib/axn/core.rb:70` (the include), `lib/axn.rb` if it requires the file by path
- Modify: any comment in `lib/` naming `Core::Tools`

**Interfaces:**
- Produces: `Axn::Core::ToolDeclaration` — same `self.included(base)` contract, included by `Axn::Core.included`.

- [ ] **Step 1: Move the file and rename the module**

```bash
git mv lib/axn/core/tools.rb lib/axn/core/tool_declaration.rb
```

In the moved file, rename `module Tools` to `module ToolDeclaration` and update its docstring's first line so it describes the module rather than repeating the old name:

```ruby
    # Tool membership (the `tool` DSL) and the canonical, provider-safe `tool_name`
    # derivation. Every Axn is a potential tool; the registry (Axn::Tools::Registry)
    # decides which classes an adapter actually exposes, reading the storage declared here.
    module ToolDeclaration
```

- [ ] **Step 2: Update the include and any require**

In `lib/axn/core.rb:70`:

```ruby
        include Core::ToolDeclaration
```

Then find how the file is loaded and fix the path:

```bash
grep -rn "core/tools\|Core::Tools" lib/ spec/ spec_rails/
```

Update every hit. If `lib/axn/core.rb` requires `axn/core/tools`, it becomes `axn/core/tool_declaration`.

- [ ] **Step 3: Run everything**

Run: `bundle exec rspec && bundle exec rake spec_rails && bundle exec rubocop`
Expected: PASS. `spec/axn/core/tool_dsl_spec.rb` and `tool_name_spec.rb` keep their filenames — they describe behavior, not the module — and should pass untouched.

- [ ] **Step 4: Commit**

```bash
git add -A lib/axn/core.rb lib/axn/core/tool_declaration.rb
git commit -m "PRO-3005: Core::Tools becomes Core::ToolDeclaration, freeing Tools for the surface"
```

---

## Task 10: Docs, `AGENTS.md` namespace policy, CHANGELOG

**Files:**
- Modify: `AGENTS.md:37` and `:55` (plus the new policy section)
- Modify: `AGENTS-tool-adapters.md` (lines 27, 35, 36, 38, 40, 43, 45, 52, 59, 141, 151, 185, 217)
- Modify: `docs/recipes/authoring-tool-adapters.md` (lines 22, 27, 36, 40, 43, 45, 64, 84, 232, 317, 318, 319, 330)
- Modify: `docs/recipes/gem-configuration.md`, `docs/reference/configuration.md:91`, `docs/reference/factory.md:113`
- Modify: `CHANGELOG.md` (lines 14, 34, 104, 126, 127, 134, 135, 137, 139, 140, 165)

- [ ] **Step 1: Sweep the mechanical renames through docs**

```bash
for f in AGENTS.md AGENTS-tool-adapters.md CHANGELOG.md docs/recipes/authoring-tool-adapters.md docs/recipes/gem-configuration.md docs/reference/configuration.md docs/reference/factory.md; do
  sed -i '' \
    -e 's/Axn\.tools_for(/Axn::Tools.for(/g' \
    -e 's/Axn\.versions_for(/Axn::Tools.versions(/g' \
    -e 's/Axn\.register_tool_adapter(/Axn::Tools.register_adapter(/g' \
    -e 's/Axn\.validate_tool_contracts!/Axn::Tools.validate_contracts!/g' \
    -e 's/Axn::InvalidToolContract/Axn::Tools::InvalidContract/g' \
    -e 's/Axn\.owns_failure_exception?/Axn::Extensions.owned_failure?/g' \
    -e 's/Axn::Reflection::UnserializableValue/Axn::Extensions::Serialization::UnserializableValue/g' \
    "$f"
done
grep -rn "tools_for\|register_tool_adapter\|versions_for\|validate_tool_contracts\|InvalidToolContract\|owns_failure_exception\|Reflection::UnserializableValue\|broad_tool_path\|normalize_tool_path\|Core::Tools" AGENTS.md AGENTS-tool-adapters.md CHANGELOG.md docs/ | grep -v "docs/.vitepress/dist"
```

The grep's remaining hits are prose that a `sed` cannot fix — bare method names in sentences (`register_tool_adapter takes an optional second argument`, `` `tools_for` sorts on … ``, `tools_for warns`). Rewrite each so the sentence names the new method, and re-run the grep until only `docs/.vitepress/dist/` (build artifacts) remains.

- [ ] **Step 2: Rewrite `AGENTS.md:37`**

```markdown
- **Tool registry** — `tool` DSL / `Axn::Tools.for(:adapter)` / `tool_name` (`Axn::Core::ToolDeclaration`, `Axn::Tools::Registry`) own tool membership and naming; adapters consume them, never re-derive names or re-list members.
```

- [ ] **Step 3: Rewrite `AGENTS.md:55` and add the namespace policy**

Replace the reserved-constants paragraph so it stops listing `Reflection` as a claimed namespace only if PRO-3028 has landed; for THIS PR, keep `Reflection` listed and add the policy section below the existing `Axn::Extensions` paragraph:

```markdown
### Namespace policy

Which namespace a new constant belongs in, so the next addition follows a rule instead of copying a precedent:

- `Internal::X` — internal **and generically useful**: a value-level mechanism any layer can use, with no presence in the action's surface. `CycleGuard`, `ShapeGraph`, `NativeMethods`, `Timing`, `Callable`, `ClassName`, `ExceptionMessage`.
- `Core::X` — internal **and contextual to one topic**: a layer extended onto the action class, named for what the *author* writes. `Contract`, `Hooks`, `Tagging`, `Logging`, `AmbientContext`, `ToolDeclaration`.
- `Core::Contract::X` — machinery one layer owns and that is meaningless outside it. `FieldConfig`, `ShapeConfig`, `ShapeDeclaration`, `Redaction`.
- `Extensions::X` — axn **or downstream gems**. The only namespace a gem should name; adding to it is adding to the public API.
- `Tools::X` — the tool surface: its calls (`Axn::Tools.for`) *and* its exceptions (`Axn::Tools::InvalidContract`).

A namespace is not a substitute for `private`. `Axn::Configurable` is `extend`ed onto each consuming gem's own module, so an underscore-named method there is a public method of `Axn::MCP` / `Axn::OpenAPI` / `DataShifter` — "internal by namespace" guarantees nothing. Underscore-name AND `private` unless a cross-file caller with an explicit receiver needs it, and record why when one does.
```

- [ ] **Step 4: Add the CHANGELOG entries for what is genuinely new**

Under the `### Tools & adapters` heading in `CHANGELOG.md`, add one entry (the renames themselves are absorbed by the in-place edits from Step 1):

```markdown
* [FEAT] The tool surface lives on `Axn::Tools`: `Axn::Tools.for(:adapter)` enumerates an adapter's tools (`all_versions:` for every version), `Axn::Tools.versions(:adapter, tool_name)` returns one tool's version group, `Axn::Tools.register_adapter(:key, self)` registers an adapter, `Axn::Tools.adapters` lists the registered keys, and `Axn::Tools.validate_contracts!` validates every tool axn's contract at setup. Tool-specific errors live there too (`Axn::Tools::InvalidContract`). The top-level `Axn` module holds only `config`, `configure`, and `included`. The two predicates a gem building on axn asks are on the extension-author surface: `Axn::Extensions.owned_failure?(exception)` (is this exception's `#message` axn's own, or a foreign technical cause a `fails_on` reclassified) and `Axn::Extensions::Serialization::UnserializableValue` (raised when an exposed value has no honest JSON representation).
```

Under `### Configuration`, add:

```markdown
* [FEAT] `Axn.config.default_async?` answers whether a default async adapter is configured, so a gem asking that question no longer reads the underscored `_default_async_adapter` off the config object.
```

- [ ] **Step 5: Verify the docs build and the examples still typecheck by eye**

Run: `grep -rn "Axn::Tools.for\|Axn::Tools.versions\|Axn::Tools.register_adapter" docs/recipes/authoring-tool-adapters.md | head -20`
Expected: the recipe's code fences now teach the new calls, including the zero-arg `.tools` example (`def self.tools = Axn::Tools.for(:mcp).map { |axn_class| wrap(axn_class) }`).

- [ ] **Step 6: Commit**

```bash
git add AGENTS.md AGENTS-tool-adapters.md CHANGELOG.md docs/
git commit -m "PRO-3005: docs, AGENTS namespace policy, and CHANGELOG name the new surface"
```

---

## Task 11: Whole-repo verification

**Files:** none — this task only reads and reports.

- [ ] **Step 1: Confirm no old name survives anywhere in the repo**

```bash
grep -rInE "Axn\.tools_for|Axn\.versions_for|Axn\.register_tool_adapter|Axn\.validate_tool_contracts|Axn\.owns_failure_exception|Axn::InvalidToolContract|Axn::Reflection::UnserializableValue|broad_tool_path|normalize_tool_path|TOOL_PATHS_BLOCKLIST|BROAD_TOOL_PATH_LEAVES|Axn::Core::Tools|Registry\.tools_for|Registry\.versions_for" . \
  | grep -v "docs/.vitepress/dist\|internal-docs/\|^./\.git/"
```

Expected: no output. `internal-docs/` is excluded deliberately — historical plans and specs describe what the code was at the time and are not edited.

- [ ] **Step 2: Confirm the top-level surface**

```bash
ruby -Ilib -e 'require "axn"; puts Axn.singleton_methods(false).sort.inspect'
ruby -Ilib -e 'require "axn"; puts Axn::Tools.singleton_methods(false).sort.inspect'
```

Expected exactly:

```
[:config, :configure, :included]
[:adapters, :for, :register_adapter, :validate_contracts!, :versions]
```

- [ ] **Step 3: Confirm the private helpers are private**

```bash
ruby -Ilib -e 'require "axn"
  puts Axn::Tools.singleton_class.private_instance_methods(false).sort.inspect
  puts Axn::Tools.respond_to?(:_registered_adapter!).inspect
  puts Axn.singleton_class.private_instance_methods(false).sort.inspect'
```

Expected: `[:_named_invalid_contract, :_registered_adapter!]`, then `false`, then `[]`.

- [ ] **Step 4: Run the whole suite set**

Run: `bundle exec rake all_specs`
Expected: PASS — `spec`, `spec_rubocop`, and `spec_rails`.

- [ ] **Step 5: Verify against a Ruby the CI matrix uses but the repo does not pin**

CI runs 3.2 / 3.3 / 3.4 and the repo pins 3.3.6. Ruby 3.4 changed `Hash#inspect` spacing, so if any new expectation asserts inspected Hash text, it will pass locally and fail on 3.4. Grep the specs this PR touched for that hazard:

```bash
git diff --name-only origin/main...HEAD -- 'spec/**' 'spec_rails/**' | xargs grep -n 'to eq("{\|to eq("#<' 2>/dev/null
```

Expected: no output. (The specs added by this plan assert constants, booleans, and class names — none of them inspected Hash text.)

- [ ] **Step 6: Commit any fixes and confirm the branch is clean**

```bash
git status --short
git log --oneline origin/main..HEAD
```

Expected: a clean tree and one commit per task above.

---

## Downstream handoff (after this PR merges, before `0.1.0-alpha.5`)

Not part of the plan's tasks — the snippets to paste into each gem's session. **Re-measure each gem before handing off**, since an in-flight branch may have merged (axn-openapi's `kali/clean-serialization` already did, which is why its old snippet named a file that no longer exists).

| gem | branch as of 2026-08-03 | changes |
| -- | -- | -- |
| axn-mcp | `kali/pro-2770-axn-mcp-adopt-axn-configuration-dsl` | `mcp.rb:92` → `Axn::Tools.register_adapter(:mcp, self)`; `mcp/wrap.rb:32` → `Axn::Tools.for(:mcp)`; 3 lines in `spec/axn/mcp/registry_spec.rb`; `UnserializableValue` at `serializer_spec.rb:102,107` and `wrap_spec.rb:357,361,368`; comments at `mcp.rb:35`, `wrap.rb:67`, `server_integration_spec.rb:198,307` |
| axn-openapi | `main` | `openapi.rb:60` → `Axn::Tools.for(:openapi, all_versions: true)`; `openapi.rb:75` → `Axn::Tools.register_adapter(:openapi, self)`; 1 line in `spec/axn/openapi/registration_spec.rb`; comments only for `UnserializableValue` at `openapi.rb:29`, `dispatcher.rb:95,120` |
| axn-ruby_llm | `kali/pro-2771-axn-ruby_llm-adopt-axn-configuration-dsl` | `ruby_llm.rb:28` → `Axn::Tools.register_adapter(:ruby_llm, self)`; `tool_adapter.rb:157` → `Axn::Tools.for(:ruby_llm)`; 2 lines in `spec/axn/ruby_llm/tool_adapter_spec.rb`; `tool_adapter.rb:105`'s `rescue` list → `Axn::Extensions::Serialization::UnserializableValue`. Give this session PRO-3017's tracer snippet at the same time (`ask_spec.rb:550`) |
| axn-webhooks | `main` | `dispatch.rb:66`, `outbound/deliver.rb:105`, `outbound/emit.rb:51` → `Axn.config.default_async?` (drop the `!!`) |

`slack_sender` and `data_shifter` need nothing — verified 2026-08-03 with the full rename set as bare substrings over their own source.
