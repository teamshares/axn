# Exception-Report Facets Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Attach an action's resolved `tag`/`dimension` facets to the global exception report (`Axn.config.on_exception`) as namespaced `context[:tags]` / `context[:dimensions]`.

**Architecture:** The Executor already resolves and memoizes facets (`resolved_tags`/`resolved_dimensions`) and dispatches the global report from `trigger_on_exception`. We pass `dup_facets`-copied maps into `Internal::ExceptionContext.build`, which attaches each to the report `context` only when non-empty. Values pass through as-is (already coerced at resolve time) — no re-formatting. The keys are reserved so `set_execution_context` can't clobber them.

**Tech Stack:** Ruby, RSpec. Non-Rails specs live in `spec/`; the Rails dummy app is `spec_rails/`. Tests run with `bundle exec rspec`.

## Global Constraints

- axn must work outside Rails — guard any AR/Rails constants with `defined?()`. (None needed here.)
- Facet values are already coerced to legal scalars/flat-arrays by `Core::Tagging.coerce` at resolve time; do **not** re-run them through `format_hash_values`.
- Hand each external consumer its own copy via `Core::Tagging.dup_facets` — never the memoized map.
- Follow existing patterns; no manual line-wrapping in docs (one line per paragraph).
- Design doc: `internal-docs/specs/2026-07-02-exception-report-facets-design.md`.

---

### Task 1: `ExceptionContext.build` accepts and attaches facets

**Files:**
- Modify: `lib/axn/internal/exception_context.rb`
- Test: `spec/axn/internal/exception_context_spec.rb`

**Interfaces:**
- Produces: `Axn::Internal::ExceptionContext.build(action:, retry_context: nil, tags: {}, dimensions: {}) → Hash`. When `tags.any?` the result has `context[:tags] == tags` (the passed map, verbatim); likewise `:dimensions`. Empty maps → key absent.

- [ ] **Step 1: Write the failing tests**

Add to `spec/axn/internal/exception_context_spec.rb`, inside the `describe ".build"` block:

```ruby
it "attaches non-empty tags and dimensions under namespaced keys" do
  action_class = build_axn do
    expects :name, type: String
    def call; end
  end
  stub_const("TestAction", action_class)
  instance = TestAction.send(:new, name: "Alice")

  result = described_class.build(
    action: instance,
    tags: { company_id: 42 },
    dimensions: { plan_tier: "pro" },
  )

  expect(result[:tags]).to eq(company_id: 42)
  expect(result[:dimensions]).to eq(plan_tier: "pro")
end

it "omits the facet keys entirely when the maps are empty" do
  action_class = build_axn do
    expects :name, type: String
    def call; end
  end
  stub_const("TestAction", action_class)
  instance = TestAction.send(:new, name: "Alice")

  result = described_class.build(action: instance)

  expect(result).not_to have_key(:tags)
  expect(result).not_to have_key(:dimensions)
end

it "attaches facet values verbatim without re-formatting them" do
  # A resolved Integer stays an Integer (not GID-stringified like inputs/outputs) —
  # facets are already coerced at resolve time; build must not touch them again.
  action_class = build_axn do
    expects :name, type: String
    def call; end
  end
  stub_const("TestAction", action_class)
  instance = TestAction.send(:new, name: "Alice")

  result = described_class.build(action: instance, tags: { company_id: 7 })

  expect(result[:tags][:company_id]).to be(7)
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/axn/internal/exception_context_spec.rb -e "namespaced keys" -e "empty" -e "verbatim"`
Expected: FAIL — `build` doesn't accept `tags:`/`dimensions:` (`ArgumentError: unknown keyword: :tags`).

- [ ] **Step 3: Implement**

In `lib/axn/internal/exception_context.rb`, change the `build` signature and append the facet attachment just before the final `context` return.

Change the signature line:

```ruby
        def build(action:, retry_context: nil, tags: {}, dimensions: {})
```

Then, immediately after the `current_attributes` block and before `context` is returned (currently line ~53), add:

```ruby
          # Declared observability facets (PRO-2853), attached under reserved namespaced keys so a
          # consumer's on_exception can route tag → freeform extra, dimension → indexed tags. Values
          # arrive already coerced (Core::Tagging.coerce) and pre-duped (Core::Tagging.dup_facets) by
          # the Executor, so they are attached verbatim — NOT re-run through format_hash_values (which
          # would diverge from what the span/metrics observe) — and a handler mutating them can't
          # corrupt the memoized maps. Omitted when empty, mirroring the other optional keys above.
          context[:tags] = tags if tags.any?
          context[:dimensions] = dimensions if dimensions.any?

          context
```

Remove the now-duplicate trailing `context` line if the edit leaves two.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/axn/internal/exception_context_spec.rb`
Expected: PASS (all, including the pre-existing examples).

- [ ] **Step 5: Commit**

```bash
git add lib/axn/internal/exception_context.rb spec/axn/internal/exception_context_spec.rb
git commit -m "PRO-2853: ExceptionContext.build attaches tag/dimension facets"
```

---

### Task 2: Reserve `:tags` / `:dimensions` execution-context keys

**Files:**
- Modify: `lib/axn/core/contract.rb:556` (`RESERVED_EXECUTION_CONTEXT_KEYS` + its doc comment)
- Test: `spec/axn/core/additional_execution_context_spec.rb`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `set_execution_context(tags:)` / `additional_execution_context` returning `:tags` or `:dimensions` are stripped from `execution_context`.

- [ ] **Step 1: Write the failing test**

Add to `spec/axn/core/additional_execution_context_spec.rb`, inside `describe "set_execution_context"`:

```ruby
it "strips reserved facet keys (:tags, :dimensions) from set_execution_context" do
  instance = build_axn do
    def call; end
  end.send(:new)

  instance.send(:set_execution_context, tags: { user_tag: 1 }, dimensions: { user_dim: 2 }, keep: "ok")
  ctx = instance.execution_context

  expect(ctx).not_to have_key(:tags)
  expect(ctx).not_to have_key(:dimensions)
  expect(ctx).to include(keep: "ok")
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/core/additional_execution_context_spec.rb -e "strips reserved facet keys"`
Expected: FAIL — `:tags`/`:dimensions` are not yet reserved, so they appear in `execution_context`.

- [ ] **Step 3: Implement**

In `lib/axn/core/contract.rb`, update the constant and its doc comment. Replace:

```ruby
      # Keys the framework owns in the execution/exception-report context, so they can't be set via
      # set_execution_context or the additional_execution_context hook: :inputs/:outputs are the
      # structural pair, and :async/:current_attributes/:axn_stack are framework-populated in
      # Internal::ExceptionContext.build — reserving them here prevents a user value from being
      # silently overwritten when build assigns them after merging the user's extra keys.
      RESERVED_EXECUTION_CONTEXT_KEYS = %i[inputs outputs async current_attributes axn_stack].freeze
```

with:

```ruby
      # Keys the framework owns in the execution/exception-report context, so they can't be set via
      # set_execution_context or the additional_execution_context hook: :inputs/:outputs are the
      # structural pair, and :async/:current_attributes/:axn_stack/:tags/:dimensions are
      # framework-populated in Internal::ExceptionContext.build — reserving them here prevents a user
      # value from being silently overwritten when build assigns them after merging the user's extra
      # keys. :tags/:dimensions carry the resolved `tag`/`dimension` facets (PRO-2853).
      RESERVED_EXECUTION_CONTEXT_KEYS = %i[inputs outputs async current_attributes axn_stack tags dimensions].freeze
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/axn/core/additional_execution_context_spec.rb`
Expected: PASS (new example plus all pre-existing ones).

- [ ] **Step 5: Commit**

```bash
git add lib/axn/core/contract.rb spec/axn/core/additional_execution_context_spec.rb
git commit -m "PRO-2853: reserve :tags/:dimensions execution-context keys"
```

---

### Task 3: Wire memoized, dup'd facets from the Executor into the report

**Files:**
- Modify: `lib/axn/executor.rb:283` (the `ExceptionContext.build` call in `trigger_on_exception`)
- Test: `spec/axn/core/exception_report_facets_spec.rb` (new)

**Interfaces:**
- Consumes: `Internal::ExceptionContext.build(..., tags:, dimensions:)` from Task 1; reserved keys from Task 2.
- Produces: end-to-end — a raised (unexpected) exception in an action declaring `tag`/`dimension` reaches `Axn.config.on_exception` with `context[:tags]`/`context[:dimensions]` populated from a private copy.

- [ ] **Step 1: Write the failing tests**

Create `spec/axn/core/exception_report_facets_spec.rb`:

```ruby
# frozen_string_literal: true

RSpec.describe "Exception-report facets (on_exception context)" do
  around do |example|
    original = Axn.config.instance_variable_get(:@on_exception)
    example.run
    Axn.config.instance_variable_set(:@on_exception, original)
  end

  def capture_context(&action_body)
    captured = nil
    Axn.config.instance_variable_set(:@on_exception, proc { |context:| captured = context })
    Class.new { include Axn }.tap { |k| k.class_eval(&action_body) }.call
    captured
  end

  it "attaches resolved tags and dimensions to the report context" do
    ctx = capture_context do
      tag(:company_id) { 7 }
      dimension(:plan) { "pro" }
      def call = raise("boom")
    end

    expect(ctx[:tags]).to eq(company_id: 7)
    expect(ctx[:dimensions]).to eq(plan: "pro")
  end

  it "omits facet keys when the action declares none" do
    ctx = capture_context do
      def call = raise("boom")
    end

    expect(ctx).not_to have_key(:tags)
    expect(ctx).not_to have_key(:dimensions)
  end

  it "hands the reporter its own copy — mutation can't corrupt other sinks" do
    payload_tags = nil
    sub = ActiveSupport::Notifications.subscribe("axn.call") { |*args| payload_tags = args.last[:tags] }
    Axn.config.instance_variable_set(:@on_exception, proc { |context:| context[:tags][:company_id] = "MUTATED" })

    Class.new do
      include Axn
      tag(:company_id) { 7 }
      def call = raise("boom")
    end.call

    # on_exception mutated its dup before the notification payload was built from a fresh dup of the
    # untouched memoized map, so the subscriber still sees the real value.
    expect(payload_tags).to eq(company_id: 7)
  ensure
    ActiveSupport::Notifications.unsubscribe(sub)
  end

  it "lets the framework facet win over a user-supplied set_execution_context key" do
    ctx = capture_context do
      tag(:company_id) { 7 }
      def call
        set_execution_context(tags: { company_id: "user" })
        raise "boom"
      end
    end

    expect(ctx[:tags]).to eq(company_id: 7)
  end

  it "does NOT report facets for a fail! (failure bucket never reaches on_exception)" do
    reported = false
    Axn.config.instance_variable_set(:@on_exception, proc { reported = true })

    Class.new do
      include Axn
      tag(:company_id) { 7 }
      def call = fail!("nope")
    end.call

    expect(reported).to be(false)
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/axn/core/exception_report_facets_spec.rb`
Expected: FAIL — the "attaches" / "own copy" / "framework wins" examples fail because the Executor doesn't yet pass facets to `build` (so `ctx[:tags]` is nil). The "omits" and "fail!" examples should already pass.

- [ ] **Step 3: Implement**

In `lib/axn/executor.rb`, in `trigger_on_exception`, replace:

```ruby
      context = Internal::ExceptionContext.build(action: @action, retry_context:)
```

with:

```ruby
      context = Internal::ExceptionContext.build(
        action: @action,
        retry_context:,
        # dup so a reporter callback mutating these can't corrupt the maps the span/metrics read
        # (same memoized values, same guarantee as with_tracing / emit_metrics).
        tags: Core::Tagging.dup_facets(resolved_tags),
        dimensions: Core::Tagging.dup_facets(resolved_dimensions),
      )
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/axn/core/exception_report_facets_spec.rb`
Expected: PASS (all five).

- [ ] **Step 5: Run the broader suite for regressions**

Run: `bundle exec rspec spec/axn/core/additional_execution_context_spec.rb spec/axn/internal/exception_context_spec.rb spec/axn/internal/tracing/tagging_spec.rb spec/axn/core/global_on_exception_spec.rb spec/axn/core/nested_exception_reporting_spec.rb`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/axn/executor.rb spec/axn/core/exception_report_facets_spec.rb
git commit -m "PRO-2853: wire resolved tag/dimension facets into exception reports"
```

---

### Task 4: Docs + CHANGELOG

**Files:**
- Modify: `docs/reference/configuration.md`
- Modify: `CHANGELOG.md`

**Interfaces:** none (documentation only).

- [ ] **Step 1: Document the new context keys**

In `docs/reference/configuration.md`, in the `on_exception` context-shape block (the fenced list around lines 54–63 that shows `inputs:`/`outputs:`/`async:`), add two lines describing the facet keys. After the `# ... any extra keys from set_execution_context or additional_execution_context hook` line and before `async: { ... }`, add:

```
  tags: { ... }                 # Resolved `tag` facets (only when the action declares any)
  dimensions: { ... }           # Resolved `dimension` facets (only when the action declares any)
```

- [ ] **Step 2: Update the cardinality-mapping note to present tense + worked example**

In `docs/reference/configuration.md`, in the `### Tagging spans with domain context (tag / dimension)` section, update the sentence at line ~265 that reads "becomes a span attribute (and, later, a log field / exception detail)" and "additionally flows to indexing sinks — today `emit_metrics`, later Sentry/Sidekiq tags" — drop the "later" hedging for exception reports. Change that paragraph to:

```markdown
**Cardinality mapping.** An Axn `tag` is high-cardinality and becomes a span attribute and an exception-report facet (`context[:tags]`) — safe for per-call values like ids. An Axn `dimension` is bounded and additionally flows to indexing sinks — `emit_metrics` and the exception report's `context[:dimensions]`, meant for indexed tags (e.g. Sentry/Honeybadger tags) — where unbounded values are costly. This is the reverse of "tag" in Datadog/Sentry/Sidekiq (where a tag is the bounded thing); pick the Axn macro by cardinality, not by the downstream tool's word.
```

Then add a worked example immediately after that paragraph:

````markdown
Both facet maps ride along in the `on_exception` `context`, so a handler routes them onto its reporter:

```ruby
c.on_exception = proc do |e, context:| # [!code focus:5]
  Honeybadger.notify(e,
    context: context, # tags land here as freeform extra
    tags: context[:dimensions]&.values&.join(", ")) # dimensions → indexed tags
end
```

They appear only when the action declares facets; a handler that just forwards `context` wholesale picks up `context[:tags]`/`context[:dimensions]` automatically.
````

- [ ] **Step 3: Add CHANGELOG entry**

In `CHANGELOG.md`, under `## Unreleased`, add a `[FEAT]` bullet (place it just after the existing `tag`/`dimension` FEAT bullet for continuity):

```markdown
* [FEAT] Resolved `tag`/`dimension` facets now attach to the global exception report: `Axn.config.on_exception` receives them as `context[:tags]` and `context[:dimensions]` (each present only when the action declares facets). A consumer handler that forwards `context` to its error tracker picks them up automatically; route `context[:dimensions]` to indexed/bounded tags and `context[:tags]` to freeform extra. Facet values are the same coerced, per-consumer-duped maps the span and `emit_metrics` see (a reporter callback mutating them can't corrupt other sinks). `:tags`/`:dimensions` are now reserved execution-context keys — **breaking** only for code that set a `tags`/`dimensions` key via `set_execution_context` or the `additional_execution_context` hook (now stripped, framework facets win).
```

- [ ] **Step 4: Verify docs build references nothing broken**

Run: `bundle exec rspec spec/axn/internal/exception_context_spec.rb spec/axn/core/exception_report_facets_spec.rb`
Expected: PASS (sanity re-run; docs have no test but confirm nothing regressed).

- [ ] **Step 5: Commit**

```bash
git add docs/reference/configuration.md CHANGELOG.md
git commit -m "PRO-2853: document exception-report tag/dimension facets"
```

---

## Self-Review

**Spec coverage:**
- Executor passes memoized dup'd facets → Task 3.
- `build` attaches namespaced keys, verbatim, non-empty-only → Task 1.
- Reserved keys → Task 2.
- Failure-path partials / failures-don't-report → Task 3 (fail! example); partial-resolution is existing `Tagging.resolve` behavior, no new code.
- No-facets byte-identical → Task 1 + Task 3 (omit examples).
- dup mutation-safety → Task 3.
- Docs + CHANGELOG → Task 4.
- Async coexistence: covered by design; the `retry_context` and facet kwargs are independent in `build` (Task 1 signature) and the existing async report path is unchanged. No dedicated task step — the wiring in Task 3 flows through `trigger_on_exception` which already computes `retry_context`, so async reports get facets for free. (If desired, an async example can be added, but it exercises no new branch.)

**Placeholder scan:** none — every step has concrete code/commands.

**Type consistency:** `build(action:, retry_context:, tags:, dimensions:)`, `Core::Tagging.dup_facets`, `resolved_tags`/`resolved_dimensions`, `RESERVED_EXECUTION_CONTEXT_KEYS` — all match existing names in the codebase and are used consistently across tasks.
