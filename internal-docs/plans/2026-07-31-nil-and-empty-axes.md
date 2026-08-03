# Nil and Empty Axes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the emptiness axis its own name (`allow_empty:`), so all four nil/empty contracts are declarable, one requiredness question is asked everywhere, and a collection field's non-emptiness finally reaches the reflected schema.

**Architecture:** `allow_empty:` is a declaration-level kwarg threaded alongside `allow_blank:`/`allow_nil:`/`optional:` through the five existing signatures, resolved in `_parse_field_validations`. `true` suppresses the auto-injected `presence: true` and pushes no tolerance, leaving `TypeValidator` to reject `nil`; `false` under a nil-tolerance injects a nil-tolerant `length: { minimum: 1 }` check. The nil-tolerance predicate that reflection already uses moves to `Axn::Validation::Base` so `FieldOptionality#optional?` stops keeping a second, wrong answer, and `build_property` gains size-constraint emission.

**Tech Stack:** Ruby, RSpec, RuboCop, ActiveModel validations. No new dependencies, no new `lib/` files.

**Ticket:** [PRO-3016](https://linear.app/teamshares/issue/PRO-3016/axn-separate-the-nil-and-empty-axes-allow-empty-requiredness-parity)
**Spec:** `internal-docs/specs/2026-07-31-nil-and-empty-axes-design.md`

## Global Constraints

- **`allow_empty:` is tri-state.** Its default is `nil` (unspecified), NOT `false` — `false` is a meaningful author request (assert non-emptiness) and must be distinguishable from silence. Same tri-state pattern as `coerce_input_types`' per-field override.
- **The default contract does not change.** Bare `type: Array` keeps rejecting `[]` and `nil`; no existing declaration starts accepting or rejecting a value it did not before. Three deliberate exceptions, and nothing beyond them: Task 3 makes a previously-raising *declaration* legal, Task 5 reduces a nil's error message from N clauses to one, and Task 6 adds a key to *reflected schema output* (which is not the runtime contract — it is the fix for schema disagreeing with a runtime that itself stays put).
- **Emptiness is `empty?`, not `blank?`.** `" "` is not empty. Never implement the emptiness axis with `presence`/`blank?`; the probe showed `presence: { allow_nil: true }` lands back on non-nil-non-empty and `presence` rejects whitespace-only strings.
- **Do not reference `Set` unguarded.** axn runs outside Rails and `Set` may not be loaded; `schema.rb:1365` uses `defined?(Set)` for exactly this. The empty-able check in Task 1 avoids the constant entirely via `public_method_defined?(:empty?)` — do not replace it with a class allowlist.
- Comments describe current behavior and intrinsic why. No "used to X / now Y", no ticket numbers, no review references.
- No manual line breaks in Markdown prose — one line per paragraph.
- Never assert `Hash#inspect` text in a spec: Ruby 3.4 changed its spacing and CI runs 3.2/3.3/3.4.
- Run `bundle exec rubocop` before each commit. Relevant maxima: `Layout/LineLength` 160, `Metrics/MethodLength` 70, `Metrics/AbcSize` 60, `Metrics/ClassLength` 250. Multiline argument lists require a trailing comma; `Style/HashSyntax` requires shorthand for symbol keys.
- Full suite: `bundle exec rspec`. The Rails dummy app is a separate bundle, run from the repo root via `rake spec_rails`. Run it in Tasks 4 and 6 (both touch predicates the dummy app's reflection specs exercise).
- CHANGELOG edits go under the existing `## 0.1.0-alpha.5` section, in `### Validation, coercion & schema`. Do **not** open an `## Unreleased`. If a newer `##` version section exists at the top when you run this, use that one instead.
- `_parse_field_validations` already carries `# rubocop:disable Metrics/ParameterLists` on its enclosing methods; keep those comments intact when adding a kwarg.

## File Structure

| File | Responsibility | Change |
| --- | --- | --- |
| `lib/axn/core/contract.rb` | The declaration DSL: kwarg signatures, presence injection, tolerance push-down, shape members, `FieldOptionality` | Modify: `expects` (L137), `exposes` (L207), `_parse_field_configs` (L847), `_parse_field_validations` (L1082), `SHAPE_MEMBER_FIELD_OPTIONS` (L710), `FieldOptionality#optional?` (L44) |
| `lib/axn/core/contract_for_subfields.rb` | Subfield declaration path | Modify: `_expects_subfields` (L455), `_parse_subfield_configs` (L549) — thread the kwarg only |
| `lib/axn/core/validation/base.rb` | Single definitions shared by the validator builder and reflection | Modify: add `nil_accepted?` / `nil_tolerant_validation?` / `set_includes_nil?` |
| `lib/axn/reflection/schema.rb` | Schema derivation | Modify: delegate the nil predicates to `Validation::Base`, add size-constraint emission in `build_property` (L918), correct the stale comment at L14-15 |
| `spec/axn/core/validations/nil_empty_axes_matrix_spec.rb` | Table-driven coverage of all four cells × four container types × three declaration sites | **Create** |
| `spec/axn/core/schema_reflection_spec.rb` | Schema reflection | Modify: add size-constraint and `optional?`-agreement coverage |
| `docs/reference/class.md` | User-facing reference | Modify: four-cell table near the tolerance discussion (L181, L210) |
| `AGENTS-consuming.md` | Consumer cheat-sheet | Modify: tolerance table at L64 |
| `CHANGELOG.md` | Release notes | Modify: entries under `### Validation, coercion & schema` |

---

### Task 1: `allow_empty: true` and its declaration guard

The whole flag's plumbing plus the cell the ticket was filed about. `allow_empty: true` means "required, non-nil, may be empty": skip the auto-injected `presence: true`, push no tolerance, and let `TypeValidator` reject `nil` on its own.

**Files:**
- Modify: `lib/axn/core/contract.rb` (L137 `expects`, L207 `exposes`, L847 `_parse_field_configs`, L1082 `_parse_field_validations`)
- Modify: `lib/axn/core/contract_for_subfields.rb` (L455, L549)
- Create: `spec/axn/core/validations/nil_empty_axes_matrix_spec.rb`

**Interfaces:**
- Produces: `allow_empty:` accepted by `expects` / `exposes` / `expects … on:`, tri-state (`nil` unspecified, `true`, `false`). Task 3 implements `false`; this task accepts it and treats it as unspecified.
- Produces: `Axn::Core::Contract::ClassMethods#_emptiable_type?(klass) → Boolean` and `EMPTIABLE_PSEUDO_TYPES`, consumed by Task 3's guard reuse and Task 6's emission decision.

- [ ] **Step 1: Write the failing test**

Create `spec/axn/core/validations/nil_empty_axes_matrix_spec.rb`:

```ruby
# frozen_string_literal: true

require "set"

RSpec.describe "nil and empty axes" do
  # Each container type paired with an empty and a non-empty instance of itself.
  CONTAINERS = {
    Array => { empty: [], filled: [1] },
    Hash => { empty: {}, filled: { a: 1 } },
    String => { empty: "", filled: "x" },
    Set => { empty: Set.new, filled: Set["x"] },
  }.freeze

  def build(**opts)
    Class.new do
      include Axn
      expects :v, **opts
      def call = nil
    end
  end

  describe "allow_empty: true — required, non-nil, may be empty" do
    CONTAINERS.each do |klass, values|
      context "with type: #{klass}" do
        subject(:action) { build(type: klass, allow_empty: true) }

        it "rejects nil" do
          result = action.call(v: nil)
          expect(result).not_to be_ok
          expect(result.exception.message).to include("is not a #{klass}")
        end

        it "accepts an empty #{klass}" do
          expect(action.call(v: values[:empty])).to be_ok
        end

        it "accepts a non-empty #{klass}" do
          expect(action.call(v: values[:filled])).to be_ok
        end

        it "rejects an omitted key" do
          expect(action.call).not_to be_ok
        end
      end
    end

    it "keeps of: element checks working alongside it" do
      action = build(type: Array, of: Integer, allow_empty: true)
      expect(action.call(v: [])).to be_ok
      expect(action.call(v: ["1"])).not_to be_ok
    end

    it "does not tolerate a wrong-typed blank" do
      expect(build(type: Hash, allow_empty: true).call(v: "")).not_to be_ok
    end
  end

  describe "the declaration guard" do
    it "rejects a type whose instances cannot be empty" do
      expect { build(type: Integer, allow_empty: true) }
        .to raise_error(ArgumentError, /allow_empty:.*Integer.*cannot be empty/)
    end

    it "rejects :boolean" do
      expect { build(type: :boolean, allow_empty: true) }.to raise_error(ArgumentError, /allow_empty:/)
    end

    it "rejects a declaration with no type at all" do
      expect { build(allow_empty: true) }
        .to raise_error(ArgumentError, /allow_empty:.*requires a `type:`/)
    end

    it "accepts :params" do
      expect { build(type: :params, allow_empty: true) }.not_to raise_error
    end
  end

  describe "parity across declaration sites" do
    it "works on exposes" do
      klass = Class.new do
        include Axn
        exposes :out, type: Array, allow_empty: true
        def call = expose(:out, [])
      end
      expect(klass.call).to be_ok
    end

    it "works on a subfield" do
      klass = Class.new do
        include Axn
        expects :payload, type: Hash
        expects :list, on: :payload, type: Array, allow_empty: true
        def call = nil
      end
      expect(klass.call(payload: { list: [] })).to be_ok
      expect(klass.call(payload: { list: nil })).not_to be_ok
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bundle exec rspec spec/axn/core/validations/nil_empty_axes_matrix_spec.rb`
Expected: FAIL — `ArgumentError: Unknown key(s) :allow_empty in field declaration`, because `expects` forwards unrecognized keys to `_partition_field_options`.

- [ ] **Step 3: Thread the kwarg through the five signatures**

In `lib/axn/core/contract.rb`, add `allow_empty: nil` beside `allow_nil:` in `expects` (after L141) and `exposes` (after L210), and forward it at all three call sites in those methods (L188-189, L192-193, L236). Add it to `_parse_field_configs` (after L851) and forward to `_parse_field_validations` at L870:

```ruby
_parse_field_validations(*fields, allow_nil:, allow_blank:, allow_empty:, **validations).map do |field, parsed_validations|
```

In `lib/axn/core/contract_for_subfields.rb`, add `allow_empty: nil` to `_expects_subfields` (after L459) and `_parse_subfield_configs` (after L553), forwarding through both `_parse_subfield_configs` (L500) and `_parse_field_configs` (L566) calls.

- [ ] **Step 4: Implement the guard and the presence-injection change**

In `contract.rb`, above `_parse_field_validations`:

```ruby
        # Pseudo-types (Symbol type names) whose values can be empty. `:params` is Hash-backed; `:boolean`
        # and `:uuid` have no empty state.
        EMPTIABLE_PSEUDO_TYPES = %i[params].freeze

        # Whether a declared type has an empty state for `allow_empty:` to talk about. Asked of the class
        # rather than an allowlist: `public_method_defined?` is the same reflective test schema.rb uses for
        # capability questions, it covers a custom container with its own `empty?`, and it avoids naming
        # `Set`, which may not be loaded outside Rails.
        def _emptiable_type?(klass)
          return EMPTIABLE_PSEUDO_TYPES.include?(klass) if klass.is_a?(Symbol)

          klass.is_a?(Class) && klass.public_method_defined?(:empty?)
        end

        # `allow_empty:` permits (or forbids) an empty value of a declared type. With no `type:` there is
        # nothing to reject a nil, so the flag would silently widen the field to accept anything; on a type
        # with no empty state there is nothing to permit. Both are declaration errors rather than silently
        # inert options.
        def _validate_allow_empty!(fields, validations)
          klasses = Array(validations.dig(:type, :klass))
          where = fields.map(&:to_s).inspect

          if klasses.empty?
            raise ArgumentError,
                  "allow_empty: requires a `type:` on #{where} — without one nothing rejects a nil, so the " \
                  "flag would widen the field to accept any value. Declare the container type (e.g. `type: Array`)."
          end

          offending = klasses.reject { |k| _emptiable_type?(k) }
          return if offending.empty?

          raise ArgumentError,
                "allow_empty: is not supported for #{offending.map(&:inspect).join('/')} on #{where} — those " \
                "values cannot be empty, so there is no empty state to permit or forbid. Drop allow_empty:."
        end
```

Then in `_parse_field_validations`, add `allow_empty: nil` to the signature (after L1085's `allow_blank: false`), call the guard once the type sugar is canonical — immediately after the `_derive_raw_shape_container!(validations)` line at L1112 — and gate the presence injection in the `else` branch:

```ruby
          _validate_allow_empty!(fields, validations) unless allow_empty.nil?
```

```ruby
          else
            # Apply default presence validation (unless the type is boolean or params, or the field opted
            # into emptiness — an empty value is exactly what the presence check would reject, while the
            # type check still rejects nil).
            type_values = Array(validations.dig(:type, :klass))
            unless allow_empty || validations.key?(:presence) || type_values.include?(:boolean) || type_values.include?(:params)
              validations[:presence] = true
            end
          end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bundle exec rspec spec/axn/core/validations/nil_empty_axes_matrix_spec.rb`
Expected: PASS.

- [ ] **Step 6: Run the full suite and RuboCop**

Run: `bundle exec rspec && bundle exec rubocop`
Expected: PASS with no new failures. Nothing existing declares `allow_empty:`, and the `else` branch only changes behavior when the flag is set.

- [ ] **Step 7: Commit**

```bash
git add lib/axn/core/contract.rb lib/axn/core/contract_for_subfields.rb spec/axn/core/validations/nil_empty_axes_matrix_spec.rb
git commit -m "feat: allow_empty: declares a required, non-nil, possibly-empty field"
```

---

### Task 2: shape-member parity

A shape member reuses the top-level option handling but only for the options named in `SHAPE_MEMBER_FIELD_OPTIONS` — anything else routes into `_partition_field_options` and raises as an unknown validation key. The downstream fields that motivated this ticket are shape members, so without this the flag is unreachable where it is most needed.

**Files:**
- Modify: `lib/axn/core/contract.rb:710`
- Modify: `spec/axn/core/validations/nil_empty_axes_matrix_spec.rb`

**Interfaces:**
- Consumes: `allow_empty:` from Task 1.
- Produces: `allow_empty:` usable inside an `expects … do … field … end` block, on inbound and outbound shapes alike.

- [ ] **Step 1: Write the failing test**

Append to `spec/axn/core/validations/nil_empty_axes_matrix_spec.rb`, inside the `"parity across declaration sites"` describe block:

```ruby
    it "works on a shape member" do
      klass = Class.new do
        include Axn
        expects :snapshot, type: Hash do
          field :history, type: Hash, allow_empty: true
          field :months, type: Array, of: Integer, allow_empty: true
        end
        def call = nil
      end

      expect(klass.call(snapshot: { history: {}, months: [] })).to be_ok
      expect(klass.call(snapshot: { history: nil, months: [] })).not_to be_ok
      expect(klass.call(snapshot: { history: {}, months: nil })).not_to be_ok
    end

    it "names the offending member when a nested collection is nil" do
      klass = Class.new do
        include Axn
        expects :snapshot, type: Hash do
          field :history, type: Hash, allow_empty: true
        end
        def call = nil
      end

      result = klass.call(snapshot: { history: nil })
      expect(result.exception.message).to include("history")
    end

    it "guards a non-empty-able member type at declaration" do
      expect do
        Class.new do
          include Axn
          expects :snapshot, type: Hash do
            field :count, type: Integer, allow_empty: true
          end
          def call = nil
        end
      end.to raise_error(ArgumentError, /allow_empty:/)
    end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bundle exec rspec spec/axn/core/validations/nil_empty_axes_matrix_spec.rb -e "works on a shape member"`
Expected: FAIL — `ArgumentError: Unknown key(s) :allow_empty in field declaration`, raised from `_partition_field_options` via `_build_shape_member`.

- [ ] **Step 3: Add the option to the shape-member allowlist**

In `lib/axn/core/contract.rb:710`:

```ruby
        SHAPE_MEMBER_FIELD_OPTIONS = %i[allow_blank allow_nil allow_empty optional method_call sensitive user_facing].freeze
```

No other change: `_build_shape_member` slices these into `field_opts` (L781) and splats them into `_parse_field_configs` (L786), which Task 1 taught to accept the kwarg.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bundle exec rspec spec/axn/core/validations/nil_empty_axes_matrix_spec.rb`
Expected: PASS.

- [ ] **Step 5: Run the full suite and RuboCop**

Run: `bundle exec rspec && bundle exec rubocop`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/axn/core/contract.rb spec/axn/core/validations/nil_empty_axes_matrix_spec.rb
git commit -m "feat: allow_empty: on shape members"
```

---

### Task 3: `allow_empty: false` — the mirror cell

"May be nil, but if supplied must be non-empty." Today this needs `allow_nil: true, length: { minimum: 1 }`, and its natural Rails spelling (`presence: true, allow_nil: true`) raises. The injected check must be size-based, and must carry explicit tolerance keys that survive the push-down: the loop at L1148 merges `{ allow_blank:, allow_nil: }` *under* each validator's own normalized options, so a validator declaring `allow_blank: false` keeps it and stays able to fire on `[]`.

**Files:**
- Modify: `lib/axn/core/contract.rb` (`_parse_field_validations` tolerance branch, L1115-1125)
- Modify: `spec/axn/core/validations/nil_empty_axes_matrix_spec.rb`

**Interfaces:**
- Consumes: `allow_empty:` and `_validate_allow_empty!` from Task 1.
- Produces: `optional: true, allow_empty: false` (and the `allow_blank:`/`allow_nil:` spellings) accepting `nil` while rejecting an empty value, with the message `can't be empty`.

- [ ] **Step 1: Write the failing test**

Append a new describe block to `spec/axn/core/validations/nil_empty_axes_matrix_spec.rb`:

```ruby
  describe "allow_empty: false — may be nil, must be non-empty" do
    CONTAINERS.each do |klass, values|
      context "with type: #{klass}" do
        subject(:action) { build(type: klass, optional: true, allow_empty: false) }

        it "accepts nil" do
          expect(action.call(v: nil)).to be_ok
        end

        it "accepts an omitted key" do
          expect(action.call).to be_ok
        end

        it "rejects an empty #{klass}" do
          result = action.call(v: values[:empty])
          expect(result).not_to be_ok
          expect(result.exception.message).to include("can't be empty")
        end

        it "accepts a non-empty #{klass}" do
          expect(action.call(v: values[:filled])).to be_ok
        end
      end
    end

    it "treats a whitespace-only String as non-empty" do
      action = build(type: String, optional: true, allow_empty: false)
      expect(action.call(v: " ")).to be_ok
    end

    it "is a no-op restatement of the default when no nil-tolerance is declared" do
      action = build(type: Array, allow_empty: false)
      expect(action.call(v: nil)).not_to be_ok
      expect(action.call(v: [])).not_to be_ok
      expect(action.call(v: [1])).to be_ok
    end

    it "defers to an author-declared length minimum" do
      action = build(type: Array, optional: true, allow_empty: false, length: { minimum: 2 })
      expect(action.call(v: nil)).to be_ok
      expect(action.call(v: [1])).not_to be_ok
      expect(action.call(v: [1, 2])).to be_ok
    end

    it "points a dead presence:/tolerance combination at the working spelling" do
      expect { build(type: Array, presence: true, allow_nil: true) }
        .to raise_error(ArgumentError, /allow_empty: false/)
    end
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bundle exec rspec spec/axn/core/validations/nil_empty_axes_matrix_spec.rb -e "allow_empty: false"`
Expected: FAIL — empty values pass, because `allow_empty: false` is currently treated as unspecified and the tolerance flag suppresses every check.

- [ ] **Step 3: Inject the nil-tolerant non-emptiness check**

In `_parse_field_validations`, inside the `if allow_blank || allow_nil` branch, after the explicit-`presence:` rejection (L1125) and before the shared-option slicing:

```ruby
            # An explicit `allow_empty: false` under a nil-tolerance is the one contract the tolerance flags
            # cannot express: nil is fine, an empty value is not. Assert it with a size check rather than
            # `presence:` — `presence` is `!blank?`, which would also reject a whitespace-only String that is
            # not empty, and a presence check under a pushed-down tolerance can never fire. The explicit
            # tolerance keys survive the push-down below (each validator's own options are merged OVER the
            # pushed pair), so this stays able to fire on an empty value while skipping nil. An author-declared
            # `length:` already forbids empty, so it is left alone rather than overwritten.
            if allow_empty == false && !validations.key?(:length)
              validations[:length] = { minimum: 1, message: "can't be empty", allow_nil: true, allow_blank: false }
            end
```

- [ ] **Step 4: Redirect the dead-combination message**

The `presence:`-plus-tolerance combination at L1119-1125 stays a declaration error — under a pushed-down tolerance the presence check genuinely cannot fire — but its message now names the spelling that works. Replace the message:

```ruby
              raise ArgumentError,
                    "optional:/allow_blank:/allow_nil: cannot be combined with an explicit `presence:` — " \
                    "the tolerance is pushed into every validator, so the presence check could never fail. " \
                    "For \"may be nil, but not empty\", declare `allow_empty: false` alongside the tolerance; " \
                    "otherwise declare one requiredness signal (drop the flag, or drop presence:)."
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bundle exec rspec spec/axn/core/validations/nil_empty_axes_matrix_spec.rb`
Expected: PASS.

- [ ] **Step 6: Run the full suite and RuboCop**

Run: `bundle exec rspec && bundle exec rubocop`
Expected: PASS. One existing spec may assert the old message text for the presence/tolerance rejection — search with `grep -rn "could never fail" spec/` and update the expectation to match the new wording rather than weakening the assertion.

- [ ] **Step 7: Commit**

```bash
git add lib/axn/core/contract.rb spec/axn/core/validations/nil_empty_axes_matrix_spec.rb
git commit -m "feat: allow_empty: false expresses may-be-nil-but-not-empty"
```

---

### Task 4: one requiredness question

`FieldOptionality#optional?` asks "is there a `presence: true`?" and answers `true` for a field the schema emits as `required` and non-nullable. The schema layer asks the question that matters — "do this field's real validators accept nil?" — so that predicate moves to `Axn::Validation::Base`, which already hosts `validator_entries` as the single definition of "is this a validator", and both layers call it.

**Files:**
- Modify: `lib/axn/core/validation/base.rb`
- Modify: `lib/axn/reflection/schema.rb` (delete the three moved methods, delegate)
- Modify: `lib/axn/core/contract.rb:38-48`
- Modify: `spec/axn/core/schema_reflection_spec.rb`

**Interfaces:**
- Produces: `Axn::Validation::Base.nil_accepted?(validations) → Boolean`, `Axn::Validation::Base.nil_tolerant_validation?(key, opt) → Boolean`, `Axn::Validation::Base.set_includes_nil?(opt) → true/false/nil`. Task 6 consumes `nil_accepted?`.
- Changes: `FieldConfig#optional?` / `ShapeConfig#optional?` return `false` for a field whose validators reject nil (`allow_empty: true`, `presence: false`).

- [ ] **Step 1: Write the failing test**

Add to `spec/axn/core/schema_reflection_spec.rb`:

```ruby
  describe "optional? agrees with input_schema requiredness" do
    [
      { type: Array },
      { type: Array, allow_empty: true },
      { type: Array, optional: true },
      { type: Array, allow_nil: true },
      { type: Array, presence: false },
      { type: Array, optional: true, allow_empty: false },
      { type: String, allow_empty: true },
    ].each do |opts|
      it "agrees for #{opts.inspect}" do
        klass = Class.new do
          include Axn
          def call = nil
        end
        klass.expects :v, **opts

        config = klass.internal_field_configs.find { _1.field == :v }
        schema_requires = Array(klass.input_schema[:required]).include?("v")

        expect(config.optional?).to eq(!schema_requires)
      end
    end
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bundle exec rspec spec/axn/core/schema_reflection_spec.rb -e "optional? agrees"`
Expected: FAIL for `allow_empty: true` and `presence: false` — `optional?` returns `true` while the schema lists the field as required.

- [ ] **Step 3: Move the nil predicates into `Validation::Base`**

Cut `nil_accepted?` (`schema.rb:1240-1250`), `nil_tolerant_validation?` (L1342-1351) and `set_includes_nil?` (L1359-1370) verbatim — including their comments and the `rubocop:disable Style/ReturnNilInPredicateMethodDefinition` pair — into `lib/axn/core/validation/base.rb` as `def self.` methods beside `validator_entries`, and change `nil_accepted?`'s body to call the module's own `validator_entries` directly:

```ruby
      # Whether every real validator on this field accepts nil — the question requiredness and nullability
      # both turn on, asked identically by schema reflection and by a field config's own `optional?` so the
      # two can never disagree about the same declaration.
      def self.nil_accepted?(validations)
        v = validator_entries(validations)
        return true if v.empty?

        v.all? { |key, opt| nil_tolerant_validation?(key, opt) }
      end
```

In `schema.rb`, replace the three deleted definitions with delegations so every existing call site is untouched:

```ruby
      def nil_accepted?(config) = Axn::Validation::Base.nil_accepted?(config.validations)
      def nil_tolerant_validation?(key, opt) = Axn::Validation::Base.nil_tolerant_validation?(key, opt)
      def set_includes_nil?(opt) = Axn::Validation::Base.set_includes_nil?(opt)
```

- [ ] **Step 4: Rewrite `optional?` to ask the shared question**

In `lib/axn/core/contract.rb`, replace `FieldOptionality#optional?` (L41-48) and update the module comment above it:

```ruby
      # Optionality is shared by FieldConfig and ShapeConfig, and is the same question schema reflection
      # asks when deciding requiredness: a field is optional exactly when its validators accept nil. Keyed
      # on the validators rather than on the presence of a `presence: true` entry, so a field that rejects
      # nil by type alone (`allow_empty: true`, `presence: false`) reads as required here and in the schema.
      module FieldOptionality
        def optional?
          Axn::Validation::Base.nil_accepted?(validations)
        end
      end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bundle exec rspec spec/axn/core/schema_reflection_spec.rb`
Expected: PASS.

- [ ] **Step 6: Run the full suite, the Rails app, and RuboCop**

Run: `bundle exec rspec && rake spec_rails && bundle exec rubocop`
Expected: PASS. `default_call.rb:18` reads this predicate to decide whether a missing exposure method is tolerable, so watch `spec/axn/core/validations/outbound_validation_spec.rb` and the auto-exposure specs. A genuine behavior change here is confined to fields that reject nil without a `presence: true` entry — previously misreported as optional.

- [ ] **Step 7: Commit**

```bash
git add lib/axn/core/validation/base.rb lib/axn/reflection/schema.rb lib/axn/core/contract.rb spec/axn/core/schema_reflection_spec.rb
git commit -m "fix: optional? and schema requiredness ask one question"
```

---

### Task 5: one error per nil

A field that rejects nil by type currently also runs every other validator against that nil, so a `validate:` lambda written for a real value crashes and contributes a second, derivative message. One value has one defect.

**Files:**
- Modify: `lib/axn/core/contract.rb` (`_parse_field_validations`)
- Modify: `spec/axn/core/validations/nil_empty_axes_matrix_spec.rb`

**Interfaces:**
- Consumes: nothing from earlier tasks. It keys only on "does this field's `type:` reject nil", so it stands alone and applies to every typed field, flag or no flag.
- Produces: `_type_rejects_nil?(validations) → Boolean`.

- [ ] **Step 1: Write the failing test**

Append to `spec/axn/core/validations/nil_empty_axes_matrix_spec.rb`:

```ruby
  describe "a nil rejected by type produces exactly one error" do
    let(:action) do
      build(type: Hash, allow_empty: true, validate: ->(h) { "values must be Integer" unless h.values.all?(Integer) })
    end

    it "reports the type error and not a crashed custom validator" do
      message = action.call(v: nil).exception.message

      expect(message).to include("is not a Hash")
      expect(message).not_to include("failed validation")
      expect(message).not_to include("undefined method")
    end

    it "still runs the custom validator for a non-nil value" do
      expect(action.call(v: { a: 1 })).to be_ok
      expect(action.call(v: { a: "x" }).exception.message).to include("values must be Integer")
    end

    it "still reports both when two independent validators reject the same non-nil value" do
      klass = build(type: Array, of: Integer, allow_empty: true, validate: ->(_a) { "always fails" })
      message = klass.call(v: ["x"]).exception.message

      expect(message).to include("element at index 0 is not a Integer")
      expect(message).to include("always fails")
    end
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bundle exec rspec spec/axn/core/validations/nil_empty_axes_matrix_spec.rb -e "exactly one error"`
Expected: FAIL — the message contains both `is not a Hash` and `failed validation: undefined method 'values' for nil`.

- [ ] **Step 3: Push a nil-skip into the non-type validators**

In `_parse_field_validations`, after the `else` branch that injects the default presence (Task 1's edit) and before `fields.map`:

```ruby
          # A field whose `type:` rejects nil has already reported that nil completely; running the other
          # validators against it only adds derivative messages (a custom `validate:` written for a real value
          # raises, and its crash is surfaced as a second failure on the same field). Give every non-type
          # validator nil-tolerance so the type error stands alone. Only the type validator's own nil verdict
          # is authoritative, so it is left untouched, as are validators that already carry explicit tolerance.
          if _type_rejects_nil?(validations)
            # Iterate a snapshot of the keys: the loop reassigns entries as it goes, and Ruby forbids
            # mutating a Hash mid-iteration.
            validations.keys.each do |key| # rubocop:disable Style/HashEachMethods
              opt = validations[key]
              next if key == :type || !opt || Axn::Validation::Base.shared_validation_option_keys.include?(key)

              normalized = Axn::Validation::Base.normalize_validator_options(opt)
              next if normalized.key?(:allow_nil) || normalized.key?(:allow_blank)

              validations[key] = normalized.merge(allow_nil: true)
            end
          end
```

And the predicate, beside `_validate_allow_empty!`:

```ruby
        # Whether this field's declared type rules out nil on its own — a declared `type:` with no
        # nil-tolerance pushed into it. TypeValidator skips nil only under allow_nil:/allow_blank:.
        def _type_rejects_nil?(validations)
          type = validations[:type]
          return false unless type.is_a?(Hash) && type[:klass]

          !(type[:allow_nil] || type[:allow_blank])
        end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bundle exec rspec spec/axn/core/validations/nil_empty_axes_matrix_spec.rb`
Expected: PASS.

- [ ] **Step 5: Run the full suite and RuboCop**

Run: `bundle exec rspec && bundle exec rubocop`
Expected: PASS. This changes messages for any *required* typed field given nil too — previously `Arr is not a Array and Arr can't be blank`, now the type error alone. Search `grep -rn "can't be blank" spec/ | grep -i "is not a"` for combined-message expectations and update them; a spec asserting only one of the two clauses still passes.

- [ ] **Step 6: Commit**

```bash
git add lib/axn/core/contract.rb spec/axn/core/validations/nil_empty_axes_matrix_spec.rb
git commit -m "fix: a nil rejected by type reports one error, not N"
```

---

### Task 6: reflect the emptiness axis

`minItems` / `minProperties` / `minLength` are emitted nowhere today, so a bare `expects :ids, type: Array` tells a tool caller `[]` is acceptable and then rejects it — schema looser than runtime, the same class of bug the bare-`inclusion:` CHANGELOG entry describes. Emit the constraint whenever the validator set rejects empty, from any of the three sources.

**Files:**
- Modify: `lib/axn/reflection/schema.rb` (`build_property` L918, plus the stale comment at L14-15)
- Modify: `spec/axn/core/schema_reflection_spec.rb`

**Interfaces:**
- Consumes: `prop[:type]` as written by `apply_type_info!`, and the `presence:` entry as it stands *after* Task 5's nil-skip push (which may rewrite `presence: true` into `{ allow_nil: true }` — hence the emission check consults `allow_blank` only).
- Produces: `minItems` / `minProperties` / `minLength` on input and output properties.

- [ ] **Step 1: Write the failing test**

Add to `spec/axn/core/schema_reflection_spec.rb`:

```ruby
  describe "emptiness constraints" do
    def schema_for(**opts)
      klass = Class.new do
        include Axn
        def call = nil
      end
      klass.expects :v, **opts
      klass.input_schema.dig(:properties, :v)
    end

    it "emits minItems for a required Array" do
      expect(schema_for(type: Array)).to include(type: "array", minItems: 1)
    end

    it "emits minProperties for a required Hash" do
      expect(schema_for(type: Hash)).to include(type: "object", minProperties: 1)
    end

    it "emits minLength for a required String" do
      expect(schema_for(type: String)).to include(type: "string", minLength: 1)
    end

    it "omits the constraint when the field allows empty" do
      expect(schema_for(type: Array, allow_empty: true)).to eq(type: "array")
    end

    it "omits the constraint when the field is optional" do
      expect(schema_for(type: Array, optional: true)).not_to have_key(:minItems)
    end

    it "emits it for the may-be-nil-but-not-empty cell alongside a nullable type" do
      prop = schema_for(type: Array, optional: true, allow_empty: false)
      expect(prop[:type]).to eq(["array", "null"])
      expect(prop[:minItems]).to eq(1)
    end

    it "honors an author-declared length minimum" do
      expect(schema_for(type: Array, length: { minimum: 3 })[:minItems]).to eq(3)
    end

    it "emits nothing for a type with no empty state" do
      expect(schema_for(type: Integer)).not_to have_key(:minLength)
    end
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bundle exec rspec spec/axn/core/schema_reflection_spec.rb -e "emptiness constraints"`
Expected: FAIL — no property carries any `min*` key.

- [ ] **Step 3: Emit the constraint**

In `schema.rb`, call a new helper from `build_property` immediately after `apply_type_info!` (L946):

```ruby
        apply_size_constraints!(prop, config)
```

And define it beside `apply_type_info!`:

```ruby
      # The emptiness axis, as JSON Schema sees it: `minItems`/`minProperties`/`minLength` keyed off the
      # emitted type. A field rejects empty when it carries an explicit length minimum, or when the default
      # presence check applies without blank-tolerance — `presence` is `!blank?`, so it forbids the empty value
      # too. Only `allow_blank` is consulted, never `allow_nil`: nil-tolerance is the other axis and says
      # nothing about whether an empty value is admissible. Emitting this is
      # what keeps a required collection's schema from advertising `[]` as acceptable when the runtime
      # rejects it. For a String under `presence:` the runtime also rejects whitespace-only values, which
      # `minLength` cannot express, so the emitted constraint stays a floor rather than an exact mirror.
      def apply_size_constraints!(prop, config)
        minimum = declared_size_minimum(config)
        return unless minimum

        key = case Array(prop[:type]).find { |t| %w[array object string].include?(t) }
              when "array" then :minItems
              when "object" then :minProperties
              when "string" then :minLength
              end
        return unless key

        prop[key] = minimum
      end

      # The smallest size this field's validators admit, or nil when they admit an empty value. An explicit
      # `length:`/`size:` minimum wins over the presence check's implicit 1 — a caller needs the tighter of
      # the two, and both forbid empty.
      def declared_size_minimum(config)
        validations = config.validations
        explicit = [validations[:length], validations[:size]].compact.filter_map { |opt| opt.is_a?(Hash) ? opt[:minimum] : nil }
        declared = explicit.select { |m| m.is_a?(Integer) && m.positive? }.max
        return declared if declared

        presence = validations[:presence]
        return 1 if presence && !(presence.is_a?(Hash) && presence[:allow_blank])

        nil
      end
```

- [ ] **Step 4: Correct the stale requiredness comment**

`schema.rb:14-15` lists `presence: false` among the signals that make a field omittable. That is true only of the type-less form Task 1 made illegal; a typed `presence: false` field is emitted as required. Replace the parenthetical:

```ruby
    # A field is omittable (absent from `required`) when a declared signal says so — a usable default, or a
    # nil-tolerant validator set (`optional:`/`allow_nil:`/`allow_blank:`). A field that rejects nil by type
    # alone (`allow_empty: true`) stays required and non-nullable: emptiness is permitted, absence is not.
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bundle exec rspec spec/axn/core/schema_reflection_spec.rb`
Expected: PASS.

- [ ] **Step 6: Run the full suite, the Rails app, and RuboCop**

Run: `bundle exec rspec && rake spec_rails && bundle exec rubocop`
Expected: PASS. This is the widest-blast-radius change in the plan: every required-collection and required-String property in every schema assertion gains a key. Existing specs using `eq(...)` on a whole property hash will fail and must be updated to include the new key — that is the change being made, not a regression. Do not weaken an `eq` to an `include` to make it pass; add the expected `min*` key.

- [ ] **Step 7: Commit**

```bash
git add lib/axn/reflection/schema.rb spec/axn/core/schema_reflection_spec.rb
git commit -m "fix: reflect the emptiness axis as minItems/minProperties/minLength"
```

---

### Task 7: docs and CHANGELOG

The four cells are only usable if they are visible together — the reason the flag exists rather than blessing `presence: false` is discoverability.

**Files:**
- Modify: `docs/reference/class.md` (near L181 and L210)
- Modify: `AGENTS-consuming.md` (L64)
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Add the four-cell table to `docs/reference/class.md`**

After the sentence at L181 explaining the automatic presence validation, insert:

```markdown
Requiredness is really two independent questions — may the value be `nil` (or absent), and may it be empty? All four combinations are declarable:

| Declaration | `nil` / absent | empty (`[]`, `{}`, `""`) | non-empty |
| --- | --- | --- | --- |
| `type: Array` | rejected | rejected | accepted |
| `type: Array, allow_empty: true` | rejected | accepted | accepted |
| `type: Array, optional: true` | accepted | accepted | accepted |
| `type: Array, optional: true, allow_empty: false` | accepted | rejected | accepted |

`optional:`, `allow_blank:` and `allow_nil:` are three spellings of the third row. `allow_empty:` is the only option that speaks to emptiness alone, and it requires a `type:` whose values can be empty (`Array`, `Hash`, `Set`, `String`, `:params`) — on any other type there is no empty state to talk about, so it raises at declaration. Emptiness is `empty?`, not `blank?`: a whitespace-only String is not empty, so `type: String, optional: true, allow_empty: false` accepts `" "` and rejects `""`.

A field that rejects empty reflects that into its schema as `minItems` / `minProperties` / `minLength`.
```

- [ ] **Step 2: Add the row to `AGENTS-consuming.md`**

In the option table at L64, after the `optional: true` row:

```markdown
| `allow_empty: true` | Accept an empty collection or string but **not** `nil` — the field stays required. Needs a `type:` with an empty state (`Array`/`Hash`/`Set`/`String`/`:params`); raises otherwise. Pair with a tolerance flag inverted (`optional: true, allow_empty: false`) for "may be omitted, but not empty". |
```

- [ ] **Step 3: Add the CHANGELOG entries**

Under `## 0.1.0-alpha.5` → `### Validation, coercion & schema`:

```markdown
* [FEAT] `allow_empty:` declares the emptiness axis independently of nullability, so all four requiredness contracts are expressible: `allow_empty: true` keeps a field required and non-nil while accepting an empty collection or string (previously reachable only as a side effect of `presence: false`), and `optional: true, allow_empty: false` accepts an omitted or nil value while rejecting an empty one (previously raised at declaration). It requires a `type:` whose values can be empty. Emptiness is `empty?`, not `blank?` — a whitespace-only String is not empty.
* [BUGFIX] A field that rejects empty values now reflects that into `input_schema`/`output_schema` as `minItems`/`minProperties`/`minLength`. Previously a required `type: Array` rejected `[]` at runtime while its schema advertised `[]` as acceptable, leaving schema looser than runtime.
* [BUGFIX] A field's `optional?` and its schema requiredness now answer one shared question ("do this field's validators accept nil?"). A field that rejects nil by type alone was previously reported as optional while the schema listed it as required.
* [BUGFIX] A `nil` rejected by a field's `type:` now produces that one error instead of also running every other validator against the nil — a custom `validate:` written for a real value no longer contributes a derivative "failed validation" message alongside the type error.
```

- [ ] **Step 4: Verify the docs site builds and links resolve**

Run: `yarn docs:check`
Expected: VitePress builds and the link checker passes. The new table adds no cross-references, so a failure here means a pre-existing dead link — check `git stash && yarn docs:check` before chasing it.

- [ ] **Step 5: Commit**

```bash
git add docs/reference/class.md AGENTS-consuming.md CHANGELOG.md
git commit -m "docs: the four nil/empty contracts, side by side"
```

---

## Post-Plan Verification

- [ ] `bundle exec rspec` — full suite green
- [ ] `rake spec_rails` — Rails dummy app green (Tasks 4 and 6 change predicates its reflection specs exercise)
- [ ] `bundle exec rubocop` — clean
- [ ] Re-run the probe matrix from the spec against the built gem and confirm all four cells behave as the spec's table claims, including the two accidental spellings (`presence: false`, `presence: { allow_blank: true }`) still working — they are not removed by this plan, only superseded in the docs.
- [ ] Confirm `Axn::Validation::Base` has no remaining duplicate of the nil predicates in `schema.rb` (`grep -n "def nil_tolerant_validation?\|def set_includes_nil?" lib/`) — two definitions is the bug Task 4 exists to remove.
