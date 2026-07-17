# PRO-2943 — Tool input-validation surfacing — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give adapters a first-class way to run an Axn as a tool so inbound-contract violations come back structured and non-reported (not paged as bugs), coercion is auto-applied for the trusted-JSON boundary, and undeclared inputs can optionally be rejected — all opt-in and without changing normal `.call` semantics.

**Architecture:** Two layers. (1) Core: three per-call gates carried on an `IsolatedExecutionState` holder (`Axn::Internal::CurrentCallOptions`), *consumed and cleared* by the executor at the top of `with_contract` so they apply only to the wrapped call and never leak into nested sub-actions. The gates tune existing executor behavior — `coerce_input_types` (a per-call layer over the PRO-2884 setting), `user_facing_input_errors` (compose the whole inbound contract as user-facing, reusing the existing settling), `reject_undeclared_inputs` (undeclared top-level keys become normal inbound errors). (2) Tools: `Axn::Tools::Invoker`, a value object holding an adapter's profile, that sets the gates for one call, strips a smuggled `ambient_context`, runs `.call`, and returns a plain `Axn::Result`. Surfacing rides on the already-public `result.exception` plus a new `InboundValidationError#field_errors`; `Axn::Result` is untouched.

**Tech Stack:** Ruby, ActiveSupport (`IsolatedExecutionState`), ActiveModel (`Errors`), RSpec. Must run **outside Rails** (`spec/`); model-consistency behavior is additionally covered **inside Rails** (`spec_rails/dummy_app`).

## Global Constraints

- **Works outside Rails.** No hard dependency on Rails/ActiveRecord — guard every `Rails`/`ActiveRecord` reference with `defined?(...)`. `spec/` runs without Rails; `spec_rails/dummy_app/` is the Rails app. (from AGENTS.md)
- **TDD.** Failing test first, then implementation. Bugfixes/behaviors start with a reproducing test. (from AGENTS.md / CONTRIBUTING.md)
- **Additive at the seam.** Existing canonical behavior stays identical; the new behavior is a distinct axis alongside. Normal `.call` (no gates set) must be byte-for-byte unchanged. (from AGENTS.md)
- **Reuse the seams.** No parallel validation path — the gates tune the existing `_validate_inbound!` / `_collect_contract_failures` / `_with_effective_coerce` flow and reuse the existing `user_facing` settling. (from AGENTS.md; user memory "mirror layers reuse the source")
- **Framework state is double-underscored** (`@__call_options`) so user actions can't clobber it; internal-only classes live under `Axn::Internal`. (from AGENTS.md)
- **No historical comments.** Comments describe current behavior + intrinsic why, never "used to X / now Y" or ticket-review notes. (user memory)
- **No manual line breaks in Markdown prose** in any docs touched — one line per paragraph. (user memory)
- **Reflection stays side-effect-free** — this work does NOT touch schema reflection; validation gates run only on the real call path, never during `input_schema` reflection. (user memory)

## Design decisions locked for this plan (beyond the spec)

- **Consume-and-clear, not depth-gating.** The executor reads `CurrentCallOptions` exactly once, at the top of `with_contract`, via `CurrentCallOptions.consume` (returns current value and nils the thread-local). This scopes the profile to the single action the invoker wrapped regardless of nesting depth: a nested `.call` in the tool body finds the holder already cleared and runs with default semantics. Chosen over gating on `NestingTracking` stack size (which breaks if a tool is itself invoked from within another action).
- **`coerce_input_types` per-call is tri-state via nil.** The holder stores `coerce_input_types: nil` meaning "unset — fall back to class/global"; the invoker sets `true`. The executor resolves `per_call.nil? ? resolve_override_for(...) : per_call`. Field-level explicit `coerce:` still wins (unchanged `_with_effective_coerce`).
- **Undeclared-input allow-list = declared top-level wire roots ∪ `:ambient_context`.** Computed from each inbound config's resolved path `wire_path.first` (top-level fields fall back to `config.field`), unioned with the reserved ambient parent. This exempts subfield `on:` roots (which are legitimate top-level wire keys) and the reserved `ambient_context` parent. Top-level only; nested/subfield unknown keys are out of scope.
- **`user_facing_input_errors` composes model-consistency mismatches and undeclared-input messages too** (as `:base` message parts), via a `base_extras` parameter on `_composed_user_facing_error`. With the gate off, `_undeclared_input_messages` returns `[]`, so `base_extras == mismatches` and the settle logic is identical to today.
- **No class-level DSL** for `user_facing_input_errors` / `reject_undeclared_inputs` — the only public setter is `Axn::Tools::Invoker` (YAGNI; additive later). `coerce_input_types` keeps its existing class/global setter.

## File Structure

**Create:**
- `lib/axn/internal/current_call_options.rb` — `Axn::Internal::CurrentCallOptions`: the per-call gate holder (`Data`-backed `Options`, `with`/`consume`/readers over `IsolatedExecutionState`).
- `lib/axn/tools/invoker.rb` — `Axn::Tools::Invoker`: per-adapter profile value object, reserved-key guard, `#call` returning `Axn::Result`, `.input_invalid?` sugar.
- `spec/axn/internal/current_call_options_spec.rb` — holder unit tests (set/consume/restore/isolation).
- `spec/axn/core/tool_invocation_gates_spec.rb` — executor gate behavior (coerce per-call, user_facing_input_errors, reject_undeclared_inputs) driven directly via `CurrentCallOptions.with`.
- `spec/axn/tools/invoker_spec.rb` — invoker profile→gates mapping, reserved-key guard, return type, sugar.
- `spec/axn/exceptions_field_errors_spec.rb` — `InboundValidationError#field_errors` shape.
- `spec_rails/dummy_app/spec/tool_invocation_model_consistency_spec.rb` — user-facing surfacing of a model-consistency mismatch (needs AR).

**Modify:**
- `lib/axn.rb` — require the two new files.
- `lib/axn/executor.rb` — consume options in `with_contract`; per-call coerce resolution; gate `_validate_inbound!`; add `_undeclared_input_messages` / `_declared_top_level_keys` helpers; extend `_composed_user_facing_error`.
- `lib/axn/exceptions.rb` — add `InboundValidationError#field_errors`.
- `docs/reference/*` + `CHANGELOG.md` + `AGENTS-consuming.md` — document the tool invoker + per-call coerce (final task).

---

### Task 1: `Axn::Internal::CurrentCallOptions` holder

**Files:**
- Create: `lib/axn/internal/current_call_options.rb`
- Modify: `lib/axn.rb` (add require)
- Test: `spec/axn/internal/current_call_options_spec.rb`

**Interfaces:**
- Produces:
  - `Axn::Internal::CurrentCallOptions::Options = Data.define(:coerce_input_types, :user_facing_input_errors, :reject_undeclared_inputs)`
  - `CurrentCallOptions.with(coerce_input_types: nil, user_facing_input_errors: false, reject_undeclared_inputs: false) { ... }` → yields, restores previous on ensure
  - `CurrentCallOptions.consume` → returns current `Options` (or `nil`) and clears the thread-local
  - `CurrentCallOptions.current` / `.current=`

- [ ] **Step 1: Write the failing test**

```ruby
# spec/axn/internal/current_call_options_spec.rb
require "spec_helper"

RSpec.describe Axn::Internal::CurrentCallOptions do
  after { described_class.current = nil }

  it "defaults to no current options" do
    expect(described_class.current).to be_nil
  end

  it "sets options within a `with` block and restores afterward" do
    described_class.with(user_facing_input_errors: true) do
      expect(described_class.current.user_facing_input_errors).to be(true)
      expect(described_class.current.coerce_input_types).to be_nil
      expect(described_class.current.reject_undeclared_inputs).to be(false)
    end
    expect(described_class.current).to be_nil
  end

  it "restores the prior value even when the block raises" do
    expect do
      described_class.with(coerce_input_types: true) { raise "boom" }
    end.to raise_error("boom")
    expect(described_class.current).to be_nil
  end

  it "consume returns the current options and clears the holder" do
    described_class.with(reject_undeclared_inputs: true) do
      consumed = described_class.consume
      expect(consumed.reject_undeclared_inputs).to be(true)
      expect(described_class.current).to be_nil
    end
  end

  it "consume returns nil when nothing is set" do
    expect(described_class.consume).to be_nil
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/internal/current_call_options_spec.rb`
Expected: FAIL with `uninitialized constant Axn::Internal::CurrentCallOptions`.

- [ ] **Step 3: Write minimal implementation**

```ruby
# lib/axn/internal/current_call_options.rb
# frozen_string_literal: true

module Axn
  module Internal
    # Per-call tuning gates set by a caller (today only Axn::Tools::Invoker) and read once by the
    # executor. Scoped via IsolatedExecutionState (same pattern as Async::CurrentRetryContext) so
    # nothing rides on `.call`'s kwargs. The executor `consume`s (reads + clears) at the top of its
    # contract phase, so the gates apply to exactly the wrapped action and a nested `.call` in its
    # body sees a cleared holder and runs with default semantics.
    module CurrentCallOptions
      Options = Data.define(:coerce_input_types, :user_facing_input_errors, :reject_undeclared_inputs)

      class << self
        def current = ActiveSupport::IsolatedExecutionState[:_axn_call_options]
        def current=(value) = (ActiveSupport::IsolatedExecutionState[:_axn_call_options] = value)

        def with(coerce_input_types: nil, user_facing_input_errors: false, reject_undeclared_inputs: false)
          previous = current
          self.current = Options.new(coerce_input_types:, user_facing_input_errors:, reject_undeclared_inputs:)
          yield
        ensure
          self.current = previous
        end

        # Read the current options and clear the holder, so the reading action takes sole ownership
        # and nested sub-actions do not inherit the gates.
        def consume = current.tap { self.current = nil }
      end
    end
  end
end
```

- [ ] **Step 4: Wire the require**

In `lib/axn.rb`, add alongside the other `require "axn/internal/..."` lines:

```ruby
require "axn/internal/current_call_options"
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bundle exec rspec spec/axn/internal/current_call_options_spec.rb`
Expected: PASS (5 examples).

- [ ] **Step 6: Commit**

```bash
git add lib/axn/internal/current_call_options.rb lib/axn.rb spec/axn/internal/current_call_options_spec.rb
git commit -m "PRO-2943: add CurrentCallOptions per-call gate holder

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Executor consumes options + per-call `coerce_input_types`

**Files:**
- Modify: `lib/axn/executor.rb` (`with_contract` start; `_collect_contract_failures` coerce line ~505; add resolver helpers)
- Test: `spec/axn/core/tool_invocation_gates_spec.rb`

**Interfaces:**
- Consumes: `Axn::Internal::CurrentCallOptions.consume` (Task 1)
- Produces (private executor helpers used by Tasks 3–4):
  - `@__call_options` — the consumed `Options` or `nil`
  - `_coerce_input_types?` → Boolean (per-call layer over class/global)
  - `_user_facing_input_errors?` → Boolean
  - `_reject_undeclared_inputs?` → Boolean

- [ ] **Step 1: Write the failing test**

```ruby
# spec/axn/core/tool_invocation_gates_spec.rb
require "spec_helper"

RSpec.describe "tool invocation gates: coerce_input_types" do
  let(:action) do
    Class.new do
      include Axn
      expects :age, type: Integer
      expects :count, type: Integer, coerce: false
      exposes :age, :count
      def call
        expose(age:, count:)
      end
    end
  end

  it "coerces a wire string when the per-call gate is set (field lacks explicit coerce:)" do
    result = Axn::Internal::CurrentCallOptions.with(coerce_input_types: true) do
      action.call(age: "42", count: 5)
    end
    expect(result).to be_ok
    expect(result.age).to eq(42)
  end

  it "honors a field-level `coerce: false` even under the per-call gate" do
    result = Axn::Internal::CurrentCallOptions.with(coerce_input_types: true) do
      action.call(age: "42", count: "5")
    end
    expect(result).not_to be_ok
    expect(result.exception).to be_a(Axn::InboundValidationError)
  end

  it "does not coerce on a normal call with no gate set" do
    result = action.call(age: "42", count: 5)
    expect(result).not_to be_ok
  end

  it "does not leak the gate into a nested sub-action" do
    inner = Class.new do
      include Axn
      expects :n, type: Integer
      def call; end
    end
    outer = Class.new do
      include Axn
      expects :age, type: Integer
      define_method(:call) { @inner_result = inner.call(n: "7") }
      attr_reader :inner_result
    end
    result = Axn::Internal::CurrentCallOptions.with(coerce_input_types: true) do
      outer.call(age: "1")
    end
    expect(result).to be_ok
    expect(result.__action__.inner_result).not_to be_ok # nested "7" was NOT coerced
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/core/tool_invocation_gates_spec.rb`
Expected: FAIL — the first example returns `age == "42"` / not ok (gate not yet read), and the nested example's inner result is ok (gate leaked or not applied — currently no gate at all so first example fails).

- [ ] **Step 3: Consume options at the top of `with_contract`**

In `lib/axn/executor.rb`, `with_contract` currently begins by calling `_clear_pre_pipeline_memos!`. Add the consume as the very first line:

```ruby
def with_contract(&block)
  # Take sole ownership of any per-call gates set by the caller (e.g. Axn::Tools::Invoker),
  # clearing the holder so a nested `.call` in the body runs with default semantics.
  @__call_options = Internal::CurrentCallOptions.consume

  _clear_pre_pipeline_memos!
  # ... rest unchanged
```

- [ ] **Step 4: Add the resolver helpers**

Add these private helpers to `Executor` (near `_resolved_parent_value`, still under `private`):

```ruby
# Per-call gate readers. `@__call_options` is the consumed CurrentCallOptions (or nil for a
# normal call). coerce is tri-state: a nil per-call value falls back to the class/global setting,
# so a normal call is unchanged; the tool invoker forces `true`.
def _coerce_input_types?
  per_call = @__call_options&.coerce_input_types
  per_call.nil? ? Axn::Configuration.resolve_override_for(@action_class, :coerce_input_types) : per_call
end

def _user_facing_input_errors? = @__call_options&.user_facing_input_errors || false
def _reject_undeclared_inputs? = @__call_options&.reject_undeclared_inputs || false
```

- [ ] **Step 5: Route the coerce read through the helper**

In `_collect_contract_failures`, replace the first line:

```ruby
coerce_input_types = Axn::Configuration.resolve_override_for(@action_class, :coerce_input_types)
```

with:

```ruby
coerce_input_types = _coerce_input_types?
```

- [ ] **Step 6: Run test to verify it passes**

Run: `bundle exec rspec spec/axn/core/tool_invocation_gates_spec.rb`
Expected: PASS (4 examples).

- [ ] **Step 7: Run the full contract/executor suite to prove no regression**

Run: `bundle exec rspec spec/axn/core spec/axn/executor_spec.rb 2>/dev/null; bundle exec rspec spec`
Expected: PASS (normal `.call` unchanged — the nil-fallback preserves prior behavior).

- [ ] **Step 8: Commit**

```bash
git add lib/axn/executor.rb spec/axn/core/tool_invocation_gates_spec.rb
git commit -m "PRO-2943: consume per-call options; per-call coerce_input_types layer

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: `user_facing_input_errors` gate

**Files:**
- Modify: `lib/axn/executor.rb` (`_validate_inbound!`, `_composed_user_facing_error`)
- Test: `spec/axn/core/tool_invocation_gates_spec.rb` (append)

**Interfaces:**
- Consumes: `_user_facing_input_errors?` (Task 2)
- Produces: `_composed_user_facing_error(failures, base_extras = [])` (extended signature; used by Task 4)

- [ ] **Step 1: Write the failing test**

```ruby
# append to spec/axn/core/tool_invocation_gates_spec.rb
RSpec.describe "tool invocation gates: user_facing_input_errors" do
  let(:action) do
    Class.new do
      include Axn
      expects :name, type: String
      expects :status, type: String, inclusion: { in: %w[active closed] }
      def call; end
    end
  end

  def invoke(**args)
    Axn::Internal::CurrentCallOptions.with(user_facing_input_errors: true) { action.call(**args) }
  end

  it "settles a type violation as a non-reported user-facing failure" do
    expect(Axn.config).not_to receive(:on_exception)
    result = invoke(name: 123, status: "active")
    expect(result).not_to be_ok
    expect(result.outcome).to eq("failure")
    expect(result.exception).to be_a(Axn::InboundValidationError)
    expect(result.error).to match(/name/i)
  end

  it "surfaces per-field detail for an inclusion (enum) violation" do
    result = invoke(name: "ok", status: "nope")
    expect(result.error).to match(/not included/i)
  end

  it "composes multiple violations into one message" do
    result = invoke(name: 123, status: "nope")
    expect(result.error).to match(/name/i).and match(/status/i)
  end

  it "still REPORTS the same inputs on a normal call (no gate)" do
    expect(Axn.config).to receive(:on_exception).at_least(:once)
    result = action.call(name: 123, status: "active")
    expect(result).not_to be_ok
    expect(result.outcome).to eq("exception")
  end

  it "does NOT reclassify a fail! in the body" do
    failing = Class.new do
      include Axn
      def call = fail!("nope")
    end
    result = Axn::Internal::CurrentCallOptions.with(user_facing_input_errors: true) { failing.call }
    expect(result.outcome).to eq("failure")
    expect(result.exception).not_to be_a(Axn::InboundValidationError)
    expect(result.error).to eq("nope")
  end

  it "does NOT reclassify a genuine StandardError in the body (still reports)" do
    expect(Axn.config).to receive(:on_exception).at_least(:once)
    boom = Class.new do
      include Axn
      def call = raise "kaboom"
    end
    result = Axn::Internal::CurrentCallOptions.with(user_facing_input_errors: true) { boom.call }
    expect(result.outcome).to eq("exception")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/core/tool_invocation_gates_spec.rb -e "user_facing_input_errors"`
Expected: FAIL — under the gate, `on_exception` still fires and `result.outcome` is `"exception"` (gate not yet honored).

- [ ] **Step 3: Extend `_composed_user_facing_error` to accept base extras**

In `lib/axn/executor.rb`, replace:

```ruby
def _composed_user_facing_error(failures)
  parts = failures.flat_map { |failure| _user_facing_parts(failure) }
  InboundValidationError.new(_aggregate_errors(failures, []),
                             user_facing: true, user_facing_message: parts.uniq.to_sentence)
end
```

with:

```ruby
# base_extras are :base-level message strings (model-consistency mismatches and, under
# reject_undeclared_inputs, unknown-input messages) that compose into the user-facing message and
# aggregate onto :base. Empty by default, so the per-field-declared path is unchanged.
def _composed_user_facing_error(failures, base_extras = [])
  parts = failures.flat_map { |failure| _user_facing_parts(failure) } + base_extras
  InboundValidationError.new(_aggregate_errors(failures, base_extras),
                             user_facing: true, user_facing_message: parts.uniq.to_sentence)
end
```

- [ ] **Step 4: Gate the settle decision in `_validate_inbound!`**

In `lib/axn/executor.rb`, replace the tail of `_validate_inbound!` (from `mismatches = ...` to the end):

```ruby
      mismatches = _model_consistency_mismatches(failed_nodes)

      return if failures.empty? && mismatches.empty?

      raise InboundValidationError, _aggregate_errors(failures, mismatches) unless mismatches.empty? && failures.all? { |f| _failure_fully_user_facing?(f) }

      # ... (comment) ...
      raise _composed_user_facing_error(failures)
    end
```

with:

```ruby
      mismatches = _model_consistency_mismatches(failed_nodes)
      base_extras = mismatches + _undeclared_input_messages

      return if failures.empty? && base_extras.empty?

      # Tool-invocation opt-in: treat the WHOLE inbound contract as user-facing for this call —
      # compose every violation (including model-consistency mismatches and unknown-input messages)
      # into one non-reported failure. No new classification; the existing user_facing settling,
      # applied contract-wide.
      raise _composed_user_facing_error(failures, base_extras) if _user_facing_input_errors?

      raise InboundValidationError, _aggregate_errors(failures, base_extras) unless base_extras.empty? && failures.all? { |f| _failure_fully_user_facing?(f) }

      # Resolve the user-facing message — invoking any Symbol/Proc handler — only now, once we know
      # this is the exception we actually raise, so a discarded reclassification never fires an
      # expensive/side-effecting handler for nothing.
      raise _composed_user_facing_error(failures)
    end
```

Note: `_undeclared_input_messages` is added in Task 4; add a temporary stub now so this task is independently green:

```ruby
# Placeholder until Task 4 wires undeclared-input rejection; returns [] so base_extras == mismatches.
def _undeclared_input_messages = []
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bundle exec rspec spec/axn/core/tool_invocation_gates_spec.rb -e "user_facing_input_errors"`
Expected: PASS (6 examples).

- [ ] **Step 6: Run the full suite (normal-call semantics unchanged)**

Run: `bundle exec rspec spec`
Expected: PASS — `_undeclared_input_messages` returns `[]`, so with the gate off `base_extras == mismatches` and the settle logic is identical to before.

- [ ] **Step 7: Commit**

```bash
git add lib/axn/executor.rb spec/axn/core/tool_invocation_gates_spec.rb
git commit -m "PRO-2943: user_facing_input_errors gate composes whole inbound contract

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: `reject_undeclared_inputs` gate

**Files:**
- Modify: `lib/axn/executor.rb` (replace the `_undeclared_input_messages` stub; add `_declared_top_level_keys`)
- Test: `spec/axn/core/tool_invocation_gates_spec.rb` (append)

**Interfaces:**
- Consumes: `_reject_undeclared_inputs?` (Task 2), `Axn::Core::AmbientContext::PARENT` (`:ambient_context`)
- Produces: `_undeclared_input_messages` → `Array<String>` (`"unknown input: <key>"`)

- [ ] **Step 1: Write the failing test**

```ruby
# append to spec/axn/core/tool_invocation_gates_spec.rb
RSpec.describe "tool invocation gates: reject_undeclared_inputs" do
  let(:action) do
    Class.new do
      include Axn
      expects :name, type: String
      expects :city, on: :address, type: String # subfield: :address is a legitimate top-level wire root
      def call; end
    end
  end

  it "rejects an undeclared top-level key as an inbound error" do
    result = Axn::Internal::CurrentCallOptions.with(reject_undeclared_inputs: true, user_facing_input_errors: true) do
      action.call(name: "ok", address: { city: "NYC" }, bogus: 1)
    end
    expect(result).not_to be_ok
    expect(result.exception).to be_a(Axn::InboundValidationError)
    expect(result.error).to include("unknown input: bogus")
  end

  it "exempts declared fields and subfield wire roots" do
    result = Axn::Internal::CurrentCallOptions.with(reject_undeclared_inputs: true, user_facing_input_errors: true) do
      action.call(name: "ok", address: { city: "NYC" })
    end
    expect(result).to be_ok
  end

  it "exempts the reserved ambient_context key" do
    result = Axn::Internal::CurrentCallOptions.with(reject_undeclared_inputs: true, user_facing_input_errors: true) do
      action.call(name: "ok", address: { city: "NYC" }, ambient_context: {})
    end
    expect(result).to be_ok
  end

  it "does NOT reject undeclared keys NESTED inside a hash field" do
    result = Axn::Internal::CurrentCallOptions.with(reject_undeclared_inputs: true, user_facing_input_errors: true) do
      action.call(name: "ok", address: { city: "NYC", zip: "10001" })
    end
    expect(result).to be_ok
  end

  it "silently ignores undeclared keys when the gate is off" do
    result = action.call(name: "ok", address: { city: "NYC" }, bogus: 1)
    expect(result).to be_ok
  end

  it "surfaces an undeclared key as a dev-facing reported bug when user_facing is off but reject is on" do
    expect(Axn.config).to receive(:on_exception).at_least(:once)
    result = Axn::Internal::CurrentCallOptions.with(reject_undeclared_inputs: true) do
      action.call(name: "ok", address: { city: "NYC" }, bogus: 1)
    end
    expect(result.outcome).to eq("exception")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/core/tool_invocation_gates_spec.rb -e "reject_undeclared_inputs"`
Expected: FAIL — the stub returns `[]`, so `bogus` is silently accepted and the first/last examples fail.

- [ ] **Step 3: Replace the stub with the real helpers**

In `lib/axn/executor.rb`, replace:

```ruby
def _undeclared_input_messages = []
```

with:

```ruby
# Under reject_undeclared_inputs, every provided top-level wire key that is neither a declared
# field/subfield wire root nor the reserved ambient parent becomes a normal inbound error. Top-level
# only: keys nested inside a Hash field are not the top-level contract's concern.
def _undeclared_input_messages
  return [] unless _reject_undeclared_inputs?

  (@context.provided_data.keys - _declared_top_level_keys).map { |key| "unknown input: #{key}" }
end

# The set of legitimate top-level wire keys: each inbound config's resolved-path root (top-level
# fields fall back to their own field name), plus the reserved always-present ambient parent.
def _declared_top_level_keys
  roots = _inbound_configs.filter_map do |config|
    path = _resolved_path_for(config)
    path ? path.wire_path.first : config.field
  end
  (roots + [Core::AmbientContext::PARENT]).uniq
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/axn/core/tool_invocation_gates_spec.rb -e "reject_undeclared_inputs"`
Expected: PASS (6 examples).

- [ ] **Step 5: Run the full gate spec + suite**

Run: `bundle exec rspec spec/axn/core/tool_invocation_gates_spec.rb && bundle exec rspec spec`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/axn/executor.rb spec/axn/core/tool_invocation_gates_spec.rb
git commit -m "PRO-2943: reject_undeclared_inputs gate (top-level, ambient-exempt)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: `InboundValidationError#field_errors`

**Files:**
- Modify: `lib/axn/exceptions.rb`
- Test: `spec/axn/exceptions_field_errors_spec.rb`

**Interfaces:**
- Produces: `Axn::InboundValidationError#field_errors` → `Array<{field: Symbol, message: String}>`

- [ ] **Step 1: Write the failing test**

```ruby
# spec/axn/exceptions_field_errors_spec.rb
require "spec_helper"

RSpec.describe Axn::InboundValidationError do
  def errors_with(&block)
    e = ActiveModel::Errors.new(Axn::Validation::Aggregate.new)
    block.call(e)
    e
  end

  it "maps each error to {field:, message:} using the full message" do
    errors = errors_with { |e| e.add(:name, "is not a String") }
    exc = described_class.new(errors)
    expect(exc.field_errors).to eq([{ field: :name, message: "Name is not a String" }])
  end

  it "surfaces base-level errors with field == :base" do
    errors = errors_with { |e| e.add(:base, "unknown input: bogus") }
    exc = described_class.new(errors)
    expect(exc.field_errors).to eq([{ field: :base, message: "unknown input: bogus" }])
  end

  it "is empty when there are no errors" do
    exc = described_class.new(errors_with { |_e| })
    expect(exc.field_errors).to eq([])
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/exceptions_field_errors_spec.rb`
Expected: FAIL with `undefined method 'field_errors'`.

- [ ] **Step 3: Add the accessor**

In `lib/axn/exceptions.rb`, inside `class ValidationError` (so both inbound and outbound inherit it — the adapter only ever reads it off an `InboundValidationError`, but the mapping is generic), add after `def to_s = message`:

```ruby
    # Structured per-field view of the validation errors, for callers that want to format each
    # failure individually (e.g. a tool adapter handing per-argument reasons back to a model).
    # `full_message` so each entry reads standalone; base-level errors surface with field == :base.
    def field_errors = errors.map { |error| { field: error.attribute, message: error.full_message } }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/axn/exceptions_field_errors_spec.rb`
Expected: PASS (3 examples).

- [ ] **Step 5: Commit**

```bash
git add lib/axn/exceptions.rb spec/axn/exceptions_field_errors_spec.rb
git commit -m "PRO-2943: add ValidationError#field_errors structured accessor

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: `Axn::Tools::Invoker`

**Files:**
- Create: `lib/axn/tools/invoker.rb`
- Modify: `lib/axn.rb` (add require, near the `axn/tools/registry` require)
- Test: `spec/axn/tools/invoker_spec.rb`

**Interfaces:**
- Consumes: `Axn::Internal::CurrentCallOptions.with` (Task 1), `Axn::InboundValidationError` (Task 5)
- Produces:
  - `Axn::Tools::Invoker.new(user_facing_input_errors: false, reject_undeclared_inputs: false)`
  - `#call(axn_class, args = {}, ambient_context: NOT_SET)` → `Axn::Result`
  - `Axn::Tools::Invoker.input_invalid?(result)` → Boolean
  - `Axn::Tools::Invoker::RESERVED_INPUT_KEYS` → `%i[ambient_context]`

- [ ] **Step 1: Write the failing test**

```ruby
# spec/axn/tools/invoker_spec.rb
require "spec_helper"

RSpec.describe Axn::Tools::Invoker do
  let(:action) do
    Class.new do
      include Axn
      expects :name, type: String
      expects :age, type: Integer
      exposes :name
      def call = expose(name:)
    end
  end

  it "returns a plain Axn::Result on success" do
    result = described_class.new.call(action, { name: "ada", age: 36 })
    expect(result).to be_a(Axn::Result)
    expect(result).to be_ok
    expect(result.name).to eq("ada")
  end

  it "coerces wire strings without any per-field coerce: (coerce always on for tools)" do
    result = described_class.new.call(action, { name: "ada", age: "36" })
    expect(result).to be_ok
  end

  it "surfaces an inbound violation as a non-reported failure when user_facing_input_errors is on" do
    expect(Axn.config).not_to receive(:on_exception)
    invoker = described_class.new(user_facing_input_errors: true)
    result = invoker.call(action, { name: 123, age: 36 })
    expect(result).not_to be_ok
    expect(described_class.input_invalid?(result)).to be(true)
    expect(result.error).to match(/name/i)
  end

  it "input_invalid? is false for a fail! / success" do
    ok = described_class.new.call(action, { name: "ada", age: 36 })
    expect(described_class.input_invalid?(ok)).to be(false)
  end

  it "strips a model-supplied ambient_context from untrusted args" do
    sensing = Class.new do
      include Axn
      expects :x, type: Integer
      define_method(:call) { @seen = ambient_context }
      attr_reader :seen
    end
    result = described_class.new.call(sensing, { x: 1, ambient_context: { tenant: "evil" } })
    expect(result.__action__.seen).to eq({})
  end

  it "injects the adapter's trusted ambient_context after stripping" do
    sensing = Class.new do
      include Axn
      expects :tenant, on: :ambient_context, type: String
      exposes :tenant
      def call = expose(tenant:)
    end
    result = described_class.new.call(
      sensing,
      { ambient_context: { tenant: "evil" } },
      ambient_context: { tenant: "trusted" },
    )
    expect(result).to be_ok
    expect(result.tenant).to eq("trusted")
  end

  it "clears CurrentCallOptions after the call" do
    described_class.new(user_facing_input_errors: true).call(action, { name: "ada", age: 36 })
    expect(Axn::Internal::CurrentCallOptions.current).to be_nil
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/tools/invoker_spec.rb`
Expected: FAIL with `uninitialized constant Axn::Tools::Invoker`.

- [ ] **Step 3: Write the implementation**

```ruby
# lib/axn/tools/invoker.rb
# frozen_string_literal: true

module Axn
  module Tools
    # The sanctioned entry point for running an Axn AS A TOOL. Holds an adapter's chosen profile and
    # runs `.call` under the matching per-call gates (Axn::Internal::CurrentCallOptions), returning a
    # plain Axn::Result so an adapter's existing result-mapping is unchanged. Coercion is always on
    # for tools (the trusted-JSON boundary wants it, and a field's own `coerce:` still wins); the
    # user-facing surfacing and undeclared-input rejection are per-adapter opt-ins. Detection of an
    # input-contract failure rides on the returned result's exception (`input_invalid?`), not on any
    # new Axn::Result method.
    class Invoker
      NOT_SET = Object.new.freeze

      # axn framework-reserved input keys that untrusted (model-supplied) args may not set. Currently
      # only :ambient_context — direct passing is a valid override for a normal `.call`, but a tool's
      # args come from the model, so the invoker forces the ambient-resolution pipeline and lets the
      # adapter inject its own trusted context. NOT :server_context — that is an mcp transport concept
      # the mcp adapter extracts itself and passes in as the trusted ambient_context.
      RESERVED_INPUT_KEYS = %i[ambient_context].freeze

      def initialize(user_facing_input_errors: false, reject_undeclared_inputs: false)
        @user_facing_input_errors = user_facing_input_errors
        @reject_undeclared_inputs = reject_undeclared_inputs
      end

      # args: the untrusted, model-supplied argument hash.
      # ambient_context: the adapter's OWN trusted ambient context (optional), merged after the guard.
      def call(axn_class, args = {}, ambient_context: NOT_SET)
        clean = args.reject { |key, _| RESERVED_INPUT_KEYS.include?(key.to_sym) }
        clean = clean.merge(ambient_context:) unless ambient_context.equal?(NOT_SET)

        Axn::Internal::CurrentCallOptions.with(
          coerce_input_types: true,
          user_facing_input_errors: @user_facing_input_errors,
          reject_undeclared_inputs: @reject_undeclared_inputs,
        ) do
          axn_class.call(**clean)
        end
      end

      # Whether a returned result failed on an inbound contract violation (as opposed to a `fail!`,
      # an outbound violation, or a genuine exception). Mode-independent — true regardless of whether
      # the violation was reported or surfaced as user-facing.
      def self.input_invalid?(result) = result.exception.is_a?(Axn::InboundValidationError)
    end
  end
end
```

- [ ] **Step 4: Wire the require**

In `lib/axn.rb`, add next to the tools registry require:

```ruby
require "axn/tools/invoker"
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bundle exec rspec spec/axn/tools/invoker_spec.rb`
Expected: PASS (7 examples).

- [ ] **Step 6: Commit**

```bash
git add lib/axn/tools/invoker.rb lib/axn.rb spec/axn/tools/invoker_spec.rb
git commit -m "PRO-2943: add Axn::Tools::Invoker tool-invocation profile

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 7: Rails coverage for model-consistency surfacing

**Files:**
- Test: `spec_rails/dummy_app/spec/tool_invocation_model_consistency_spec.rb`

**Interfaces:**
- Consumes: `Axn::Tools::Invoker` (Task 6), the dummy app's existing AR models.

- [ ] **Step 1: Identify an existing dummy-app model with a `model:` id-based field pattern**

Run: `ls spec_rails/dummy_app/app/models && grep -rln "model:" spec_rails/dummy_app/spec | head`
Expected: a model (e.g. `User`) usable for `expects :user, model: true`. Use whatever the dummy app already provides; adapt the class below to it.

- [ ] **Step 2: Write the failing test**

```ruby
# spec_rails/dummy_app/spec/tool_invocation_model_consistency_spec.rb
require "rails_helper"

RSpec.describe "tool invocation: model-consistency mismatch surfaces user-facing" do
  # Adjust `User` / attributes to a model the dummy app actually defines (see Step 1).
  let(:action) do
    Class.new do
      include Axn
      expects :user, model: true
      def call; end
    end
  end

  it "composes a record/id mismatch into a non-reported user-facing failure" do
    user = User.create!
    other_id = user.id + 1
    expect(Axn.config).not_to receive(:on_exception)
    result = Axn::Tools::Invoker.new(user_facing_input_errors: true).call(
      action, { user:, user_id: other_id },
    )
    expect(result).not_to be_ok
    expect(Axn::Tools::Invoker.input_invalid?(result)).to be(true)
    expect(result.error).to match(/conflicts with user_id/)
  end
end
```

- [ ] **Step 3: Run test to verify it fails, then passes**

Run (from the dummy app bundle — see AGENTS / user memory "Running axn spec_rails"):
```bash
BUNDLE_GEMFILE=spec_rails/dummy_app/Gemfile bundle exec rspec spec_rails/dummy_app/spec/tool_invocation_model_consistency_spec.rb
```
Expected: after Tasks 3–6 this PASSES (mismatch composed via `base_extras`). If it FAILS on model setup, fix the fixture to match the dummy app's real models — the behavior under test (mismatch → user-facing) is already implemented.

- [ ] **Step 4: Commit**

```bash
git add spec_rails/dummy_app/spec/tool_invocation_model_consistency_spec.rb
git commit -m "PRO-2943: Rails coverage for model-consistency user-facing surfacing

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 8: Documentation + CHANGELOG

**Files:**
- Create: `docs/reference/tool-invoker.md` (or extend an existing tools reference page if one exists — check `docs/reference/`)
- Modify: `CHANGELOG.md`, `AGENTS-consuming.md`
- Modify: `docs/reference/configuration.md` (or wherever `coerce_input_types` is documented) — note the per-call layer

- [ ] **Step 1: Locate the existing docs surfaces**

Run: `ls docs/reference && grep -rln "coerce_input_types\|tools_for\|tool_name" docs`
Expected: the tools/config reference pages to extend.

- [ ] **Step 2: Write the tool-invoker reference**

Create `docs/reference/tool-invoker.md` documenting: what `Axn::Tools::Invoker` is (run an Axn as a tool), the profile knobs (`user_facing_input_errors`, `reject_undeclared_inputs`, coerce always-on), that it returns a plain `Axn::Result`, detection via `Axn::Tools::Invoker.input_invalid?(result)` / `result.exception.is_a?(Axn::InboundValidationError)`, per-field detail via `result.error` and `InboundValidationError#field_errors`, and the `ambient_context` reserved-key guard. Include the two-line adapter usage example from the spec. One line per paragraph (no hard wraps).

- [ ] **Step 3: Note the guidance shift**

In the inputs/`type:` guidance doc (find via `grep -rln "expects" docs/guide docs/reference | head`) and in `AGENTS-consuming.md`, add: declare a `type:` on every input — tool coercion and schema reflection both depend on it, so with the invoker's always-on coercion you no longer need defensive `coerce: true` per field. Keep it short; do not restructure surrounding docs.

- [ ] **Step 4: CHANGELOG entry**

Add to `CHANGELOG.md` under the unreleased section (match the existing FEAT-line format):

```
- **FEAT:** `Axn::Tools::Invoker` — run an Axn as a tool with auto-coercion and opt-in structured, non-reported inbound-validation surfacing (`user_facing_input_errors`, `reject_undeclared_inputs`); adds `ValidationError#field_errors`. Normal `.call` semantics unchanged. (PRO-2943)
```

- [ ] **Step 5: Verify docs build / links (if the repo has a docs check)**

Run: `grep -rn "tool-invoker" docs` to confirm the page is linked from any index/sidebar; add a sidebar entry if the repo uses one (check `docs/.vitepress/config.*`).
Expected: the new page is reachable.

- [ ] **Step 6: Commit**

```bash
git add docs CHANGELOG.md AGENTS-consuming.md
git commit -m "PRO-2943: document tool invoker + per-call coerce; type: guidance

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- Core gate `coerce_input_types` (per-call layer, field-level wins, class/global governs direct call) → Task 2. ✓
- Core gate `user_facing_input_errors` (compose whole contract, non-reported, reuse settling; only inbound affected) → Task 3. ✓
- Core gate `reject_undeclared_inputs` (top-level, ambient/subfield-root exempt, nested out of scope) → Task 4. ✓
- Consume-and-clear scoping (no nested-call leak) → Task 2 (mechanism + nested test). ✓
- No `Axn::Result` changes; detection via `result.exception`; `InboundValidationError#field_errors`; `Invoker.input_invalid?` sugar → Tasks 5, 6. ✓
- `Axn::Tools::Invoker` profile + reserved-key guard + trusted ambient injection + returns Result → Task 6. ✓
- Normal `.call` / `fail!` / outbound / genuine exception unchanged → Tasks 2, 3 (explicit tests). ✓
- Model-consistency mismatch composes user-facing → Task 3 (unit) + Task 7 (Rails). ✓
- Downstream adapter migration → out of scope for this repo (captured in spec/ticket; separate adapter PRs). ✓
- README/`type:` guidance simplification → Task 8. ✓

**Placeholder scan:** No TBD/TODO; every code step shows full code. The Task 3 `_undeclared_input_messages` stub is intentional and explicitly replaced in Task 4 (keeps Task 3 independently green). Task 7's model fixture is explicitly "adapt to the dummy app's real models" with a discovery step, not a placeholder for behavior. ✓

**Type consistency:** `@__call_options` / `_coerce_input_types?` / `_user_facing_input_errors?` / `_reject_undeclared_inputs?` (Task 2) are consumed verbatim in Tasks 3–4. `_composed_user_facing_error(failures, base_extras = [])` (Task 3) matches its Task 4 usage. `Axn::Tools::Invoker#call(axn_class, args, ambient_context:)` and `.input_invalid?` (Task 6) match the invoker spec and Task 7. `field_errors` shape `{field:, message:}` (Task 5) matches its use in Task 3's inclusion test. ✓
