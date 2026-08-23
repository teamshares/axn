# Container-position validators — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make one positional rule true — *a validator constrains the value at the position it is declared at* — so an `Array`/`Hash`-typed field's validators, the runtime, and the emitted schema stop disagreeing about what they target.

**Architecture:** Four independent changes behind one rule. (1) Axn's own `Clusivity` subclasses, exposed as constants on `Axn::Validation::Base`, drop ActiveModel's element-wise Array branch so `inclusion:`/`exclusion:` compare the whole value at every position — which is what reflection has been emitting all along. (2+3) Two declaration-time refusals in `_parse_field_validations`, beside `_reject_validator_context_scope!`: validators that can only reach a container through its Ruby string form, and an `inclusion:` set no member of which can satisfy the declared `type:`. (4) The ceiling twin of `declared_length_floor`, emitted as `maxItems`/`maxProperties`/`maxLength`.

**Tech Stack:** Ruby, ActiveModel 8.1.x (`Validations::Clusivity`, `InclusionValidator`, `ExclusionValidator`, `LengthValidator`), RSpec.

**Spec:** `internal-docs/specs/2026-08-21-container-field-validators-design.md` — read it first; every task below argues from it. Ticket: https://linear.app/teamshares/issue/PRO-3192/axn-validators-on-a-container-typed-field-runtime-and-schema-disagree

## Global Constraints

- **TDD** (`AGENTS.md`, `CONTRIBUTING.md`): failing test first, then implementation. Every task writes its spec before touching `lib/`.
- **Works outside Rails.** No new hard Rails/ActiveRecord reference; `spec/` runs without Rails. Nothing here is Rails-adjacent, so no `spec_rails` addition is needed — but the suite still has to pass: `BUNDLE_GEMFILE=Gemfile bundle exec rspec` from `spec_rails/dummy_app` (368 examples).
- **Reuse the seams.** `Axn::Validation::Base` owns every shared judgment about a validator entry (`validator_entries`, `effective_entry_options`, `declared_length_checks`, `entry_effective_gate_keys`). New judgments go there, not beside their callers.
- **Never dispatch on a caller-supplied object to decide a declaration.** Compare classes with `equal?`, classify with `case`/`when Module`, and read a bag through `Internal::ShapeGraph.hash_or_nil` / `carries_key?` — a guard a caller can invert is not a guard (`internal-docs/agent-notes/error-paths.md`).
- **Know which way a guard errs.** Both new refusals must UNDER-restrict when they cannot tell: a dynamic set, an undeclared `type:`, a pseudo-type token, or a union carrying one non-container all stand the guard down. Over-restriction rejects a legal declaration; under-restriction only delays the diagnosis.
- **The projection stays biased stricter.** `docs/reference/class.md:270` and `docs/recipes/authoring-tool-adapters.md:117` state schema-valid ⇒ runtime-valid. Emitting a ceiling only shrinks the schema-valid set, so it preserves that; nothing in this plan may widen it.
- **CHANGELOG:** `## Unreleased` exists at `CHANGELOG.md:3` (newest tag is `v0.1.0.pre.alpha.5.1`, so alpha-5 is shipped). Entries go under its `### Changed` / `### Fixed`, tagged `[BREAKING]` / `[FIX]`.
- **Verify before claiming done:** `bundle exec rspec`, the `spec_rails` run above, and `bundle exec rubocop`.

---

## File Structure

| File | Responsibility |
| --- | --- |
| `lib/axn/core/validation/validators/whole_value_clusivity.rb` (new) | The one `include?` override that drops ActiveModel's Array branch. |
| `lib/axn/core/validation/validators/inclusion_validator.rb` (new) | `Axn::Validators::InclusionValidator` — AM's, plus the override. |
| `lib/axn/core/validation/validators/exclusion_validator.rb` (new) | `Axn::Validators::ExclusionValidator` — same. |
| `lib/axn/core.rb` (modify, `:25-30`) | Require the three new files in the existing validator block. |
| `lib/axn/core/validation/base.rb` (modify) | Expose both validator constants; `literal_set_members`; `declared_length_ceiling`; `emittable_length_ceiling?`. |
| `lib/axn/core/contract.rb` (modify) | `CONTAINER_TYPE_TOKENS`, `TO_S_TARGETED_VALIDATOR_KEYS`, and the two refusals, called from `_parse_field_validations`. |
| `lib/axn/internal/reflection/schema.rb` (modify) | `SIZE_CEILING_KEYS`, `size_ceiling_key_for`, `declared_size_maximum`, and the ceiling half of `apply_size_constraints!`. |
| `lib/axn/core/validation/validators/validate_validator.rb` (modify) | Its guard message advises `inclusion: { in: [...] }`, which is now refusable at a container position. |
| `spec/axn/core/validations/container_position_validators_spec.rb` (new) | The spec's failure grid, row by row, Array and Hash, with a scalar control per row. |
| `spec/axn/internal/reflection/schema_spec.rb` (modify) | Ceiling emission: alone, with a floor, across `anyOf` branches, and the stand-downs. |
| `AGENTS.md`, `internal-docs/agent-notes/guards-and-projections.md`, `docs/reference/class.md`, `CHANGELOG.md` (modify) | The rule, the satisfiability corollary, the grammar, the entries. |

Task order matters once: **Task 1 before Task 3.** Task 3 refuses the declaration Task 1's semantics make unsatisfiable; landing it first would reject declarations that still work element-wise.

Reassuring measurement, already taken: **no existing spec pins element-wise inclusion on a container field.** `grep -rn 'type: Array' spec | grep -c 'inclusion\|exclusion'` is `0`; every "bare-Array inclusion" spec is about the *set* being an Array (the `inclusion: %w[a b]` shorthand), not the value. Task 1 should therefore break nothing — if it does, read the failure before editing the spec.

---

## Task 1: Whole-value `inclusion:` / `exclusion:`

**Files:**
- Create: `lib/axn/core/validation/validators/whole_value_clusivity.rb`
- Create: `lib/axn/core/validation/validators/inclusion_validator.rb`
- Create: `lib/axn/core/validation/validators/exclusion_validator.rb`
- Modify: `lib/axn/core.rb:25-30` (the validator require block)
- Modify: `lib/axn/core/validation/base.rb:13-20` (the validator constant block)
- Test: `spec/axn/core/validations/container_position_validators_spec.rb` (new)

**Interfaces:**
- Consumes: `ActiveModel::Validations::InclusionValidator` / `ExclusionValidator`, and the private `Clusivity#delimiter` / `#inclusion_method` / `ResolveValue#resolve_value` they include.
- Produces: `Axn::Validators::InclusionValidator`, `Axn::Validators::ExclusionValidator`, `Axn::Validators::WholeValueClusivity`, and the constants `Axn::Validation::Base::InclusionValidator` / `::ExclusionValidator` — which is what makes `validates inclusion: …` resolve to axn's subclass (`ActiveModel::Validations::ClassMethods#validates` does `const_get("#{key.camelize}Validator")` from the class being declared on, activemodel `validates.rb:121-124`, and `const_get` walks ancestors).

- [ ] **Step 1: Write the failing test**

Create `spec/axn/core/validations/container_position_validators_spec.rb`:

```ruby
# frozen_string_literal: true

require "axn/testing/spec_helpers"

# One positional rule: a validator constrains the value AT THE POSITION IT IS DECLARED AT. `of:` is how a
# declaration descends a level. ActiveModel's Clusivity#include? special-cases an Array VALUE
# (activemodel-8.1.3.1 clusivity.rb:24) and distributes the set over its elements, which no rule states, which
# emits as `enum` on the array node, and which inverts to nonsense under exclusion's negating caller. See
# internal-docs/specs/2026-08-21-container-field-validators-design.md.
RSpec.describe "a validator at a container position" do
  describe "inclusion: constrains the value at its own position" do
    it "compares an Array-typed field's value as a whole" do
      action = build_axn { expects :tags, type: Array, of: String, inclusion: { in: [%w[a b], %w[c]] } }

      expect(action.call(tags: %w[a b]).ok?).to be(true)
      expect(action.call(tags: %w[c]).ok?).to be(true)
      expect(action.call(tags: %w[b a]).ok?).to be(false) # whole-value equality: order is part of the value
      expect(action.call(tags: %w[a]).ok?).to be(false)
    end

    it "does not distribute the set over an Array's elements" do
      action = build_axn { expects :tags, type: Array, inclusion: { in: %w[a b] } }

      expect(action.call(tags: %w[a b]).ok?).to be(false)
      expect(action.call(tags: %w[a]).ok?).to be(false)
    end

    it "agrees with the emitted enum on the same value" do
      action = build_axn { expects :tags, type: Array, of: String, inclusion: { in: [%w[a b]] } }

      expect(action.input_schema[:properties][:tags][:enum]).to eq([%w[a b]])
      expect(action.call(tags: %w[a b]).ok?).to be(true)
    end

    it "is unchanged at a scalar position" do
      action = build_axn { expects :status, type: String, inclusion: { in: %w[a b] } }

      expect(action.call(status: "a").ok?).to be(true)
      expect(action.call(status: "zzz").ok?).to be(false)
    end

    it "is unchanged on a Hash-typed field, where Clusivity never distributed" do
      action = build_axn { expects :meta, type: Hash, inclusion: { in: [{ "a" => 1 }] } }

      expect(action.call(meta: { "a" => 1 }).ok?).to be(true)
      expect(action.call(meta: { "a" => 2 }).ok?).to be(false)
    end
  end

  describe "exclusion: constrains the value at its own position" do
    it "rejects an Array value that IS a forbidden member, and nothing else" do
      action = build_axn { expects :tags, type: Array, of: String, exclusion: { in: [%w[bad]] } }

      expect(action.call(tags: %w[bad]).ok?).to be(false)
      expect(action.call(tags: %w[ok]).ok?).to be(true)
    end

    it "no longer passes an array carrying one forbidden element among legal ones" do
      # The old reading was `all?` under a negating caller: reject only when EVERY element is forbidden.
      action = build_axn { expects :tags, type: Array, exclusion: { in: %w[bad] } }

      expect(action.call(tags: %w[ok bad]).ok?).to be(true)  # no element-wise reading at all now
      expect(action.call(tags: %w[bad]).ok?).to be(true)     # the array is not the String "bad"
    end

    it "is unchanged at a scalar position" do
      action = build_axn { expects :name, type: String, exclusion: { in: %w[bad] } }

      expect(action.call(name: "bad").ok?).to be(false)
      expect(action.call(name: "ok").ok?).to be(true)
    end
  end

  describe "the constant shadowing reaches every position a validator is built at" do
    it "reaches a subfield" do
      action = build_axn do
        expects :payload, type: Hash
        expects :tags, on: :payload, type: Array, inclusion: { in: [%w[a b]] }
      end

      expect(action.call(payload: { tags: %w[a b] }).ok?).to be(true)
      expect(action.call(payload: { tags: %w[a] }).ok?).to be(false)
    end

    it "reaches a shape member" do
      action = build_axn do
        expects :row, type: Hash do
          field :tags, type: Array, inclusion: { in: [%w[a b]] }
        end
      end

      expect(action.call(row: { tags: %w[a b] }).ok?).to be(true)
      expect(action.call(row: { tags: %w[a] }).ok?).to be(false)
    end

    it "resolves inclusion: to axn's own validator, not ActiveModel's" do
      expect(Axn::Validation::Base::InclusionValidator).to be(Axn::Validators::InclusionValidator)
      expect(Axn::Validation::Base::ExclusionValidator).to be(Axn::Validators::ExclusionValidator)
      expect(Axn::Validators::InclusionValidator.ancestors).to include(Axn::Validators::WholeValueClusivity)
    end
  end

  describe "nil membership is unaffected" do
    # A nil was never an Array, so it never took Clusivity's Array branch — the nil-tolerance judgment that
    # drives requiredness and nullability read the whole value before this change and still does.
    it "keeps a field optional when its inclusion set contains nil" do
      action = build_axn { expects :tags, type: Array, inclusion: { in: [nil, %w[a]] } }

      expect(action.input_schema[:required]).not_to include("tags")
      expect(action.call.ok?).to be(true)
    end

    it "keeps a field required when its inclusion set does not contain nil" do
      action = build_axn { expects :tags, type: Array, inclusion: { in: [%w[a]] } }

      expect(action.input_schema[:required]).to include("tags")
    end
  end
end
```

- [ ] **Step 2: Run it to confirm it fails for the right reason**

```bash
bundle exec rspec spec/axn/core/validations/container_position_validators_spec.rb
```

Expected: the whole-value examples FAIL (an Array value still distributes, so `tags: %w[a b]` is rejected against `in: [%w[a b]]` and accepted against `in: %w[a b]`), and the constant example fails with `NameError: uninitialized constant Axn::Validators::InclusionValidator`. The scalar, Hash and nil-membership examples should PASS already — if any of those fails, stop: the change is reaching further than intended.

- [ ] **Step 3: Write the override module**

Create `lib/axn/core/validation/validators/whole_value_clusivity.rb`:

```ruby
# frozen_string_literal: true

require "active_model"

module Axn
  module Validators
    # ActiveModel's `Clusivity#include?` special-cases an Array VALUE — `value.all? { |v| members.include?(v) }`
    # (activemodel-8.1.3.1, clusivity.rb:24) — so an inclusion set distributes over an array's elements while
    # every other validator on the same field constrains the field's own value. Axn's rule is positional: a
    # validator constrains the value at the position it is declared at, and `of:` is how a declaration descends
    # a level. So the branch goes, and one reading holds everywhere.
    #
    # Three things that reading buys, in the order they matter. The emitted `enum` sits on the field's own node
    # and always did, so the runtime now agrees with the document instead of contradicting it. `exclusion:`
    # stops being wrong under every reading: `include?` is called by a negating caller, so distributing with
    # `all?` meant "reject only when EVERY element is forbidden", and an array carrying one forbidden element
    # among legal ones passed. And the reading reaches every depth, where the special case reached only a
    # field-level Array — a map's axis and an element two levels down have no field-level slot to borrow.
    #
    # Included into axn's own subclasses, which places it ahead of `Clusivity` in each subclass's ancestry;
    # `delimiter` / `inclusion_method` / `resolve_value` still come from ActiveModel. The consuming app's own
    # validators are untouched.
    module WholeValueClusivity
      private

      def include?(record, value)
        members = resolve_value(record, delimiter)

        members.public_send(inclusion_method(members), value)
      end
    end
  end
end
```

- [ ] **Step 4: Write the two subclasses**

Create `lib/axn/core/validation/validators/inclusion_validator.rb`:

```ruby
# frozen_string_literal: true

require "active_model"

require "axn/core/validation/validators/whole_value_clusivity"

module Axn
  module Validators
    # ActiveModel's inclusion check with the positional reading — see WholeValueClusivity. Exposed as a
    # constant on `Validation::Base`, which is how `validates inclusion: …` resolves to this class rather than
    # ActiveModel's for axn's one-off validator classes, and only for those.
    class InclusionValidator < ActiveModel::Validations::InclusionValidator
      include WholeValueClusivity
    end
  end
end
```

Create `lib/axn/core/validation/validators/exclusion_validator.rb`:

```ruby
# frozen_string_literal: true

require "active_model"

require "axn/core/validation/validators/whole_value_clusivity"

module Axn
  module Validators
    # ActiveModel's exclusion check with the positional reading — see WholeValueClusivity. The old distributing
    # reading was wrong here under any reading, not merely unstated: `include?` is consulted by a negating
    # caller, so `all?` meant "reject only when every element is forbidden".
    class ExclusionValidator < ActiveModel::Validations::ExclusionValidator
      include WholeValueClusivity
    end
  end
end
```

- [ ] **Step 5: Require them and expose the constants**

In `lib/axn/core.rb`, inside the existing validator block (currently lines 25-30), add — `whole_value_clusivity` first, since the two subclasses require it:

```ruby
require "axn/core/validation/validators/whole_value_clusivity"
require "axn/core/validation/validators/inclusion_validator"
require "axn/core/validation/validators/exclusion_validator"
```

In `lib/axn/core/validation/base.rb`, in the constant block that starts at line 13 (`ModelValidator = Validators::ModelValidator`), add:

```ruby
      # ActiveModel's own two, subclassed for the positional reading (see WholeValueClusivity). Listed here for
      # the same reason the axn-only validators are: `validates` resolves a validator by `const_get` from the
      # class being declared on, so a constant here shadows `ActiveModel::Validations::InclusionValidator` for
      # axn's one-off validator classes — top-level field, subfield, shape member and ContainerContents alike —
      # and for nothing else the consuming app declares.
      InclusionValidator = Validators::InclusionValidator
      ExclusionValidator = Validators::ExclusionValidator
```

- [ ] **Step 6: Run the new spec, then the whole suite**

```bash
bundle exec rspec spec/axn/core/validations/container_position_validators_spec.rb
bundle exec rspec
```

Expected: the new file passes in full. The suite should pass unchanged — no spec pins the old element-wise reading. **If something fails, read it before touching it:** a failure here is evidence the shadowing reached somewhere unintended, not a spec that needs updating.

- [ ] **Step 7: Commit**

```bash
git add lib/axn/core/validation/validators/whole_value_clusivity.rb \
        lib/axn/core/validation/validators/inclusion_validator.rb \
        lib/axn/core/validation/validators/exclusion_validator.rb \
        lib/axn/core.rb lib/axn/core/validation/base.rb \
        spec/axn/core/validations/container_position_validators_spec.rb
git commit -m "PRO-3192: inclusion:/exclusion: constrain the value at their own position

ActiveModel's Clusivity#include? special-cases an Array value and distributes the
set over its elements. Nothing in axn opted into that: it has no spelling in the
emitted schema (enum sits on the field's own node), it inverts to nonsense under
exclusion's negating caller, and it reaches only a field-level Array. Axn's own
subclasses drop the branch, exposed as constants on Validation::Base so they reach
every position a validator is built at and nothing the consuming app declares.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 2: Refuse the validators that can only reach a container through its `to_s`

**Files:**
- Modify: `lib/axn/core/contract.rb` — two constants near `SHAPE_INCOMPATIBLE_TYPES` (`:1227`), the guard beside `_reject_validator_context_scope!` (`:3015`), and the call in `_parse_field_validations` (`:3165`)
- Test: `spec/axn/core/validations/container_position_validators_spec.rb` (extend)

**Interfaces:**
- Consumes: `Axn::Validation::Base.validator_entries`, `Axn::Internal::ShapeGraph.hash_or_nil`, `_declared_type_tokens`, `_declared_fields_label`.
- Produces: `CONTAINER_TYPE_TOKENS`, `TO_S_TARGETED_VALIDATOR_KEYS`, `_reject_container_position_validators!(validations, fields:)`, `_declares_container_type_only?(declared)`, and `_declared_type_tokens_in(declared)` — **Task 3 consumes the last one** (controller Ruling 2: one bag-aware token read, two guards asking different questions of it, rather than the same three-line prologue twice).

- [ ] **Step 1: Write the failing test**

Append to `spec/axn/core/validations/container_position_validators_spec.rb`:

```ruby
  describe "validators that can only reach a container through its to_s are refused at declaration" do
    it "refuses format: on an Array-typed field" do
      expect { build_axn { expects :tags, type: Array, of: String, format: { with: /\A[A-Z]+\z/ } } }
        .to raise_error(ArgumentError, %r{format:.*:tags.*position}m)
    end

    it "refuses format: on a Hash-typed field" do
      expect { build_axn { expects :meta, type: Hash, format: { with: /k/ } } }
        .to raise_error(ArgumentError, /format:/)
    end

    it "refuses numericality:, comparison: and acceptance: on a container" do
      expect { build_axn { expects :tags, type: Array, numericality: true } }.to raise_error(ArgumentError, /numericality:/)
      expect { build_axn { expects :tags, type: Array, comparison: { greater_than: 1 } } }.to raise_error(ArgumentError, /comparison:/)
      expect { build_axn { expects :tags, type: Array, acceptance: true } }.to raise_error(ArgumentError, /acceptance:/)
    end

    it "names every offender at once, so one declaration is one fix" do
      expect { build_axn { expects :tags, type: Array, format: { with: /a/ }, numericality: true } }
        .to raise_error(ArgumentError, %r{format: / numericality:})
    end

    it "refuses a gated one too — a gate can skip a check, not give it a reading" do
      expect { build_axn { expects :tags, type: Array, format: { with: /a/, if: :never? } } }
        .to raise_error(ArgumentError, /format:/)
    end

    it "refuses on a Set, whose to_s is an inspect form like the other two" do
      expect { build_axn { expects :tags, type: Set, format: { with: /a/ } } }
        .to raise_error(ArgumentError, /format:/)
    end

    # The stand-downs. Each is a declaration the guard must NOT reject: over-restriction rejects legal work,
    # under-restriction only defers the diagnosis to the value that triggers it.
    it "admits a union type carrying a scalar, where the validator has something to constrain" do
      expect { build_axn { expects :f, type: [String, Array], format: { with: /a/ } } }.not_to raise_error
    end

    it "admits an undeclared type, which says nothing about what the value will be" do
      expect { build_axn { expects :f, format: { with: /a/ } } }.not_to raise_error
    end

    it "admits a pseudo-type token" do
      expect { build_axn { expects :f, type: :params, format: { with: /a/ } } }.not_to raise_error
    end

    it "admits a scalar container-ish type whose to_s is a real rendering" do
      expect { build_axn { expects :f, type: String, format: { with: /a/ } } }.not_to raise_error
    end

    it "admits a disabled entry, which ActiveModel skips outright" do
      expect { build_axn { expects :tags, type: Array, format: false } }.not_to raise_error
    end

    it "admits the validators that DO have a reading on a container" do
      expect { build_axn { expects :tags, type: Array, length: { maximum: 2 } } }.not_to raise_error
      expect { build_axn { expects :tags, type: Array, presence: true } }.not_to raise_error
      expect { build_axn { expects :tags, type: Array, of: String } }.not_to raise_error
    end
  end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bundle exec rspec spec/axn/core/validations/container_position_validators_spec.rb -e "can only reach a container"
```

Expected: every `raise_error` example FAILS with "expected ArgumentError but nothing was raised"; every stand-down example PASSES already.

- [ ] **Step 3: Add the two constants**

In `lib/axn/core/contract.rb`, immediately after `SHAPE_INCOMPATIBLE_TYPES` (`:1227-1230`):

```ruby
        # The classes whose `to_s` is a Ruby inspect form rather than a rendering of the value — so a validator
        # matching or coercing `value.to_s` reaches punctuation rather than data. Deliberately NOT "every
        # structured type": a `Data` class or a PORO may render itself meaningfully (`URI::HTTP#to_s`), and
        # refusing `format:` there would reject a legal declaration. `Set` is listed because its `to_s` is an
        # inspect form exactly as the other two are.
        CONTAINER_TYPE_TOKENS = [::Array, ::Hash, ::Set].freeze

        # Validators ActiveModel implements against `value.to_s` or a numeric coercion of it, so no container
        # value can satisfy them WHATEVER the options say: FormatValidator matches `value.to_s` (on an Array it
        # constrains `["a"].inspect` — measured: `format: { with: /\A\["a"\]\z/ }` really does accept `["a"]`),
        # and NumericalityValidator parses a numeric coercion, which no container has (measured against `["1"]`,
        # `[1]` and `{"a"=>1}`, with `only_integer:` and `greater_than:` alike).
        #
        # `comparison:` and `acceptance:` deliberately do NOT belong here, though an earlier draft of this plan
        # had them: their options can name a CONTAINER, and then they work. `comparison: { equal_to: ["a"] }`
        # accepts `["a"]`, `{ greater_than_or_equal_to: { "read" => true } }` accepts a Hash superset (Hash#>=),
        # `{ greater_than: Set["a"] }` accepts a Set superset (Set#>), and `acceptance: { accept: [["a"]] }`
        # accepts `["a"]` — all measured in bare ActiveModel. What is broken about them is a bound or set of the
        # WRONG type, which is the satisfiability question Task 3 answers with the runtime's own matcher, not a
        # blanket refusal by key.
        TO_S_TARGETED_VALIDATOR_KEYS = %i[format numericality].freeze
```

- [ ] **Step 4: Write the guard**

In `lib/axn/core/contract.rb`, immediately after `_reject_validator_context_scope!` (which ends at `:3023`):

```ruby
        # A validator whose ActiveModel implementation can only reach the declared value through its Ruby string
        # form, on a field whose every declared type is a container. Refused at declaration: `format:` there
        # constrains `["a"].inspect` — satisfiable, meaningless, and unexpressible in JSON Schema, where
        # `pattern` applies to strings — and the other three accept no container value at all.
        #
        # Gates do NOT rescue one. This is a judgment about what the validator can MEAN at this position, and a
        # closed `if:` skips a check rather than giving it a reading; the satisfiability guard below is the one
        # that stands down for a gate, because there the gate genuinely leaves a passing value.
        #
        # Every offender is named at once: an author who wrote two has one declaration to fix.
        def _reject_container_position_validators!(validations, fields:)
          return unless _declares_container_type_only?(validations[:type])

          entries = Axn::Validation::Base.validator_entries(validations)
          # A falsy entry is a disabled validator ActiveModel skips, so it constrains nothing and names nothing.
          offenders = TO_S_TARGETED_VALIDATOR_KEYS.select { |key| entries[key] }
          return if offenders.empty?

          raise ArgumentError,
                "#{offenders.map { |key| "#{key}:" }.join(' / ')} on #{_declared_fields_label(fields)} cannot " \
                "constrain a container: ActiveModel reads #{offenders.length == 1 ? 'it' : 'them'} off the " \
                "value's Ruby string form (`format:` matches `[\"a\"].to_s`) or off a numeric coercion of it " \
                "(`numericality:`), and a container has neither — so the check constrains punctuation or can " \
                "never pass. A validator constrains the value at the position it is declared at. Express a " \
                "constraint on the contents as `validate: ->(value) { ... }` — a per-element spelling inside " \
                "`of:` is not supported yet (PRO-3193) — or drop the option."
        end

        # Whether every type this declaration names is a container whose `to_s` is an inspect form. Answers
        # false for an undeclared type, a union carrying one non-container, and a pseudo-type token — each a
        # declaration the guard above must stand down on, since a value it can constrain is still possible.
        #
        # The `type:` bag's `klass:` is read where a bag was declared — which in practice is axn's own
        # canonicalized `{ klass: Array }`, since `_validate_coercion!` refuses `coerce:` on every container
        # earlier in the same pass. Compared with `equal?` and classified through `hash_or_nil`, because a guard
        # that dispatches `==`/`is_a?` on a caller's class is one the caller can switch off.
        def _declares_container_type_only?(declared)
          tokens = _declared_type_tokens_in(declared)
          return false if tokens.empty?

          tokens.all? { |token| CONTAINER_TYPE_TOKENS.any? { |container| container.equal?(token) } }
        end

        # The type tokens a FIELD declaration names, reading a `type:` bag's `klass:` where a bag was declared
        # and the bare spelling otherwise. One read serving every guard that asks something about the declared
        # type, so no two of THEM can disagree about which tokens one declaration names.
        #
        # It is not interchangeable with the `_declared_type_tokens` it wraps, and the difference is the whole
        # point: a bare Hash written where a type belongs is `[{…}]` to that one (a Hash is not unwrapped as a
        # union) and `[]` here (a bag with no `klass:` names no type). Callers deciding something about a FIELD's
        # declared type want this; callers reading a bag's own axis want that.
        #
        # Classified through `hash_or_nil`, never by dispatching to the value: the bag is the caller's, and a
        # Hash subclass denying its own class would otherwise pick how it is read.
        def _declared_type_tokens_in(declared)
          bag = Internal::ShapeGraph.hash_or_nil(declared)

          _declared_type_tokens(nil.equal?(bag) ? declared : bag[:klass])
        end
```

- [ ] **Step 5: Call it**

In `_parse_field_validations` (`lib/axn/core/contract.rb:3165`), immediately after the `_reject_validator_context_scope!` line:

```ruby
          # Beside the context-scope refusal, and for the same reason it sits here: both refuse a validator that
          # cannot do what the declaration says, ahead of every consumer of this bag. Placement relative to the
          # tolerance push-down is not load-bearing for THIS message (it carries only key names and the field
          # label, both push-down-invariant) but is for Task 3's, which quotes the declared set.
          _reject_container_position_validators!(validations, fields:)
```

- [ ] **Step 6: Run the spec, then the suite**

```bash
bundle exec rspec spec/axn/core/validations/container_position_validators_spec.rb
bundle exec rspec
bundle exec rubocop lib/axn/core/contract.rb
```

Expected: all pass. A `Metrics/MethodLength` or `Metrics/AbcSize` offense on `_parse_field_validations` means refactor rather than disable — the added line is one call, so an offense here is pre-existing headroom being spent; if it fires, extract the two new calls into one `_reject_incoherent_validators!(validations, fields:, tolerant:)` wrapper (Task 3 adds the second call anyway) and note it in the commit.

- [ ] **Step 7: Commit**

```bash
git add lib/axn/core/contract.rb spec/axn/core/validations/container_position_validators_spec.rb
git commit -m "PRO-3192: refuse to_s-targeted validators at a container position

format: on an Array matches the array's inspect form; numericality:, comparison:
and acceptance: accept no container value at all. Both are checks the declaration
cannot mean, so they are refused at declaration beside the context-scope refusal.
Stands down on a union carrying a scalar, an undeclared type, a pseudo-type token
and a disabled entry — under-restriction defers a diagnosis, over-restriction
rejects legal work.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 3: Refuse a value constraint nothing of the declared type can satisfy

This is the guard that turns Task 1 from a silent semantics flip into a teachable error: `type: Array, of: String, inclusion: { in: %w[a b] }` — the spelling existing users wrote for element-wise — becomes a declaration error naming the position they meant.

It covers **three** validators, not one. `inclusion:`, `acceptance:` and `comparison:` each compare the value against literals the declaration supplies — a set under `in:`/`within:`, a set under `accept:`, a bound under one of the six comparison keys — and each is broken the same way when nothing of the declared type could satisfy those literals. The latter two arrive from Task 2, where a blanket by-key refusal was measured wrong: in bare ActiveModel, `comparison: { equal_to: ["a"] }` accepts `["a"]`, `{ greater_than_or_equal_to: { "read" => true } }` accepts a Hash superset (`Hash#>=`), `{ greater_than: Set["a"] }` accepts a Set superset (`Set#>`), and `acceptance: { accept: [["a"]] }` accepts `["a"]`. What is broken about them is a literal of the wrong type, which is this question.

**Files:**
- Modify: `lib/axn/core/validation/base.rb` — `declared_set_collection`, `literal_set_members`, and `set_includes_nil?` rerouted through them (`:295-320`)
- Modify: `lib/axn/internal/reflection/schema.rb:1233-1236` — `inclusion_enum_values` reads the shared location helper
- Modify: `lib/axn/core/contract.rb` — `VALUE_CONSTRAINT_KEYS`, `DEFAULT_ACCEPTANCE_SET`, the guard and its two literal readers, and its call in `_parse_field_validations`
- Test: `spec/axn/core/validations/container_position_validators_spec.rb` (extend)

**Interfaces:**
- Consumes: `Axn::Validators::TypeValidator.value_matches?(value, klass:)`, `Axn::Validation::Base.validator_entries`, `Base.validator_entry_options`, and `_declared_type_tokens_in` (Task 2's).
- Produces: `Base.declared_set_collection(opt, keys:)` → the raw collection under the named keys (or the bare shorthand); `Base.literal_set_members(opt, keys:)` → an Array/Set of members, or `nil` when the set is one axn may not read; `VALUE_CONSTRAINT_KEYS`; `DEFAULT_ACCEPTANCE_SET`; `_reject_unsatisfiable_value_constraints!(validations, fields:, tolerant:)`; `_judgeable_set_members`; `_judgeable_constraint_literals`.

- [ ] **Step 1: Write the failing test**

Append to `spec/axn/core/validations/container_position_validators_spec.rb`:

```ruby
  describe "an inclusion: set no value of the declared type can satisfy is refused" do
    it "refuses the element-wise spelling on an Array field, naming the position" do
      expect { build_axn { expects :tags, type: Array, of: String, inclusion: { in: %w[a b] } } }
        .to raise_error(ArgumentError, %r{inclusion: on :tags can never match.*of:}m)
    end

    it "refuses the bare-Array shorthand identically" do
      expect { build_axn { expects :tags, type: Array, inclusion: %w[a b] } }
        .to raise_error(ArgumentError, /inclusion:/)
    end

    it "refuses an empty literal set, which nothing can satisfy at any type" do
      expect { build_axn { expects :tags, type: Array, inclusion: { in: [] } } }
        .to raise_error(ArgumentError, /inclusion:/)
    end

    it "refuses on a Hash field too" do
      expect { build_axn { expects :meta, type: Hash, inclusion: { in: %w[a b] } } }
        .to raise_error(ArgumentError, /inclusion:/)
    end

    # NOT container-only: the defect is the same shape on every type, and scoping to containers would leave a
    # structurally identical hole open everywhere else.
    it "refuses a scalar declaration whose set matches no value of the declared type" do
      expect { build_axn { expects :n, type: Integer, inclusion: { in: %w[1 2] } } }
        .to raise_error(ArgumentError, /inclusion:/)
    end

    it "admits a set whose members ARE of the declared type" do
      expect { build_axn { expects :tags, type: Array, inclusion: { in: [%w[a b]] } } }.not_to raise_error
      expect { build_axn { expects :n, type: Integer, inclusion: { in: [1, 2] } } }.not_to raise_error
    end

    it "admits a set where only one member matches — one passing value is enough" do
      expect { build_axn { expects :n, type: Integer, inclusion: { in: ["1", 2] } } }.not_to raise_error
    end

    it "admits a union type any member of which matches" do
      expect { build_axn { expects :f, type: [String, Array], inclusion: { in: %w[a b] } } }.not_to raise_error
    end

    it "stands down on a dynamically-sourced set, which reflection may not read" do
      expect { build_axn { expects :tags, type: Array, inclusion: { in: :allowed_tags } } }.not_to raise_error
      expect { build_axn { expects :tags, type: Array, inclusion: { in: -> { [] } } } }.not_to raise_error
    end

    it "stands down on an Array-subclass set, judged by the same exact-class rule reflection uses" do
      subclass = Class.new(Array)
      set = subclass.new
      set << "a"

      expect { build_axn { expects :tags, type: Array, inclusion: { in: set } } }.not_to raise_error
    end

    it "stands down on a Range set at a scalar position, where cross-type comparison really works" do
      # `(1.0..5.0).cover?(3)` is true, so judging a Range's bounds against a scalar type would falsely refuse.
      expect { build_axn { expects :n, type: Integer, inclusion: { in: 1..5 } } }.not_to raise_error
      expect { build_axn { expects :n, type: Integer, inclusion: { in: 1.0..5.0 } } }.not_to raise_error
    end

    it "refuses a Range set at a container position, where nothing can be a member" do
      # `<=>` is nil across unrelated classes, so `(1..5).cover?([1, 2])` is false however the array is spelled.
      # Before the positional rule this declaration accepted `[1, 2]` element-wise while emitting no constraint
      # at all — the schema said nothing and the runtime rejected everything.
      expect { build_axn { expects :nums, type: Array, of: Integer, inclusion: { in: 1..5 } } }
        .to raise_error(ArgumentError, /inclusion:/)
      expect { build_axn { expects :m, type: Hash, inclusion: { in: 1..5 } } }
        .to raise_error(ArgumentError, /inclusion:/)
    end

    it "admits a Range whose bounds ARE the declared container, which can genuinely match" do
      # `(["a"]..["z"]).cover?(["b"])` is true, so the bounds decide rather than the Range-ness.
      expect { build_axn { expects :tags, type: Array, inclusion: { in: ["a"]..["z"] } } }.not_to raise_error
    end

    it "stands down on an undeclared type and on a pseudo-type token" do
      expect { build_axn { expects :f, inclusion: { in: %w[a b] } } }.not_to raise_error
      expect { build_axn { expects :f, type: :params, inclusion: { in: %w[a b] } } }.not_to raise_error
    end

    it "stands down under tolerance, where nil is a passing value" do
      expect { build_axn { expects :tags, type: Array, inclusion: { in: %w[a b] }, optional: true } }.not_to raise_error
      expect { build_axn { expects :tags, type: Array, inclusion: { in: %w[a b] }, allow_nil: true } }.not_to raise_error
    end

    it "refuses a gated entry too — a gate removes the check, it does not give the set a reading" do
      # Reflection is static-maximal (it treats every gate as open), so a gated can-never-match set still
      # emits `{type: "array", enum: ["a","b"]}` — the unsatisfiable node the corollary forbids. Closed the
      # check enforces nothing; open it rejects everything. Incoherent either way.
      expect { build_axn { expects :tags, type: Array, inclusion: { in: %w[a b], if: :flag? } } }
        .to raise_error(ArgumentError, /inclusion:/)
      expect { build_axn { expects :tags, type: Array, inclusion: { in: %w[a b] }, if: :flag? } }
        .to raise_error(ArgumentError, /inclusion:/)
    end

    it "leaves the tolerance case satisfiable on both sides, which is why tolerance stands the guard down" do
      action = build_axn { expects :tags, type: Array, inclusion: { in: %w[a b] }, optional: true }
      prop = action.input_schema[:properties][:tags]

      # The emitted node admits exactly `null`; the runtime admits exactly nil. Both sides agree, and the node
      # is satisfiable — the contract is pointless, not broken, so it is not this guard's business.
      expect(prop[:type]).to eq(%w[array null])
      expect(prop[:enum]).to include(nil)
      expect(action.call.ok?).to be(true)
      expect(action.call(tags: %w[a b]).ok?).to be(false)
    end
  end

  describe "comparison: and acceptance: are judged by their literals, not refused by key" do
    it "refuses a comparison bound of the wrong type" do
      # `["a"] > 1` raises NoMethodError on every call today, so refusing it at declaration is a strict
      # improvement over the status quo.
      expect { build_axn { expects :tags, type: Array, comparison: { greater_than: 1 } } }
        .to raise_error(ArgumentError, %r{comparison:})
    end

    it "admits a comparison bound that IS the declared container, which really works" do
      action = build_axn { expects :tags, type: Array, comparison: { equal_to: ["a"] } }

      expect(action.call(tags: ["a"]).ok?).to be(true)
      expect(action.call(tags: ["b"]).ok?).to be(false)
    end

    it "admits a Hash bound, which compares by subset" do
      action = build_axn { expects :meta, type: Hash, comparison: { greater_than_or_equal_to: { "read" => true } } }

      expect(action.call(meta: { "read" => true, "w" => 1 }).ok?).to be(true)
    end

    it "stands down on a Symbol or Proc bound, which ActiveModel resolves per call" do
      expect { build_axn { expects :tags, type: Array, comparison: { equal_to: :allowed } } }.not_to raise_error
      expect { build_axn { expects :tags, type: Array, comparison: { equal_to: -> (_r) { ["a"] } } } }.not_to raise_error
    end

    it "refuses acceptance: whose effective set holds nothing of the declared type" do
      # `acceptance: true` compares against ActiveModel's own ["1", true].
      expect { build_axn { expects :tags, type: Array, acceptance: true } }
        .to raise_error(ArgumentError, %r{acceptance:})
      expect { build_axn { expects :n, type: Integer, acceptance: true } }
        .to raise_error(ArgumentError, %r{acceptance:})
    end

    it "admits acceptance: whose accept set names the declared container" do
      action = build_axn { expects :tags, type: Array, acceptance: { accept: [["a"]] } }

      expect(action.call(tags: ["a"]).ok?).to be(true)
    end

    it "admits acceptance: true on a String, where \"1\" is a member of the default set" do
      expect { build_axn { expects :flag, type: String, acceptance: true } }.not_to raise_error
    end
  end

  describe "Validation::Base.literal_set_members" do
    it "reads the hash long form, both keys, and the bare shorthand" do
      expect(Axn::Validation::Base.literal_set_members({ in: %w[a b] })).to eq(%w[a b])
      expect(Axn::Validation::Base.literal_set_members({ within: %w[a b] })).to eq(%w[a b])
      expect(Axn::Validation::Base.literal_set_members(%w[a b])).to eq(%w[a b])
    end

    it "reads a Set, and a Hash's keys" do
      expect(Axn::Validation::Base.literal_set_members({ in: Set.new(%w[a]) })).to eq(Set.new(%w[a]))
      expect(Axn::Validation::Base.literal_set_members({ in: { "a" => 1 } })).to eq(%w[a])
    end

    it "answers nil for a set it may not read" do
      expect(Axn::Validation::Base.literal_set_members({ in: :dynamic })).to be_nil
      expect(Axn::Validation::Base.literal_set_members({ in: -> { [] } })).to be_nil
      expect(Axn::Validation::Base.literal_set_members({ in: 1..5 })).to be_nil
      expect(Axn::Validation::Base.literal_set_members({ in: Class.new(Array).new })).to be_nil
    end
  end
```

- [ ] **Step 1b: Convert the Task 1 example this task's guard now refuses**

Task 1 left an example that declares exactly what this task refuses, so the file lands red unless it is
converted first. In the `describe "inclusion: constrains the value at its own position"` block, the example
`"does not distribute the set over an Array's elements"` declares
`expects :tags, type: Array, inclusion: { in: %w[a b] }` — a set holding no Array, which Step 4's guard raises
on. Replace that example's body with a mixed set, which survives the guard (one member IS an Array) and still
discriminates against the old element-wise reading. Both assertions verified against the post-Task-1 tree:

```ruby
    it "does not distribute the set over an Array's elements" do
      # A mixed set: one member is the array that should match whole-value, one is the String an element-wise
      # reading would have matched. The second assertion is what fails under a distributing reading.
      action = build_axn { expects :tags, type: Array, inclusion: { in: [%w[a b], "a"] } }

      expect(action.call(tags: %w[a b]).ok?).to be(true)
      expect(action.call(tags: %w[a]).ok?).to be(false)
    end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bundle exec rspec spec/axn/core/validations/container_position_validators_spec.rb -e "no value of the declared type"
bundle exec rspec spec/axn/core/validations/container_position_validators_spec.rb -e "literal_set_members"
```

Expected: the `raise_error` examples FAIL with nothing raised; `literal_set_members` FAILS with `NoMethodError`. Every stand-down example PASSES already.

- [ ] **Step 3: Extract the two shared set readers**

In `lib/axn/core/validation/base.rb`, above `set_includes_nil?`:

```ruby
      # WHERE a clusivity set lives, for one validator entry: under one of `keys:` in the hash long form
      # (`in:`/`within:` for inclusion/exclusion, `accept:` for acceptance), or the bare collection itself in
      # the shorthand (`inclusion: %w[a b]`). The two enforce the same set at runtime, so every consumer reads
      # them identically. THE single definition of that location, shared by the nil-membership judgment below,
      # the declaration-time satisfiability guard (contract.rb `_reject_unsatisfiable_value_constraints!`), and schema
      # reflection's `enum` (`Schema.inclusion_enum_values`), so no two can disagree about which collection one
      # entry names.
      def self.declared_set_collection(opt, keys: %i[in within])
        return keys.filter_map { |key| opt[key] }.first if opt.is_a?(Hash)

        opt
      end

      # The MEMBERS of a clusivity set, when they are members axn may read: a literal in-memory Array or Set, or
      # a Hash (whose `include?` tests KEYS, so the keys are the members). Nil — "can't tell" — for everything
      # else, because a judgment on a set must stay side-effect-free: a dynamic collection (a Symbol or Proc
      # resolved against the record at validation time, an `ActiveRecord::Relation` whose `include?` would query
      # the database) is never read, and neither is an Array SUBCLASS, which could override the traversal.
      # Exact-class throughout (`instance_of?`), for the reason reflection's own read is (PRO-2944).
      #
      # THE single definition of "which members can be judged", shared by the nil-membership judgment below and
      # by the declaration-time satisfiability guard, so the two cannot read one declaration differently.
      def self.literal_set_members(opt, keys: %i[in within])
        collection = declared_set_collection(opt, keys:)
        members = collection.instance_of?(Hash) ? collection.keys : collection
        return nil unless members.instance_of?(Array) || (defined?(Set) && members.instance_of?(Set))

        members
      rescue StandardError
        nil
      end
```

Then reroute `set_includes_nil?` onto it, replacing its own collection/members read (its `Range` early-return stays — a Range's bounds are Comparable, so nil is never a member, and that is an answer rather than an unknown):

```ruby
      def self.set_includes_nil?(opt, keys: %i[in within])
        return false if declared_set_collection(opt, keys:).is_a?(Range)

        members = literal_set_members(opt, keys:)
        return nil if members.nil?

        members.any? { |element| element.equal?(nil) }
      rescue StandardError
        nil
      end
```

And in `lib/axn/internal/reflection/schema.rb`, `inclusion_enum_values` reads the shared location while keeping its own narrower admissibility rule (exact `Array` only — it maps and each-es the members into the emitted document):

```ruby
        def inclusion_enum_values(inclusion)
          values = Axn::Validation::Base.declared_set_collection(inclusion)
          values if values.instance_of?(Array)
        end
```

- [ ] **Step 4: Write the guard**

In `lib/axn/core/contract.rb`, after `_reject_container_position_validators!`:

```ruby
        # An `inclusion:` set no value of the declared type can be a member of — a contract that rejects every
        # input while looking like a constraint. The common spelling of it is the one this ticket retires:
        # `type: Array, of: String, inclusion: { in: %w[a b] }` used to distribute over the elements, and under
        # the positional rule it asks for an array that IS the string "a", so it is refused with the position
        # named rather than silently rejecting every call.
        #
        # NOT container-only: `type: Integer, inclusion: { in: %w[1 2] }` is unsatisfiable for the same reason
        # and is as broken, so scoping this to containers would leave the identical hole open on every other
        # type.
        #
        # Membership is judged by the runtime's own matcher (`TypeValidator.value_matches?`), so the guard cannot
        # disagree with the check it is predicting — the guard/projection rule in AGENTS.md. It stands down
        # wherever a passing value survives the check as written: a set it may not read, a type it cannot judge,
        # or a tolerance flag, under which nil passes and the emitted node stays satisfiable (`type:
        # ["array","null"]` with nil in the enum).
        #
        # An `if:`/`unless:` gate does NOT stand it down, and that asymmetry is the point: reflection is
        # static-maximal, so a gated can-never-match set still emits `{type: "array", enum: [...]}` — exactly
        # the unsatisfiable node the corollary forbids. A gate removes the check rather than giving the set a
        # reading: closed it enforces nothing, open it rejects everything.
        # The option keys each value-comparing validator reads its literals from. One judgment serves all three
        # because they break the same way. Comparison's six are ActiveModel's own (activemodel 7.2.2.2,
        # comparison.rb COMPARE_CHECKS).
        VALUE_CONSTRAINT_KEYS = {
          inclusion: %i[in within],
          acceptance: %i[accept],
          comparison: %i[equal_to other_than greater_than greater_than_or_equal_to less_than less_than_or_equal_to],
        }.freeze

        # AcceptanceValidator's own default set, used when an entry names none (`acceptance: true`) — so
        # `type: Integer, acceptance: true` is judged against what it will really be compared with and refused,
        # while `type: String, acceptance: true` stands down, because `"1"` is a String.
        DEFAULT_ACCEPTANCE_SET = ["1", true].freeze

        def _reject_unsatisfiable_value_constraints!(validations, fields:, tolerant:)
          return if tolerant

          klasses = _judgeable_type_klasses(validations[:type])
          return if klasses.empty?

          entries = Axn::Validation::Base.validator_entries(validations)
          VALUE_CONSTRAINT_KEYS.each do |key, option_keys|
            entry = entries[key]
            next unless entry

            opts = Axn::Validation::Base.validator_entry_options(entry)
            next if opts[:allow_nil] || opts[:allow_blank]

            literals = _judgeable_constraint_literals(key, entry, option_keys, klasses)
            next if literals.nil?
            next if literals.any? { |literal| klasses.any? { |klass| Validators::TypeValidator.value_matches?(literal, klass:) } }

            raise ArgumentError,
                  "#{key}: on #{_declared_fields_label(fields)} can never match — nothing it compares against " \
                  "is a #{klasses.map { |klass| _inspect_field_name(klass) }.join(' or ')}, so every value is " \
                  "rejected. A validator constrains the value at the position it is declared at: compare " \
                  "against literals of the declared type, and for a constraint on a container's CONTENTS " \
                  "express it as `validate: ->(value) { ... }` (a per-element spelling inside `of:` is not " \
                  "supported yet — PRO-3193)."
          end
        end

        # The literals one value-comparing entry will be judged against, or nil for an entry that cannot be
        # judged at declaration. Each validator names them differently, and each has its own unjudgeable shapes:
        #
        # `comparison:` names one bound per key, and ActiveModel RESOLVES a Symbol or Proc bound against the
        # record at validation time (`ResolveValue`) — measured: `comparison: { equal_to: :allowed }` passes when
        # that method returns the value — so a declaration carrying one is unjudgeable and stands down. Bounds are
        # read by `key?` rather than truthiness, since `equal_to: false` is a real bound.
        #
        # `acceptance:` names a set under `accept:`, defaulting to ActiveModel's own when absent. A bare scalar
        # (`accept: "yes"`) is not a literal set the shared reader will read, so it stands down.
        #
        # `inclusion:` delegates to the set reader, which also judges a Range's bounds at a container position.
        def _judgeable_constraint_literals(key, entry, option_keys, klasses)
          return _judgeable_set_members(entry, klasses) if key == :inclusion

          opts = Axn::Validation::Base.validator_entry_options(entry)
          if key == :acceptance
            return DEFAULT_ACCEPTANCE_SET.dup unless Internal::ShapeGraph.carries_key?(opts, :accept)

            return Axn::Validation::Base.literal_set_members(opts, keys: %i[accept])
          end

          bounds = option_keys.select { |option| opts.key?(option) }.map { |option| opts[option] }
          return nil if bounds.empty?
          return nil if bounds.any? { |bound| bound.is_a?(::Symbol) || bound.is_a?(::Proc) }

          bounds
        end

        # The declared types this guard can judge membership against: every token a real Class or Module. Empty
        # for an undeclared type and for a declaration naming any pseudo-type (`:boolean`/`:uuid`/`:params`),
        # whose admissible values are not a class membership question — both stand the guard down.
        #
        # Classified with `case`/`when Module`, which does not call the token's own `is_a?`.
        def _judgeable_type_klasses(declared)
          tokens = _declared_type_tokens_in(declared)
          return [] if tokens.empty?

          tokens.all? { |token| case token when ::Module then true else false end } ? tokens : []
        end

        # The set members whose type membership can be judged, or nil for a set that cannot be judged at all.
        # Usually that is `Base.literal_set_members` — a literal in-memory Array/Set, never an Array subclass or
        # a dynamic source, since judging one would run the caller's own traversal.
        #
        # A RANGE is the one non-literal set that can still be judged, and only at a container position: a Range
        # decides membership with `<=>`, which is nil across unrelated classes, so `(1..5).cover?([1, 2])` is
        # false however the array is spelled — while `(["a"]..["z"]).cover?(["b"])` is TRUE, because Arrays
        # compare with Arrays. So the BOUNDS are what decide, not the Range-ness, and they are exactly what the
        # membership test wants. Deliberately not extended past a container position: `(1.0..5.0).cover?(3)` is
        # true, so a Float-bounded Range on `type: Integer` is satisfiable and judging its bounds would falsely
        # refuse it. A beginless-and-endless Range yields no bounds and stands the guard down.
        def _judgeable_set_members(entry, klasses)
          collection = Axn::Validation::Base.declared_set_collection(entry)
          return Axn::Validation::Base.literal_set_members(entry) unless collection.is_a?(::Range)
          return nil unless klasses.all? { |klass| CONTAINER_TYPE_TOKENS.any? { |container| container.equal?(klass) } }

          bounds = [collection.begin, collection.end].compact
          bounds.empty? ? nil : bounds
        end
```

- [ ] **Step 5: Call it**

In `_parse_field_validations`, immediately after the `_reject_container_position_validators!` call added in Task 2:

```ruby
          # `tolerant` is computed further down for the push-down; it is passed here explicitly rather than read
          # off the entries, because the tolerance flags are declaration KWARGS at this point and the push-down
          # that writes them into each entry has not run yet.
          _reject_unsatisfiable_value_constraints!(validations, fields:, tolerant: allow_blank || allow_nil)
```

- [ ] **Step 6: Run the spec, the suite, and the downstream check**

```bash
bundle exec rspec spec/axn/core/validations/container_position_validators_spec.rb
bundle exec rspec
bundle exec rubocop lib/axn/core/contract.rb lib/axn/core/validation/base.rb lib/axn/internal/reflection/schema.rb
```

Then the blast-radius check the spec asks for, because this guard can newly reject already-dead declarations in a consumer:

```bash
grep -rn "inclusion:" ~/code/core/app ~/code/core/lib 2>/dev/null | grep -v spec | head -40
```

Read each hit against the rule (is every member an instance of the declared type?). If any legitimate declaration would now raise, stop and report it rather than widening the guard — this task is deliberately its own commit so it can be reverted without taking Task 1's rule with it.

- [ ] **Step 7: Commit**

```bash
git add lib/axn/core/contract.rb lib/axn/core/validation/base.rb lib/axn/internal/reflection/schema.rb \
        spec/axn/core/validations/container_position_validators_spec.rb
git commit -m "PRO-3192: refuse a value constraint nothing of the declared type can satisfy

The element-wise spelling users wrote (type: Array, inclusion: { in: %w[a b] })
now asks for an array that IS the string \"a\", so it is refused at declaration
with the position named instead of rejecting every call silently. One judgment
covers inclusion:, acceptance: and comparison: — all three compare the value
against declared literals, and comparison:/acceptance: moved here from a blanket
by-key refusal that was measured wrong (a container-typed bound or accept set
really does work). Judged by the
runtime's own TypeValidator.value_matches?, on literal sets only, standing down
under tolerance, an unjudgeable type, or a set reflection may not read — but NOT
under an if:/unless: gate, since reflection is static-maximal and a gated
can-never-match set still emits an unsatisfiable node.

Extracts Base.declared_set_collection / literal_set_members so the nil-membership
judgment, this guard, and Schema.inclusion_enum_values read one set one way.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 4: Emit the size ceiling

**Files:**
- Modify: `lib/axn/core/validation/base.rb` — `declared_length_ceiling`, `emittable_length_ceiling?`, beside `declared_length_floor` (`:363-380`)
- Modify: `lib/axn/internal/reflection/schema.rb` — `SIZE_CEILING_KEYS` (beside `SIZE_CONSTRAINT_KEYS`, `:63-67`), `size_ceiling_key_for`, `declared_size_maximum`, and both size-application methods (`:1317-1343`)
- Test: `spec/axn/internal/reflection/schema_spec.rb` (extend)

**Interfaces:**
- Consumes: `Base.declared_length_checks`, `Schema#effective_entry_options`, `Schema#shared_validation_options`.
- Produces: `Base.declared_length_ceiling(entry_opts)` → an Integer, `nil`, or `:unverifiable`; `Base.emittable_length_ceiling?(ceiling)`; `Schema#declared_size_maximum(config)`.

- [ ] **Step 1: Write the failing test**

Append to `spec/axn/internal/reflection/schema_spec.rb`:

```ruby
  # The ceiling twin of the emptiness floor. Emitting it only shrinks the schema-valid set, so it preserves the
  # documented direction (docs/reference/class.md:270 — stricter than the runtime, never looser) by construction.
  describe "size ceilings" do
    it "emits maxItems for an Array length maximum" do
      action = build_axn { expects :tags, type: Array, of: String, length: { maximum: 2 } }

      expect(action.input_schema[:properties][:tags][:maxItems]).to eq(2)
    end

    it "emits maxProperties for a Hash length maximum" do
      action = build_axn { expects :meta, type: Hash, length: { maximum: 3 } }

      expect(action.input_schema[:properties][:meta][:maxProperties]).to eq(3)
    end

    it "emits maxLength for a String length maximum" do
      action = build_axn { expects :name, type: String, length: { maximum: 5 } }

      expect(action.input_schema[:properties][:name][:maxLength]).to eq(5)
    end

    it "emits both bounds from a range" do
      prop = build_axn { expects :tags, type: Array, length: { in: 2..4 } }.input_schema[:properties][:tags]

      expect(prop[:minItems]).to eq(2)
      expect(prop[:maxItems]).to eq(4)
    end

    it "counts one less for an exclusive range end, as ActiveModel does" do
      prop = build_axn { expects :tags, type: Array, length: { in: 2...4 } }.input_schema[:properties][:tags]

      expect(prop[:maxItems]).to eq(3)
    end

    it "emits both bounds from an exact length" do
      prop = build_axn { expects :tags, type: Array, length: { is: 2 } }.input_schema[:properties][:tags]

      expect(prop[:minItems]).to eq(2)
      expect(prop[:maxItems]).to eq(2)
    end

    it "emits a zero ceiling, which names size 0 as the only admissible size" do
      prop = build_axn { expects :tags, type: Array, length: { maximum: 0 }, allow_empty: true }.input_schema[:properties][:tags]

      expect(prop[:maxItems]).to eq(0)
    end

    it "emits the ceiling on every size-bearing branch of a union" do
      prop = build_axn { expects :f, type: [String, Array], length: { maximum: 2 } }.input_schema[:properties][:f]

      expect(prop[:anyOf]).to include(a_hash_including(type: "string", maxLength: 2))
      expect(prop[:anyOf]).to include(a_hash_including(type: "array", maxItems: 2))
    end

    it "emits no ceiling for a per-call bound ActiveModel resolves against the record" do
      prop = build_axn { expects :tags, type: Array, length: { maximum: :max_tags } }.input_schema[:properties][:tags]

      expect(prop).not_to have_key(:maxItems)
    end

    it "emits no ceiling for an infinite one, which no finite number expresses" do
      prop = build_axn { expects :tags, type: Array, length: { maximum: Float::INFINITY } }.input_schema[:properties][:tags]

      expect(prop).not_to have_key(:maxItems)
    end

    it "emits no ceiling for a type with no size" do
      prop = build_axn { expects :n, type: Integer, length: { maximum: 2 } }.input_schema[:properties][:n]

      expect(prop).not_to have_key(:maxItems)
      expect(prop).not_to have_key(:maxLength)
    end

    it "emits no ceiling where the declaration names none" do
      prop = build_axn { expects :tags, type: Array, of: String }.input_schema[:properties][:tags]

      expect(prop).not_to have_key(:maxItems)
      expect(prop[:minItems]).to eq(1)
    end
  end

  describe "Validation::Base.declared_length_ceiling" do
    it "reads a maximum, an exact length, and a range end" do
      expect(Axn::Validation::Base.declared_length_ceiling({ maximum: 2 })).to eq(2)
      expect(Axn::Validation::Base.declared_length_ceiling({ is: 3 })).to eq(3)
      expect(Axn::Validation::Base.declared_length_ceiling({ in: 1..4 })).to eq(4)
    end

    it "answers nil where the ceiling is open" do
      expect(Axn::Validation::Base.declared_length_ceiling({ minimum: 2 })).to be_nil
      expect(Axn::Validation::Base.declared_length_ceiling({})).to be_nil
    end

    it "answers :unverifiable for a bound ActiveModel resolves per call" do
      expect(Axn::Validation::Base.declared_length_ceiling({ maximum: :max })).to eq(:unverifiable)
    end

    it "admits only a non-negative Integer as emittable" do
      expect(Axn::Validation::Base.emittable_length_ceiling?(0)).to be(true)
      expect(Axn::Validation::Base.emittable_length_ceiling?(2)).to be(true)
      expect(Axn::Validation::Base.emittable_length_ceiling?(Float::INFINITY)).to be(false)
      expect(Axn::Validation::Base.emittable_length_ceiling?(2.5)).to be(false)
      expect(Axn::Validation::Base.emittable_length_ceiling?(:unverifiable)).to be(false)
      expect(Axn::Validation::Base.emittable_length_ceiling?(nil)).to be(false)
    end
  end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bundle exec rspec spec/axn/internal/reflection/schema_spec.rb -e "size ceilings"
bundle exec rspec spec/axn/internal/reflection/schema_spec.rb -e "declared_length_ceiling"
```

Expected: the emission examples FAIL (`maxItems` absent), the reader examples FAIL with `NoMethodError`. The three "emits no ceiling" examples PASS already.

- [ ] **Step 3: Add the two readers**

In `lib/axn/core/validation/base.rb`, after `declared_length_floor` and before `emittable_length_floor?`:

```ruby
      # The largest size a `length:` entry admits, read from the checks it runs — the twin of the floor above,
      # off the same `declared_length_checks`, so an `in:`/`within:` range (exclusive end counted one less) and
      # an `is:` (which names both bounds) resolve identically for both. Returns nil when the entry leaves the
      # ceiling open (a `minimum:` alone, or no size key at all), and `:unverifiable` for a ceiling ActiveModel
      # resolves per call (a Symbol/Proc).
      #
      # Blank-tolerance is not consulted, and the floor's careful reasoning about it does not transfer: a
      # tolerated empty value measures 0, which every non-negative ceiling already admits, so a ceiling is exact
      # whether or not an empty value stands the entry aside.
      #
      # THE single definition of "how large may this length: entry be", read by schema reflection's
      # `maxItems`/`maxProperties`/`maxLength` emission.
      def self.declared_length_ceiling(entry_opts)
        checks = declared_length_checks(entry_opts)

        ceiling = checks[:is] || checks[:maximum]
        return :unverifiable unless ceiling.nil? || ceiling.is_a?(Numeric)

        ceiling
      end

      # Whether a ceiling read above is one a JSON Schema `maxItems`/`maxProperties`/`maxLength` can carry: a
      # non-negative Integer. `0` counts — it names size 0 as the only admissible size, which is a constraint a
      # caller can act on. `Float::INFINITY` (ActiveModel's spelling for "no ceiling") and a fractional bound
      # (which its LengthValidator refuses outright at validation time) are both uncarryable, exactly as they
      # are for the floor.
      def self.emittable_length_ceiling?(ceiling) = ceiling.is_a?(Integer) && !ceiling.negative?
```

- [ ] **Step 4: Emit it**

In `lib/axn/internal/reflection/schema.rb`, after `SIZE_CONSTRAINT_KEYS` (`:63-67`):

```ruby
        # The ceiling half of the same mapping. A type absent here has no size to bound.
        SIZE_CEILING_KEYS = {
          "array" => :maxItems,
          "object" => :maxProperties,
          "string" => :maxLength,
        }.freeze
```

Replace `apply_size_constraints!` and `apply_member_size_constraints` (`:1317-1334`) with:

```ruby
        def apply_size_constraints!(prop, config)
          minimum = declared_size_minimum(config)
          maximum = declared_size_maximum(config)
          return if minimum.nil? && maximum.nil?

          if prop[:anyOf]
            prop[:anyOf] = apply_member_size_constraints(prop[:anyOf], minimum, maximum)
          else
            prop.merge!(size_bounds_for(prop[:type], minimum, maximum))
          end
        end

        # A union emits one branch per member type instead of a single `type:`, and the validators reject an
        # out-of-bounds value whichever branch it takes — so each bound belongs on every branch that can carry
        # it. A branch with no size (an `integer` member) and the nullability branch carry none, decided by the
        # same per-type key lookup the single-type path uses.
        def apply_member_size_constraints(members, minimum, maximum)
          members.map do |member|
            bounds = size_bounds_for(member[:type], minimum, maximum)
            bounds.empty? ? member : member.merge(bounds)
          end
        end

        # The size keywords one emitted type can carry, for the bounds this field declares. Empty for a type
        # with no size, which is what keeps a bound off an `integer` branch and off `"null"`.
        def size_bounds_for(type, minimum, maximum)
          bounds = {}
          bounds[size_constraint_key_for(type)] = minimum if minimum && size_constraint_key_for(type)
          bounds[size_ceiling_key_for(type)] = maximum if maximum && size_ceiling_key_for(type)
          bounds
        end

        # The JSON Schema ceiling key for an emitted type, or nil for a type with no size. Reads the single-type
        # String and the `[T, "null"]` nullable pair alike, exactly as the floor's own key lookup does.
        def size_ceiling_key_for(type)
          Array(type).filter_map { |t| SIZE_CEILING_KEYS[t] }.first
        end
```

And beside `declared_size_minimum`:

```ruby
        # The largest size this field's validators admit, or nil when they bound it nowhere. Simpler than the
        # floor in two ways, both because a ceiling has no interaction with emptiness: only `length:` can name
        # one (presence and the emptiness axis impose floors, never ceilings), and blank-tolerance cannot
        # loosen one (an empty value measures 0, which every emittable ceiling admits). A GATED entry is counted
        # as if its gate were open, the static-maximal policy every constraint here follows.
        def declared_size_maximum(config)
          length = effective_entry_options(config.validations[:length], shared_validation_options(config))
          declared = Axn::Validation::Base.declared_length_ceiling(length)

          declared if Axn::Validation::Base.emittable_length_ceiling?(declared)
        end
```

- [ ] **Step 5: Run the spec, then the suite**

```bash
bundle exec rspec spec/axn/internal/reflection/schema_spec.rb
bundle exec rspec
bundle exec rubocop lib/axn/internal/reflection/schema.rb lib/axn/core/validation/base.rb
```

Expected: all pass. Watch for a property-count or collision spec failing — `count_emitted_properties!` counts properties rather than keywords, so a new keyword should not move it; if one does, read the failure before editing it.

- [ ] **Step 6: Commit**

```bash
git add lib/axn/core/validation/base.rb lib/axn/internal/reflection/schema.rb spec/axn/internal/reflection/schema_spec.rb
git commit -m "PRO-3192: emit maxItems/maxProperties/maxLength

declared_length_floor had no twin, so a declared ceiling reflected nowhere at any
position. Adds the reader beside it, held to the same conservatism (non-negative
Integer only; :unverifiable for a per-call bound, Float::INFINITY uncarryable),
and emits it on a single type and on every size-bearing anyOf branch. A ceiling
only shrinks the schema-valid set, so the documented stricter-than-runtime
direction is preserved by construction.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 5: Write the rule down

**Files:**
- Modify: `lib/axn/core/validation/validators/validate_validator.rb:14-27` and `:33-41` — both messages advise `inclusion: { in: [...] }` as the fix
- Modify: `AGENTS.md:108-115` (the guards-and-projections bullet) and the validation section
- Modify: `internal-docs/agent-notes/guards-and-projections.md`
- Modify: `docs/reference/class.md` — the `of:` grammar (`:92-105`), the size-constraint line (`:235`), and the validator-kwarg row (`:23`)
- Modify: `CHANGELOG.md` (the `## Unreleased` section at `:3`)
- Test: `spec/axn/core/validations/container_position_validators_spec.rb` (extend, for the message change only)

**Interfaces:** none — documentation, plus one message string.

- [ ] **Step 1: Write the failing test for the message**

Append to `spec/axn/core/validations/container_position_validators_spec.rb`:

```ruby
  describe "validate:'s misuse guard does not advise a fix that is itself refused" do
    it "does not promise a bare inclusion: as the fix for a container" do
      # `validate: { inclusion: ... }` enforces nothing, so it is refused — but its advice used to be "declare
      # inclusion: directly", which at a container position now raises on its own.
      expect { build_axn { expects :tags, type: Array, validate: { inclusion: { in: %w[a b] } } } }
        .to raise_error(ArgumentError, /constrains the value at that position/)
    end
  end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bundle exec rspec spec/axn/core/validations/container_position_validators_spec.rb -e "does not advise a fix"
```

Expected: FAIL — the raised message is the current one, which says "declare it directly (e.g. `inclusion: { in: [...] }`)" and matches no such phrase.

- [ ] **Step 3: Amend both messages**

In `lib/axn/core/validation/validators/validate_validator.rb`, in `apply_syntactic_sugar`, replace the trailing sentence of the raise:

```ruby
                  "(keys: #{value.keys.inspect}). If you meant a standard validation such as an " \
                  "allowed-value set, declare it directly (e.g. `inclusion: { in: [...] }`), which constrains " \
                  "the value at that position — on a container-typed field that is the container itself, not " \
                  "its contents."
```

And the same clause in `check_validity!`:

```ruby
              "`validate:` requires a callable under `:with` (`validate: { with: <callable> }`) or the bare form " \
              "`validate: ->(value) { ... }`. For a standard validation such as an allowed-value set, use the " \
              "validator directly (e.g. `inclusion: { in: [...] }`), which constrains the value at that " \
              "position — on a container-typed field that is the container itself, not its contents."
```

- [ ] **Step 4: Run the spec**

```bash
bundle exec rspec spec/axn/core/validations/container_position_validators_spec.rb
bundle exec rspec spec/axn/core/validations/validate_lambda_misattribution_spec.rb
```

Expected: PASS. The misattribution spec may assert the old wording — if it does, update it to the new sentence; that is the one place a message assertion is the point of the test.

- [ ] **Step 5: State the rule in `AGENTS.md`**

Add to the validation guidance, as its own bullet:

```markdown
- **A validator constrains the value at the position it is declared at.** `expects` names the field's own
  value; `of:` descends a level (an Array's element, a map's `keys:`/`values:` axis); each rung of a nested
  bag names its own. So `inclusion:` on a `type: Array` field constrains the ARRAY, and a constraint on the
  elements goes in `of:`. ActiveModel's `Clusivity` special-cases an Array value and distributes the set over
  its elements; axn's own `Inclusion`/`ExclusionValidator` (constants on `Validation::Base`) drop that branch,
  because the distributing reading has no schema spelling, inverts to nonsense under exclusion, and stops at
  depth 1. A validator with no reading at a container position is refused at declaration
  (`_reject_container_position_validators!`), never left enforcing something no rule states. The rule governs
  axn CONTRACTS: a consuming app's own `validates` is untouched, and so is `Axn::FormObject`, which is an
  ActiveModel model whose `validates` axn only wraps to auto-add `attr_accessor`s — the same boundary, stated
  because the class ships with axn and the difference would otherwise be discovered rather than read.
```

And extend the guards-and-projections bullet (`:108-115`) with the corollary:

```markdown
  The projection of a satisfiable contract must itself be satisfiable: "biased stricter" (see
  `docs/reference/class.md`) licenses a node admitting FEWER values, never one admitting NONE — an
  unsatisfiable node is the signature of the runtime and the emitter disagreeing about what a validator
  targets, and it satisfies a directional invariant vacuously.
```

- [ ] **Step 6: Add the case study to `internal-docs/agent-notes/guards-and-projections.md`**

Append a section:

```markdown
## An unsatisfiable projection satisfies a directional invariant vacuously

Reflection is documented as biased STRICTER than the runtime — schema-valid ⇒ runtime-valid
(`docs/reference/class.md`, `docs/recipes/authoring-tool-adapters.md`), with two documented looser exceptions.
A directional rule alone does not catch the worst kind of divergence, because a node admitting NO value is
maximally strict and therefore trivially "not looser".

`inclusion: { in: %w[a b] }` on a `type: Array` field emitted `{type: "array", enum: ["a","b"]}` — nothing is
both an array and the string `"a"` — while the runtime accepted `["a","b"]` by distributing the set over the
elements (ActiveModel's `Clusivity`). Every value the runtime accepted, the document rejected; the invariant
as written did not name it, because the schema was strict rather than loose.

So the invariant has a corollary: the projection of a satisfiable contract must itself be satisfiable. And the
fix ran the other way from the schema — the runtime moved to meet the document (PRO-3192's positional rule),
after which the emitted `enum` needed no change at all, and the spelling that produced the unsatisfiable node
is refused at declaration before any projection exists. When a node cannot be satisfied, suspect the two sides
disagree about what the validator TARGETS, not about how strict to be.
```

- [ ] **Step 7: Document the rule for users in `docs/reference/class.md`**

In the `of:` grammar area (`:92-105`), add a paragraph (one line per paragraph — the file's convention):

```markdown
**Where a validator applies.** A validator constrains the value at the position it is declared at. On the `expects` that is the field's own value, so `inclusion:` on a `type: Array` field asks whether the ARRAY is a member of the set (`inclusion: { in: [["a", "b"], ["c"]] }`), and `length:` measures the array's size. A constraint on the *contents* belongs at the contents' own position — inside `of:` — and until that bag accepts value validators, a `validate: ->(value) { ... }` callable expresses it. Four validators have no reading at a container position at all and are refused at declaration: `format:` (which ActiveModel matches against `value.to_s`, so on an `Array` it would constrain the Ruby inspect form), `numericality:`, `comparison:` and `acceptance:` (which accept no container value). An `inclusion:` set no value of the declared `type:` could belong to is refused on the same terms, at every type — `type: Array, inclusion: { in: ["a", "b"] }` and `type: Integer, inclusion: { in: ["1", "2"] }` alike — since it rejects every input while looking like a constraint.
```

Then fix the validator-kwarg row at `:23`, which currently promises that any non-axn kwarg behaves "as if passed to `validates :foo, <...>` on an ActiveRecord model — with one exception, `confirmation:`". That is now false for four more validators, and for the two whose reading changed. Extend the exception clause:

```markdown
| anything else | `expects :foo, inclusion: { in: [:apple, :peach] }` | Any other arguments will be processed [as ActiveModel validations](https://guides.rubyonrails.org/active_record_validations.html) (i.e. as if passed to `validates :foo, <...>` on an ActiveRecord model) — with three exceptions. `confirmation:` axn extends past ActiveModel's own behavior (see below). `inclusion:`/`exclusion:` constrain the value at the position they are declared at, where ActiveModel distributes a set over an `Array` value's elements (see [Where a validator applies](#where-a-validator-applies)). And `format:`/`numericality:`/`comparison:`/`acceptance:` are refused at declaration on a container-typed field rather than silently constraining the container's `to_s`. An `Axn::FormObject` is an ActiveModel model rather than an axn contract, so `validates` there keeps ActiveModel's own readings throughout |
```

And extend the size line (`:235`):

```markdown
A field that rejects empty reflects that into its schema as `minItems` / `minProperties` / `minLength`, and a declared `length:` ceiling reflects as `maxItems` / `maxProperties` / `maxLength` (an exact `length: { is: 2 }` emitting both). A bound ActiveModel resolves per call (a Symbol or Proc) and an infinite one emit nothing, since no fixed number expresses them.
```

- [ ] **Step 8: Add the CHANGELOG entries**

Under `## Unreleased` → `### Changed`:

```markdown
* [BREAKING] A validator constrains **the value at the position it is declared at** — and `inclusion:`/`exclusion:` now follow that rule on a container-typed field, where ActiveModel's `Clusivity` had been distributing the set over an `Array`'s elements. `expects :tags, type: Array, inclusion: { in: [["a", "b"], ["c"]] }` asks whether the array itself is a member of the set; the elements are constrained at their own position (`of:`), or with a `validate: ->(value) { ... }` callable until the `of:` bag takes value validators. The distributing reading was never opted into: it emitted as `enum` on the array's own node (a schema that rejected every value the runtime accepted), it inverted to nonsense under `exclusion:` — `all?` under a negating caller meant "reject only when EVERY element is forbidden", so `["ok", "bad"]` passed an `exclusion: { in: ["bad"] }` — and it reached only a field-level `Array`, never a map's axis or an element two levels down. **The common spelling of the old behavior now raises at declaration** (see below), so the failure is loud at boot rather than silent at call time; a set whose members happen to be arrays, or one read dynamically (a Symbol or Proc source, which cannot be judged at declaration), changes meaning without an error, so audit those. `inclusion:` on a `type: Hash` field is unchanged — `Clusivity`'s special case was Array-only (see PRO-3192).
* [BREAKING] Four validators are refused at declaration on a field whose every declared type is a container (`Array`, `Hash`, `Set`): `format:`, which ActiveModel matches against `value.to_s` and which therefore constrained the Ruby inspect form (`format: { with: /a/ }` really did accept `["a"]`), and `numericality:`/`comparison:`/`acceptance:`, which accept no container value at all and so rejected every input. A union type carrying a scalar (`type: [String, Array]`), an undeclared type, a pseudo-type token and a disabled entry (`format: false`) all still declare cleanly. Drop the option, or constrain the contents at their own position (see PRO-3192).
* [BREAKING] An `inclusion:` set no value of the declared `type:` could be a member of is refused at declaration, at **every** type: `type: Array, of: String, inclusion: { in: ["a", "b"] }` (the old element-wise spelling) and `type: Integer, inclusion: { in: ["1", "2"] }` alike were contracts that rejected every input while looking like constraints. Judged by the runtime's own type matcher, so the refusal cannot disagree with the check it predicts, and it stands down wherever a passing value survives: a tolerance flag (`optional:`/`allow_nil:`, under which nil passes and the emitted node stays satisfiable), an undeclared or pseudo-type `type:`, and any set axn may not read side-effect-free — a Symbol/Proc source, an `ActiveRecord::Relation`, a `Range`, or an `Array` subclass. An `if:`/`unless:` gate does **not** excuse one: reflection is static-maximal, so a gated can-never-match set would still emit an unsatisfiable node, and a gate removes the check rather than giving the set a reading (see PRO-3192).
```

Under `### Fixed`:

```markdown
* [FIX] A declared `length:` ceiling now reflects into the schema as `maxItems` / `maxProperties` / `maxLength`, at every position — only the floor was ever emitted, so `length: { maximum: 2 }` advertised no bound at all while the runtime enforced one. An exact `length: { is: 2 }` emits both bounds, a range emits both (an exclusive end counting one less, as ActiveModel resolves it), and a union emits each bound on every size-bearing `anyOf` branch. A bound ActiveModel resolves per call (a Symbol/Proc) and `Float::INFINITY` emit nothing, since no fixed number expresses them (see PRO-3192).
```

- [ ] **Step 9: Verify and commit**

```bash
bundle exec rspec
BUNDLE_GEMFILE=Gemfile bundle exec rspec  # run from spec_rails/dummy_app
bundle exec rubocop
```

```bash
git add lib/axn/core/validation/validators/validate_validator.rb AGENTS.md \
        internal-docs/agent-notes/guards-and-projections.md docs/reference/class.md CHANGELOG.md \
        spec/axn/core/validations/container_position_validators_spec.rb
git commit -m "PRO-3192: write the positional rule down

AGENTS.md gains the rule and the satisfiability corollary to the projection
invariant; guards-and-projections.md gains the case study (an unsatisfiable node
satisfies a directional invariant vacuously, which is how enum-on-an-array-node
survived); class.md documents where a validator applies and the new ceilings.
validate:'s misuse guard no longer advises a fix that is itself refused.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage.** The spec's five changes map to Tasks 1-5 one-to-one; its failure grid is Task 1's and Task 2's spec files row by row; its *Files* table matches the File Structure above with one addition (`spec/axn/internal/reflection/schema_spec.rb`, where the ceiling examples belong beside the floor's). Two spec claims are corrected here rather than carried: the extraction is **two** readers (`declared_set_collection` for the location, shared by three consumers; `literal_set_members` for side-effect-free membership, shared by two) rather than one, because reflection's admissibility rule is deliberately narrower than the membership judgment's — it maps the members into the emitted document, so it takes an exact `Array` where membership also accepts a `Set` or a Hash's keys. And the two guards differ on gates, deliberately: coherence (Task 2) is not rescued by a gate, satisfiability (Task 3) is.

**Everything the spec put out of scope stays out:** `uniqueness:`, `absence:` + the non-emptiness floor, `exclusion` emission, and the whole `of:`-bag widening (PRO-3193, updated 2026-08-21 with what it inherits).

**Placeholders:** none — every step carries the code or the command it needs.

**Type consistency:** `Base.declared_set_collection` / `literal_set_members` / `declared_length_ceiling` / `emittable_length_ceiling?`, `Schema#declared_size_maximum` / `size_ceiling_key_for` / `size_bounds_for`, and `_reject_container_position_validators!` / `_declares_container_type_only?` / `_reject_unsatisfiable_value_constraints!` / `_judgeable_type_klasses` / `_judgeable_constraint_literals` are each spelled identically at their definition and at every call. `_declares_container_type_only?` (Task 2) is defined once and read by Task 2 only; Task 3 uses `_judgeable_type_klasses`, which answers a different question (judgeable, not container) and is defined in Task 3.
