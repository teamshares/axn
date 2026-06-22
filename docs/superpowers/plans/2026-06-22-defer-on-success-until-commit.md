# Defer `on_success` Until Transaction Commit — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `on_success` fire after the *enclosing* transaction commits (immediately if none), and be skipped on rollback — so the documented post-commit guarantee holds under nesting, not just at the top level.

**Architecture:** Route the success dispatch in `Executor#trigger_on_success` through `ActiveRecord.after_all_transactions_commit` (AR 7.2+), which yields immediately when no transaction is open and registers an `after_commit` hook otherwise. Single method change; both `trigger_on_success` call sites (normal + `done!`) flow through it. Failure/error/exception callbacks are untouched. No config or DSL — this is simply the definition of `on_success`.

**Tech Stack:** Ruby, ActiveRecord 7.2+, RSpec. Design doc: `docs/superpowers/specs/2026-06-22-defer-on-success-until-commit-design.md`.

## Global Constraints

- ActiveRecord/ActiveSupport floor is **>= 7.2** (`ActiveRecord.after_all_transactions_commit` is 7.2+). Verbatim from `axn.gemspec`: `spec.add_dependency "activesupport", ">= 7.2"`.
- **Must work without Rails.** Guard the AR call with `defined?(ActiveRecord)`, matching `lib/axn/strategies/model.rb:37`. With no AR loaded, dispatch inline as today.
- **No new config or DSL.** The behavior is unconditional (no opt-out flag), per the spec.
- **Scope is success only.** Do not modify the `on_failure` / `on_error` / `on_exception` paths in `with_exception_handling`.
- New Ruby files start with `# frozen_string_literal: true`.
- Rails-dependent specs live in `spec_rails/dummy_app/spec/`; non-Rails specs live in `spec/`. (`[[project_axn_works_outside_rails]]`)

## File Structure

- **Modify** `lib/axn/executor.rb` — rewrite `Executor#trigger_on_success` (currently lines 435-437) to route through `after_all_transactions_commit`. This is the entire production change.
- **Create** `spec_rails/dummy_app/spec/axn/on_success_transaction_spec.rb` — Rails-backed behavior + ordering + scope tests.
- **Create** `spec/axn/core/on_success_without_activerecord_spec.rb` — non-Rails guard test (inline dispatch when AR undefined).
- **Modify** `docs/strategies/transaction.md`, `docs/reference/class.md` (`### on_success`, line 665) — document the commit-anchored, nesting-safe semantic and the after-hook ordering tradeoff.
- **Modify** `CHANGELOG.md` — add an `## Unreleased` entry.

## Test Run Commands

- Rails specs (run from repo root): `cd spec_rails/dummy_app && BUNDLE_GEMFILE=Gemfile bundle exec rspec spec/axn/on_success_transaction_spec.rb`
- Non-Rails specs (run from repo root): `bundle exec rspec spec/axn/core/on_success_without_activerecord_spec.rb`

---

### Task 1: Defer `on_success` to the enclosing transaction commit

**Files:**
- Modify: `lib/axn/executor.rb:435-437` (`trigger_on_success`)
- Test: `spec_rails/dummy_app/spec/axn/on_success_transaction_spec.rb` (create)
- Test: `spec/axn/core/on_success_without_activerecord_spec.rb` (create)

**Interfaces:**
- Consumes: `@action_class._dispatch_callbacks(:success, action:, exception:)` (existing), `ActiveRecord.after_all_transactions_commit(&block)` (AR 7.2 stdlib).
- Produces: unchanged public surface — `trigger_on_success` stays a private no-arg method; behavior change only.

- [ ] **Step 1: Write the failing driver test**

Create `spec_rails/dummy_app/spec/axn/on_success_transaction_spec.rb`:

```ruby
# frozen_string_literal: true

RSpec.describe "on_success transaction-commit semantics" do
  before(:all) do
    Rails.application.initialize! if defined?(Rails) && !Rails.application.initialized?
  end

  # Inner axn: writes a row, has its own transaction + an on_success side effect.
  let(:inner) do
    build_axn do
      use :transaction
      expects :collector
      expects :name
      on_success { collector << :inner_success }

      def call
        User.create!(name:)
      end
    end
  end

  describe "nested inside an outer transaction that rolls back" do
    let(:outer) do
      build_axn do
        use :transaction
        expects :collector
        expects :inner

        def call
          inner.call!(collector:, name: "Nested User")
          raise "force rollback"
        end
      end
    end

    it "does not fire the inner on_success (skipped on rollback)" do
      collector = []
      expect { outer.call(collector:, inner:) }.not_to change(User, :count)
      expect(collector).to be_empty
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd spec_rails/dummy_app && BUNDLE_GEMFILE=Gemfile bundle exec rspec spec/axn/on_success_transaction_spec.rb`
Expected: FAIL — `collector` contains `:inner_success`. Today the nested `on_success` fires inline (pre-commit), so it runs even though the outer transaction rolls back.

- [ ] **Step 3: Implement the deferral**

In `lib/axn/executor.rb`, replace `trigger_on_success` (currently):

```ruby
    def trigger_on_success
      @action_class._dispatch_callbacks(:success, action: @action, exception: nil)
    end
```

with:

```ruby
    # on_success is defined to run only once the *enclosing* transaction durably commits
    # (immediately when none is open), and to be skipped if it rolls back.
    # ActiveRecord.after_all_transactions_commit (AR 7.2+) yields immediately with no open
    # transaction, otherwise registers an after_commit hook on the outermost transaction.
    # Guarded by defined?(ActiveRecord) so non-Rails usage dispatches inline as before.
    def trigger_on_success
      dispatch = -> { @action_class._dispatch_callbacks(:success, action: @action, exception: nil) }

      if defined?(ActiveRecord)
        ActiveRecord.after_all_transactions_commit(&dispatch)
      else
        dispatch.call
      end
    end
```

- [ ] **Step 4: Run the driver test to verify it passes**

Run: `cd spec_rails/dummy_app && BUNDLE_GEMFILE=Gemfile bundle exec rspec spec/axn/on_success_transaction_spec.rb`
Expected: PASS.

- [ ] **Step 5: Add the top-level (unchanged) characterization test**

Append inside the top-level `describe` block in `spec_rails/dummy_app/spec/axn/on_success_transaction_spec.rb`:

```ruby
  describe "top-level (no enclosing axn transaction)" do
    let(:action) do
      build_axn do
        use :transaction
        expects :collector
        on_success { collector << :success }

        def call
          User.create!(name: "Top Level User")
        end
      end
    end

    it "fires on_success after the transaction commits" do
      collector = []
      expect { action.call!(collector:) }.to change(User, :count).by(1)
      expect(collector).to eq([:success])
    end
  end
```

- [ ] **Step 6: Write the non-Rails guard test**

Create `spec/axn/core/on_success_without_activerecord_spec.rb`:

```ruby
# frozen_string_literal: true

RSpec.describe "on_success without ActiveRecord" do
  it "dispatches on_success inline when ActiveRecord is not loaded" do
    expect(defined?(ActiveRecord)).to be_falsey

    collector = []
    action = build_axn do
      expects :collector
      on_success { collector << :success }

      def call; end
    end

    action.call!(collector:)
    expect(collector).to eq([:success])
  end
end
```

- [ ] **Step 7: Run both suites to verify all pass**

Run: `cd spec_rails/dummy_app && BUNDLE_GEMFILE=Gemfile bundle exec rspec spec/axn/on_success_transaction_spec.rb`
Expected: PASS (2 examples).
Run: `bundle exec rspec spec/axn/core/on_success_without_activerecord_spec.rb`
Expected: PASS (1 example). The `defined?(ActiveRecord)` assertion confirms the guard path is the one exercised.

- [ ] **Step 8: Commit**

```bash
git add lib/axn/executor.rb spec_rails/dummy_app/spec/axn/on_success_transaction_spec.rb spec/axn/core/on_success_without_activerecord_spec.rb
git commit -m "$(cat <<'EOF'
Defer on_success until the enclosing transaction commits

on_success now fires after the enclosing transaction commits (immediately
if none is open) and is skipped on rollback, via
ActiveRecord.after_all_transactions_commit. Fixes the nested case where an
inner on_success fired pre-commit and survived an outer rollback. Inline
(non-AR) behavior unchanged.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Characterize ordering and the success-only scope boundary

**Files:**
- Test: `spec_rails/dummy_app/spec/axn/on_success_transaction_spec.rb` (modify — add describes)

**Interfaces:**
- Consumes: the `let(:inner)` defined in Task 1's file; `build_axn`; the dummy app `User` model.
- Produces: no production code. These tests lock in guarantees the Task 1 implementation already satisfies; if any fails, the implementation is wrong.

- [ ] **Step 1: Add the ordering test (child-first; outer `after` precedes inner `on_success`)**

Append to `spec_rails/dummy_app/spec/axn/on_success_transaction_spec.rb`:

```ruby
  describe "ordering when the enclosing transaction commits" do
    let(:outer) do
      build_axn do
        use :transaction
        expects :collector
        expects :inner
        after { collector << :outer_after }
        on_success { collector << :outer_success }

        def call
          inner.call!(collector:, name: "Nested User")
        end
      end
    end

    it "runs inner on_success before outer on_success, after the outer after-hook" do
      collector = []
      expect { outer.call!(collector:, inner:) }.to change(User, :count).by(1)
      expect(collector).to eq(%i[outer_after inner_success outer_success])
    end
  end
```

Rationale (for the reviewer): the outer `after` hook runs inside the still-open transaction; the inner success is deferred to commit (fires next); the outer success fires inline after commit. Hence `outer_after → inner_success → outer_success`.

- [ ] **Step 2: Add the failure-path scope test (not deferred)**

Append to the same file:

```ruby
  describe "failure-path callbacks are not deferred" do
    let(:failing_inner) do
      build_axn do
        use :transaction
        expects :collector
        on_failure { collector << :inner_failure }

        def call
          User.create!(name: "Doomed User")
          fail!("nope")
        end
      end
    end

    let(:outer) do
      build_axn do
        use :transaction
        expects :collector
        expects :inner

        def call
          inner.call!(collector:)
        end
      end
    end

    it "fires inner on_failure immediately even though the enclosing transaction rolls back" do
      collector = []
      expect { outer.call(collector:, inner: failing_inner) }.not_to change(User, :count)
      expect(collector).to eq([:inner_failure])
    end
  end
```

Rationale: `fail!` fires `on_failure` synchronously, then re-raises `Axn::Failure` (nested), rolling back the outer transaction. The failure callback must still have run (it is not routed through `after_all_transactions_commit`), and the `Doomed User` row must be gone.

- [ ] **Step 3: Run the full file to verify all pass**

Run: `cd spec_rails/dummy_app && BUNDLE_GEMFILE=Gemfile bundle exec rspec spec/axn/on_success_transaction_spec.rb`
Expected: PASS (4 examples total across Tasks 1 and 2).

- [ ] **Step 4: Commit**

```bash
git add spec_rails/dummy_app/spec/axn/on_success_transaction_spec.rb
git commit -m "$(cat <<'EOF'
Add ordering and scope characterization specs for on_success deferral

Locks in child-first ordering (inner on_success before outer), the
documented tradeoff that the outer after-hook runs before the deferred
inner on_success, and that failure-path callbacks are never deferred.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Documentation + CHANGELOG

**Files:**
- Modify: `docs/strategies/transaction.md:28` (the `on_success` paragraph)
- Modify: `docs/reference/class.md:667` (the `### on_success` description)
- Modify: `CHANGELOG.md` (`## Unreleased` section)

**Interfaces:** none (docs only).

- [ ] **Step 1: Update the transaction strategy doc**

In `docs/strategies/transaction.md`, replace the paragraph that currently begins
`**`on_success` runs after the transaction commits.**` (line 28) with:

```markdown
**`on_success` runs after the enclosing transaction commits.** It is the place for work
that must only happen once the DB work is durably persisted—calling an external HTTP
service, sending email, enqueuing a job. This holds under nesting too: when an action runs
inside another action's transaction (or any open `ActiveRecord::Base.transaction`), its
`on_success` is deferred until the **outermost** transaction commits, and is **skipped
entirely if that transaction rolls back**. With no open transaction it runs immediately.

Ordering follows from this: nested `on_success` callbacks fire in child-first order (inner
before outer). One consequence to be aware of—because `on_success` waits for the commit, an
outer action's `after` hooks (which run *inside* the transaction) execute **before** an inner
action's `on_success`.

Putting slow or unreliable external calls inside `call` or `after` keeps the transaction open
until they complete and can block the connection—use `on_success` instead.
```

- [ ] **Step 2: Update the `on_success` reference description**

In `docs/reference/class.md`, replace line 667 (the description under `### on_success`) with:

```markdown
This is triggered after the Axn completes successfully, once the enclosing database
transaction has committed (immediately if none is open); it is skipped if that transaction
rolls back. Nested `on_success` callbacks fire child-first (inner before outer). Difference
from `after`: if the given block raises an error, this WILL be reported to the global
exception handler, but will NOT change `ok?` to false.
```

- [ ] **Step 3: Add a CHANGELOG entry**

In `CHANGELOG.md`, add as the first bullet under `## Unreleased`:

```markdown
* [BREAKING] `on_success` now fires after the **enclosing** transaction commits (immediately when none is open) and is **skipped on rollback**, rather than always firing inline. Previously, an action nested inside another action's transaction ran its `on_success` before the outer transaction committed — so the side effect (email, HTTP call, enqueue) fired even when the outer transaction later rolled back. Implemented via `ActiveRecord.after_all_transactions_commit` (requires ActiveRecord 7.2+; no-op/inline without ActiveRecord). Nested `on_success` callbacks fire child-first; note that an outer action's `after` hooks now run before an inner action's `on_success`. Failure-path callbacks (`on_failure`/`on_error`/`on_exception`) are unaffected and still fire immediately. No opt-out flag.
```

- [ ] **Step 4: Commit**

```bash
git add docs/strategies/transaction.md docs/reference/class.md CHANGELOG.md
git commit -m "$(cat <<'EOF'
Document on_success commit-anchored, nesting-safe semantics

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Spec coverage:**
- Core deferral via `after_all_transactions_commit` + `defined?(ActiveRecord)` guard → Task 1.
- Both `trigger_on_success` call sites (normal + `done!`) covered → single method change in Task 1 (no per-call-site code needed).
- Skip-on-rollback → Task 1 driver test; top-level unchanged → Task 1.
- Universal (any open transaction, not just `:transaction` strategy) → exercised by nested `build_axn`s; inline-without-AR → Task 1 non-Rails test.
- Child-first ordering + outer-`after`-before-inner-`on_success` tradeoff → Task 2.
- Success-only scope (failure path not deferred) → Task 2.
- No config/DSL → reflected by the absence of any config task; called out in CHANGELOG/docs (Task 3).
- Docs (transaction.md + class.md) and CHANGELOG → Task 3.

**Not separately tested (intentional):** the dev-only `raise_piping_errors_in_dev` corner (a diagnostic-mode behavior, documented in the spec, not a guaranteed contract); transactional-test consumer behavior (verified by spike, no consumer code involved).

**Placeholder scan:** none — all steps contain concrete code/commands.

**Type consistency:** `trigger_on_success` stays a private no-arg method; `collector`/`inner`/`name` field names are consistent across all test actions; `%i[outer_after inner_success outer_success]` matches the symbols pushed by the hooks/callbacks.
