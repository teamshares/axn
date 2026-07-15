# First-class per-member error classification (PRO-2925) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make shape-member errors individually classifiable so `user_facing:` composes uniformly at every declaration depth — a member may opt into `user_facing:` (full parity: `true`/String/Symbol/Proc), a field's own errors honor its `user_facing:` even when it carries a shape block, and the `user_facing:` + shape-block declaration guard is removed.

**Architecture:** `ShapeValidator` tags each member error it folds into the parent field's `ActiveModel::Errors` with two options (`axn_shape_member: true`, `axn_member_user_facing: <intent>`). Settlement stops treating `ContractFailure` as the atomic classification unit and partitions it per-error: the field's own (untagged) errors honor `config.user_facing`, each member (tagged) error honors its own intent. The existing `_resolve_user_facing_override` seam is reused for message selection — no parallel classification path.

**Tech Stack:** Ruby, RSpec, ActiveModel. Non-Rails `spec/` (guard AR/Rails constants with `defined?`). Run specs with `bundle exec rspec`.

## Global Constraints

- Comments describe *current* behavior + intrinsic why — never "used to X / now Y" or "(PRO-nnnn review)". (repo convention)
- axn must work outside Rails: `spec/` is non-Rails; the tests here need no Rails.
- Member `user_facing:` has **full parity** with a field's: `true` / String / Symbol / Proc, validated through the existing `_validate_user_facing!`.
- Member errors default **dev-facing**; a structural member failure never leaks as user-facing.
- Commit only at the plan's `git commit` steps; the branch is `kali/pro-2925-...` (not `gitbutler/worktree`), so `git commit` is fine.
- Reuse the settlement seam (`ContractFailure`, `_resolve_user_facing_override`, `_aggregate_errors`) — do not add a parallel classification path.

## Files

- Modify: `lib/axn/core/contract.rb` — `ShapeConfig` gains `user_facing`; `_build_shape_member` validates + threads it; add `user_facing` to `SHAPE_MEMBER_FIELD_OPTIONS`; remove the guard at `:189-191`.
- Modify: `lib/axn/core/validation/validators/shape_validator.rb` — tag member errors at both `add` sites (`:60`, `:69`), preserving an already-tagged nested intent.
- Modify: `lib/axn/executor.rb` — per-error partition helpers; per-error dominance (`:518`); per-error message composition (`_composed_user_facing_error`, `:607`).
- Modify: `spec/axn/core/user_facing_spec.rb` — replace the two guard-pinning specs (`:512-534`) with behavioral specs.
- Modify: `docs/reference/class.md` (`:155`, `:226`), `docs/usage/writing.md` (`:595`, `:599`) — member options + the guard-removal narrative.
- Modify: `CHANGELOG.md` — one `[FEAT]` entry.

---

## Task 1: Member `user_facing:` opt-in + per-error classification machinery

The additive half: a shape member may opt into `user_facing:`, and settlement classifies per-error. The field-level guard STAYS UP in this task (a shape-carrying field still can't be `user_facing:`), so the only new reachable behavior is member-level — which is fully testable because the guard checks the *field's* `user_facing:`, not a member's.

**Files:**
- Modify: `lib/axn/core/contract.rb` — `ShapeConfig`, `SHAPE_MEMBER_FIELD_OPTIONS`, `_build_shape_member`.
- Modify: `lib/axn/core/validation/validators/shape_validator.rb` — tag both `add` sites.
- Modify: `lib/axn/executor.rb` — partition helpers, dominance, composition.
- Test: `spec/axn/core/user_facing_spec.rb`.

**Interfaces:**
- Produces: `ShapeConfig#user_facing` (default `false`). Member errors tagged `axn_shape_member: true` + `axn_member_user_facing: <intent>`. Executor helpers `_own_errors(failure)`, `_member_errors(failure)`, `_failure_fully_user_facing?(failure)`, `_user_facing_parts(failure)`, `_errors_containing(error_list)`.

- [ ] **Step 1: Write the failing behavioral specs**

Add to `spec/axn/core/user_facing_spec.rb` (anywhere inside the top-level `describe`, e.g. before the `mixed failure` block):

```ruby
describe "user_facing: on a shape member" do
  it "surfaces the member's own message when the member opts in with true" do
    action = build_axn do
      expects :items, type: Array do
        field :status, type: String, inclusion: { in: %w[open closed] }, user_facing: true
      end
      def call = nil
    end
    result = action.call(items: [{ status: "bogus" }])
    expect(result.outcome).to be_failure
    expect(result.error).to eq("Items element at index 0: status is not included in the list")
  end

  it "surfaces a String override" do
    action = build_axn do
      expects :items, type: Array do
        field :status, type: String, inclusion: { in: %w[open closed] }, user_facing: "Each item needs a valid status"
      end
      def call = nil
    end
    result = action.call(items: [{ status: "bogus" }])
    expect(result.outcome).to be_failure
    expect(result.error).to eq("Each item needs a valid status")
  end

  it "invokes a Symbol handler on the action" do
    action = build_axn do
      expects :items, type: Array do
        field :status, type: String, inclusion: { in: %w[open closed] }, user_facing: :status_msg
      end
      def status_msg = "Pick a real status"
      def call = nil
    end
    expect(action.call(items: [{ status: "bogus" }]).error).to eq("Pick a real status")
  end

  it "computes a Proc handler from the member's own error" do
    action = build_axn do
      expects :items, type: Array do
        field :status, type: String, inclusion: { in: %w[open closed] }, user_facing: ->(e) { "Bad: #{e.message}" }
      end
      def call = nil
    end
    expect(action.call(items: [{ status: "bogus" }]).error)
      .to eq("Bad: Items element at index 0: status is not included in the list")
  end

  it "stays dev-facing when the member does not opt in" do
    action = build_axn do
      expects :items, type: Array do
        field :status, type: String, inclusion: { in: %w[open closed] }
      end
      def call = nil
    end
    result = action.call(items: [{ status: "bogus" }])
    expect(result.outcome).to be_exception
    expect(result.error).to eq("Something went wrong")
  end

  it "collapses a String override to one clause across multiple failing elements" do
    action = build_axn do
      expects :items, type: Array do
        field :status, type: String, inclusion: { in: %w[open closed] }, user_facing: "Each item needs a valid status"
      end
      def call = nil
    end
    result = action.call(items: [{ status: "a" }, { status: "b" }])
    expect(result.outcome).to be_failure
    expect(result.error).to eq("Each item needs a valid status")
  end

  it "composes a user_facing member nested inside a nested shape" do
    action = build_axn do
      expects :order, type: Hash do
        field :line, type: Hash do
          field :sku, type: String, user_facing: "SKU is required"
        end
      end
      def call = nil
    end
    result = action.call(order: { line: { sku: 123 } })
    expect(result.outcome).to be_failure
    expect(result.error).to eq("SKU is required")
  end

  it "rejects a non-parity user_facing value on a member at declaration" do
    expect do
      build_axn do
        expects :items, type: Array do
          field :status, type: String, user_facing: 123
        end
      end
    end.to raise_error(ArgumentError, /user_facing: must be true, a String, a Symbol, or a Proc/)
  end
end
```

- [ ] **Step 2: Run the specs to verify they fail**

Run: `bundle exec rspec spec/axn/core/user_facing_spec.rb -e "user_facing: on a shape member"`
Expected: failures — `user_facing: 123` currently reports "Unknown key(s)" (not the parity message), and the opt-in cases surface `"Something went wrong"` (member intent ignored).

- [ ] **Step 3: Add `user_facing` to `ShapeConfig`**

In `lib/axn/core/contract.rb`, change the `ShapeConfig` definition (currently `:100`):

```ruby
      ShapeConfig = Data.define(:field, :validations, :metadata, :method_call, :sensitive, :user_facing) do
        def initialize(field:, validations:, metadata: {}, method_call: false, sensitive: false, user_facing: false)
          super
        end

        include FieldOptionality

        def description = metadata[:description]
      end
```

- [ ] **Step 4: Accept + validate + thread member `user_facing:`**

In `lib/axn/core/contract.rb`, add `user_facing` to the allowlist (currently `:646`):

```ruby
        SHAPE_MEMBER_FIELD_OPTIONS = %i[allow_blank allow_nil optional method_call sensitive user_facing].freeze
```

Then in `_build_shape_member` (currently `:671`), validate the resolved value and thread it into the `ShapeConfig`. Replace the tail of the method (from `config = _parse_field_configs...` onward):

```ruby
          config = _parse_field_configs(name, metadata:, **field_opts, **field_validations).first
          raise ArgumentError, "coerce: is not supported on a shape member (top-level `expects` fields only)." if config.validations.dig(:type, :coerce)

          # A member's `user_facing:` has full parity with a field's — validate it through the same
          # gate, so a bad value (`user_facing: 123`) raises the same clear ArgumentError rather than
          # slipping through as an opaque option.
          _validate_user_facing!(config.user_facing)

          ShapeConfig.new(field: name, validations: config.validations, metadata: config.metadata,
                          method_call: config.method_call, sensitive: config.sensitive, user_facing: config.user_facing)
```

- [ ] **Step 5: Tag member errors at `ShapeValidator`**

In `lib/axn/core/validation/validators/shape_validator.rb`, tag both `record.errors.add` sites and add a helper. Change the unreadable-member add (currently `:60`):

```ruby
            record.errors.add(attribute, "#{prefix}#{member.field} could not be read (got #{source.class})",
                              axn_shape_member: true, axn_member_user_facing: member_user_facing(member))
```

Change the member-validator error loop (currently `:69`):

```ruby
          errors.each do |error|
            # A member error carries its own `user_facing:` intent. When re-wrapping an error that
            # bubbled up from this member's OWN nested shape (already tagged), keep the deeper member's
            # intent rather than overwriting it — so a `user_facing:` member composes at any depth. A
            # member's own direct-validator errors are untagged here and take this member's intent.
            intent = error.options[:axn_shape_member] ? error.options[:axn_member_user_facing] : member_user_facing(member)
            record.errors.add(attribute, "#{prefix}#{member.field} #{error.message}",
                              axn_shape_member: true, axn_member_user_facing: intent)
          end
```

Add the helper alongside `member_method_call?` (near `:113`):

```ruby
      # A member's `user_facing:` opt-in, honored when present. Duck-typed like `method_call:`/
      # `sensitive:` — a raw `shape:` member object that doesn't implement `#user_facing` defaults to
      # not opted in (dev-facing).
      def member_user_facing(member) = member.respond_to?(:user_facing) ? member.user_facing : false
```

- [ ] **Step 6: Partition + per-error dominance + composition in the executor**

In `lib/axn/executor.rb`, change the dominance line in `_validate_inbound!` (currently `:518`):

```ruby
      raise InboundValidationError, _aggregate_errors(failures, mismatches) unless mismatches.empty? && failures.all? { |f| _failure_fully_user_facing?(f) }
```

Replace `_composed_user_facing_error` (currently `:607-615`) and add the new helpers below it:

```ruby
    # The one exception raised when every classification unit is user-facing: all errors aggregated
    # (so dev-facing introspection still sees the full picture), with the composed message drawn per
    # unit — each failing config's own `user_facing:` and each shape-member's own tagged intent — one
    # uniform path for every depth. Parts are de-duplicated so a String/Symbol member override on an
    # Array shape surfaces once rather than repeating per failing element.
    def _composed_user_facing_error(failures)
      parts = failures.flat_map { |failure| _user_facing_parts(failure) }
      InboundValidationError.new(_aggregate_errors(failures, []),
                                 user_facing: true, user_facing_message: parts.uniq.to_sentence)
    end

    # A ContractFailure is a container of errors at two classification granularities: a shape-member
    # error (tagged by ShapeValidator) is its own structural, individually-classified unit; every
    # other error is the field's OWN error.
    def _own_errors(failure) = failure.errors.reject { |e| e.options[:axn_shape_member] }
    def _member_errors(failure) = failure.errors.select { |e| e.options[:axn_shape_member] }

    # A failure composes user-facing only when EVERY classification unit is: the field's own errors
    # honor the field's `user_facing:` (own empty ⇒ vacuously satisfied), and each shape-member error
    # honors the member's own tagged intent. A member error defaults dev-facing, so an un-opted member
    # forces the aggregate dev-facing.
    def _failure_fully_user_facing?(failure)
      (_own_errors(failure).empty? || failure.config.user_facing) &&
        _member_errors(failure).all? { |e| e.options[:axn_member_user_facing] }
    end

    # The user-facing message part(s) for one failure, per classification unit: the field's own errors
    # resolve through the field's `user_facing:`; each shape-member error resolves through its own
    # tagged intent, scoped to just that member's failure. Reached only when the failure is fully
    # user-facing.
    def _user_facing_parts(failure)
      parts = []
      own = _own_errors(failure)
      if own.any?
        parts.concat(_resolve_user_facing_override(failure.config.user_facing,
                                                   own: own.map(&:full_message),
                                                   scoped_error: InboundValidationError.new(_errors_containing(own))))
      end
      _member_errors(failure).each do |error|
        parts.concat(_resolve_user_facing_override(error.options[:axn_member_user_facing],
                                                   own: [error.full_message],
                                                   scoped_error: InboundValidationError.new(_errors_containing([error]))))
      end
      parts
    end

    # A fresh ActiveModel::Errors carrying just the given Error objects, so a Symbol/Proc user_facing
    # handler resolving against it sees exactly that classification unit's message (not the aggregate).
    def _errors_containing(error_list)
      errors = ActiveModel::Errors.new(Axn::Validation::Aggregate.new)
      error_list.each { |err| errors.import(err) }
      errors
    end
```

- [ ] **Step 7: Run the new specs and the whole file**

Run: `bundle exec rspec spec/axn/core/user_facing_spec.rb`
Expected: the new "user_facing: on a shape member" block PASSES; the two guard specs at `:512-534` still PASS (guard untouched in this task); everything else green.

- [ ] **Step 8: Commit**

```bash
git add lib/axn/core/contract.rb lib/axn/core/validation/validators/shape_validator.rb lib/axn/executor.rb spec/axn/core/user_facing_spec.rb
git commit -m "PRO-2925: per-member user_facing classification (member opt-in)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Remove the `user_facing:` + shape-block guard

The symmetry half. The partition machinery from Task 1 already classifies own vs member errors, so a `user_facing:` field that also carries a shape block "just works" once the declaration guard is gone: the field's own errors honor `user_facing:`, member errors stay dev-facing unless they opted in.

**Files:**
- Modify: `lib/axn/core/contract.rb` — remove the guard at `:189-191`.
- Test: `spec/axn/core/user_facing_spec.rb` — replace the two guard-pinning specs.

**Interfaces:**
- Consumes: the per-error partition machinery from Task 1.

- [ ] **Step 1: Replace the two guard specs with behavioral specs**

In `spec/axn/core/user_facing_spec.rb`, delete the two examples at `:512-534` ("rejects a shape block on a user_facing field" and "rejects a shape passed as a raw shape: kwarg") and add in their place:

```ruby
    describe "user_facing: on a field that also carries a shape block" do
      it "surfaces the field's own failure user-facing" do
        action = build_axn do
          expects :order, type: Hash, user_facing: "Order details are required" do
            field :sku, type: String
          end
          def call = nil
        end
        result = action.call # :order omitted → the field's OWN presence fails
        expect(result.outcome).to be_failure
        expect(result.error).to eq("Order details are required")
      end

      it "keeps a member failure dev-facing (does not leak) when the member fails alone" do
        action = build_axn do
          expects :order, type: Hash, user_facing: "Order details are required" do
            field :sku, type: String
          end
          def call = nil
        end
        result = action.call(order: { sku: 123 }) # field's own presence OK; member :sku invalid
        expect(result.outcome).to be_exception
        expect(result.error).to eq("Something went wrong")
      end

      it "lets dev-facing dominate and reports BOTH when the field's own check and a member both fail" do
        action = build_axn do
          # A custom `validate:` gives the field its OWN check that fails while the value is still a
          # valid Hash whose member also fails — the only way to co-fail the field's own error and a
          # member error in one call (an absent/wrong-type value would short-circuit ShapeValidator).
          expects :order, type: Hash, user_facing: "Order details are required",
                          validate: ->(v) { "order is not ready" unless v[:ready] } do
            field :sku, type: String
          end
          def call = nil
        end
        result = action.call(order: { sku: 123 }) # own validate: fails AND member :sku is not a String
        expect(result.outcome).to be_exception
        expect(result.error).to eq("Something went wrong")
        messages = result.exception.errors.full_messages.join(" ")
        expect(messages).to include("order is not ready")
        expect(messages).to include("sku")
      end

      it "accepts a shape passed as a raw shape: kwarg on a user_facing field" do
        expect do
          build_axn do
            expects :order, type: Hash, user_facing: true, shape: { members: [] }
            def call = nil
          end
        end.not_to raise_error
      end
    end
```

- [ ] **Step 2: Run to verify the acceptance specs fail on the guard**

Run: `bundle exec rspec spec/axn/core/user_facing_spec.rb -e "also carries a shape block"`
Expected: FAIL — `build_axn` raises `ArgumentError: user_facing: is not supported with a shape block` (guard still present).

- [ ] **Step 3: Remove the guard**

In `lib/axn/core/contract.rb`, delete the block currently at `:183-191` (the comment and the `if user_facing && validations[:shape]` raise):

```ruby
          # A shape (whether built from a `do … end` block or passed as a raw `shape:` option)
          # validates nested members, which `ShapeValidator` reports under this same attribute — so
          # reclassifying the field user-facing would wrongly turn a malformed-member (structural)
          # failure into a user-facing one. Nested member checks stay dev-facing at every level, so
          # reject the combination. Keyed on the resolved `validations[:shape]`, not the block, so a
          # direct `shape:` kwarg is caught too.
          if user_facing && validations[:shape]
            raise ArgumentError, "user_facing: is not supported with a shape block (nested member checks are always dev-facing)"
          end
```

- [ ] **Step 4: Run the file**

Run: `bundle exec rspec spec/axn/core/user_facing_spec.rb`
Expected: all green (new acceptance/behavioral specs pass; the deleted guard specs are gone).

- [ ] **Step 5: Run the full suite + rubocop**

Run: `bundle exec rspec spec/ && bundle exec rubocop lib/axn/core/contract.rb lib/axn/core/validation/validators/shape_validator.rb lib/axn/executor.rb`
Expected: all green; no offenses. If a shape-related spec elsewhere pinned the guard, update it to the new behavior.

- [ ] **Step 6: Commit**

```bash
git add lib/axn/core/contract.rb spec/axn/core/user_facing_spec.rb
git commit -m "PRO-2925: remove the user_facing: + shape-block declaration guard

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Docs + CHANGELOG

**Files:**
- Modify: `docs/reference/class.md` (`:155`, `:226`), `docs/usage/writing.md` (`:595`, `:599`), `CHANGELOG.md`.

- [ ] **Step 1: Update `docs/reference/class.md` — member options list (`:155`)**

Add `user_facing:` to the list of options a member accepts (currently "validations …, `optional`/`allow_blank`/`allow_nil`, `sensitive:`, and `description`"). Change it to include `user_facing:` with a one-line note that a member's own failure can surface to the caller (full parity with a field's `user_facing:`), defaulting dev-facing.

- [ ] **Step 2: Update `docs/reference/class.md` — the `user_facing:` section (`:226`)**

The current text ends with: "Two exceptions remain declaration errors: a shape block's member checks are always structural/dev-facing (so `user_facing:` + `do … end` is rejected at every level), and an ambient_context subfield …". Rewrite the shape clause: `user_facing:` now composes at shape depth too — a shape-carrying field's own errors honor its `user_facing:`, and a shape member may itself opt into `user_facing:` (defaults dev-facing). Keep the ambient_context clause as the one remaining declaration error.

- [ ] **Step 3: Update `docs/usage/writing.md` — the narrative (`:595`, `:599`)**

At `:599`, replace "Shape-block member checks stay structural/dev-facing (`user_facing:` + `do … end` is rejected at every level — member failures report under the parent's own attribute, so they can't be classified separately)" with: member checks default dev-facing but a member may opt into `user_facing:` (full parity), and a shape-carrying field's own errors honor the field's `user_facing:` independently of its members. Keep model-consistency + ambient_context as still-always-dev-facing.

- [ ] **Step 4: Add the CHANGELOG entry**

In `CHANGELOG.md`, under `## Unreleased`, add one `[FEAT]` line:

```markdown
* [FEAT] `user_facing:` now composes uniformly at every declaration depth, including shape members (PRO-2925). A shape-block member may opt into `user_facing:` with full parity to a field (`true`/String/Symbol/Proc) — `expects :items, type: Array do field :status, inclusion: { in: %w[open closed] }, user_facing: "Pick a valid status" end` surfaces the member's own failure to the caller — while a member that does not opt in stays dev-facing (a structural member failure never leaks). A field carrying a shape block may now itself be `user_facing:`: its OWN errors (e.g. the field's presence/type) surface user-facing while its members stay independently classified, so the previous rejection of `user_facing:` + a `do … end`/`shape:` block is gone. Settlement classifies per-error rather than per-config: dev-facing still dominates the moment any single unit (a field's own error under a non-`user_facing:` field, or an un-opted member) is dev-facing, and all violations co-report. Multi-element String/Symbol member overrides de-duplicate so an Array shape surfaces one clause, not one per failing element. Model-consistency checks and `ambient_context` subfields remain always dev-facing.
```

- [ ] **Step 5: Commit**

```bash
git add docs/reference/class.md docs/usage/writing.md CHANGELOG.md
git commit -m "PRO-2925: document per-member user_facing classification

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-review notes

- **Spec coverage:** member opt-in (true/String/Symbol/Proc) → Task 1 Step 1; un-opted member dev-facing → Task 1; multi-element uniq → Task 1; nested member → Task 1; parity validation → Task 1; guard removal + field-own user-facing + member-no-leak + both-reported → Task 2; docs/CHANGELOG → Task 3. All spec §Testing bullets covered.
- **Type consistency:** `ShapeConfig#user_facing`, `axn_shape_member`, `axn_member_user_facing`, `_own_errors`/`_member_errors`/`_failure_fully_user_facing?`/`_user_facing_parts`/`_errors_containing` are named identically everywhere they appear.
- **Guard-up testability (Task 1):** the field-level guard checks the *field's* `user_facing:`, never a member's, so every Task-1 member spec declares a field with no `user_facing:` and passes the guard — Task 1 is fully testable before Task 2 removes the guard.
- **"Both reported" edge:** an absent or wrong-type shape field short-circuits `ShapeValidator` (no member errors), so co-failing the field's OWN error and a member error in one call requires the value to be a valid container that fails an independent own check — the Task 2 "both fail" spec uses a custom `validate:` for that. Verify the exact `full_messages` when running and tighten the assertion if needed.
- **Message assertions:** the `user_facing: true` and Proc specs assert exact strings (`"Items element at index 0: status is not included in the list"`) — confirm the real full_message against ActiveModel's rendering on first run and correct the literal if it differs (attribute humanization / prefix spacing).
