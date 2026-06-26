# Error Message Presentation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a nested failure's `result.error` aggregate every level's base header (`"Outer: Inner: leaf"`), make an Axn-owned exception's `#message` equal its `result.error`, and document the override/`prefixed: false` patterns — without ever rewriting a foreign exception's message.

**Architecture:** A failure accumulates its presentation as it bubbles. Each level's executor (`with_exception_handling`) resolves *its* `result.error` by prefixing its own base onto the child's already-resolved presentation, stores that presentation in an identity-keyed side table for the next ancestor to read, and (for Axn-owned exceptions only) stamps it onto the exception's `#message`. The side table is reset with the nesting stack, exactly like `ExceptionClassification`. Because accumulation happens in the executor (which runs at every level, bang or not), `call!` needs no change and the top-level `#message`/`result.error` always agree.

**Tech Stack:** Ruby, RSpec, ActiveSupport (`IsolatedExecutionState`). Gem is pre-1.0 (alpha); breaking message-shape changes are acceptable and belong in the CHANGELOG.

## Global Constraints

- **Must work outside Rails.** Guard any AR/Rails constant with `defined?()`. Non-Rails specs live in `spec/`; the Rails dummy app is `spec_rails/`. (`ActiveSupport::IsolatedExecutionState` is already a hard dependency and is fine to use.)
- **No manual line breaks in Markdown prose** (repo convention): one line per paragraph in any docs you touch.
- **Ownership rule (load-bearing):** stamp `#message` only on Axn-owned exceptions — `Axn::Failure` and user-facing `Axn::ValidationError`. **Never** mutate a foreign exception's `#message`. Foreign exceptions keep their technical cause; their user-facing presentation lives only in `result.error`.
- **Idempotency rule:** framework code reads the *raw reason* / *carried presentation*, never `Axn::Failure#message`, when resolving — so re-resolution never double-prefixes.
- Run the suite with `bundle exec rspec`. Run a single file with `bundle exec rspec path:line`.

---

## File Structure

- `lib/axn/exceptions.rb` — `Axn::Failure` gains a raw-reason / presentation split.
- `lib/axn/internal/carried_presentation.rb` *(new)* — identity-keyed per-call-tree store of the resolved presentation, mirroring `ExceptionClassification`.
- `lib/axn/core/nesting_tracking.rb` — reset the new store alongside `ExceptionClassification`.
- `lib/axn.rb` — add `Axn.owns_failure_exception?(e)` predicate (used by the executor and tests).
- `lib/axn/executor.rb` — in `with_exception_handling`, eagerly resolve `result.error`, store the presentation, stamp owned `#message`.
- `lib/axn/result.rb` — `_resolve_error` reads the carried presentation for bubbled failures; `_user_provided_error_message` reads `raw_reason`.
- `lib/axn.rb` — `require` the new file in the flat internal-requires list (right after `require "axn/internal/exception_classification"`, line ~27).
- `docs/usage/writing.md` — Thread 4 documentation.
- Specs: `spec/axn/core/messages_aggregation_spec.rb` *(new)*, plus updates to `spec/axn/core/messages_prefix_spec.rb` and `spec/axn/core/callbang_spec.rb` where they assert the old single-header nested behavior.

---

### Task 1: Split raw reason from presentation on `Axn::Failure`

Establishes the data split with **no behavior change** at a single level. `#message` still returns the reason today (presentation is unset until later tasks populate it), and the framework stops reading `#message` during resolution.

**Files:**
- Modify: `lib/axn/exceptions.rb:17-40`
- Modify: `lib/axn/result.rb:174-183` (`_user_provided_error_message`)
- Test: `spec/axn/core/messages_aggregation_spec.rb` (new)

**Interfaces:**
- Produces: `Axn::Failure#raw_reason -> String|nil` (the `fail!` argument), `Axn::Failure#__present_as(String) -> void` (sets the presentation shown by `#message`), `Axn::Failure#message -> String` (returns `presentation || raw_reason || DEFAULT_MESSAGE`).

- [ ] **Step 1: Write the failing test**

```ruby
# spec/axn/core/messages_aggregation_spec.rb
# frozen_string_literal: true

RSpec.describe "Axn::Failure raw/presentation split" do
  it "exposes the raw fail! reason and falls back to it for #message" do
    f = Axn::Failure.new("email taken", action: nil)
    expect(f.raw_reason).to eq("email taken")
    expect(f.message).to eq("email taken")
  end

  it "returns the presentation from #message once stamped, leaving raw_reason intact" do
    f = Axn::Failure.new("email taken", action: nil)
    f.__present_as("Couldn't sync user: email taken")
    expect(f.message).to eq("Couldn't sync user: email taken")
    expect(f.raw_reason).to eq("email taken")
  end

  it "falls back to DEFAULT_MESSAGE when neither is present" do
    expect(Axn::Failure.new(nil, action: nil).message).to eq(Axn::Failure::DEFAULT_MESSAGE)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/core/messages_aggregation_spec.rb`
Expected: FAIL — `NoMethodError: undefined method 'raw_reason'` (and `__present_as`).

- [ ] **Step 3: Implement the split**

In `lib/axn/exceptions.rb`, replace the `Axn::Failure` body's message handling:

```ruby
  class Failure < StandardError
    DEFAULT_MESSAGE = "Execution was halted"

    attr_reader :__originating_action, :raw_reason

    def initialize(message = nil, prefixed: true, action: nil)
      @raw_reason = message
      @presentation = nil
      @prefixed = prefixed
      @__originating_action = action
      super(message)
    end

    # Set the resolved, presentation-layer string shown by #message. Leaves raw_reason untouched so
    # the framework can keep re-resolving from the raw reason without double-prefixing.
    def __present_as(string) = @presentation = string.presence

    def prefixed? = @prefixed
    def message = @presentation.presence || @raw_reason.presence || DEFAULT_MESSAGE
    def default_message? = message == DEFAULT_MESSAGE
    def inspect = "#<#{self.class.name} '#{message}'>"
  end
```

In `lib/axn/result.rb`, change `_user_provided_error_message` to read `raw_reason` (never `message`):

```ruby
    def _user_provided_error_message
      return exception.user_facing_message.presence if Axn::ValidationError.user_facing?(exception)

      return unless exception.is_a?(Axn::Failure)
      return if exception.default_message?

      exception.raw_reason.presence
    end
```

- [ ] **Step 4: Run the new test and the existing message specs**

Run: `bundle exec rspec spec/axn/core/messages_aggregation_spec.rb spec/axn/core/messages_prefix_spec.rb`
Expected: PASS (single-level behavior is unchanged; `default_message?` still keys off `message`, which falls back to `raw_reason`).

- [ ] **Step 5: Commit**

```bash
git add lib/axn/exceptions.rb lib/axn/result.rb spec/axn/core/messages_aggregation_spec.rb
git commit -m "feat(messages): split raw_reason from presentation on Axn::Failure

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Carried-presentation store

A per-call-tree, identity-keyed store of each failure's resolved presentation, so the next ancestor can prefix onto it. Mirrors `ExceptionClassification` exactly (same isolation, same reset lifecycle, same `compare_by_identity` rationale).

**Files:**
- Create: `lib/axn/internal/carried_presentation.rb`
- Modify: `lib/axn/internal/registry.rb` (add the `require`)
- Modify: `lib/axn/core/nesting_tracking.rb:13-29` (reset alongside `ExceptionClassification`)
- Test: `spec/axn/internal/carried_presentation_spec.rb` (new)

**Interfaces:**
- Produces: `Internal::CarriedPresentation.get(exception) -> String|nil`, `.set(exception, string) -> void`, `.reset! -> void`.

- [ ] **Step 1: Write the failing test**

```ruby
# spec/axn/internal/carried_presentation_spec.rb
# frozen_string_literal: true

RSpec.describe Axn::Internal::CarriedPresentation do
  after { described_class.reset! }

  it "stores and retrieves a presentation by exception identity" do
    e = RuntimeError.new("boom")
    expect(described_class.get(e)).to be_nil
    described_class.set(e, "Outer: boom")
    expect(described_class.get(e)).to eq("Outer: boom")
  end

  it "keys by identity, not equality" do
    a = RuntimeError.new("x")
    b = RuntimeError.new("x") # equal message, different object
    described_class.set(a, "A")
    expect(described_class.get(b)).to be_nil
  end

  it "drops everything on reset!" do
    e = RuntimeError.new("boom")
    described_class.set(e, "Outer: boom")
    described_class.reset!
    expect(described_class.get(e)).to be_nil
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/internal/carried_presentation_spec.rb`
Expected: FAIL — `uninitialized constant Axn::Internal::CarriedPresentation`.

- [ ] **Step 3: Implement the store**

```ruby
# lib/axn/internal/carried_presentation.rb
# frozen_string_literal: true

module Axn
  module Internal
    # Per-call-tree record of each failure's resolved presentation string, so an ancestor `call!`
    # that re-raises the SAME exception object can prefix its own base onto the child's already-
    # resolved message (header aggregation). Mirrors ExceptionClassification: scoped via
    # IsolatedExecutionState, identity-keyed (compare_by_identity), and cleared when the nesting
    # stack empties (see NestingTracking) so a later independent run starts fresh.
    module CarriedPresentation
      class << self
        def get(exception) = _store[exception]
        def set(exception, string) = (_store[exception] = string)

        def reset!
          ActiveSupport::IsolatedExecutionState[:_axn_carried_presentation] = nil
        end

        private

        def _store
          ActiveSupport::IsolatedExecutionState[:_axn_carried_presentation] ||= {}.compare_by_identity
        end
      end
    end
  end
end
```

Add the require in `lib/axn.rb` immediately after `require "axn/internal/exception_classification"` (line ~27), matching the flat internal-requires list:

```ruby
require "axn/internal/carried_presentation"
```

- [ ] **Step 4: Wire reset into NestingTracking**

In `lib/axn/core/nesting_tracking.rb`, at both reset sites (the open-guard near line 17-18 and the close-guard near line 28), add the new reset next to the existing one:

```ruby
        if _current_axn_stack.empty?
          Axn::Internal::ExceptionClassification.reset!
          Axn::Internal::CarriedPresentation.reset!
        end
```

```ruby
        if _current_axn_stack.empty?
          Axn::Internal::ExceptionClassification.reset!
          Axn::Internal::CarriedPresentation.reset!
        end
```

- [ ] **Step 5: Run tests**

Run: `bundle exec rspec spec/axn/internal/carried_presentation_spec.rb`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/axn/internal/carried_presentation.rb lib/axn/internal/registry.rb lib/axn/core/nesting_tracking.rb spec/axn/internal/carried_presentation_spec.rb
git commit -m "feat(messages): add per-call-tree carried-presentation store

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Aggregate headers across nested `call!`

Wire the executor to resolve and store each level's presentation, and teach `_resolve_error` to prefix onto a child's carried presentation. After this task, `Outer.call.error` of a nested `fail!` reads `"Outer: Inner: leaf"`.

**Files:**
- Modify: `lib/axn.rb` (add `Axn.owns_failure_exception?`)
- Modify: `lib/axn/executor.rb:196-209` (failure branch of `with_exception_handling`)
- Modify: `lib/axn/result.rb:151-157` (`_resolve_error`)
- Test: `spec/axn/core/messages_aggregation_spec.rb`

**Interfaces:**
- Consumes: `Internal::CarriedPresentation` (Task 2); `Axn::Failure#raw_reason` (Task 1).
- Produces: `Axn.owns_failure_exception?(exception) -> Boolean`.

- [ ] **Step 1: Write the failing test**

```ruby
# append to spec/axn/core/messages_aggregation_spec.rb
RSpec.describe "Header aggregation across nested call!" do
  it "prefixes every level's base onto the leaf, outermost first" do
    inner = build_axn do
      error "Charge failed"
      def call = fail!("card declined")
    end
    mid = build_axn do
      expects :inner
      error "Onboarding failed"
      def call = inner.call!
    end
    stub_const("Inner", inner)
    outer = build_axn do
      expects :mid
      error "Signup failed"
      def call = mid.call!
    end

    # two levels
    expect(mid.call(inner:).error).to eq("Onboarding failed: Charge failed: card declined")
    # three levels
    expect(outer.call(mid: mid).error).to eq("Signup failed: Onboarding failed: Charge failed: card declined")
  end

  it "passes the child's resolved presentation through a baseless ancestor unchanged" do
    inner = build_axn do
      error "Charge failed"
      def call = fail!("card declined")
    end
    outer = build_axn do
      expects :inner
      def call = inner.call! # no base declared
    end
    expect(outer.call(inner:).error).to eq("Charge failed: card declined")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/core/messages_aggregation_spec.rb -e "Header aggregation"`
Expected: FAIL — currently resolves to `"Onboarding failed: card declined"` (outermost-only), inner base dropped.

- [ ] **Step 3: Add the ownership predicate**

In `lib/axn.rb`, add a module method (near the other top-level `Axn.` helpers):

```ruby
  # Whether axn owns this exception's #message (and may stamp the resolved presentation onto it).
  # Foreign exceptions reclassified via fails_on are NOT owned — they keep their technical cause.
  def self.owns_failure_exception?(exception)
    exception.is_a?(Axn::Failure) || Axn::ValidationError.user_facing?(exception)
  end
```

- [ ] **Step 4: Teach `_resolve_error` to use the carried presentation**

In `lib/axn/result.rb`, replace `_resolve_error`:

```ruby
    def _resolve_error
      resolver = _msg_resolver(:error, exception:)

      # Ancestor of a bubbled failure: the child already resolved its full presentation; prefix this
      # level's base onto it (always — a bubbled child is never this action's own fail!). A baseless
      # ancestor's with_base_prefix is a no-op, so the child's presentation passes through unchanged.
      carried = Internal::CarriedPresentation.get(exception)
      return resolver.with_base_prefix(carried) if carried

      # Originating level (no carried presentation yet): unchanged behavior.
      reason = _user_provided_error_message
      return resolver.resolve_message unless reason

      _fail_prefixed? ? resolver.with_base_prefix(reason) : reason
    end
```

- [ ] **Step 5: Store the presentation in the executor failure branch**

In `lib/axn/executor.rb`, inside `with_exception_handling`, in the failure branch (after `@action_class._dispatch_callbacks(:failure, ...)` at line ~205), add:

```ruby
        # Resolve THIS level's presentation now (reads the child's carried presentation if this was a
        # bubbled call!), persist it for the next ancestor, and — for axn-owned exceptions only —
        # stamp it onto #message so a rescued exception reads the same string as result.error.
        resolved = @action.result.error
        Internal::CarriedPresentation.set(e, resolved) if resolved
        e.__present_as(resolved) if resolved && Axn.owns_failure_exception?(e)
```

Note: `@action.result.error` resolves and memoizes here because `__record_exception` (line 192) has already finalized the context. `__present_as` only exists on `Axn::Failure`; the `owns_failure_exception?` guard ensures we only call it there (user-facing `ValidationError` stamping is Task 7).

- [ ] **Step 6: Run tests**

Run: `bundle exec rspec spec/axn/core/messages_aggregation_spec.rb`
Expected: PASS.

- [ ] **Step 7: Update existing nested-`call!` assertions to the aggregated shape**

Run `bundle exec rspec spec/axn/core/messages_prefix_spec.rb` and update any nested-`call!` example that asserted the old outermost-only string (e.g. the `prefixed: false` bubbling example at `messages_prefix_spec.rb:318-326`, whose parent now also surfaces the child's chain). Adjust expected strings to the aggregated form; do **not** change `prefixed: false` originating-level examples (those are Task 5). Add a CHANGELOG entry under the alpha section noting nested `call!` now aggregates base headers.

- [ ] **Step 8: Run the full suite, then commit**

Run: `bundle exec rspec`
Expected: PASS (with the updated expectations).

```bash
git add lib/axn.rb lib/axn/executor.rb lib/axn/result.rb spec/ CHANGELOG.md
git commit -m "feat(messages): aggregate base headers across nested call!

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Per-segment delimiters

Verify (and fix if needed) that each level's declared `delimiter:` governs its own join. The mechanism from Task 3 already uses each level's own `resolver.with_base_prefix`, so each segment uses its own delimiter — this task pins it with a test and only touches code if the test fails.

**Files:**
- Test: `spec/axn/core/messages_aggregation_spec.rb`
- (Modify only if failing: `lib/axn/core/flow/handlers/resolvers/message_resolver.rb`)

- [ ] **Step 1: Write the failing test**

```ruby
# append to spec/axn/core/messages_aggregation_spec.rb
RSpec.describe "Per-segment delimiters in aggregation" do
  it "uses each level's own delimiter for its own join" do
    inner = build_axn do
      error "C", delimiter: " | "
      def call = fail!("leaf")
    end
    mid = build_axn do
      expects :inner
      error "B", delimiter: " > "
      def call = inner.call!
    end
    stub_const("Inner", inner)
    outer = build_axn do
      expects :mid
      error "A" # default ": "
      def call = mid.call!
    end
    expect(outer.call(mid: mid).error).to eq("A: B > C | leaf")
  end
end
```

- [ ] **Step 2: Run test**

Run: `bundle exec rspec spec/axn/core/messages_aggregation_spec.rb -e "Per-segment"`
Expected: PASS (the design predicts this works unchanged). If it FAILS, the delimiter is being sourced globally — fix `MessageResolver#delimiter`/`with_base_prefix` so each `with_base_prefix` call uses *its own* resolver's `resolved_base` delimiter, then re-run.

- [ ] **Step 3: Commit**

```bash
git add spec/axn/core/messages_aggregation_spec.rb
git commit -m "test(messages): pin per-segment delimiter behavior in aggregation

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: Preserve `prefixed: false` at the originating level

`fail!(..., prefixed: false)` must still suppress the originating action's own base, while an ancestor still prefixes its base onto the bubbled child (child opt-out is local).

**Files:**
- Test: `spec/axn/core/messages_aggregation_spec.rb`
- (No production change expected — Task 3 routes the originating level through the unchanged `_fail_prefixed?` path.)

- [ ] **Step 1: Write the failing test**

```ruby
# append to spec/axn/core/messages_aggregation_spec.rb
RSpec.describe "prefixed: false under aggregation" do
  it "suppresses the originating action's own base" do
    action = build_axn do
      error "Child base"
      def call = fail!("card declined", prefixed: false)
    end
    expect(action.call.error).to eq("card declined")
  end

  it "still lets an ancestor prefix its base onto a bubbled opt-out child" do
    stub_const("OptOutChild", build_axn { def call = fail!("card declined", prefixed: false) })
    parent = build_axn do
      error "Charging failed"
      def call = OptOutChild.call!
    end
    expect(parent.call.error).to eq("Charging failed: card declined")
  end
end
```

- [ ] **Step 2: Run tests**

Run: `bundle exec rspec spec/axn/core/messages_aggregation_spec.rb -e "prefixed: false"`
Expected: PASS. (Originating level: no carried presentation → `_fail_prefixed?` honors `prefixed?`. Ancestor: child's presentation is `"card declined"`, carried branch prefixes the ancestor base.)

- [ ] **Step 3: Commit**

```bash
git add spec/axn/core/messages_aggregation_spec.rb
git commit -m "test(messages): verify prefixed: false opt-out under aggregation

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: `call!` / `#message` parity and residual dissolution

Assert the Thread 1 invariant: `X.call!` raises an `Axn::Failure` whose `#message == X.call.error`, at every level, and `result.exception.message == result.error` on the non-bang path.

**Files:**
- Test: `spec/axn/core/messages_aggregation_spec.rb`
- (No production change expected — owned `#message` stamping landed in Task 3.)

- [ ] **Step 1: Write the failing test**

```ruby
# append to spec/axn/core/messages_aggregation_spec.rb
RSpec.describe "call! / #message parity (Axn::Failure)" do
  it "raises with #message equal to result.error at the top level" do
    action = build_axn do
      error "Couldn't sync user"
      def call = fail!("email taken")
    end
    expect(action.call.error).to eq("Couldn't sync user: email taken")
    expect { action.call! }.to raise_error(Axn::Failure, "Couldn't sync user: email taken")
  end

  it "matches the aggregated string at the outer level" do
    inner = build_axn do
      error "Charge failed"
      def call = fail!("card declined")
    end
    outer = build_axn do
      expects :inner
      error "Onboarding failed"
      def call = inner.call!
    end
    expect(outer.call(inner:).error).to eq("Onboarding failed: Charge failed: card declined")
    expect { outer.call!(inner:) }.to raise_error(Axn::Failure, "Onboarding failed: Charge failed: card declined")
  end

  it "leaves result.exception.message equal to result.error on the non-bang path" do
    inner = build_axn do
      error "Charge failed"
      def call = fail!("card declined")
    end
    outer = build_axn do
      expects :inner
      error "Onboarding failed"
      def call = inner.call!
    end
    r = outer.call(inner:)
    expect(r.exception.message).to eq(r.error)
  end
end
```

- [ ] **Step 2: Run tests**

Run: `bundle exec rspec spec/axn/core/messages_aggregation_spec.rb -e "parity"`
Expected: PASS. (The outermost level's executor stamps last, so `#message` reflects the outermost presentation = top `result.error`.)

- [ ] **Step 3: Update the `Nested call! parity` doc-tip spec/docs**

Run `bundle exec rspec spec/axn/core/messages_prefix_spec.rb` and reconcile the "result.error vs Axn::Failure#message" tip in `docs/usage/writing.md` — it currently says a rescued `Axn::Failure#message` carries the *raw* reason. Update it to: an Axn-owned exception's `#message` now equals `result.error`; only *foreign* (`fails_on`) exceptions carry a different (technical) `#message`. (Full doc rewrite is Task 9; here just correct the now-false claim.)

- [ ] **Step 4: Commit**

```bash
git add spec/axn/core/messages_aggregation_spec.rb docs/usage/writing.md
git commit -m "test(messages): assert call!/#message parity and residual dissolution

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 7: `user_facing` validation parity

User-facing `Axn::ValidationError` is Axn-owned, so it must aggregate like `fail!` and get its `#message` stamped.

**Files:**
- Modify: `lib/axn/executor.rb` (extend the owned-stamp to `ValidationError`)
- Test: `spec/axn/core/messages_aggregation_spec.rb`

**Interfaces:**
- Consumes: `Axn.owns_failure_exception?` (already returns true for user-facing `ValidationError`).

- [ ] **Step 1: Write the failing test**

```ruby
# append to spec/axn/core/messages_aggregation_spec.rb
RSpec.describe "user_facing validation parity" do
  it "prefixes the base onto the user-facing validation message and aggregates across call!" do
    inner = build_axn do
      error "Couldn't add note"
      expects :note, user_facing: "Add a note"
      def call = nil
    end
    outer = build_axn do
      expects :inner
      error "Save failed"
      def call = inner.call!(note: nil)
    end
    expect(inner.call(note: nil).error).to eq("Couldn't add note: Add a note")
    expect(outer.call(inner:).error).to eq("Save failed: Couldn't add note: Add a note")
    expect { outer.call!(inner:) }.to raise_error(Axn::ValidationError) { |e|
      expect(e.message).to eq("Save failed: Couldn't add note: Add a note")
    }
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/core/messages_aggregation_spec.rb -e "user_facing validation"`
Expected: FAIL on the `#message` expectation — `ValidationError#message` renders `errors.full_messages`, not the stamped presentation (Task 3 only stamped `Axn::Failure`).

- [ ] **Step 3: Make user-facing `ValidationError` carry a stamped presentation**

Add a presentation slot to the user-facing validation error so `Axn.owns_failure_exception?`-stamping works uniformly. In `lib/axn/exceptions.rb`, on the user-facing `ValidationError` (the class whose `#message` is at `exceptions.rb:107`/`120`), add the same `__present_as` + presentation-preferring `#message` (preserve the existing `errors.full_messages` rendering as the fallback when no presentation is stamped). Then in `lib/axn/executor.rb`, change the stamp guard so it calls `__present_as` for any owned exception that responds to it:

```ruby
        resolved = @action.result.error
        Internal::CarriedPresentation.set(e, resolved) if resolved
        e.__present_as(resolved) if resolved && Axn.owns_failure_exception?(e) && e.respond_to?(:__present_as)
```

- [ ] **Step 4: Run tests**

Run: `bundle exec rspec spec/axn/core/messages_aggregation_spec.rb spec/axn/core/expects_user_facing_spec.rb`
Expected: PASS (existing user-facing specs still green; new aggregation assertion green).

- [ ] **Step 5: Commit**

```bash
git add lib/axn/exceptions.rb lib/axn/executor.rb spec/axn/core/messages_aggregation_spec.rb
git commit -m "feat(messages): user_facing validation parity with fail! presentation

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 8: Foreign (`fails_on`) exceptions — aggregate `result.error`, never touch `#message`

A `fails_on` foreign exception's `result.error` must aggregate like the others, while its `#message` stays the original technical cause.

**Files:**
- Test: `spec/axn/core/messages_aggregation_spec.rb`
- (No production change expected — `owns_failure_exception?` already excludes foreign exceptions, so they participate in `CarriedPresentation`/`result.error` but are never stamped.)

- [ ] **Step 1: Write the failing test**

```ruby
# append to spec/axn/core/messages_aggregation_spec.rb
RSpec.describe "fails_on foreign exception presentation" do
  before { stub_const("ThirdPartyError", Class.new(StandardError)) }

  it "aggregates result.error but preserves the foreign technical message on the exception" do
    inner = build_axn do
      error "Couldn't sync"
      fails_on [ThirdPartyError], "the upstream service is down"
      def call = raise ThirdPartyError, "ECONNREFUSED"
    end
    outer = build_axn do
      expects :inner
      error "Onboarding failed"
      fails_on [ThirdPartyError]
      def call = inner.call!
    end

    r = outer.call(inner:)
    expect(r.error).to eq("Onboarding failed: Couldn't sync: the upstream service is down")
    expect(r.exception).to be_a(ThirdPartyError)
    expect(r.exception.message).to eq("ECONNREFUSED") # technical cause preserved, never rewritten
  end
end
```

- [ ] **Step 2: Run tests**

Run: `bundle exec rspec spec/axn/core/messages_aggregation_spec.rb -e "fails_on foreign"`
Expected: PASS. If `result.error` does not aggregate, confirm the foreign exception flows through `CarriedPresentation` (the executor stores for any failure, owned or not) and that `_resolve_error`'s carried branch fires.

- [ ] **Step 3: Commit**

```bash
git add spec/axn/core/messages_aggregation_spec.rb
git commit -m "test(messages): foreign fails_on exceptions aggregate result.error, keep technical #message

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 9: `step` compatibility regression (no `step` changes)

**Decision (made up front, not deferred):** `step` stays as-is. Its distinguishing contribution is the per-step **label** (`"Step N: "` / `error_prefix:`, `step.rb:118`), which base-header aggregation structurally cannot produce (aggregation only adds an action's declared `error` base). Switching `step` to `call!` to lean on aggregation would bubble the failure past the orchestrator before the label could be injected — losing "which step failed." So aggregation cannot absorb `step`'s interpolation. The part that *does* compose — `step` interpolating `step_result.error` (`step.rb:130`) — already works unchanged, since that value simply becomes the child's richer aggregated presentation.

This task is therefore a **regression test only**: confirm `step` + aggregation compose correctly — the label is preserved, the child error is aggregated, and no segment is double-counted (the `step`-created `fail!` is a fresh origin — `CarriedPresentation` is nil for it — so only the parent's base prepends).

**Files:**
- Test: `spec/axn/mountable/steps/steps_spec.rb` (add an example) or `spec/axn/core/messages_aggregation_spec.rb`
- (Modify `lib/axn/mountable/steps/*` only if the test reveals doubling.)

- [ ] **Step 1: Write the failing test**

```ruby
# append to spec/axn/core/messages_aggregation_spec.rb
RSpec.describe "step interaction with aggregation" do
  it "does not double-count base headers for a step failure" do
    child = build_axn do
      error "Charge failed"
      def call = fail!("card declined")
    end
    parent = build_axn do
      error "Onboarding failed"
      step :charge, child
      def call = nil
    end
    # Exactly one "Onboarding failed" and one "Charge failed" — no repeated segments.
    msg = parent.call.error
    expect(msg.scan("Onboarding failed").size).to eq(1)
    expect(msg.scan("Charge failed").size).to eq(1)
    expect(msg).to include("card declined")
  end
end
```

(Adjust the `step :charge, child` form to the repo's actual `step` DSL if it differs — check `spec/axn/mountable/steps/steps_spec.rb` for the canonical invocation.)

- [ ] **Step 2: Run test**

Run: `bundle exec rspec spec/axn/core/messages_aggregation_spec.rb -e "step interaction"`
Expected: PASS unchanged — `step` already swallows the child via `.call` and originates a fresh `fail!`, so accumulation sees only the parent. If a segment repeats, the bug is in *our* accumulation (it must not capture a child whose failure was swallowed by `.call` — only re-raised/`call!`-bubbled exceptions accumulate); fix the executor accumulation, not `step`.

- [ ] **Step 3: Commit**

```bash
git add spec/axn/core/messages_aggregation_spec.rb
git commit -m "test(messages): guard against step double-counting under aggregation

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 10: Documentation (Thread 4 + the new model)

Document the override pattern, the `base + prefixed: false` default-with-overrides idiom, the block-header footgun, the caller-prefix opt-out, and the corrected `result.error` vs `#message` ownership model.

**Files:**
- Modify: `docs/usage/writing.md`

- [ ] **Step 1: Update the message-resolution docs**

In `docs/usage/writing.md`, make these edits (one line per paragraph; no hard wrapping):

1. Replace the "result.error vs Axn::Failure#message" tip with the ownership model: `result.error` is the uniform user-facing presentation; an Axn-owned exception's `#message` now equals it; a foreign (`fails_on`) exception keeps its own technical `#message` and its user-facing copy lives only in `result.error`.
2. Add a "Header aggregation" note: nested `call!` composes every level's base, outermost first, each segment joined by its own `delimiter:`.
3. Add the "Overriding an inherited base" subsection: a subclass's `error "..."` wins (last-declared); show literal and context-derived block override; warn that **a header block must describe the action/class, not the failure reason** (interpolating `e.message` doubles it).
4. Add the "Default with specific overrides" pattern: unconditional base + `error "...", if: SomeError, prefixed: false` conditionals (the teamshares_api shape).
5. Add the "Opting out of a caller's prefix" note: drop the base, or `r = inner.call; fail!(r.error, prefixed: false) unless r.ok?`.

- [ ] **Step 2: Verify docs build / link check**

Run the repo's docs check (per `package.json` / the docs-link checker added in #131): `npm run docs:build` (or the documented command) and confirm no broken links.
Expected: builds clean.

- [ ] **Step 3: Commit**

```bash
git add docs/usage/writing.md
git commit -m "docs(messages): aggregation, ownership model, override + prefixed:false patterns

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage vs design doc (`internal-docs/specs/2026-06-26-error-message-presentation-design.md`):**
- Thread 1 (`call!` parity, raw/presentation split) → Tasks 1, 3, 6. ✓
- Thread 1 residual (dissolved by aggregation) → Task 6 step 1 (non-bang `exception.message == error`). ✓
- Thread 2 (aggregate, append model, per-segment delimiter) → Tasks 3, 4. ✓
- Thread 2a (caller-prefix opt-out, no new API) → Task 10 (docs only). ✓
- Thread 3 (ownership: stamp owned only, never foreign) → Tasks 3, 7, 8. ✓
- `user_facing` parity item → Task 7. ✓
- Thread 4 (override works; footgun; teamshares pattern) → Task 10. ✓
- Punted dominance-filter → intentionally out of scope. ✓

**Open risks to watch during execution (not placeholders — flagged decisions):**
- Task 3 assumes the context is finalized after `__record_exception` so `@action.result.error` memoizes. If a not-yet-finalized read returns a live (non-memoized) value, move the stamp to just after `@context.__finalize!`-equivalent on the failure path, or finalize explicitly before resolving.
- Task 9's `step` form must match the repo's actual `step` DSL; verify against `spec/axn/mountable/steps/steps_spec.rb` before writing the test.
- Retten retries (Async) re-enter `with_exception_handling`; the identity store naturally de-dupes by object, and a retry produces a fresh result — confirm no stale carried presentation leaks across a retry of the same exception object (add a targeted spec if the async suite surfaces it).
