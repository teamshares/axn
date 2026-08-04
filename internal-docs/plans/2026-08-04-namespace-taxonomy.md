# Namespace Taxonomy Cleanup Implementation Plan (PRO-2997)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give axn one rescuable error root (`Axn::Error`) whose inclusion declares the public-error boundary, stop six public exception classes from inheriting out of `Axn::Internal`, move four non-reflection modules out of `Axn::Internal::Reflection`, and add a supported spec-reset seam so host apps stop poking internal ivars.

**Architecture:** `Axn::Error` is a marker **module** included into every public exception, never a base class — `rescue` matches modules by `is_a?`, so the root costs no inheritance surgery and lets a sibling gem keep whatever superclass its own ecosystem needs. Membership is enforced by a policy spec that pins the exact set of *untagged* exception classes, so both an untagged public error and a tagged internal one fail CI. The `Internal::Reflection` moves are pure relocations validated by the existing suite plus `spec/axn/standalone_require_spec.rb`, which derives each file's constant references from its parse tree and so catches a missed require automatically.

**Tech Stack:** Ruby 3.3.6 (CI also runs 3.2/3.4), RSpec, ActiveSupport. No new dependencies.

## Global Constraints

- Spec of record: `internal-docs/specs/2026-08-04-namespace-taxonomy-design.md`. Read it before starting.
- `Axn::Failure` is **deliberately not tagged** with `Axn::Error`. It is a control-flow signal from `call!`, not a fault. Do not tag it, and do not "fix" its absence.
- `Axn::Internal::EarlyCompletion` and `Axn::Internal::Registry::{NotFound, DuplicateError}` are **deliberately not tagged**. They are internal.
- `Axn::Testing.reset!` must **not** touch `Axn.config`, `Axn::Extensions.config`, or the three registries (`Strategies`, `Async::Adapters`, `Mountable::MountingStrategies`). Resetting those would silently un-configure a host app's suite after the first example.
- `lib/axn/error.rb` must have **zero requires**. It is loaded by `lib/axn/exceptions.rb`, which sits near the bottom of the dependency graph; any require in it risks a cycle. Same discipline as `lib/axn/internal/text.rb`.
- No hard-wrapping of Markdown prose in docs — one line per paragraph (repo convention).
- Comments describe current behavior and intrinsic why. Never "used to X / now Y", never "(PRO-2997)" attributions in code.
- Never assert `Hash#inspect` output text in a spec — Ruby 3.4 changed its spacing and CI runs 3.4.
- Run the suite with `bundle exec rspec`. `spec_rails/` needs its own bundle: `(cd spec_rails/dummy_app && bundle exec rspec spec)`.

## File Structure

**Created:**
- `lib/axn/error.rb` — the `Axn::Error` marker module. Zero requires, zero methods.
- `lib/axn/testing.rb` — `Axn::Testing.reset!`. Requirable without the RSpec-shaped helpers.
- `lib/axn/internal/coercion.rb` — moved from `lib/axn/internal/reflection/coercion.rb`.
- `lib/axn/internal/subfield_tree.rb` — moved from `lib/axn/internal/reflection/subfield_tree.rb`.
- `lib/axn/internal/resolved_subfields.rb` — moved from `lib/axn/internal/reflection/resolved_subfields.rb`.
- `lib/axn/core/contract/subfield_contradictions.rb` — moved from `lib/axn/internal/reflection/subfield_contradictions.rb`.
- `spec/axn/error_policy_spec.rb` — pins the tagged/untagged partition.
- `spec/axn/testing/reset_spec.rb` — covers `Axn::Testing.reset!`.

**Modified:**
- `lib/axn/exceptions.rb` — require the marker; tag `ContractViolation`, `UnsupportedArgument`, `UnreraisableException`→`ReraiseFailed`, `Mountable::MountingError`, `Tools::InvalidContract`, `Extensions::Serialization::UnserializableValue`, `Async::UnserializableArgument`; nest `DuplicateFieldError`.
- `lib/axn/strategies.rb`, `lib/axn/async/adapters.rb`, `lib/axn/mountable/mounting_strategies.rb` — drop the `Internal::Registry::*` ancestry, tag with the marker.
- `lib/axn/async/enqueue_all_orchestrator.rb`, `lib/axn/async/adapters/sidekiq/auto_configure.rb` — tag two stragglers.
- `lib/axn/internal/reflection.rb` — drop the moved modules from its requires and rewrite its header.
- `lib/axn/core/nesting_tracking.rb` — add a reset for `@_isolation_mismatch_warned`.
- `lib/axn/testing/spec_helpers.rb` — require `axn/testing`.
- `spec/spec_helper.rb` — call `Axn::Testing.reset!` in place of `Tools::Registry.reset_adapters!`.
- `spec/axn/namespace_policy_spec.rb` — add `Error` and `DuplicateFieldError` changes to the reserved list.
- `spec/axn/standalone_require_spec.rb` — update the `subfield_tree.rb` path in `upward_references`.
- `AGENTS.md` — line 64's reflection membership; the `Axn::Error` rule.
- `CHANGELOG.md` — under the existing `## 0.1.0-alpha.5` heading (bumped, untagged, so it *is* the unreleased section).

---

### Task 1: `Axn::Error` marker module, and tag everything in `exceptions.rb`

**Files:**
- Create: `lib/axn/error.rb`
- Modify: `lib/axn/exceptions.rb`
- Test: `spec/axn/error_spec.rb` (create)

**Interfaces:**
- Consumes: nothing.
- Produces: `Axn::Error` — an empty module, included into public exception classes. `rescue Axn::Error` matches any tagged exception. Later tasks include it in classes defined outside `exceptions.rb`.

- [ ] **Step 1: Write the failing test**

Create `spec/axn/error_spec.rb`:

```ruby
# frozen_string_literal: true

RSpec.describe Axn::Error do
  it "is a module, not a class, so a gem can keep its own superclass" do
    expect(described_class).to be_a(Module)
    expect(described_class).not_to be_a(Class)
  end

  # The whole point: one rescue for anything axn objected to, whatever it descends from.
  it "catches a tagged exception rooted at StandardError" do
    expect { raise Axn::ContractViolation::MethodNotAllowed, "nope" }.to raise_error(Axn::Error)
  end

  it "catches a tagged exception rooted at ArgumentError" do
    expect { raise Axn::UnsupportedArgument, "some feature" }.to raise_error(Axn::Error)
  end

  it "leaves the tagged class's own ancestry intact" do
    expect(Axn::UnsupportedArgument.ancestors).to include(ArgumentError)
    expect(Axn::InboundValidationError.ancestors).to include(Axn::ContractViolation)
  end

  # Failure is a control-flow signal from call!, not a fault. Tagging it would make
  # `rescue Axn::Error` catch the INTENDED outcome while still missing an unintended
  # NoMethodError from the action body.
  it "does not catch Axn::Failure" do
    expect(Axn::Failure.include?(described_class)).to be(false)
  end

  it "does not catch internal-only exceptions" do
    expect(Axn::Internal::EarlyCompletion.include?(described_class)).to be(false)
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bundle exec rspec spec/axn/error_spec.rb`
Expected: FAIL with `NameError: uninitialized constant Axn::Error`.

- [ ] **Step 3: Create the marker module**

Create `lib/axn/error.rb`. **Zero requires** — this file is loaded by `exceptions.rb`, which sits near the bottom of the dependency graph.

```ruby
# frozen_string_literal: true

module Axn
  # The public-error boundary, as a MODULE rather than a base class: `rescue` matches a module by
  # `is_a?`, so tagging a class gives callers `rescue Axn::Error` without touching its ancestry.
  #
  # That is what makes the tag usable everywhere it needs to be. Four core errors are deliberately
  # `ArgumentError`s, and an adapter gem may need its own base to be a `Faraday::Error` or a
  # `Timeout::Error` for its ecosystem's interop — a base class would force each of them to choose
  # between the superclass they need and being catchable as an axn error. A module forces nothing.
  #
  # Inclusion IS the boundary declaration, not a blanket sweep over everything axn raises: a class
  # that includes this is public, documented, rescuable, and breaking to remove, and one that does not
  # is either internal or (in the single case of `Axn::Failure`) deliberately excluded. That makes the
  # boundary per-class and explicit rather than inferred from which directory a file sits in, and
  # `spec/axn/error_policy_spec.rb` pins the exact partition so neither an untagged public error nor a
  # tagged internal one can land.
  #
  # `Axn::Failure` is the deliberate exclusion. It is a control-flow signal raised by `call!`, not a
  # fault, so tagging it would make `rescue Axn::Error` around a `call!` catch the INTENDED outcome
  # while still missing an unintended `NoMethodError` from the action body — a net whose partiality is
  # the confusing part. Untagged, the three outcomes stay legible: `Axn::Error` means axn objected,
  # `Axn::Failure` means the action deliberately failed, anything else means the body blew up. A caller
  # who wants all three writes `rescue StandardError`.
  #
  # A gem building on axn roots its own hierarchy here:
  #
  #   module Axn::Webhooks
  #     class Error < StandardError
  #       include Axn::Error
  #     end
  #     class RetryLater < Error; end
  #   end
  #
  # The tag is inherited, so a tagged class cannot have an untagged subclass. That is deliberate: a
  # public error family should not have secretly-internal members.
  module Error; end
end
```

- [ ] **Step 4: Tag the exceptions defined in `exceptions.rb`**

Add the require at the top of `lib/axn/exceptions.rb`, alongside the three already there:

```ruby
require "axn/error"
```

Then add `include Axn::Error` as the first line of each of these class bodies. Do **not** touch `Axn::Failure` or `Axn::Internal::EarlyCompletion`.

- `Axn::ContractViolation` — one include covers all thirteen descendants (`ValidationError`, `InboundValidationError`, `OutboundValidationError`, `Tools::InvalidContract`, `DuplicateFieldError`, and the eight nested)
- `Axn::UnreraisableException`
- `Axn::UnsupportedArgument`
- `Axn::Mountable::MountingError`
- `Axn::Extensions::Serialization::UnserializableValue`
- `Axn::Async::UnserializableArgument`

For example:

```ruby
  class ContractViolation < StandardError
    include Axn::Error
```

- [ ] **Step 5: Run the new spec and the full suite**

Run: `bundle exec rspec spec/axn/error_spec.rb && bundle exec rspec`
Expected: both PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/axn/error.rb lib/axn/exceptions.rb spec/axn/error_spec.rb
git commit -m "PRO-2997: Axn::Error is the rescuable public-error root

A marker module rather than a base class, so tagging a class costs it no
ancestry: rescue matches a module by is_a?, four core errors are deliberately
ArgumentErrors, and an adapter gem may need its own base to be a Faraday::Error
for its ecosystem's interop.

Axn::Failure stays untagged — a control-flow signal from call!, not a fault, and
tagging it would catch the intended outcome while missing an unintended
NoMethodError from the action body."
```

---

### Task 2: Delete the `Internal::Registry::*` ancestry from the six public registry errors

**Files:**
- Modify: `lib/axn/strategies.rb:6-7`
- Modify: `lib/axn/async/adapters.rb:8-9`
- Modify: `lib/axn/mountable/mounting_strategies.rb:7-8`
- Test: `spec/axn/error_spec.rb` (extend)

**Interfaces:**
- Consumes: `Axn::Error` from Task 1.
- Produces: `Axn::StrategyNotFound`, `Axn::DuplicateStrategyError`, `Axn::Async::AdapterNotFound`, `Axn::Async::DuplicateAdapterError`, `Axn::Mountable::MountingTypeNotFound`, `Axn::Mountable::DuplicateMountingTypeError` — all now `< StandardError` with the marker, none inheriting out of `Axn::Internal`.

Context for the implementer: all three registries already override **both** `not_found_error_class` and `duplicate_error_class` (`strategies.rb:16-17`, `async/adapters.rb:18-19`, `mounting_strategies.rb:17-18`), so `Internal::Registry::{NotFound, DuplicateError}` are never raised through these paths. Nothing in `lib/`, `spec/`, or any downstream gem or app raises or rescues them. They exist *only* as ancestors, and that ancestry is the leak. The two base classes stay in `internal/registry.rb` as the registry's own defaults — do not delete them.

- [ ] **Step 1: Write the failing test**

Append to `spec/axn/error_spec.rb`, inside the top-level `describe`:

```ruby
  # A public class must not inherit out of Axn::Internal: it puts an internal constant in a
  # documented class's ancestry, and makes that constant the only way to express "any registry
  # lookup miss". rescue Axn::Error is that expression now.
  describe "registry errors" do
    subject(:registry_errors) do
      [Axn::StrategyNotFound, Axn::DuplicateStrategyError,
       Axn::Async::AdapterNotFound, Axn::Async::DuplicateAdapterError,
       Axn::Mountable::MountingTypeNotFound, Axn::Mountable::DuplicateMountingTypeError]
    end

    it "have no Axn::Internal constant in their ancestry" do
      leaked = registry_errors.reject do |klass|
        klass.ancestors.grep(Class).none? { |a| a.name.to_s.start_with?("Axn::Internal") }
      end
      expect(leaked).to be_empty
    end

    it "are all catchable as Axn::Error" do
      expect(registry_errors.reject { |k| k.include?(Axn::Error) }).to be_empty
    end

    it "still descend from StandardError" do
      expect(registry_errors.reject { |k| k <= StandardError }).to be_empty
    end
  end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bundle exec rspec spec/axn/error_spec.rb -e "registry errors"`
Expected: FAIL — the ancestry example reports all six, and the marker example reports all six.

- [ ] **Step 3: Reparent and tag**

In `lib/axn/strategies.rb`, replace lines 6-7:

```ruby
  # Deliberately NOT descended from the registry's internal base classes: a public class must not put
  # an Axn::Internal constant in its ancestry, and "any registry lookup miss" is `rescue Axn::Error`.
  class StrategyNotFound < StandardError
    include Axn::Error
  end

  class DuplicateStrategyError < StandardError
    include Axn::Error
  end
```

In `lib/axn/async/adapters.rb`, replace lines 8-9 with the same shape for `AdapterNotFound` and `DuplicateAdapterError` (carry the comment once, above the pair).

In `lib/axn/mountable/mounting_strategies.rb`, replace lines 7-8 with the same shape for `MountingTypeNotFound` and `DuplicateMountingTypeError`.

Each of those three files needs `require "axn/error"` if it does not already resolve `Axn::Error`. Check with `bundle exec rspec spec/axn/standalone_require_spec.rb`, which derives each file's constant references from its parse tree and fails on an unresolved one.

- [ ] **Step 4: Run the specs**

Run: `bundle exec rspec spec/axn/error_spec.rb spec/axn/standalone_require_spec.rb && bundle exec rspec`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/axn/strategies.rb lib/axn/async/adapters.rb lib/axn/mountable/mounting_strategies.rb spec/axn/error_spec.rb
git commit -m "PRO-2997: no public exception inherits out of Axn::Internal

Six public registry errors descended from Axn::Internal::Registry::{NotFound,
DuplicateError}, which put an internal constant in a documented class's ancestry
and made it the only way to express 'any registry lookup miss'.

All three registries already override both error classes, and nothing in lib,
spec, or any downstream gem raises or rescues the bases — they were ancestors and
nothing else. Closed by removal rather than by coining a public name for an unused
capability; rescue Axn::Error covers the lost query. The bases stay in
internal/registry.rb as its own defaults."
```

---

### Task 3: Tag the two stragglers, and pin the partition with a policy spec

**Files:**
- Modify: `lib/axn/async/enqueue_all_orchestrator.rb:8`
- Modify: `lib/axn/async/adapters/sidekiq/auto_configure.rb:150`
- Test: `spec/axn/error_policy_spec.rb` (create)

**Interfaces:**
- Consumes: `Axn::Error` from Task 1.
- Produces: `spec/axn/error_policy_spec.rb` — the invariant that later tasks (which rename and move exception classes) are checked against.

- [ ] **Step 1: Write the failing test**

Create `spec/axn/error_policy_spec.rb`:

```ruby
# frozen_string_literal: true

require "axn/testing/spec_helpers"

# Every Exception subclass reachable under Axn:: either includes Axn::Error — public, documented,
# rescuable, breaking to remove — or is deliberately excluded. The exclusions are pinned by name
# rather than by a namespace predicate, so adding one is a visible decision in this file.
RSpec.describe "Axn exception tagging" do
  # rubocop:disable Lint/ConstantDefinitionInBlock
  #
  # Axn::Failure is a control-flow signal from call!, not a fault: tagging it would make
  # `rescue Axn::Error` catch the intended outcome while still missing an unintended NoMethodError
  # from the action body. The other three are internal — EarlyCompletion is rescued before a Result
  # is returned and never escapes, and the two Registry bases are unreachable defaults now that no
  # public class descends from them.
  UNTAGGED = %w[
    Axn::Failure
    Axn::Internal::EarlyCompletion
    Axn::Internal::Registry::NotFound
    Axn::Internal::Registry::DuplicateError
  ].freeze
  # rubocop:enable Lint/ConstantDefinitionInBlock

  def self.exception_classes
    found = []
    walk = lambda do |mod, seen|
      mod.constants(false).each do |const|
        value = begin
          mod.const_get(const, false)
        rescue StandardError, ScriptError
          next
        end
        next unless value.is_a?(Module)
        next unless seen.add?(value.object_id)
        next unless value.name.to_s.start_with?("Axn")

        found << value if value.is_a?(Class) && value <= Exception
        walk.call(value, seen)
      end
    end
    walk.call(Axn, Set.new)
    found
  end

  let(:all_exceptions) { self.class.exception_classes }

  it "finds the exception classes at all (guards against a walk that silently matches nothing)" do
    expect(all_exceptions.size).to be >= 25
  end

  it "tags every exception class except the pinned exclusions" do
    untagged = all_exceptions.reject { |k| k.include?(Axn::Error) }.map { |k| k.name.to_s }.sort
    expect(untagged).to eq(UNTAGGED.sort)
  end

  it "keeps every pinned exclusion reachable, so a rename cannot leave a stale entry here" do
    missing = UNTAGGED.reject { |name| all_exceptions.any? { |k| k.name.to_s == name } }
    expect(missing).to be_empty, "pinned as untagged but no longer defined: #{missing.inspect}"
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bundle exec rspec spec/axn/error_policy_spec.rb`
Expected: FAIL on the tagging example, reporting `Axn::Async::MissingEnqueuesEachError` and `Axn::Async::Adapters::Sidekiq::ConfigurationError` as unexpectedly untagged.

- [ ] **Step 3: Tag the two stragglers**

In `lib/axn/async/enqueue_all_orchestrator.rb:8`:

```ruby
    class MissingEnqueuesEachError < StandardError
      include Axn::Error
    end
```

In `lib/axn/async/adapters/sidekiq/auto_configure.rb:150`:

```ruby
        class ConfigurationError < StandardError
          include Axn::Error
        end
```

- [ ] **Step 4: Run the specs**

Run: `bundle exec rspec spec/axn/error_policy_spec.rb spec/axn/standalone_require_spec.rb && bundle exec rspec`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/axn/async/enqueue_all_orchestrator.rb lib/axn/async/adapters/sidekiq/auto_configure.rb spec/axn/error_policy_spec.rb
git commit -m "PRO-2997: pin the tagged/untagged exception partition

Walks every Exception subclass under Axn:: and asserts the untagged set is
exactly the four deliberate exclusions. Fails on an untagged public error, on a
tagged internal one, and on a stale exclusion entry left behind by a rename —
which is what makes the following renames safe."
```

---

### Task 4: `DuplicateFieldError` joins its siblings under `ContractViolation`

**Files:**
- Modify: `lib/axn/exceptions.rb:221`
- Test: existing suite + `spec/axn/namespace_policy_spec.rb`

**Interfaces:**
- Consumes: `Axn::ContractViolation` (already tagged, Task 1).
- Produces: `Axn::ContractViolation::DuplicateFieldError`. `Axn::DuplicateFieldError` no longer exists.

Context: verified zero references in executable Ruby across all six sibling gems and three apps, so this breaks nothing downstream. It is pinned in `spec/axn/namespace_policy_spec.rb`'s `RESERVED` list, which must be updated in the same commit.

- [ ] **Step 1: Find every reference**

Run: `grep -rn "DuplicateFieldError" lib spec spec_rails docs internal-docs AGENTS*.md`

Note the count before editing so you can confirm none were missed.

- [ ] **Step 2: Write the failing test**

Add to `spec/axn/error_policy_spec.rb`, inside the top-level `describe`:

```ruby
  it "nests DuplicateFieldError with its ContractViolation siblings" do
    expect(Axn::ContractViolation.const_defined?(:DuplicateFieldError, false)).to be(true)
    expect(Axn.const_defined?(:DuplicateFieldError, false)).to be(false)
  end
```

- [ ] **Step 3: Run it to verify it fails**

Run: `bundle exec rspec spec/axn/error_policy_spec.rb -e "nests DuplicateFieldError"`
Expected: FAIL — the constant is still at top level.

- [ ] **Step 4: Move the class**

In `lib/axn/exceptions.rb`, delete line 221 (`class DuplicateFieldError < ContractViolation; end`) and add it inside the `ContractViolation` body, after `MethodCallNotPermittedError`:

```ruby
    class DuplicateFieldError < ContractViolation; end
```

Then update every reference found in Step 1 to `Axn::ContractViolation::DuplicateFieldError`. Remove `DuplicateFieldError` from the `RESERVED` array in `spec/axn/namespace_policy_spec.rb`.

Note: `lib/axn/tools.rb`'s `InvalidContract` comment names "an ordinary ArgumentError or DuplicateFieldError included" — update that prose too.

- [ ] **Step 5: Run the full suite**

Run: `bundle exec rspec`
Expected: PASS. Then `(cd spec_rails/dummy_app && bundle exec rspec spec)` — also PASS.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "PRO-2997: DuplicateFieldError nests with its ContractViolation siblings

It sat alone at top level while its eight siblings nested under the class it
descends from. Zero references in executable Ruby across all six sibling gems and
three apps, so nothing downstream moves with it."
```

---

### Task 5: `UnreraisableException` → `Axn::ReraiseFailed`

**Files:**
- Modify: `lib/axn/exceptions.rb:291`
- Modify: `lib/axn/extensions.rb` (the `_reraise_for_dev` raise site)
- Test: existing suite

**Interfaces:**
- Consumes: `Axn::Error` (Task 1).
- Produces: `Axn::ReraiseFailed`. `Axn::UnreraisableException` no longer exists.

Context: the old name describes the *original* exception (the one `raise` could not hand back) while the object it names is the *substitute*, so `rescue Axn::UnreraisableException` reads as "catch the exception that could not be re-raised" — precisely the thing that cannot be caught, because it was replaced. `Unreraisable` also stacks un- + re- + raisable, which CamelCase gives no help parsing. Zero downstream references.

- [ ] **Step 1: Find every reference**

Run: `grep -rn "UnreraisableException" lib spec spec_rails docs internal-docs AGENTS*.md CHANGELOG.md`

- [ ] **Step 2: Write the failing test**

Add to `spec/axn/error_policy_spec.rb`, inside the top-level `describe`:

```ruby
  it "names the substitute for what happened, not for the exception it replaced" do
    expect(Axn.const_defined?(:ReraiseFailed, false)).to be(true)
    expect(Axn.const_defined?(:UnreraisableException, false)).to be(false)
  end
```

- [ ] **Step 3: Run it to verify it fails**

Run: `bundle exec rspec spec/axn/error_policy_spec.rb -e "names the substitute"`
Expected: FAIL — `ReraiseFailed` is not defined.

- [ ] **Step 4: Rename**

In `lib/axn/exceptions.rb`, rename the class at line 291 to `ReraiseFailed`. Keep the whole header comment and the `include Axn::Error` from Task 1. The message body interpolates `self.class`, so its text follows the rename with no edit.

Update the raise site in `lib/axn/extensions.rb#_reraise_for_dev`, the `best_effort` docstring above it that names the class, the `SWALLOWABLE_BEYOND_STANDARD_ERROR` prose in `AGENTS.md` if it names it, and every spec reference from Step 1.

- [ ] **Step 5: Run the full suite**

Run: `bundle exec rspec && (cd spec_rails/dummy_app && bundle exec rspec spec)`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "PRO-2997: UnreraisableException is Axn::ReraiseFailed

The old name described the ORIGINAL exception — the one raise could not hand back
— while the object it names is the substitute, so 'rescue UnreraisableException'
read as catching precisely the thing that cannot be caught, because it was
replaced. ReraiseFailed names what happened.

BestEffortError was considered and rejected as misleading: best_effort did not
fail, only the re-raise fidelity degraded."
```

---

### Task 6: Move `Coercion` out of `Internal::Reflection` — file move only

**Files:**
- Move: `lib/axn/internal/reflection/coercion.rb` → `lib/axn/internal/coercion.rb`
- Move: `spec/axn/internal/reflection/coercion_spec.rb` → `spec/axn/internal/coercion_spec.rb`
- Modify: require sites (`lib/axn/internal/reflection.rb:3`, and any other `require "axn/internal/reflection/coercion"`)

**Interfaces:**
- Consumes: nothing.
- Produces: the files at their new paths, still defining `Axn::Internal::Reflection::Coercion`. The constant moves in Task 7.

This task is **deliberately mechanical and contains no constant edits.** A rename that also re-indents defeats git's rename detection, so the move and the nesting change are separate commits.

- [ ] **Step 1: Move both files with git**

```bash
git mv lib/axn/internal/reflection/coercion.rb lib/axn/internal/coercion.rb
git mv spec/axn/internal/reflection/coercion_spec.rb spec/axn/internal/coercion_spec.rb
```

- [ ] **Step 2: Update every require path**

Run `grep -rn 'axn/internal/reflection/coercion' lib spec spec_rails` and change each to `axn/internal/coercion`. As of writing that is `lib/axn/internal/reflection.rb:3`.

- [ ] **Step 3: Run the suite to confirm the move alone changed nothing**

Run: `bundle exec rspec`
Expected: PASS. The constant is still `Axn::Internal::Reflection::Coercion` — only the file location changed.

- [ ] **Step 4: Commit, verifying git recorded a rename**

```bash
git add -A
git commit -m "PRO-2997: move coercion.rb out of the reflection directory

File move only, no constant or nesting change, so git records a rename and the
next commit's diff is just the nesting."
git show --stat --find-renames HEAD
```

Expected in the output: `rename` lines for both files, not a delete-plus-add pair. If git shows delete+add, the indentation changed — undo and redo the move without touching contents.

---

### Task 7: `Internal::Reflection::Coercion` → `Internal::Coercion`

**Files:**
- Modify: `lib/axn/internal/coercion.rb` (drop one nesting level, rewrite the false header)
- Modify: `lib/axn/core/contract.rb`, `lib/axn/core/contract_for_subfields.rb`, `lib/axn/core/executor.rb`
- Modify: `spec/axn/internal/coercion_spec.rb` and any other spec naming the constant

**Interfaces:**
- Consumes: the moved file from Task 6.
- Produces: `Axn::Internal::Coercion`, with the same module functions — `coerce_value`, `coerce_boolean`, `already_valid_for_target?`, `coercible_klasses`, `field_coerces?`, `coerce_config_value` — and the same public `SUPPORTED` constant. `Axn::Internal::Reflection::Coercion` no longer exists.

- [ ] **Step 1: Write the failing test**

Add to `spec/axn/internal/coercion_spec.rb`, at the top of its outermost describe:

```ruby
  it "is a value-level mechanism at Internal::, not a member of the reflection layer" do
    expect(Axn::Internal.const_defined?(:Coercion, false)).to be(true)
    expect(Axn::Internal::Reflection.const_defined?(:Coercion, false)).to be(false)
  end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bundle exec rspec spec/axn/internal/coercion_spec.rb -e "value-level mechanism"`
Expected: FAIL — `Axn::Internal::Reflection::Coercion` is still where it was.

- [ ] **Step 3: Drop the nesting level and rewrite the header**

In `lib/axn/internal/coercion.rb`, remove the `module Reflection` wrapper (and its `end`), and outdent the body by one level.

Replace the module header. The current text is **false** on two counts — it runs inside validation from three `Core::` call sites, and no adapter calls it (verified across all four sibling gems). Write:

```ruby
      # Inbound wire DECODER — the parse-based inverse of Internal::Reflection::Values.serialize_value,
      # keyed off the same class set so encoder and decoder cannot drift. The single home for the
      # wire→Ruby mapping a `coerce:` field runs through.
      #
      # At Internal:: rather than in the reflection layer because it is a value-level mechanism with no
      # presence in the action's surface, and because it runs INSIDE validation — the contract's
      # declaration check, the executor, and ContractForSubfields.resolve_value's read-path transforms
      # are its only callers. The reflection layer derives a JSON view of a contract off the execution
      # path, which is the opposite of what this does.
      #
      # Its encoder counterpart stays in that layer, because the two have different audiences: the
      # encoder renders a result for a serializing adapter, this decodes input during validation. What
      # must not drift is the CLASS SET both are keyed off, which is an obligation of these two headers
      # rather than of a shared namespace — a namespace never enforced it.
```

Then update the constant at every call site. Run `grep -rn "Reflection::Coercion" lib spec spec_rails internal-docs` and change each to `Internal::Coercion` (adjusting for lexical nesting — inside `module Axn; module Internal` a bare `Coercion` resolves).

- [ ] **Step 4: Run the suite**

Run: `bundle exec rspec spec/axn/standalone_require_spec.rb && bundle exec rspec`
Expected: PASS. `standalone_require_spec` derives each file's constant references from its parse tree, so it catches a call site left pointing at the old path.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "PRO-2997: Coercion is Internal::Coercion, not part of the reflection layer

A value-level wire decoder with no presence in the action's surface, whose only
callers are the contract, the executor, and the subfield read path — it runs
INSIDE validation, which is the opposite of what the reflection layer does.

Its header claimed 'read-only, off the execution path' and that adapters call it.
Both were false: three Core:: call sites run it during validation, and no adapter
references it in any of the four sibling gems. Same defect PRO-2992 corrected in
the Reflection module doc one file over."
```

---

### Task 8: Move `SubfieldTree` and `ResolvedSubfields` to `Internal::`

**Files:**
- Move: `lib/axn/internal/reflection/subfield_tree.rb` → `lib/axn/internal/subfield_tree.rb`
- Move: `lib/axn/internal/reflection/resolved_subfields.rb` → `lib/axn/internal/resolved_subfields.rb`
- Move: `spec/axn/internal/reflection/subfield_tree_spec.rb` → `spec/axn/internal/subfield_tree_spec.rb`
- Modify: `lib/axn/internal/reflection.rb`, `lib/axn/core/ambient_context.rb:3`, `lib/axn/core/contract_for_subfields.rb:4`, `lib/axn/internal/reflection/schema.rb:6`, `lib/axn/internal/reflection/property_names.rb`, `lib/axn/internal/reflection/subfield_contradictions.rb:3`
- Modify: `spec/axn/standalone_require_spec.rb` — the `upward_references` entry

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `Axn::Internal::SubfieldTree` and `Axn::Internal::ResolvedSubfields`, same public API. The `Reflection::` spellings no longer exist.

Rationale for the implementer: these two are used by `Core::` **and** by `Internal::Reflection::PropertyNames`. AGENTS.md:66's test for `Core::Contract::X` is "machinery one layer owns and that is meaningless outside it," which fails on its own terms here — two layers means `Internal::X` per AGENTS.md:63.

- [ ] **Step 1: Move the files (commit 1 of 2)**

```bash
git mv lib/axn/internal/reflection/subfield_tree.rb lib/axn/internal/subfield_tree.rb
git mv lib/axn/internal/reflection/resolved_subfields.rb lib/axn/internal/resolved_subfields.rb
git mv spec/axn/internal/reflection/subfield_tree_spec.rb spec/axn/internal/subfield_tree_spec.rb
```

Update every require path: `grep -rn 'axn/internal/reflection/\(subfield_tree\|resolved_subfields\)' lib spec spec_rails` and drop the `reflection/` segment in each.

Also update the path in `spec/axn/standalone_require_spec.rb`'s `upward_references`:

```ruby
      ["axn/internal/subfield_tree.rb", "Schema"],
```

- [ ] **Step 2: Run the suite, then commit the move**

Run: `bundle exec rspec`
Expected: PASS — constants unchanged.

```bash
git add -A
git commit -m "PRO-2997: move subfield_tree.rb and resolved_subfields.rb out of the reflection directory

File moves only, so git records renames and the next commit's diff is the nesting."
git show --stat --find-renames HEAD
```

Confirm `rename` lines rather than delete+add.

- [ ] **Step 3: Write the failing test (commit 2 of 2)**

Add to `spec/axn/internal/subfield_tree_spec.rb`, at the top of its outermost describe:

```ruby
  it "lives at Internal::, being used by both the contract layer and the reflection layer" do
    expect(Axn::Internal.const_defined?(:SubfieldTree, false)).to be(true)
    expect(Axn::Internal.const_defined?(:ResolvedSubfields, false)).to be(true)
    expect(Axn::Internal::Reflection.const_defined?(:SubfieldTree, false)).to be(false)
    expect(Axn::Internal::Reflection.const_defined?(:ResolvedSubfields, false)).to be(false)
  end
```

- [ ] **Step 4: Run it to verify it fails**

Run: `bundle exec rspec spec/axn/internal/subfield_tree_spec.rb -e "lives at Internal::"`
Expected: FAIL.

- [ ] **Step 5: Drop the nesting and update call sites**

In both moved lib files, remove the `module Reflection` wrapper and outdent the body one level.

Then `grep -rn "Reflection::SubfieldTree\|Reflection::ResolvedSubfields" lib spec spec_rails internal-docs` and update each to the `Internal::` spelling. Call sites are `lib/axn/core/ambient_context.rb`, `lib/axn/core/contract_for_subfields.rb`, `lib/axn/internal/reflection/property_names.rb`, `lib/axn/internal/reflection/schema.rb`, `lib/axn/internal/reflection/subfield_contradictions.rb`, plus `spec/axn/core/resolved_subfields_cache_spec.rb`.

Watch the lexical nesting: inside `module Axn; module Internal; module Reflection`, a bare `SubfieldTree` used to resolve to the sibling. It now needs `Internal::SubfieldTree` or a bare `SubfieldTree` that resolves one level out — `standalone_require_spec` will tell you if you got it wrong.

- [ ] **Step 6: Run the suite**

Run: `bundle exec rspec spec/axn/standalone_require_spec.rb && bundle exec rspec && (cd spec_rails/dummy_app && bundle exec rspec spec)`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "PRO-2997: SubfieldTree and ResolvedSubfields are Internal::, not reflection

Both are used by the contract layer AND by Reflection::PropertyNames, so
AGENTS.md's test for Core::Contract:: — machinery one layer owns and that is
meaningless outside it — fails on its own terms. Two layers means Internal::."
```

---

### Task 8b: Make `Internal::SubfieldTree` genuinely layer-free

**Files:**
- Modify: `lib/axn/internal/subfield_tree.rb`
- Modify: `lib/axn/internal/reflection/schema.rb`
- Modify: `lib/axn/internal/resolved_subfields.rb`
- Modify: `spec/axn/internal/subfield_tree_spec.rb`
- Test: existing suite

**Interfaces:**
- Consumes: `Axn::Internal::SubfieldTree` and `Axn::Internal::ResolvedSubfields` as Task 8 left them.
- Produces: `SubfieldTree::ResolutionResult` with members `roots`, `deep_paths`, `index` — **no `dropped`**. `Internal::ResolvedSubfields` gains a third Data member `dropped`, so `#dropped` stays a cheap reader for `Core::`. `Reflection::Schema.dropped_deep_subfields` keeps its current signature and return value.

Why this task exists: Task 8 moved `SubfieldTree` to `Internal::` on the grounds that two layers consume it, but AGENTS.md:63's bar for `Internal::X` is "generically useful… a value-level mechanism **any layer can use**," and the module as moved cannot complete a single `build` without `Reflection::Schema` — `compute_dropped` → `path_blocked?` → `blocking_ancestor?` call `node_configs_block_nesting?`, `nestable_as_object?` and `shape_members_at` unconditionally. The rule was checked against *who calls it* and never against *what it reads*. Separating the pure tree construction from the JSON-representability judgment makes the destination true rather than merely defensible.

`Internal::ResolvedSubfields` deliberately keeps its `Reflection::Schema` dependency and stays at `Internal::`. It exists to pair a tree with `Schema.derive_annotations`, and `Core::` consumes it on the runtime read path — so it can be neither purified (the annotations are its purpose) nor moved into `Reflection` (whose members are guaranteed off the execution path). A composition depending on the layer it composes is an ordinary dependency direction, not the inversion this task fixes.

- [ ] **Step 1: Write the failing test**

Add to `spec/axn/internal/subfield_tree_spec.rb`, at the top of its outermost describe:

```ruby
  # The module's placement at Internal:: claims it is a value-level mechanism any layer can use.
  # That is only true if building a tree needs nothing from the reflection layer.
  it "constructs a tree without reaching into the reflection layer" do
    source = File.read(File.expand_path("../../../lib/axn/internal/subfield_tree.rb", __dir__))
    expect(source).not_to match(/Reflection/)
  end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bundle exec rspec spec/axn/internal/subfield_tree_spec.rb -e "without reaching into the reflection layer"`
Expected: FAIL — the file currently names `Reflection::Schema` in five places plus a require.

- [ ] **Step 3: Strip the judgment out of `SubfieldTree`**

Delete `compute_dropped`, `path_blocked?`, `blocking_ancestor?`, `merged_shape_members` and `colliding_shape_members` (currently lines ~110-160), and delete `require "axn/internal/reflection/schema"`.

Change `ResolutionResult` to carry the raw pairs instead of the verdict:

```ruby
      # The finished build: per-root node trees, the deep `[config, hops]` pairs whose representability is
      # the reflection layer's to judge, and the per-config ResolvedPath index. (Named to be unmistakable
      # next to the public Axn::Result.)
      ResolutionResult = Data.define(:roots, :deep_paths, :index)
```

and the return at the end of `build`:

```ruby
        ResolutionResult.new(roots:, deep_paths:, index:)
```

Keep the `deep_paths << [config, hops] if hops.size > 1` line and its comment — collecting the candidates is tree construction; judging them is not.

- [ ] **Step 4: Move the judgment into `Reflection::Schema`**

Move all five deleted methods into `lib/axn/internal/reflection/schema.rb` as **private** class methods, adjusting each `Reflection::Schema.foo` call to a bare `foo` (they are now in that module). Carry each method's comment across unchanged in substance — those comments explain why the drop pass and emission must agree, which is exactly the reason they now live beside emission.

Rewrite `dropped_deep_subfields` (line ~198) to compute from the raw pairs:

```ruby
        def dropped_deep_subfields(field_configs, subfield_configs, resolved: nil)
          return resolved.dropped if resolved

          compute_dropped(Axn::Internal::SubfieldTree.build(field_configs, Array(subfield_configs)).deep_paths)
        end
```

Verify that signature against its call sites before committing to it — `resolved:` is passed a `ResolvedSubfields` at some sites and possibly something else at others. If the shape differs, keep the method's external contract identical and adapt the body, reporting what you found.

- [ ] **Step 5: Give `ResolvedSubfields` a stored `dropped`**

`Core::` reads `_resolved_subfields.dropped` on the read path, so it must stay a cheap reader rather than a recomputation. Add it as a third Data member, computed once at build time:

```ruby
    ResolvedSubfields = Data.define(:tree, :annotations, :dropped) do
      def self.build(field_configs, subfield_configs)
        tree = SubfieldTree.build(field_configs, Array(subfield_configs))
        annotations = Reflection::Schema.derive_annotations(tree.roots)
        dropped = Reflection::Schema.dropped_deep_subfields(nil, nil, resolved: nil, deep_paths: tree.deep_paths)
        _deep_freeze!(tree)
        new(tree:, annotations: annotations.freeze, dropped: dropped.freeze)
      end
```

That `dropped_deep_subfields` call shape is a guess and probably wrong — do NOT force it. What the code needs is a Reflection-side entry point that turns `tree.deep_paths` into the dropped list. Pick the cleanest one (a small public `Schema.dropped_from_deep_paths(deep_paths)` beside `dropped_deep_subfields`, with both funnelling through the same private `compute_dropped`, is likely tidier than overloading one method with four kwargs) and say in your report which you chose and why.

In `_deep_freeze!`, `tree.dropped.freeze` must go — that member no longer exists. Freeze the new stored `dropped` at the point it is assigned instead, as shown. Delete the `def dropped = tree.dropped` delegator, since `dropped` is now a real member.

- [ ] **Step 6: Update the specs that asserted through the tree**

`spec/axn/internal/subfield_tree_spec.rb` asserts `tree.dropped` at five sites (~lines 30, 44, 119, 131, 144). Those assertions are about the DROP JUDGMENT, not about tree construction, so they belong with the layer that now owns it. Move each to assert through the Reflection entry point you built in Step 5, or relocate them to `spec/axn/internal/reflection/schema_spec.rb` if that reads better — your call, but every one of the five behaviors must still be asserted somewhere. Do not delete a case to make the suite green.

- [ ] **Step 7: Run everything**

Run: `bundle exec rspec spec/axn/standalone_require_spec.rb && bundle exec rspec && bundle exec rubocop && (cd spec_rails/dummy_app && bundle exec rspec spec)`
Expected: all PASS. `standalone_require_spec`'s `upward_references` list should need no new entry — `SubfieldTree` now references nothing upward, and its allowlist entry was already removed. If the list needs a new entry, the split is incomplete.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "PRO-2997: SubfieldTree constructs, the reflection layer judges

Internal::X promises a value-level mechanism any layer can use, and the module
could not complete a build without Reflection::Schema — compute_dropped walked
every deep path through node_configs_block_nesting?, nestable_as_object? and
shape_members_at.

Tree construction stays: the build now returns the deep [config, hops] pairs and
says nothing about whether they are representable. The five methods that judged
them move beside the emission they have to agree with, and ResolvedSubfields
stores the verdict so the read path still reads it for free.

Internal::ResolvedSubfields keeps its Schema dependency deliberately: deriving the
annotations is its purpose, and Core:: reads it on the execution path, so it can
neither be purified nor filed under Reflection."
```

---

### Task 9: `SubfieldContradictions` → `Core::Contract::SubfieldContradictions`

**Files:**
- Move: `lib/axn/internal/reflection/subfield_contradictions.rb` → `lib/axn/core/contract/subfield_contradictions.rb`
- Move: `spec/axn/internal/reflection/subfield_contradictions_spec.rb` → `spec/axn/core/contract/subfield_contradictions_spec.rb`
- Modify: `lib/axn/core/contract_for_subfields.rb:6`, `lib/axn/core/ambient_context.rb`, `lib/axn/internal/reflection.rb`

**Interfaces:**
- Consumes: `Axn::Internal::SubfieldTree` from Task 8 (this module requires it).
- Produces: `Axn::Core::Contract::SubfieldContradictions`, same public API. The `Reflection::` spelling no longer exists.

Rationale: declaration-time validation of a contract, called only from `Core::`. Meaningless outside the contract layer, so unlike Task 8's pair this one *does* satisfy AGENTS.md:66's `Core::Contract::X` test. It joins `Redaction` and `ShapeDeclaration` in `lib/axn/core/contract/`.

- [ ] **Step 1: Move the files (commit 1 of 2)**

```bash
git mv lib/axn/internal/reflection/subfield_contradictions.rb lib/axn/core/contract/subfield_contradictions.rb
mkdir -p spec/axn/core/contract
git mv spec/axn/internal/reflection/subfield_contradictions_spec.rb spec/axn/core/contract/subfield_contradictions_spec.rb
```

Update require paths: `grep -rn 'axn/internal/reflection/subfield_contradictions' lib spec spec_rails` → `axn/core/contract/subfield_contradictions`.

- [ ] **Step 2: Run the suite, then commit the move**

Run: `bundle exec rspec`
Expected: PASS.

```bash
git add -A
git commit -m "PRO-2997: move subfield_contradictions.rb into core/contract/

File move only; the next commit changes the nesting."
git show --stat --find-renames HEAD
```

- [ ] **Step 3: Write the failing test (commit 2 of 2)**

Add to `spec/axn/core/contract/subfield_contradictions_spec.rb`, at the top of its outermost describe:

```ruby
  it "belongs to the contract layer it validates, not to the reflection layer" do
    expect(Axn::Core::Contract.const_defined?(:SubfieldContradictions, false)).to be(true)
    expect(Axn::Internal::Reflection.const_defined?(:SubfieldContradictions, false)).to be(false)
  end
```

- [ ] **Step 4: Run it to verify it fails**

Run: `bundle exec rspec spec/axn/core/contract/subfield_contradictions_spec.rb -e "belongs to the contract layer"`
Expected: FAIL.

- [ ] **Step 5: Rewrap the nesting and update call sites**

Change the moved file's wrapper from `module Axn; module Internal; module Reflection` to `module Axn; module Core; module Contract`, re-indenting the body to match (the depth is the same, so this is a wrapper swap rather than an outdent).

Then `grep -rn "Reflection::SubfieldContradictions" lib spec spec_rails internal-docs` and update each — call sites are `lib/axn/core/contract_for_subfields.rb` and `lib/axn/core/ambient_context.rb`.

Remove any now-dead require of it from `lib/axn/internal/reflection.rb`.

- [ ] **Step 6: Run the suite**

Run: `bundle exec rspec spec/axn/standalone_require_spec.rb && bundle exec rspec && (cd spec_rails/dummy_app && bundle exec rspec spec)`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "PRO-2997: SubfieldContradictions belongs to Core::Contract

Declaration-time validation of a contract, called only from Core:: — meaningless
outside the contract layer, which is exactly AGENTS.md's test for Core::Contract::X.
Joins Redaction and ShapeDeclaration there."
```

---

### Task 10: Rewrite `Internal::Reflection`'s own header

**Files:**
- Modify: `lib/axn/internal/reflection.rb`

**Interfaces:**
- Consumes: the completed moves from Tasks 6–9.
- Produces: nothing new. This is the documentation half of §1.

- [ ] **Step 1: Rewrite the file**

After Tasks 6–9 the namespace holds exactly `Schema`, `Values` and `PropertyNames`. Its current header describes seven modules and concedes that "the name describes the family loosely rather than a guarantee they share" — which was the honest reading of a mixed namespace and is no longer needed.

```ruby
# frozen_string_literal: true

require "axn/internal/reflection/schema"
require "axn/internal/reflection/values"
require "axn/internal/reflection/property_names"

module Axn
  module Internal
    # The layer that derives a JSON view of a contract, and nothing else: the JSON Schema behind
    # `input_schema`/`output_schema` (Schema), the JSON-safe rendering behind
    # Axn::Extensions::Serialization.render (Values), and the property-name rules both are judged
    # against (PropertyNames).
    #
    # All three run OFF the execution path, which is what makes the name a guarantee rather than a
    # loose family: anything that runs during validation or at declaration belongs at Internal:: (the
    # wire decoder Internal::Coercion, the shared resolution Internal::SubfieldTree and
    # Internal::ResolvedSubfields) or in the layer it serves (Core::Contract::SubfieldContradictions).
    #
    # Not an adapter surface: a gem building on axn reads a schema through `axn_class.input_schema` and
    # renders a result through Axn::Extensions::Serialization.render, reaching for nothing here.
    module Reflection
    end
  end
end
```

- [ ] **Step 2: Run the suite**

Run: `bundle exec rspec`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add lib/axn/internal/reflection.rb
git commit -m "PRO-2997: the reflection namespace's header is now a guarantee

Holding only Schema, Values and PropertyNames, every member runs off the execution
path — so the header no longer has to concede that the name describes the family
loosely."
```

---

### Task 11: `Axn::Testing.reset!`

**Files:**
- Create: `lib/axn/testing.rb`
- Create: `spec/axn/testing/reset_spec.rb`
- Modify: `lib/axn/core/nesting_tracking.rb`
- Modify: `lib/axn/testing/spec_helpers.rb`
- Modify: `spec/spec_helper.rb:35`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `Axn::Testing.reset!` — takes no arguments, returns `nil`, idempotent, safe in a `before` hook. And `Axn::Core::NestingTracking._reset_isolation_warning!` — resets the one-time fiber-isolation warning flag.

- [ ] **Step 1: Write the failing test**

Create `spec/axn/testing/reset_spec.rb`:

```ruby
# frozen_string_literal: true

require "axn/testing"

RSpec.describe Axn::Testing do
  describe ".reset!" do
    it "drops the tracer auto-detection memos" do
      Axn::Internal::Tracing.autodetected_tracer
      described_class.reset!
      expect(Axn::Internal::Tracing.instance_variable_defined?(:@tracer_entry)).to be(false)
      expect(Axn::Internal::Tracing.instance_variable_defined?(:@probe_entry)).to be(false)
    end

    it "drops registered tool-adapter sources" do
      Axn::Tools.register_adapter(:reset_probe)
      expect(Axn::Tools::Registry.adapters).to include(:reset_probe)

      described_class.reset!
      expect(Axn::Tools::Registry.adapters).to be_empty
    end

    it "re-arms the one-time fiber-isolation warning" do
      Axn::Core::NestingTracking.instance_variable_set(:@_isolation_mismatch_warned, true)
      described_class.reset!
      expect(Axn::Core::NestingTracking.instance_variable_defined?(:@_isolation_mismatch_warned)).to be(false)
    end

    it "is idempotent, so a before hook can call it unconditionally" do
      expect { 2.times { described_class.reset! } }.not_to raise_error
    end

    # The load-bearing exclusions. A host app configures axn in an initializer; a suite-wide
    # `before { Axn::Testing.reset! }` that reset config would silently un-configure every example
    # after the first, presenting as unrelated failures deep in someone else's suite.
    it "leaves Axn.config alone" do
      Axn.config.log_level = :error
      described_class.reset!
      expect(Axn.config.log_level).to eq(:error)
    end

    it "leaves registered strategies alone" do
      before_keys = Axn::Strategies.all.keys
      described_class.reset!
      expect(Axn::Strategies.all.keys).to eq(before_keys)
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bundle exec rspec spec/axn/testing/reset_spec.rb`
Expected: FAIL — `cannot load such file -- axn/testing`.

- [ ] **Step 3: Add the `NestingTracking` reset seam**

In `lib/axn/core/nesting_tracking.rb`, beside `_warn_if_fiber_isolation_mismatch`:

```ruby
      # Re-arms the once-per-process warning above, for a spec suite that asserts on it. Named for
      # the caller it exists for: Axn::Testing.reset! is the supported entry point.
      def self._reset_isolation_warning!
        remove_instance_variable(:@_isolation_mismatch_warned) if instance_variable_defined?(:@_isolation_mismatch_warned)
      end
```

- [ ] **Step 4: Create `lib/axn/testing.rb`**

```ruby
# frozen_string_literal: true

require "axn"

module Axn
  # The supported testing surface. Separate from `axn/testing/spec_helpers`, which exists to be
  # `include`d into an RSpec config — a host app wanting only the reset should not have to load
  # RSpec-shaped helpers to get it.
  module Testing
    class << self
      # Drops axn's process-global DERIVED state, so one example's auto-detection cannot decide the
      # next one's behavior. Safe and idempotent in a `before` hook.
      #
      # Deliberately does NOT reset:
      #
      #   * `Axn.config` or `Axn::Extensions.config`. A host app configures axn once in an
      #     initializer, so resetting config here would silently un-configure every example after the
      #     first — presenting as unrelated failures deep in someone else's suite rather than as
      #     anything traceable to this call.
      #   * The registries (`Strategies`, `Async::Adapters`, `Mountable::MountingStrategies`). Their
      #     `clear!` restores built-ins and discards deliberate registrations, which is axn's own
      #     suite's business rather than a host app's.
      #   * `Tools::Registry`'s recorded action classes. That set accumulates every action class
      #     defined in the process, and clearing it mid-suite would make `Axn.tools_for` blind to
      #     classes that are still loaded.
      #
      # Two further pieces of per-execution state need nothing here: Internal::ExceptionClassification
      # and Internal::CarriedPresentation both store in ActiveSupport::IsolatedExecutionState and are
      # already reset by NestingTracking when the outermost action finishes.
      def reset!
        Axn::Internal::Tracing.reset!
        Axn::Async::Adapters::Sidekiq::AutoConfigure.reset! if defined?(Axn::Async::Adapters::Sidekiq::AutoConfigure)
        Axn::Core::NestingTracking._reset_isolation_warning!
        Axn::Tools::Registry.reset_adapters!

        nil
      end
    end
  end
end
```

The `defined?` guard on the Sidekiq constant is required: axn must work outside Rails and without Sidekiq installed.

- [ ] **Step 5: Wire it up**

Add `require "axn/testing"` to the top of `lib/axn/testing/spec_helpers.rb`.

In `spec/spec_helper.rb`, replace line 35:

```ruby
  config.before { Axn::Testing.reset! }
```

This is the dogfooding step — axn's own suite now drives the seam, so its covered list cannot drift from what a real suite needs.

- [ ] **Step 6: Run everything**

Run: `bundle exec rspec spec/axn/testing/reset_spec.rb && bundle exec rspec && (cd spec_rails/dummy_app && bundle exec rspec spec)`
Expected: PASS. If any spec that previously reset `Internal::Tracing` by hand now fails, replace its manual reset with `Axn::Testing.reset!`.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "PRO-2997: Axn::Testing.reset! is the supported spec-reset seam

A host app's spec suite had no way to clear axn's memoized detection state, so it
reached into Axn::Internal::Tracing's ivars. This covers the four pieces of
process-global derived state and deliberately leaves config and the registries
alone — resetting config would silently un-configure every example after the
first.

axn's own spec_helper now calls it in place of Tools::Registry.reset_adapters!,
so the covered list cannot drift from what a suite actually needs."
```

---

### Task 12: Documentation — AGENTS.md, the namespace policy spec, CHANGELOG

**Files:**
- Modify: `AGENTS.md` (namespace policy section, lines ~51–70)
- Modify: `spec/axn/namespace_policy_spec.rb`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: every earlier task.
- Produces: nothing executable.

- [ ] **Step 1: Add `Error` to the reserved constants**

In `spec/axn/namespace_policy_spec.rb`, add `Error` to the `RESERVED` array. Confirm `DuplicateFieldError` was already removed in Task 4.

- [ ] **Step 2: Run it**

Run: `bundle exec rspec spec/axn/namespace_policy_spec.rb`
Expected: PASS.

- [ ] **Step 3: Update AGENTS.md**

Three edits, no hard-wrapping:

**(a)** Line 64's `Internal::Reflection::X` bullet currently lists `SubfieldTree` as a member. Replace the bullet with:

```
- `Internal::Reflection::X` — the layer that derives a JSON view of a contract, and only that: `Schema`, `Values`, `PropertyNames`. All three run off the execution path, which is what makes the name a guarantee rather than a loose family. Nothing outside axn names it; what a gem consumes are the projections — `input_schema`/`output_schema` on the action class, and `Extensions::Serialization.render` for a result. Anything that runs during validation or at declaration belongs at `Internal::X` (`Coercion`, `SubfieldTree`, `ResolvedSubfields`) or in the layer it serves (`Core::Contract::SubfieldContradictions`).
```

**(b)** Add a paragraph to the namespace policy section stating the exception rule:

```
`Axn::Error` is the public-error boundary, and it is a **module** rather than a base class: `rescue` matches a module by `is_a?`, so tagging a class costs it no ancestry — which is what lets four core errors stay `ArgumentError`s and lets an adapter gem keep a base its own ecosystem requires (`Faraday::Error`, `Timeout::Error`) while still being catchable as an axn error. Including it is the boundary DECLARATION, not a blanket sweep: a class that includes it is public, documented, rescuable and breaking to remove. A sibling gem roots its own hierarchy there — `class Axn::Webhooks::Error < StandardError; include Axn::Error; end` — and `spec/axn/error_policy_spec.rb` pins the exact set of untagged classes, so neither an untagged public error nor a tagged internal one can land. `Axn::Failure` is the one deliberate public exclusion: it is a control-flow signal from `call!`, not a fault, so tagging it would make `rescue Axn::Error` catch the intended outcome while still missing an unintended `NoMethodError` from the action body. No public exception class inherits out of `Axn::Internal`; where six once did, the internal base was an ancestor and nothing else, and `rescue Axn::Error` is how "any registry lookup miss" is expressed now.
```

**(c)** If the `best_effort` paragraph (~line 129) names `Axn::UnreraisableException`, update it to `Axn::ReraiseFailed`.

- [ ] **Step 4: Update the CHANGELOG**

Add under the existing `## 0.1.0-alpha.5` heading — that version is bumped but untagged (`git tag` shows `v0.1.0.pre.alpha.4.3` as the latest), so it *is* the unreleased section. Do not add a new heading.

```markdown
- **[BREAKING]** `Axn::DuplicateFieldError` is now `Axn::ContractViolation::DuplicateFieldError`, joining its eight siblings under the class it descends from.
- **[BREAKING]** `Axn::UnreraisableException` is now `Axn::ReraiseFailed`. The old name described the original exception — the one `raise` could not hand back — while the object it names is the substitute.
- **[BREAKING]** The six public registry errors (`Axn::StrategyNotFound`, `Axn::DuplicateStrategyError`, `Axn::Async::AdapterNotFound`, `Axn::Async::DuplicateAdapterError`, `Axn::Mountable::MountingTypeNotFound`, `Axn::Mountable::DuplicateMountingTypeError`) no longer descend from `Axn::Internal::Registry::{NotFound, DuplicateError}`. They are `StandardError`s carrying `Axn::Error`; use `rescue Axn::Error` for "any registry lookup miss".
- **FEAT:** `Axn::Error` — a marker module included into every public exception, so `rescue Axn::Error` catches anything axn objected to. `Axn::Failure` is deliberately excluded (a control-flow signal from `call!`, not a fault). A gem building on axn roots its own hierarchy there: `class Axn::Webhooks::Error < StandardError; include Axn::Error; end`.
- **FEAT:** `Axn::Testing.reset!` — drops axn's process-global derived state (tracer auto-detection, Sidekiq auto-configure flags, the one-time fiber-isolation warning, registered tool-adapter sources) for a host app's spec suite. Deliberately leaves `Axn.config` and the registries alone.
- Internal: `Internal::Reflection` now holds only the three modules that derive a JSON view of a contract. `Coercion`, `SubfieldTree` and `ResolvedSubfields` moved to `Internal::`, and `SubfieldContradictions` to `Core::Contract::`.
```

- [ ] **Step 5: Run everything one final time**

Run: `bundle exec rspec && (cd spec_rails/dummy_app && bundle exec rspec spec) && bundle exec rubocop`
Expected: all PASS/clean.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "PRO-2997: document the namespace taxonomy

AGENTS.md's Internal::Reflection bullet listed SubfieldTree, which the moves
falsify; adds the Axn::Error rule and the no-public-class-inherits-from-Internal
invariant. CHANGELOG entries land under the bumped-but-uncut alpha.5 heading."
```

---

### Task 13: Fold in the final review's follow-ups — accuracy and one hardening

**Files:**
- Modify: `lib/axn/internal/registry.rb:65-73`
- Modify: `lib/axn/internal/reflection.rb` (header enumeration)
- Modify: `CHANGELOG.md`
- Modify: `internal-docs/specs/2026-08-04-namespace-taxonomy-design.md`
- Test: `spec/axn/error_policy_spec.rb` or a registry spec, for the hardening

**Interfaces:**
- Consumes: everything Tasks 1–12 produced.
- Produces: `Internal::Registry.{not_found_error_class, duplicate_error_class}` become abstract (raising `NotImplementedError`) instead of defaulting to the untagged internal bases.

Five items, all from the final whole-branch review. Four are accuracy; one is the only behavior change.

**(a) The registry leak is closed by convention, not construction.** `lib/axn/internal/registry.rb:65-73` still *defaults* `not_found_error_class`/`duplicate_error_class` to the untagged `Internal::Registry::{NotFound, DuplicateError}`. All three current registries override both, so the bases are unreachable today — but a fourth registry that forgets an override would raise an untagged `Axn::Internal::` exception publicly, re-opening exactly the leak Task 2 closed, and `error_policy_spec.rb` could not catch it (it pins those classes AS untagged, which is what a new leak looks like). Make both abstract in the shape `registry_directory` already uses at line 76-78 — `raise NotImplementedError, "Subclasses must implement …"`. Verify all three registries override both before doing this, and add a spec proving a registry subclass that omits an override raises `NotImplementedError` rather than leaking an internal class.

**(b) `CHANGELOG.md:178` is now false.** It lists "registered tool-adapter sources" among what `Axn::Testing.reset!` drops, but the final fix wave removed `reset_adapters!` from `reset!` precisely because adapter gems register at file-load time and the registration cannot come back. Correct the entry: drop that item from the list, and add registered tool adapters to the "deliberately leaves alone" clause with the reason. Cross-check the whole entry against `lib/axn/testing.rb`'s actual body and docstring so the released record matches the code.

**(c) `reflection.rb`'s header under-enumerates and undercounts.** It names `CallLogger`, the executor's validation-failure messages, and the shape validator as `PropertyNames.renderable_label` consumers, then claims those three conditions are the only ways in. It omits `Core::Context::FacadeInspector#rendered_field_name` (`facade_inspector.rb:115`), reached by `result.inspect` on a **successful** result for every displayed field with none of those conditions to short-circuit, and `Core::SchemaReflection#_schema_name_label` (`schema_reflection.rb:68`). Separately it says `Schema.usable_id_token_default?` is consulted "once" when it is reached from three distinct runtime call sites, each individually memoized. Verify every caller before naming it, and keep the existing precision about WHEN each fires — do not regress a conditional into an unconditional.

**(d) The §2 audit record states a false pre-existing break.** `internal-docs/specs/2026-08-04-namespace-taxonomy-design.md:188` says axn-openapi "references `Axn::Reflection::UnserializableValue` in `lib/` … that gem is broken on its next bump." All three references (`openapi.rb:29`, `dispatcher.rb:95`, `dispatcher.rb:120`) are inside **comments**; the live handler rescues `StandardError, SystemStackError`. Since that section's whole purpose is to stop the next person re-running the audit, a wrong record is the costliest defect in it. Correct it to say what is true — the references are prose, and the gem is not broken — and adjust the "Downstream" section's port list accordingly. This is the one file under `internal-docs/` you may edit.

**(e) CHANGELOG tag style.** The entries this branch added use bold `**[BREAKING]**` / `**[FEAT]**`; the other 241 entries in the file use plain `[BREAKING]` / `[FEAT]`. Match the file.

- [ ] **Step 1: Verify the three registries override both methods**

Run: `grep -rn "not_found_error_class\|duplicate_error_class" lib`
Expected: `strategies.rb`, `async/adapters.rb`, `mounting_strategies.rb` each define both, plus the definitions and raise sites in `internal/registry.rb`. If any registry does NOT override both, stop and report — making the methods abstract would break it.

- [ ] **Step 2: Write the failing test for (a)**

Add to `spec/axn/error_policy_spec.rb`, inside the top-level describe:

```ruby
  # The six public registry errors stopped inheriting from Internal::Registry's bases. Those bases
  # remain as the registry's own defaults, so a new registry that forgets to name its error classes
  # would raise an untagged Axn::Internal:: exception publicly — the leak this spec cannot see, since
  # it pins those two classes AS untagged. Abstract methods make that unreachable by construction.
  it "refuses to raise an internal base class for a registry that names no error classes" do
    registry = Class.new(Axn::Internal::Registry) do
      def self.built_in = {}
    end

    expect { registry.find(:anything) }.to raise_error(NotImplementedError, /error_class/)
  end
```

- [ ] **Step 3: Run it to verify it fails**

Run: `bundle exec rspec spec/axn/error_policy_spec.rb -e "refuses to raise an internal base class"`
Expected: FAIL — it currently raises `Axn::Internal::Registry::NotFound`, not `NotImplementedError`.

- [ ] **Step 4: Make both methods abstract**

In `lib/axn/internal/registry.rb`, replace both bodies with the shape `registry_directory` uses:

```ruby
        # Abstract on purpose. A registry names its OWN error classes, which are public and carry
        # Axn::Error; defaulting to the classes below would let a registry that forgot raise an
        # internal class to a caller.
        def not_found_error_class
          raise NotImplementedError, "Subclasses must implement not_found_error_class method"
        end

        def duplicate_error_class
          raise NotImplementedError, "Subclasses must implement duplicate_error_class method"
        end
```

Leave `NotFound` and `DuplicateError` defined at lines 8-9 — `error_policy_spec.rb` pins them as untagged internal classes, and other code may still reference them. Verify nothing else raises them.

- [ ] **Step 5: Apply (b), (c), (d), (e)**

Each is described above. For (c), verify each caller by reading the code before naming it.

- [ ] **Step 6: Run everything**

Run: `bundle exec rspec && bundle exec rubocop && (cd spec_rails/dummy_app && bundle exec rspec spec)`
Expected: all PASS.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "PRO-2997: close the registry leak by construction, and fix four records

A registry that named no error classes inherited defaults pointing at the
untagged Internal:: bases, so forgetting an override would raise an internal
class publicly — and error_policy_spec pins those two AS untagged, so it is
the one leak that spec cannot see. Both are abstract now.

The rest is accuracy: the CHANGELOG still listed tool adapters among what
Axn::Testing.reset! drops after the fix that stopped it dropping them; the
reflection header omitted two renderable_label callers and undercounted the
id-default check; the audit record called axn-openapi pre-broken over three
references that are comments."
```

---

### Task 14: Document the error boundary for downstream gem authors

**Files:**
- Modify: `AGENTS-tool-adapters.md`
- Modify: `docs/recipes/authoring-tool-adapters.md`
- Modify: `docs/recipes/testing.md`
- Modify: `docs/reference/axn-result.md` (or wherever exceptions are documented — verify)

**Interfaces:**
- Consumes: `Axn::Error` and `Axn::Testing.reset!` as Tasks 1–13 left them.
- Produces: documentation only.

Neither of this branch's two new public APIs reaches `docs/` at all — `grep -rn "Axn::Error\|Testing.reset!" docs/` returns nothing. `Axn::Error` matters most to the audience `AGENTS-tool-adapters.md` and `docs/recipes/authoring-tool-adapters.md` serve, because the convention it establishes is theirs to follow.

What the adapter-author documentation must convey, in whatever structure those files already use:

- **The convention, as one line of code.** A gem roots its own hierarchy at `Axn::Error`: `class Axn::Webhooks::Error < StandardError; include Axn::Error; end`, with its specific errors subclassing that. Two of the four sibling gems already have such a base class and need only the `include`.
- **Why it is a module rather than a base class**, because this is the part an author needs in order to trust it: `rescue` matches a module by `is_a?`, so including it costs the class no ancestry. That is what lets an adapter keep whatever superclass its own ecosystem requires — `< Faraday::Error`, `< Timeout::Error` — and still be catchable as an axn error. A base class would force a choice.
- **What including it MEANS**, since it is a promise, not decoration: the class is public, documented, rescuable, and breaking to remove. It is the boundary declaration.
- **The tag is inherited**, so a tagged class cannot have an untagged subclass — a public error family should not have secretly-internal members.
- **What is deliberately outside the boundary**, so an author is not surprised: `Axn::Failure` (a control-flow signal from `call!`, not a fault — a caller who wants that too writes `rescue StandardError`), and generic `ArgumentError`s raised for DSL misuse, which stay plain by design.
- **What a consuming app gets from it**: `rescue Axn::Error` catches core's errors and every participating adapter's, which is the reason the convention is worth following rather than inventing a per-gem base.

`docs/recipes/testing.md` is the natural home for `Axn::Testing.reset!`. Document: it is opt-in via `require "axn/testing"` (`require "axn"` does not define `Axn::Testing`); it is safe and idempotent in a suite-wide `before`; what it drops (tracer auto-detection memos, Sidekiq auto-configure flags, the one-time fiber-isolation warning); and — the part that matters most — what it deliberately leaves alone and why, since those exclusions are load-bearing: `Axn.config` and `Axn::Extensions.config` (a host app configures axn once in an initializer, so resetting it would silently un-configure every example after the first), the three registries, and registered tool adapters (adapter gems register at file-load time, and `require` is once-per-process, so a reset could never be undone).

- [ ] **Step 1: Read the existing files before writing**

Read `AGENTS-tool-adapters.md` and `docs/recipes/authoring-tool-adapters.md` in full, plus `docs/recipes/testing.md`. Match each file's existing structure, voice, and heading conventions rather than appending a foreign-looking section. Note that `AGENTS-tool-adapters.md` already documents `Axn::Extensions::Serialization::UnserializableValue` and `Axn::Extensions.owned_failure?` around lines 89-149 — the error boundary belongs near that material.

- [ ] **Step 2: Check whether the docs site needs a nav entry**

Look for a VitePress config (`docs/.vitepress/config.*`). If the pages you touch are already in the nav, nothing to do; if you add a new page, wire it in. Prefer extending existing pages over adding new ones.

- [ ] **Step 3: Write the documentation**

Cover the points above. Apply the repo's code-focus rubric selectively: `[!code focus]` earns its place in a full scaffold block teaching one or two lines, not in a tight snippet.

- [ ] **Step 4: Verify the docs build and the claims are true**

Run: `bundle exec rspec && bundle exec rubocop`. If the repo has a docs build or link check, run it. Then re-read every factual claim you wrote against the code — a doc that overclaims the boundary is the defect this branch already had to fix twice.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "PRO-2997: document the error boundary for adapter authors

Axn::Error's convention is the adapter author's to follow, and neither it nor
Axn::Testing.reset! appeared in docs/ at all. Covers the one-line convention,
why a module rather than a base class (an adapter keeps the superclass its own
ecosystem needs and is still catchable), what including it promises, and what
sits outside the boundary on purpose."
```

---

## Verification checklist

Before opening the PR:

- [ ] `bundle exec rspec` — green
- [ ] `(cd spec_rails/dummy_app && bundle exec rspec spec)` — green (the Rails dummy app has its own bundle; the root rspec run misses it)
- [ ] `bundle exec rubocop` — clean
- [ ] `git log --oneline --find-renames --stat` shows **renames**, not delete+add pairs, for the six moved files
- [ ] `grep -rn "Reflection::Coercion\|Reflection::SubfieldTree\|Reflection::ResolvedSubfields\|Reflection::SubfieldContradictions\|Axn::DuplicateFieldError\|UnreraisableException" lib spec spec_rails docs internal-docs AGENTS*.md` returns nothing outside `internal-docs/specs/` and `internal-docs/plans/` (historical design docs keep their original text)
- [ ] `spec/axn/error_policy_spec.rb` untagged set is exactly the four pinned exclusions

## Downstream port notes

Collect these for the port snippets after merge. None is a code break caused by this plan.

- **All sibling gems:** add `include Axn::Error` to the base error class. axn-webhooks (`Axn::Webhooks::Error`) and axn-openapi (`Axn::OpenAPI::Error`) already have one; axn-ruby_llm and axn-mcp need a base first (axn-mcp has `SchemaError` with no base).
- **axn-openapi, pre-existing break:** `lib/` references `Axn::Reflection::UnserializableValue` in both the main checkout and the `clean-serialization` worktree. PRO-2992 already moved that to `Axn::Extensions::Serialization::UnserializableValue`; this gem breaks on its next bump regardless of PRO-2997.
- **teamshares-rails, pre-existing no-op:** `spec/lib/axn/opentelemetry_integration_spec.rb:10-11` sets `@tracer` and `@tracer_provider` on `Axn::Internal::Tracing`. Those are not the real ivar names (`@tracer_entry`, `@probe_entry`), so the setup never clears the memo. Replace both lines with `Axn::Testing.reset!`.
