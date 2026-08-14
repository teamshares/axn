# Integrity against instance-method shadowing — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a user's `def foo` or `expects :foo` cost them a convenience and nothing else — never a corrupted framework — by removing every internal dispatch through a shadowable instance name and replacing both hand-maintained reserved lists with one owner-derived rule.

**Architecture:** A new `Axn::Internal::ActionState` holds each load-bearing implementation as an `UnboundMethod` and `bind_call`s it, so internals invoke a specific method object that a shadowing `def` or generated reader cannot intercept — the technique `Axn::Internal::Identity` already uses for caller-supplied collaborators. User-facing sugar relocates into included modules, so shadowing degrades to `super`. The reserved lists are then deleted in favour of a `Method#owner` query against the three receivers a declaration can actually clobber: the action class, `Axn::Core::InternalContext`, and `Axn::Result`.

**Tech Stack:** Ruby 3.2+, RSpec, ActiveSupport (`delegate`, `class_attribute`). No new dependencies.

**Spec:** `internal-docs/specs/2026-08-14-instance-method-shadowing-integrity-design.md`

## Global Constraints

- **Non-Rails safe.** Guard any AR/Rails reference with `defined?()`. Specs live in `spec/` (plain POROs); mirror Rails-specific behaviour in `spec_rails/dummy_app/` only if a Rails-path difference appears.
- **Fail at declaration, not runtime.** Every new rejection raises when the class is *defined*, with a message saying how to fix it.
- **Pre-alpha: remove outright, no tombstone.** `internal_context` and both `RESERVED_FIELD_NAMES_*` constants are deleted, not deprecated.
- **`ContractViolation::ReservedAttributeError`** stays the error class for every declaration-time name rejection. Reuse `lib/axn/exceptions.rb`; do not invent classes.
- **Comments explain *why*, not *what*.** No historical narration ("used to X, now Y"), no ticket references in code comments.
- **CHANGELOG every user-visible change** under the top version heading, tagged `[BREAKING]` / `[BUGFIX]` / `[INTERNAL]`.
- **Never assert on `Hash#inspect` text** — CI runs Ruby 3.2/3.3/3.4 and the rendering differs.
- Run `bundle exec rspec` before every commit. From `spec_rails/dummy_app`, Rails specs need `BUNDLE_GEMFILE=Gemfile`.

---

### Task 1: `Axn::Internal::ActionState` — the funnel, with `result` and `internal_context`

**Files:**
- Create: `lib/axn/internal/action_state.rb`
- Modify: `lib/axn.rb` (add the require alongside the other `axn/internal/*` requires)
- Modify: `lib/axn/core/executor.rb:363, 495, 504, 639, 758, 760, 771, 927, 1086` (`result`), `:1170, 1441, 1574` (`internal_context`)
- Test: `spec/axn/internal/action_state_spec.rb`

**Interfaces:**
- Consumes: nothing (first task).
- Produces: `Axn::Internal::ActionState.result(action) -> Axn::Result`, `.internal_context(action) -> Axn::Core::InternalContext`, `.instance?(obj) -> Boolean`, `.result_or_nil(obj) -> Axn::Result | nil`. Later tasks add `.log`, `.inputs`, `.expose`, `.execution_context`, `.ambient_context` to this same module.

- [ ] **Step 1: Write the failing test**

```ruby
# spec/axn/internal/action_state_spec.rb
RSpec.describe Axn::Internal::ActionState do
  describe ".result" do
    it "reaches the real result through a `def result` shadow" do
      klass = build_axn do
        def result = "shadowed"
      end
      action = klass.send(:new)

      expect(action.result).to eq("shadowed")
      expect(described_class.result(action)).to be_a(Axn::Result)
    end

    it "reaches the real result through an `expects :result` reader shadow" do
      klass = build_axn { expects :result }
      action = klass.send(:new, result: 42)

      expect(action.result).to eq(42)
      expect(described_class.result(action)).to be_a(Axn::Result)
    end

    it "preserves memoization (same object across calls)" do
      action = build_axn {}.send(:new)

      expect(described_class.result(action)).to be(described_class.result(action))
    end
  end

  describe ".internal_context" do
    it "reaches the real context through a shadow" do
      klass = build_axn { expects :internal_context }
      action = klass.send(:new, internal_context: "shadowed")

      expect(described_class.internal_context(action)).to be_a(Axn::Core::InternalContext)
    end
  end

  describe ".instance? / .result_or_nil" do
    it "discriminates an action instance from a class, nil, and an unrelated object" do
      klass = build_axn {}

      expect(described_class.instance?(klass.send(:new))).to be true
      expect(described_class.instance?(klass)).to be false
      expect(described_class.instance?(nil)).to be false
      expect(described_class.instance?(Object.new)).to be false
    end

    it "returns nil rather than raising for a non-instance" do
      expect(described_class.result_or_nil(nil)).to be_nil
      expect(described_class.result_or_nil(build_axn {})).to be_nil
    end

    it "is not fooled by an object that merely responds to :result" do
      impostor = Class.new { def result = "not an action" }.new

      expect(impostor).to respond_to(:result)
      expect(described_class.result_or_nil(impostor)).to be_nil
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/internal/action_state_spec.rb`
Expected: FAIL — `uninitialized constant Axn::Internal::ActionState`

- [ ] **Step 3: Write the implementation**

```ruby
# lib/axn/internal/action_state.rb
# frozen_string_literal: true

require "axn/internal/identity"

module Axn
  module Internal
    # How axn's own machinery reads an action's state.
    #
    # `include Axn` puts helpers on the user's class, and a user may take any of those names — with a
    # `def`, or with a field declaration whose generated reader lands on the same class. A name is
    # therefore not a reliable way to reach an implementation: dispatching `action.result` reaches
    # whatever currently answers to `result`, which is how a user's declaration used to corrupt the
    # framework instead of merely costing them a helper.
    #
    # So internals never dispatch. Each implementation is held as an UnboundMethod and `bind_call`ed,
    # naming the method object directly — the same technique, and the same reason, as
    # `Internal::Identity` (for collaborators axn has no cause to trust) and the executor's
    # `FAILURE_PRESENT_AS`. Shadowing then costs the user their own convenience and nothing else.
    module ActionState
      RESULT = Axn::Core::Contract::InstanceMethods.instance_method(:result)
      INTERNAL_CONTEXT = Axn::Core::Contract::InstanceMethods.instance_method(:internal_context)
      private_constant :RESULT, :INTERNAL_CONTEXT

      module_function

      def result(action) = RESULT.bind_call(action)

      def internal_context(action) = INTERNAL_CONTEXT.bind_call(action)

      # True only for an action INSTANCE. Several callers legitimately hold nil or an action CLASS
      # instead (a guard firing before the instance exists), and `respond_to?(:result)` cannot tell
      # them apart from an instance whose `result` a user has taken — it answers true and then hands
      # back a String.
      def instance?(obj) = Identity.kind?(obj, ::Axn)

      # The result when there is one, nil for every shape that cannot have one — a degraded report
      # naming the exception beats no report at all.
      def result_or_nil(obj) = instance?(obj) ? result(obj) : nil
    end
  end
end
```

Add to `lib/axn.rb`, after `axn/core` is loaded (the UnboundMethod constants resolve at load time, so `Axn::Core::Contract` must already be defined):

```ruby
require "axn/internal/action_state"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/axn/internal/action_state_spec.rb`
Expected: PASS

- [ ] **Step 5: Migrate the executor's `result` and `internal_context` reads**

In `lib/axn/core/executor.rb`, replace every `@action.result` with `Internal::ActionState.result(@action)` and every `@action.internal_context` with `Internal::ActionState.internal_context(@action)`. The nine `result` sites are at `:363, 495, 504, 639, 758, 760, 771, 927, 1086`; the three `internal_context` sites at `:1170, 1441, 1574`.

Where a site reads `result` more than once, hoist it to a local first — `:758-760` and `:771` each read it two or three times:

```ruby
def log_after
  result = Internal::ActionState.result(@action)
  return unless result.finalized?

  level = @action_class._auto_log_level_for(result.outcome)
  return unless level

  log_after_at_level(level, result)
end
```

Leave `@action.call` (`:232`) exactly as it is — the executor must invoke the user's method, and that is the one name the framework cannot surrender.

- [ ] **Step 6: Verify the ticket's headline breakage is fixed**

```ruby
# spec/axn/core/method_shadowing_integrity_spec.rb
RSpec.describe "shadowing an axn instance method" do
  it "does not corrupt the framework when `result` is shadowed by a def" do
    klass = build_axn do
      exposes :out
      def result = "shadowed"
      def call = expose(out: 1)
    end

    result = klass.call

    expect(result).to be_ok
    expect(result.out).to eq(1)
  end

  it "does not corrupt the framework when `result` is shadowed by a declaration" do
    klass = build_axn do
      expects :result
      exposes :out
      def call = expose(out: result * 2)
    end

    outcome = klass.call(result: 21)

    expect(outcome).to be_ok
    expect(outcome.out).to eq(42)
  end
end
```

Run: `bundle exec rspec spec/axn/core/method_shadowing_integrity_spec.rb`
Expected: PASS — previously `NoMethodError: undefined method 'finalized?' for an instance of String`

- [ ] **Step 7: Run the full suite**

Run: `bundle exec rspec`
Expected: PASS, no new failures

- [ ] **Step 8: Commit**

```bash
git add lib/axn/internal/action_state.rb lib/axn.rb lib/axn/core/executor.rb \
        spec/axn/internal/action_state_spec.rb spec/axn/core/method_shadowing_integrity_spec.rb
git commit -m "PRO-3062: read action state through a bound call, not a dispatchable name"
```

---

### Task 2: Relocate the logging sugar into a module so `super` works

**Files:**
- Modify: `lib/axn/core/logging.rb:13` (the `delegate` moves out of `class_eval`)
- Test: `spec/axn/core/logging_spec.rb` (add cases; create if absent)

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `Axn::Core::Logging::InstanceMethods`, owning `log` plus the five `LEVELS` aliases. Task 3 takes `instance_method(:log)` from it.

- [ ] **Step 1: Write the failing test**

```ruby
RSpec.describe Axn::Core::Logging do
  it "lets a user wrap `log` with super" do
    logged = []
    allow(Axn.config.logger).to receive(:info) { |msg| logged << msg }

    klass = build_axn do
      def log(message, **) = super("[wrapped] #{message}")
      def call = log("hello", level: :info)
    end
    klass.call

    expect(logged.last).to include("[wrapped] hello")
  end

  it "owns the helpers in a module rather than on the user's class" do
    klass = build_axn {}

    expect(klass.instance_method(:log).owner).to eq(described_class::InstanceMethods)
    expect(klass.instance_method(:info).owner).to eq(described_class::InstanceMethods)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/core/logging_spec.rb`
Expected: FAIL — `super: no superclass method 'log'`, and `owner` is the action class

- [ ] **Step 3: Write the implementation**

In `lib/axn/core/logging.rb`, move the delegation off the class and into a module:

```ruby
module Axn
  module Core
    module Logging
      LEVELS = %i[debug info warn error fatal].freeze

      # In a module rather than stamped onto the action class, so a user who wants to wrap one of
      # these (to prefix every message, say) can `def log` and reach axn's via `super` — and so a user
      # who takes the name outright loses only the helper. Internals never come through here.
      module InstanceMethods
        delegate :log, *LEVELS, to: :class
      end

      def self.included(base)
        base.class_eval do
          extend ClassMethods
          include InstanceMethods
        end
      end
      # ... ClassMethods unchanged
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/axn/core/logging_spec.rb`
Expected: PASS

- [ ] **Step 5: Run the full suite**

Run: `bundle exec rspec`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add lib/axn/core/logging.rb spec/axn/core/logging_spec.rb
git commit -m "PRO-3062: own the logging helpers in a module so a user can wrap them"
```

---

### Task 3: Finish the funnel — `log`, `inputs`, `expose`, `execution_context`, `ambient_context`

**Files:**
- Modify: `lib/axn/internal/action_state.rb` (add the members)
- Modify: `lib/axn/configuration.rb:243-244, 275, 290`
- Modify: `lib/axn/extensions.rb:274-276, 323-328`
- Modify: `lib/axn/internal/exception_context.rb:34`
- Modify: `lib/axn/core/contract_for_subfields.rb:289`
- Modify: `lib/axn/core/flow/handlers/invoker.rb:55`, `matcher.rb:58, 78`, `resolvers/message_resolver.rb:174, 197, 205`
- Modify: `lib/axn/core.rb` (`fail!`, `done!`, `forward!` route exposures through the funnel)
- Modify: `lib/axn/internal/call_logger.rb:64` (`inputs_for_logging` / `outputs_for_logging`)
- Test: `spec/axn/internal/action_state_spec.rb`, `spec/axn/core/method_shadowing_integrity_spec.rb`

**Interfaces:**
- Consumes: `ActionState.instance?`, `.result`, `.internal_context` (Task 1); `Logging::InstanceMethods` (Task 2).
- Produces: `ActionState.log(target, message, **)`, `.inputs(action) -> Hash`, `.expose(action, *args, **kwargs)`, `.execution_context(action) -> Hash`, `.ambient_context(action)`, `.inputs_for_logging(action)`, `.outputs_for_logging(action)`.

- [ ] **Step 1: Write the failing test**

```ruby
# spec/axn/internal/action_state_spec.rb — add
describe ".log" do
  it "reaches the logger through a `log` shadow" do
    logged = []
    allow(Axn.config.logger).to receive(:warn) { |msg| logged << msg }

    klass = build_axn { expects :log }
    action = klass.send(:new, log: "an input value")

    described_class.log(action, "internal message", level: :warn)

    expect(logged.last).to include("internal message")
  end

  it "accepts an action CLASS and nil, which several guards legitimately hold" do
    logged = []
    allow(Axn.config.logger).to receive(:warn) { |msg| logged << msg }

    described_class.log(build_axn {}, "from a class", level: :warn)
    described_class.log(nil, "from nil", level: :warn)

    expect(logged).to include(a_string_including("from a class"), a_string_including("from nil"))
  end
end

describe ".expose / .inputs" do
  it "reaches the real implementations through shadows" do
    klass = build_axn do
      expects :inputs
      exposes :out
      def expose(*) = raise("user's expose must not be called by internals")
    end
    action = klass.send(:new, inputs: "an input value")

    described_class.expose(action, out: 7)

    expect(described_class.result(action).out).to eq(7)
    expect(described_class.inputs(action)).to eq({ inputs: "an input value" })
  end
end
```

```ruby
# spec/axn/core/method_shadowing_integrity_spec.rb — add
it "still exposes from fail! when `expose` is shadowed" do
  klass = build_axn do
    exposes :out
    def expose(*) = nil
    def call = fail!("nope", out: 3)
  end

  result = klass.call

  expect(result.error).to eq("nope")
  expect(result.out).to eq(3)
end

it "logs the handled-exception line when `log` is shadowed by a declaration" do
  logged = []
  allow(Axn.config.logger).to receive(:info) { |msg| logged << msg }

  klass = build_axn do
    expects :log
    def call = raise("boom")
  end
  klass.call(log: "an input value")

  expect(logged).to include(a_string_including("Handled exception"))
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/internal/action_state_spec.rb spec/axn/core/method_shadowing_integrity_spec.rb`
Expected: FAIL — `undefined method 'log' for module Axn::Internal::ActionState`, and the `fail!` case exposes nothing

- [ ] **Step 3: Add the funnel members**

```ruby
# lib/axn/internal/action_state.rb
LOG = Axn::Core::Logging::InstanceMethods.instance_method(:log)
INPUTS = Axn::Core::Contract::InstanceMethods.instance_method(:inputs)
EXPOSE = Axn::Core::Contract::InstanceMethods.instance_method(:expose)
EXECUTION_CONTEXT = Axn::Core::Contract::InstanceMethods.instance_method(:execution_context)
AMBIENT_CONTEXT = Axn::Core::AmbientContext.instance_method(:ambient_context)
INPUTS_FOR_LOGGING = Axn::Core::Contract::InstanceMethods.instance_method(:inputs_for_logging)
OUTPUTS_FOR_LOGGING = Axn::Core::Contract::InstanceMethods.instance_method(:outputs_for_logging)
private_constant :LOG, :INPUTS, :EXPOSE, :EXECUTION_CONTEXT, :AMBIENT_CONTEXT,
                 :INPUTS_FOR_LOGGING, :OUTPUTS_FOR_LOGGING

def inputs(action) = INPUTS.bind_call(action)
def expose(action, *args, **kwargs) = EXPOSE.bind_call(action, *args, **kwargs)
def execution_context(action) = EXECUTION_CONTEXT.bind_call(action)
def ambient_context(action) = AMBIENT_CONTEXT.bind_call(action)
def inputs_for_logging(action) = INPUTS_FOR_LOGGING.bind_call(action)
def outputs_for_logging(action) = OUTPUTS_FOR_LOGGING.bind_call(action)

# Three shapes reach here and all three are legitimate: an action instance (bound, so a shadowed
# `log` cannot intercept), an action CLASS at a guard that fires before the instance exists (its
# class-level `log` is the right target), and nil at a guard with no action at all.
def log(target, message, **)
  return LOG.bind_call(target, message, **) if instance?(target)
  return target.log(message, **) if Identity.kind?(target, ::Class) && target < ::Axn

  Axn.config.logger.warn(message)
end
```

- [ ] **Step 4: Migrate the call sites**

`lib/axn/configuration.rb` — the `respond_to?` probe becomes an honest question, and both `log` calls route through the funnel:

```ruby
def on_exception(e, action:, context: {})
  resolved_error = Axn::Internal::ActionState.result_or_nil(action)&.error
  if resolved_error
    # ... the existing default_message / detail logic, unchanged
  else
    detail = e
  end

  msg = "Handled exception (#{Axn::Internal::Rendering.class_name(e)}): #{_rendered_detail(detail)}"
  msg = ("#" * 10) + " #{msg} " + ("#" * 10) unless Axn.config.env.production?
  Axn::Internal::ActionState.log(action, msg)

  return unless @on_exception

  if Axn::Extensions.reporting?
    Axn::Internal::ActionState.log(action, "Skipping nested exception report: a report handler is already on the stack.")
    return
  end
  # ... unchanged
```

`lib/axn/extensions.rb:274-276` — `_surrounding_outcome`'s defensive re-probes go away, because the funnel's answer is trustworthy:

```ruby
def _surrounding_outcome(action)
  result = Internal::ActionState.result_or_nil(action)
  return nil unless result&.finalized?

  Internal::Text.renderable(result.outcome.to_s)
rescue StandardError, *SWALLOWABLE_BEYOND_STANDARD_ERROR
  nil
end
```

`lib/axn/extensions.rb:323` — `_emit_warning` keeps its two-attempt structure exactly; only the dispatch changes:

```ruby
def _emit_warning(action, message)
  Internal::ActionState.log(action, message, level: :warn)
rescue StandardError, *SWALLOWABLE_BEYOND_STANDARD_ERROR
  return if action.nil?

  begin
    Axn.config.logger.send(:warn, message)
  rescue StandardError, *SWALLOWABLE_BEYOND_STANDARD_ERROR
    nil
  end
end
```

`lib/axn/internal/exception_context.rb:34` → `Internal::ActionState.execution_context(action)`.
`lib/axn/core/contract_for_subfields.rb:289` → `[Internal::ActionState.internal_context(action), :"@_memoized_reader_#{config.field}"]`.
`lib/axn/internal/call_logger.rb:64` → `Internal::ActionState.inputs_for_logging(context_instance)` (and the outbound branch to `.outputs_for_logging`).
`flow/handlers/invoker.rb:55`, `matcher.rb:58, 78`, `resolvers/message_resolver.rb:174, 197, 205` → `Internal::ActionState.log(action, "…", level: :warn)`.

`lib/axn/core.rb` — `fail!` and `done!` stop calling their own public `expose`:

```ruby
def fail!(message = nil, standalone: false, **exposures)
  Internal::ActionState.expose(self, **exposures) if exposures.any?
  raise Axn::Failure.new(message, standalone:, action: self)
end
```

Apply the same substitution in `done!` and in `_expose_from_result`'s caller path used by `forward!`.

- [ ] **Step 5: Run the tests**

Run: `bundle exec rspec spec/axn/internal/action_state_spec.rb spec/axn/core/method_shadowing_integrity_spec.rb`
Expected: PASS

- [ ] **Step 6: Run the full suite**

Run: `bundle exec rspec`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add lib/axn/internal/action_state.rb lib/axn/configuration.rb lib/axn/extensions.rb \
        lib/axn/internal/exception_context.rb lib/axn/internal/call_logger.rb \
        lib/axn/core/contract_for_subfields.rb lib/axn/core/flow/handlers lib/axn/core.rb \
        spec/axn/internal/action_state_spec.rb spec/axn/core/method_shadowing_integrity_spec.rb
git commit -m "PRO-3062: route every remaining internal read through the bound-call funnel"
```

---

### Task 4: Generated readers stop dispatching `internal_context`, which leaves the public surface

**Files:**
- Modify: `lib/axn/core/contract.rb:1881` (`_define_field_reader`), `:2545` (remove the public `internal_context`)
- Modify: any remaining `internal_context` reference surfaced by grep
- Test: `spec/axn/core/method_shadowing_integrity_spec.rb`

**Interfaces:**
- Consumes: `ActionState.internal_context` (Task 1).
- Produces: no public `internal_context` on an action; the name is free for user declarations.

- [ ] **Step 1: Write the failing test**

```ruby
it "does not poison every other field's reader when `internal_context` is declared" do
  klass = build_axn do
    expects :internal_context, :other
    exposes :out
    def call = expose(out: "#{internal_context}/#{other}")
  end

  result = klass.call(internal_context: "mine", other: "theirs")

  expect(result).to be_ok
  expect(result.out).to eq("mine/theirs")
end

it "no longer injects internal_context as public surface" do
  expect(build_axn {}.public_method_defined?(:internal_context)).to be false
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/core/method_shadowing_integrity_spec.rb`
Expected: FAIL — outcome is `exception`, and `internal_context` is still public

- [ ] **Step 3: Write the implementation**

In `_define_field_reader` (`contract.rb:1881`), the reader body must not dispatch a name a sibling declaration may have taken:

```ruby
def _define_field_reader(reader, source = reader, target: self)
  # Bound rather than dispatched: this body runs on the user's class, where a sibling declaration
  # (`expects :internal_context`) or a `def` could otherwise redirect every field's read.
  target.define_method(reader) { Axn::Internal::ActionState.internal_context(self).public_send(source) }
end
```

Then delete the public reader at `contract.rb:2545` and make the implementation private to the module, so `ActionState`'s UnboundMethod still resolves while nothing dispatches it:

```ruby
module InstanceMethods
  def result = @__result ||= _build_context_facade(:outbound)

  private

  def internal_context = @__internal_context ||= _build_context_facade(:inbound)
```

`UnboundMethod` binding is unaffected by visibility, so `ActionState.internal_context` keeps working; update its constant to `instance_method(:internal_context)` only if the lookup now needs `private_instance_method` — verify by running the Task 1 spec.

Grep for stragglers and convert each: `grep -rn "internal_context" lib/`. `delegate :default_error, :default_success, to: :internal_context` (`:2561`) is an implicit-receiver dispatch from within the same object and must become explicit:

```ruby
def default_error = Internal::ActionState.internal_context(self).default_error
def default_success = Internal::ActionState.internal_context(self).default_success
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/axn/core/method_shadowing_integrity_spec.rb spec/axn/internal/action_state_spec.rb`
Expected: PASS

- [ ] **Step 5: Run the full suite**

Run: `bundle exec rspec`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add lib/axn/core/contract.rb spec/axn/core/method_shadowing_integrity_spec.rb
git commit -m "PRO-3062: bind the generated reader's context read and unpublish internal_context"
```

---

### Task 5: Close the `class_attribute` instance-accessor leak

**Files:**
- Modify: `lib/axn/core/hooks.rb:8-10`, `lib/axn/core/contract.rb:30`, `lib/axn/core/contract_for_subfields.rb:20`, `lib/axn/core/tagging.rb:26-27`, `lib/axn/core/automatic_logging.rb:16`, `lib/axn/async.rb:14, 19, 20`, `lib/axn/mountable.rb:78`, and the `_callbacks_registry` / `_messages_registry` / `_fails_on_matchers` / `_batch_enqueue_configs` declarations
- Modify: `lib/axn/result.rb:145` (the one instance-side read)
- Test: `spec/axn/core/method_shadowing_integrity_spec.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: no unprefixed `class_attribute` instance accessors on an action.

- [ ] **Step 1: Write the failing test**

```ruby
it "injects no unprefixed class_attribute accessors onto the instance" do
  leaked = build_axn {}.public_instance_methods.grep_v(/\A_/) &
           %i[before_hooks after_hooks around_hooks internal_field_configs
              external_field_configs subfield_configs]

  expect(leaked).to be_empty
end

it "exposes a field named for a config accessor without breaking the Result" do
  klass = build_axn do
    exposes :out
    def call = expose(out: 1)
  end

  expect(klass.call.out).to eq(1)
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/core/method_shadowing_integrity_spec.rb`
Expected: FAIL — `leaked` contains all six names

- [ ] **Step 3: Move the one instance-side read first**

`lib/axn/result.rb:145` reads `action.external_field_configs` off the *instance*. Change it to the class:

```ruby
def _define_boolean_predicate_readers
  action.class.external_field_configs.each do |config|
```

- [ ] **Step 4: Add `instance_accessor: false`**

Add `instance_accessor: false` to every `class_attribute` call listed under **Files**, matching the style already used in `tool_declaration.rb:13`, `versioning.rb:13`, and `naming.rb:11`. Example:

```ruby
class_attribute :around_hooks, instance_accessor: false, default: []
class_attribute :before_hooks, instance_accessor: false, default: []
class_attribute :after_hooks, instance_accessor: false, default: []
```

- [ ] **Step 5: Run the full suite to surface any other instance-side read**

Run: `bundle exec rspec`
Expected: PASS. Any `NoMethodError` here names another instance-side read — convert it to `self.class.<name>` and re-run.

- [ ] **Step 6: Commit**

```bash
git add lib/axn/core/hooks.rb lib/axn/core/contract.rb lib/axn/core/contract_for_subfields.rb \
        lib/axn/core/tagging.rb lib/axn/core/automatic_logging.rb lib/axn/async.rb \
        lib/axn/mountable.rb lib/axn/result.rb spec/axn/core/method_shadowing_integrity_spec.rb
git commit -m "PRO-3062: stop leaking class_attribute accessors onto the action instance"
```

---

### Task 6: One derived rule replaces `RESERVED_FIELD_NAMES_FOR_EXPECTATIONS`

**Files:**
- Create: `lib/axn/internal/name_ownership.rb`
- Modify: `lib/axn.rb` (require)
- Modify: `lib/axn/core/contract.rb:507` (the `expects` check), `:990` (`_validate_reader_names!`), `:1029` (delete the constant)
- Test: `spec/axn/internal/name_ownership_spec.rb`, `spec/axn/core/contract/reserved_names_spec.rb`

**Interfaces:**
- Consumes: the sugar modules established in Tasks 2-4.
- Produces: `Axn::Internal::NameOwnership.conflict_for(klass, name) -> Module | Symbol | nil`, `.surrenderable?(owner) -> Boolean`.

- [ ] **Step 1: Write the failing test**

```ruby
# spec/axn/core/contract/reserved_names_spec.rb
RSpec.describe "reserved names for expectations" do
  describe "names a user may take" do
    %i[result log info error expose inputs fail! forward! execution_context ambient_context].each do |name|
      it "allows `expects :#{name}`" do
        expect { build_axn { expects name } }.not_to raise_error
      end
    end

    it "reads the declared value back" do
      klass = build_axn do
        expects :log
        exposes :out
        def call = expose(out: log)
      end

      expect(klass.call(log: "a value").out).to eq("a value")
    end
  end

  describe "names the framework cannot surrender" do
    it "rejects `expects :call` rather than silently skipping the action body" do
      expect { build_axn { expects :call } }
        .to raise_error(Axn::ContractViolation::ReservedAttributeError, /call/)
    end

    it "rejects `expects :_run`" do
      expect { build_axn { expects :_run } }.to raise_error(Axn::ContractViolation::ReservedAttributeError)
    end
  end

  describe "names owned by Ruby or the reader's own facade" do
    it "rejects `expects :class` rather than recursing until SystemStackError" do
      expect { build_axn { expects :class } }
        .to raise_error(Axn::ContractViolation::ReservedAttributeError, /class/)
    end

    %i[hash send inspect declared_fields default_error].each do |name|
      it "rejects `expects :#{name}`" do
        expect { build_axn { expects name } }.to raise_error(Axn::ContractViolation::ReservedAttributeError)
      end
    end
  end

  describe "names owned by the user's own code" do
    it "rejects a declaration that would clobber an earlier def" do
      expect do
        Class.new do
          include Axn
          def helper = "mine"
          expects :helper
        end
      end.to raise_error(Axn::ContractViolation::ReservedAttributeError, /helper/)
    end

    it "still allows a def AFTER the declaration (the wrap idiom)" do
      klass = build_axn do
        expects :name
        exposes :out
        def call = expose(out: name)
        def name = "wrapped"
      end

      expect(klass.call(name: "raw").out).to eq("wrapped")
    end
  end

  it "applies the same rule to an `as:` reader name" do
    expect { build_axn { expects :thing, as: :class } }
      .to raise_error(Axn::ContractViolation::ReservedAttributeError, /class/)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/core/contract/reserved_names_spec.rb`
Expected: FAIL — `expects :call` succeeds, `expects :class` raises `SystemStackError` rather than the declaration error, `expects :result` raises today only for exposures

- [ ] **Step 3: Write the implementation**

```ruby
# lib/axn/internal/name_ownership.rb
# frozen_string_literal: true

module Axn
  module Internal
    # Whether a declared reader may take a name, decided by who currently OWNS it rather than by a
    # list of names kept by hand.
    #
    # A declared reader is defined directly on the action class (and an exposure's on the Result's
    # singleton), so it outranks everything — axn's helpers, Ruby's own methods, and anything the
    # user wrote. Surrendering an axn CONVENIENCE is fine and deliberate: internals never dispatch
    # those names, so the cost is the helper and nothing more. Surrendering anything else is not, and
    # is refused here, at declaration, naming the owner.
    module NameOwnership
      # Axn's user-facing sugar — the surface a declaration may take over. Modules, not names: a
      # helper added to one of these is covered without editing anything here.
      SURRENDERABLE_OWNERS = %w[
        Axn::Core
        Axn::Core::Contract::InstanceMethods
        Axn::Core::Logging::InstanceMethods
        Axn::Core::AmbientContext
      ].freeze

      # Load-bearing whatever owns them: the executor invokes `call`, and `.call` invokes `_run`.
      UNSURRENDERABLE = %i[call _run].freeze

      module_function

      # nil when `name` is free to take; otherwise what stands in the way — the owning Module, or
      # :unsurrenderable for a name no owner could make available.
      def conflict_for(klass, name)
        name = name.to_sym
        return :unsurrenderable if UNSURRENDERABLE.include?(name)

        owner = owner_of(klass, name)
        return nil if owner.nil? || surrenderable?(owner)

        owner
      end

      def owner_of(klass, name)
        return nil unless klass.method_defined?(name) || klass.private_method_defined?(name)

        klass.instance_method(name).owner
      end

      def surrenderable?(owner) = SURRENDERABLE_OWNERS.include?(owner.to_s)

      def describe(conflict)
        return "axn itself (the framework dispatches it)" if conflict == :unsurrenderable

        "#{conflict} (not axn's to surrender)"
      end
    end
  end
end
```

In `contract.rb`, replace the constant lookup at `:507`:

```ruby
fields.each { |field| _reject_shadowed_name!(field) }
```

and add, near `_reader_name_available?`:

```ruby
# Both receivers a declared inbound reader can clobber: the action class, where the reader is
# defined, and InternalContext, where the value is read from. Nothing on the facade is sugar, so
# nothing there is surrenderable.
def _reject_shadowed_name!(name)
  return if _reader_owners.key?(name.to_sym) || _inferred_reader?(name)

  conflict = Internal::NameOwnership.conflict_for(self, name) ||
             Internal::NameOwnership.owner_of(Axn::Core::InternalContext, name)
  return unless conflict

  raise ContractViolation::ReservedAttributeError.new(name, owner: Internal::NameOwnership.describe(conflict))
end
```

Apply the same call in `_validate_reader_names!` (`:990`) in place of its `RESERVED_FIELD_NAMES_FOR_EXPECTATIONS` check, then delete the constant at `:1029`.

Extend `ContractViolation::ReservedAttributeError` in `lib/axn/exceptions.rb` to accept the optional `owner:` and name it in the message, keeping the existing single-argument form working.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/axn/core/contract/reserved_names_spec.rb`
Expected: PASS

- [ ] **Step 5: Run the full suite and reconcile**

Run: `bundle exec rspec`
Expected: PASS. A failure here is signal, not noise — it names a spec declaring a field the new rule refuses. For each, decide whether the name is genuinely surrenderable (add its owning module to `SURRENDERABLE_OWNERS`) or the spec should rename the field. Do not widen the list to silence a failure without saying why in the commit message.

- [ ] **Step 6: Audit the guard by mutation**

Invert the guard (`return unless conflict` → `return if conflict`), re-run `spec/axn/core/contract/reserved_names_spec.rb`, and confirm the rejection examples fail. Then restore it and introduce an over-eager version (treat every owner as a conflict) and confirm the "names a user may take" examples fail — the controls, which mutation alone cannot audit.

- [ ] **Step 7: Commit**

```bash
git add lib/axn/internal/name_ownership.rb lib/axn.rb lib/axn/core/contract.rb \
        lib/axn/exceptions.rb spec/axn/internal/name_ownership_spec.rb \
        spec/axn/core/contract/reserved_names_spec.rb
git commit -m "PRO-3062: derive the expectations reserved rule from method ownership"
```

---

### Task 7: The same rule for exposures, against `Axn::Result`

**Files:**
- Modify: `lib/axn/core/contract.rb:596` (the `exposes` check), `:1039` (delete the constant)
- Test: `spec/axn/core/contract/reserved_names_spec.rb`

**Interfaces:**
- Consumes: `NameOwnership.owner_of` (Task 6).
- Produces: nothing new.

- [ ] **Step 1: Write the failing test**

```ruby
RSpec.describe "reserved names for exposures" do
  describe "names Result owns" do
    %i[error message ok? outcome exception elapsed_time finalized? fail!
       declared_fields deconstruct_keys hash class].each do |name|
      it "rejects `exposes :#{name}`" do
        expect { build_axn { exposes name } }
          .to raise_error(Axn::ContractViolation::ReservedAttributeError)
      end
    end

    it "rejects deconstruct_keys rather than breaking pattern matching" do
      expect { build_axn { exposes :deconstruct_keys } }
        .to raise_error(Axn::ContractViolation::ReservedAttributeError, /deconstruct_keys/)
    end
  end

  describe "names lifted because Result does not own them" do
    %i[each_pair ok result standalone inputs ambient_context default_error].each do |name|
      it "allows `exposes :#{name}`" do
        klass = build_axn do
          exposes name
          define_method(:call) { expose(name => "value") }
        end

        expect(klass.call.public_send(name)).to eq("value")
      end
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/core/contract/reserved_names_spec.rb`
Expected: FAIL — `exposes :declared_fields` raises `NoMethodError` at `result.rb:145` rather than at declaration; `exposes :hash` / `:class` / `:deconstruct_keys` succeed; the seven lifted names still raise

- [ ] **Step 3: Write the implementation**

Replace the check at `contract.rb:596`:

```ruby
# Judged against Result, because that is where an exposure's reader is defined — on the
# instance's singleton, which outranks Result's own API and Ruby's alike. Nothing there is
# sugar, so nothing is surrenderable.
fields.each do |field|
  owner = Internal::NameOwnership.owner_of(Axn::Result, field)
  next unless owner

  raise ContractViolation::ReservedAttributeError.new(field, owner: Internal::NameOwnership.describe(owner))
end
```

Delete `RESERVED_FIELD_NAMES_FOR_EXPOSURES` at `:1039`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/axn/core/contract/reserved_names_spec.rb`
Expected: PASS

- [ ] **Step 5: Run the full suite and reconcile**

Run: `bundle exec rspec`
Expected: PASS. As in Task 6, treat a failure as a spec declaring a now-refused exposure name and rename it.

- [ ] **Step 6: Commit**

```bash
git add lib/axn/core/contract.rb spec/axn/core/contract/reserved_names_spec.rb
git commit -m "PRO-3062: derive the exposures reserved rule from Result's method table"
```

---

### Task 8: Enforce the pattern, then document it

**Files:**
- Create: `spec/axn/internal/no_shadowable_dispatch_spec.rb`
- Modify: `AGENTS.md` (under "DSL & API patterns")
- Modify: `CHANGELOG.md`
- Test: the enforcement spec is itself the test

**Interfaces:**
- Consumes: everything above.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Write the enforcement spec**

```ruby
# spec/axn/internal/no_shadowable_dispatch_spec.rb
RSpec.describe "internal dispatch through shadowable instance names" do
  let(:sugar) do
    %w[result internal_context inputs expose log debug info warn error fatal
       execution_context ambient_context default_error default_success]
  end

  # The executor must invoke the user's own method, so this one dispatch is the point.
  let(:allowed) { ["@action.call"] }

  it "does not appear anywhere in lib/" do
    pattern = /(@?action)\.(#{sugar.join('|')})\b/
    offenders = Dir[File.expand_path("../../../lib/**/*.rb", __FILE__)].flat_map do |path|
      File.readlines(path).each_with_index.filter_map do |line, index|
        next if line.strip.start_with?("#")
        next unless line.match?(pattern)
        next if ALLOWED.any? { |allowed| line.include?(allowed) }

        "#{path.sub(%r{.*/lib/}, 'lib/')}:#{index + 1}: #{line.strip}"
      end
    end

    expect(offenders).to be_empty, <<~MSG
      Internals must read action state through Axn::Internal::ActionState, which binds the
      implementation rather than dispatching a name a user can take. Offending lines:

      #{offenders.join("\n")}
    MSG
  end
end
```

- [ ] **Step 2: Run it**

Run: `bundle exec rspec spec/axn/internal/no_shadowable_dispatch_spec.rb`
Expected: PASS. If it fails, a call site was missed in Tasks 1-4 — migrate it rather than widening `ALLOWED`.

- [ ] **Step 3: Document the pattern in `AGENTS.md`**

Add under "DSL & API patterns":

```markdown
- **Internals never dispatch a name a user can take.** `include Axn` puts helpers on the user's
  class, and a field declaration's reader lands there too — so `action.result` reaches whatever
  currently answers to `result`. Read action state through `Axn::Internal::ActionState`, which holds
  each implementation as an `UnboundMethod` and `bind_call`s it. `@action.call` is the one exception,
  and it is the reason `call` is unsurrenderable. New user-facing sugar goes in an included module
  (never `class_eval`'d onto the class) so a user can wrap it with `super`; new `class_attribute`s
  take `instance_accessor: false`. `spec/axn/internal/no_shadowable_dispatch_spec.rb` enforces this.
- **Reserved names are derived from ownership, never listed.** Whether a declaration may take a name
  is `Axn::Internal::NameOwnership`'s question, asked of the receivers the reader is defined on — the
  action class and `Axn::Core::InternalContext` for `expects`, `Axn::Result` for `exposes`. Axn's own
  sugar modules are surrenderable; Ruby's methods, the user's own code, and `call`/`_run` are not. To
  make a new helper surrenderable, add its MODULE to `SURRENDERABLE_OWNERS` — never a bare name.
```

- [ ] **Step 4: Write the CHANGELOG entries**

Add under the top version heading (confirm from `git tag` and rubygems which state the file is in — a version heading with no matching tag is the unreleased section):

```markdown
- [BUGFIX] Shadowing an axn instance method no longer corrupts the framework. `def result`,
  `expects :result` and `expects :log` previously produced a swallowed internal `NoMethodError`;
  `expects :internal_context` broke every other field's reader; `expects :call` reported success for
  an action body that never ran. Internals now read action state through a bound call that a
  shadowing definition cannot intercept, so taking one of these names costs only the helper.
- [BREAKING] Declaration-time name checks are derived from method ownership rather than two
  hand-maintained lists. Newly rejected: `expects :call` / `:_run`, any name owned by Ruby
  (`expects :class`, which previously recursed until `SystemStackError`), any name a `def` earlier in
  the class body owns, and `exposes :declared_fields` / `:deconstruct_keys` / `:hash` / `:class`,
  which previously clobbered the Result silently. Newly allowed: `expects :result`, `:log`, `:error`
  and the rest of axn's user-facing sugar, plus `exposes :each_pair`, `:ok`, `:result`,
  `:standalone`, `:inputs`, `:ambient_context` and `:default_error`, which named methods `Axn::Result`
  does not have.
- [BREAKING] `internal_context` is no longer a public instance method — it was framework plumbing,
  and the name is now free for user declarations.
- [INTERNAL] The logging helpers (`log`, `debug`, `info`, `warn`, `error`, `fatal`) are defined in a
  module instead of on the action class, so `def log(msg) = super("[prefix] #{msg}")` now works.
- [INTERNAL] `class_attribute`s no longer leak unprefixed instance accessors (`before_hooks`,
  `after_hooks`, `around_hooks`, `internal_field_configs`, `external_field_configs`,
  `subfield_configs`).
```

- [ ] **Step 5: Run the full suite**

Run: `bundle exec rspec`
Expected: PASS

Then the Rails path:

Run: `cd spec_rails/dummy_app && BUNDLE_GEMFILE=Gemfile bundle exec rspec ../`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add spec/axn/internal/no_shadowable_dispatch_spec.rb AGENTS.md CHANGELOG.md
git commit -m "PRO-3062: enforce and document the no-shadowable-dispatch rule"
```

---

## Verification against the ticket's acceptance sketch

Run this probe after Task 8 and confirm each line. Every case below is one the ticket or the spec's probe section recorded as broken.

```ruby
# All four ticket cases, plus the five the probe added
def result           → runs correctly, result.out reads back        (Task 1)
expects :result      → runs correctly, the field reads back         (Task 1)
expects :log         → runs correctly, the field reads back         (Task 3)
def expose           → fail!'s exposures still land                 (Task 3)
expects :internal_context → every other reader still resolves       (Task 4)
expects :call        → ReservedAttributeError at declaration        (Task 6)
expects :class       → ReservedAttributeError, not SystemStackError (Task 6)
exposes :declared_fields  → ReservedAttributeError at declaration   (Task 7)
exposes :deconstruct_keys → ReservedAttributeError at declaration   (Task 7)
```

And the negative, which is the property that ties the whole ticket together: **no internal error may reach a side channel** in any case above. Assert it against the `on_ignored_exception` seam rather than by eyeballing log output — a swallowed error should fail a test, not print a warning.

Add this to `spec/axn/core/method_shadowing_integrity_spec.rb` in Task 1, and wrap every example in the file with it from then on:

```ruby
around do |example|
  swallowed = []
  original = Axn.config.on_ignored_exception
  Axn.config.on_ignored_exception = ->(exception, **) { swallowed << exception }

  example.run

  Axn.config.on_ignored_exception = original
  expect(swallowed).to be_empty, "axn swallowed #{swallowed.map(&:class).join(', ')} into a side channel"
end
```

This is what distinguishes a real fix from a moved symptom: before Task 1, `def result` swallows two `NoMethodError`s here before raising a third.
