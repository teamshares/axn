# Conditional Validation (`if:`/`unless:` on field declarations) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bless ActiveModel-style `if:`/`unless:` on `expects`/`exposes` declarations (conditional requiredness + conditional validation), with correct tolerance-flag interplay, schema reflection, and contradiction-detector carve-outs, per the approved spec.

**Architecture:** The runtime core already exists (the validations hash lands in one `validates` call, where `if:`/`unless:` are ActiveModel shared options). This plan adds the surrounding discipline: a shared gate-key constant, push-down/empty-set guards, two declaration-time rejections, reflection rules (static-maximal + a deliberate ancestor-forcing exception + declarative Symbol emission), the dead-tolerance carve-out, the Matcher both-conditions alignment, and docs.

**Tech Stack:** Ruby gem (axn), ActiveModel validations, RSpec.

**Spec:** `internal-docs/specs/2026-07-14-conditional-validation-if-unless-design.md` — read it first; it defines all semantics and rationale.

## Global Constraints

- **Sequencing: PRO-2907 must land first.** This branch builds on `kali/pro-2907-axn-add-shape-block-handling-of-method-calls` (shape-member `method_call:` gate): Task 2 consumes its `ShapeConfig#method_call`, the `permit_method_call:` kwarg on `Fields.errors_for`, and its regression specs, and Tasks 1-2 edit the same lines of `fields.rb`/`shape_validator.rb` it touched. Rebase this branch onto main AFTER PRO-2907 merges, before starting; if PRO-2907 hasn't merged, do Tasks 3-10 and hold Tasks 1-2 (Task 1's `validator_class_for` edit also collides trivially).
- **Orthogonality (PRO-2907): the `method_call:` dispatch gate must stay independent of action threading.** Permission is carried explicitly per call site (`permit_method_call:` — facade passes `true`, ShapeValidator passes `member.method_call`); when Task 2 threads `action:` into member validation it must NOT touch that kwarg or reintroduce any "action present → permit dispatch" inference. The regression spec "gate is independent of action threading" in `spec/axn/core/validations/shape_contracts_spec.rb` (written against exactly this change) must stay green.
- Reflection is side-effect-free: schema/contradiction code must NEVER call a condition Proc or dispatch methods on user values (repo doctrine; see `Schema` module header).
- Schema direction invariant: input schema may be stricter than runtime, never looser (documented exceptions only); output schema must admit a superset of what the runtime emits.
- No manual line breaks in Markdown prose (one line per paragraph — repo convention).
- Comments describe current behavior + intrinsic why; never reference this ticket's history or review rounds in code comments (PRO-XXXX pointers for cross-reference are established style and fine).
- Run `bundle exec rspec <file>` for targeted runs; full verification is `bundle exec rspec` + `bundle exec rubocop` from the repo root, plus the Rails dummy-app suite (`cd spec_rails/dummy_app && bundle exec rspec`) at the end.
- All work on branch `kali/pro-2881-axn-global-conditional-requiredness-ifunless-on-validations`; commit after each task with the trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Test helper: `build_axn { ...class body... }` (auto-included) builds an anonymous action class; `Action.call(...)` returns a result with `ok?`/`exception`; a dev-facing inbound violation surfaces as `result.exception` being an `Axn::InboundValidationError`.

---

### Task 1: Gate-key constant, push-down guard, tolerance-vs-presence rejection, empty-validator-set guard

**Files:**
- Modify: `lib/axn/internal/field_config.rb` (add constant)
- Modify: `lib/axn/core/contract.rb:721-730` (`_parse_field_validations` push-down branch)
- Modify: `lib/axn/core/validation/fields.rb:50-54` (`validator_class_for`)
- Test: `spec/axn/core/conditional_validation_spec.rb` (create)

**Interfaces:**
- Produces: `Axn::Internal::FieldConfig::CONDITIONAL_GATE_KEYS` (`%i[if unless].freeze`) — every later task references this constant; never hardcode `%i[if unless]` elsewhere.

- [ ] **Step 1: Write the failing tests**

Create `spec/axn/core/conditional_validation_spec.rb`:

```ruby
# frozen_string_literal: true

RSpec.describe "conditional validation declarations (if:/unless:)" do
  describe "tolerance flags + declaration-level condition" do
    it "declares and runs (condition gates validators; tolerance keeps the field omittable)" do
      action = build_axn do
        expects :flag, type: :boolean
        expects :note, type: String, optional: true, if: :flag
        def call; end
      end

      expect(action.call(flag: false).ok?).to be true                 # omitted, tolerance
      expect(action.call(flag: false, note: 123).ok?).to be true      # type gated off
      expect(action.call(flag: true).ok?).to be true                  # still omittable (optional:)
      expect(action.call(flag: true, note: 123).ok?).to be false      # type enforced, blank-tolerant
      expect(action.call(flag: true, note: "hi").ok?).to be true
    end

    it "declares cleanly when the tolerance leaves no validators at all" do
      action = build_axn do
        expects :note, optional: true, if: :never
        def never = false
        def call; end
      end

      expect(action.call.ok?).to be true
      expect(action.call(note: "anything").ok?).to be true
    end
  end

  describe "tolerance flags + explicit presence:" do
    it "rejects optional: + presence: true with a clear declaration error" do
      expect do
        build_axn { expects :note, optional: true, presence: true }
      end.to raise_error(ArgumentError, /cannot be combined with an explicit `presence:`/)
    end

    it "rejects allow_nil: + a per-validator conditional presence (the tolerance would neuter it)" do
      expect do
        build_axn { expects :note, allow_nil: true, presence: { if: :cond } }
      end.to raise_error(ArgumentError, /cannot be combined with an explicit `presence:`/)
    end

    it "still allows presence: false alongside a tolerance flag (explicit suppression, coherent)" do
      expect { build_axn { expects :note, optional: true, presence: false } }.not_to raise_error
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/axn/core/conditional_validation_spec.rb`
Expected: FAIL — the first two with `TypeError: no implicit conversion of Symbol into Hash` at declaration, the `presence: true` one with `TypeError` (not the required `ArgumentError` message), the `presence: { if: }` one failing the message match.

- [ ] **Step 3: Implement**

In `lib/axn/internal/field_config.rb`, after `module_function` (line 8), add:

```ruby
      # The ActiveModel shared-option keys that conditionally gate a declaration's validators
      # (`expects :x, ..., if:`/`unless:`). They ride the validations hash as sibling keys but are
      # not validators themselves: the tolerance push-down skips them, reflection treats them as
      # neutral, and the contradiction detectors treat a gated declaration as relaxable.
      CONDITIONAL_GATE_KEYS = %i[if unless].freeze
```

In `lib/axn/core/contract.rb`, replace the push-down branch (currently lines 721-726):

```ruby
          # Push allow_blank and allow_nil to the individual validations
          if allow_blank || allow_nil
            validations.transform_values! do |v|
              { allow_blank:, allow_nil: }.merge(v)
            end
          else
```

with:

```ruby
          # Push allow_blank and allow_nil to the individual validations
          if allow_blank || allow_nil
            # A truthy explicit presence: can never fire under a tolerance flag — the pushed-down
            # allow_blank/allow_nil would make the presence validator accept exactly the values it
            # exists to reject — so the combination is dead machinery, rejected at declaration.
            # (`presence: false` is coherent: explicit suppression, same intent as the flag.)
            if validations[:presence]
              raise ArgumentError,
                    "optional:/allow_blank:/allow_nil: cannot be combined with an explicit `presence:` — " \
                    "the tolerance is pushed into every validator, so the presence check could never fail. " \
                    "Declare one requiredness signal (drop the flag, or drop presence:)."
            end

            # `if:`/`unless:` are ActiveModel shared options riding the hash as sibling keys, not
            # validators — there is nothing to push tolerance flags into.
            gates = validations.slice(*Internal::FieldConfig::CONDITIONAL_GATE_KEYS)
            validations.except!(*Internal::FieldConfig::CONDITIONAL_GATE_KEYS)
            validations.transform_values! do |v|
              { allow_blank:, allow_nil: }.merge(v)
            end
            validations.merge!(gates)
          else
```

In `lib/axn/core/validation/fields.rb`, replace (currently lines 51-53):

```ruby
          # A field may legitimately carry no validators at all (e.g. `optional: true` with no
          # type/model), which `validates` rejects — an empty set means nothing to enforce.
          validates field, **validations unless validations.empty?
```

with:

```ruby
          # A field may legitimately carry no validators at all (e.g. `optional: true` with no
          # type/model), which `validates` rejects — an empty set means nothing to enforce. Gate
          # keys (if:/unless:) don't count toward the set: with every validator gated away there
          # is nothing to conditionally run either.
          validates field, **validations unless validations.except(*Axn::Internal::FieldConfig::CONDITIONAL_GATE_KEYS).empty?
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/axn/core/conditional_validation_spec.rb`
Expected: PASS (all).

- [ ] **Step 5: Run the adjacent suites to catch regressions**

Run: `bundle exec rspec spec/axn/core spec/axn/reflection`
Expected: PASS (no existing spec pins the old TypeError crashes; if one does, update it to the new ArgumentError and note it in the commit message).

- [ ] **Step 6: Commit**

```bash
git add lib/axn/internal/field_config.rb lib/axn/core/contract.rb lib/axn/core/validation/fields.rb spec/axn/core/conditional_validation_spec.rb
git commit -m "PRO-2881: Gate-key constant + tolerance push-down guard + presence rejection

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Thread the action into shape-member validation (member conditions + Symbol args)

> **DEPENDS ON PRO-2907 having merged and this branch being rebased on it** (see Global Constraints). The code below assumes PRO-2907's `fields.rb`/`shape_validator.rb` (with `permit_method_call:`); on the pre-2907 tree the anchors won't match.

Members already *compile* `if:`/`unless:` (they share `_parse_field_validations`; the gates survive onto `ShapeConfig#validations`, and Task 1's push-down guard covers them). The gap is runtime-only: `ShapeValidator` passes no `action:` into the per-member `errors_for`, so ANY action-scoped Symbol/Proc on a member — an `if:` condition or a Symbol validator argument like `inclusion: { in: :allowed_statuses }` — dies with `NoMethodError: undefined method ... for an instance of Axn::Validation::Fields::OneOff` (verified by probe; the same declaration works top-level). Fix: `validate_each`'s `record` IS the parent field's one-off validator, which already carries `@action` — read it via the `_action_for_validation` seam and thread it down. Nested shapes inherit for free (the member's validator becomes the next level's `record`).

**Files:**
- Modify: `lib/axn/core/validation/validators/shape_validator.rb` (`validate_members`, currently ~lines 43-55 on the PRO-2907 tree)
- Test: `spec/axn/core/conditional_validation_spec.rb` (extend), `spec/axn/core/validations/shape_contracts_spec.rb` (must stay green untouched)

**Interfaces:**
- Consumes: `Axn::Validation::Base#_action_for_validation` (private reader for the injected `@action`); PRO-2907's `permit_method_call:` kwarg on `Fields.errors_for` and `ShapeConfig#method_call`.
- Constraint: `permit_method_call: member.method_call` stays EXACTLY as-is — do not add, remove, or derive it from the action (Global Constraints orthogonality rule).

- [ ] **Step 1: Write the failing tests**

Append to `spec/axn/core/conditional_validation_spec.rb`:

```ruby
  describe "shape members (action-scoped conditions and Symbol args)" do
    it "resolves a member's Symbol validator argument against the action" do
      action = build_axn do
        expects :payload, type: Hash do
          field :status, type: String, inclusion: { in: :allowed_statuses }
        end
        def allowed_statuses = %w[open closed]
        def call; end
      end
      expect(action.call(payload: { status: "open" }).ok?).to be true
      expect(action.call(payload: { status: "bogus" }).ok?).to be false
    end

    it "gates a member's validations on an action-scoped if: condition" do
      action = build_axn do
        expects :flag, type: :boolean
        expects :payload, type: Hash do
          field :note, type: String, if: :flag
        end
        def call; end
      end
      expect(action.call(flag: false, payload: {}).ok?).to be true
      expect(action.call(flag: false, payload: { note: 123 }).ok?).to be true
      expect(action.call(flag: true, payload: {}).ok?).to be false
      expect(action.call(flag: true, payload: { note: "hi" }).ok?).to be true
    end

    it "resolves conditions on NESTED members (the member's validator carries the action down)" do
      action = build_axn do
        expects :flag, type: :boolean
        expects :payload, type: Hash do
          field :meta, type: Hash do
            field :note, type: String, if: :flag
          end
        end
        def call; end
      end
      expect(action.call(flag: false, payload: { meta: {} }).ok?).to be true
      expect(action.call(flag: true, payload: { meta: {} }).ok?).to be false
    end

    it "does NOT expose element data to conditions (action-scoped only — element scoping is a non-goal)" do
      action = build_axn do
        expects :items, type: Array do
          field :b, type: String, if: -> { a }  # `a` is a sibling MEMBER, not an action method
        end
        def call; end
      end
      result = action.call(items: [{ "a" => true }])
      expect(result.ok?).to be false
      expect(result.exception).to be_a(NoMethodError) # condition cannot see the element
    end
  end
```

(For the last example: pin whatever exception class actually surfaces — the contract is "does not silently resolve against the element"; adjust the matcher to the observed class and leave a comment.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/axn/core/conditional_validation_spec.rb -e "shape members"`
Expected: the first three FAIL with `NoMethodError` surfacing as the call's exception; the last may already pass (pins the non-goal).

- [ ] **Step 3: Implement**

In `lib/axn/core/validation/validators/shape_validator.rb`, replace `validate_members`:

```ruby
      def validate_members(record, attribute, source, prefix:)
        members.each do |member|
          unless extractable?(source, member.field)
            record.errors.add(attribute, "#{prefix}#{member.field} could not be read (got #{source.class})")
            next
          end

          errors = Axn::Validation::Fields.errors_for(
            member_validator_classes[member.field], source:, validations: member.validations,
            action: record.send(:_action_for_validation), permit_method_call: member.method_call
          )
          errors.each { |error| record.errors.add(attribute, "#{prefix}#{member.field} #{error.message}") }
        end
      end
```

Add a comment above the `errors_for` call:

```ruby
          # `record` is the parent field's one-off validator, which carries the action (threaded by
          # errors_for at every level) — pass it down so a member's Symbol/Proc arguments and
          # if:/unless: conditions resolve against the ACTION, exactly as at the top level (a member
          # condition is action-scoped, never element-scoped). Orthogonal to the dispatch gate:
          # permission stays the member's own method_call: opt-in, never inferred from the action.
```

Nothing else changes — in particular `permit_method_call: member.method_call` is untouched.

- [ ] **Step 4: Run tests to verify they pass — including the PRO-2907 regression suite**

Run: `bundle exec rspec spec/axn/core/conditional_validation_spec.rb spec/axn/core/validations/shape_contracts_spec.rb`
Expected: PASS — all new examples AND the untouched shape-contracts suite, especially "gate is independent of action threading" (if that one fails, the orthogonality constraint was violated — do not adjust the spec; fix the change).

- [ ] **Step 5: Commit**

```bash
git add lib/axn/core/validation/validators/shape_validator.rb spec/axn/core/conditional_validation_spec.rb
git commit -m "PRO-2881: Thread action into shape-member validation (conditions + Symbol args resolve)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Runtime behavior matrix (pin the blessed semantics)

**Files:**
- Test: `spec/axn/core/conditional_validation_spec.rb` (extend; no lib changes expected — this pins behavior that now exists)

**Interfaces:**
- Consumes: guards from Task 1.

- [ ] **Step 1: Write the tests**

Append to `spec/axn/core/conditional_validation_spec.rb`:

```ruby
  describe "declaration-level if:/unless: runtime semantics" do
    let(:action) do
      build_axn do
        expects :flag, type: :boolean
        expects :num, type: Integer, if: :flag
        def call; end
      end
    end

    it "skips ALL validation (requiredness and type) when the condition is false" do
      expect(action.call(flag: false).ok?).to be true
      expect(action.call(flag: false, num: "junk").ok?).to be true
    end

    it "enforces requiredness and type when the condition is true" do
      failed = action.call(flag: true)
      expect(failed.ok?).to be false
      expect(failed.exception).to be_a(Axn::InboundValidationError)
      expect(action.call(flag: true, num: "junk").ok?).to be false
      expect(action.call(flag: true, num: 5).ok?).to be true
    end

    it "supports the boolean field's generated ? predicate as the Symbol" do
      predicated = build_axn do
        expects :flag, type: :boolean
        expects :num, type: Integer, if: :flag?
        def call; end
      end
      expect(predicated.call(flag: false).ok?).to be true
      expect(predicated.call(flag: true).ok?).to be false
    end

    it "supports a custom action method and a zero-arity Proc (method calls resolve to the action)" do
      custom = build_axn do
        expects :flag, type: :boolean
        expects :a, type: String, if: :enforce?
        expects :b, type: String, if: -> { flag }
        def enforce? = flag
        def call; end
      end
      expect(custom.call(flag: false).ok?).to be true
      expect(custom.call(flag: true, a: "x", b: "y").ok?).to be true
      expect(custom.call(flag: true, a: "x").ok?).to be false
      expect(custom.call(flag: true, b: "y").ok?).to be false
    end

    it "supports unless: (validates only when falsey) and if:+unless: together (ANDed)" do
      both = build_axn do
        expects :on_flag, :off_flag, type: :boolean
        expects :num, type: Integer, if: :on_flag, unless: :off_flag
        def call; end
      end
      expect(both.call(on_flag: false, off_flag: false).ok?).to be true
      expect(both.call(on_flag: true, off_flag: true).ok?).to be true
      expect(both.call(on_flag: true, off_flag: false).ok?).to be false
    end
  end

  describe "conditions on subfields and exposes" do
    it "gates a subfield's validations (required-when-parent-present pattern)" do
      action = build_axn do
        expects :data, optional: true
        expects :user, type: String, on: :data, if: -> { data.present? }
        def call; end
      end
      expect(action.call.ok?).to be true                                  # parent omitted
      expect(action.call(data: { user: "kali" }).ok?).to be true
      expect(action.call(data: { role: "admin" }).ok?).to be false        # parent present, user missing
    end

    it "gates an exposes field's outbound validation" do
      action = build_axn do
        expects :flag, type: :boolean
        exposes :num, type: Integer, if: :flag
        def call; end
      end
      expect(action.call(flag: false).ok?).to be true                     # nothing exposed, gate closed
      failed = action.call(flag: true)
      expect(failed.ok?).to be false
      expect(failed.exception).to be_a(Axn::OutboundValidationError)
    end
  end

  describe "conditions gate validation only" do
    it "still applies default: and preprocess: when the condition is false" do
      action = build_axn do
        expects :flag, type: :boolean
        expects :num, type: Integer, default: 42, if: :flag
        expects :name, type: String, preprocess: ->(v) { v.to_s.strip }, allow_nil: true, if: :flag
        exposes :seen_num, :seen_name, allow_nil: true
        def call
          expose seen_num: num, seen_name: name
        end
      end
      result = action.call(flag: false, name: "  kali  ")
      expect(result.ok?).to be true
      expect(result.seen_num).to eq(42)
      expect(result.seen_name).to eq("kali")
    end
  end

  describe "evaluation count" do
    it "may evaluate a declaration-level condition more than once per validation pass (documented; conditions must be cheap/idempotent)" do
      count = 0
      action = build_axn do
        expects :num, type: Integer, if: -> { count += 1; true }
        def call; end
      end
      result = action.call(num: 5)
      expect(result.ok?).to be true
      expect(count).to be >= 1 # AM applies the shared option per validator; exact count is AM-internal
    end
  end

  # NOTE for the implementer: the Proc above closes over the spec-local `count` variable, which works
  # because instance_exec preserves the closure — no action method needed. If the harness's build_axn
  # block scoping interferes, hoist `count` to an example-group `let` or a module-level accumulator.
  # Assert `>= 1` (and, if stable, the current exact value with a comment that it pins AM internals).

  describe "per-validator nested if: (split validations on one field)" do
    it "gates only the validator carrying the condition" do
      action = build_axn do
        expects :flag, type: :boolean
        expects :num, type: Integer, numericality: { greater_than: 100, if: :flag }
        def call; end
      end
      expect(action.call(flag: false, num: 5).ok?).to be true
      expect(action.call(flag: true, num: 5).ok?).to be false
      expect(action.call(flag: true, num: 500).ok?).to be true
      expect(action.call(flag: false, num: "junk").ok?).to be false      # type still unconditional
    end
  end
```

Note: the subfield example (`data`/`user`) FAILS AT DECLARATION until Task 5 lands (the dead-tolerance detector still rejects it). Wrap that one example in `pending "until the gated-config carve-out (Task 5)"` for now, and remove the `pending` in Task 5.

- [ ] **Step 2: Run and verify**

Run: `bundle exec rspec spec/axn/core/conditional_validation_spec.rb`
Expected: PASS, with the subfield example pending. If any non-pending example fails, the runtime semantics diverge from the spec — STOP and investigate rather than adjusting the assertion (these pins ARE the spec).

- [ ] **Step 3: Commit**

```bash
git add spec/axn/core/conditional_validation_spec.rb
git commit -m "PRO-2881: Pin declaration-level and per-validator condition runtime semantics

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Schema statics — gate-neutral `nil_accepted?`, `conditionally_gated?`, gated-exposes nullability

**Files:**
- Modify: `lib/axn/reflection/schema.rb:1081-1096` (`nil_accepted?`) and `schema.rb:785-810` (`build_property`)
- Test: `spec/axn/reflection/schema_spec.rb` (extend)

**Interfaces:**
- Produces: `Axn::Reflection::Schema.conditionally_gated?(config)` — Tasks 5 and 6 call it.

- [ ] **Step 1: Write the failing tests**

Append to `spec/axn/reflection/schema_spec.rb` (a new top-level describe, following the file's existing `build_axn`-based style):

```ruby
  describe "conditional validation (if:/unless:) reflection" do
    it "reflects a bare conditional field static-maximal (required, non-null) without executing the condition" do
      ran = false
      action = build_axn do
        expects :flag, type: :boolean
        expects :num, type: Integer, if: -> { ran = true }
      end
      schema = action.input_schema
      expect(schema[:required]).to include("num")
      expect(schema[:properties][:num][:type]).to eq("integer")
      expect(ran).to be false
    end

    it "keeps a tolerance-flagged conditional field optional (the static tolerance is unconditional)" do
      action = build_axn do
        expects :note, type: String, optional: true, if: :cond
      end
      schema = action.input_schema
      expect(schema[:required].to_a).not_to include("note")
      expect(schema[:properties][:note][:type]).to eq(%w[string null])
    end

    it "admits null on a gated exposes property (a closed gate can emit nil)" do
      action = build_axn do
        expects :flag, type: :boolean
        exposes :num, type: Integer, if: :flag
        def call; end
      end
      expect(action.output_schema[:properties][:num][:type]).to eq(%w[integer null])
    end

    it "reflects a gated shape member static-maximal (required inside its object)" do
      action = build_axn do
        expects :flag, type: :boolean
        expects :payload, type: Hash do
          field :note, type: String, if: :flag
        end
      end
      prop = action.input_schema[:properties][:payload]
      expect(prop[:required]).to include("note")
      expect(prop[:properties][:note][:type]).to eq("string")
    end
  end
```

(The shape-member example only needs Task 1 — members share the parse path — but its runtime counterpart lands in Task 2.)

- [ ] **Step 2: Run tests to verify current state**

Run: `bundle exec rspec spec/axn/reflection/schema_spec.rb -e "conditional validation"`
Expected: first example PASSES already (the `:if` key accidentally reads as nil-rejecting); second and third FAIL (`note` reflects required/non-null; `num` output reflects non-null).

- [ ] **Step 3: Implement**

In `lib/axn/reflection/schema.rb`, replace `nil_accepted?` (currently lines 1081-1086):

```ruby
      def nil_accepted?(config)
        v = config.validations
        return true if v.empty?

        v.all? { |key, opt| nil_tolerant_validation?(key, opt) }
      end
```

with:

```ruby
      def nil_accepted?(config)
        # Gate keys (if:/unless:) are shared options, not validators — neutral here. The judgment is
        # static-maximal: the gated validators are counted as if their gates were open (a condition
        # can only relax enforcement at runtime, never tighten it).
        v = config.validations.except(*Internal::FieldConfig::CONDITIONAL_GATE_KEYS)
        return true if v.empty?

        v.all? { |key, opt| nil_tolerant_validation?(key, opt) }
      end

      # Whether the config's declaration carries a declaration-level if:/unless: gate — the signal
      # that its enforcement (NOT its shape) is conditional at runtime.
      def conditionally_gated?(config)
        Internal::FieldConfig::CONDITIONAL_GATE_KEYS.any? { |k| config.validations.key?(k) }
      end
```

In `build_property` (currently line 790), replace:

```ruby
        nullable = nil_allowed?(config)
```

with:

```ruby
        # OUTPUT safety runs the other direction from input: the property must admit a superset of
        # what the serializer can emit. A gated outbound field may skip its validators entirely
        # (condition false), so nil can flow through — admit null regardless of the validators'
        # own nil-tolerance.
        nullable = nil_allowed?(config) || (for_output && conditionally_gated?(config))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/axn/reflection/schema_spec.rb`
Expected: PASS (all, including pre-existing).

- [ ] **Step 5: Commit**

```bash
git add lib/axn/reflection/schema.rb spec/axn/reflection/schema_spec.rb
git commit -m "PRO-2881: Gate-neutral nil_accepted? + gated exposes admit null on output

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Gated nodes don't force ancestors + dead-tolerance carve-out + extended rejection message

**Files:**
- Modify: `lib/axn/reflection/schema.rb:263-286` (`annotate_node!`)
- Modify: `lib/axn/reflection/subfield_contradictions.rb:198-212` (`raise_dead_tolerance!`)
- Test: `spec/axn/reflection/subfield_contradictions_spec.rb`, `spec/axn/reflection/schema_spec.rb`, `spec/axn/core/conditional_validation_spec.rb` (un-pend the Task 3 subfield example)

**Interfaces:**
- Consumes: `Schema.conditionally_gated?` (Task 4).

- [ ] **Step 1: Write the failing tests**

Append to `spec/axn/reflection/subfield_contradictions_spec.rb`:

```ruby
  describe "conditionally gated required subfields (PRO-2881)" do
    it "accepts a nil-tolerant parent whose required subfield is gated (the tolerance is exercisable)" do
      expect do
        build_axn do
          expects :data, optional: true
          expects :user, type: String, on: :data, if: -> { data.present? }
        end
      end.not_to raise_error
    end

    it "still rejects when an UNGATED required sibling strands the parent" do
      expect do
        build_axn do
          expects :data, optional: true
          expects :user, type: String, on: :data, if: -> { data.present? }
          expects :role, type: String, on: :data
        end
      end.to raise_error(ArgumentError, /:data is declared nil-tolerant/)
    end

    it "points the rejection message at the conditional spelling" do
      expect do
        build_axn do
          expects :data, optional: true
          expects :user, type: String, on: :data
        end
      end.to raise_error(ArgumentError, /gate it conditionally.*if: -> \{ data\.present\? \}/m)
    end
  end
```

Append to `spec/axn/reflection/schema_spec.rb` (inside the Task 4 describe):

```ruby
    it "does not force a gated required subfield's ancestors (own-level nested required kept)" do
      action = build_axn do
        expects :data, optional: true
        expects :user, type: String, on: :data, if: -> { data.present? }
      end
      schema = action.input_schema
      expect(schema[:required].to_a).not_to include("data")
      expect(schema[:properties][:data][:type]).to eq(%w[object null])
      expect(schema[:properties][:data][:required]).to eq(["user"])
      expect(schema[:properties][:data][:properties][:user][:type]).to eq("string")
    end

    it "keeps ancestor-forcing when any config at the node is ungated" do
      action = build_axn do
        expects :data, type: Hash
        expects :user, type: String, on: :data, if: :cond
        expects :role, type: String, on: :data
      end
      schema = action.input_schema
      expect(schema[:required]).to include("data")
      expect(schema[:properties][:data][:required]).to match_array(%w[user role])
    end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/axn/reflection/subfield_contradictions_spec.rb spec/axn/reflection/schema_spec.rb`
Expected: FAIL — the gated parent/child declaration raises the dead-tolerance ArgumentError; the message lacks the conditional pointer; the schema examples can't even declare.

- [ ] **Step 3: Implement**

In `lib/axn/reflection/schema.rb` `annotate_node!`, after the `required = !node_optional?(...)` line (currently line 270), add:

```ruby
        # A node whose EVERY declaration is conditionally gated never forces its ancestors: the
        # gates may all be closed at runtime, so an omitted/nil ancestor CAN validate. Own-level
        # emission stays static-maximal (apply_children! consults node_optional? directly, so the
        # nested `required` keeps the gated obligation) — this only stops requiredness from
        # propagating upward. Mode-independent: satisfiability mode needs it so a declared
        # tolerance above a gated child is exercisable (not dead), and strict mode honors the
        # ancestor's own declared optionality instead of inventing strictness the declaration
        # disavowed (see the design doc's "one deliberate exception"). An implicit node has no
        # configs, so it is untouched (its required already follows its — now relaxed — subtree).
        required &&= !(node.configs.any? && node.configs.all? { |c| conditionally_gated?(c) })
```

In `lib/axn/reflection/subfield_contradictions.rb` `raise_dead_tolerance!`, replace the final message segment (currently):

```ruby
              "Drop the tolerance on :#{owner}, or mark #{stranded ? ":#{stranded}" : 'the subtree'} optional: or give it a " \
              "default: (declare rescuing defaults BEFORE the dependent subfield).#{model_hint}"
```

with:

```ruby
              "Drop the tolerance on :#{owner}, or mark #{stranded ? ":#{stranded}" : 'the subtree'} optional: or give it a " \
              "default: (declare rescuing defaults BEFORE the dependent subfield). If it is only required when " \
              ":#{owner} is supplied, gate it conditionally: `expects ..., if: -> { #{owner}.present? }`.#{model_hint}"
```

In `spec/axn/core/conditional_validation_spec.rb`, remove the `pending` from the Task 3 subfield example.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/axn/reflection spec/axn/core/conditional_validation_spec.rb`
Expected: PASS, including the previously-pending subfield runtime example and all pre-existing contradiction/schema specs (existing dead-tolerance message pins match on the message HEAD, which is unchanged; if one pins the full tail, extend it).

- [ ] **Step 5: Commit**

```bash
git add lib/axn/reflection/schema.rb lib/axn/reflection/subfield_contradictions.rb spec/axn/reflection spec/axn/core/conditional_validation_spec.rb
git commit -m "PRO-2881: Gated nodes don't force ancestors; dead-tolerance carve-out + message pointer

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Declarative Symbol conditions → exact `allOf`/`if`/`then` emission

**Files:**
- Modify: `lib/axn/reflection/schema.rb:71-106` (`build_input`) + two new module functions
- Test: `spec/axn/reflection/schema_spec.rb` (extend)

**Interfaces:**
- Consumes: `Schema.conditionally_gated?` conceptually; gate keys via `Internal::FieldConfig::CONDITIONAL_GATE_KEYS`.
- Produces: `Schema.conditional_requiredness_clause(config, field_configs, node)` and `Schema.condition_reference(rule, field_configs)` (module functions; private to the schema layer, but named here so tests can target behavior through `input_schema`).

- [ ] **Step 1: Write the failing tests**

Append to `spec/axn/reflection/schema_spec.rb` (inside the conditional-validation describe):

```ruby
    describe "declarative Symbol conditions (allOf/if/then emission)" do
      it "emits an exact conditional for a Symbol referencing a declared sibling field" do
        action = build_axn do
          expects :promo_enabled, type: :boolean
          expects :coupon_code, type: String, if: :promo_enabled?
        end
        schema = action.input_schema
        expect(schema[:required].to_a).not_to include("coupon_code")
        expect(schema[:allOf]).to eq([{
                                       if: {
                                         required: ["promo_enabled"],
                                         properties: { promo_enabled: { not: { enum: [false, nil] } } },
                                       },
                                       then: { required: ["coupon_code"] },
                                     }])
        expect(schema[:properties][:coupon_code][:type]).to eq("string")
      end

      it "emits else for unless:" do
        action = build_axn do
          expects :skip_check, type: :boolean
          expects :coupon_code, type: String, unless: :skip_check
        end
        clause = action.input_schema[:allOf].first
        expect(clause[:if][:required]).to eq(["skip_check"])
        expect(clause[:else]).to eq({ required: ["coupon_code"] })
        expect(clause).not_to have_key(:then)
      end

      it "falls back to unconditional required when any guard fails" do
        fallback_required = lambda do |&decl|
          schema = build_axn(&decl).input_schema
          expect(schema[:allOf]).to be_nil
          expect(schema[:required]).to include("coupon_code")
        end

        # Proc condition (opaque)
        fallback_required.call do
          expects :flag, type: :boolean
          expects :coupon_code, type: String, if: -> { flag }
        end
        # Symbol naming a non-field action method (opaque)
        fallback_required.call do
          expects :coupon_code, type: String, if: :some_method
        end
        # referenced field carries a default (settled value can diverge from the wire)
        fallback_required.call do
          expects :flag, type: :boolean, default: true
          expects :coupon_code, type: String, if: :flag
        end
        # referenced field carries a preprocess
        fallback_required.call do
          expects :flag, preprocess: ->(v) { !v.nil? }, optional: true
          expects :coupon_code, type: String, if: :flag
        end
        # referenced field is model:-routed (lookup success isn't wire-expressible)
        fallback_required.call do
          expects :user, model: { klass: "User", finder: :find }, optional: true
          expects :coupon_code, type: String, if: :user
        end
        # both if: and unless: given
        fallback_required.call do
          expects :a, :b, type: :boolean
          expects :coupon_code, type: String, if: :a, unless: :b
        end
      end

      it "emits no clause for an already-optional gated field (nothing to make conditional)" do
        action = build_axn do
          expects :flag, type: :boolean
          expects :coupon_code, type: String, optional: true, if: :flag
        end
        schema = action.input_schema
        expect(schema[:allOf]).to be_nil
        expect(schema[:required].to_a).not_to include("coupon_code")
      end

      it "matches the referenced field through an as: alias and emits its wire key" do
        action = build_axn do
          expects :promo, type: :boolean, as: :promotion
          expects :coupon_code, type: String, if: :promotion
        end
        clause = action.input_schema[:allOf].first
        expect(clause[:if][:required]).to eq(["promo"])
      end
    end
```

Note on the `model:` fallback example: the repo's schema specs already have a pattern for declaring `model:` without a real class — copy the existing pattern from `schema_spec.rb` (search for `model:` there) if the literal `klass: "User"` form differs.

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/axn/reflection/schema_spec.rb -e "declarative Symbol"`
Expected: FAIL — no `allOf` is emitted anywhere today; gated fields are unconditionally required.

- [ ] **Step 3: Implement**

In `lib/axn/reflection/schema.rb` `build_input`, initialize `conditionals = []` alongside `required = []`, and replace the requiredness line (currently line 92):

```ruby
            required << config.field.to_s unless field_optional?(config, node.children, ann)
```

with:

```ruby
            unless field_optional?(config, node.children, ann)
              clause = conditional_requiredness_clause(config, field_configs, node)
              clause ? conditionals << clause : required << config.field.to_s
            end
```

and before the final `schema[:required] = ...` line, add:

```ruby
        schema[:allOf] = conditionals unless conditionals.empty?
```

Add the two module functions (place them after `field_optional?`):

```ruby
      # An exact JSON Schema conditional for a gated-but-otherwise-required top-level field whose
      # single Symbol condition references a declared sibling field. Ruby truthiness on a JSON value
      # is precisely "present, and neither false nor null", so the emitted clause matches the runtime
      # gate exactly. Returns nil — fall back to unconditional `required`, the static-maximal safe
      # direction — unless EVERY guard holds:
      #   * exactly one gate (if: XOR unless:), and its rule is a Symbol;
      #   * the Symbol resolves to a declared top-level inbound field's reader (condition_reference);
      #   * the referenced field carries no default: and no preprocess: (either can make the settled
      #     runtime value diverge from what the caller sent, flipping the gate relative to the wire —
      #     wire coercion is fine: it can only flip a truthy wire literal to falsey, which leaves the
      #     schema stricter, never looser) and is not model:-routed (lookup success isn't
      #     wire-expressible) nor schema-excluded;
      #   * the gated field is not model:-routed and has no subfields of its own (a required
      #     descendant unconditionally forces the field, contradicting a conditional requirement).
      def conditional_requiredness_clause(config, field_configs, node)
        return nil if config.validations[:model] || node.children.any?

        gates = config.validations.slice(*Internal::FieldConfig::CONDITIONAL_GATE_KEYS)
        return nil unless gates.size == 1

        rule = gates.values.first
        return nil unless rule.is_a?(Symbol)

        ref = condition_reference(rule, field_configs)
        return nil unless ref
        return nil if ref.validations[:model] || !ref.default.nil? || ref.preprocess
        return nil if EXCLUDED_FROM_INPUT_SCHEMA.include?(ref.field)

        condition = {
          required: [ref.field.to_s],
          properties: { ref.field => { not: { enum: [false, nil] } } },
        }
        branch = gates.key?(:if) ? :then : :else
        { if: condition, branch => { required: [config.field.to_s] } }
      end

      # The declared top-level inbound field a Symbol condition reads: an exact reader-name match,
      # or — for a `?`-suffixed Symbol — the boolean field whose generated predicate alias it names.
      # The condition reads the READER; the emitted schema keys by the field's WIRE key.
      def condition_reference(rule, field_configs)
        name = rule.to_s
        exact = field_configs.find { |c| c.reader_as.to_s == name }
        return exact if exact
        return nil unless name.end_with?("?")

        base = name.delete_suffix("?")
        field_configs.find { |c| c.reader_as.to_s == base && c.boolean? }
      end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/axn/reflection/schema_spec.rb`
Expected: PASS (all, including pre-existing — no existing schema spec emits `allOf` at the top level, so no collisions).

- [ ] **Step 5: Commit**

```bash
git add lib/axn/reflection/schema.rb spec/axn/reflection/schema_spec.rb
git commit -m "PRO-2881: Emit exact allOf/if/then for Symbol conditions referencing declared fields

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: Companion change — allow `if:` + `unless:` together on messages and callbacks

**Files:**
- Modify: `lib/axn/core/flow/handlers/matcher.rb:71-107` (rework `Matcher`)
- Modify: `lib/axn/core/flow/messages.rb:25` (remove guard)
- Modify: `lib/axn/core/flow/callbacks.rb:46` (remove guard)
- Test: `spec/axn/core/messages_spec.rb:505-530` (flip the raise pins to behavior), `spec/axn/core/hooks_and_callbacks_spec.rb:395-410` (same)

**Interfaces:**
- Consumes/preserves: `Matcher.build(if:, unless:)` and `#call(exception:, action:)`/`#static?` — external API unchanged (`message_descriptor.rb:49,55,60`, `base_descriptor.rb:23,29`, `message_resolver.rb:58,82` all keep working). `Matcher#invert?` is dropped — first grep `invert?` across lib/ and spec/ to confirm no remaining callers (lib/ has none today).

- [ ] **Step 1: Flip the existing raise pins into behavior tests**

In `spec/axn/core/messages_spec.rb` (the examples around lines 505-530 asserting `Axn::UnsupportedArgument` on both `:if` and `:unless`), replace those examples with:

```ruby
      it "accepts if: and unless: together (ANDed: every condition must pass)" do
        action = build_axn do
          expects :flagged, :suppressed, type: :boolean, optional: true
          error "combined message", if: -> { flagged }, unless: -> { suppressed }
          def call
            raise "boom"
          end
        end

        expect(action.call(flagged: true, suppressed: false).error).to eq("combined message")
        expect(action.call(flagged: true, suppressed: true).error).not_to eq("combined message")
        expect(action.call(flagged: false, suppressed: false).error).not_to eq("combined message")
      end
```

Adapt the declaration form to the file's local conventions (it may use `error` with different scaffolding — mirror the surrounding examples; the assertions above are the contract). In `spec/axn/core/hooks_and_callbacks_spec.rb` (the example at ~line 404 asserting "cannot be called with both :if and :unless"), replace with a behavior test on the same callback type:

```ruby
      it "accepts if: and unless: together (ANDed)" do
        calls = []
        action = build_axn do
          expects :flagged, :suppressed, type: :boolean, optional: true
          on_failure(if: -> { flagged }, unless: -> { suppressed }) { calls << :fired }
          def call
            fail! "nope"
          end
        end

        action.call(flagged: true, suppressed: false)
        action.call(flagged: true, suppressed: true)
        action.call(flagged: false, suppressed: false)
        expect(calls).to eq([:fired])
      end
```

(Again: mirror the surrounding examples' scaffolding — the local variable capture may need `@calls`/`let` per the file's style.)

- [ ] **Step 2: Run to verify they fail**

Run: `bundle exec rspec spec/axn/core/messages_spec.rb spec/axn/core/hooks_and_callbacks_spec.rb`
Expected: the new examples FAIL with `Axn::UnsupportedArgument` / `ArgumentError` raised at declaration.

- [ ] **Step 3: Implement**

Replace the `Matcher` class body in `lib/axn/core/flow/handlers/matcher.rb` (keep `SingleRuleMatcher` untouched):

```ruby
        class Matcher
          # if: and unless: may be combined (ANDed): every if: rule must match AND every unless:
          # rule must not — the same combination rule as steps and field declarations. Multi-rule
          # arrays keep their existing semantics (if: [A, B] requires all; unless: [A, B] requires
          # none).
          def initialize(if_rules: [], unless_rules: [])
            @if_rules = Array(if_rules).compact
            @unless_rules = Array(unless_rules).compact
          end

          def call(exception:, action:)
            matches?(exception:, action:)
          rescue StandardError => e
            Axn::Internal::PipingError.swallow("determining if handler applies to exception", action:, exception: e)
          end

          def static? = @if_rules.empty? && @unless_rules.empty?

          # Class method to build matcher from kwargs
          def self.build(if: nil, unless: nil)
            new(
              if_rules: Array(binding.local_variable_get(:if)).compact,
              unless_rules: Array(binding.local_variable_get(:unless)).compact,
            )
          end

          private

          def matches?(exception:, action:)
            @if_rules.all? { |rule| SingleRuleMatcher.new(rule).call(exception:, action:) } &&
              @unless_rules.all? { |rule| SingleRuleMatcher.new(rule, invert: true).call(exception:, action:) }
          end
        end
```

Remove the guard line in `lib/axn/core/flow/messages.rb:25` (`raise Axn::UnsupportedArgument, "calling #{kind} with both :if and :unless" ...`) and in `lib/axn/core/flow/callbacks.rb:46` (`raise ArgumentError, "on_#{event_type} cannot be called with both :if and :unless" ...`). Then grep for stragglers:

Run: `grep -rn "invert" lib/axn spec/ | grep -v single_rule` — fix any remaining `Matcher.new(rules, invert:)` positional construction or `#invert?` caller to the new keyword form (as of planning, `lib/` has none; `fails_on` builds via `if:` kwargs).

- [ ] **Step 4: Run to verify**

Run: `bundle exec rspec spec/axn/core/messages_spec.rb spec/axn/core/hooks_and_callbacks_spec.rb spec/axn/core/fails_on_spec.rb spec/axn/core/flow`
Expected: PASS — including every pre-existing single-condition and array-rule message/callback spec (the rework must not change their behavior).

- [ ] **Step 5: Commit**

```bash
git add lib/axn/core/flow spec/axn/core/messages_spec.rb spec/axn/core/hooks_and_callbacks_spec.rb
git commit -m "PRO-2881: Allow if: + unless: together on messages and callbacks (ANDed)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 8: Direction-audit spec (schema stricter-or-exact, never looser)

**Files:**
- Test: `spec/axn/reflection/conditional_direction_audit_spec.rb` (create)

**Interfaces:**
- Consumes: everything above; no lib changes expected. If an audit case FAILS, that is a real defect in Tasks 4-6 — fix the lib code, don't weaken the case.

- [ ] **Step 1: Write the audit spec**

Create `spec/axn/reflection/conditional_direction_audit_spec.rb`:

```ruby
# frozen_string_literal: true

# The direction invariant from the design doc: for INPUT, the schema may reject inputs the runtime
# accepts (stricter) but must never accept an input the runtime rejects (looser) — outside the two
# documented exceptions. Each case runs a REAL call and checks the schema's verdict by hand
# (required-array membership + the allOf conditional), so schema and runtime are compared on the
# same concrete input.
RSpec.describe "conditional validation direction audit" do
  # Minimal hand-rolled check: does the input schema (top-level required + allOf clauses +
  # property-level nested required) permit omitting the named keys for this payload?
  def schema_accepts_omission?(schema, payload, omitted_key)
    return false if schema[:required].to_a.include?(omitted_key.to_s)

    Array(schema[:allOf]).all? do |clause|
      cond = clause[:if]
      ref_key = cond[:required].first.to_sym
      ref_present_truthy = payload.key?(ref_key) && ![false, nil].include?(payload[ref_key])
      branch = ref_present_truthy ? clause[:then] : clause[:else]
      !branch || !branch[:required].include?(omitted_key.to_s)
    end
  end

  it "top-level Proc gate: schema strictly requires; runtime accepts omission when the gate is closed" do
    action = build_axn do
      expects :flag, type: :boolean
      expects :num, type: Integer, if: -> { flag }
      def call; end
    end
    schema = action.input_schema
    expect(schema_accepts_omission?(schema, { flag: false }, :num)).to be false # stricter
    expect(action.call(flag: false).ok?).to be true                             # runtime relaxes
    expect(action.call(flag: true).ok?).to be false                             # and schema agrees when open
  end

  it "declarative Symbol gate: schema and runtime agree on every quadrant" do
    action = build_axn do
      expects :flag, type: :boolean
      expects :num, type: Integer, if: :flag
      def call; end
    end
    schema = action.input_schema
    expect(schema_accepts_omission?(schema, { flag: false }, :num)).to be true
    expect(action.call(flag: false).ok?).to be true
    expect(schema_accepts_omission?(schema, { flag: true }, :num)).to be false
    expect(action.call(flag: true).ok?).to be false
  end

  it "gated subfield, canonical parent-presence condition: exact agreement" do
    action = build_axn do
      expects :data, optional: true
      expects :user, type: String, on: :data, if: -> { data.present? }
      def call; end
    end
    schema = action.input_schema
    expect(schema_accepts_omission?(schema, {}, :data)).to be true
    expect(action.call.ok?).to be true
    expect(schema[:properties][:data][:required]).to include("user")   # bound when data sent
    expect(action.call(data: { role: "x" }).ok?).to be false
  end

  it "gated subfield, non-parent condition: the documented looser corner, and only that corner" do
    action = build_axn do
      expects :strict, type: :boolean
      expects :data, optional: true
      expects :user, type: String, on: :data, if: :strict
      def call; end
    end
    schema = action.input_schema
    # The documented divergence: parent omitted + condition true — schema accepts, runtime rejects.
    expect(schema_accepts_omission?(schema, { strict: true }, :data)).to be true
    expect(action.call(strict: true).ok?).to be false
    # Everything else agrees.
    expect(action.call(strict: false).ok?).to be true
    expect(action.call(strict: true, data: { user: "x" }).ok?).to be true
  end
end
```

- [ ] **Step 2: Run and verify**

Run: `bundle exec rspec spec/axn/reflection/conditional_direction_audit_spec.rb`
Expected: PASS. Any failure here is a lib defect from Tasks 4-6 — investigate there.

- [ ] **Step 3: Commit**

```bash
git add spec/axn/reflection/conditional_direction_audit_spec.rb
git commit -m "PRO-2881: Direction audit — schema stricter-or-exact vs runtime across placements

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 9: Docs + CHANGELOG

**Files:**
- Modify: `docs/reference/class.md` (option table ~line 13-21; new section after "How `optional`, `allow_blank` and `allow_nil` work with validators" ~line 169)
- Modify: `docs/usage/writing.md` (messages `if:`/`unless:` narrative — grep `unless` in that file and update any "cannot combine" claim; add a combined example)
- Modify: `CHANGELOG.md` (Unreleased section, top)

**Interfaces:** none (prose only). One line per paragraph — no hard wrapping.

- [ ] **Step 1: class.md — option table row**

Add to the shared options table (after the `allow_blank` row):

```markdown
| `if` / `unless` | `expects :coupon, type: String, if: :promo_enabled?` | Conditionally validate: gates **every** check in this declaration (including the implicit presence check) on an action method (Symbol) or Proc. See [Conditional validation](#conditional-validation-if-unless) |
```

- [ ] **Step 2: class.md — new section**

Insert after the "How `optional`, `allow_blank` and `allow_nil` work with validators" subsection:

```markdown
#### Conditional validation (`if:` / `unless:`)

Both `expects` and `exposes` accept ActiveModel's `if:`/`unless:` as declaration-level options. The condition gates **every** validator in the declaration — including the automatically-added presence check — so a field can be *conditionally required*:

```ruby
expects :promo_enabled, type: :boolean
expects :coupon_code, type: String, if: :promo_enabled?
```

When `promo_enabled` is falsey, `coupon_code` is wholly unvalidated (it may be omitted, and a supplied value is not type-checked); when truthy, it is required and must be a String. `unless:` is the negation. Both may be given together and combine with AND — every condition must pass for validation to run. This also composes with subfields, making "required only when the parent is supplied" expressible:

```ruby
expects :data, optional: true
expects :user, type: String, on: :data, if: -> { data.present? }
```

To gate a *single* check instead of the whole declaration, nest the condition in that validator's own options — no duplicate declaration needed:

```ruby
expects :num, type: Integer, numericality: { greater_than: 100, if: :big_num_needed? }
```

Rules and caveats:

- **Conditions gate validation only.** `default:` and `preprocess:` are pipeline stages, not validations — they still apply when the condition is false. Readers and `sensitive:` filtering are likewise ungated.
- **Condition forms**: a Symbol names an action method or reader (a boolean field's generated `?` predicate works: `if: :promo_enabled?`); a Proc should be zero-arity and call reader methods (`if: -> { data.present? }`). Inside a Proc, method calls resolve to the action, but `self` is a validation-internal object — instance variables will not resolve; use readers.
- **Conditions must be cheap and side-effect-free**: a declaration-level condition may be evaluated once *per validator* on the field during a single validation pass.
- Combining a tolerance flag (`optional:`/`allow_nil:`/`allow_blank:`) with an explicit `presence:` raises at declaration — the tolerance would make the presence check unable to fire.
- Shape-block members (`field :x` inside `do … end`) support `if:`/`unless:` too, with the same action-scoped semantics — the condition resolves against the action, **not** the element being validated (a condition cannot reference sibling members). This also means Symbol validator arguments (e.g. `inclusion: { in: :allowed_statuses }`) now resolve on members.

::: warning Schema reflection advertises the maximal contract
`input_schema` never executes conditions. It reflects every conditional field **as if every gate were open** — `if:` treated as true, `unless:` treated as false, every declared validator counted — so the schema may be *stricter* than the runtime (it can tell a caller a field is required when a closed gate would have accepted omission), but never looser. Two refinements: a Symbol condition referencing a declared sibling field (like `if: :promo_enabled?` above) is emitted *exactly*, as a JSON Schema `allOf`/`if`/`then` conditional instead of an unconditional requirement; and a gated required subfield keeps its nested `required` without forcing its ancestors, so the parent's own declared optionality is honored. On `output_schema`, a gated exposed field admits `null` (a closed gate can emit nil).
:::
```

- [ ] **Step 3: writing.md + steps alignment**

Run: `grep -n "unless" docs/usage/writing.md docs/usage/steps.md`. In `writing.md`'s message-conditionals narrative, update any statement that `if:` and `unless:` cannot be combined; add one sentence: combined conditions are ANDed (every condition must pass), consistently across messages, callbacks, steps, and field declarations. Add a cross-link from the messages `if:`/`unless:` narrative to the new class.md section to distinguish message-conditionals from validation-conditionals.

- [ ] **Step 4: CHANGELOG**

Add at the top of the Unreleased section:

```markdown
* [FEAT] Conditional validation: `expects`/`exposes` accept declaration-level `if:`/`unless:` (PRO-2881). The condition (a Symbol naming an action method/reader — a boolean field's `?` predicate works — or a zero-arity Proc) gates every validator in the declaration, including the implicit presence check, so requiredness itself can be conditional; per-validator conditions (nested in a validator's options hash) gate a single check. This makes the conditionally-required-subfield pattern expressible: `expects :data, optional: true` + `expects :user, on: :data, if: -> { data.present? }` now declares (the dead-tolerance rejection treats a gated subfield as relaxable, and its message points at the spelling). Tolerance-flag interplay is fixed: `optional:`/`allow_nil:`/`allow_blank:` + a declaration-level condition now works (previously a bare `TypeError` at declaration), while a tolerance flag + explicit truthy `presence:` now raises a clear `ArgumentError` (the tolerance made the presence check unable to fire — previously a crash for `presence: true` and a silently-dead check for `presence: { if: }`). Shape-block members support conditions too (action-scoped, never element-scoped): ShapeValidator now threads the action into member validation, which also fixes Symbol validator arguments (`inclusion: { in: :action_method }`) on members — previously a `NoMethodError`. The member `method_call:` dispatch gate (PRO-2907) is unaffected: permission stays the member's own opt-in, never inferred from the action. `input_schema` reflects conditionals static-maximally (gates treated as open; stricter than runtime, never looser), with two refinements: a Symbol condition referencing a declared sibling field emits an exact `allOf`/`if`/`then` conditional, and a gated required subfield keeps its nested `required` without forcing its ancestors. `output_schema` admits `null` on gated exposed fields. `default:`/`preprocess:` are pipeline stages and apply regardless of the condition.
* [FEAT] `error`/`success`/`fails_on` and the `on_*` callbacks now accept `if:` and `unless:` together (PRO-2881), combined with AND (every condition must pass) — matching steps and field declarations. Previously the combination raised at declaration; single-condition and array-rule behavior is unchanged.
```

- [ ] **Step 5: Verify docs build (if VitePress is set up locally) or at minimum markdown-lint by eye, then commit**

```bash
git add docs/reference/class.md docs/usage/writing.md CHANGELOG.md
git commit -m "PRO-2881: Docs + CHANGELOG for conditional validation

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 10: Full verification

**Files:** none (verification only).

- [ ] **Step 1: Full gem suite**

Run: `bundle exec rspec`
Expected: 0 failures.

- [ ] **Step 2: Rubocop**

Run: `bundle exec rubocop`
Expected: no offenses (use `bundle exec rubocop -a` for autocorrectable style nits; re-run tests after).

- [ ] **Step 3: Rails dummy-app suite**

Run: `cd spec_rails/dummy_app && bundle exec rspec && cd ../..`
Expected: 0 failures (the dummy app contains the real-world optional-parent contract that motivated this ticket — confirm nothing there regresses).

- [ ] **Step 4: End-to-end sanity probe**

Re-run the design-phase probe expectations manually — one anonymous action exercising: bare `if:` conditional requiredness, `optional: + if:`, the gated-subfield pattern, and `input_schema`/`output_schema` output for each. Compare against the spec's examples; any mismatch is a defect.

- [ ] **Step 5: Commit any stragglers, then hand off for PR**

PR description must link the Linear ticket (https://linear.app/teamshares/issue/PRO-2881/...) and the spec/plan docs; no CI-covered checklist items in the test plan.
