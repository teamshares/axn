# First-class tool versioning (PRO-2955) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `tool_version` as a first-class core tool attribute (sibling of `tool_name`) so multiple versions of one logical tool can coexist in the registry, grouped under a single `tool_name`.

**Architecture:** A new `Axn::Core::Versioning` DSL module stores `_tool_version`/`_tool_version_default` and validates at declaration. `Axn::Core::Tools#tool_name` derivation drops a trailing `::Vn` segment when a version is declared. A new `Axn::Tools::VersionGroup` value object is the single place that resolves `.latest`/`.default` and validates a group; the registry builds one group per `(adapter, tool_name)` and projects either latest-per-name (default) or every version.

**Tech Stack:** Ruby (>= 3.2.1), RSpec, ActiveSupport `class_attribute`. No new dependencies.

## Global Constraints

- Ruby `>= 3.2.1` (from `axn.gemspec`).
- `spec/` is the **non-Rails** suite; do not reference Rails constants. Run tests with `bundle exec rspec <path>`.
- No manual line breaks in Markdown prose (repo convention): one line per paragraph.
- Registry identity is `(tool_name, tool_version)`; `tool_version` is **core, single-valued, not per-adapter**.
- `tool_version N` is the **sole** source of truth for the version number — nothing derives version from the filesystem.
- Fail-loud-at-declaration for anything knowable from one class; group conflicts raise at enumeration.
- The reader consumed by the registry/adapters is `tool_version` (never a bare `version` — `version` stays free for downstream use).

---

### Task 1: `Axn::Core::Versioning` DSL module

**Files:**
- Create: `lib/axn/core/versioning.rb`
- Modify: `lib/axn/core.rb:21` (add `require`), `lib/axn/core.rb:71` (add `include`)
- Test: `spec/axn/core/versioning_spec.rb`

**Interfaces:**
- Produces:
  - Class method `tool_version(value = NOT_SET, default: false)` — setter when given an `Integer >= 1`; zero-arg reader returning the **effective** version (`_tool_version || 1`).
  - Class attributes `_tool_version` (default `nil`) and `_tool_version_default` (default `false`), both `instance_accessor: false`, readable as `Klass._tool_version` / `Klass._tool_version_default`.
  - Declaration-time raises: non-Integer / `< 1` value; a `::Vn` constant segment whose number disagrees with the declared version.

- [ ] **Step 1: Write the failing test**

```ruby
# spec/axn/core/versioning_spec.rb
# frozen_string_literal: true

RSpec.describe Axn::Core::Versioning do
  # Anonymous-class-safe builder; optionally stamps a constant name so the
  # ::Vn mismatch guard (which reads `self.name`) can be exercised.
  def tool_klass(const_name = nil)
    Class.new do
      include Axn
      define_singleton_method(:name) { const_name } if const_name
    end
  end

  describe "reader default" do
    it "is 1 when never declared" do
      expect(tool_klass.tool_version).to eq(1)
    end

    it "is not flagged the explicit default when never declared" do
      expect(tool_klass._tool_version_default).to be(false)
    end
  end

  describe "setter" do
    it "stores the declared version and reads it back" do
      k = tool_klass
      k.tool_version(2)
      expect(k.tool_version).to eq(2)
      expect(k._tool_version).to eq(2)
    end

    it "records the default: flag" do
      k = tool_klass
      k.tool_version(2, default: true)
      expect(k._tool_version_default).to be(true)
    end

    it "defaults the default: flag to false" do
      k = tool_klass
      k.tool_version(2)
      expect(k._tool_version_default).to be(false)
    end
  end

  describe "validation" do
    it "rejects zero" do
      expect { tool_klass.tool_version(0) }.to raise_error(ArgumentError, /Integer >= 1/)
    end

    it "rejects negatives" do
      expect { tool_klass.tool_version(-1) }.to raise_error(ArgumentError, /Integer >= 1/)
    end

    it "rejects non-Integers" do
      expect { tool_klass.tool_version("2") }.to raise_error(ArgumentError, /Integer >= 1/)
    end
  end

  describe "::Vn mismatch guard" do
    it "raises when the constant segment number disagrees with the declared version" do
      k = tool_klass("AgentTools::ApproveLoan::V2")
      expect { k.tool_version(3) }.to raise_error(ArgumentError, /::V2.*tool_version 3/)
    end

    it "accepts a matching ::Vn segment" do
      k = tool_klass("AgentTools::ApproveLoan::V2")
      expect { k.tool_version(2) }.not_to raise_error
      expect(k.tool_version).to eq(2)
    end

    it "is skipped for an anonymous class (no constant name)" do
      k = tool_klass # name is nil
      expect { k.tool_version(2) }.not_to raise_error
    end

    it "ignores a trailing segment that is not the exact vN pattern" do
      k = tool_klass("AgentTools::ApproveLoanV2") # not a ::Vn segment
      expect { k.tool_version(3) }.not_to raise_error
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/core/versioning_spec.rb`
Expected: FAIL — `uninitialized constant Axn::Core::Versioning` (and `tool_version` undefined).

- [ ] **Step 3: Create the module**

```ruby
# lib/axn/core/versioning.rb
# frozen_string_literal: true

module Axn
  module Core
    # First-class tool contract version — a sibling of `tool_name`, never part of it.
    # `_tool_version` nil means "undeclared" (effective version 1, and the group default).
    # Advisory/metadata like SemanticHints; the registry groups by (tool_name, tool_version).
    module Versioning
      def self.included(base)
        base.class_eval do
          # instance_accessor: false — class-level DSL, not per-instance state.
          # _tool_version nil = undeclared (effective 1 & default); separate calls so each
          # carries its own default.
          class_attribute :_tool_version, instance_accessor: false, default: nil
          class_attribute :_tool_version_default, instance_accessor: false, default: false
          extend ClassMethods
        end
      end

      module ClassMethods
        NOT_SET = Object.new.freeze
        private_constant :NOT_SET

        # Matches a constant's final segment when it is exactly the vN convention (`V1`, `v2`).
        VERSION_SEGMENT = /\Av(\d+)\z/i

        # `tool_version 2, default: true` sets; zero-arg reads the effective version (1 when
        # undeclared). `default: true` blesses this version as the movable stable pin adapters
        # that pin (e.g. an HTTP bare path) honor; it is a no-op on an only/earliest version.
        def tool_version(value = NOT_SET, default: false)
          return (_tool_version || 1) if value.equal?(NOT_SET)

          raise ArgumentError, "tool_version must be an Integer >= 1 (got #{value.inspect})" unless value.is_a?(Integer) && value >= 1

          _assert_version_segment_matches!(value)
          self._tool_version = value
          self._tool_version_default = default
          value
        end

        private

        # When the constant follows the ::Vn convention, the segment number and the declared
        # version must agree — the segment is what `tool_name` derivation drops, so a mismatch
        # (`::V2` declaring `tool_version 3`) would ship a name/number that disagree. Skipped for
        # an anonymous class (no constant name) — the factory / `Class.new` path is unaffected.
        def _assert_version_segment_matches!(value)
          segment = name.to_s.split("::").last
          return unless segment&.match(VERSION_SEGMENT)

          declared_in_name = Regexp.last_match(1).to_i
          return if declared_in_name == value

          raise ArgumentError,
                "#{name}: constant ends in ::#{segment} but `tool_version #{value}` was declared. " \
                "Align the constant name and the version (rename to ::V#{value}) or drop the ::vN suffix."
        end
      end
    end
  end
end
```

- [ ] **Step 4: Wire the module into the core**

In `lib/axn/core.rb`, add the require next to the other core DSL requires (after line 21, `require "axn/core/semantic_hints"`):

```ruby
require "axn/core/versioning"
```

And add the include next to `Core::Tools` (after line 71, `include Core::Tools`):

```ruby
        include Core::Versioning
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bundle exec rspec spec/axn/core/versioning_spec.rb`
Expected: PASS (all examples).

- [ ] **Step 6: Commit**

```bash
git add lib/axn/core/versioning.rb lib/axn/core.rb spec/axn/core/versioning_spec.rb
git commit -m "PRO-2955: tool_version DSL (Axn::Core::Versioning)"
```

---

### Task 2: `tool_name` derivation — drop trailing `::Vn` (option B) + no-`tool_version` guard

**Files:**
- Modify: `lib/axn/core/tools.rb:139-165` (the `tool_name` reader) and add a private helper
- Test: `spec/axn/core/tool_name_spec.rb`

**Interfaces:**
- Consumes: `_tool_version` (Task 1).
- Produces: `tool_name` returns the enclosing-namespace-derived name (`AgentTools::ApproveLoan::V2` → `"approve_loan"`) when `_tool_version` is set and the final segment matches `/\Av\d+\z/i`; raises at derivation when the final segment matches but `_tool_version` is `nil`.

- [ ] **Step 1: Write the failing tests**

Append to `spec/axn/core/tool_name_spec.rb` (inside the top-level `describe`, reusing the file's existing `tool_klass(name)` helper which stamps `self.name`):

```ruby
  describe "version segment handling (option B)" do
    it "drops a trailing ::Vn and derives from the enclosing namespace when tool_version is declared" do
      k = tool_klass("AgentTools::ApproveLoan::V2")
      k.tool_version(2)
      expect(k.tool_name).to eq("approve_loan")
    end

    it "groups v1 and v2 under the same derived name" do
      v1 = tool_klass("AgentTools::ApproveLoan::V1")
      v1.tool_version(1)
      v2 = tool_klass("AgentTools::ApproveLoan::V2")
      v2.tool_version(2)
      expect(v1.tool_name).to eq("approve_loan")
      expect(v2.tool_name).to eq("approve_loan")
    end

    it "raises when a ::Vn constant declares no tool_version (promote-and-forget guard)" do
      k = tool_klass("AgentTools::ApproveLoan::V1") # no tool_version declared
      expect { k.tool_name }.to raise_error(ArgumentError, /::V1.*tool_version/)
    end

    it "lets an explicit tool name: win over version-segment derivation" do
      k = tool_klass("AgentTools::ApproveLoan::V2")
      k.tool_version(2)
      k.tool name: "loan_approver"
      expect(k.tool_name).to eq("loan_approver")
    end

    it "leaves a non-::Vn trailing segment untouched" do
      k = tool_klass("AgentTools::ApproveLoanV2") # V2 is part of the word, not its own segment
      k.tool_version(2)
      expect(k.tool_name).to eq("approve_loan_v2")
    end

    it "falls back to the never-blank default for a bare ::Vn with no enclosing namespace" do
      k = tool_klass("V2")
      k.tool_version(2)
      expect(k.tool_name).to eq("tool")
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/axn/core/tool_name_spec.rb -e "version segment handling"`
Expected: FAIL — the `::V2` name currently derives `"agent_tools_approve_loan_v2"`, and the no-`tool_version` case does not raise.

- [ ] **Step 3: Implement option B + the guard**

In `lib/axn/core/tools.rb`, inside `tool_name` (after `source` is computed and the `return "tool"` empty-guard, before `segments = source.split("::")` is used for derivation), route the segments through a new helper. Replace:

```ruby
          source = axn_name.presence || name.presence
          return "tool" if source.nil? || source.strip.empty?

          segments = source.split("::")
          kept = _tool_name_strip_leading_prefixes(segments)
```

with:

```ruby
          source = axn_name.presence || name.presence
          return "tool" if source.nil? || source.strip.empty?

          segments = _apply_version_segment_rule(source.split("::"))
          kept = _tool_name_strip_leading_prefixes(segments)
```

Then add the helper in the `private` section of `ClassMethods` (near `_tool_name_strip_leading_prefixes`):

```ruby
        # The vN convention: a final constant segment like `V2`. With a declared `tool_version`,
        # derive from the enclosing namespace (`AgentTools::ApproveLoan::V2` → the ApproveLoan
        # segments) so both versions collapse to one `tool_name` and group. With no declared
        # version it is the promote-and-forget footgun (v1.rb would orphan itself as `..._v1`),
        # so raise here — the earliest point it is knowable, `tool_version` never having been
        # called. A bare `::Vn` with nothing enclosing falls through to the never-blank fallback.
        def _apply_version_segment_rule(segments)
          return segments unless segments.last&.match?(Axn::Core::Versioning::ClassMethods::VERSION_SEGMENT)

          if _tool_version.nil?
            raise ArgumentError,
                  "#{name}: constant ends in ::#{segments.last} (the vN tool-version convention) but no " \
                  "`tool_version` was declared. Declare `tool_version N` to opt into versioning, or rename the constant."
          end

          segments[0...-1].presence || segments
        end
```

Note: `VERSION_SEGMENT` is currently under `ClassMethods` with no visibility restriction (it is a constant, not a private method), so `Axn::Core::Versioning::ClassMethods::VERSION_SEGMENT` resolves. Keep the reference fully-qualified to make the cross-module dependency explicit.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/axn/core/tool_name_spec.rb`
Expected: PASS (new group plus every pre-existing example — derivation for non-versioned classes is unchanged).

- [ ] **Step 5: Commit**

```bash
git add lib/axn/core/tools.rb spec/axn/core/tool_name_spec.rb
git commit -m "PRO-2955: tool_name drops trailing ::Vn when tool_version declared"
```

---

### Task 3: `Axn::Tools::VersionGroup` value object

**Files:**
- Create: `lib/axn/tools/version_group.rb`
- Modify: `lib/axn.rb:19` (add `require` next to `require "axn/tools/registry"`)
- Test: `spec/axn/tools/version_group_spec.rb`

**Interfaces:**
- Consumes: member classes responding to `tool_version` (Task 1) and `_tool_version_default` (Task 1).
- Produces: `Axn::Tools::VersionGroup.new(adapter:, tool_name:, members:)` with readers `#adapter`, `#tool_name`, `#all` (members sorted ascending by `tool_version`), and methods `#latest` (max version member) and `#default` (the `_tool_version_default` member, else the earliest). Raises `ArgumentError` on a duplicate `tool_version` within the group, or more than one `_tool_version_default` member.

- [ ] **Step 1: Write the failing test**

```ruby
# spec/axn/tools/version_group_spec.rb
# frozen_string_literal: true

RSpec.describe Axn::Tools::VersionGroup do
  # Minimal stand-ins: the group only reads tool_version and _tool_version_default.
  def member(version, default: false)
    Class.new do
      include Axn
      tool_version(version, default: default)
    end
  end

  def group(members)
    described_class.new(adapter: :mcp, tool_name: "approve_loan", members: members)
  end

  it "sorts .all ascending by version regardless of input order" do
    v1 = member(1)
    v3 = member(3)
    g = group([v3, v1])
    expect(g.all).to eq([v1, v3])
  end

  it ".latest is the highest version" do
    v1 = member(1)
    v3 = member(3)
    expect(group([v1, v3]).latest).to eq(v3)
  end

  it ".default is the earliest version when none is flagged" do
    v1 = member(1)
    v3 = member(3)
    expect(group([v3, v1]).default).to eq(v1)
  end

  it ".default is the flagged version when one declares default: true" do
    v1 = member(1)
    v2 = member(2, default: true)
    v3 = member(3)
    expect(group([v1, v2, v3]).default).to eq(v2)
  end

  it "tolerates version gaps" do
    v1 = member(1)
    v3 = member(3)
    g = group([v1, v3])
    expect(g.default).to eq(v1)
    expect(g.latest).to eq(v3)
  end

  it "raises on a duplicate (tool_name, version)" do
    a = member(2)
    b = member(2)
    expect { group([a, b]) }.to raise_error(ArgumentError, /v2/)
  end

  it "raises when more than one version is flagged default: true" do
    a = member(1, default: true)
    b = member(2, default: true)
    expect { group([a, b]) }.to raise_error(ArgumentError, /default/)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/tools/version_group_spec.rb`
Expected: FAIL — `uninitialized constant Axn::Tools::VersionGroup`.

- [ ] **Step 3: Create the value object**

```ruby
# lib/axn/tools/version_group.rb
# frozen_string_literal: true

module Axn
  module Tools
    # The coexisting versions of ONE logical tool (one (adapter, tool_name)), and the single
    # place `latest` and `default` resolve — so `tools_for`'s latest-collapse and a path-routing
    # adapter's default-pin consume the same rules instead of each re-deriving them. Validates the
    # group on construction (the relaxed replacement for the old unique-tool_name assertion).
    class VersionGroup
      attr_reader :adapter, :tool_name, :all

      def initialize(adapter:, tool_name:, members:)
        @adapter = adapter
        @tool_name = tool_name
        @all = members.sort_by(&:tool_version)
        _validate!
      end

      # Newest contract. What latest-favoring adapters (MCP, ruby_llm) serve.
      def latest
        @all.max_by(&:tool_version)
      end

      # The author-blessed stable pin: the version flagged `default: true`, else the earliest.
      # What stability-favoring adapters (an HTTP bare path) serve. Validation guarantees at most
      # one flagged member, so `find` is unambiguous.
      def default
        @all.find(&:_tool_version_default) || @all.min_by(&:tool_version)
      end

      private

      def _validate!
        duplicates = @all.group_by(&:tool_version).select { |_version, klasses| klasses.length > 1 }
        unless duplicates.empty?
          details = duplicates.map { |version, klasses| "#{@tool_name.inspect} v#{version} (#{klasses.map(&:name).sort.join(', ')})" }.join("; ")
          raise ArgumentError,
                "Duplicate tool for adapter #{@adapter.inspect}: #{details}. Two tools cannot share a " \
                "(tool_name, tool_version); give one an explicit `tool name: \"...\"` or a distinct `tool_version`."
        end

        flagged = @all.select(&:_tool_version_default)
        return if flagged.length <= 1

        raise ArgumentError,
              "Multiple `default: true` versions of #{@tool_name.inspect} for adapter #{@adapter.inspect}: " \
              "#{flagged.map(&:name).sort.join(', ')}. Only one version may be the default."
      end
    end
  end
end
```

- [ ] **Step 4: Wire the require**

In `lib/axn.rb`, add next to line 19 (`require "axn/tools/registry"`), before the registry require so the constant is available to it:

```ruby
require "axn/tools/version_group"
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bundle exec rspec spec/axn/tools/version_group_spec.rb`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/axn/tools/version_group.rb lib/axn.rb spec/axn/tools/version_group_spec.rb
git commit -m "PRO-2955: Axn::Tools::VersionGroup resolver (latest/default + validation)"
```

---

### Task 4: Registry enumeration — `(tool_name, tool_version)` identity, latest / all-versions / versions_for

**Files:**
- Modify: `lib/axn/tools/registry.rb` (the `tools_for` method at :63-71, remove `_assert_unique_tool_names!` at :156-164, add `versions_for` + `_version_groups`)
- Modify: `lib/axn.rb:65-72` (public `tools_for` gains `all_versions:`; add `versions_for`)
- Test: `spec/axn/tools/registry_spec.rb`

**Interfaces:**
- Consumes: `Axn::Tools::VersionGroup` (Task 3), `tool_version` (Task 1).
- Produces:
  - `Axn::Tools::Registry.tools_for(adapter, all_versions: false)` → latest-per-`tool_name` (sorted by `tool_name`) by default; every member sorted by `(tool_name, tool_version)` when `all_versions: true`.
  - `Axn::Tools::Registry.versions_for(adapter, tool_name)` → the `VersionGroup`, or `nil` when no member matches.
  - `Axn.tools_for(adapter, all_versions: false)` and `Axn.versions_for(adapter, tool_name)` public wrappers (both validate the adapter is registered).

- [ ] **Step 1: Write the failing tests**

Append a new `describe` to `spec/axn/tools/registry_spec.rb` (top-level, sibling of the existing `.tools_for` block; the file already has `require "support/tool_adapter_helpers"` and resets adapters around each example):

```ruby
  describe "versioning" do
    before { Axn.register_tool_adapter(:mcp) }

    def versioned_tool(const, version, default: false)
      stub_const(const, Class.new do
        include Axn
        tool :mcp
        tool_version(version, default: default)
      end)
    end

    it "returns only the latest version per tool_name by default" do
      v1 = versioned_tool("VerSpec::ApproveLoan::V1", 1)
      v2 = versioned_tool("VerSpec::ApproveLoan::V2", 2)
      result = Axn.tools_for(:mcp)
      expect(result).to include(v2)
      expect(result).not_to include(v1)
    end

    it "returns every version with all_versions: true, sorted by (tool_name, version)" do
      v1 = versioned_tool("VerSpec::ApproveLoan::V1", 1)
      v2 = versioned_tool("VerSpec::ApproveLoan::V2", 2)
      expect(Axn.tools_for(:mcp, all_versions: true)).to eq([v1, v2])
    end

    it "versions_for returns the group with latest/default/all" do
      v1 = versioned_tool("VerSpec::ApproveLoan::V1", 1)
      v2 = versioned_tool("VerSpec::ApproveLoan::V2", 2)
      group = Axn.versions_for(:mcp, "approve_loan")
      expect(group.all).to eq([v1, v2])
      expect(group.latest).to eq(v2)
      expect(group.default).to eq(v1)
    end

    it "versions_for honors a moved default" do
      versioned_tool("VerSpec::ApproveLoan::V1", 1)
      v2 = versioned_tool("VerSpec::ApproveLoan::V2", 2, default: true)
      expect(Axn.versions_for(:mcp, "approve_loan").default).to eq(v2)
    end

    it "versions_for returns nil for an unknown tool_name" do
      expect(Axn.versions_for(:mcp, "nope")).to be_nil
    end

    it "raises on two tools sharing (tool_name, version)" do
      versioned_tool("VerSpec::DupeA", 2).tool name: "dupe"
      versioned_tool("VerSpec::DupeB", 2).tool name: "dupe"
      expect { Axn.tools_for(:mcp) }.to raise_error(ArgumentError, /Duplicate tool/)
    end

    it "leaves an unversioned tool enumerated exactly as before" do
      solo = stub_const("VerSpec::Solo", Class.new do
        include Axn
        tool :mcp
      end)
      expect(Axn.tools_for(:mcp)).to include(solo)
      expect(Axn.versions_for(:mcp, solo.tool_name(:mcp)).all).to eq([solo])
    end
  end
```

Note: the `raises on two tools sharing (tool_name, version)` example calls `tool` a second time via `.tool name: "dupe"` on the returned class — that is a *fresh* second `tool` call on a class whose only prior `tool` was inside `versioned_tool`. Rewrite `versioned_tool` for that example to declare the name inline instead, to avoid the repeat-`tool` guard:

```ruby
    it "raises on two tools sharing (tool_name, version)" do
      stub_const("VerSpec::DupeA", Class.new do
        include Axn
        tool :mcp, name: "dupe"
        tool_version 2
      end)
      stub_const("VerSpec::DupeB", Class.new do
        include Axn
        tool :mcp, name: "dupe"
        tool_version 2
      end)
      expect { Axn.tools_for(:mcp) }.to raise_error(ArgumentError, /Duplicate tool/)
    end
```

(Use only this corrected form; delete the first draft of that example.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/axn/tools/registry_spec.rb -e versioning`
Expected: FAIL — `tools_for` has no `all_versions:` keyword; `Axn.versions_for` is undefined.

- [ ] **Step 3: Rework the registry enumeration**

In `lib/axn/tools/registry.rb`, replace `tools_for` (:63-71):

```ruby
      def tools_for(adapter, all_versions: false)
        ensure_loaded!
        members = all_classes.select { |klass| member?(klass, adapter) }
        groups = _version_groups(members, adapter)
        if all_versions
          # Deterministic: by tool_name, then ascending version within each group.
          groups.sort_by(&:tool_name).flat_map(&:all)
        else
          # Latest per tool_name. Names are distinct after collapsing, so sort_by is tie-free.
          groups.map(&:latest).sort_by { |klass| klass.tool_name(adapter) }
        end
      end

      # The resolved version group for one logical tool under `adapter`, or nil when nothing
      # matches. Entry point for a path-routing adapter (all versions + default pin) and for
      # exercising movable-default semantics without an adapter.
      def versions_for(adapter, tool_name)
        ensure_loaded!
        target = tool_name.to_s
        members = all_classes.select { |klass| member?(klass, adapter) && klass.tool_name(adapter) == target }
        return nil if members.empty?

        VersionGroup.new(adapter: adapter, tool_name: target, members: members)
      end
```

Remove the now-obsolete `_assert_unique_tool_names!` method (:156-164) — its uniqueness role moves into `VersionGroup#_validate!`, keyed on `(tool_name, tool_version)` rather than `tool_name` alone. Add a private grouping helper (near the other private registry helpers):

```ruby
      # One VersionGroup per (adapter, tool_name). Group construction validates the group
      # (duplicate (tool_name, tool_version), multiple default: true), so both enumeration
      # paths share one set of rules.
      def _version_groups(members, adapter)
        members.group_by { |klass| klass.tool_name(adapter) }.map do |tool_name, klasses|
          VersionGroup.new(adapter: adapter, tool_name: tool_name, members: klasses)
        end
      end
```

- [ ] **Step 4: Update the public wrappers**

In `lib/axn.rb`, replace `self.tools_for` (:65-72) and add `self.versions_for`:

```ruby
  def self.tools_for(adapter, all_versions: false)
    adapter = _registered_tool_adapter!(adapter)
    Axn::Tools::Registry.tools_for(adapter, all_versions: all_versions)
  end

  def self.versions_for(adapter, tool_name)
    adapter = _registered_tool_adapter!(adapter)
    Axn::Tools::Registry.versions_for(adapter, tool_name)
  end

  def self._registered_tool_adapter!(adapter)
    adapter = adapter.to_sym
    unless Axn::Tools::Registry.adapters.include?(adapter)
      raise ArgumentError, "#{adapter.inspect} is not a registered tool adapter (registered: #{Axn::Tools::Registry.adapters.to_a.inspect})"
    end

    adapter
  end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bundle exec rspec spec/axn/tools/registry_spec.rb`
Expected: PASS. If a pre-existing example asserted the **old** duplicate-`tool_name` message ("Duplicate tool_name for adapter"), update its expected message to match `VersionGroup`'s new wording ("Duplicate tool for adapter") — the collision still raises, only the phrasing and the `(tool_name, tool_version)` framing changed.

- [ ] **Step 6: Run the full suite to confirm no regressions**

Run: `bundle exec rspec spec/`
Expected: PASS (green). Investigate any failure before proceeding — the likeliest touch-points are tests asserting the old collision message or enumeration order.

- [ ] **Step 7: Commit**

```bash
git add lib/axn/tools/registry.rb lib/axn.rb spec/axn/tools/registry_spec.rb
git commit -m "PRO-2955: registry identity (tool_name, tool_version) + versions_for/all_versions"
```

---

### Task 5: Documentation + CHANGELOG

**Files:**
- Modify: `docs/recipes/authoring-tool-adapters.md` (add a `## Versioning` section)
- Modify: `CHANGELOG.md` (Unreleased)

**Interfaces:**
- Consumes: the final public surface from Tasks 1–4 (`tool_version`, `tools_for(all_versions:)`, `versions_for`, `.latest`/`.default`).

- [ ] **Step 1: Add the Versioning section to the tool-adapters recipe**

In `docs/recipes/authoring-tool-adapters.md`, add a `## Versioning` section before `## Testing`. Content (one line per paragraph, no manual wrapping):

````markdown
## Versioning

A tool declares its contract version with `tool_version` — a first-class core attribute, a sibling of `tool_name`, never part of it. Absent, a tool is version 1 and its own default. Multiple versions of one logical tool coexist by sharing a `tool_name`:

```ruby
class ApproveLoan
  include Axn
  tool :mcp
  tool_version 2, default: true
end
```

The registry identity is `(tool_name, tool_version)`: two tools may share a `tool_name` as long as their versions differ (same name *and* version still raises). Enumeration exposes two designations for an adapter to project as fits its consumer:

- `Axn.tools_for(:mcp)` returns the **latest** version per `tool_name` — a model re-reads the schema each session and wants the newest contract. Backward-compatible: today's unversioned tools are groups of one, so latest-of-one is unchanged.
- `Axn.tools_for(:mcp, all_versions: true)` returns **every** version (sorted by `tool_name`, then ascending version) — for an adapter that surfaces all of them, e.g. path-routed HTTP.
- `Axn.versions_for(:mcp, "approve_loan")` returns the version group: `.all`, `.latest`, and `.default` (the version flagged `default: true`, else the earliest — a movable stable pin a bare/unqualified route can honor so it never jumps when a new version lands).

The MCP-latest vs bare-path-pinned asymmetry is intentional: a fresh model call wants newest; a long-lived HTTP client wants stability. Choosing `latest` vs `default` is the adapter's projection policy — core just resolves both.

### Filesystem convention

`tool_version N` is the sole source of truth for the number — nothing derives version from the filesystem. The recommended layout is a convention with no magic:

- **Single version: stay flat** — `agent_tools/approve_loan.rb`.
- **Second version: promote to a folder** — rename to `agent_tools/approve_loan/v1.rb` (declaring `tool_version 1`) and add `v2.rb` (`tool_version 2`). With no `approve_loan.rb`, Zeitwerk treats `approve_loan/` as a namespace module (`AgentTools::ApproveLoan`) and nests `::V1`/`::V2`; the module itself is not a tool (it does not `include Axn`).

When a class declares `tool_version` and its constant ends in a `::Vn` segment, `tool_name` derives from the enclosing namespace (`AgentTools::ApproveLoan::V2` → `"approve_loan"`), so both versions group. The promotion moves the Ruby constant but not the wire contract — identity stays `tool_name`. Two guardrails keep the convention honest: a `::Vn` constant that declares no `tool_version` raises (so a promoted `v1.rb` can't silently orphan itself), and a `::V2` constant declaring a different number (`tool_version 3`) raises.
````

- [ ] **Step 2: Add CHANGELOG entries**

In `CHANGELOG.md`, under `## Unreleased`, add a `### Tools & adapters` subsection (or append to it if one already exists) with:

```markdown
### Tools & adapters

* [FEAT] `tool_version N` declares a tool's contract version (a first-class core attribute, sibling of `tool_name`). Absent ⇒ version 1 and the default. Multiple versions of one logical tool coexist by sharing a `tool_name`; the registry identity is `(tool_name, tool_version)`.
* [FEAT] `Axn.tools_for(adapter)` now returns the latest version per `tool_name` (unchanged for unversioned tools). `Axn.tools_for(adapter, all_versions: true)` enumerates every version, and `Axn.versions_for(adapter, tool_name)` returns the version group (`.all` / `.latest` / `.default`, where `default: true` moves the otherwise-earliest stable pin).
* [FEAT] When a class declares `tool_version` and its constant ends in a `::Vn` segment (`AgentTools::ApproveLoan::V2`), `tool_name` derives from the enclosing namespace (`"approve_loan"`) so versions group under one name. A `::Vn` constant with no `tool_version`, or a `::V2` declaring a mismatched number, raises.
```

- [ ] **Step 3: Verify docs build / no broken references (optional but recommended)**

If a docs build is configured, run it (e.g. `npm --prefix docs run build` or the repo's documented command) and confirm the new section renders. Otherwise, visually confirm the Markdown is well-formed and the code fences are balanced.

- [ ] **Step 4: Commit**

```bash
git add docs/recipes/authoring-tool-adapters.md CHANGELOG.md
git commit -m "PRO-2955: document tool_version + versioned enumeration"
```

---

## Self-Review

**Spec coverage:**
- `tool_version` DSL + validation + `default:` → Task 1.
- `version` left free (no bare-`version` method defined) → Task 1 defines only `tool_version`; no code claims `version`.
- Option-B `::Vn` derivation + both `::Vn` guards → Task 1 (mismatch, at declaration) + Task 2 (no-`tool_version`, at enumeration).
- `(tool_name, tool_version)` identity + relaxed uniqueness → Task 3 (`VersionGroup#_validate!`) + Task 4 (removal of `_assert_unique_tool_names!`).
- `latest` / `default` single-resolver → Task 3.
- `tools_for` latest default + `all_versions:` + `versions_for` → Task 4.
- Filesystem convention + reader-availability docs → Task 5.
- Reflection: no central tool-descriptor reflection exists today (adapters read `tool_name`/`semantic_hints`/`_semantic_hints` off the class directly), so `tool_version` needs no reflection plumbing beyond being a public reader — provided by Task 1. No separate task required.
- Out-of-scope items (adapter projection, per-adapter `default`, filename→version) — intentionally no tasks.

**Placeholder scan:** No TBD/TODO; every code step shows complete code and exact commands.

**Type consistency:** `tool_version` (reader/setter), `_tool_version` / `_tool_version_default` (attributes), `VersionGroup.new(adapter:, tool_name:, members:)` with `#all`/`#latest`/`#default`, `tools_for(adapter, all_versions:)`, `versions_for(adapter, tool_name)` are used identically across Tasks 1–5. `VERSION_SEGMENT` is defined in Task 1 and referenced fully-qualified in Task 2.
