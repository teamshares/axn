# Recursive `of:` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `of:` take the full inner contract — `klass:` / `of:` / `shape:` / `message:` — recursively, so a container can be declared inside a container at any depth.

**Architecture:** One inner-contract bag grammar is used in three positions (an Array's element, a map's `keys:` axis, a map's `values:` axis). The declaration walk fuses `shape:` descent and `of:` descent into a single pass with one depth budget, one path budget and one cycle guard. Runtime recursion reuses the existing validator pipeline by mapping an inner bag to a validations bag and validating it against a source that reads as itself. Schema emission extracts a nameless-node builder shared by the field emitter and the recursion. Finally the flat distributing `type: Array … shape:` form is canonicalized forward into an `of:` bag, so the stored graph carries one contract shape.

**Tech Stack:** Ruby 3.2–3.4, ActiveModel 8.x, RSpec. No Rails dependency in any file touched here.

**Spec:** `internal-docs/specs/2026-08-19-recursive-of-design.md`

## Global Constraints

- **Works outside Rails.** Every file touched here is loaded by plain `require "axn"`. No `ActiveRecord`/`Rails` reference without a `defined?(...)` guard. All specs go under `spec/` (non-Rails); nothing here needs `spec_rails`.
- **TDD.** Failing test first, then implementation. Every task below is ordered that way; do not reorder.
- **Fail at declaration, not runtime.** A bad option combination raises `ArgumentError` when the class is defined, with a message that states the fix. Never silently ignore an option.
- **Never dispatch a caller's method from a guard or error path.** Use `Internal::ShapeGraph.hash_or_nil` / `.carries_key?` / `.read` / `.fetch` / `.each_entry`, `Internal::NativeMethods.*`, `Internal::Identity.kind?` / `.same?`, `Internal::Rendering.type_label`, `PropertyNames.inspect_field_name`. Compare classes with `equal?` where the receiver is one of ours (`::Hash.equal?(x)`, never `x == ::Hash`).
- **Validation messages are settled unredacted.** They reach `result.exception.message` and the INFO log line without passing through `contract/redaction.rb`. No message may render a caller's Hash key or value. Locate a failing entry by ordinal.
- **Bounds:** `Internal::ShapeGraph::MAX_NESTING` (64) and `MAX_MEMBER_PATHS` (25_000) are one budget each across BOTH edge types. Depth comparison is `>` (a graph exactly at the cap is legal), matching every existing walk.
- **Copy discipline.** A caller-supplied container that a declaration stores is copied entry-wise, never aliased. An already-frozen container may be stored as-is. `reject_defaulting_option_container!` applies to every bag stored.
- **Error messages** explain the problem *and* the fix.
- **Never assert on `Hash#inspect` text** — its formatting differs across the supported Ruby matrix. Build expected strings explicitly.
- **CHANGELOG** every user-visible change under `## Unreleased`, tagged `[FEAT]` / `[BREAKING]` / `[BUGFIX]` / `[INTERNAL]`.
- Run `bundle exec rspec` before each commit. Run `bundle exec rubocop` before each commit.

## File Structure

**Created:**
- `lib/axn/core/validation/container_contents.rb` — the one-line `Validation::Fields` subclass whose attribute read answers the source itself, so an unnamed position can be validated by the normal pipeline.
- `spec/axn/core/validations/recursive_of_spec.rb` — the declaration + runtime failure grid for the new positions.
- `spec/axn/core/contract/canonical_storage_spec.rb` — stored-config assertions; the net that proves all four descent seams read one shape.

**Modified:**
- `lib/axn/internal/shape_graph.rb` — `ANY_CONTAINER`, `inner_contracts`, position constants.
- `lib/axn/core/contract.rb` — the `of:` grammar (`OF_OPTION_KEYS`, `_canonical_array_of!`, `_canonical_map_of!`, the axis checks), the exempt-key derivation, and the forward canonicalization of the flat form.
- `lib/axn/core/contract/shape_declaration.rb` — the fused walk: descend `of:` bags, charge them, guard them, copy them.
- `lib/axn/core/validation/validators/of_validator.rb` — recursion, the `check_validity!` relaxation, the exemption skip.
- `lib/axn/core/validation/validators/shape_validator.rb` — `ANY_CONTAINER` handling.
- `lib/axn/internal/reflection/schema.rb` — the nameless-node builder; `properties` + `additionalProperties` at one node.
- `lib/axn/internal/reflection/property_names.rb` — `count_emitted_properties!` charges the new rung.
- `lib/axn/core/contract/redaction.rb` — descend the new edge.
- `lib/axn/core/ambient_context.rb` — descend the new edge.
- `docs/reference/class.md`, `CHANGELOG.md`.

**Task ordering rationale.** Tasks 1–8 are **additive**: the flat `type: Array … shape:` form keeps working unchanged throughout, and every seam learns the new edge while the old one still exists. Task 9 is the flip, isolated on its own with the stored-config assertions as its net. That ordering means no task has to change a seam and re-point its producer in the same commit.

---

### Task 1: The sentinel and the child-enumerator

**Files:**
- Modify: `lib/axn/internal/shape_graph.rb`
- Create: `spec/axn/internal/shape_graph_spec.rb` (does not exist yet — this task creates it)

**Interfaces:**
- Produces: `Axn::Internal::ShapeGraph::ANY_CONTAINER` (a Module); `Axn::Internal::ShapeGraph::ELEMENT_POSITION` (`:[]`), `KEYS_POSITION` (`:keys`), `VALUES_POSITION` (`:values`); `Axn::Internal::ShapeGraph.inner_contracts(validations) -> [[position, bag], …]`.

- [ ] **Step 1: Write the failing test**

Create `spec/axn/internal/shape_graph_spec.rb` with the standard `# frozen_string_literal: true` header and `RSpec.describe Axn::Internal::ShapeGraph do … end` wrapper, containing:

```ruby
describe ".inner_contracts" do
  subject(:positions) { described_class.inner_contracts(validations) }

  context "with no of:" do
    let(:validations) { { type: { klass: Array } } }

    it "yields nothing" do
      expect(positions).to eq([])
    end
  end

  context "with an Array's of: bag" do
    let(:validations) { { of: { klass: String, container: Array } } }

    it "yields the bag itself at the element position" do
      expect(positions).to eq([[described_class::ELEMENT_POSITION, { klass: String, container: Array }]])
    end
  end

  context "with a map's axis bag" do
    let(:validations) { { of: { keys: { klass: String }, values: { klass: Integer }, container: Hash } } }

    it "yields each axis that carries a bag" do
      expect(positions).to eq([[described_class::KEYS_POSITION, { klass: String }],
                               [described_class::VALUES_POSITION, { klass: Integer }]])
    end
  end

  context "with a map axis naming a bare type" do
    let(:validations) { { of: { values: Integer, container: Hash } } }

    it "yields nothing for that axis, since a bare type has no inner contract" do
      expect(positions).to eq([])
    end
  end

  context "with an of: that is not a Hash" do
    let(:validations) { { of: String } }

    it "yields nothing rather than raising" do
      expect(positions).to eq([])
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bundle exec rspec spec/axn/internal/shape_graph_spec.rb -e "inner_contracts"`
Expected: FAIL with `NameError: uninitialized constant Axn::Internal::ShapeGraph::ELEMENT_POSITION`

- [ ] **Step 3: Implement the sentinel and the enumerator**

In `lib/axn/internal/shape_graph.rb`, beside `NOT_DEFINED` (near line 428):

```ruby
      # The container of a `shape:` whose position names no class — an `of:` bag that constrains its
      # contents by members alone (`of: { shape: … }`). A Module rather than a bare `nil` because
      # ABSENCE already means something here: it is the bug signature `_derive_raw_shape_container!`
      # exists to catch, a shape that never got a container derived and fails every call with a bare
      # `TypeError: class or module required`. Being a Module also satisfies the "a container must be a
      # class" guard without a special case there. `ShapeValidator` tests it by IDENTITY, with this
      # constant as the receiver, and never with `is_a?` — nothing is an instance of it.
      ANY_CONTAINER = ::Module.new do
        def self.name = "Axn::Internal::ShapeGraph::ANY_CONTAINER"
        def self.to_s = name
      end

      # Where an inner contract can sit. Logical positions, not schema path segments: reflection maps
      # these onto its own `items`/`additionalProperties` spelling, so the declaration layer does not
      # carry the emitter's vocabulary.
      ELEMENT_POSITION = :[]
      KEYS_POSITION = :keys
      VALUES_POSITION = :values
      MAP_POSITIONS = [KEYS_POSITION, VALUES_POSITION].freeze

      EMPTY_INNER_CONTRACTS = [].freeze
      private_constant :EMPTY_INNER_CONTRACTS

      # THE one answer to "what containers sit inside this node", shared by the declaration walk, the
      # redaction walk, the ambient walk and reflection — so no two of them can descend a different set.
      #
      # An ARRAY's `of:` bag IS the inner contract (one element position). A HASH's `of:` bag is the axis
      # bag, and the inner contracts are its axis VALUES — only where an axis carries a bag, since a bare
      # type names a class and has nothing inside it. Read through `hash_or_nil` throughout: the bag may be
      # a config ASSIGNED onto a class rather than one this DSL canonicalized, so an `of:` that is not a
      # Hash answers "nothing inside" rather than raising.
      def self.inner_contracts(validations)
        bag = hash_or_nil(validations && validations[:of])
        return EMPTY_INNER_CONTRACTS if nil.equal?(bag)

        return [[ELEMENT_POSITION, bag]] unless ::Hash.equal?(bag[:container])

        MAP_POSITIONS.filter_map do |axis|
          inner = hash_or_nil(bag[axis])
          inner && [axis, inner]
        end
      end
```

- [ ] **Step 4: Run it to verify it passes**

Run: `bundle exec rspec spec/axn/internal/shape_graph_spec.rb -e "inner_contracts"`
Expected: PASS

- [ ] **Step 5: Run the full suite and rubocop**

Run: `bundle exec rspec && bundle exec rubocop`
Expected: PASS — nothing consumes the new constants yet.

- [ ] **Step 6: Commit**

```bash
git add lib/axn/internal/shape_graph.rb spec/axn/internal/shape_graph_spec.rb
git commit -m "PRO-3166: the ANY_CONTAINER sentinel and the one inner-contract enumerator"
```

---

### Task 2: A nested `of:` inside an Array's element bag

Declaration, walk, bounds and runtime for `of: { klass: Array, of: Integer }`, end to end. Schema follows in Task 3.

**Files:**
- Create: `lib/axn/core/validation/container_contents.rb`
- Create: `spec/axn/core/validations/recursive_of_spec.rb`
- Modify: `lib/axn/core/contract.rb` (`OF_OPTION_KEYS`, `_canonical_array_of!`)
- Modify: `lib/axn/core/contract/shape_declaration.rb` (the walk descends `of:`)
- Modify: `lib/axn/core/validation/validators/of_validator.rb`
- Modify: `lib/axn/core/contract.rb:13` — the one place `axn/core/validation/fields` is required (there is no `lib/axn/core/validation.rb`)

**Interfaces:**
- Consumes: `ShapeGraph.inner_contracts`, `ShapeGraph::ELEMENT_POSITION` (Task 1).
- Produces: `Axn::Validation::ContainerContents` (a `Validation::Fields` subclass); an `of:` bag may carry `:of`; the declaration walk descends `of:` bags charging `MAX_NESTING` and `MAX_MEMBER_PATHS`.

- [ ] **Step 1: Write the failing tests**

Create `spec/axn/core/validations/recursive_of_spec.rb`:

```ruby
# frozen_string_literal: true

RSpec.describe "recursive of:" do
  describe "an Array of Arrays" do
    let(:action) { build_axn { expects :matrix, type: Array, of: { klass: Array, of: Integer } } }

    it "passes when every inner element matches" do
      expect(action.call(matrix: [[1, 2], [3]])).to be_ok
    end

    it "fails when an inner element does not match, naming both positions" do
      result = action.call(matrix: [[1, 2], [3, "four"]])
      expect(result).not_to be_ok
      expect(result.exception.message).to include("element at index 1: element at index 1 is not a Integer")
    end

    it "fails when an outer element is not an Array" do
      result = action.call(matrix: [[1], 2])
      expect(result).not_to be_ok
      expect(result.exception.message).to include("element at index 1 is not a Array")
    end
  end

  describe "declaration-time refusals" do
    it "refuses an of: bag naming no container but carrying of:" do
      expect { build_axn { expects :m, type: Array, of: { of: Integer } } }
        .to raise_error(ArgumentError, /names no container/)
    end

    it "refuses a nested of: under a scalar klass" do
      expect { build_axn { expects :m, type: Array, of: { klass: String, of: Integer } } }
        .to raise_error(ArgumentError, /of: requires type: Array or Hash/)
    end

    it "refuses a nested of: under a union klass" do
      expect { build_axn { expects :m, type: Array, of: { klass: [Array, Hash], of: Integer } } }
        .to raise_error(ArgumentError, /of: requires type: Array or Hash/)
    end
  end

  describe "bounds" do
    def nested_of(depth)
      depth.zero? ? Integer : { klass: Array, of: nested_of(depth - 1) }
    end

    it "accepts a graph exactly at MAX_NESTING" do
      bag = nested_of(Axn::Internal::ShapeGraph::MAX_NESTING)
      expect { build_axn { expects :m, type: Array, of: bag } }.not_to raise_error
    end

    it "refuses a graph one level deeper" do
      bag = nested_of(Axn::Internal::ShapeGraph::MAX_NESTING + 1)
      expect { build_axn { expects :m, type: Array, of: bag } }
        .to raise_error(ArgumentError, /levels deep/)
    end

    it "refuses an of: bag that contains itself" do
      bag = { klass: Array }
      bag[:of] = bag
      expect { build_axn { expects :m, type: Array, of: bag } }
        .to raise_error(ArgumentError, /contains itself|levels deep/)
    end
  end

  describe "the caller's bag is copied, not aliased" do
    it "does not carry a later mutation into a declared contract" do
      inner = { klass: Integer }
      action = build_axn { expects :m, type: Array, of: { klass: Array, of: inner } }
      inner[:klass] = String

      expect(action.call(m: [[1]])).to be_ok
    end
  end
end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bundle exec rspec spec/axn/core/validations/recursive_of_spec.rb`
Expected: FAIL — `ArgumentError: of: does not support of: (supported: klass:, message:, …)`

- [ ] **Step 3: Open the grammar**

In `lib/axn/core/contract.rb`, replace the `OF_OPTION_KEYS` definition:

```ruby
        # What an `of:` bag may carry. `of:` and `shape:` are the recursion (PRO-3166): a bag describes one
        # unnamed position, and a position may hold a container of its own. Everything else is refused rather
        # than ignored — the bag reaches `OfValidator` as an EachValidator options hash, which reads the keys
        # it knows and drops the rest, so an unrecognized key declares cleanly and constrains nothing.
        #
        # `on:` is admitted here and refused by `_reject_validator_context_scope!`, which names the actual
        # problem (axn has no validation contexts) instead of reporting the key as unknown.
        OF_OPTION_KEYS = (Set.new(%i[klass of shape message]) | Axn::Validation::Base.shared_validation_option_keys).freeze
```

Replace `_canonical_array_of!`:

```ruby
        # An Array holds one kind of thing, so the bare form says everything there is to say and expands into
        # the bag `OfValidator` reads. A bag has to CONSTRAIN something: `klass:` names the element's class,
        # `of:` names what is inside it, `shape:` names its members — a bag with none of the three is the
        # silent no-op this option exists to refuse.
        def _canonical_array_of!(validations, fields)
          bag = Axn::Validators::OfValidator.apply_syntactic_sugar(validations[:of], fields)
          _reject_unknown_of_keys!(bag, OF_OPTION_KEYS)
          _reject_unconstraining_of_bag!(bag)
          _canonicalize_inner_contract!(bag, fields)

          bag.merge(container: ::Array)
        end

        # The three axes a bag can constrain on. Keyed on `key?` rather than on truthiness, so a supplied-but-
        # empty axis is caught by its own check rather than reported as an absent one.
        INNER_CONTRACT_AXES = %i[klass of shape].freeze

        def _reject_unconstraining_of_bag!(bag)
          return if INNER_CONTRACT_AXES.any? { |axis| Internal::ShapeGraph.carries_key?(bag, axis) && !bag[axis].nil? }

          raise ArgumentError,
                "of: must constrain something — name the contents' class with `klass:`, what is inside them " \
                "with `of:`, or their members with `shape:`"
        end

        # A bag's own `of:` is held to exactly the grammar a FIELD's is, with `klass:` in `type:`'s role: the
        # class it names decides whether the inner bag is read as an Array's element or as a map's axes. One
        # function, so a container two levels down is judged by the same rules as one at the top.
        def _canonicalize_inner_contract!(bag, fields)
          return unless Internal::ShapeGraph.carries_key?(bag, :of)

          container = _inner_of_container!(bag)
          _drop_derived_of_container!(bag, container)
          bag[:of] = container.equal?(::Hash) ? _canonical_map_of!(bag) : _canonical_array_of!(bag, fields)
        end

        # The same derivation `_of_container!` makes for a field, reading the bag's `klass:` instead of the
        # field's `type:`. A bag naming no class at all is refused here rather than guessing: with no container
        # named there is no way to tell the Array grammar from the Hash grammar.
        def _inner_of_container!(bag)
          raise ArgumentError, "of: names no container, so its own `of:` has no reading — add `klass: Array` " \
                               "or `klass: Hash`" unless Internal::ShapeGraph.carries_key?(bag, :klass)

          _of_container!({ type: { klass: bag[:klass] } })
        end
```

Note: `_canonical_map_of!` and `_of_container!` both read a `validations`-shaped Hash today. `_canonicalize_inner_contract!` passes the BAG in the `validations` slot, which works because both read only `[:of]`, `[:shape]` and `[:type]` — verify that in Step 4 and adjust `_canonical_map_of!`'s signature to take the bag directly if it reads anything else.

- [ ] **Step 4: Make the declaration walk descend the new edge**

In `lib/axn/core/contract/shape_declaration.rb`, inside `_check_and_copy_shape_members!` the walk already descends a member's `shape:`. Add the sibling descent, and add a top-level entry point. After the `WalkedShape` definition, add:

```ruby
        # An `of:` bag is the other kind of child a node has, and it is bounded on exactly the terms a nested
        # `shape:` is: one depth counter (a graph 64 `of:` deep by 64 `shape:` deep is 128 levels of walking,
        # which two counters would admit), one path allowance (a bag SHARED between siblings multiplies 2^N
        # exactly as a shared shape does), and one cycle guard (`h[:of] = h` is reachable by hand). Returns the
        # copy to store, so the caller keeps nothing live in a declared contract.
        def _walk_inner_contracts!(validations, walk, allowance, via:, via_name:)
          Internal::ShapeGraph.inner_contracts(validations).each do |_position, bag|
            _spend_paths!(allowance, 1)
            _raise_shape_too_deep!(via, via_name) if walk.depth > Internal::ShapeGraph::MAX_NESTING

            walked = Axn::Internal::CycleGuard.guard(bag, walk.seen, on_cycle: CYCLIC_SHAPE) do |nested|
              child = walk.with(seen: nested, depth: walk.depth + 1)
              _snapshot_declared_shape!(bag, [via_name].compact) if Internal::ShapeGraph.hash_or_nil(bag[:shape])
              _walk_inner_contracts!(bag, child, allowance, via:, via_name:)
              bag
            end
            _raise_cyclic_shape!(via, via_name) if CYCLIC_SHAPE.equal?(walked)
          end
        end
```

Then call it from the two places a node is finished: at the end of `_check_and_copy_shape_members!`'s per-member block (for a member's own `of:`), and from `Contract#_parse_field_validations` right after `_canonicalize_validator_options!` (for the field's). Add to the `private_class_method`/`private` list at `shape_declaration.rb:558`.

- [ ] **Step 5: Run the declaration tests**

Run: `bundle exec rspec spec/axn/core/validations/recursive_of_spec.rb -e "declaration-time refusals" -e "bounds" -e "copied"`
Expected: PASS. The runtime examples still FAIL.

- [ ] **Step 6: Add the unnamed-position validator source**

Create `lib/axn/core/validation/container_contents.rb`:

```ruby
# frozen_string_literal: true

require "axn/core/validation/fields"

module Axn
  module Validation
    # Validates the value at an UNNAMED position — an array element, a map key, a map value — against a
    # contract of its own. `Fields` reads a NAMED attribute off its source; here the source IS the value, so
    # the read answers it whatever attribute is asked for. That one override is the whole difference, which is
    # what lets an inner contract run through the ordinary validator pipeline: `type:`, a recursive `of:` and
    # a `shape:` all apply at an unnamed position exactly as they do at a named one, at any depth.
    #
    # ActiveModel's `error.message` excludes the attribute name, so the synthetic name the one-off class is
    # built under never reaches a message — the enclosing `OfValidator` supplies the positional prefix.
    class ContainerContents < Fields
      def read_attribute_for_validation(_attr) = @source
    end
  end
end
```

Add `require "axn/core/validation/container_contents"` beside the existing `require "axn/core/validation/fields"` at `lib/axn/core/contract.rb:13`.

- [ ] **Step 7: Make `OfValidator` recurse**

In `lib/axn/core/validation/validators/of_validator.rb`, replace `validate_elements` and add the helpers:

```ruby
      def validate_elements(record, attribute, value)
        return unless value.is_a?(::Array)

        klasses = Array(options[:klass])
        # A custom message: replaces the type description but the index is always reported —
        # element position is the locating info that makes a per-element error actionable.
        msg = options[:message] || describe_mismatch(klasses)

        value.each_with_index do |el, i|
          # allow_blank governs whether the whole field may be absent (handled above), not whether
          # individual elements may be blank — so it is intentionally not passed to the matcher.
          record.errors.add(attribute, "element at index #{i} #{msg}") unless matches_axis?(el, klasses)
          # The type verdict does NOT gate the contents check: a wrong-typed element still reports what its
          # members could not be read from, which is what the pre-recursion pairing of OfValidator and
          # ShapeValidator did (both ran, independently) and what an author fixing a payload needs.
          add_contents_errors(record, attribute, el, "element at index #{i}: ")
        end
      end

      # The inner contract this bag declares, as a VALIDATIONS bag: `klass:` is deliberately absent, because
      # the type check is performed above and its message ("element at index 0 is not a String" — no colon)
      # differs in punctuation from a delegated one. Nil when the bag constrains only a class, which is the
      # overwhelmingly common case and the one that must allocate nothing.
      def contents_validations
        return @contents_validations if defined?(@contents_validations)

        inner = {}
        inner[:of] = options[:of] if options[:of]
        inner[:shape] = options[:shape] if options[:shape]
        @contents_validations = inner.empty? ? nil : inner
      end

      # One validator class per bag, built once and reused across every element/entry, exactly as
      # ShapeValidator caches its per-member classes.
      def contents_validator_class
        @contents_validator_class ||=
          Axn::Validation::ContainerContents.validator_class_for(field: :__axn_contents__, validations: contents_validations)
      end

      def add_contents_errors(record, attribute, value, prefix)
        return if nil.equal?(contents_validations)

        Axn::Validation::Fields.errors_for(
          contents_validator_class, source: value, validations: contents_validations,
          action: record.send(:_action_for_validation),
          # A shape member's own `method_call:` opt-in is honored by ShapeValidator per member; nothing at
          # this level may re-permit dispatch on the caller's object.
          permit_method_call: false,
          shape_ancestry: record.send(:_shape_ancestry_for_validation)
        ).each { |error| record.errors.add(attribute, "#{prefix}#{error.message}") }
      end
```

- [ ] **Step 8: Run the task's tests**

Run: `bundle exec rspec spec/axn/core/validations/recursive_of_spec.rb`
Expected: PASS

- [ ] **Step 9: Run the full suite and rubocop**

Run: `bundle exec rspec && bundle exec rubocop`
Expected: PASS. If `of_validator_spec.rb` fails on a message, the punctuation rule in Step 7 was not preserved — fix the implementation, never the existing expectation.

- [ ] **Step 10: Commit**

```bash
git add lib/axn spec/axn
git commit -m "PRO-3166: a nested of: inside an Array's element bag"
```

---

### Task 3: Emit the nested rung, and charge it

**Files:**
- Modify: `lib/axn/internal/reflection/schema.rb`
- Modify: `lib/axn/internal/reflection/property_names.rb`
- Test: `spec/axn/internal/reflection/schema_spec.rb`, `spec/axn/core/validations/property_name_collision_spec.rb`

**Interfaces:**
- Consumes: the `of:` bag may carry `:of` (Task 2).
- Produces: `Schema.contents_node_schema(bag, for_output:) -> Hash` — the schema for one unnamed position, shared by the field emitter and the recursion.

- [ ] **Step 1: Write the failing tests**

Append to `spec/axn/internal/reflection/schema_spec.rb`:

```ruby
describe "a recursive of:" do
  it "emits items inside items" do
    action = build_axn { expects :matrix, type: Array, of: { klass: Array, of: Integer } }

    expect(action.input_schema[:properties][:matrix]).to include(
      type: "array",
      items: { type: "array", items: { type: "integer" } }
    )
  end

  it "emits a union at the inner rung as anyOf" do
    action = build_axn { expects :m, type: Array, of: { klass: Array, of: [String, Integer] } }

    expect(action.input_schema.dig(:properties, :m, :items, :items)).to eq(
      anyOf: [{ type: "string" }, { type: "integer" }]
    )
  end

  it "emits a map nested inside an array" do
    action = build_axn { expects :m, type: Array, of: { klass: Hash, of: { values: Integer } } }

    expect(action.input_schema.dig(:properties, :m, :items)).to include(
      type: "object", additionalProperties: { type: "integer" }
    )
  end
end
```

Append to `spec/axn/core/validations/property_name_collision_spec.rb`:

```ruby
it "charges properties named beneath a nested of: against the projection cap" do
  point = Data.define(:x, :y)
  action = build_axn { expects :m, type: Array, of: { klass: Array, of: point } }

  # The Data class's own members reach items.items, so they are charged there rather than nowhere.
  expect(action.input_schema.dig(:properties, :m, :items, :items, :properties).keys).to eq(%i[x y])
end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bundle exec rspec spec/axn/internal/reflection/schema_spec.rb -e "a recursive of:"`
Expected: FAIL — `items` is `{ type: "array" }` with no inner `items`.

- [ ] **Step 3: Extract the nameless-node builder**

In `lib/axn/internal/reflection/schema.rb`, beside `contents_schema_for` (line 1609):

```ruby
        # The schema for ONE unnamed position — an array element, a map value. The node an `of:` bag
        # describes, built from the same three ingredients a field's node is: its declared type
        # (`contents_schema_for`), its own `of:` contents, and its `shape:` members. Shared with
        # `apply_structured_schema!` so the emitter and every rule derived from it charge the same nodes.
        #
        # A union type keeps the merge order `apply_structured_schema!` has always used: the structural keys
        # land beside the `anyOf` at this node rather than inside each branch. That is existing behavior,
        # preserved deliberately rather than corrected here.
        def contents_node_schema(bag, for_output: false)
          node = bag[:klass] ? contents_schema_for(bag[:klass], for_output:) : {}
          inner = Axn::Internal::ShapeGraph.hash_or_nil(bag[:of])
          return node if nil.equal?(inner)

          if ::Hash.equal?(inner[:container])
            values = Array(inner[:values])
            klasses = values.reject { |v| v.is_a?(::Hash) }
            nested = Axn::Internal::ShapeGraph.hash_or_nil(inner[:values])
            contents = nested ? contents_node_schema(nested, for_output:) : (klasses.empty? ? {} : contents_schema_for(klasses, for_output:))
            node = node.merge(type: "object", additionalProperties: contents) unless contents.empty?
          else
            contents = contents_node_schema(inner, for_output:)
            node = node.merge(items: contents) unless contents.empty?
          end
          node
        end
```

Then in `shape_property_plan`'s `in_items` branch, replace `contents_schema_for(of[:klass], for_output:)` with `contents_node_schema(of, for_output:)`.

- [ ] **Step 4: Run the schema tests**

Run: `bundle exec rspec spec/axn/internal/reflection/schema_spec.rb`
Expected: PASS

- [ ] **Step 5: Charge the new rung in the cap walk**

In `lib/axn/internal/reflection/property_names.rb`, `count_emitted_properties!` currently descends `plan.shape`'s members only. After the `each_type_namespace` charge, add the inner-contract descent:

```ruby
          # A container's CONTENTS are a node the emitter builds and this walk must charge: `each_emitted_node`
          # sees them because it walks the emitted schema, but this walk descends DECLARATIONS, so a rung it
          # cannot step is a rung it cannot charge — and a recursive `of:` would cost nothing at all.
          Internal::ShapeGraph.inner_contracts(validations).each do |position, bag|
            segment = position == Internal::ShapeGraph::VALUES_POSITION ? VALUES_SEGMENT : ITEMS_SEGMENT
            next if position == Internal::ShapeGraph::KEYS_POSITION # keys: emits nothing, so it names nothing

            count_emitted_properties!(budget, ContentsOwner.new(bag), budget.namespace(node, segment),
                                      seen, depth + 1, via:, for_output:, &label)
          end
```

with a tiny adapter beside `CYCLIC_SHAPE`, since `count_emitted_properties!` reads `validations` off an owner:

```ruby
        # An `of:` bag presented as something with `validations`, so the counting walk reaches a container's
        # contents through its one existing entry point rather than a parallel copy of it.
        ContentsOwner = Struct.new(:validations)
        private_constant :ContentsOwner
```

- [ ] **Step 6: Run the collision/cap tests**

Run: `bundle exec rspec spec/axn/core/validations/property_name_collision_spec.rb`
Expected: PASS

- [ ] **Step 7: Full suite, rubocop, commit**

```bash
bundle exec rspec && bundle exec rubocop
git add lib/axn spec/axn
git commit -m "PRO-3166: emit and charge a container nested inside a container"
```

---

### Task 4: A `shape:` inside an `of:` bag

**Files:**
- Modify: `lib/axn/core/contract.rb` (`_canonicalize_inner_contract!` handles `shape:`), `lib/axn/core/contract/shape_declaration.rb`
- Modify: `lib/axn/core/validation/validators/of_validator.rb` (`check_validity!`), `lib/axn/core/validation/validators/shape_validator.rb` (`ANY_CONTAINER`)
- Test: `spec/axn/core/validations/recursive_of_spec.rb`

**Interfaces:**
- Consumes: `ANY_CONTAINER` (Task 1), `contents_validations` (Task 2), `contents_node_schema` (Task 3).
- Produces: an `of:` bag may carry `:shape`; a bag with no `klass:` is legal when it carries `of:` or `shape:`.

- [ ] **Step 1: Write the failing tests**

Append to `spec/axn/core/validations/recursive_of_spec.rb`:

```ruby
describe "a shape: inside an of: bag" do
  let(:shape) { { members: [Axn::Core::Contract::ShapeConfig.new(field: :sku, validations: { type: { klass: String } })] } }

  it "validates each element's members" do
    action = build_axn { expects :rows, type: Array, of: { klass: Hash, shape: shape } }

    expect(action.call(rows: [{ sku: "a" }])).to be_ok
    result = action.call(rows: [{ sku: 1 }])
    expect(result).not_to be_ok
    expect(result.exception.message).to include("element at index 0: sku is not a String")
  end

  it "accepts a bag constraining by members alone, with no klass:" do
    action = build_axn { expects :rows, type: Array, of: { shape: shape } }

    expect(action.call(rows: [{ sku: "a" }])).to be_ok
    expect(action.call(rows: [{ sku: 1 }])).not_to be_ok
  end

  it "emits the members as items.properties" do
    action = build_axn { expects :rows, type: Array, of: { klass: Hash, shape: shape } }

    expect(action.input_schema.dig(:properties, :rows, :items)).to include(
      type: "object", properties: { sku: { type: "string" } }
    )
  end

  it "recurses two containers deep with members at the bottom" do
    action = build_axn { expects :m, type: Array, of: { klass: Array, of: { klass: Hash, shape: shape } } }

    result = action.call(m: [[{ sku: 1 }]])
    expect(result).not_to be_ok
    expect(result.exception.message).to include("element at index 0: element at index 0: sku is not a String")
  end
end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bundle exec rspec spec/axn/core/validations/recursive_of_spec.rb -e "a shape: inside"`
Expected: FAIL — `ArgumentError: of: does not support shape:` is already gone (Task 2 opened the key), so expect a `TypeError` or a missing-container failure instead. Record the actual message.

- [ ] **Step 3: Derive the shape's container inside a bag**

In `_canonicalize_inner_contract!` (Task 2), add the shape branch before the `of:` branch:

```ruby
          if Internal::ShapeGraph.carries_key?(bag, :shape) && !nil.equal?(Internal::ShapeGraph.hash_or_nil(bag[:shape]))
            # A shape inside a bag names the members of the value AT THAT POSITION — never "each element of
            # it", which is the distributing reading `shape:` has only at a field under `type: Array` and
            # which PRO-3191 removes. So the container is the bag's own `klass:` when it names one single
            # structured type, and the explicit "no gate" sentinel when it names none.
            detached = Internal::ShapeGraph.detach_node(Internal::ShapeGraph.hash_or_nil(bag[:shape]))
            if nil.equal?(detached[:container])
              detached[:container] = Internal::ShapeGraph.carries_key?(bag, :klass) ? _shape_compatible_type!({ type: { klass: bag[:klass] } }) : Internal::ShapeGraph::ANY_CONTAINER
            end
            _reject_non_class_container!(detached[:container])
            bag[:shape] = detached
          end
```

- [ ] **Step 4: Relax `check_validity!` and teach `ShapeValidator` the sentinel**

In `of_validator.rb`:

```ruby
      # A map names its axes with `keys:`/`values:`, either of which may be left off. An element bag names
      # `klass:` only when that is what it constrains — a bag constraining by `of:` or `shape:` names no class
      # deliberately (`of: { shape: … }` is "each element has these members, class unconstrained"), and the
      # declaration guard has already refused a bag constraining none of the three.
      def check_validity!
        return if options[:container] == ::Hash
        return if options[:of] || options[:shape]

        raise ArgumentError, "must supply :klass" if options[:klass].nil?
      end
```

In `shape_validator.rb`, replace the container dispatch in `validate_each`:

```ruby
      def validate_each(record, attribute, value)
        return if value.nil? && (options[:allow_nil] || options[:allow_blank])

        container = options[:container]
        if container == Array
          return unless value.is_a?(Array) # TypeValidator owns the non-Array error

          value.each_with_index do |element, index|
            validate_members(record, attribute, element, prefix: "element at index #{index}: ")
          end
        else
          # ANY_CONTAINER: the enclosing `of:` bag named no class, so there is no type to gate on and the
          # members are read off whatever arrived — `extractable?` still reports a value they cannot be read
          # from. Identity with the sentinel as the RECEIVER, so nothing a caller supplied answers the question.
          unless Axn::Internal::ShapeGraph::ANY_CONTAINER.equal?(container)
            return unless value.is_a?(container) # TypeValidator owns the type mismatch
          end

          validate_members(record, attribute, value, prefix: "")
        end
      end
```

- [ ] **Step 5: Make the walk snapshot a bag's shape**

Task 2's `_walk_inner_contracts!` already calls `_snapshot_declared_shape!` on a bag carrying a shape. Verify the members of that shape are walked with the SAME allowance and depth as the enclosing bag (they must share the budget, not restart it) — if `_snapshot_declared_shape!` starts a fresh allowance, replace that call with a direct `_walk_shape_graph!(bag[:shape], child, allowance, via:, via_name:)` and store `.copy`.

- [ ] **Step 6: Run the task's tests, then the full suite**

Run: `bundle exec rspec spec/axn/core/validations/recursive_of_spec.rb && bundle exec rspec && bundle exec rubocop`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add lib/axn spec/axn
git commit -m "PRO-3166: a shape: inside an of: bag, and the no-container-gate sentinel"
```

---

### Task 5: Inner bags on the map axes, and a per-axis `message:`

**Files:**
- Modify: `lib/axn/core/contract.rb` (`_reject_nested_map_contract!` becomes the axis canonicalizer; `MAP_OF_OPTION_KEYS`)
- Modify: `lib/axn/core/validation/validators/of_validator.rb` (`validate_entries`)
- Modify: `lib/axn/internal/reflection/schema.rb`
- Test: `spec/axn/core/validations/recursive_of_spec.rb`

**Interfaces:**
- Consumes: everything from Tasks 2–4.
- Produces: a map axis may hold an inner-contract bag; an axis bag may carry `message:`.

- [ ] **Step 1: Write the failing tests**

```ruby
describe "a map whose values carry a contract" do
  let(:shape) { { members: [Axn::Core::Contract::ShapeConfig.new(field: :sku, validations: { type: { klass: String } })] } }

  it "validates each value's members, located by ordinal" do
    action = build_axn { expects :by_region, type: Hash, of: { values: { klass: Hash, shape: shape } } }

    expect(action.call(by_region: { "acme" => { sku: "a" } })).to be_ok
    result = action.call(by_region: { "acme" => { sku: 1 } })
    expect(result).not_to be_ok
    expect(result.exception.message).to include("value at index 0: sku is not a String")
  end

  it "never renders a key, so a sensitive map's keys cannot leak" do
    action = build_axn { expects :m, type: Hash, of: { values: { klass: Integer } } }

    result = action.call(m: { "secret-customer-id" => "x" })
    expect(result.exception.message).not_to include("secret-customer-id")
    expect(result.exception.message).to include("value at index 0 is not a Integer")
  end

  it "takes a per-axis message:" do
    action = build_axn { expects :m, type: Hash, of: { values: { klass: Integer, message: "must be a whole number" } } }

    expect(action.call(m: { a: "x" }).exception.message).to include("value at index 0 must be a whole number")
  end

  it "validates a nested bag on the keys: axis, and emits nothing for it" do
    action = build_axn { expects :m, type: Hash, of: { keys: { klass: String }, values: Integer } }

    expect(action.call(m: { "a" => 1 })).to be_ok
    expect(action.call(m: { a: 1 })).not_to be_ok
    expect(action.input_schema.dig(:properties, :m)).not_to have_key(:propertyNames)
  end

  it "emits a map of shaped records as additionalProperties" do
    action = build_axn { expects :m, type: Hash, of: { values: { klass: Hash, shape: shape } } }

    expect(action.input_schema.dig(:properties, :m, :additionalProperties)).to include(
      type: "object", properties: { sku: { type: "string" } }
    )
  end

  it "still refuses a bag-level message:, which cannot say which axis failed" do
    expect { build_axn { expects :m, type: Hash, of: { values: Integer, message: "x" } } }
      .to raise_error(ArgumentError, /does not support message:/)
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bundle exec rspec spec/axn/core/validations/recursive_of_spec.rb -e "a map whose values"`
Expected: FAIL — `of: values: takes a type, not a nested contract — that is not supported yet`

- [ ] **Step 3: Replace the axis refusal with the axis canonicalizer**

In `contract.rb`, delete `_reject_nested_map_contract!` and its call, and add:

```ruby
        # An axis takes the same forms `type:` does — a class, a union of them, a `:boolean`/`:uuid`/`:params`
        # symbol — OR a contract of its own, which is the same inner-contract bag an Array's element takes.
        # One grammar in three positions, so a map's values are held to exactly what an array's elements are.
        def _canonicalize_map_axes!(bag, fields)
          MAP_OF_AXES.each do |axis|
            inner = Internal::ShapeGraph.hash_or_nil(bag[axis])
            next if nil.equal?(inner)

            bag[axis] = _canonical_axis_contract!(inner, fields)
          end
        end

        def _canonical_axis_contract!(inner, fields)
          copy = Internal::ShapeGraph.detached_option_bag(:of, inner)
          _reject_unknown_of_keys!(copy, OF_OPTION_KEYS)
          _reject_unconstraining_of_bag!(copy)
          _canonicalize_inner_contract!(copy, fields)
          copy
        end
```

Call `_canonicalize_map_axes!(bag, fields)` from `_canonical_map_of!` in place of `_reject_nested_map_contract!(bag)`, and change `_canonical_map_of!` to accept `fields`. `_reject_unsupported_map_axis!` must skip an axis holding a Hash (that axis is now a contract, judged by `_canonical_axis_contract!`) — its existing "runs after the nested-contract check" comment already assumes that order; keep it.

- [ ] **Step 4: Recurse in `validate_entries`**

```ruby
      def validate_entries(record, attribute, value)
        return unless value.is_a?(::Hash)

        index = 0
        Axn::Internal::ShapeGraph.each_entry(value) do |key, entry|
          validate_axis(record, attribute, options[:keys], key, "key at index #{index}")
          validate_axis(record, attribute, options[:values], entry, "value at index #{index}")
          index += 1
        end
      end

      # One axis of one entry. An axis holding a BAG is a contract of its own and runs through the same
      # element machinery: its class check reports here, and its `of:`/`shape:` contents report under a
      # positional prefix. An axis holding a bare type (or absent) is the type check alone.
      def validate_axis(record, attribute, declared, value, position)
        bag = Axn::Internal::ShapeGraph.hash_or_nil(declared)
        klasses = Array(bag ? bag[:klass] : declared)
        msg = (bag && bag[:message]) || describe_mismatch(klasses)
        record.errors.add(attribute, "#{position} #{msg}") unless matches_axis?(value, klasses)
        return if nil.equal?(bag)

        add_axis_contents_errors(record, attribute, bag, value, "#{position}: ")
      end
```

`add_axis_contents_errors` mirrors `add_contents_errors` from Task 2 but builds its validations from the AXIS bag rather than from `options`; memoize the built class per axis so it is built once per declaration, not once per entry.

- [ ] **Step 5: Emit the axis contract**

In `shape_property_plan`'s map branch, replace the `Array(of[:values])` handling with a call to the Task 3 builder when the axis holds a bag:

```ruby
            axis = Axn::Internal::ShapeGraph.hash_or_nil(of[:values])
            values = if axis
                       contents_node_schema(axis, for_output:)
                     else
                       klasses = Array(of[:values])
                       klasses.empty? ? {} : contents_schema_for(klasses, for_output:)
                     end
```

`keys:` continues to emit nothing, bag or not.

- [ ] **Step 6: Run the tests, full suite, rubocop, commit**

```bash
bundle exec rspec spec/axn/core/validations/recursive_of_spec.rb
bundle exec rspec && bundle exec rubocop
git add lib/axn spec/axn
git commit -m "PRO-3166: an inner contract on a map's keys: and values: axes"
```

---

### Task 6: `shape:` beside `of:` on a Hash — the exemption

**Files:**
- Modify: `lib/axn/core/contract.rb` (drop `_reject_map_beside_shape!`, derive the exempt set)
- Modify: `lib/axn/core/validation/validators/of_validator.rb`
- Modify: `lib/axn/internal/reflection/schema.rb` (`apply_structured_schema!` combines `map?` and `shape`)
- Test: `spec/axn/core/validations/recursive_of_spec.rb`

**Interfaces:**
- Produces: an `of:` bag under a Hash carries a derived `:shaped_keys` Array of Symbols.

- [ ] **Step 1: Write the failing tests**

```ruby
describe "shape: beside of: on a Hash" do
  subject(:action) do
    build_axn do
      expects :metrics, type: Hash, of: { values: Integer } do
        field :label, type: String
      end
    end
  end

  it "exempts a key the shape names from the map's values axis" do
    expect(action.call(metrics: { label: "q3", visits: 120 })).to be_ok
  end

  it "still holds an unshaped key to the values axis" do
    result = action.call(metrics: { label: "q3", visits: "lots" })
    expect(result).not_to be_ok
    expect(result.exception.message).to include("value at index 1 is not a Integer")
  end

  it "exempts a STRING-keyed occurrence of the same member" do
    expect(action.call(metrics: { "label" => "q3", "visits" => 120 })).to be_ok
  end

  it "still validates the shape member itself" do
    result = action.call(metrics: { label: 5 })
    expect(result).not_to be_ok
    expect(result.exception.message).to include("label is not a String")
  end

  it "counts an exempt key toward the ordinal, so positions name the entry the caller wrote" do
    result = action.call(metrics: { label: "q3", visits: "lots" })
    expect(result.exception.message).to include("index 1")
  end

  it "emits properties and additionalProperties at one node" do
    expect(action.input_schema[:properties][:metrics]).to include(
      type: "object",
      properties: { label: { type: "string", minLength: 1 } },
      required: ["label"],
      additionalProperties: { type: "integer" }
    )
  end

  it "exempts a shaped key from the keys: axis too" do
    keyed = build_axn do
      expects :m, type: Hash, of: { keys: Symbol, values: Integer } do
        field :label, type: String
      end
    end

    expect(keyed.call(m: { "label" => "q3", visits: 1 })).to be_ok
  end
end

it "still refuses a subfield rooted at a map" do
  expect do
    build_axn do
      expects :m, type: Hash, of: { values: Integer }
      expects :sku, on: :m
    end
  end.to raise_error(ArgumentError, /not supported yet/)
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bundle exec rspec spec/axn/core/validations/recursive_of_spec.rb -e "shape: beside of:"`
Expected: FAIL — `of: beside shape: on a Hash is not supported yet`

- [ ] **Step 3: Replace the refusal with the derivation**

Delete `_reject_map_beside_shape!` and its call. In `_canonical_map_of!`, replace the final line:

```ruby
          bag.merge(container: ::Hash, shaped_keys: _shaped_keys!(validations))
```

and add:

```ruby
        # The keys a `shape:` names at this node, which JSON Schema emits as `properties` and which
        # `additionalProperties` therefore does NOT govern. Read from the emitter's own key computation
        # (`Schema.named_members`) rather than re-derived beside it, so the runtime skips exactly the keys the
        # document exempts — the "a guard derives from what its consumer emits" rule, whose failure mode here
        # would be a contract stricter than the schema it publishes.
        def _shaped_keys!(validations)
          shape = Internal::ShapeGraph.hash_or_nil(validations[:shape])
          return Internal::ShapeGraph::NO_SHAPED_KEYS if nil.equal?(shape)

          Axn::Internal::Reflection::Schema.named_members(shape[:members]).map { |_member, name| name.to_sym }.freeze
        end
```

Add `NO_SHAPED_KEYS = [].freeze` to `ShapeGraph`. `Schema.named_members` is already reachable — `Internal::Reflection::Schema` declares `module_function` at line 77 and defines it at line 128 — so this is a call, not a visibility change.

`shaped_keys:` is DERIVED, so it needs the same drop-and-re-derive handling `container:` gets — extend `_drop_derived_of_container!` to drop it, or add a sibling. Without that, the second canonicalization pass over a shape member's bag reports axn's own key as unsupported.

- [ ] **Step 4: Skip exempt keys at runtime**

In `of_validator.rb`'s `validate_entries`:

```ruby
        exempt = options[:shaped_keys] || Axn::Internal::ShapeGraph::NO_SHAPED_KEYS
        index = 0
        Axn::Internal::ShapeGraph.each_entry(value) do |key, entry|
          # A key the shape names is emitted as a `properties` entry, which `additionalProperties` does not
          # govern — so the map contract does not govern it either, on BOTH axes. The ordinal still advances:
          # it names the entry's position in what the caller wrote, not its position among governed entries.
          unless exempt_key?(key, exempt)
            validate_axis(record, attribute, options[:keys], key, "key at index #{index}")
            validate_axis(record, attribute, options[:values], entry, "value at index #{index}")
          end
          index += 1
        end
```

```ruby
      SYMBOL_NAME = ::Symbol.instance_method(:name)
      STRING_EQ = ::String.instance_method(:==)
      private_constant :SYMBOL_NAME, :STRING_EQ

      # A shape member's key is matched in either form, because extraction accepts both
      # (`FieldResolvers.extract_or_nil` reads a Hash by symbol or by string) and JSON input is string-keyed —
      # a Symbol-only comparison would silently stop exempting for the commonest payload shape. Both sides are
      # compared through BOUND base implementations, so a String subclass answering `==` for its own purposes
      # cannot decide whether a key is governed.
      def exempt_key?(key, exempt)
        return false if exempt.empty?

        case key
        when ::Symbol then exempt.include?(key)
        when ::String then exempt.any? { |member| STRING_EQ.bind_call(key, SYMBOL_NAME.bind_call(member)) }
        else false
        end
      end
```

- [ ] **Step 5: Combine the emitter's branches**

In `apply_structured_schema!`, the `plan.map?` branch currently returns after merging `plan.type_schema`. Make it also apply the shape overlay:

```ruby
          if plan.map?
            prop.merge!(plan.type_schema)
            return unless shape && plan.emitted

            member_props, required = member_properties(shape[:members], for_output:)
            prop[:type] = "object"
            prop[:properties] = plan.base_properties.merge(member_props)
            prop[:required] = required unless required.empty?
```

`shape_property_plan`'s map branch currently hardcodes `emitted: false`; it must now compute `emitted` the way the non-array branch does (`!for_output || shape_serializes_to_object?(validations)`), since a shape beside a map does emit properties. Update the comment there that says a map's `of:` is refused beside a shape.

- [ ] **Step 6: Run the tests, full suite, rubocop, commit**

```bash
bundle exec rspec spec/axn/core/validations/recursive_of_spec.rb
bundle exec rspec && bundle exec rubocop
git add lib/axn spec/axn
git commit -m "PRO-3166: shape: beside of: on a Hash, with shaped keys exempt from the map contract"
```

---

### Task 7: Redaction descends the new edge

**Files:**
- Modify: `lib/axn/core/contract/redaction.rb`
- Test: `spec/axn/core/validations/sensitive_shape_members_spec.rb` (the home of the existing sensitive-member behaviour; `spec/axn/core/dynamic_sensitive_spec.rb` covers the Proc/Symbol axis and is not the right home for this)

**Interfaces:**
- Consumes: `ShapeGraph.inner_contracts` (Task 1).

- [ ] **Step 1: Write the failing test**

```ruby
describe "a sensitive member inside a nested of:" do
  let(:shape) do
    { members: [Axn::Core::Contract::ShapeConfig.new(field: :ssn, validations: { type: { klass: String } }, sensitive: true),
                Axn::Core::Contract::ShapeConfig.new(field: :name, validations: { type: { klass: String } })] }
  end

  it "masks the member two containers down and leaves its sibling readable" do
    action = build_axn { expects :m, type: Array, of: { klass: Array, of: { klass: Hash, shape: shape } } }
    result = action.call(m: [[{ ssn: "123-45-6789", name: "Ada" }]])

    expect(result.inspect).not_to include("123-45-6789")
    expect(result.inspect).to include("Ada")
  end

  it "masks a sensitive member inside a map's values" do
    action = build_axn { expects :m, type: Hash, of: { values: { klass: Hash, shape: shape } } }
    result = action.call(m: { "acme" => { ssn: "123-45-6789", name: "Ada" } })

    expect(result.inspect).not_to include("123-45-6789")
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bundle exec rspec spec/axn/core/validations/sensitive_shape_members_spec.rb -e "nested of:"`
Expected: FAIL — the SSN appears in the inspect output.

- [ ] **Step 3: Descend the new edge in the sensitive collectors and the masker**

`_flatten_sensitive_candidates` and `_derive_sensitive_member_names` walk configs and members; both need `ShapeGraph.inner_contracts(validations)` added to what they descend, at the same depth bound they already apply.

`_mask_shape_value` dispatches on `shape[:container]`. Add a sibling that masks a container's CONTENTS from the `of:` bag rather than from a shape:

```ruby
        # A container's contents have no member name, so they are masked positionally: every element of an
        # Array, every value of a map. `_mask_shape_element` is reused rather than mirrored — it already
        # answers "mask this one value against this shape, descending only where a sensitive member lives"
        # and that is the same question one rung down.
        def _mask_contents(value, bag, action_instance, seen = nil)
          shape = Internal::ShapeGraph.hash_or_nil(bag[:shape])
          inner = Internal::ShapeGraph.inner_contracts(bag)

          if value.is_a?(::Array)
            value.map { |element| _mask_one_content(element, shape, inner, action_instance, seen) }
          elsif value.is_a?(::Hash)
            value.each_with_object(value.dup) { |(k, v), out| out[k] = _mask_one_content(v, shape, inner, action_instance, seen) }
          else
            _mask_opaque_or_preserve(value)
          end
        end
```

with `_mask_one_content` applying `_mask_shape_element` when there is a shape and recursing through `_mask_contents` for each inner position. Guard the recursion with `CycleGuard.guard` on the VALUE, exactly as `_mask_shape_element` documents (a cycle cannot close through Arrays alone).

- [ ] **Step 4: Run the tests, full suite, rubocop, commit**

```bash
bundle exec rspec && bundle exec rubocop
git add lib/axn spec/axn
git commit -m "PRO-3166: redact a sensitive member inside a container's contents"
```

---

### Task 8: Ambient context descends the new edge

**Files:**
- Modify: `lib/axn/core/ambient_context.rb:95,120,150`
- Test: `spec/axn/core/ambient_context_spec.rb`

- [ ] **Step 1: Write the failing test**

```ruby
it "reaches a member declared inside a nested of:" do
  shape = { members: [Axn::Core::Contract::ShapeConfig.new(field: :sku, validations: { type: { klass: String } })] }
  action = build_axn { expects :m, type: Array, of: { klass: Hash, shape: shape }, on: :ambient_context }

  expect(action.call).not_to be_nil # replace with the assertion the surrounding examples use
end
```

Match the shape of the existing examples in that file — read three of them first and mirror their assertion style, since the ambient specs assert on resolved values rather than on `call`.

- [ ] **Step 2: Run to verify it fails**

Run: `bundle exec rspec spec/axn/core/ambient_context_spec.rb -e "nested of:"`
Expected: FAIL — the member is not reached.

- [ ] **Step 3: Descend the new edge**

`_each_shape_member` recurses via `Internal::ShapeGraph.nested_shape(member)`. Add the sibling recursion through `Internal::ShapeGraph.inner_contracts(member_validations)`, at the same `depth + 1` and under the same depth bound the method already applies.

- [ ] **Step 4: Run the tests, full suite, rubocop, commit**

```bash
bundle exec rspec && bundle exec rubocop
git add lib/axn spec/axn
git commit -m "PRO-3166: the ambient walk descends a container's contents"
```

---

### Task 9: The flip — canonicalize the flat distributing form forward

The riskiest task, deliberately last and alone. Everything it re-points has already learned the nested form.

**Files:**
- Modify: `lib/axn/core/contract.rb` (`_canonicalize_validator_options!` / the `of:` seam)
- Create: `spec/axn/core/contract/canonical_storage_spec.rb`

**Interfaces:**
- Produces: for a field whose declared `type:` is `Array` and which carries a `shape:`, the shape is stored inside the `of:` bag and `validations[:shape]` is absent.

- [ ] **Step 1: Write the characterisation test for the CURRENT order**

Before changing anything, pin what runs when, so the sequencing move in Step 4 is visible if it breaks something. Create `spec/axn/core/contract/canonical_storage_spec.rb`:

```ruby
# frozen_string_literal: true

RSpec.describe "canonical storage of a container's contents" do
  def validations_for(action) = action.internal_field_configs.first.validations

  let(:member) { Axn::Core::Contract::ShapeConfig.new(field: :sku, validations: { type: { klass: String } }) }

  it "stores an Array's element contract in the of: bag, with no top-level shape:" do
    action = build_axn { expects :rows, type: Array, of: Hash do field :sku, type: String end }
    v = validations_for(action)

    expect(v[:shape]).to be_nil
    expect(v[:of]).to include(klass: Hash, container: Array)
    expect(v.dig(:of, :shape, :container)).to eq(Hash)
    expect(v.dig(:of, :shape, :members).map(&:field)).to eq([:sku])
  end

  it "stores a class-unconstrained element contract when there is no of:" do
    action = build_axn { expects :rows, type: Array do field :sku, type: String end }
    v = validations_for(action)

    expect(v[:shape]).to be_nil
    expect(v.dig(:of, :container)).to eq(Array)
    expect(v.dig(:of, :shape, :container)).to eq(Axn::Internal::ShapeGraph::ANY_CONTAINER)
  end

  it "leaves a Hash's own shape at the field" do
    action = build_axn { expects :h, type: Hash do field :sku, type: String end }
    v = validations_for(action)

    expect(v[:of]).to be_nil
    expect(v.dig(:shape, :container)).to eq(Hash)
  end

  it "leaves a Data field's shape at the field" do
    point = Data.define(:x)
    action = build_axn { expects :p, type: point do field :x, type: Integer end }

    expect(validations_for(action).dig(:shape, :container)).to eq(point)
  end

  it "leaves a map's of: bag alone" do
    action = build_axn { expects :m, type: Hash, of: { values: Integer } }
    v = validations_for(action)

    expect(v[:shape]).to be_nil
    expect(v[:of]).to include(values: Integer, container: Hash)
  end

  it "canonicalizes the flat form at a nested position too" do
    action = build_axn do
      expects :outer, type: Hash do
        field :rows, type: Array, of: Hash, shape: { members: [Axn::Core::Contract::ShapeConfig.new(field: :sku, validations: { type: { klass: String } })] }
      end
    end
    rows = validations_for(action).dig(:shape, :members).first.validations

    expect(rows[:shape]).to be_nil
    expect(rows.dig(:of, :shape, :members).map(&:field)).to eq([:sku])
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bundle exec rspec spec/axn/core/contract/canonical_storage_spec.rb`
Expected: FAIL on rows 1, 2 and 6 — `v[:shape]` is present and `v[:of][:shape]` is nil.

- [ ] **Step 3: Write the message-parity test**

Append to the same file:

```ruby
describe "message parity across the canonicalization" do
  let(:action) { build_axn { expects :rows, type: Array, of: Hash do field :sku, type: String end } }

  it "keeps the element TYPE message unpunctuated" do
    expect(action.call(rows: ["nope"]).exception.message).to include("element at index 0 is not a Hash")
  end

  it "keeps the element MEMBER message colon-prefixed" do
    expect(action.call(rows: [{ sku: 1 }]).exception.message).to include("element at index 0: sku is not a String")
  end

  it "still reports both when an element is the wrong type AND its members cannot be read" do
    message = action.call(rows: ["nope"]).exception.message
    expect(message).to include("element at index 0 is not a Hash")
    expect(message).to include("element at index 0: sku could not be read")
  end
end
```

Run it against the CURRENT tree first (`bundle exec rspec spec/axn/core/contract/canonical_storage_spec.rb -e "message parity"`) — all three must PASS before the flip. If the third does not, correct the expectation to what today actually produces and note the correction; that is the behavior to preserve, not the one assumed here.

- [ ] **Step 4: Implement the flip**

In `_canonicalize_validator_options!`, after the container is derived and before the array/map branch, fold a distributing shape into the bag:

```ruby
          container = _of_container!(validations)
          _fold_distributing_shape!(validations, container)
          _drop_derived_of_container!(validations, container)
          validations[:of] = container.equal?(::Hash) ? _canonical_map_of!(validations, fields) : _canonical_array_of!(validations, fields)
```

```ruby
        # `shape:` under `type: Array` means "each ELEMENT's members" — the one position where it reaches
        # through a value instead of describing it, and the only reason it ever had to was that an Array's
        # contents had no other word. `of:` is that word now, so the declaration is folded into the bag at
        # declaration and the stored graph carries ONE contract shape: a container's contents live in its
        # `of:` bag at every depth, and nothing downstream has two places to look.
        #
        # The SURFACE is unchanged here — both spellings still declare — which is what PRO-3191 removes.
        # `_derive_raw_shape_container!` has already run, so the shape arrives carrying `container: Array`
        # from its old position; the fold rewrites it to the ELEMENT's container, which is what the members
        # are actually read off.
        def _fold_distributing_shape!(validations, container)
          return unless container.equal?(::Array)

          shape = Internal::ShapeGraph.hash_or_nil(validations[:shape])
          return if nil.equal?(shape)

          bag = Internal::ShapeGraph.hash_or_nil(validations[:of])
          bag = bag ? Internal::ShapeGraph.copy_entries(bag) : {}
          detached = Internal::ShapeGraph.detach_node(shape)
          detached[:container] = bag[:klass] ? _shape_compatible_type!({ type: { klass: bag[:klass] } }) : Internal::ShapeGraph::ANY_CONTAINER
          bag[:shape] = detached
          validations[:of] = bag
          validations.delete(:shape)
        end
```

Handle the no-`of:` case: `validations.key?(:of)` is what gates the whole seam today, so a `type: Array` + block with no `of:` never reaches it. Move the `return unless validations.key?(:of)` guard to also admit a field whose declared type is `Array` and which carries a `shape:`.

- [ ] **Step 5: Run the storage tests**

Run: `bundle exec rspec spec/axn/core/contract/canonical_storage_spec.rb`
Expected: PASS

- [ ] **Step 6: Run the full suite and fix the fallout**

Run: `bundle exec rspec`
Expected: some failures in redaction, ambient, reflection and shape specs. Each is a seam still reading `validations[:shape]` for an Array field. Fix by routing that read through `ShapeGraph.inner_contracts`, never by re-adding a top-level `shape:`. If a message changed, the fix is in the implementation — the Step 3 expectations are the contract.

- [ ] **Step 7: A/B the guard specs against the prior commit**

Follow `internal-docs/agent-notes/ab-testing-guards.md`. Create a throwaway worktree at the pre-flip commit (never `git stash`), run the same spec files in both trees, and confirm that only the examples this change actually moved differ. An example failing in BOTH trees is a broken fixture, not a finding.

- [ ] **Step 8: Commit**

```bash
git add lib/axn spec/axn
git commit -m "PRO-3166: canonicalize the distributing shape: into the of: bag"
```

---

### Task 10: Mutation audit of the new bounds

**Files:** none modified permanently — this task ends with `git checkout` of the probes and a commit only if it uncovers a gap.

- [ ] **Step 1: Remove the depth charge for the `of:` edge**

Comment out the `_raise_shape_too_deep!` line inside `_walk_inner_contracts!`.

- [ ] **Step 2: Run the suite**

Run: `bundle exec rspec spec/axn/core/validations/recursive_of_spec.rb`
Expected: the "refuses a graph one level deeper" example FAILS. If it passes, the guard is unguarded — add the missing example before restoring.

- [ ] **Step 3: Restore, then remove the path charge**

Restore the line. Comment out `_spend_paths!(allowance, 1)` in `_walk_inner_contracts!`, and add a test that a bag shared between siblings at 20 levels is refused (2^20 paths). Confirm it fails without the charge and passes with it.

- [ ] **Step 4: Inverse-mutate the controls**

Restore everything, then make the depth guard one level stricter (`>=` instead of `>`). Confirm the "accepts a graph exactly at MAX_NESTING" example FAILS. Over-rejection is the recurring failure mode when a guard is tightened, and mutation alone cannot find it — only the inverse can.

- [ ] **Step 5: Restore and verify clean**

Run: `git diff --stat` (expect empty) then `bundle exec rspec`
Expected: PASS

- [ ] **Step 6: Commit any tests the audit added**

```bash
git add spec/axn
git commit -m "PRO-3166: pin the bounds the mutation audit found unguarded"
```

---

### Task 11: Docs, CHANGELOG, and the downstream sweep

**Files:**
- Modify: `docs/reference/class.md`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Document the grammar**

In `docs/reference/class.md`, beside the existing `of:` bullet (line ~90) and the map section PRO-3165 added, document: the inner-contract bag and its three positions; that a bag must constrain something; the Hash exemption with the worked example from the spec; and the two residues (shared options inert inside a bag; a `keys:` bag validates but emits nothing). One line per paragraph — no manual line breaks.

- [ ] **Step 2: Write the CHANGELOG entry**

Under the existing `## Unreleased` → `### Added`, matching the density of the PRO-3165 entry immediately above it. Cover: `of:` takes `klass:`/`of:`/`shape:`/`message:` recursively; the three positions; a bag may omit `klass:` when it constrains by `of:`/`shape:`; per-axis `message:`; `shape:` beside `of:` on a Hash with shaped keys exempt from BOTH axes (and why — `additionalProperties` does not govern `properties`); the nested error-message shapes; the emitted `items.items` / `additionalProperties` nesting; and that `keys:` still emits nothing. Tag `[FEAT]`.

Add an `[INTERNAL]` entry for the storage change: a container's contents now live in its `of:` bag at every depth, so a gem reading `config.validations[:shape]` for an `Array`-typed field must read through `ShapeGraph.inner_contracts`. Public reflection (`input_schema`/`output_schema`, `Extensions::Serialization.render`) is unchanged.

Also amend PRO-3165's existing `[BREAKING]` of:-whitelist entry, which currently lists a nested `of:` and a nested `shape:` as refused keys — they are supported now, and that entry is in the same unreleased section, so it must not ship contradicting this one.

- [ ] **Step 3: Sweep the downstream consumers**

Run: `rake downstream:check`
Then grep the siblings for direct reads of the internal shape: `grep -rn "validations\[:shape\]\|validations\[:of\]" ../axn-* ../data_shifter ../slack_sender 2>/dev/null`
Expected: no hits, or a listed follow-up for each hit.

- [ ] **Step 4: Full verification**

Run: `bundle exec rspec && bundle exec rubocop && bundle exec rspec spec_rubocop`
Then from `spec_rails/dummy_app`: `BUNDLE_GEMFILE=Gemfile bundle exec rspec` (nothing here is Rails-specific, but the suite must stay green).

- [ ] **Step 5: Commit**

```bash
git add docs CHANGELOG.md
git commit -m "PRO-3166: document recursive of: and the Hash exemption"
```

---

## Self-Review

**Spec coverage.** Grammar → Tasks 2, 4, 5. Canonical storage → Task 9 (with Task 1's sentinel). The two relaxations → Tasks 2 (constrains-something) and 4 (`ANY_CONTAINER`, `check_validity!`). Declaration grid → Tasks 2, 4, 5, 6. Hash exemption → Task 6, including the string-key edge and the ordinal rule. Runtime → Tasks 2, 4, 5; message parity → Task 9 Step 3. Schema → Tasks 3, 5, 6. Declaration walk and bounds → Task 2 Step 4, audited in Task 10. Four seams → declaration (2), redaction (7), ambient (8), reflection (3, 5, 6). Scope refusals kept → Task 6's last example (subfield under a map). Testing section → Tasks 9, 10, 11.

**Known gap carried deliberately.** Task 2 Step 3 passes a BAG into `_of_container!` and `_canonical_map_of!` in the `validations` slot, and Task 5 changes `_canonical_map_of!`'s arity. Both are flagged inline with instructions to verify and adjust rather than assume; the exact signature depends on what those methods read, which the implementer will have in front of them.

**Placeholder scan.** No "TBD"/"add error handling"/"similar to Task N". Two steps deliberately instruct the implementer to *read first and mirror* rather than supplying code: Task 8 Step 1 (the ambient specs assert on resolved values in a style that must be matched, not guessed) and Task 9 Step 3's third example (which must be run against the current tree and corrected to observed behavior before the flip). Both are verification instructions with a stated expected outcome, not deferred design.

**Type consistency.** `ShapeGraph.inner_contracts` returns `[[position, bag], …]` and is consumed with that arity in Tasks 3, 7 and 8. `ANY_CONTAINER` is produced in Task 1, written in Tasks 4 and 9, read in Task 4's `ShapeValidator`. `contents_node_schema(bag, for_output:)` is produced in Task 3 and consumed in Task 5. `shaped_keys:` is produced in Task 6 Step 3 and read in Step 4. `NO_SHAPED_KEYS` is defined in Task 6 Step 3 and used in Step 4.
