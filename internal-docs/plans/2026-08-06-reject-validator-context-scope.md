# Reject an `on:` naming an ActiveModel validation context — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refuse at declaration every `on:` that does not mean "a subfield on the named parent", so a validator that ActiveModel would silence on every call can no longer be declared.

**Architecture:** One shared raiser scans validator entries at the two seams every declaration route funnels through (`_parse_field_validations` for fields/subfields/`exposes`/block members/Factory, `_symbol_keyed_member_validations` for raw and object-backed shape members). Three bag-level cases — a shape member's own `on:` on either member route, and `exposes … on:` — are refused where they arrive, each with its own reason. With no declaration able to carry one, the seven `lib/` reads that taught the nil/empty predicates and schema reflection to tolerate an inert entry are deleted and replaced by a policy spec pinning the four places that construct a stored `validations` bag.

**Tech Stack:** Ruby, RSpec, ActiveModel 7.2.2.2 (validations only — axn must work outside Rails).

**Spec:** `internal-docs/specs/2026-08-06-reject-validator-context-scope-design.md`
**Ticket:** https://linear.app/teamshares/issue/PRO-3022

## Global Constraints

- **Works outside Rails.** Guard every Rails/ActiveRecord reference with `defined?(...)`. Everything in this plan is `spec/` (non-Rails); no `spec_rails` mirror is required, because the `expects`/`exposes` grammar and ActiveModel's option handling load in both.
- **TDD.** Failing test first, then implementation. Every task below is ordered that way.
- **Fail at declaration, not runtime.** Every new error is an `ArgumentError` raised while the class is being defined, and every message states the problem **and** the fix.
- **Never render a caller's object by dispatching to it.** In a declaration error, render a class via `Axn::Internal::Reflection::PropertyNames.renderable_class_name` and a declared name via `PropertyNames.inspect_field_name` / `renderable_label` (reached in `contract.rb` through `_inspect_field_name` / `_shape_member_label`). None of the messages in this plan interpolate a caller value, so no new renderer is needed — do not add one.
- **`Axn::Internal::ShapeGraph` is the seam for reading a caller Hash.** Never classify one with `is_a?`; use `ShapeGraph.hash_or_nil` (`case`/`when`, which does not call the object's `is_a?`).
- **Comments explain *why*, never *what*.** No historical framing — no "used to X, now Y", no ticket numbers narrating a change. Present tense, describing the rule as it stands.
- **Run** `bundle exec rspec` from the repo root. Formatting is enforced in CI; run `bundle exec rubocop -a` before each commit and match surrounding style.

---

## File Structure

| File | Responsibility in this change |
|---|---|
| `lib/axn/internal/shape_graph.rb` | gains `carries_key?` — a bound `Hash#key?`, so a subclass cannot hide a key from a guard |
| `lib/axn/core/validation/base.rb` | `entry_context_scoped?` becomes un-invertible and is re-documented as the guard's definition; the inert-entry branch in `nil_tolerant_validation?` is deleted |
| `lib/axn/core/contract.rb` | the shared raiser + the field-path call site; the member context-option constant, raiser and classification; the `exposes` rejection; four inert-entry reads deleted |
| `lib/axn/core/contract/shape_declaration.rb` | the member-walk call site |
| `lib/axn/internal/reflection/schema.rb` | two inert-entry reads and one delegator deleted |
| `spec/axn/core/validations/validator_context_scope_spec.rb` | **new** — every rejection: route, spelling, validator, both member routes, `exposes`, and the controls |
| `spec/axn/stored_validations_policy_spec.rb` | **new** — pins the four stored-bag constructors, with what a bypass costs |
| `spec/axn/core/schema_reflection_spec.rb` | five rows dropped, one rewritten to `presence: false`, one describe block re-aimed at gates |
| `spec/axn/core/validations/nil_empty_axes_matrix_spec.rb` | six examples retired (their state can no longer be declared) |
| `docs/reference/class.md` | states that axn has no validation contexts, in the `if:`/`unless:` section |
| `CHANGELOG.md` | `[BREAKING]` under `## Unreleased` |

---

### Task 1: Make `entry_context_scoped?` un-invertible

The predicate becomes a declaration guard in Task 2, and "a declaration guard a caller can invert is not a guard". Today it asks `entry_opts.is_a?(Hash)` and then `key?` — both ordinary overridable methods — while ActiveModel classifies the same bag with `case`/`when` (C-level `Module#===`) and reads the key off a plain Hash built by `merge`. So a `Hash` subclass can make axn answer `false` on a bag ActiveModel still gates. `ShapeGraph.detach_option_containers!` neutralizes this for every entry it copies, but it explicitly skips `:shape` — and `shape:` is a validator entry — so the evasion is reachable.

Both halves are hardened together. Fixing the classification and leaving the key read dispatched would be the worse of the three options: a guard that is un-invertible on one axis and invertible on the other.

**Files:**
- Modify: `lib/axn/internal/shape_graph.rb:63-74` (add the bound method + seam), `lib/axn/core/validation/base.rb:140-153`
- Test: `spec/axn/core/validations/validator_context_scope_spec.rb` (create)

**Interfaces:**
- Produces: `Axn::Internal::ShapeGraph.carries_key?(hash, key) -> Boolean`, and an `Axn::Validation::Base.entry_context_scoped?(entry_opts) -> Boolean` whose verdict no caller-defined method can change. Task 2 consumes the latter.

- [ ] **Step 1: Write the failing test**

Create `spec/axn/core/validations/validator_context_scope_spec.rb`:

```ruby
# frozen_string_literal: true

require "axn/testing/spec_helpers"

# Axn has no ActiveModel validation contexts: `Validation::Fields` calls `valid?` with no context, while
# `validate` installs a gate of `!(Array(options[:on]) & Array(validation_context)).empty?` whenever
# `options.key?(:on)` — an intersection that is empty on every call. So an `on:` anywhere ActiveModel reads
# validator options names a check that runs on no call, and is refused at declaration.
#
# A DECLARATION-level `on:` on `expects` is a different option entirely — axn's subfield parent — and every
# control here exists to keep it working.
RSpec.describe "an `on:` that names a validation context" do
  # A Hash subclass that denies its own class. ActiveModel classifies with `case`/`when`, which is C-level and
  # ignores this, so a bag like it still reaches the validator carrying `on:` and still goes inert — the guard
  # has to agree, or it is one a caller can switch off.
  let(:disowning_hash) do
    Class.new(Hash) do
      def is_a?(klass) = klass == ::Hash ? false : super
      def key?(_key) = false
    end
  end

  describe "Validation::Base.entry_context_scoped?" do
    it "reads a plain bag carrying on:" do
      expect(Axn::Validation::Base.entry_context_scoped?({ klass: String, on: :create })).to be(true)
    end

    it "reads a bag without on: as unscoped" do
      expect(Axn::Validation::Base.entry_context_scoped?({ klass: String, if: :flag })).to be(false)
    end

    it "reads a non-Hash entry as unscoped" do
      expect(Axn::Validation::Base.entry_context_scoped?(String)).to be(false)
      expect(Axn::Validation::Base.entry_context_scoped?(true)).to be(false)
      expect(Axn::Validation::Base.entry_context_scoped?(nil)).to be(false)
    end

    it "is not fooled by a bag that denies being a Hash and hides its keys" do
      bag = disowning_hash.new
      bag[:on] = :create

      expect(bag.is_a?(::Hash)).to be(false)                                    # the lie
      expect(Axn::Validation::Base.normalize_validator_options(bag)).to have_key(:on) # what AM still sees
      expect(Axn::Validation::Base.entry_context_scoped?(bag)).to be(true)
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bundle exec rspec spec/axn/core/validations/validator_context_scope_spec.rb`
Expected: the first three examples PASS; **"is not fooled by a bag that denies being a Hash and hides its keys" FAILS** with `expected true, got false`.

- [ ] **Step 3: Add the bound-key seam to `ShapeGraph`**

In `lib/axn/internal/shape_graph.rb`, add `HASH_KEY_P` to the bound-method group and include it in the existing `private_constant` line:

```ruby
      HASH_EACH = ::Hash.instance_method(:each)
      HASH_KEY_P = ::Hash.instance_method(:key?)
      KERNEL_DUP = ::Kernel.instance_method(:dup)
      HASH_DEFAULT = ::Hash.instance_method(:default)
      HASH_DEFAULT_PROC = ::Hash.instance_method(:default_proc)
      private_constant :HASH_EACH, :HASH_KEY_P, :KERNEL_DUP, :HASH_DEFAULT, :HASH_DEFAULT_PROC
```

Then add the seam immediately after `each_entry`:

```ruby
      # Whether a caller Hash carries a key — BOUND, for the same reason the traversal above is: a guard whose
      # verdict a subclass can change by defining `key?` is not a guard. Read where the answer decides a
      # declaration, alongside `hash_or_nil` for the classification.
      def self.carries_key?(hash, key) = HASH_KEY_P.bind_call(hash, key)
```

- [ ] **Step 4: Harden the predicate**

Replace `lib/axn/core/validation/base.rb:153` (leave the comment block above it for Task 7, which rewrites it):

```ruby
      def self.entry_context_scoped?(entry_opts)
        bag = Axn::Internal::ShapeGraph.hash_or_nil(entry_opts)
        !nil.equal?(bag) && Axn::Internal::ShapeGraph.carries_key?(bag, :on)
      end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bundle exec rspec spec/axn/core/validations/validator_context_scope_spec.rb`
Expected: 4 examples, 0 failures.

- [ ] **Step 6: Run the full suite**

Run: `bundle exec rspec`
Expected: 0 failures. The hardening only widens what the predicate recognizes, and only for a bag no existing example builds.

- [ ] **Step 7: Commit**

```bash
bundle exec rubocop -a lib spec
git add lib/axn/internal/shape_graph.rb lib/axn/core/validation/base.rb spec/axn/core/validations/validator_context_scope_spec.rb
git commit -m "PRO-3022: entry_context_scoped? cannot be inverted by the bag it reads"
```

---

### Task 2: Reject a nested `on:` on the field path, and retire the examples that relied on it

The raiser plus the call site that covers top-level `expects`, `exposes`, an `on:` subfield, a block-form shape member, and `Axn::Factory.build` — all of which reach `_parse_field_validations`. Ten existing examples declare a context-scoped entry and start raising the moment this lands, so they are retired in the same commit; leaving them for a later task means a red suite in between.

**Files:**
- Modify: `lib/axn/core/contract.rb` (add `_reject_validator_context_scope!` after `_canonicalize_validator_options!`, which ends at `:1559`; add the call inside `_parse_field_validations` between `:1669` and `:1671`)
- Modify: `spec/axn/core/schema_reflection_spec.rb`, `spec/axn/core/validations/nil_empty_axes_matrix_spec.rb`

**Interfaces:**
- Consumes: `Axn::Validation::Base.entry_context_scoped?` (Task 1), plus the existing `Axn::Validation::Base.validator_entries(validations)`.
- Produces: `_reject_validator_context_scope!(validations, where:)` — a private class method on the contract module, raising `ArgumentError`. Task 4 calls it with a member label.

- [ ] **Step 1: Write the failing test**

Append to `spec/axn/core/validations/validator_context_scope_spec.rb`, inside the top-level `describe`:

```ruby
  describe "inside a validator's option bag" do
    it "is refused on a top-level expects, naming the field, the validator and the fix" do
      expect do
        Class.new do
          include Axn
          expects :v, type: { klass: String, on: :create }
          def call = nil
        end
      end.to raise_error(ArgumentError, /`on:` inside type: on \["v"\].*validation context.*no context.*if:.*unless:/m)
    end

    it "is refused on an exposes" do
      expect do
        Class.new do
          include Axn
          exposes :v, type: { klass: String, on: :create }
          def call = expose(v: "x")
        end
      end.to raise_error(ArgumentError, /`on:` inside type:/)
    end

    it "is refused on an on: subfield, whose own on: is the parent and stays legal" do
      expect do
        Class.new do
          include Axn
          expects :parent, type: Hash
          expects :zip, on: :parent, type: { klass: String, on: :create }
          def call = nil
        end
      end.to raise_error(ArgumentError, /`on:` inside type: on \["zip"\]/)
    end

    it "is refused on a block-form shape member" do
      expect do
        Class.new do
          include Axn
          expects(:h, type: Hash) { field :x, type: { klass: String, on: :create } }
          def call = nil
        end
      end.to raise_error(ArgumentError, /`on:` inside type:/)
    end

    it "is refused through Axn::Factory.build" do
      expect do
        Axn::Factory.build(expects: { v: { type: { klass: String, on: :create } } }) { nil }
      end.to raise_error(ArgumentError, /`on:` inside type:/)
    end

    # AM installs the context gate on the KEY's presence whatever the value, and `Array(nil) & anything` is
    # empty — so every spelling names a context no call is in, and none is "the default context".
    [:create, nil, false, []].each do |spelling|
      it "is refused for on: #{spelling.inspect}" do
        expect do
          Class.new do
            include Axn
            expects :v, type: { klass: String, on: spelling }
            def call = nil
          end
        end.to raise_error(ArgumentError, /`on:` inside type:/)
      end
    end

    # Axn's own validators are validator ENTRIES too, and none of the five reads `:on` for anything of its
    # own — so the check covers them without rejecting anything legitimate.
    {
      length: { minimum: 5, on: :create },
      presence: { on: :create },
      inclusion: { in: %w[a b], on: :create },
      numericality: { greater_than: 1, on: :create },
      format: { with: /\Aa+\z/, on: :create },
      of: { klass: String, on: :create },
      validate: { with: ->(_v) { nil }, on: :create },
    }.each do |key, entry|
      it "is refused on #{key}:" do
        opts = key == :of ? { type: Array, key => entry } : { optional: true, key => entry }
        expect do
          klass = Class.new do
            include Axn
            def call = nil
          end
          klass.expects :v, **opts
        end.to raise_error(ArgumentError, /`on:` inside #{key}:/)
      end
    end

    # A raw `shape:` bag is itself a validator entry, so it is caught here — and the check sits ahead of
    # `_derive_raw_shape_container!`, which rebuilds the node and would otherwise drop the key being reported.
    it "is refused on a raw shape: bag's own on:" do
      expect do
        Class.new do
          include Axn
          expects :h, type: Hash, shape: { members: [], container: Hash, on: :create }
          def call = nil
        end
      end.to raise_error(ArgumentError, /`on:` inside shape:/)
    end

    it "names every offending entry, not only the first" do
      expect do
        klass = Class.new do
          include Axn
          def call = nil
        end
        klass.expects :v, type: { klass: String, on: :create }, length: { minimum: 2, on: :create }
      end.to raise_error(ArgumentError, /type:.*length:|length:.*type:/)
    end
  end

  # Over-rejection is the failure mode when a guard is tightened, so these pin what must keep being ACCEPTED.
  # Audit them by INVERSE mutation: make the guard over-eager (drop the `validator_entries` filter, or test
  # any gate key rather than `:on`) and confirm one of these fails.
  describe "what stays legal" do
    it "accepts a declaration-level on: — the subfield parent" do
      klass = Class.new do
        include Axn
        expects :parent, type: Hash
        expects :zip, on: :parent, type: String
        def call = nil
      end

      expect(klass.call(parent: { zip: "02118" })).to be_ok
    end

    it "accepts a declaration-level on: beside a legitimately gated entry" do
      klass = Class.new do
        include Axn
        expects :parent, type: Hash
        expects :flag, type: :boolean
        expects :zip, on: :parent, type: { klass: String, if: :flag }
        def call = nil
      end

      expect(klass.call(parent: { zip: "02118" }, flag: true)).to be_ok
      expect(klass.call(parent: { zip: 5 }, flag: false)).to be_ok # the gate is closed, so the type check is skipped
    end

    it "accepts on: :ambient_context" do
      klass = Class.new do
        include Axn
        expects :who, on: :ambient_context, type: String, optional: true
        def call = nil
      end

      expect(klass.call).to be_ok
    end

    it "accepts every other ActiveModel shared option nested in an entry" do
      klass = Class.new do
        include Axn
        expects :v, optional: true, length: { minimum: 5, if: :never, unless: :never, allow_nil: true, allow_blank: true }
        def call = nil
        def never = false
      end

      expect(klass.call(v: "a")).to be_ok
    end

    it "accepts a nested strict:, which raises rather than being inert" do
      klass = Class.new do
        include Axn
        expects :v, optional: true, length: { minimum: 5, strict: true }
        def call = nil
      end

      expect(klass.call(v: "a")).not_to be_ok
    end
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bundle exec rspec spec/axn/core/validations/validator_context_scope_spec.rb`
Expected: every example under "inside a validator's option bag" FAILS with "expected ArgumentError but nothing was raised". The five under "what stays legal" PASS already — they are controls, and passing now is the point.

- [ ] **Step 3: Add the raiser**

In `lib/axn/core/contract.rb`, immediately after `_canonicalize_validator_options!` (which ends at `:1559`):

```ruby
        # `on:` inside a validator's own option bag is ActiveModel's validation CONTEXT option, and axn has no
        # validation contexts: `Validation::Fields` calls `valid?` with no context, while `validate` installs a
        # gate of `!(Array(options[:on]) & Array(validation_context)).empty?` whenever `options.key?(:on)` — an
        # intersection that is empty on every call. So the entry runs on no call and whatever it declared is
        # unenforced, which is the strongest form of a silently ignored option: the author wrote a check, the
        # class defines cleanly, and every value passes.
        #
        # Only real validator ENTRIES are scanned. A BAG-level `on:` is a different declaration needing a
        # different fix — a shape member has no validation context and no subfield parent either, and neither
        # has an exposure — so it is reported where it arrives (`_check_member_option_keys!` /
        # `_build_shape_member` for a member, `exposes` for an exposure) and is out of this check's remit.
        #
        # Every offender is named at once: an author who wrote two of them has one declaration to fix, not two
        # rounds of the same error.
        def _reject_validator_context_scope!(validations, where:)
          offenders = Axn::Validation::Base.validator_entries(validations).filter_map do |key, entry|
            "#{key}:" if Axn::Validation::Base.entry_context_scoped?(entry)
          end
          return if offenders.empty?

          runs = offenders.size == 1 ? "that check runs" : "those checks run"
          raise ArgumentError,
                "`on:` inside #{offenders.join(' / ')} on #{where} names an ActiveModel validation context, and " \
                "axn validates with no context — so #{runs} on no call and the declaration is left unenforced. " \
                "Axn has no validation contexts: drop `on:`, or gate the check with `if:`/`unless:`, which axn " \
                "does support. (A DECLARATION-level `on:` is axn's subfield parent — `expects :zip, on: :address` " \
                "— and is unaffected.)"
        end
```

- [ ] **Step 4: Add the field-path call site**

In `_parse_field_validations`, between `_canonicalize_validator_options!` (`:1669`) and `_derive_raw_shape_container!` (`:1671`):

```ruby
          _canonicalize_validator_options!(validations, fields)

          # Ahead of every consumer of this bag — `_validate_allow_empty!`, `_reconcile_emptiness_axis!`, the
          # tolerance push-down, `_apply_nil_skip_to_non_type_validators!` — so none of them ever judges an entry
          # that cannot run. Ahead of the push-down specifically so the message quotes the author's own spelling
          # rather than one carrying merged tolerance keys, and ahead of `_derive_raw_shape_container!` because
          # that rebuilds a raw `shape:` node and drops the very key being reported.
          #
          # After `ShapeGraph.detach_option_containers!` (`:1651`), which is what makes the verdict the caller's
          # to state and not to decide: every Hash-valued entry is axn's own plain Hash by now. `:shape` is the
          # one entry that seam skips, which is why the predicate classifies and reads its key without
          # dispatching to the bag.
          _reject_validator_context_scope!(validations, where: fields.map(&:to_s).inspect)

          _derive_raw_shape_container!(validations)
```

- [ ] **Step 5: Run the new spec to verify it passes**

Run: `bundle exec rspec spec/axn/core/validations/validator_context_scope_spec.rb`
Expected: 0 failures.

- [ ] **Step 6: Run the full suite and confirm exactly the expected examples now fail**

Run: `bundle exec rspec 2>&1 | tail -30`
Expected: **10 failures**, all `ArgumentError` from a declaration — 4 in `spec/axn/core/schema_reflection_spec.rb` and 6 in `spec/axn/core/validations/nil_empty_axes_matrix_spec.rb`. Any failure outside those two files is over-rejection: stop and fix the guard rather than the spec.

- [ ] **Step 7: Drop the retired row from the requiredness-parity table**

In `spec/axn/core/schema_reflection_spec.rb`, delete this line (the table's other rows already cover a nil-admitting type with the presence check suppressed):

```ruby
      "a context-scoped presence: over a nil-admitting type" => { type: Object, presence: { on: :publish } },
```

- [ ] **Step 8: Re-aim the "never runs" describe block at gates**

In `spec/axn/core/schema_reflection_spec.rb`, replace the whole block — comment, helper, and four examples — with the two survivors. The `action_for` helper defined inside it is used only by the two examples being removed (the survivors use `schema_for`), so it goes with them; the independent `action_for` at `:832` is untouched.

Replace:

```ruby
    # An entry scoped to a validation context never runs: axn validates with `valid?` and no context. Its
    # floor is not a constraint the contract ever applies, so advertising one would reject a value every
    # call accepts. This is not the gate policy below it — a gate MAY be open, and is counted as if it were.
    describe "an entry scoped to a validation context, which never runs" do
      def action_for(**opts)
        klass = Class.new do
          include Axn
          def call = nil
        end
        klass.expects :v, **opts
        klass
      end

      it "emits no floor for a context-scoped presence:, whose empty value the runtime accepts" do
        expect(action_for(type: Array, presence: { on: :publish }).call(v: [])).to be_ok
        expect(schema_for(type: Array, presence: { on: :publish })).to eq(type: "array")
      end

      it "emits no floor for a context-scoped length:, whose empty value the runtime accepts" do
        opts = { type: Array, presence: false, length: { minimum: 3, on: :publish } }
        expect(action_for(**opts).call(v: [])).to be_ok
        expect(schema_for(**opts)).to eq(type: "array")
      end

      it "still emits the floor of a GATED presence:, which a call may run" do
        expect(schema_for(type: Array, presence: { if: :flag })).to eq(type: "array", minItems: 1)
      end

      it "still emits the floor of a GATED length:, which a call may run" do
        expect(schema_for(type: Array, presence: false, length: { minimum: 3, if: :flag })).to eq(type: "array", minItems: 3)
      end
    end
```

with:

```ruby
    # A gated entry MAY be open on a given call, so its floor is emitted as if the gate were open —
    # static-maximal, which can leave the input schema stricter than a closed-gate runtime but never looser,
    # and is the policy for every gated constraint here.
    describe "an entry a gate may skip" do
      it "emits the floor of a gated presence:, which a call may run" do
        expect(schema_for(type: Array, presence: { if: :flag })).to eq(type: "array", minItems: 1)
      end

      it "emits the floor of a gated length:, which a call may run" do
        expect(schema_for(type: Array, presence: false, length: { minimum: 3, if: :flag })).to eq(type: "array", minItems: 3)
      end
    end
```

- [ ] **Step 9: Rewrite the one example with a live fixture**

Its subject is that a *present-but-inert* `presence:` does not count as the other check rejecting the empty value. `presence: false` is a live spelling of exactly that. Replace:

```ruby
        it "emits no floor when the only other check is one no call runs" do
          opts = { type: String, presence: { on: :publish }, length: { minimum: 3, allow_blank: true } }
          expect(action_for(**opts).call(v: "")).to be_ok
          expect(schema_for(**opts)).to eq(type: "string")
        end
```

with:

```ruby
        it "emits no floor when the only other check is one that is switched off" do
          opts = { type: String, presence: false, length: { minimum: 3, allow_blank: true } }
          expect(action_for(**opts).call(v: "")).to be_ok
          expect(schema_for(**opts)).to eq(type: "string")
        end
```

- [ ] **Step 10: Retire the six matrix examples**

In `spec/axn/core/validations/nil_empty_axes_matrix_spec.rb`, delete these six examples outright. Each one's subject is a validator that is declared and unconditionally dead, and no live fixture produces that: dropping the `on:` raises the emptiness conflict, and so does a closed `if:` gate, because `_length_emptiness_answer` never consults gates. Their `if: -> { false }` neighbours cover the gate predicate, which survives, and must be left exactly as they are.

Delete: `"keeps enforcing allow_empty: false alongside a length: floor scoped to a validation context"`, `"keeps enforcing allow_empty: false alongside a presence: scoped to a validation context"`, `"reads no answer at all out of a context-scoped length: that would otherwise admit an empty value"` (and the two-line comment directly above it, which describes an inert entry), `"reads no answer at all out of a context-scoped presence: alongside allow_empty: true"`, `"reads no answer at all out of a context-scoped, per-call length: minimum"`, and `"leaves the other validators' nil rejections in force when the type entry is scoped to a context"`.

Then fix the describe block's own comment, which still promises the retired half. Replace:

```ruby
    # An entry carrying its OWN if:/unless: is skipped whenever its condition says so, and one scoped to a
    # validation context never runs at all — so `allow_empty: false` keeps its own check alongside either,
    # rather than trusting a promise that can go quiet.
```

with:

```ruby
    # An entry carrying its OWN if:/unless: is skipped whenever its condition says so — so `allow_empty: false`
    # keeps its own check alongside one, rather than trusting a promise that can go quiet.
```

- [ ] **Step 11: Run the full suite**

Run: `bundle exec rspec`
Expected: 0 failures.

- [ ] **Step 12: Commit**

```bash
bundle exec rubocop -a lib spec
git add lib/axn/core/contract.rb spec/axn/core/validations/validator_context_scope_spec.rb \
        spec/axn/core/schema_reflection_spec.rb spec/axn/core/validations/nil_empty_axes_matrix_spec.rb
git commit -m "PRO-3022: refuse a validator entry scoped to a validation context"
```

---

### Task 3: Reject a nested `on:` on the shape-member walk

The field path covers a block-form member because it routes through `_parse_field_configs`. A **raw** `shape:` member — a `ShapeConfig`, or any object answering to `field`/`validations` — bypasses `expects`' option handling entirely and is canonicalized only in the declaration walk. That walk is also the one route an object-backed member takes, so this call site is what makes the guard's coverage total.

**Files:**
- Modify: `lib/axn/core/contract/shape_declaration.rb:408-413`
- Test: `spec/axn/core/validations/validator_context_scope_spec.rb`

**Interfaces:**
- Consumes: `_reject_validator_context_scope!(validations, where:)` (Task 2) and the existing `_shape_member_label(name)`.

- [ ] **Step 1: Write the failing test**

Append inside the `describe "inside a validator's option bag"` block:

```ruby
    it "is refused on a raw shape: member, which bypasses expects' option handling" do
      member = Axn::Core::Contract::ShapeConfig.new(field: :x, validations: { type: { klass: String, on: :create } })

      expect do
        Class.new do
          include Axn
          expects :h, type: Hash, shape: { members: [member], container: Hash }
          def call = nil
        end
      end.to raise_error(ArgumentError, /shape member `x`.*`on:` inside type:|`on:` inside type:.*shape member `x`/m)
    end

    it "is refused on an object-backed member, which only the declaration walk sees" do
      member = Class.new do
        def field = :x
        def validations = { type: { klass: String, on: :create } }
      end.new

      expect do
        Class.new do
          include Axn
          expects :h, type: Hash, shape: { members: [member], container: Hash }
          def call = nil
        end
      end.to raise_error(ArgumentError, /`on:` inside type:/)
    end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bundle exec rspec spec/axn/core/validations/validator_context_scope_spec.rb -e "raw shape: member" -e "object-backed member"`
Expected: both FAIL with "expected ArgumentError but nothing was raised".

- [ ] **Step 3: Add the member-walk call site**

In `lib/axn/core/contract/shape_declaration.rb`, between `_canonicalize_validator_options!` (`:408`) and `_reject_member_coerce!` (`:413`) — the same position relative to canonicalization that the field path uses, so a declaration failing both is reported by the same one on either route:

```ruby
          _canonicalize_validator_options!(copy, [key])
          # A raw member never reaches `_parse_field_validations`, so this is where its entries are held to the
          # rule a field's are. The member's own BAG-level `on:` is refused earlier, by
          # `_check_member_option_keys!` above, with the reason particular to a member.
          _reject_validator_context_scope!(copy, where: "shape member `#{_shape_member_label(name)}`")
          _reject_member_coerce!(copy)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bundle exec rspec spec/axn/core/validations/validator_context_scope_spec.rb`
Expected: 0 failures.

- [ ] **Step 5: Run the full suite**

Run: `bundle exec rspec`
Expected: 0 failures.

- [ ] **Step 6: Commit**

```bash
bundle exec rubocop -a lib spec
git add lib/axn/core/contract/shape_declaration.rb spec/axn/core/validations/validator_context_scope_spec.rb
git commit -m "PRO-3022: hold a raw shape member's entries to the same context rule"
```

---

### Task 4: Reject a shape member's own bag-level `on:`

Neither meaning of `on:` exists on a member: axn has no validation contexts, and a member has no subfield parent. Today the two member routes fail differently and both silently — a raw member's bag reaches `validates` verbatim so *every* validator in it goes dead (a `{ presence: true, on: :create }` member accepts `nil`), while a block-form member's `on:` is absorbed as the subfield-parent kwarg and then dropped by `ShapeConfig`, so the option vanishes with no error. One reason, applied on both routes.

`:on` stays in `KNOWN_MEMBER_VALIDATION_KEYS`. Removing it would make the raw route report "Unknown key(s) :on", which is false — the key is recognized, it just cannot mean anything here.

**Files:**
- Modify: `lib/axn/core/contract.rb` — the constant beside `SHAPE_MEMBER_READER_OPTIONS` (`:949`), `_check_member_option_keys!` (`:985-1013`), the raiser beside `_raise_member_reader_options!` (`:1025-1032`), `_build_shape_member` (`:1067-1069`)
- Modify: `spec/axn/core/schema_reflection_spec.rb` (four table rows)
- Test: `spec/axn/core/validations/validator_context_scope_spec.rb`

**Interfaces:**
- Produces: `SHAPE_MEMBER_CONTEXT_OPTIONS` and `_raise_member_context_option!(name, context_opts)`, both used on the two member routes only.

- [ ] **Step 1: Write the failing test**

Append to `spec/axn/core/validations/validator_context_scope_spec.rb`, inside the top-level `describe`:

```ruby
  # A member's bag reaches `validates` as-is on the raw route, so a bag-level `on:` silences every validator in
  # it; on the block route the same key is absorbed as the subfield-parent kwarg and then dropped. One reason
  # covers both, and it is not the reader-option or unknown-key reason.
  describe "at the top of a shape member's bag" do
    it "is refused on a raw shape: member" do
      member = Axn::Core::Contract::ShapeConfig.new(field: :x, validations: { presence: true, on: :create })

      expect do
        Class.new do
          include Axn
          expects :h, type: Hash, shape: { members: [member], container: Hash }
          def call = nil
        end
      end.to raise_error(ArgumentError, /shape member `x` does not support on:.*validation context.*no subfield parent/m)
    end

    it "is refused on a block-form member" do
      expect do
        Class.new do
          include Axn
          expects(:h, type: Hash) { field :x, presence: true, on: :create }
          def call = nil
        end
      end.to raise_error(ArgumentError, /shape member `x` does not support on:/)
    end

    it "keeps reporting an unknown key as unknown rather than as a context option" do
      expect do
        Class.new do
          include Axn
          expects(:h, type: Hash) { field :x, tpye: String }
          def call = nil
        end
      end.to raise_error(ArgumentError, /Unknown key\(s\) :tpye/)
    end

    it "keeps reporting a reader option with the reader-less reason" do
      expect do
        Class.new do
          include Axn
          expects(:h, type: Hash) { field :x, type: String, as: :y }
          def call = nil
        end
      end.to raise_error(ArgumentError, /does not support as:.*reader-less/m)
    end

    it "still accepts the tolerance a member's bag may legitimately carry" do
      member = Axn::Core::Contract::ShapeConfig.new(field: :x, validations: { type: String, allow_nil: true })
      klass = Class.new do
        include Axn
        expects :h, type: Hash, shape: { members: [member], container: Hash }
        def call = nil
      end

      expect(klass.call(h: { x: nil })).to be_ok
    end
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bundle exec rspec spec/axn/core/validations/validator_context_scope_spec.rb -e "at the top of a shape member's bag"`
Expected: the first two FAIL with "expected ArgumentError but nothing was raised"; the last three PASS (controls).

- [ ] **Step 3: Add the constant**

In `lib/axn/core/contract.rb`, after `SHAPE_MEMBER_READER_OPTIONS` (`:949`):

```ruby
        # `on:` on a member has neither of its two meanings available: axn has no ActiveModel validation
        # contexts (a bag-level one reaches `validates` verbatim on the raw route and silences every validator
        # in the bag on every call), and a member has no subfield parent for it to name either. Refused with
        # that reason rather than as an unrecognized key — `:on` IS a recognized option, which is why it stays
        # in KNOWN_MEMBER_VALIDATION_KEYS — and separately from the reader options, because an author who
        # wrote `on:` has a different problem from one who wrote `as:`.
        SHAPE_MEMBER_CONTEXT_OPTIONS = %i[on].freeze
```

- [ ] **Step 4: Add the raiser**

After `_raise_member_reader_options!` (`:1032`):

```ruby
        def _raise_member_context_option!(name, context_opts)
          return if context_opts.empty?

          raise ArgumentError,
                "shape member `#{_shape_member_label(name)}` does not support " \
                "#{context_opts.map { |k| "#{k}:" }.join('/')} — it names an ActiveModel validation context, and " \
                "axn validates with no context, so every validator in the member's bag would be skipped on " \
                "every call. A member has no subfield parent for it to name either. Gate the checks with " \
                "`if:`/`unless:`, which axn does support."
        end
```

- [ ] **Step 5: Classify the key on the raw route**

In `_check_member_option_keys!`, the recognized-key short circuit has to stop swallowing `:on` — it is a member of `KNOWN_MEMBER_VALIDATION_KEYS`, so without the exclusion the loop `next`s past it and nothing classifies it. Replace the method body's loop and raise sequence:

```ruby
        def _check_member_option_keys!(name, validations)
          unsupported = reader_opts = context_opts = unknown = nil
          validations.each_key do |key|
            case key
            when ::Symbol
              next if KNOWN_MEMBER_VALIDATION_KEYS.include?(key) && SHAPE_MEMBER_CONTEXT_OPTIONS.exclude?(key)
            end

            if SHAPE_MEMBER_UNSUPPORTED_OPTIONS.include?(key)
              (unsupported ||= []) << key
            elsif SHAPE_MEMBER_READER_OPTIONS.include?(key)
              (reader_opts ||= []) << key
            elsif SHAPE_MEMBER_CONTEXT_OPTIONS.include?(key)
              (context_opts ||= []) << key
            else
              (unknown ||= []) << key
            end
          end

          _raise_member_unsupported_options!(name, unsupported) if unsupported
          _raise_member_reader_options!(name, reader_opts) if reader_opts
          _raise_member_context_option!(name, context_opts) if context_opts
          return if unknown.nil?
```

Leave the `raise ArgumentError` for `unknown` that follows exactly as it is. Then extend the method's own doc comment (`:964-984`) — where it explains the ordering "an option a member may never carry is named for what it is, and only what is left over is an unrecognized key" — with one sentence: a recognized key that a member still cannot carry is excluded from the short circuit above, or it would be skipped before it could be classified.

- [ ] **Step 6: Reject it on the block route too**

In `_build_shape_member`, after the reader-options line (`:1069`):

```ruby
          _raise_member_unsupported_options!(name, opts.keys & SHAPE_MEMBER_UNSUPPORTED_OPTIONS)
          _raise_member_reader_options!(name, opts.keys & SHAPE_MEMBER_READER_OPTIONS)
          # Ahead of `_parse_field_configs` below, whose `on:` parameter would otherwise absorb the key as a
          # subfield parent — which `ShapeConfig` then drops, leaving the option silently gone.
          _raise_member_context_option!(name, opts.keys & SHAPE_MEMBER_CONTEXT_OPTIONS)
```

- [ ] **Step 7: Run the new examples to verify they pass**

Run: `bundle exec rspec spec/axn/core/validations/validator_context_scope_spec.rb`
Expected: 0 failures.

- [ ] **Step 8: Run the full suite and confirm the four expected failures**

Run: `bundle exec rspec 2>&1 | tail -20`
Expected: **4 failures**, all in `spec/axn/core/schema_reflection_spec.rb` — the `on:` rows of the raw-member tolerance table.

- [ ] **Step 9: Drop the four retired rows**

In `spec/axn/core/schema_reflection_spec.rb`, delete the comment and the four rows. The table's subject is a declaration-wide *tolerance* surviving on a raw member, and its seven `allow_nil:`/`allow_blank:` rows carry that on their own.

Delete:

```ruby
      # A declaration-wide `on:` is merged into every validator, and axn validates with no context — so no
      # spelling of it can match and nothing in the declaration runs at all.
      "a hash-level on: naming a context" => [{ type: String, on: :publish }, true],
      "a hash-level on: nil" => [{ type: String, on: nil }, true],
      "a hash-level on: false" => [{ type: String, on: false }, true],
      "a hash-level on: []" => [{ type: String, on: [] }, true],
```

Then trim the describe block's lead-in comment, which still cites the retired rows as where a spelling "survives to be judged". Replace:

```ruby
  # ActiveModel applies a DECLARATION-WIDE `allow_nil:`/`allow_blank:` to every validator in the `validates`
  # call, so an entry that carries none of its own still runs tolerant. A raw shape member is where that
  # spelling survives to be judged — a field declaration pushes the tolerance down into each entry before it
  # is ever read — so each row here holds the runtime, the member's `optional?` and the emitted property to
  # one answer.
```

with:

```ruby
  # ActiveModel applies a DECLARATION-WIDE `allow_nil:`/`allow_blank:` to every validator in the `validates`
  # call, so an entry that carries none of its own still runs tolerant. A raw shape member is where that
  # spelling survives to be judged — a field declaration pushes the tolerance down into each entry before it
  # is ever read — so each row here holds the runtime, the member's `optional?` and the emitted property to
  # one answer. `on:` is not among them: a member cannot carry one at all (see `_raise_member_context_option!`).
```

- [ ] **Step 10: Run the full suite**

Run: `bundle exec rspec`
Expected: 0 failures.

- [ ] **Step 11: Commit**

```bash
bundle exec rubocop -a lib spec
git add lib/axn/core/contract.rb spec/axn/core/validations/validator_context_scope_spec.rb spec/axn/core/schema_reflection_spec.rb
git commit -m "PRO-3022: a shape member cannot carry on: on either route"
```

---

### Task 5: Reject `exposes … on:`

`exposes` has no `on:` parameter, so the key falls through `**` into `_partition_field_options`, is accepted (`:on` is in `KNOWN_VALIDATION_KEYS`), and is then absorbed by `_parse_field_configs`' subfield-parent parameter — landing as `config.on` on an outbound config, which nothing reads. Neither meaning exists here: an exposure has no subfield parent, and axn has no validation contexts.

**Files:**
- Modify: `lib/axn/core/contract.rb:507` (`exposes`, immediately after `validations, metadata = _partition_field_options(fields, **)`)
- Test: `spec/axn/core/validations/validator_context_scope_spec.rb`

- [ ] **Step 1: Write the failing test**

Append to `spec/axn/core/validations/validator_context_scope_spec.rb`, inside the top-level `describe`:

```ruby
  describe "at the top of an exposes declaration" do
    it "is refused, naming both meanings it cannot have" do
      expect do
        Class.new do
          include Axn
          exposes :v, presence: true, on: :create
          def call = expose(v: "x")
        end
      end.to raise_error(ArgumentError, /exposes does not support `on:` on \["v"\].*no subfield parent.*no ActiveModel validation contexts/m)
    end

    it "is refused whatever the value, since nothing reads it either way" do
      expect do
        Class.new do
          include Axn
          exposes :v, presence: true, on: nil
          def call = expose(v: "x")
        end
      end.to raise_error(ArgumentError, /exposes does not support `on:`/)
    end

    it "leaves an ordinary exposes untouched" do
      klass = Class.new do
        include Axn
        exposes :v, type: String
        def call = expose(v: "x")
      end

      expect(klass.call).to be_ok
    end
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bundle exec rspec spec/axn/core/validations/validator_context_scope_spec.rb -e "at the top of an exposes declaration"`
Expected: the first two FAIL ("nothing was raised"); the third PASSES.

- [ ] **Step 3: Add the rejection**

In `exposes`, directly after `validations, metadata = _partition_field_options(fields, **)`:

```ruby
          # `exposes` takes no `on:` parameter, so the key arrives in the validations bag and would then be
          # absorbed by `_parse_field_configs`' subfield-parent parameter — stored as `config.on` on an outbound
          # config, where nothing reads it. Neither meaning is available: an exposure has no subfield parent
          # (see `_reject_dotted_field_name!` above, which refuses a dotted name for the same reason), and axn
          # has no ActiveModel validation contexts. Rejected on the key's presence, whatever the value, matching
          # how `exposes` refuses `user_facing:`.
          if validations.key?(:on)
            raise ArgumentError,
                  "exposes does not support `on:` on #{fields.map(&:to_s).inspect} — an exposure has no subfield " \
                  "parent to reach into, and axn has no ActiveModel validation contexts. Drop `on:`; to gate the " \
                  "outbound checks, use `if:`/`unless:`."
          end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bundle exec rspec spec/axn/core/validations/validator_context_scope_spec.rb`
Expected: 0 failures.

- [ ] **Step 5: Run the full suite**

Run: `bundle exec rspec`
Expected: 0 failures.

- [ ] **Step 6: Commit**

```bash
bundle exec rubocop -a lib spec
git add lib/axn/core/contract.rb spec/axn/core/validations/validator_context_scope_spec.rb
git commit -m "PRO-3022: exposes refuses an on: it can neither route nor scope"
```

---

### Task 6: Delete the seven reads that tolerated an inert entry

With Tasks 2–5 in place, no declaration can put an `:on` into a stored `validations` bag, so seven reads in `lib/` are unreachable. They are deleted rather than kept as fallbacks, because the impossibility is enumerable — exactly four places construct a stored bag, and Task 7 pins that set.

`_entry_guaranteed_to_run?` collapses to a single question once its context half is gone, and its `declaration_options` parameter becomes unused; the two call sites stop computing an argument nobody reads. `entry_self_gated?` and `entry_effective_gate_keys` are untouched — the gate predicates stay reachable and their examples must stay green.

**Files:**
- Modify: `lib/axn/core/validation/base.rb:83-153`, `lib/axn/core/contract.rb:1770-1966`, `lib/axn/internal/reflection/schema.rb:864-876, 1328-1355, 1801`

- [ ] **Step 1: Confirm the suite is green before deleting**

Run: `bundle exec rspec`
Expected: 0 failures. This is the baseline that makes the next step's result meaningful — a deletion of unreachable code must not change it.

- [ ] **Step 2: Delete the branch in `nil_tolerant_validation?`**

In `lib/axn/core/validation/base.rb`, delete this line from `nil_tolerant_validation?`:

```ruby
        return true if entry_context_scoped?(opts)
```

In the `nil_accepted?` doc comment above it, delete the clause `one scoped to a validation context (it never runs, so it rejects nothing), ` from the sentence listing what makes an entry nil-tolerant, and delete the trailing clause of the static-maximal sentence — ` — a context-scoped entry is different in kind, running on no call at all, and counts for nothing` — leaving that sentence ending at "never tighten it)".

- [ ] **Step 3: Rewrite the canonical comment on `entry_context_scoped?`**

Its current text names three consumers that no longer exist. Replace the whole comment above `entry_context_scoped?` with:

```ruby
      # Whether a validator ENTRY is scoped to an ActiveModel validation CONTEXT — an `on:` among its options,
      # which makes it permanently inert: `Fields.errors_for` calls `valid?` with no context, so the entry runs
      # on no call at all. THE definition behind the declaration guards that refuse one
      # (`_reject_validator_context_scope!`), and its only consumer: a context-scoped entry cannot be declared,
      # so no judgment downstream ever meets one.
      #
      # Only the key's presence is asked: `validate` installs the context gate on `options.key?(:on)` whatever
      # the value, so `on: nil`/`false`/`[]` name a context no call is in exactly as `on: :publish` does —
      # `Array(nil)` is `[]`, and intersecting an empty Array with anything is empty.
      #
      # Neither the classification nor the key read dispatches to the bag, because this decides a declaration
      # and a guard a caller can invert is not a guard: `hash_or_nil` classifies with `case`/`when` (which does
      # not call the object's `is_a?`) and `carries_key?` binds `Hash#key?`. That matches how ActiveModel reads
      # the same bag — `_parse_validates_options` cases on `Hash`, and `key?` is asked of the plain Hash its
      # `merge` builds — so the two cannot disagree about one entry.
      #
      # Distinct from an if:/unless: GATE, which a given call MAY run, and which stays fully supported.
      # (Not to be confused with a DECLARATION-level `on:`, which is axn's subfield parent.)
```

- [ ] **Step 4: Delete the four reads in `contract.rb`**

In `_type_rejects_nil?`, delete the line and the comment bullet describing it:

```ruby
          return false if Axn::Validation::Base.entry_context_scoped?(type)
```

```ruby
        #   * an `on:` inside the type BAG — ActiveModel's validation-context option, which makes the entry
        #     permanently inert and so its nil verdict vacuous (Validation::Base.entry_context_scoped?).
```

Then change the doc comment's opening count from "Four ways it isn't" to "Three ways it isn't".

In `_presence_emptiness_answer`, delete these two lines:

```ruby
          entry = Axn::Validation::Base.effective_entry_options(validations[:presence], _shared_validation_options(validations))
          return nil if Axn::Validation::Base.entry_context_scoped?(entry)
```

and restore the read the second line stood in front of, so the method still resolves the entry against the declaration's shared options:

```ruby
          entry = Axn::Validation::Base.effective_entry_options(validations[:presence], _shared_validation_options(validations))
```

In its doc comment, delete the clause `nor out of a context-scoped entry, which runs on no call at all: an entry that never runs answers NOTHING, so it can neither carry the axis nor contradict the flag, in either polarity`, keeping the sentence about a nil-tolerance intact.

In `_length_emptiness_answer`, delete:

```ruby
          return nil if Axn::Validation::Base.entry_context_scoped?(opts)
```

and in its doc comment change "Three shapes answer nothing" to "Two shapes answer nothing", deleting the clause `a CONTEXT-SCOPED entry, which runs on no call, so its floor is neither a promise to lean on nor a contradiction to raise over; and`.

Replace `_entry_guaranteed_to_run?` entirely:

```ruby
        # Whether a validator ENTRY runs on every call, and so can be trusted with the emptiness axis in place
        # of the flag's own check. What withdraws that guarantee is a gate of its OWN — a closed condition skips
        # that one validator, leaving nothing to reject the empty value while the rest of the contract still
        # applies. Judged structurally; no condition is ever evaluated.
        #
        # A DECLARATION-level gate is deliberately not one: it skips EVERY validator in the declaration, the
        # emptiness check included, so relative to the check that would replace this entry there is nothing to
        # withdraw.
        def _entry_guaranteed_to_run?(entry) = !Axn::Validation::Base.entry_self_gated?(entry)
```

Update both call sites to stop building an argument nobody reads:

```ruby
          if length_answer == :rejected && _entry_guaranteed_to_run?(validations[:length])
```

```ruby
          return if presence_answer == :rejected && _entry_guaranteed_to_run?(validations[:presence])
```

Then, in `_reconcile_emptiness_axis!`'s doc comment, replace `an entry a closed gate or a validation context can skip enforces nothing on the call where it is skipped` with `an entry a closed gate can skip enforces nothing on the call where it is skipped`.

- [ ] **Step 5: Delete the two reads and the delegator in `schema.rb`**

In `presence_rejects_blank?`:

```ruby
          !opts[:allow_blank] && !entry_context_scoped?(opts)
```

becomes:

```ruby
          !opts[:allow_blank]
```

and its doc comment drops `, and it is not context-scoped (an entry that runs on no call rejects nothing)`.

In `declared_size_minimum`:

```ruby
          if !entry_context_scoped?(length) && (rejects_empty || !length[:allow_blank])
```

becomes:

```ruby
          if rejects_empty || !length[:allow_blank]
```

and its doc comment drops the paragraph beginning `A context-scoped entry contributes no floor either`, keeping the two sentences after it that state the gate policy — reword their opening from `That is not the gate treatment: a GATED entry` to `A GATED entry` so the paragraph stands alone.

Delete the now-unused delegator:

```ruby
        def entry_context_scoped?(opt) = Axn::Validation::Base.entry_context_scoped?(opt)
```

- [ ] **Step 6: Verify nothing outside the guard reads the predicate**

Run: `grep -rn "entry_context_scoped" lib`
Expected: exactly two lines — the definition in `lib/axn/core/validation/base.rb` and the read inside `_reject_validator_context_scope!` in `lib/axn/core/contract.rb`.

- [ ] **Step 7: Run the full suite**

Run: `bundle exec rspec`
Expected: 0 failures — identical to Step 1. A failure here means something reachable was deleted, not something dead.

- [ ] **Step 8: Confirm the gate predicates are untouched**

Run: `bundle exec rspec spec/axn/core/validations/nil_empty_axes_matrix_spec.rb spec/axn/core/schema_reflection_spec.rb spec/axn/core/conditional_validation_spec.rb`
Expected: 0 failures. These hold the `if:`/`unless:` behavior that must survive this deletion intact.

- [ ] **Step 9: Commit**

```bash
bundle exec rubocop -a lib
git add lib/axn/core/validation/base.rb lib/axn/core/contract.rb lib/axn/internal/reflection/schema.rb
git commit -m "PRO-3022: drop the reads that tolerated an entry no declaration can carry"
```

---

### Task 7: Pin the four constructors of a stored validations bag

The deletion in Task 6 rests on a claim about the whole library: every stored `validations` bag comes from a guarded seam. A spec enumerating today's declaration routes cannot protect that — it only covers sites that exist when it is written. What protects it is pinning the constructor set, so a fifth one fails the suite and forces whoever adds it to route through a seam or re-open the question.

**Files:**
- Create: `spec/axn/stored_validations_policy_spec.rb`

- [ ] **Step 1: Write the test**

This one is written to pass immediately — it is a pin, not a red-green cycle. Its value is the failure it produces later.

```ruby
# frozen_string_literal: true

require "axn/testing/spec_helpers"

# An `on:` inside a validator's option bag is refused at declaration (`_reject_validator_context_scope!`), and
# the nil/empty predicates and schema reflection therefore carry no branch for one. That is sound only while
# every stored `validations` bag comes from a guarded seam — `_parse_field_validations` for a field, subfield,
# exposure, block-form member or Factory declaration, and `_symbol_keyed_member_validations` for a raw or
# object-backed shape member.
#
# So the constructors are pinned by count per file. A NEW one is the single way that claim can break, and it
# is what this spec exists to catch: route the new bag through a seam, or restore the tolerance the predicates
# used to carry.
#
# A bag can also be RE-DERIVED from an existing config rather than constructed: `Data#with` builds a new
# config carrying a different bag without going through either seam. That dimension is pinned too, so both
# ways a stored bag comes to exist are covered.
#
# What a bypass costs, so the next reader knows what the pin protects. It is not schema drift:
#
#   * `_type_rejects_nil?` reading an inert type entry as authoritative hands `allow_nil: true` to EVERY other
#     validator on the field, so a nil passes with nothing left to reject it.
#   * `_reconcile_emptiness_axis!` defers `allow_empty: false` to a floor that never runs, so the flag is
#     silently unenforced.
#
# Both are runtime holes. Failing here, at the commit that would cause one, is the point.
#
# Both pins are text scans, so they catch the spellings they are written against and not the idea. A
# derivation assembled at runtime (`config.with(**overrides)`) leaves no literal keyword to match and is
# invisible here. So a green run is not proof that the claim above holds — it is only the absence of the
# reachable ways to break it. Treat a change in this area as needing the argument made again, not as
# cleared by this file passing.
RSpec.describe "constructors of a stored validations bag" do
  # rubocop:disable Lint/ConstantDefinitionInBlock
  EXPECTED_CONSTRUCTORS = {
    # `_build_shape_member` (from a config `_parse_field_validations` produced) and `_parse_field_configs`.
    "lib/axn/core/contract.rb" => 2,
    # The declaration walk, from `_symbol_keyed_member_validations`.
    "lib/axn/core/contract/shape_declaration.rb" => 1,
    # The synthetic ambient root, whose bag is a literal `{}` and can carry nothing.
    "lib/axn/core/ambient_context.rb" => 1,
  }.freeze

  # Both spellings of construction are counted: these configs are `Data.define`d, so `Klass[...]` builds one
  # exactly as `.new` does, and a pin that saw only `.new` would leave the other spelling a silent hole.
  # `Axn::Internal::FieldConfig` is the field-NAME convention helper, a different thing that happens to share
  # the base name, so it is excluded by lookbehind rather than counted.
  CONSTRUCTOR_PATTERN = /(?<!Internal::)(?:Field|Shape)Config(?:\.new\b|\[)/

  # Deriving one config from another carries a bag too, and `Data#with` reaches neither seam: it runs the
  # class's own `initialize`, which validates `sensitive:`/`user_facing:` and nothing about validator entries.
  # The constructor scan cannot see such a site, because the class name is absent from it — the receiver is a
  # variable (`config.with(...)`) — so the bag-REPLACING form is pinned by its own keyword instead.
  #
  # The one pinned site is sound by construction rather than by inspection: `effective_validations` only
  # `reject`s entries, so it returns a subset of a bag a seam already cleared, and a subset cannot introduce a
  # key. That is the property a new site needs: every retained entry must be an unmodified entry from an
  # already-cleared bag. Dropping entries preserves it; rewriting a retained entry's VALUE does not, even
  # though it adds no key — that needs a seam.
  EXPECTED_BAG_DERIVATIONS = {
    "lib/axn/internal/reflection/schema.rb" => 1,
  }.freeze

  DERIVATION_PATTERN = /\.with\([^)]*\bvalidations:/
  # rubocop:enable Lint/ConstantDefinitionInBlock

  def self.lib_root = File.expand_path("../../lib", __dir__)

  def scan_for(pattern)
    Dir.glob("#{self.class.lib_root}/**/*.rb").each_with_object({}) do |path, counts|
      hits = File.read(path).scan(pattern).size
      next if hits.zero?

      counts["lib#{path.delete_prefix(self.class.lib_root)}"] = hits
    end
  end

  it "constructs a stored bag in exactly the pinned places" do
    expect(scan_for(CONSTRUCTOR_PATTERN)).to eq(EXPECTED_CONSTRUCTORS)
  end

  it "re-derives a stored bag in exactly the pinned places" do
    expect(scan_for(DERIVATION_PATTERN)).to eq(EXPECTED_BAG_DERIVATIONS)
  end

  it "reads every one of them out of a guarded seam" do
    # A behavioural companion to the count above: each seam refuses a context-scoped entry, so a bag arriving
    # from one cannot carry an `:on` however it was declared.
    member = Axn::Core::Contract::ShapeConfig.new(field: :x, validations: { type: { klass: String, on: :create } })

    expect do
      Class.new do
        include Axn
        expects :v, type: { klass: String, on: :create }
        def call = nil
      end
    end.to raise_error(ArgumentError, /`on:` inside type:/)

    expect do
      Class.new do
        include Axn
        expects :h, type: Hash, shape: { members: [member], container: Hash }
        def call = nil
      end
    end.to raise_error(ArgumentError, /`on:` inside type:/)
  end
end
```

- [ ] **Step 2: Run it and verify it passes**

Run: `bundle exec rspec spec/axn/stored_validations_policy_spec.rb`
Expected: 3 examples, 0 failures.

- [ ] **Step 3: Verify the pin actually bites**

Temporarily add a fifth constructor — e.g. paste `Axn::Core::Contract::FieldConfig.new(field: :zzz, validations: {}, reader_as: :zzz)` into an unreachable private method in `lib/axn/core/ambient_context.rb` — and re-run.

Run: `bundle exec rspec spec/axn/stored_validations_policy_spec.rb`
Expected: FAIL, reporting `"lib/axn/core/ambient_context.rb" => 2`. **Revert the temporary line** and re-run to confirm green. A pin that cannot fail is not a pin.

- [ ] **Step 4: Commit**

```bash
bundle exec rubocop -a spec
git add spec/axn/stored_validations_policy_spec.rb
git commit -m "PRO-3022: pin the constructors a stored validations bag may come from"
```

---

### Task 8: Document it, and write the changelog

**Files:**
- Modify: `docs/reference/class.md` (the `#### Conditional validation (`if:` / `unless:`)` section at `:206`)
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Document the absence of validation contexts**

At the end of the `Conditional validation (`if:` / `unless:`)` section in `docs/reference/class.md` — the supported mechanism the errors point at — add the following. One line per Markdown paragraph, no manual line breaks. (Shown here in a four-backtick block because it contains a fenced Ruby example; write three-backtick fences into the file.)

````markdown
Axn has **no validation contexts.** ActiveModel lets a model gate a validator on a context (`record.valid?(:create)` against `validates … on: :create`), but axn validates with no context at all, so a validator carrying `on:` would never run on any call. Rather than accept a check that silently enforces nothing, axn refuses the declaration:

```ruby
expects :v, type: { klass: String, on: :create }
# => ArgumentError: `on:` inside type: on ["v"] names an ActiveModel validation context, and axn validates
#    with no context — so that check runs on no call and the declaration is left unenforced.
```

Use `if:`/`unless:` to gate a check instead. The same rejection covers a shape member's own `on:`, and `on:` on an `exposes`.

Note that this is only about `on:` **inside a validator's options.** A declaration-level `on:` on `expects` is a completely different option — it is axn's [subfield parent](#nestedsubfield-expectations) (`expects :zip, on: :address`) — and is unaffected.
````

Confirm the anchor before committing: `grep -n "nested-subfield-expectations\|#### Nested/Subfield" docs/reference/class.md`. VitePress derives the slug from the heading text, so use whatever that heading actually produces rather than the guess above.

- [ ] **Step 2: Verify the docs build and the new anchor resolves**

Run: `yarn docs:check 2>&1 | tail -10`
Expected: a successful build followed by a clean link check. This is the step that catches a wrong `#nestedsubfield-expectations` slug — `docs:build` alone would not.

- [ ] **Step 3: Write the changelog entry**

`## Unreleased` is genuinely the unreleased section: the `0.1.0-alpha.5.1` heading below it is tagged (`v0.1.0.pre.alpha.5.1`), so this is not the post-rename state where the top *version* heading would be the one to write under. It currently holds only `### Fixed`, so add a sibling section in the prevailing style — `### Validation, coercion & schema` is the heading the released notes use for this area. Insert it directly above `### Fixed`:

```markdown
### Validation, coercion & schema

* [BREAKING] An `on:` inside a validator's options is now refused at declaration. Axn validates with no ActiveModel validation context, so `validates`' context gate never matched and such an entry ran on **no call at all** — `expects :v, type: { klass: String, on: :create }` declared cleanly and then accepted every value, `v: 5` included. Every spelling was equally dead (`on: nil`/`false`/`[]` too, since `Array(nil)` is `[]` and an empty intersection never matches), and it applied to every validator, axn's own `type:`/`of:`/`validate:`/`model:`/`shape:` as well as ActiveModel's. Three sibling spellings that were accepted and then silently discarded are refused with it: a shape member's own bag-level `on:` (which on the raw `shape:` route silenced every validator in that member's bag — a `{ presence: true, on: :create }` member accepted `nil`), and `on:` on an `exposes` (stored on the outbound config, read by nothing). To gate a check, use `if:`/`unless:`. A DECLARATION-level `on:` on `expects` is untouched — it is the subfield parent, a different option that happens to share the spelling (see PRO-3022).
```

- [ ] **Step 4: Run the full suite one last time**

Run: `bundle exec rspec`
Expected: 0 failures.

- [ ] **Step 5: Commit**

```bash
git add docs/reference/class.md CHANGELOG.md
git commit -m "PRO-3022: document that axn has no validation contexts"
```

---

## Self-Review

**Spec coverage.** Every section of the design maps to a task: the hardening → Task 1; C1's field path → Task 2; C1's member walk → Task 3; C2 → Task 4; C3 → Task 5; C4's deletions → Task 6; C4's pin → Task 7; docs and changelog → Task 8. The spec's testing section maps as follows — route enumeration, spellings, every validator, two-offender message, the `shape:` bag, and the hardening example in Tasks 1–3; both member routes in Task 4; `exposes` in Task 5; the over-rejection controls in Task 2 with the gate-predicate survival check in Task 6 Step 8. Scope item 3 (no `strict:`-style sweep) needs no task by design; the controls in Task 2 Step 1 are what pin that the other five shared options stay accepted.

**Sequencing.** Each guard task retires the examples it breaks in the same commit, so the suite is green at every commit boundary: Task 2 carries the ten it breaks, Task 4 the four. Task 6 deletes only after every declaration that could reach the deleted reads is already refused, which is why its Step 1 establishes a green baseline and Step 7 requires the identical result.

**Type and name consistency.** `_reject_validator_context_scope!(validations, where:)` is defined in Task 2 and called with a member label in Task 3. `SHAPE_MEMBER_CONTEXT_OPTIONS` and `_raise_member_context_option!(name, context_opts)` are defined and used within Task 4. `ShapeGraph.carries_key?(hash, key)` is added in Task 1 and used only by `entry_context_scoped?`. `_entry_guaranteed_to_run?` changes arity in Task 6, and both call sites are updated in the same step.

**One judgment call worth flagging to the reviewer.** Task 6 Step 4 deletes `_presence_emptiness_answer`'s context check but keeps the `effective_entry_options` read directly above it, because the method still needs the entry resolved against the declaration's shared options to read `allow_blank:`. The step spells that out rather than leaving a two-line deletion that would silently drop the resolution too.
