# `on_enqueue_all` Hook Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a declarative `on_enqueue_all` callback that runs once per fan-out run, after enqueueing completes, receiving the exact enqueued count and an honest per-field sources hash.

**Architecture:** A new DSL method (`on_enqueue_all`) stores blocks in a `_enqueue_all_callbacks` class attribute on the action. `EnqueueAllOrchestrator.execute_iteration` — the single method both the async and foreground enqueue paths funnel through — fires the registered callbacks after `iterate` completes, resolving the sources hash only when callbacks exist. Each block is `instance_exec`-ed on the target action class with arity-filtered kwargs and wrapped in `PipingError.swallow` so a raise never aborts the fan-out.

**Tech Stack:** Ruby, RSpec. Gem: `axn`. No new dependencies.

## Global Constraints

- `spec/` is the **non-Rails** suite — AR/Rails constants must stay guarded via `defined?()`; do not require Rails in `spec/`. Rails-dependent behavior belongs in `spec_rails/`. (This feature is pure Ruby and tests entirely in `spec/`.)
- Follow existing patterns in `lib/axn/async/`. The `on_*` callback family swallows raised errors via `PipingError.swallow`; `on_enqueue_all` matches that contract and must **not** route to `Axn.config.on_exception`.
- Block execution context is the **target action class** (`target.instance_exec`), giving the block class-level `log`/`info`/`warn`.
- The hook fires for runs that pass through `execute_iteration` (async `#call` and the foreground `execute_iteration_without_logging` path). It does **not** fire on the no-`expects` short-circuit at `enqueue_all_orchestrator.rb:60`.
- Reference spec: `docs/superpowers/specs/2026-06-17-on-enqueue-all-hook-design.md`.

## File Structure

- **Modify** `lib/axn/async/batch_enqueue.rb` — add `_enqueue_all_callbacks` class attribute and the `on_enqueue_all` DSL method (+ YARD docs).
- **Modify** `lib/axn/async/enqueue_all_orchestrator.rb` — fire callbacks at the end of `execute_iteration`; add private `fire_enqueue_all_callbacks` / `invoke_enqueue_all_callback` helpers.
- **Modify** `spec/axn/async/batch_enqueue_spec.rb` — full test coverage (registration, count, sources hash, arity, error isolation, no-fire path).
- **Modify** `docs/reference/async.md` — add a "Run summary with `on_enqueue_all`" subsection under "Batch Enqueueing".

---

### Task 1: DSL — `on_enqueue_all` registration

**Files:**
- Modify: `lib/axn/async/batch_enqueue.rb`
- Test: `spec/axn/async/batch_enqueue_spec.rb`

**Interfaces:**
- Produces: `_enqueue_all_callbacks` class attribute (Array of Procs, default `[]`, inherited by subclasses); class method `on_enqueue_all(&block)` that appends to it and raises `ArgumentError` if no block given.

- [ ] **Step 1: Write the failing tests**

Add this `describe` block to `spec/axn/async/batch_enqueue_spec.rb` (place it after the existing top-level `describe "enqueue_all is defined on all Axn classes"` block):

```ruby
describe "on_enqueue_all DSL registration" do
  it "registers a callback block" do
    action_class = build_axn do
      on_enqueue_all { |count:| count }
    end

    expect(action_class._enqueue_all_callbacks.size).to eq(1)
    expect(action_class._enqueue_all_callbacks.first).to be_a(Proc)
  end

  it "defaults to an empty array" do
    action_class = build_axn {}

    expect(action_class._enqueue_all_callbacks).to eq([])
  end

  it "allows multiple callbacks, preserving declaration order" do
    action_class = build_axn do
      on_enqueue_all { |count:| "first #{count}" }
      on_enqueue_all { |count:| "second #{count}" }
    end

    expect(action_class._enqueue_all_callbacks.size).to eq(2)
    expect(action_class._enqueue_all_callbacks.map { |cb| cb.call(count: 5) }).to eq(["first 5", "second 5"])
  end

  it "raises ArgumentError when called without a block" do
    expect do
      build_axn { on_enqueue_all }
    end.to raise_error(ArgumentError, /on_enqueue_all requires a block/)
  end

  it "does not leak callbacks across sibling classes" do
    parent = build_axn { on_enqueue_all { |count:| count } }
    sibling = build_axn {}

    expect(parent._enqueue_all_callbacks.size).to eq(1)
    expect(sibling._enqueue_all_callbacks).to eq([])
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec rspec spec/axn/async/batch_enqueue_spec.rb -e "on_enqueue_all DSL registration"`
Expected: FAIL — `NoMethodError: undefined method 'on_enqueue_all'` / `undefined method '_enqueue_all_callbacks'`.

- [ ] **Step 3: Add the class attribute**

In `lib/axn/async/batch_enqueue.rb`, in the `included do` block, add the attribute alongside the existing one:

```ruby
included do
  class_attribute :_batch_enqueue_configs, default: []
  class_attribute :_enqueue_all_callbacks, default: []
end
```

- [ ] **Step 4: Add the DSL method**

In `lib/axn/async/batch_enqueue.rb`, in `module DSL`, add after `enqueues_each`:

```ruby
# Register a once-per-run callback that fires after the batch fan-out completes.
#
# Runs inside EnqueueAllOrchestrator (off the clock thread), after all jobs are
# enqueued. The block is evaluated in the context of this action class, so it has
# access to class-level `log`/`info`/`warn`. Multiple declarations are allowed and
# fire in declaration order.
#
# The block may declare any subset of these keyword arguments (or none):
# @yieldparam count [Integer] exact number of jobs enqueued (post-filter)
# @yieldparam sources [Hash{Symbol => Object}] resolved (un-materialized) source per
#   iterated field, e.g. { tax_profile: <relation> } or { user: <rel>, company: <rel> }
#
# A raise inside the block is swallowed (logged; re-raised in dev only when
# `Axn.config.raise_piping_errors_in_dev` is set) and cannot change the enqueue
# outcome — rescue inside your block if you need stronger guarantees.
#
# @example Post a run summary to Slack
#   on_enqueue_all do |sources:, count:|
#     active, inactive = sources[:tax_profile].partition { _1.user.active? }
#     SlackSender.call(channel: :eng_ops, text: "#{active.size} active, #{inactive.size} deactivated (#{count} enqueued)")
#   end
#
# @example Count-only heartbeat
#   on_enqueue_all { |count:| info "Found #{count} events" }
def on_enqueue_all(&block)
  raise ArgumentError, "on_enqueue_all requires a block" unless block

  self._enqueue_all_callbacks += [block]
end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bundle exec rspec spec/axn/async/batch_enqueue_spec.rb -e "on_enqueue_all DSL registration"`
Expected: PASS (5 examples).

- [ ] **Step 6: Commit**

```bash
git add lib/axn/async/batch_enqueue.rb spec/axn/async/batch_enqueue_spec.rb
git commit -m "PRO-2743 Add on_enqueue_all DSL registration

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Fire callbacks after fan-out — count + context

**Files:**
- Modify: `lib/axn/async/enqueue_all_orchestrator.rb`
- Test: `spec/axn/async/batch_enqueue_spec.rb`

**Interfaces:**
- Consumes: `target._enqueue_all_callbacks` (from Task 1); existing `execute_iteration`, `Config#resolve_source`, `Axn::Internal::Callable.only_requested_params`, `Axn::Internal::PipingError.swallow`.
- Produces: private class methods `fire_enqueue_all_callbacks(target:, configs:, count:)` and `invoke_enqueue_all_callback(target:, callback:, sources:, count:)` on `EnqueueAllOrchestrator`; `execute_iteration` now fires callbacks before returning.

- [ ] **Step 1: Write the failing tests**

Add this `describe` block to `spec/axn/async/batch_enqueue_spec.rb` (after the cross-product describe, near the other behavioral specs). It reuses the file's `company_class` / `enable_async_on` / `with_synchronous_enqueue_all` helpers:

```ruby
describe "on_enqueue_all firing" do
  before { with_synchronous_enqueue_all }

  it "fires once after the fan-out with the exact enqueued count" do
    captured = []
    cc = company_class
    action_class = build_axn do
      expects :company, type: cc
      define_method(:call) { company.name }
      enqueues_each :company, from: -> { cc.all }
    end.tap { |klass| enable_async_on(klass) }
    action_class.on_enqueue_all { |count:| captured << count }

    allow(action_class).to receive(:call_async)
    action_class.enqueue_all

    expect(captured).to eq([3]) # 3 company records, fired once
  end

  it "reflects the post-filter count when a filter block skips items" do
    captured = []
    action_class = build_axn do
      expects :number
      enqueues_each :number, from: -> { [1, 2, 3, 4] } do |n|
        n.even?
      end
    end.tap { |klass| enable_async_on(klass) }
    action_class.on_enqueue_all { |count:| captured << count }

    allow(action_class).to receive(:call_async)
    action_class.enqueue_all

    expect(captured).to eq([2]) # only 2 and 4 pass the filter
  end

  it "evaluates the block in the target action class context" do
    captured = {}
    cc = company_class
    action_class = build_axn do
      expects :company, type: cc
      define_method(:call) { company.name }
      enqueues_each :company, from: -> { cc.all }
    end.tap { |klass| enable_async_on(klass) }
    action_class.on_enqueue_all { captured[:context] = self }

    allow(action_class).to receive(:call_async)
    action_class.enqueue_all

    expect(captured[:context]).to eq(action_class)
  end

  it "exposes class-level logging (info) inside the block without raising" do
    cc = company_class
    action_class = build_axn do
      expects :company, type: cc
      define_method(:call) { company.name }
      enqueues_each :company, from: -> { cc.all }
    end.tap { |klass| enable_async_on(klass) }
    action_class.on_enqueue_all { |count:| info "enqueued #{count}" }

    allow(action_class).to receive(:call_async)

    expect { action_class.enqueue_all }.not_to raise_error
  end

  it "fires each registered callback in declaration order" do
    order = []
    cc = company_class
    action_class = build_axn do
      expects :company, type: cc
      define_method(:call) { company.name }
      enqueues_each :company, from: -> { cc.all }
    end.tap { |klass| enable_async_on(klass) }
    action_class.on_enqueue_all { order << :first }
    action_class.on_enqueue_all { order << :second }

    allow(action_class).to receive(:call_async)
    action_class.enqueue_all

    expect(order).to eq(%i[first second])
  end

  it "does not fire when no callbacks are registered (no extra source resolution)" do
    cc = company_class
    resolve_calls = 0
    action_class = build_axn do
      expects :company, type: cc
      define_method(:call) { company.name }
      enqueues_each :company, from: -> { resolve_calls += 1; cc.all }
    end.tap { |klass| enable_async_on(klass) }

    allow(action_class).to receive(:call_async)
    action_class.enqueue_all

    # Source resolved once for iteration only; the hook adds no extra resolution.
    expect(resolve_calls).to eq(1)
  end

  it "does not fire on the no-expects single-job path" do
    fired = false
    action_class = build_axn do
      define_method(:call) { "noop" }
    end.tap { |klass| enable_async_on(klass) }
    action_class.on_enqueue_all { fired = true }

    allow(action_class).to receive(:call_async)
    action_class.enqueue_all # no expects -> enqueue_for short-circuits to call_async, bypassing the orchestrator

    expect(fired).to be(false)
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec rspec spec/axn/async/batch_enqueue_spec.rb -e "on_enqueue_all firing"`
Expected: FAIL — callbacks never invoked (`captured` stays empty), so the count/context/order expectations fail. (The "no-expects" example passes from the start — it asserts non-firing — which is fine.)

- [ ] **Step 3: Fire callbacks at the end of `execute_iteration`**

In `lib/axn/async/enqueue_all_orchestrator.rb`, modify `execute_iteration` to fire callbacks before returning:

```ruby
def execute_iteration(target, on_progress: nil, **static_args)
  configs, resolved_static = resolve_configs(target, static_args:)
  count = { value: 0 }
  iterate(target:, configs:, index: 0, accumulated: {}, static_args: resolved_static, count:, on_progress:)
  fire_enqueue_all_callbacks(target:, configs:, count: count[:value])
  count[:value]
end
```

- [ ] **Step 4: Add the firing helpers**

In `lib/axn/async/enqueue_all_orchestrator.rb`, add these private class methods (inside `class << self`, e.g. after `execute_iteration_without_logging`):

```ruby
# Fire any registered on_enqueue_all callbacks once, after the fan-out completes.
# Resolves the per-field sources hash only when callbacks exist, so actions
# without the hook pay no extra source resolution.
def fire_enqueue_all_callbacks(target:, configs:, count:)
  callbacks = target._enqueue_all_callbacks
  return if callbacks.empty?

  sources = configs.each_with_object({}) do |config, hash|
    hash[config.field] = config.resolve_source(target:)
  end

  callbacks.each { |callback| invoke_enqueue_all_callback(target:, callback:, sources:, count:) }
end

# Invoke a single callback in the target class context with arity-filtered kwargs.
# A raise is swallowed (mirrors on_success / filter_block) so the fan-out is never aborted.
def invoke_enqueue_all_callback(target:, callback:, sources:, count:)
  args, kwargs = Axn::Internal::Callable.only_requested_params(callback, kwargs: { sources:, count: })
  target.instance_exec(*args, **kwargs, &callback)
rescue StandardError => e
  Axn::Internal::PipingError.swallow("on_enqueue_all callback for #{target.name}", exception: e)
end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bundle exec rspec spec/axn/async/batch_enqueue_spec.rb -e "on_enqueue_all firing"`
Expected: PASS (7 examples).

- [ ] **Step 6: Commit**

```bash
git add lib/axn/async/enqueue_all_orchestrator.rb spec/axn/async/batch_enqueue_spec.rb
git commit -m "PRO-2743 Fire on_enqueue_all callbacks after fan-out with count

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: `sources:` hash + arity flexibility

**Files:**
- Test: `spec/axn/async/batch_enqueue_spec.rb`

**Interfaces:**
- Consumes: the `sources`/`count` payload and `Callable.only_requested_params` filtering wired in Task 2. No production changes — this task proves the contract for the sources hash and arity, and locks it with tests.

- [ ] **Step 1: Write the failing tests**

Add this `describe` block to `spec/axn/async/batch_enqueue_spec.rb` (after the "on_enqueue_all firing" block):

```ruby
describe "on_enqueue_all sources and arity" do
  before { with_synchronous_enqueue_all }

  it "passes a single-entry sources hash for a single config" do
    captured = {}
    cc = company_class
    action_class = build_axn do
      expects :company, type: cc
      define_method(:call) { company.name }
      enqueues_each :company, from: -> { cc.all }
    end.tap { |klass| enable_async_on(klass) }
    action_class.on_enqueue_all { |sources:| captured[:sources] = sources }

    allow(action_class).to receive(:call_async)
    action_class.enqueue_all

    expect(captured[:sources].keys).to eq([:company])
    expect(captured[:sources][:company]).to match_array(company_class._records)
  end

  it "passes an entry per field for a cross-product, with the product count" do
    captured = {}
    cc = company_class
    uc = user_class
    action_class = build_axn do
      expects :company, type: cc
      expects :user, type: uc
      define_method(:call) { "#{user.name} @ #{company.name}" }
      enqueues_each :user, from: -> { uc.all }
      enqueues_each :company, from: -> { cc.active }
    end.tap { |klass| enable_async_on(klass) }
    action_class.on_enqueue_all { |sources:, count:| captured[:sources] = sources; captured[:count] = count }

    allow(action_class).to receive(:call_async)
    action_class.enqueue_all

    expect(captured[:sources].keys).to match_array(%i[user company])
    expect(captured[:sources][:user]).to match_array(user_class._records)
    expect(captured[:sources][:company]).to match_array(company_class._records.select(&:active?))
    expect(captured[:count]).to eq(4) # 2 users × 2 active companies
  end

  it "reflects a kwarg source override in the sources hash" do
    captured = {}
    cc = company_class
    action_class = build_axn do
      expects :company, type: cc
      define_method(:call) { company.name }
      enqueues_each :company, from: -> { cc.all }
    end.tap { |klass| enable_async_on(klass) }
    action_class.on_enqueue_all { |sources:| captured[:sources] = sources }

    allow(action_class).to receive(:call_async)
    override = [company_class._records.first]
    action_class.enqueue_all(company: override)

    expect(captured[:sources][:company]).to eq(override)
  end

  it "invokes a no-argument block" do
    fired = false
    cc = company_class
    action_class = build_axn do
      expects :company, type: cc
      define_method(:call) { company.name }
      enqueues_each :company, from: -> { cc.all }
    end.tap { |klass| enable_async_on(klass) }
    action_class.on_enqueue_all { fired = true }

    allow(action_class).to receive(:call_async)
    action_class.enqueue_all

    expect(fired).to be(true)
  end

  it "invokes a block that only requests count:" do
    captured = []
    cc = company_class
    action_class = build_axn do
      expects :company, type: cc
      define_method(:call) { company.name }
      enqueues_each :company, from: -> { cc.all }
    end.tap { |klass| enable_async_on(klass) }
    action_class.on_enqueue_all { |count:| captured << count }

    allow(action_class).to receive(:call_async)
    action_class.enqueue_all

    expect(captured).to eq([3])
  end
end
```

- [ ] **Step 2: Run the tests to verify they pass**

Run: `bundle exec rspec spec/axn/async/batch_enqueue_spec.rb -e "on_enqueue_all sources and arity"`
Expected: PASS (5 examples). (If the cross-product or override cases fail, the bug is in Task 2's `fire_enqueue_all_callbacks` source resolution — fix there.)

- [ ] **Step 3: Commit**

```bash
git add spec/axn/async/batch_enqueue_spec.rb
git commit -m "PRO-2743 Cover on_enqueue_all sources hash and arity flexibility

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Error isolation

**Files:**
- Test: `spec/axn/async/batch_enqueue_spec.rb`

**Interfaces:**
- Consumes: the `PipingError.swallow` wrapping in `invoke_enqueue_all_callback` (Task 2). No production changes expected — if a test fails, fix `invoke_enqueue_all_callback`.

- [ ] **Step 1: Write the failing tests**

Add this `describe` block to `spec/axn/async/batch_enqueue_spec.rb` (after the "sources and arity" block). It mirrors the existing "filter block exceptions" specs' use of the `PipingError.swallow` spy:

```ruby
describe "on_enqueue_all error isolation" do
  before { with_synchronous_enqueue_all }

  let(:action_class) do
    cc = company_class
    build_axn do
      expects :company, type: cc
      define_method(:call) { company.name }
      enqueues_each :company, from: -> { cc.all }
    end.tap { |klass| enable_async_on(klass) }
  end

  it "does not abort the fan-out when a callback raises" do
    action_class.on_enqueue_all { raise "summary exploded" }
    enqueued = []
    allow(action_class).to receive(:call_async) { |**args| enqueued << args }
    allow(Axn::Internal::PipingError).to receive(:swallow).and_call_original

    expect { action_class.enqueue_all }.not_to raise_error
    expect(enqueued.length).to eq(3) # all jobs still enqueued
  end

  it "swallows the error via PipingError" do
    action_class.on_enqueue_all { raise "summary exploded" }
    allow(action_class).to receive(:call_async)

    expect(Axn::Internal::PipingError).to receive(:swallow).with(
      a_string_including("on_enqueue_all callback"),
      exception: an_instance_of(RuntimeError),
    )

    action_class.enqueue_all
  end

  it "still fires later callbacks after an earlier one raises" do
    fired = []
    action_class.on_enqueue_all { raise "boom" }
    action_class.on_enqueue_all { fired << :second }
    allow(action_class).to receive(:call_async)
    allow(Axn::Internal::PipingError).to receive(:swallow).and_call_original

    action_class.enqueue_all

    expect(fired).to eq([:second])
  end
end
```

- [ ] **Step 2: Run the tests to verify they pass**

Run: `bundle exec rspec spec/axn/async/batch_enqueue_spec.rb -e "on_enqueue_all error isolation"`
Expected: PASS (3 examples). These should pass against Task 2's implementation; if the "later callbacks" test fails, confirm `fire_enqueue_all_callbacks` wraps each callback individually (per-callback rescue), not the whole loop.

- [ ] **Step 3: Commit**

```bash
git add spec/axn/async/batch_enqueue_spec.rb
git commit -m "PRO-2743 Cover on_enqueue_all error isolation

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: Documentation

**Files:**
- Modify: `docs/reference/async.md`

**Interfaces:** None (docs only).

- [ ] **Step 1: Add the docs subsection**

In `docs/reference/async.md`, under the "Batch Enqueueing with `enqueues_each`" section, add a new subsection immediately before "### Memory Efficiency":

````markdown
### Run summary with `on_enqueue_all`

`on_enqueue_all` registers a once-per-run callback that fires **after** the batch fan-out
completes — useful for posting a summary, emitting a metric, or logging a heartbeat without
hand-rolling a parent wrapper action. It runs inside the orchestrator (off the clock thread),
in the context of your action class, so class-level `log`/`info`/`warn` are available.

```ruby
class StockCertificate::EoyTaxReminder
  include Axn
  async :sidekiq

  expects :tax_profile, model: TaxProfile
  enqueues_each :tax_profile, from: -> { TaxProfile.needs_address_validation }

  on_enqueue_all do |sources:, count:|
    active, inactive = sources[:tax_profile].partition { _1.user.active? }
    SlackSender.call(channel: :eng_ops, text: "#{active.size} active, #{inactive.size} deactivated (#{count} enqueued)")
  end

  def call
    # per-tax-profile work
  end
end
```

The block may declare any subset of these keyword arguments (or none):

- **`count:`** — the exact number of jobs enqueued (post-filter). Always available, including
  for cross-product runs.
- **`sources:`** — a hash of `{ field => resolved_source }` for each iterated field, e.g.
  `{ tax_profile: <relation> }` or, for a cross-product, `{ user: <rel>, company: <rel> }`.
  Sources are the resolved-but-un-materialized relations (run your own `.count` / `.group` /
  `.partition`), and reflect any kwarg overrides passed to `enqueue_all`.

```ruby
# Count-only heartbeat:
on_enqueue_all { |count:| info "Found #{count} events" }
```

Multiple `on_enqueue_all` declarations are allowed and fire in declaration order.

**Error handling:** a raise inside the block is swallowed (logged; re-raised in development
only when `Axn.config.raise_piping_errors_in_dev` is set) and cannot change the enqueue
outcome — the fan-out has already completed. This matches `on_success` semantics; rescue
inside your block if you need stronger guarantees.

**When it fires:** on any run that goes through the fan-out (the async path and the foreground
path used when an iterable kwarg can't be serialized). It does **not** fire for an action with
no `expects`, which enqueues a single job directly without fanning out.
````

- [ ] **Step 2: Verify the docs render coherently**

Run: `grep -n "on_enqueue_all" docs/reference/async.md`
Expected: matches in the new subsection; confirm it sits between "Multi-Field Cross-Product" / "Static Fields" area and "### Memory Efficiency".

- [ ] **Step 3: Commit**

```bash
git add docs/reference/async.md
git commit -m "PRO-2743 Document on_enqueue_all hook

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: Full suite + lint

**Files:** None (verification only).

- [ ] **Step 1: Run the full async/batch suite**

Run: `bundle exec rspec spec/axn/async/batch_enqueue_spec.rb`
Expected: PASS (all examples, including the 20 new ones).

- [ ] **Step 2: Run the whole non-Rails suite**

Run: `bundle exec rspec spec/`
Expected: PASS (no regressions).

- [ ] **Step 3: Run RuboCop on changed files**

Run: `bundle exec rubocop lib/axn/async/batch_enqueue.rb lib/axn/async/enqueue_all_orchestrator.rb spec/axn/async/batch_enqueue_spec.rb`
Expected: no offenses. Fix any style offenses inline (match surrounding conventions), then re-run.

- [ ] **Step 4: Commit any lint fixes (if needed)**

```bash
git add -A
git commit -m "PRO-2743 Lint fixes for on_enqueue_all

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Notes for the release follow-up (out of scope for this plan)

- Do **not** bump os-app's lockfile here. Per gem-release convention, a human batches the `axn` release.
- After release, os-app adoption lands separately: EOY (PRO-2740), buyback (PRO-2737), plus the audit-for-benefit callsites listed in the Linear issue.
