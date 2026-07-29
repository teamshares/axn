# Declaration-Time Property-Name Collisions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reject at class definition any declared field, subfield, or shape member name that has no UTF-8 rendering, or that collapses onto the same JSON property as another declared name — defects that today surface mid-call, during serialization, or (for inbound names) never.

**Architecture:** Field identity inside `Axn::Core::Contract` changes from the raw Symbol to the JSON property the name renders as, computed by `Axn::Reflection::Values.canonical_wire_key` so the declaration check and the rendering it predicts share one definition. Three helpers are added to the contract's private section — an unrenderable-name rejection, a duplicate/collision reporter that absorbs three existing detect-then-raise pairs, and a recursive shape-member walker — and `_duplicate_fields` is re-keyed.

**Tech Stack:** Ruby, RSpec, RuboCop. No new dependencies, no new files in `lib/`.

**Ticket:** [PRO-2995](https://linear.app/teamshares/issue/PRO-2995/axn-reject-exposure-names-that-canonicalize-to-one-json-property-at)
**Spec:** `internal-docs/specs/2026-07-29-declaration-time-property-name-collisions-design.md`

## Global Constraints

- **`Axn::Reflection::Values.canonical_wire_key` is the only canonicalization.** Never re-derive UTF-8 transcoding inside `Core::Contract`; never copy its body. A declaration check that disagrees with the renderer is worse than no check.
- **The existing duplicate message is preserved byte for byte.** `"Duplicate field(s) declared: foo"` is asserted at `spec/axn/core/validations/inbound_validation_spec.rb:361` and `spec/axn/core/validations/outbound_validation_spec.rb:144`. Those specs must pass untouched.
- **Unrenderable names are rejected before any collision comparison.** Two such names both canonicalize to `nil`; a collision check reached first would compare `nil` to `nil` and report a shared property for two names that share none.
- **Every raise happens before the class is mutated,** matching the validate-before-commit ordering documented at `lib/axn/core/contract.rb:197-201`.
- **Never interpolate a declared name raw into a message.** A non-UTF-8 name interpolated into a UTF-8 String raises `Encoding::CompatibilityError` from the reporting itself. Use the `_inspect_field_name` helper from Task 1 everywhere.
- Every message states the problem **and** the fix (`AGENTS.md` "Errors").
- Comments describe current behavior and intrinsic why. No "used to X / now Y", no ticket numbers, no review references.
- No manual line breaks in Markdown prose — one line per paragraph.
- Never assert `Hash#inspect` text in a spec: Ruby 3.4 changed its spacing and CI runs 3.2/3.3/3.4.
- Run `bundle exec rubocop` before each commit. Relevant maxima: `Layout/LineLength` 160, `Metrics/MethodLength` 70, `Metrics/AbcSize` 60. Multiline argument lists require a trailing comma; `Style/HashSyntax` requires shorthand for symbol keys.
- Full suite: `bundle exec rspec`. The Rails dummy app is a separate bundle: `BUNDLE_GEMFILE=spec_rails/dummy_app/Gemfile bundle exec rspec spec_rails`. Run both in Task 3.
- **Encoding fixtures:** a non-UTF-8 symbol fixture must be `ASCII-8BIT`. Ruby refuses `to_sym` on bytes invalid *in UTF-8*, raising `EncodingError` before a declaration is reached, so a `force_encoding("UTF-8")` fixture tests nothing. Files are `# frozen_string_literal: true`, so `.dup` before `force_encoding`.
- **`build_axn` runs its block through `class_eval`,** so `let`-defined values are NOT visible inside it (`self` is the new class). Capture fixtures into local variables in the example body first; blocks close over locals lexically.

## File Structure

| File | Responsibility | Change |
| --- | --- | --- |
| `lib/axn/core/contract.rb` | Declaration-time contract validation. Gains `_inspect_field_name`, `_reject_unrenderable_field_names!`, `_reject_duplicate_fields!`, `_reject_colliding_shape_member_names!`; `_duplicate_fields` re-keyed; two guard call sites in `expects`, two in `exposes` | Modify |
| `lib/axn/core/contract_for_subfields.rb` | Subfield declaration | Modify: one detect-then-raise pair becomes one call (L502-503) |
| `spec/axn/core/validations/property_name_collision_spec.rb` | All coverage for both defects across every declaration surface | **Create** |
| `CHANGELOG.md` | Two `[BREAKING]` bullets | Modify |
| `docs/reference/class.md` | User-facing declaration rules | Modify: field-name rule near L383, shape-member rule near L155 |

---

### Task 1: Canonical field identity for `expects`, `exposes`, and subfields

**Files:**
- Modify: `lib/axn/core/contract.rb` (add four private helpers after `_duplicate_fields`; re-key `_duplicate_fields` at L562-575; add a guard call in `expects` after L157 and in `exposes` after L218; replace the detect-then-raise pairs at L194-195 and L241-242)
- Modify: `lib/axn/core/contract_for_subfields.rb:502-503`
- Test: `spec/axn/core/validations/property_name_collision_spec.rb` (create)

**Line numbers refer to the files as they stand before you edit them.** Later edits in this task shift them, so locate every edit by the anchor text quoted here rather than by line number.

**Interfaces:**
- Consumes: `Axn::Reflection::Values.canonical_wire_key(key)` → a frozen UTF-8 `String`, or `nil` when the key's bytes have no UTF-8 rendering. Public `module_function` on `main`; PRO-2992's plan has been amended to keep it public for this caller.
- Produces, all `private` class methods on `Axn::Core::Contract::ClassMethods`:
  - `_inspect_field_name(name)` → `String`, the name escaped to ASCII, safe to interpolate.
  - `_reject_unrenderable_field_names!(names, kind: "a field name")` → `nil`, or raises `ArgumentError`.
  - `_duplicate_fields(existing, new_configs)` → `Array` of `[claimed_field, offending_field]` pairs (was: `Array` of field names).
  - `_reject_duplicate_fields!(existing, new_configs)` → `nil`, or raises `Axn::DuplicateFieldError`.

- [ ] **Step 1: Write the failing test**

Create `spec/axn/core/validations/property_name_collision_spec.rb`:

```ruby
# frozen_string_literal: true

# A declared name becomes a JSON property name — in the reflected schema for an inbound field, in
# serialized output for an outbound one — so it carries the same UTF-8 promise the serializer enforces on a
# Hash key. Two names that collapse onto one property, and a name with no UTF-8 rendering at all, are
# rejected when the class is defined: both are knowable from the declarations alone, and by the time a call
# or a serializing adapter would notice, the business logic and its side effects have already run.
RSpec.describe "declaration-time property name collisions" do
  # Two distinct Symbols, one JSON property: the same text in two encodings. Symbols carry bytes plus an
  # encoding, while a property name is text, so these are separate Hash keys and one property.
  def utf8_name = :café
  def latin1_name = "caf\xE9".dup.force_encoding("ISO-8859-1").to_sym

  # Bytes with no UTF-8 rendering at all. ASCII-8BIT is mandatory here (see the plan's fixture note).
  def unrenderable_name = "bad\xFF".dup.force_encoding("ASCII-8BIT").to_sym

  describe "the canonicalization this check shares with the renderer" do
    # The declaration check and the rendering it predicts must agree, so the contract layer calls the
    # renderer's canonicalization rather than re-deriving it. Asserted here so narrowing the renderer's
    # public surface fails loudly rather than silently disarming the guard.
    it "is publicly callable and collapses two encodings of one property" do
      expect(Axn::Reflection::Values).to respond_to(:canonical_wire_key)
      expect(Axn::Reflection::Values.canonical_wire_key(latin1_name)).to eq("café")
      expect(Axn::Reflection::Values.canonical_wire_key(utf8_name)).to eq("café")
    end
  end

  describe "two names that collapse onto one property" do
    it "rejects them on exposes" do
      names = [utf8_name, latin1_name]

      expect { build_axn { exposes(*names) } }
        .to raise_error(Axn::DuplicateFieldError, /both render as the JSON property "café"/)
    end

    it "rejects them on expects" do
      names = [utf8_name, latin1_name]

      expect { build_axn { expects(*names) } }
        .to raise_error(Axn::DuplicateFieldError, /both render as the JSON property "café"/)
    end

    it "rejects them across separate declarations, not just within one batch" do
      first, second = [utf8_name, latin1_name]

      expect do
        build_axn do
          expects first
          expects second
        end
      end.to raise_error(Axn::DuplicateFieldError, /both render as the JSON property "café"/)
    end

    it "names both spellings and the fix" do
      names = [utf8_name, latin1_name]

      expect { build_axn { exposes(*names) } }.to raise_error(Axn::DuplicateFieldError) { |error|
        expect(error.message).to include(":café", 'caf\xE9', "stay distinct once converted to UTF-8")
      }
    end

    it "rejects two subfield leaf names under one route" do
      leaves = [utf8_name, latin1_name]

      expect do
        build_axn do
          expects :payload, type: Hash
          expects(*leaves, on: :payload)
        end
      end.to raise_error(Axn::DuplicateFieldError, /both render as the JSON property "café"/)
    end

    it "still allows one leaf spelling under two different routes" do
      leaf = utf8_name

      klass = build_axn do
        expects :billing, type: Hash
        expects :shipping, type: Hash
        expects leaf, on: :billing, as: :billing_city, optional: true
        expects leaf, on: :shipping, as: :shipping_city, optional: true
      end

      expect(klass.subfield_configs.size).to eq(2)
    end
  end

  describe "a name with no UTF-8 rendering" do
    it "is rejected on expects" do
      name = unrenderable_name

      expect { build_axn { expects name } }
        .to raise_error(ArgumentError, /bytes that have no UTF-8 rendering/)
    end

    it "is rejected on exposes" do
      name = unrenderable_name

      expect { build_axn { exposes name } }
        .to raise_error(ArgumentError, /bytes that have no UTF-8 rendering/)
    end

    it "is rejected before the collision check, so two of them do not report a shared property" do
      names = [unrenderable_name, "worse\xFE".dup.force_encoding("ASCII-8BIT").to_sym]

      expect { build_axn { expects(*names) } }
        .to raise_error(ArgumentError, /bytes that have no UTF-8 rendering/)
    end

    it "names the offending bytes escaped to ASCII and the fix" do
      name = unrenderable_name

      expect { build_axn { expects name } }.to raise_error(ArgumentError) { |error|
        expect(error.message).to include('bad\xFF', "Declare it under a UTF-8 name")
      }
    end
  end

  describe "the identical-name duplicate this generalizes" do
    it "keeps its existing message" do
      expect do
        build_axn do
          expects :foo, type: String
          expects :foo, numericality: { greater_than: 10 }
        end
      end.to raise_error(Axn::DuplicateFieldError, "Duplicate field(s) declared: foo")
    end
  end

  # The runtime defense this does NOT replace has its own coverage: a declaration check cannot see the keys
  # of a Hash the action builds during a call, so the serializer stays the last line for that case. See
  # `spec/axn/reflection/values_spec.rb` "colliding Hash keys" — do not duplicate it here. That coverage
  # reaches the renderer directly, and PRO-2992 is in flight to make it reachable only through
  # `Axn::Extensions::Serialization`; a second copy of the same assertion in this file would become a second
  # thing to migrate for no added protection.
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bundle exec rspec spec/axn/core/validations/property_name_collision_spec.rb`
Expected: the `canonical_wire_key` example, the "identical-name duplicate" example, and "still allows one leaf spelling under two different routes" PASS (they describe behavior that exists today); every collision and unrenderable example FAILS with "expected Axn::DuplicateFieldError / ArgumentError but nothing was raised".

- [ ] **Step 3: Add the four helpers**

In `lib/axn/core/contract.rb`, immediately **after** the `_duplicate_fields` method (which ends with `end.map(&:field)` today — you will rewrite it in Step 4) and before the `_resolve_reader_names` comment block, insert:

```ruby
        # A declared name is interpolated into a message only through this: a name whose bytes have no UTF-8
        # rendering is exactly what these errors report, and interpolating those bytes into a UTF-8 message
        # would raise Encoding::CompatibilityError from the reporting itself. `inspect` escapes them to
        # ASCII, bound rather than dispatched for the same reason the renderer binds `to_s`: a Symbol's
        # cannot be overridden, but a shape member's name may be a caller-supplied String whose could be.
        # The `case`/`when` type test consults the real class, which a singleton `is_a?` cannot lie about.
        # An exotic name (neither String nor Symbol) has no bytes to mangle, so plain dispatch is safe.
        SYMBOL_NAME_INSPECT = ::Symbol.instance_method(:inspect)
        STRING_NAME_INSPECT = ::String.instance_method(:inspect)
        private_constant :SYMBOL_NAME_INSPECT, :STRING_NAME_INSPECT

        def _inspect_field_name(name)
          case name
          when ::Symbol then SYMBOL_NAME_INSPECT.bind_call(name)
          when ::String then STRING_NAME_INSPECT.bind_call(name)
          else name.inspect
          end
        end

        # A declared name becomes a JSON property name — in the reflected schema for an inbound field, in
        # serialized output for an outbound one — so it carries the same UTF-8 promise the serializer
        # enforces on a Hash key. Canonicalization belongs to the layer that renders the property, so the
        # check and the rendering it predicts cannot disagree.
        #
        # Runs before any collision comparison: two unrenderable names both canonicalize to nil, so a
        # collision check reached first would compare nil to nil and report a shared property for two names
        # that share none.
        def _reject_unrenderable_field_names!(names, kind: "a field name")
          names.each do |name|
            next if Axn::Reflection::Values.canonical_wire_key(name)

            raise ArgumentError,
                  "#{kind} becomes a JSON property name, and #{_inspect_field_name(name)} holds bytes that have no " \
                  "UTF-8 rendering — JSON is a UTF-8 format, so `JSON.generate` refuses such a property name outright. " \
                  "Declare it under a UTF-8 name."
          end
        end

        # The three declaration paths (top-level expects, exposes, subfields) report through here rather
        # than each partitioning the result of `_duplicate_fields` themselves. An identical-name duplicate
        # and two names collapsing onto one property are the same defect under one identity rule, but they
        # need different messages, and the identical case keeps the wording it has always had.
        #
        # An identical duplicate is reported first when a batch contains both, so the error is deterministic
        # and names the simpler defect — the one whose fix is unambiguous.
        def _reject_duplicate_fields!(existing, new_configs)
          collisions = _duplicate_fields(existing, new_configs)
          return if collisions.empty?

          identical, collapsed = collisions.partition { |claimed, offending| claimed == offending }
          raise Axn::DuplicateFieldError, "Duplicate field(s) declared: #{identical.map(&:last).join(', ')}" if identical.any?

          claimed, offending = collapsed.first
          raise Axn::DuplicateFieldError,
                "Duplicate field(s) declared: #{_inspect_field_name(claimed)} and #{_inspect_field_name(offending)} " \
                "both render as the JSON property #{Axn::Reflection::Values.canonical_wire_key(offending).inspect} — a " \
                "field name becomes a property name in the reflected schema and in serialized output, so the two would " \
                "collapse onto one. Declare them under names that stay distinct once converted to UTF-8."
        end
```

- [ ] **Step 4: Re-key `_duplicate_fields`**

Replace the body of `_duplicate_fields` (the `key_for` lambda through `end.map(&:field)`) with:

```ruby
        def _duplicate_fields(existing, new_configs)
          # `on:` is normalized with `to_s` so `:payload` and `"payload"` (and any symbol/string spelling
          # of the same dotted path) name the same route — matching how the SubfieldTree splits `on:` —
          # rather than slipping two configs onto one wire slot on a spelling difference. It is not
          # canonicalized further: a route must name an already-declared reader, so two spellings of one
          # route cannot both be declared to begin with.
          #
          # Every name reaching here is renderable — `_reject_unrenderable_field_names!` runs first in both
          # `expects` and `exposes` — so a nil property never enters the comparison.
          key_for = ->(c) { [c.on.to_s, Axn::Reflection::Values.canonical_wire_key(c.field)] }

          claimed = existing.to_h { |c| [key_for.call(c), c.field] }
          new_configs.each_with_object([]) do |config, collisions|
            key = key_for.call(config)
            next collisions << [claimed[key], config.field] if claimed.key?(key)

            claimed[key] = config.field
          end
        end
```

Update the doc comment above it: replace the sentence "Keys are symbol-canonical at declaration (PRO-2790), so `:note` and `"note"` are already the same field." with:

```ruby
        # Identity is the JSON PROPERTY a name renders as, not the Symbol itself: keys are symbol-canonical
        # at declaration, so `:note` and `"note"` are already one field, and canonicalizing to UTF-8 closes
        # the remaining gap — two Symbols whose bytes differ but whose property does not.
```

Also replace the final sentence "Returns the offending wire-key names." with:

```ruby
        # Returns `[claimed_field, offending_field]` pairs; equal entries are an identical-name duplicate.
```

- [ ] **Step 5: Wire the guards into `expects`**

In `expects`, immediately after `fields = fields.map(&:to_sym)` and its comment block (before the `RESERVED_FIELD_NAMES_FOR_EXPECTATIONS` loop), insert:

```ruby
          _reject_unrenderable_field_names!(fields)
```

Then replace the two-line detect-then-raise pair:

```ruby
            duplicated = _duplicate_fields(internal_field_configs, configs)
            raise Axn::DuplicateFieldError, "Duplicate field(s) declared: #{duplicated.join(', ')}" if duplicated.any?
```

with:

```ruby
            _reject_duplicate_fields!(internal_field_configs, configs)
```

- [ ] **Step 6: Wire the guards into `exposes`**

In `exposes`, immediately after `fields = fields.map(&:to_sym)` and its comment (before the `RESERVED_FIELD_NAMES_FOR_EXPOSURES` loop), insert:

```ruby
          _reject_unrenderable_field_names!(fields)
```

Then replace:

```ruby
            duplicated = _duplicate_fields(external_field_configs, configs)
            raise Axn::DuplicateFieldError, "Duplicate field(s) declared: #{duplicated.join(', ')}" if duplicated.any?
```

with:

```ruby
            _reject_duplicate_fields!(external_field_configs, configs)
```

- [ ] **Step 7: Wire the subfield path**

In `lib/axn/core/contract_for_subfields.rb`, replace:

```ruby
            duplicated = _duplicate_fields(subfield_configs, configs)
            raise Axn::DuplicateFieldError, "Duplicate field(s) declared: #{duplicated.join(', ')}" if duplicated.any?
```

with:

```ruby
            _reject_duplicate_fields!(subfield_configs, configs)
```

Subfield leaf names need no separate unrenderable guard: `_expects_subfields` is only reached from `expects`, which has already rejected them.

- [ ] **Step 8: Run the new spec to verify it passes**

Run: `bundle exec rspec spec/axn/core/validations/property_name_collision_spec.rb`
Expected: all examples PASS.

- [ ] **Step 9: Run the existing duplicate-field specs**

Run: `bundle exec rspec spec/axn/core/validations/inbound_validation_spec.rb spec/axn/core/validations/outbound_validation_spec.rb spec/axn/core/validations/on_subfields_spec.rb spec/axn/core/symbol_key_normalization_spec.rb`
Expected: all PASS with no edits. These assert the identical-name message and the symbol/string normalization behavior; a failure here means the message or the identity rule regressed, not that the specs need updating.

- [ ] **Step 10: Run the full suite and RuboCop**

Run: `bundle exec rspec && bundle exec rubocop`
Expected: no failures, no offenses. If `Metrics/AbcSize` fires on `_reject_duplicate_fields!`, extract the collapsed-message branch into a `_raise_collapsed_fields!(claimed, offending)` private method rather than shortening the message.

- [ ] **Step 11: Commit**

```bash
git add lib/axn/core/contract.rb lib/axn/core/contract_for_subfields.rb spec/axn/core/validations/property_name_collision_spec.rb
git commit -m "PRO-2995: field identity is the JSON property a declared name renders as"
```

---

### Task 2: Shape member names

**Files:**
- Modify: `lib/axn/core/contract.rb` (add `_reject_colliding_shape_member_names!` next to `_reject_outbound_shape_user_facing!`; one call site in `expects`, one in `exposes`)
- Test: `spec/axn/core/validations/property_name_collision_spec.rb` (append a `describe`)

**Interfaces:**
- Consumes: `_inspect_field_name`, `_reject_unrenderable_field_names!` from Task 1; `_member_shape(member)` → the member's nested shape `Hash` or `nil` (existing, `lib/axn/core/contract.rb:484`).
- Produces: `_reject_colliding_shape_member_names!(shape)` → `nil`, or raises `Axn::DuplicateFieldError`. Private class method.

- [ ] **Step 1: Write the failing test**

Append to `spec/axn/core/validations/property_name_collision_spec.rb`, inside the outer `describe`:

```ruby
  describe "shape member names" do
    it "rejects two members that collapse onto one property" do
      first, second = [utf8_name, latin1_name]

      expect do
        build_axn do
          expects :payload, type: Hash do
            field first, type: String
            field second, type: Integer
          end
        end
      end.to raise_error(Axn::DuplicateFieldError, /both render as the JSON property "café"/)
    end

    it "rejects a duplicate member name, which today keeps only the last in the schema" do
      expect do
        build_axn do
          expects :payload, type: Hash do
            field :a, type: String
            field :a, type: Integer
          end
        end
      end.to raise_error(Axn::DuplicateFieldError, /Duplicate shape member declared: :a\b/)
    end

    it "treats a symbol and a string spelling of one member name as one property" do
      expect do
        build_axn do
          expects :payload, type: Hash do
            field :a, type: String
            field "a", type: Integer
          end
        end
      end.to raise_error(Axn::DuplicateFieldError, /both render as the JSON property "a"/)
    end

    it "rejects a member name with no UTF-8 rendering" do
      name = unrenderable_name

      expect do
        build_axn do
          expects :payload, type: Hash do
            field name, type: String
          end
        end
      end.to raise_error(ArgumentError, /a shape member name becomes a JSON property name/)
    end

    it "reaches members nested inside a member's own block" do
      first, second = [utf8_name, latin1_name]

      expect do
        build_axn do
          expects :payload, type: Hash do
            field :inner, type: Hash do
              field first, type: String
              field second, type: Integer
            end
          end
        end
      end.to raise_error(Axn::DuplicateFieldError, /both render as the JSON property "café"/)
    end

    it "reaches members supplied as a raw shape: kwarg, which never route through the builder" do
      members = [
        Axn::Core::Contract::ShapeConfig.new(field: utf8_name, validations: {}),
        Axn::Core::Contract::ShapeConfig.new(field: latin1_name, validations: {}),
      ]

      expect { build_axn { expects :payload, type: Hash, shape: { members: } } }
        .to raise_error(Axn::DuplicateFieldError, /both render as the JSON property "café"/)
    end

    it "rejects them on an exposes shape too" do
      first, second = [utf8_name, latin1_name]

      expect do
        build_axn do
          exposes :payload, type: Hash do
            field first, type: String
            field second, type: Integer
          end
        end
      end.to raise_error(Axn::DuplicateFieldError, /both render as the JSON property "café"/)
    end

    it "leaves distinct member names alone" do
      klass = build_axn do
        expects :payload, type: Hash do
          field :a, type: String
          field :b, type: Integer
        end
      end

      expect(klass.input_schema.dig(:properties, :payload, :properties).keys).to eq(%i[a b])
    end
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bundle exec rspec spec/axn/core/validations/property_name_collision_spec.rb -e "shape member names"`
Expected: the last example ("leaves distinct member names alone") PASSES; the other seven FAIL with nothing raised. `ShapeConfig` is `Data.define(:field, :validations, :metadata, :method_call, :sensitive, :user_facing)` at `lib/axn/core/contract.rb:106`, whose `initialize` requires only `field:` and `validations:` — the two-kwarg call in the example is complete.

- [ ] **Step 3: Add the walker**

In `lib/axn/core/contract.rb`, immediately after `_reject_outbound_shape_user_facing!` (it ends with the `_reject_outbound_shape_user_facing!(_member_shape(member))` recursion), insert:

```ruby
        # A shape member's name is an object property in the reflected schema on exactly the same terms as a
        # field's, so it carries the same promise. Walks RESOLVED members rather than checking inside
        # ShapeBuilder because the `do…end` form routes through `_build_shape_member` but a raw `shape:`
        # kwarg supplies pre-built members that never do — the same reason
        # `_reject_outbound_shape_user_facing!` walks. Recursion covers a member's own nested block.
        #
        # A member not implementing `#field` is a minimal duck-typed object with no name to collide; skip it
        # rather than dispatching something it may not define.
        def _reject_colliding_shape_member_names!(shape)
          return unless shape.is_a?(Hash)

          members = (shape[:members] || []).select { |member| member.respond_to?(:field) }
          names = members.map(&:field)
          _reject_unrenderable_field_names!(names, kind: "a shape member name")

          claimed = {}
          names.each do |name|
            property = Axn::Reflection::Values.canonical_wire_key(name)
            _raise_colliding_members!(claimed[property], name, property) if claimed.key?(property)

            claimed[property] = name
          end

          members.each { |member| _reject_colliding_shape_member_names!(_member_shape(member)) }
        end

        # Two spellings of one member name are reported as a plain duplicate; two different names that
        # collapse are reported as the collision they are. A Symbol and a String spelling of one name are
        # not `==`, so they take the collapsed branch and the message names the shared property — which is
        # the useful thing to say about them.
        def _raise_colliding_members!(claimed, offending, property)
          if claimed == offending
            raise Axn::DuplicateFieldError,
                  "Duplicate shape member declared: #{_inspect_field_name(offending)} — two members of one shape would " \
                  "validate the same key, and the reflected schema keeps only the last. Declare each member once."
          end

          raise Axn::DuplicateFieldError,
                "Duplicate shape member declared: #{_inspect_field_name(claimed)} and #{_inspect_field_name(offending)} " \
                "both render as the JSON property #{property.inspect}, so the reflected schema would emit it twice. " \
                "Declare them under names that stay distinct once converted to UTF-8."
        end
```

- [ ] **Step 4: Wire the call sites**

In `expects`, immediately after the line building the shape:

```ruby
          validations[:shape] = _build_shape(fields, validations:, &block) if block
```

insert:

```ruby
          _reject_colliding_shape_member_names!(validations[:shape])
```

Placing it here — after the shape is resolved and before the `on:` early return to `_expects_subfields` — covers the block form, the raw `shape:` kwarg, and subfield shapes with one call.

In `exposes`, immediately after the existing `_reject_outbound_shape_user_facing!(validations[:shape])`, insert:

```ruby
          _reject_colliding_shape_member_names!(validations[:shape])
```

- [ ] **Step 5: Run the new examples to verify they pass**

Run: `bundle exec rspec spec/axn/core/validations/property_name_collision_spec.rb`
Expected: all examples PASS.

- [ ] **Step 6: Run the shape specs and the full suite**

Run: `bundle exec rspec spec/axn/core/validations && bundle exec rspec && bundle exec rubocop`
Expected: no failures, no offenses.

**If a pre-existing spec fails because it declares a duplicate member name, that is a finding, not a chore.** Report it — which spec, which declaration, whether it was relying on last-wins deliberately — before changing anything. The plan's premise is that nothing leans on that behavior; a hit falsifies the premise.

- [ ] **Step 7: Commit**

```bash
git add lib/axn/core/contract.rb spec/axn/core/validations/property_name_collision_spec.rb
git commit -m "PRO-2995: shape member names carry the same property promise as fields"
```

---

### Task 3: Documentation and changelog

**Files:**
- Modify: `CHANGELOG.md` (a bullet in `### Field contract & subfields`, a bullet in `### Shape blocks`, both under the top `## 0.1.0-alpha.5`)
- Modify: `docs/reference/class.md` (field-name rule near L383, shape-member rule near L155)

**Interfaces:** none — documentation only.

- [ ] **Step 1: Add the field-contract changelog bullet**

In `CHANGELOG.md`, under `### Field contract & subfields`, immediately after the existing bullet beginning "[BREAKING] Several unsatisfiable contracts now raise at class definition", add:

```markdown
* [BREAKING] A declared name that has no UTF-8 rendering, or that collapses onto the same JSON property as another declared name, now raises at class definition. A field name becomes a property name in the reflected schema and in serialized output, so two names whose bytes differ but whose property does not (`:café` in UTF-8 and in ISO-8859-1) would collapse onto one — silently emitting a duplicate property in `input_schema`, or dropping an exposure on the way out. The error names both spellings and the property they collapse to.
```

- [ ] **Step 2: Add the shape-blocks changelog bullet**

Under `### Shape blocks`, after the existing `model:` bullet, add:

```markdown
* [BREAKING] Two members of one shape may no longer share a name, or two names that render as the same JSON property. Declaring the same member twice previously built both members and kept only the last in the reflected schema, discarding the first with no signal.
```

- [ ] **Step 3: Document the field-name rule**

In `docs/reference/class.md`, in the paragraph beginning "`as:` and `prefix:` cannot be combined (raises at declaration)." — after its final sentence "The `as:` value itself may not be dotted (a reader name must name a method)." — append:

```markdown
Two fields may not share a wire key, and may not carry names that render as the same JSON property: a field name becomes a property name in the reflected schema and in serialized output, so `:café` spelled in UTF-8 and in ISO-8859-1 are one property and raise at declaration naming both spellings. A name whose bytes have no UTF-8 rendering at all is rejected the same way — JSON is a UTF-8 format, so no encoder would accept it as a property name.
```

- [ ] **Step 4: Document the shape-member rule**

In `docs/reference/class.md`, at the end of the bullet beginning "* Members accept validations (`type`, `inclusion`, …)", append:

```markdown
Each member of a shape must have a distinct name, and two members may not carry names that render as the same JSON property (member names are object properties in the schema, so the rule matches a field's) — both raise at declaration.
```

- [ ] **Step 5: Verify the docs build and the suites pass**

Run: `bundle exec rspec && BUNDLE_GEMFILE=spec_rails/dummy_app/Gemfile bundle exec rspec spec_rails && bundle exec rubocop`
Expected: no failures, no offenses. The Rails dummy app is a separate bundle and exercises the same declaration paths through a real Rails boot, so a failure there that the root suite missed is a real difference, not flake.

- [ ] **Step 6: Commit**

```bash
git add CHANGELOG.md docs/reference/class.md
git commit -m "PRO-2995: document declaration-time property-name rules"
```
