# Reject Contradiction-Only Subfield Contracts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reject four families of contradiction-only subfield contracts at declaration with `ArgumentError`, then collapse the now-dead reflection inference branches into a single-pass `{required, nullable}` derivation.

**Architecture:** Families 1–3 (cross-declaration) are detected by a new `Axn::Reflection::SubfieldContradictions` module that walks the resolved `SubfieldTree` reusing existing `Schema` predicates; `ContractForSubfields#_expects_subfields` builds the tree from configs-so-far after each subfield declaration and raises the first contradiction. Family 4 (local) is a direct check in `_parse_subfield_configs`. With the families illegal, the reflection branches that existed only to reconcile them are deleted (or replaced with impossible-state assertions), and requiredness/nullability is derived once per node.

**Tech Stack:** Ruby, RSpec, ActiveModel validations. `build_axn { ... }` test helper (`Axn::Testing::SpecHelpers`).

## Global Constraints

- **Works outside Rails.** No hard Rails/ActiveRecord dependency; guard any such reference with `defined?(...)`. `spec/` runs without Rails. Declaration guards are pure DSL (non-Rails); test them in `spec/` with plain POROs.
- **TDD.** Failing test first, then implementation. Every family starts with a reproducing declaration-raises test.
- **Reuse the seams.** Detection reuses `SubfieldTree` and `Schema` predicates — no parallel path-walker.
- **Reflection is side-effect-free.** Never run user code (custom `validate:`/`model:`/Proc defaults); identity-based membership tests only.
- **Fail at declaration.** Contradictions raise `ArgumentError` when the class is defined; every message names the exact conflicting declarations and how to fix them.
- **CHANGELOG every user-visible change** under `## Unreleased`, tagged `[BREAKING]`, stating old-vs-new explicitly (dense, matching the prevailing detail level).
- **No manual line breaks in Markdown prose** (repo convention) — CHANGELOG bullets are one line per bullet.

---

## File map

- Create: `lib/axn/reflection/subfield_contradictions.rb` — the detector (families 1–3).
- Modify: `lib/axn/core/contract_for_subfields.rb` — family 4 local check; wire detector into `_expects_subfields`.
- Modify: `lib/axn/reflection/subfield_tree.rb` — delete the shape-collision drop branch (Task 5); it moves to the detector.
- Modify: `lib/axn/reflection/schema.rb` — delete/assert the dead family-1/3/4 inference branches (Task 5); single-pass derivation (Task 6).
- Create: `spec/axn/reflection/subfield_contradictions_spec.rb` — detector unit tests.
- Modify: `spec/axn/core/validations/on_subfields_spec.rb` — per-family declaration-raise tests (co-located with existing guard tests).
- Modify: `spec/axn/reflection/schema_spec.rb`, `spec/axn/reflection/subfield_tree_spec.rb` — convert/remove existing tests that build now-illegal contracts; add surviving-legal-contract regression + derivation-parity tests.
- Modify: `CHANGELOG.md` — one `[BREAKING]` bullet per family.

---

## Task 1: Family 4 — reject dotted-name `model:` subfield (local)

Simplest, self-contained, no tree. `expects "org.company", on: :payload, model: X` generates no reader, so the id→record lookup never runs and the advertised `<leaf>_id` is unconsumable. Reject, pointing at the working spelling.

**Files:**
- Modify: `lib/axn/core/contract_for_subfields.rb` (inside `_parse_subfield_configs`, near the existing `coerce:` reject at ~line 222)
- Test: `spec/axn/core/validations/on_subfields_spec.rb`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Produces: no new public API; a new `ArgumentError` at declaration.

- [ ] **Step 1: Write the failing test**

In `spec/axn/core/validations/on_subfields_spec.rb`, add (POROs only — declaration raises before any lookup, so the model constant just needs to exist):

```ruby
describe "contradiction rejections (PRO-2877)" do
  # A minimal model target; the raise fires at declaration, before any resolution.
  class FakeModel; def self.find(_id) = new; end

  describe "family 4: dotted-name model: subfield" do
    it "raises, pointing at the reader spelling" do
      expect do
        build_axn do
          expects :payload
          expects "org.company", on: :payload, model: FakeModel
        end
      end.to raise_error(
        ArgumentError,
        'a dotted-name model: subfield (["org.company"] with on: payload) has no consumable id — ' \
        "a dotted subfield name generates no reader, so the id-to-record lookup never runs. " \
        'Use the reader spelling instead: expects :company, on: "payload.org", model: ...',
      )
    end

    it "does not raise for the reader spelling (dotted on:, single-level name)" do
      expect do
        build_axn do
          expects :payload
          expects :company, on: "payload.org", model: FakeModel
        end
      end.not_to raise_error
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/core/validations/on_subfields_spec.rb -e "family 4"`
Expected: FAIL — the contradictory declaration does not raise (or raises a different error).

- [ ] **Step 3: Implement the local check**

In `lib/axn/core/contract_for_subfields.rb`, inside `_parse_subfield_configs`, in the `.map` block right after the `coerce:` reject (which already inspects `parsed_validations`), add:

```ruby
if parsed_validations.key?(:model) && field.to_s.include?(".")
  *parents, leaf = field.to_s.split(".")
  working_on = ([on] + parents).join(".")
  raise ArgumentError,
        "a dotted-name model: subfield (#{fields.map(&:to_s).inspect} with on: #{on}) has no consumable id — " \
        "a dotted subfield name generates no reader, so the id-to-record lookup never runs. " \
        "Use the reader spelling instead: expects :#{leaf}, on: \"#{working_on}\", model: ..."
end
```

Note: `field` here is the per-field loop variable from `_parse_field_validations(...).map { |field, parsed_validations| ... }`; `on` and `fields` are the method arguments. `fields.map(&:to_s).inspect` renders `["org.company"]`.

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/axn/core/validations/on_subfields_spec.rb -e "family 4"`
Expected: PASS (both examples).

- [ ] **Step 5: Add CHANGELOG bullet**

In `CHANGELOG.md` under `## Unreleased`, add:

```markdown
* [BREAKING] A `model:` subfield with a dotted field NAME (`expects "org.company", on: :payload, model: X`) now raises `ArgumentError` at declaration. A dotted subfield name generates no reader, so at runtime the id→record lookup never runs (validation falls back to the raw Extract resolver, which digs the object, not the id) and the advertised `<leaf>_id` is unconsumable — the contract only ever validated for a Ruby caller passing the actual nested record, never for a JSON/id client. The identical capability works under the reader spelling (`expects :company, on: "payload.org", model: X`), which the error now points at. Previously this loaded and reflection dropped+warned the config; it now fails at declaration (PRO-2877).
```

- [ ] **Step 6: Run the full subfield suite; commit**

Run: `bundle exec rspec spec/axn/core/validations/on_subfields_spec.rb`
Expected: PASS.

```bash
git add lib/axn/core/contract_for_subfields.rb spec/axn/core/validations/on_subfields_spec.rb CHANGELOG.md
git commit -m "PRO-2877: reject dotted-name model: subfields at declaration (family 4)"
```

---

## Task 2: Detector scaffold + Family 1 — nil-tolerant ancestor + required descendant

Introduce `SubfieldContradictions`, wire it into `_expects_subfields`, and implement family 1: a nil-tolerant ancestor (top-level field or intermediate subfield) with a required descendant anywhere below. A nil/omitted ancestor strands the required descendant (PRO-2857).

**Files:**
- Create: `lib/axn/reflection/subfield_contradictions.rb`
- Modify: `lib/axn/core/contract_for_subfields.rb` (end of `_expects_subfields`; add `require` at top)
- Test: `spec/axn/reflection/subfield_contradictions_spec.rb`, `spec/axn/core/validations/on_subfields_spec.rb`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Produces:
  - `Axn::Reflection::SubfieldContradictions.detect(tree) → Contradiction | nil` where `tree` is a `SubfieldTree::Result` and `Contradiction = Data.define(:family, :message)`.
  - Internal helpers (module_function): `label(config)`, `self_required?(node)`, `nil_tolerant?(node)`, `nil_tolerant_model?(node)`, `first_leaf_config(node)`.
- Consumes: `Axn::Reflection::Schema.{nil_accepted?, usable_default?, nestable_as_object?, shape_members_at}`, `Axn::Internal::FieldConfig.subfield_default_applies?`.

- [ ] **Step 1: Write the failing declaration test (family 1)**

In `spec/axn/core/validations/on_subfields_spec.rb`, inside the `"contradiction rejections (PRO-2877)"` describe, add:

```ruby
describe "family 1: nil-tolerant ancestor + required descendant" do
  it "raises when a nil-tolerant top-level parent has a required deep subfield" do
    expect do
      build_axn do
        expects :payload, type: Hash, allow_nil: true
        expects :id, on: "payload.meta", type: Integer
      end
    end.to raise_error(
      ArgumentError,
      "expects :payload is declared nil-tolerant (allow_nil:/optional:) but :id (on: payload.meta) " \
      "is required — a nil or omitted :payload can never satisfy it. " \
      "Drop allow_nil:/optional: on :payload, or make :id optional.",
    )
  end

  it "raises when an intermediate subfield is optional: but its subtree requires presence" do
    expect do
      build_axn do
        expects :payload, type: Hash
        expects :meta, on: :payload, type: Hash, optional: true
        expects :id, on: "payload.meta", type: Integer
      end
    end.to raise_error(ArgumentError, /:meta .* but :id \(on: payload\.meta\) is required/)
  end

  it "does not raise when the required descendant is itself optional" do
    expect do
      build_axn do
        expects :payload, type: Hash, allow_nil: true
        expects :id, on: "payload.meta", type: Integer, optional: true
      end
    end.not_to raise_error
  end

  it "does not raise when the parent is required (no nil-tolerance)" do
    expect do
      build_axn do
        expects :payload, type: Hash
        expects :id, on: "payload.meta", type: Integer
      end
    end.not_to raise_error
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bundle exec rspec spec/axn/core/validations/on_subfields_spec.rb -e "family 1"`
Expected: FAIL — the contradictory declarations do not raise.

- [ ] **Step 3: Create the detector with family 1**

Create `lib/axn/reflection/subfield_contradictions.rb`:

```ruby
# frozen_string_literal: true

require "axn/reflection/subfield_tree"

module Axn
  module Reflection
    # Declaration-time detector for contradiction-only subfield contracts (PRO-2877). Walks the
    # resolved SubfieldTree once, top-down, carrying ancestor context, and returns the first
    # contradiction found (or nil). Reuses Schema's leaf predicates so declaration (which raises here)
    # and reflection (which emits) share one notion of "contradictory". Side-effect-free: inspects
    # declared configs only, never runs user code.
    module SubfieldContradictions
      Contradiction = Data.define(:family, :message)

      module_function

      def detect(tree)
        tree.roots.each_value do |root|
          found = walk(root, nil_tolerant_ancestor: nil, nil_tolerant_model_ancestor: nil, carried_members: [])
          return found if found
        end
        nil
      end

      # `nil_tolerant_ancestor` / `nil_tolerant_model_ancestor` are the OUTERMOST such ancestor configs
      # above this node (nil when none). `carried_members` are the object-shaped shape members an
      # implicit ancestor merged into (for a member-of-a-member family-2 collision at depth).
      def walk(node, nil_tolerant_ancestor:, nil_tolerant_model_ancestor:, carried_members:)
        # Family 1: this node must be present, but a nil-tolerant ancestor can strand it.
        return family_1(nil_tolerant_ancestor, node.config) if nil_tolerant_ancestor && self_required?(node)

        # Family 3 (Task 4 fills this in): applied default under a nil-tolerant model ancestor.
        if nil_tolerant_model_ancestor && (defaulted = applied_default_config(node))
          return family_3(nil_tolerant_model_ancestor, defaulted)
        end

        child_nil_tolerant = nil_tolerant_ancestor || (nil_tolerant?(node) ? nil_tolerant_config(node) : nil)
        child_model = nil_tolerant_model_ancestor || (nil_tolerant_model?(node) ? nil_tolerant_model_config(node) : nil)

        node.children.each do |key, child|
          child_carried = []
          if child.implicit?
            # Family 2 (Task 3 fills this in): collision with a non-object shape member.
            members = Schema.shape_members_at(node.configs + carried_members, key)
            if (blocker = members.find { |m| !Schema.nestable_as_object?(m) })
              return family_2(node, blocker, first_leaf_config(child))
            end
            child_carried = members.select { |m| Schema.nestable_as_object?(m) }
          end

          found = walk(child, nil_tolerant_ancestor: child_nil_tolerant, nil_tolerant_model_ancestor: child_model, carried_members: child_carried)
          return found if found
        end
        nil
      end

      # --- family predicates (leaf; reuse Schema) ---

      # A node whose OWN declared signals force it to be present: some config neither carries a usable
      # subfield default nor tolerates nil. Implicit nodes carry no validators, so they are never
      # self-required (their obligation lives in their explicit descendants, caught on their own hop).
      def self_required?(node)
        return false if node.implicit?

        node.configs.any? { |c| !(Schema.usable_default?(c, subfield: true) || Schema.nil_accepted?(c)) }
      end

      def nil_tolerant?(node)
        !node.implicit? && node.configs.any? { |c| Schema.nil_accepted?(c) }
      end

      def nil_tolerant_config(node)
        node.configs.find { |c| Schema.nil_accepted?(c) }
      end

      def nil_tolerant_model?(node)
        !node.implicit? && node.configs.any? { |c| c.validations[:model] && Schema.nil_accepted?(c) }
      end

      def nil_tolerant_model_config(node)
        node.configs.find { |c| c.validations[:model] && Schema.nil_accepted?(c) }
      end

      def applied_default_config(node)
        return nil if node.implicit?

        node.configs.find { |c| Axn::Internal::FieldConfig.subfield_default_applies?(c) }
      end

      def first_leaf_config(node)
        return node.config unless node.implicit?

        node.children.each_value do |child|
          found = first_leaf_config(child)
          return found if found
        end
        nil
      end

      # A top-level field config has no `on:`; a subfield config does. Render each as declared.
      def label(config)
        on = config.respond_to?(:on) ? config.on : nil
        on ? ":#{config.field} (on: #{on})" : ":#{config.field}"
      end

      # --- messages ---

      def family_1(ancestor, descendant)
        Contradiction.new(
          family: 1,
          message: "expects #{label(ancestor)} is declared nil-tolerant (allow_nil:/optional:) but " \
                   "#{label(descendant)} is required — a nil or omitted :#{ancestor.field} can never " \
                   "satisfy it. Drop allow_nil:/optional: on :#{ancestor.field}, or make :#{descendant.field} optional.",
        )
      end

      # Filled in by Task 3.
      def family_2(_parent_node, _member, _deep_config) = nil

      # Filled in by Task 4.
      def family_3(_model_ancestor, _defaulted) = nil
    end
  end
end
```

Note: `family_2`/`family_3` return `nil` placeholders here so Task 2 compiles and runs; Tasks 3 and 4 replace them. The `walk` already calls them, so wiring is complete — only the message builders are stubbed.

- [ ] **Step 4: Wire the detector into declaration**

In `lib/axn/core/contract_for_subfields.rb`, add near the top requires:

```ruby
require "axn/reflection/subfield_contradictions"
```

At the end of `_expects_subfields`, replace the final append block so detection runs after configs are appended:

```ruby
_parse_subfield_configs(*fields, on:, readers:, allow_blank:, allow_nil:, optional:, preprocess:, sensitive:, default:,
                                 metadata:, reader_names:, **validations).tap do |configs|
  duplicated = _duplicate_fields(subfield_configs, configs)
  raise Axn::DuplicateFieldError, "Duplicate field(s) declared: #{duplicated.join(', ')}" if duplicated.any?

  # NOTE: avoid <<, which would update value for parents and children
  self.subfield_configs += configs

  # Reject contradiction-only contracts (families 1–3) once the new configs are in the tree. Built
  # fresh (not cached) — this is class-load time, off the runtime hot path. Family 4 is a local
  # check in _parse_subfield_configs.
  tree = Axn::Reflection::SubfieldTree.build(internal_field_configs, subfield_configs)
  if (contradiction = Axn::Reflection::SubfieldContradictions.detect(tree))
    raise ArgumentError, contradiction.message
  end
end
```

- [ ] **Step 5: Run the family-1 declaration tests**

Run: `bundle exec rspec spec/axn/core/validations/on_subfields_spec.rb -e "family 1"`
Expected: PASS (all four examples).

- [ ] **Step 6: Add detector unit tests**

Create `spec/axn/reflection/subfield_contradictions_spec.rb` exercising `detect` directly on built trees, so the detector is covered independently of the DSL wiring:

```ruby
# frozen_string_literal: true

RSpec.describe Axn::Reflection::SubfieldContradictions do
  def tree_for(&blk)
    klass = Axn::Factory.build(&blk) # or build_axn; see existing helper usage
    Axn::Reflection::SubfieldTree.build(klass.internal_field_configs, klass.subfield_configs)
  end

  it "returns nil for a contradiction-free contract" do
    # NOTE: building a *clean* contract via build_axn already passes declaration; assert detect is nil
    #       by constructing the tree from a known-good action.
  end
end
```

Replace the body with concrete cases once the `build_axn`→configs accessor pattern is confirmed from `spec/axn/reflection/subfield_tree_spec.rb` (it already builds trees from actions — copy its setup). Add at least: a clean contract → `nil`; a family-1 contract built by bypassing declaration is not possible (declaration raises), so the detector's family-1 path is exercised through the DSL tests in Step 1. Keep this spec focused on the `label`/`self_required?`/`first_leaf_config` helper behaviors that are awkward to reach through the DSL.

- [ ] **Step 7: Convert any existing reflection tests that build a now-illegal family-1 contract**

Run: `bundle exec rspec spec/axn/reflection/schema_spec.rb spec/axn/reflection/subfield_tree_spec.rb`
Expected: some may now FAIL at declaration (they construct a nil-tolerant parent + required descendant to assert reflection output). For each failure, either (a) delete it if it only characterized the now-illegal reconciliation, or (b) convert it to a declaration-raise assertion. Grep for `allow_nil` / `optional:` near a required subfield to find them. Document each conversion in the commit message.

- [ ] **Step 8: CHANGELOG + commit**

Add to `CHANGELOG.md`:

```markdown
* [BREAKING] A nil-tolerant ancestor (`allow_nil:`/`optional:` on a top-level field or an intermediate subfield) combined with a required subfield anywhere in its subtree now raises `ArgumentError` at declaration. A nil or omitted ancestor yields every descendant absent (PRO-2857), so the required descendant can never be satisfied — the `allow_nil:`/`optional:` was a dead flag that only "worked" by silently overriding the descendant's requiredness in schema reflection. The error names both declarations and suggests dropping the nil-tolerance or making the descendant optional. Previously the contract loaded and misbehaved only on the nil/omitted path (PRO-2877).
```

Run: `bundle exec rspec spec/axn/core/validations/on_subfields_spec.rb spec/axn/reflection/`
Expected: PASS.

```bash
git add lib/axn/reflection/subfield_contradictions.rb lib/axn/core/contract_for_subfields.rb spec/ CHANGELOG.md
git commit -m "PRO-2877: reject nil-tolerant ancestor + required descendant (family 1)"
```

---

## Task 3: Family 2 — non-object shape member + colliding deep subfield

Implement the `family_2` message builder. The `walk` already detects the collision (an implicit child whose key collides with a non-object `shape:` member of its parent's configs or carried members). `expects :payload, type: Hash do field :bar, type: String end` + `expects "bar.baz", on: :payload` digs through a String — never coherent.

**Files:**
- Modify: `lib/axn/reflection/subfield_contradictions.rb` (`family_2`)
- Test: `spec/axn/core/validations/on_subfields_spec.rb`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: `walk`'s call `family_2(node, blocker, first_leaf_config(child))` from Task 2 — `node` is the explicit parent whose shape declared `blocker`; `blocker` is the non-object shape member config; the third arg is the deepest colliding subfield config.

- [ ] **Step 1: Write the failing test**

```ruby
describe "family 2: non-object shape member + colliding deep subfield" do
  it "raises when a deep subfield nests under a non-object (String) shape member" do
    expect do
      build_axn do
        expects :payload, type: Hash do
          field :bar, type: String
        end
        expects "bar.baz", on: :payload, type: String
      end
    end.to raise_error(
      ArgumentError,
      ":baz (on: payload) nests beneath shape member :bar on :payload, which is declared a non-object " \
      "type (String) — a nested subfield has nowhere to live. Make :bar an object-shaped member " \
      "(Hash/:params), or drop the nested subfield.",
    )
  end

  it "does not raise when the colliding shape member is object-shaped" do
    expect do
      build_axn do
        expects :payload, type: Hash do
          field :bar, type: Hash
        end
        expects "bar.baz", on: :payload, type: String
      end
    end.not_to raise_error
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bundle exec rspec spec/axn/core/validations/on_subfields_spec.rb -e "family 2"`
Expected: FAIL — `family_2` returns `nil` (stub), so no raise.

- [ ] **Step 3: Implement `family_2`**

Replace the stub in `lib/axn/reflection/subfield_contradictions.rb`:

```ruby
def family_2(parent_node, member, deep_config)
  parent_field = parent_node.config.field
  Contradiction.new(
    family: 2,
    message: "#{label(deep_config)} nests beneath shape member :#{member.field} on :#{parent_field}, " \
             "which is declared a non-object type (#{member_type_desc(member)}) — a nested subfield has " \
             "nowhere to live. Make :#{member.field} an object-shaped member (Hash/:params), " \
             "or drop the nested subfield.",
  )
end

# A short human name for the shape member's declared type, for the error message.
def member_type_desc(member)
  klass = member.validations.dig(:type, :klass) || member.validations[:type]
  Array(klass).map { |k| k.is_a?(Class) ? k.name : k.to_s }.join(" | ")
end
```

Note: `deep_config` may be a config whose `on:` is the parent and whose `field` is dotted (`"bar.baz"`), so `label` renders `:bar.baz (on: payload)`. Confirm the message string in the test matches the actual `field` (`"bar.baz"` vs the leaf `:baz`). If `first_leaf_config` returns the config whose `field` is `"bar.baz"`, adjust the expected message to `:bar.baz`; if the tree splits the dotted name into an implicit `bar` + leaf `baz`, it returns the `baz` leaf. Verify against the real `SubfieldTree` structure and set the expected string accordingly (the test is the oracle — run it and read the actual message).

- [ ] **Step 4: Run to verify it passes**

Run: `bundle exec rspec spec/axn/core/validations/on_subfields_spec.rb -e "family 2"`
Expected: PASS. If the message differs on the deep-config label, reconcile the test to the real structure (see Step 3 note) and re-run.

- [ ] **Step 5: Convert existing reflection tests that build this family**

Run: `bundle exec rspec spec/axn/reflection/schema_spec.rb spec/axn/reflection/subfield_tree_spec.rb`
Expected: any test that constructs a non-object shape member colliding with a deep subfield (previously exercising the drop+warn path) now raises at declaration. Convert to declaration-raise or delete, as in Task 2 Step 7.

- [ ] **Step 6: CHANGELOG + commit**

```markdown
* [BREAKING] A deep subfield whose path nests beneath a non-object `shape:` member (`expects :payload, type: Hash do field :bar, type: String end` + `expects "bar.baz", on: :payload`) now raises `ArgumentError` at declaration. Runtime digging through the non-object member (`String#[]`) produces substring nonsense, and schema reflection previously dropped+warned the deep config — the structure was never coherent. The error names the colliding member and the deep subfield. An object-shaped member (Hash/:params) is unaffected (PRO-2877).
```

Run: `bundle exec rspec spec/axn/core/validations/on_subfields_spec.rb spec/axn/reflection/`
Expected: PASS.

```bash
git add lib/axn/reflection/subfield_contradictions.rb spec/ CHANGELOG.md
git commit -m "PRO-2877: reject non-object shape member + colliding deep subfield (family 2)"
```

---

## Task 4: Family 3 — nil-tolerant `model:` parent + applied-default descendant

Implement the `family_3` message builder. The `walk` already detects it (an applied-default config under a nil-tolerant model ancestor). Under an omitted nil-tolerant model, `apply_defaults_for_subfields!` materializes `{}` under the model's wire key before the default runs, and `ModelValidator` rejects `{}` as not a record — so the id can never be omitted and the `allow_nil:` is dead.

**Files:**
- Modify: `lib/axn/reflection/subfield_contradictions.rb` (`family_3`)
- Test: `spec/axn/core/validations/on_subfields_spec.rb`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: `walk`'s call `family_3(nil_tolerant_model_ancestor, defaulted)` from Task 2.

- [ ] **Step 1: Write the failing test**

```ruby
describe "family 3: nil-tolerant model: parent + applied-default descendant" do
  it "raises when a nil-tolerant model parent has a defaulted subfield" do
    expect do
      build_axn do
        expects :company, model: FakeModel, allow_nil: true
        expects :name, on: :company, default: "Acme"
      end
    end.to raise_error(
      ArgumentError,
      "expects :company is a nil-tolerant model: (allow_nil:) but :name (on: company) carries a default " \
      "— the default materializes an empty object under :company, which the model validator rejects as " \
      "not a record, so :company can never be omitted. Drop allow_nil: on :company, or drop the subfield default.",
    )
  end

  it "counts a Proc default (materialization fires before the Proc runs)" do
    expect do
      build_axn do
        expects :company, model: FakeModel, allow_nil: true
        expects :name, on: :company, default: -> { "x" }
      end
    end.to raise_error(ArgumentError, /nil-tolerant model:/)
  end

  it "does not raise for a required model parent with a defaulted subfield" do
    expect do
      build_axn do
        expects :company, model: FakeModel
        expects :name, on: :company, default: "Acme"
      end
    end.not_to raise_error
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bundle exec rspec spec/axn/core/validations/on_subfields_spec.rb -e "family 3"`
Expected: FAIL — `family_3` returns `nil` (stub).

- [ ] **Step 3: Implement `family_3`**

Replace the stub:

```ruby
def family_3(model_ancestor, defaulted)
  Contradiction.new(
    family: 3,
    message: "expects :#{model_ancestor.field} is a nil-tolerant model: (allow_nil:) but " \
             "#{label(defaulted)} carries a default — the default materializes an empty object under " \
             ":#{model_ancestor.field}, which the model validator rejects as not a record, so " \
             ":#{model_ancestor.field} can never be omitted. Drop allow_nil: on :#{model_ancestor.field}, " \
             "or drop the subfield default.",
  )
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `bundle exec rspec spec/axn/core/validations/on_subfields_spec.rb -e "family 3"`
Expected: PASS (all three examples). The Proc case relies on `subfield_default_applies?` counting Procs (`!!config.default`), which it already does.

- [ ] **Step 5: Convert existing reflection tests that build this family**

Run: `bundle exec rspec spec/axn/reflection/schema_spec.rb`
Expected: any test constructing a nil-tolerant model parent with a defaulted subtree config (exercising `apply_model_id_requiredness!`'s hazard scan) now raises at declaration. Convert or delete.

- [ ] **Step 6: CHANGELOG + commit**

```markdown
* [BREAKING] A nil-tolerant `model:` parent (`expects :company, model: X, allow_nil: true`) combined with any applied-default subfield in its subtree (a truthy default, Proc included) now raises `ArgumentError` at declaration. On omission, `apply_defaults_for_subfields!` materializes `{}` under the model's wire key BEFORE the default is evaluated, and `ModelValidator` rejects `{}` as not a record — so the id could never actually be omitted and the `allow_nil:` was dead weight producing a confusing failure. The error names the model parent and the defaulted subfield. A required model parent (no `allow_nil:`) is unaffected (PRO-2877).
```

Run: `bundle exec rspec spec/axn/core/validations/on_subfields_spec.rb spec/axn/reflection/`
Expected: PASS.

```bash
git add lib/axn/reflection/subfield_contradictions.rb spec/ CHANGELOG.md
git commit -m "PRO-2877: reject nil-tolerant model: parent + applied-default subfield (family 3)"
```

---

## Task 5: Reflection cleanup — delete/assert the now-dead inference branches

With all four families illegal, the branches that existed only to reconcile them are dead. **DECISION (settled): clean deletion, no impossible-state assertions.** The declaration guard is the loud failure that makes these branches unreachable; a scattered `raise "unreachable"` would be dead code duplicating that guarantee. Delete the branches outright and rely on (1) the declaration `ArgumentError` and (2) the derivation-parity suite (Task 6) proving emission is unchanged for legal contracts. Reflection stays a pure reader.

**Files:**
- Modify: `lib/axn/reflection/subfield_tree.rb`
- Modify: `lib/axn/reflection/schema.rb`
- Test: `spec/axn/reflection/schema_spec.rb`, `spec/axn/reflection/subfield_tree_spec.rb` (regression — must stay green with no behavior change for legal contracts)

**Interfaces:**
- Consumes: nothing new.
- Produces: no API change; the surviving `dropped_deep_subfields` now returns only type-blocked (model/Array/mixed-union parent) drops.

- [ ] **Step 1: Confirm the suite is green before touching reflection**

Run: `bundle exec rspec spec/axn/reflection/`
Expected: PASS (Tasks 2–4 already converted the illegal-contract tests). This is the regression oracle for Task 5 — every deletion below must keep it green.

- [ ] **Step 2: Family 1 — collapse the flags-override in `schema.rb`**

In `node_optional?` (`lib/axn/reflection/schema.rb`), the explicit-node clause is:

```ruby
configs.all? do |c|
  usable_default?(c, subfield: true) || (nil_accepted?(c) && !subtree_requires_presence?(node))
end
```

A nil-tolerant node can no longer have a required subtree (family 1 rejected), so `nil_accepted?(c)` implies `!subtree_requires_presence?(node)`. Simplify to:

```ruby
configs.all? { |c| usable_default?(c, subfield: true) || nil_accepted?(c) }
```

In `field_optional?`, the clause `return true if nil_accepted?(config) && !has_required_child` simplifies to `return true if nil_accepted?(config)` — but this changes the *ordering* dependency documented there. Verify against the suite: the comment "must be checked AFTER the required-child test" becomes moot once nil-tolerance implies no required child. Simplify and update the comment to state the current (post-2877) invariant, not the history (per AGENTS.md: comments describe current behavior). Re-run `spec/axn/reflection/` after each edit.

- [ ] **Step 3: Family 2 — delete the shape-collision branch from `subfield_tree.rb`**

In `blocking_ancestor?` (`lib/axn/reflection/subfield_tree.rb`):

```ruby
def blocking_ancestor?(node, key, carried = [])
  return true if Schema.node_configs_block_nesting?(node.configs)
  return false unless node.children[key]&.implicit?

  colliding_shape_members(node, key, carried).any? { |m| !Schema.nestable_as_object?(m) }
end
```

The shape-collision case (a non-object member) is now rejected at declaration, so the last two lines can never fire for a legal contract. Reduce to:

```ruby
def blocking_ancestor?(node, _key, _carried = [])
  Schema.node_configs_block_nesting?(node.configs)
end
```

Then `merged_shape_members` / `colliding_shape_members` / the `carried` threading in `path_blocked?` exist only to feed the deleted branch — delete them and simplify `path_blocked?` to a plain hop walk:

```ruby
def path_blocked?(hops)
  hops.any? { |node, _key| Schema.node_configs_block_nesting?(node.configs) }
end
```

In `schema.rb`, `apply_implicit_node!`'s member-collision drop/merge block (the `members.any? { !nestable_as_object? }` branch that force-required + `reject_null!`s the colliding member) is likewise dead — an implicit node can no longer collide with a non-object member. Delete that branch; keep the merge-into-object-member path (carrying nestable members is now unreachable via a non-object blocker but object-member merges remain legal — verify the `shape_members_at` merge still works for the object case and keep only that).

- [ ] **Step 4: Family 3 — delete the model-hazard scan use**

In `apply_model_id_requiredness!` (`schema.rb`):

```ruby
model_omittable = optional_for_schema?(config) &&
                  !children_require_presence?(children) &&
                  !subtree_has_applied_subfield_default?(children)
```

The `!subtree_has_applied_subfield_default?(children)` term guarded the family-3 hazard on a nil-tolerant model; that combination is now illegal. Remove the term:

```ruby
model_omittable = optional_for_schema?(config) && !children_require_presence?(children)
```

Keep `subtree_has_applied_subfield_default?` itself — `required_child?` still uses it for the surviving shape-member synthesis hazard on an object/Hash parent. Update `apply_model_id_requiredness!`'s doc paragraph to drop the "any descendant carries a subfield default…" sentence.

- [ ] **Step 5: Family 4 — shrink `compute_dropped` and remove dotted-model exclusions**

In `subfield_tree.rb`, `compute_dropped`:

```ruby
def compute_dropped(deep_paths)
  deep_paths.filter_map do |config, hops|
    config if Schema.dotted_model_config?(config) || path_blocked?(hops)
  end
end
```

Dotted-name model configs are now rejected at declaration, so the `Schema.dotted_model_config?(config)` term is dead:

```ruby
def compute_dropped(deep_paths)
  deep_paths.filter_map { |config, hops| config if path_blocked?(hops) }
end
```

In `schema.rb` `apply_children!`, remove the `dotted_model_config?` exclusions (`model_configs = node.configs.select { |c| c.validations[:model] && !dotted_model_config?(c) }` → `select { |c| c.validations[:model] }`, and drop the paragraph explaining the dotted-model omission). Then check whether `Schema.dotted_model_config?` has any remaining callers (`grep -rn dotted_model_config lib spec`); if none, delete the method and its doc. Update the `dropped_deep_subfields` doc and the `_warn_dropped_deep_subfields` warning message in `schema_reflection.rb` to drop the dotted-model phrasing (the warning now covers only type-blocked parents).

- [ ] **Step 6: Full reflection + subfield suite green**

Run: `bundle exec rspec spec/axn/reflection/ spec/axn/core/validations/on_subfields_spec.rb spec/axn/core/schema_reflection_spec.rb`
Expected: PASS with no behavior change for legal contracts.

- [ ] **Step 7: Commit**

```bash
git add lib/axn/reflection/subfield_tree.rb lib/axn/reflection/schema.rb lib/axn/core/schema_reflection.rb spec/
git commit -m "PRO-2877: delete dead reflection inference branches now rejected at declaration"
```

---

## Task 6: Single-pass `{required, nullable}` derivation

Companion refactor. Derive each tree node's requiredness/nullability once, so emission reads annotations instead of recomputing `subtree_requires_presence?` / `required_child?` at ~six sites (the root cause of PR #149's rounds-5/8/9 repeat findings). Done after Task 5 so the derivation encodes the smaller post-rejection rule set.

**This is a consolidation refactor; its correctness oracle is the existing `spec/axn/reflection/schema_spec.rb` suite plus the new parity tests below. Do not change emitted schemas for any legal contract — only where the derivation is computed.**

**Files:**
- Modify: `lib/axn/reflection/schema.rb` (add derivation; convert emission sites to readers)
- Test: `spec/axn/reflection/schema_spec.rb` (parity assertions)

**Interfaces:**
- Produces (internal to `Schema`):
  - `NodeAnnotation = Data.define(:required, :nullable)` — `required` = the node must appear in its parent's `required`; `nullable` = `null` admissible for the property.
  - `derive_annotations(roots) → Hash` — a `compare_by_identity` Hash mapping each `SubfieldTree::Node` to its `NodeAnnotation`, computed bottom-up in one pass.
- Consumes: the surviving (post-Task-5) predicates `usable_default?`, `nil_accepted?`, `required_child?`, `nil_allowed?`.

- [ ] **Step 1: Write the parity test harness**

In `spec/axn/reflection/schema_spec.rb`, add a context that asserts the derivation matches the pre-refactor emission for a table of legal contracts (object parent, model parent, `type: Array` parent, mixed union, representable deep chain, defaulted subtree, nested shape members). Capture each contract's `input_schema` BEFORE this task (record the expected Hashes as literals in the test) so the refactor is pinned to no-change:

```ruby
describe "single-pass derivation parity (PRO-2877)" do
  it "emits the same input_schema for a representable deep chain" do
    action = build_axn do
      expects :payload, type: Hash
      expects :meta, on: :payload, type: Hash
      expects :id, on: "payload.meta", type: Integer
    end
    expect(action.input_schema).to eq(
      # paste the exact Hash emitted before the refactor
    )
  end
  # ... one example per row of the legal-contract table
end
```

- [ ] **Step 2: Run to capture the baseline**

Run: `bundle exec rspec spec/axn/reflection/schema_spec.rb -e "parity"`
Expected: PASS against the pasted literals (this pins current behavior before refactoring).

- [ ] **Step 3: Implement `derive_annotations`**

Add to `schema.rb`. Compute bottom-up; `subtree_requires_presence` reads children's already-computed `required`:

```ruby
NodeAnnotation = Data.define(:required, :nullable)

# One bottom-up pass over the tree. Emission reads these instead of recomputing per site.
def derive_annotations(roots)
  ann = {}.compare_by_identity
  roots.each_value { |node| annotate_node!(node, ann) }
  ann
end

def annotate_node!(node, ann)
  node.children.each_value { |child| annotate_node!(child, ann) }

  subtree_requires_presence = node.children.values.any? { |c| ann[c].required }

  if node.implicit?
    required = subtree_requires_presence
    nullable = !subtree_requires_presence
  else
    config = node.config
    required = node.configs.any? { |c| !(usable_default?(c, subfield: true) || nil_accepted?(c)) }
    # required_child? carries the surviving shape-synthesis clause; nullability mirrors it.
    nullable = nil_allowed?(config) && !required_child?(config, node.children)
  end

  ann[node] = NodeAnnotation.new(required:, nullable:)
end
```

Note: `required_child?` currently takes `(config, children)` and computes `children_require_presence?` itself. To avoid double recursion, have `annotate_node!` pass the already-computed `subtree_requires_presence` into a slimmed `required_child?` (refactor its signature to accept the precomputed flag, or read `ann` for the children). Choose the form that keeps `required_child?` the single source of truth. Verify against the parity suite after each change.

- [ ] **Step 4: Convert emission sites to read annotations**

Thread the annotation map from `build_input` (build it once: `ann = derive_annotations(tree.roots)`) through `apply_nested_subfields!` / `apply_children!` / `apply_implicit_node!`. Replace each in-emission recomputation of requiredness/nullability with a read of `ann[node]`:
- `build_input`: top-level `required << config.field.to_s unless field_optional?(...)` — keep `field_optional?` (it has the parent-synthesis clause), but its transitive `required_child?` reads the annotation.
- `apply_children!`: `prop[:required] << key.to_s unless node_optional?(...)` → `... unless !ann[node].required`; `null_ok` → `ann[node].nullable`.
- `apply_nested_subfields!`: `prop[:type] = ... ? %w[object null] : "object"` → driven by `ann[node].nullable`.
- `apply_implicit_node!`: `nullable` and the `required` push → read `ann[node]`.

Run `spec/axn/reflection/schema_spec.rb` after each site conversion; the parity suite must stay green.

- [ ] **Step 5: Full suite green**

Run: `bundle exec rspec spec/axn/reflection/ spec/axn/core/schema_reflection_spec.rb spec/axn/core/validations/`
Expected: PASS, no schema changes for legal contracts.

- [ ] **Step 6: CHANGELOG + commit**

```markdown
* [INTERNAL] Schema reflection now derives each subfield tree node's requiredness/nullability in a single bottom-up pass; emission reads those annotations instead of recomputing the transitive presence obligation at each emission site. No behavior change — this removes the class of bug where a dropped/blocked deep shape kept its runtime obligation at some sites but not others (PRO-2877).
```

```bash
git add lib/axn/reflection/schema.rb spec/axn/reflection/schema_spec.rb CHANGELOG.md
git commit -m "PRO-2877: derive subfield requiredness/nullability in a single pass"
```

---

## Task 7: Follow-up capture + final verification

**Files:** none (Linear + full-suite run).

- [ ] **Step 1: File the three follow-up tickets** (or hand the maintainer the titles):
  - A — Global conditional requiredness (`if:`/`unless:` on validations, or dynamic `optional:`), applied uniformly and reflected consistently. The deliberate home for the family-1 "conditional" interpretation.
  - B — `coerce:` on subfields: mirror the existing `apply_inbound_preprocessing_for_subfields!`/`apply_defaults_for_subfields!` passes; drop the declaration reject; reflect the wire type. Cheap, tree-independent.
  - C — Design spike: SubfieldTree as canonical resolved-subfield structure (declaration + reflection + runtime, cached per class); unlocks nested `default:`/`preprocess:`/`sensitive:`, subsumes B, feeds deep ambient (server_context for axn-mcp).

- [ ] **Step 2: Run the whole suite (both harnesses)**

Run: `bundle exec rspec`
Then the Rails dummy app specs: `bundle exec rspec spec_rails` (per AGENTS.md — Rails-adjacent changes tested in both; declaration guards are non-Rails but run the suite to confirm no regression).
Expected: PASS.

- [ ] **Step 3: Confirm no lingering references to deleted concepts**

Run: `grep -rn "dotted_model_config\|colliding_shape_members\|merged_shape_members" lib/`
Expected: empty (or only intended survivors). Investigate any hit.

---

## Self-review notes (author)

- **Spec coverage:** families 1–4 → Tasks 1–4; reflection assertions/deletions → Task 5; single-pass derivation → Task 6; follow-ups A/B/C → Task 7. CHANGELOG `[BREAKING]` per family (Tasks 1–4), `[INTERNAL]` for the derivation (Task 6). Testing in both harnesses → Task 7 Step 2.
- **Open decision carried into Task 5:** assertion vs. clean deletion (flagged with the maintainer).
- **Message strings are the oracle:** several expected error strings (especially family 2's deep-config label) must be reconciled against the real `SubfieldTree` structure when the test first runs — the plan says so at each such point rather than guessing the exact leaf spelling.
