# Inbound wire coercion for Ruby-object input types — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a declared-inbound field opt into `coerce:` so a JSON/Rails-form string is parsed into its declared Ruby type (`Date`/`DateTime`/`Time`/`Symbol`/`Integer`/`Float`) before validation — the inbound inverse of `Axn::Reflection::Values.serialize_value`.

**Architecture:** A new read-only `Axn::Reflection::Coercion` module owns the wire→Ruby mapping (single source of truth, keyed off the same class set as the encoder). The `coerce:` DSL expands to a `coerce: true` flag inside the existing `type:` option bag; a new `Executor#apply_inbound_coercion!` step runs it before `preprocess`/defaults/validation with coerce-or-leave semantics; and `TypeValidator` sharpens its failure message so an uncoerceable string reads differently from a wrong-type value. Adapters (PRO-2844/2845) consume the engine primitives.

**Tech Stack:** Ruby, ActiveModel (validators), RSpec. Stdlib `date`/`time` for parsing.

## Global Constraints

- **Must work outside Rails.** Every feature must pass in `spec/` (non-Rails). Guard any AR/Rails constant with `defined?()`. Coercion touches no Rails constants.
- **Fail at declaration, not runtime.** A bad `coerce:` option combo raises an `ArgumentError` when the class is defined, with a message saying how to fix it. Never silently ignore an option.
- **Coerce-or-leave.** An unparseable string passes through untouched to normal validation — no new raise path. Coercion runs only where declared and only transforms `String`s, so a direct Ruby caller's strictness is unchanged.
- **`coerce:` has zero schema effect.** Reflection is runtime-independent; `input_schema` for a `coerce: Date` field equals that of `type: Date`. Pin with a test.
- **No manual line breaks in Markdown docs** (repo convention): one line per paragraph.
- **Do not commit** unless the human asks; branch is `kali/pro-2873-…` (not a gitbutler worktree). Commit steps below are the intended seams — confirm per repo policy.
- Test runner: `bundle exec rspec <path>`. Full suite: `bundle exec rspec`. Lint: `bundle exec rubocop`.

## File Structure

- Create `lib/axn/reflection/coercion.rb` — `Axn::Reflection::Coercion`: the `SUPPORTED` set, `COERCERS` map, `coerce_value`, `coercible_klasses`. The single home for the wire→Ruby mapping.
- Modify `lib/axn/reflection.rb` — `require "axn/reflection/coercion"`.
- Modify `lib/axn/core/contract.rb` — add `:coerce` to `KNOWN_VALIDATION_KEYS`; expand the `coerce:` sugar + validate coercibility in `_parse_field_validations`; reject `coerce:` on `exposes` and on shape members.
- Modify `lib/axn/core/contract_for_subfields.rb` — reject `coerce:` on subfields (covers `on: :ambient_context`).
- Modify `lib/axn/core/validation/validators/type_validator.rb` — coercion-aware failure message.
- Modify `lib/axn/executor.rb` — `apply_inbound_coercion!` + wire it into `with_contract` before `apply_inbound_preprocessing!`.
- Modify `docs/reference/class.md` — replace the known-limitation warning with a `coerce:` feature section; point the manual `preprocess:` date example at `coerce:`.
- Create `spec/axn/reflection/coercion_spec.rb` — engine unit + round-trip tests.
- Create `spec/axn/core/coercion_spec.rb` — DSL parsing, boundary guards, executor behavior, failure message (end-to-end via `build_axn`).

**PR seam:** all one PR — the engine, DSL, executor step, message, and docs are one cohesive feature.

---

## Task 1: Coercion engine (`Axn::Reflection::Coercion`)

**Files:**
- Create: `lib/axn/reflection/coercion.rb`
- Modify: `lib/axn/reflection.rb`
- Test: `spec/axn/reflection/coercion_spec.rb`

**Interfaces:**
- Produces:
  - `Axn::Reflection::Coercion::SUPPORTED` → `[Date, DateTime, Time, Symbol, Integer, Float]` (frozen).
  - `Axn::Reflection::Coercion.coerce_value(value, klass_or_klasses)` → the coerced value, or the original `value` if it isn't a `String`, no target is coercible, or every coercible target's parse raised. Union targets are tried in order; first successful parse wins.
  - `Axn::Reflection::Coercion.coercible_klasses(type_opt)` → the subset of `type_opt`'s klass(es) in `SUPPORTED`. Accepts a Class, an array of Classes, or a `{ klass: … }` hash; returns `[]` for anything else.

- [ ] **Step 1: Write the failing test**

```ruby
# spec/axn/reflection/coercion_spec.rb
# frozen_string_literal: true

require "spec_helper"

RSpec.describe Axn::Reflection::Coercion do
  describe ".coerce_value" do
    it "parses a string into each supported Ruby type" do
      expect(described_class.coerce_value("2026-07-08", Date)).to eq(Date.new(2026, 7, 8))
      expect(described_class.coerce_value("2026-07-08T12:00:00+00:00", DateTime)).to eq(DateTime.new(2026, 7, 8, 12, 0, 0, "+00:00"))
      expect(described_class.coerce_value("2026-07-08T12:00:00Z", Time)).to eq(Time.utc(2026, 7, 8, 12, 0, 0))
      expect(described_class.coerce_value("active", Symbol)).to eq(:active)
      expect(described_class.coerce_value("123", Integer)).to eq(123)
      expect(described_class.coerce_value("1.5", Float)).to eq(1.5)
    end

    it "parses a zero-padded integer as base 10 (not octal)" do
      expect(described_class.coerce_value("08", Integer)).to eq(8)
    end

    it "returns the original value untouched when it is not a String" do
      d = Date.new(2026, 7, 8)
      expect(described_class.coerce_value(d, Date)).to equal(d)
      expect(described_class.coerce_value(123, Integer)).to eq(123)
    end

    it "returns the original string when the parse fails (coerce-or-leave)" do
      expect(described_class.coerce_value("nope", Date)).to eq("nope")
      expect(described_class.coerce_value("12.5", Integer)).to eq("12.5")
    end

    it "tries union members in order and falls through to the original when none parse" do
      expect(described_class.coerce_value("2026-07-08", [Date, Symbol])).to eq(Date.new(2026, 7, 8))
      expect(described_class.coerce_value("hello", [Date, Symbol])).to eq(:hello)
      expect(described_class.coerce_value("hello", [Date, Integer])).to eq("hello")
    end

    it "ignores a non-coercible target (e.g. String) as a coercion target" do
      expect(described_class.coerce_value("2026-07-08", [Date, String])).to eq(Date.new(2026, 7, 8))
      expect(described_class.coerce_value("hello", [String])).to eq("hello")
    end
  end

  describe ".coercible_klasses" do
    it "extracts the supported subset from a Class, array, or type hash" do
      expect(described_class.coercible_klasses(Date)).to eq([Date])
      expect(described_class.coercible_klasses([Date, String])).to eq([Date])
      expect(described_class.coercible_klasses({ klass: [Symbol, Integer] })).to eq([Symbol, Integer])
      expect(described_class.coercible_klasses({ klass: String })).to eq([])
      expect(described_class.coercible_klasses(:boolean)).to eq([])
    end
  end

  describe "round-trip with the encoder" do
    it "is the inverse of Values.serialize_value for string-encoded types" do
      [Date.new(2026, 7, 8), :active, Time.utc(2026, 7, 8, 12, 0, 0)].each do |value|
        encoded = Axn::Reflection::Values.serialize_value(value)
        expect(encoded).to be_a(String)
        expect(described_class.coerce_value(encoded, value.class)).to eq(value)
      end
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/reflection/coercion_spec.rb`
Expected: FAIL — `uninitialized constant Axn::Reflection::Coercion`.

- [ ] **Step 3: Write the implementation**

```ruby
# lib/axn/reflection/coercion.rb
# frozen_string_literal: true

require "date"
require "time"

module Axn
  module Reflection
    # Inbound wire DECODER — the parse-based inverse of Values.serialize_value, keyed off the same
    # class set so encoder and decoder can't drift. The single home for the wire→Ruby mapping: the
    # `coerce:` DSL (per-field, at runtime via Executor#apply_inbound_coercion!) and adapters (bulk,
    # by walking configs) both call this rather than reinventing it. Read-only, off the execution path.
    module Coercion
      module_function

      # The types with a strict, unambiguous `String → T` parse. `:boolean` (lenient/ambiguous) and
      # BigDecimal (String→decimal) are deferred to their own tickets — a coerce: target outside this
      # set raises not-yet-supported at declaration (see Contract#_validate_coercion!).
      SUPPORTED = [Date, DateTime, Time, Symbol, Integer, Float].freeze

      # Each coercer is the inverse of the corresponding Values.serialize_value branch (iso8601 for
      # Date/Time/DateTime, to_s for Symbol). Integer uses base 10 explicitly — bare `Integer("08")`
      # raises on the octal ambiguity a zero-padded form field would trip.
      COERCERS = {
        Date => ->(s) { Date.parse(s) },
        DateTime => ->(s) { DateTime.parse(s) },
        Time => ->(s) { Time.parse(s) },
        Symbol => ->(s) { s.to_sym },
        Integer => ->(s) { Integer(s, 10) },
        Float => ->(s) { Float(s) },
      }.freeze

      # Coerce-or-leave: only a String is a coercion candidate (a direct Ruby caller passing a real
      # Date, or a JSON-native number, is returned untouched). Union targets are tried in declaration
      # order; the first that parses wins; a parse that raises falls through to the next, and if none
      # parse the ORIGINAL value is returned so it hits the normal TypeValidator error. A non-coercible
      # target (e.g. String) is skipped — it never coerces, it's only a validation branch.
      def coerce_value(value, klass_or_klasses)
        return value unless value.is_a?(String)

        Array(klass_or_klasses).each do |klass|
          coercer = COERCERS[klass]
          next unless coercer

          begin
            return coercer.call(value)
          rescue ArgumentError, TypeError
            next
          end
        end

        value
      end

      # The coercible subset of a type: option's klass(es) — the single source of truth for "what does
      # this field coerce to", consulted by both the declaration-time guard and the runtime step.
      def coercible_klasses(type_opt)
        klass = type_opt.is_a?(Hash) ? type_opt[:klass] : type_opt
        Array(klass).select { |k| SUPPORTED.include?(k) }
      end
    end
  end
end
```

```ruby
# lib/axn/reflection.rb — add alongside the existing requires
require "axn/reflection/coercion"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/axn/reflection/coercion_spec.rb`
Expected: PASS (all examples green).

- [ ] **Step 5: Commit**

```bash
git add lib/axn/reflection/coercion.rb lib/axn/reflection.rb spec/axn/reflection/coercion_spec.rb
git commit -m "PRO-2873: Add Axn::Reflection::Coercion engine (wire→Ruby decoder)"
```

---

## Task 2: `coerce:` DSL sugar + coercibility validation

**Files:**
- Modify: `lib/axn/core/contract.rb` (`KNOWN_VALIDATION_KEYS`; `_parse_field_validations`; add `_expand_coerce_sugar!` + `_validate_coercion!`)
- Test: `spec/axn/core/coercion_spec.rb`

**Interfaces:**
- Consumes: `Axn::Reflection::Coercion.coercible_klasses` (Task 1).
- Produces: after declaration, a coerce field's config has `validations[:type] == { klass: <Type>, coerce: true, allow_nil:, allow_blank: }`. The standalone `:coerce` key never survives into `validations` (it is expanded and deleted), so it never reaches ActiveModel `validates`.

- [ ] **Step 1: Write the failing test**

```ruby
# spec/axn/core/coercion_spec.rb
# frozen_string_literal: true

require "spec_helper"
require "bigdecimal" # for the not-yet-supported guard test below (non-Rails specs don't autoload it)

RSpec.describe "coerce: DSL" do
  describe "parsing" do
    it "expands `coerce: <Type>` sugar into a coerce flag inside the type bag" do
      action = build_axn { expects :date, coerce: Date }
      type = action.internal_field_configs.first.validations[:type]
      expect(type[:klass]).to eq(Date)
      expect(type[:coerce]).to be(true)
    end

    it "accepts the explicit `type: { klass:, coerce: true }` form" do
      action = build_axn { expects :date, type: { klass: Date, coerce: true } }
      expect(action.internal_field_configs.first.validations[:type][:coerce]).to be(true)
    end

    it "accepts a union that pairs a coercible type with String" do
      action = build_axn { expects :date, coerce: [Date, String] }
      expect(action.internal_field_configs.first.validations[:type][:klass]).to eq([Date, String])
    end

    it "raises when coerce: and type: are combined" do
      expect { build_axn { expects :date, coerce: Date, type: Date } }
        .to raise_error(ArgumentError, /coerce: and type: cannot be combined/)
    end

    it "raises when coerce: is given a boolean at the top level" do
      expect { build_axn { expects :date, coerce: true } }
        .to raise_error(ArgumentError, /coerce: must be a type.*not a boolean/m)
    end

    it "raises a not-yet-supported error for an unsupported coerce target" do
      expect { build_axn { expects :amount, coerce: BigDecimal } }
        .to raise_error(ArgumentError, /coerce: does not yet support.*BigDecimal.*supported: Date, DateTime, Time, Symbol, Integer, Float/m)
      expect { build_axn { expects :flag, coerce: :boolean } }
        .to raise_error(ArgumentError, /coerce: does not yet support.*boolean/m)
    end

    it "raises when a union has no coercible member" do
      expect { build_axn { expects :name, coerce: [String] } }
        .to raise_error(ArgumentError, /coerce: needs at least one coercible type/)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/core/coercion_spec.rb`
Expected: FAIL — the first example errors with `Unknown key(s) :coerce in field declaration` (partition rejects it before expansion exists).

- [ ] **Step 3: Add `:coerce` to `KNOWN_VALIDATION_KEYS`**

In `lib/axn/core/contract.rb`, extend the set so `coerce:` survives `_partition_field_options`:

```ruby
        KNOWN_VALIDATION_KEYS = Set.new(%i[
                                          absence acceptance comparison confirmation exclusion format
                                          inclusion length numericality presence uniqueness
                                          type model validate of shape coerce
                                          if unless on message strict
                                        ]).freeze
```

- [ ] **Step 4: Expand + validate in `_parse_field_validations`**

In `lib/axn/core/contract.rb`, at the top of `_parse_field_validations` (before the `type:` sugar line), expand the coerce sugar, then validate coercibility for both the sugar and explicit forms:

```ruby
        def _parse_field_validations(
          *fields,
          allow_nil: false,
          allow_blank: false,
          **validations
        )
          # `coerce: <Type>` sugar → a coerce flag inside the type bag (coercion binds to the type;
          # it is meaningless without one). Runs before the type: sugar so the resulting `{ klass: }`
          # hash flows through the normal path.
          _expand_coerce_sugar!(validations)

          # Apply syntactic sugar for our custom validators (convert shorthand to full hash of options)
          validations[:type] = Axn::Validators::TypeValidator.apply_syntactic_sugar(validations[:type], fields) if validations.key?(:type)
          validations[:model] = Axn::Validators::ModelValidator.apply_syntactic_sugar(validations[:model], fields) if validations.key?(:model)
          validations[:validate] = Axn::Validators::ValidateValidator.apply_syntactic_sugar(validations[:validate], fields) if validations.key?(:validate)

          # Validate the coerce target set (covers BOTH the sugar above and an explicit
          # `type: { klass:, coerce: true }`) once the type bag is canonical.
          _validate_coercion!(validations[:type]) if validations[:type].is_a?(Hash) && validations[:type][:coerce]

          if validations.key?(:of)
```

(the `if validations.key?(:of)` block and everything after it are unchanged)

Then add the two private helpers (place them next to `_parse_field_validations`, still under `private` in `ClassMethods`):

```ruby
        # `coerce: <Type>` → `type: { klass: <Type>, coerce: true }`. The sugar value carries the
        # target type (a Class or array of Classes), never a boolean — the boolean lives only inside
        # the type hash. Combining with an explicit `type:` is contradictory (the sugar already
        # declares the type), so it raises.
        def _expand_coerce_sugar!(validations)
          return unless validations.key?(:coerce)

          if validations.key?(:type)
            raise ArgumentError,
                  "coerce: and type: cannot be combined (coerce: already declares the type). " \
                  "Use `type: { klass: …, coerce: true }` when you also need sibling type options."
          end

          target = validations.delete(:coerce)
          if [true, false].include?(target)
            raise ArgumentError,
                  "coerce: must be a type (a Class or array of Classes), not a boolean. " \
                  "The boolean form lives inside `type: { klass: …, coerce: true }`."
          end

          validations[:type] = { klass: target, coerce: true }
        end

        # A coerce target must be in the v1 coercible set (Axn::Reflection::Coercion::SUPPORTED); an
        # unsupported type raises not-yet-supported so expanding the set stays a deliberate future
        # ticket. `String` may accompany a coercible type as a passthrough branch (the raw wire scalar
        # itself), which is why `coerce: [Date, String]` is legal — but a target set with no coercible
        # member coerces nothing and is a declaration mistake.
        def _validate_coercion!(type_hash)
          klasses = Array(type_hash[:klass])
          coercible = Axn::Reflection::Coercion.coercible_klasses(type_hash)
          unsupported = klasses - coercible - [String]

          unless unsupported.empty?
            raise ArgumentError,
                  "coerce: does not yet support #{unsupported.map(&:inspect).join(', ')} " \
                  "(supported: Date, DateTime, Time, Symbol, Integer, Float). " \
                  "String may accompany a coercible type as a passthrough."
          end

          return unless coercible.empty?

          raise ArgumentError,
                "coerce: needs at least one coercible type (Date, DateTime, Time, Symbol, Integer, Float); " \
                "got #{klasses.map(&:inspect).join(', ')}."
        end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bundle exec rspec spec/axn/core/coercion_spec.rb`
Expected: PASS. Then `bundle exec rspec spec/axn/core/validations` to confirm no existing type/DSL specs regressed.

- [ ] **Step 6: Commit**

```bash
git add lib/axn/core/contract.rb spec/axn/core/coercion_spec.rb
git commit -m "PRO-2873: Add coerce: DSL sugar + declaration-time coercibility guards"
```

---

## Task 3: Boundary guards — reject `coerce:` outside top-level `expects`

**Files:**
- Modify: `lib/axn/core/contract.rb` (`exposes`; `_build_shape_member`)
- Modify: `lib/axn/core/contract_for_subfields.rb` (`_parse_subfield_configs`)
- Test: `spec/axn/core/coercion_spec.rb` (append)

**Interfaces:**
- Consumes: the expanded `validations[:type][:coerce]` flag (Task 2).
- Produces: `coerce:` raises at declaration on `exposes`, subfields (incl. `on: :ambient_context`), and shape members — mirroring the existing `preprocess:` boundary.

- [ ] **Step 1: Write the failing test (append to `spec/axn/core/coercion_spec.rb`)**

```ruby
  describe "boundary (top-level expects only)" do
    it "rejects coerce: on exposes" do
      expect { build_axn { exposes :date, coerce: Date } }
        .to raise_error(ArgumentError, /coerce: is not supported on exposes/)
    end

    it "rejects coerce: on a subfield" do
      expect do
        build_axn do
          expects :payload, type: Hash
          expects :when, on: :payload, coerce: Date
        end
      end.to raise_error(ArgumentError, /coerce: is not supported on subfields/)
    end

    it "rejects coerce: on an ambient_context subfield" do
      expect { build_axn { expects :when, on: :ambient_context, coerce: Date } }
        .to raise_error(ArgumentError, /coerce: is not supported on subfields/)
    end

    it "rejects coerce: on a shape member" do
      expect do
        build_axn do
          expects :payload, type: Hash do
            field :when, coerce: Date
          end
        end
      end.to raise_error(ArgumentError, /coerce: is not supported on a shape member/)
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/core/coercion_spec.rb -e boundary`
Expected: FAIL — no error raised (the exposes/subfield/shape declarations currently succeed, carrying an inert coerce flag).

- [ ] **Step 3: Reject on `exposes`**

In `lib/axn/core/contract.rb`, inside `exposes`, after `_parse_field_configs(...)` produces `configs` and before the duplicate check, guard the coerce flag. Replace the `.tap do |configs|` opening body:

```ruby
          _parse_field_configs(*fields, allow_blank:, allow_nil:, optional:, default:, preprocess: nil, sensitive:, metadata:, **validations).tap do |configs|
            if configs.any? { |c| c.validations.dig(:type, :coerce) }
              raise ArgumentError, "coerce: is not supported on exposes (outbound fields are serialized, not coerced)."
            end

            duplicated = _duplicate_fields(external_field_configs, configs)
            raise Axn::DuplicateFieldError, "Duplicate field(s) declared: #{duplicated.join(', ')}" if duplicated.any?

            # NOTE: avoid <<, which would update value for parents and children
            self.external_field_configs += configs
          end
```

- [ ] **Step 4: Reject on shape members**

In `lib/axn/core/contract.rb`, inside `_build_shape_member`, after `config` is built and before returning the `ShapeConfig`:

```ruby
          config = _parse_field_configs(name, metadata:, **field_opts, **field_validations).first
          if config.validations.dig(:type, :coerce)
            raise ArgumentError, "coerce: is not supported on a shape member (top-level `expects` fields only)."
          end

          ShapeConfig.new(field: name, validations: config.validations, metadata: config.metadata)
```

- [ ] **Step 5: Reject on subfields**

In `lib/axn/core/contract_for_subfields.rb`, inside `_parse_subfield_configs`, guard the coerce flag on the parsed validations. Replace the `_parse_field_validations(...).map do |field, parsed_validations|` body opening:

```ruby
          _parse_field_validations(*fields, allow_nil:, allow_blank:, **validations).map do |field, parsed_validations|
            if parsed_validations.dig(:type, :coerce)
              raise ArgumentError,
                    "coerce: is not supported on subfields (top-level `expects` fields only; " \
                    "an adapter can coerce deeper by walking the schema)."
            end
```

(the rest of the `.map` block — building each `SubfieldConfig` — is unchanged)

- [ ] **Step 6: Run tests to verify they pass**

Run: `bundle exec rspec spec/axn/core/coercion_spec.rb`
Expected: PASS. Then `bundle exec rspec spec/axn/core/validations` to confirm subfield/shape specs still pass.

- [ ] **Step 7: Commit**

```bash
git add lib/axn/core/contract.rb lib/axn/core/contract_for_subfields.rb spec/axn/core/coercion_spec.rb
git commit -m "PRO-2873: Reject coerce: outside top-level expects (mirrors preprocess boundary)"
```

---

## Task 4: Executor step — `apply_inbound_coercion!`

**Files:**
- Modify: `lib/axn/executor.rb` (`with_contract`; add `apply_inbound_coercion!`)
- Test: `spec/axn/core/coercion_spec.rb` (append)

**Interfaces:**
- Consumes: `Axn::Reflection::Coercion.coercible_klasses` / `.coerce_value` (Task 1); the `validations[:type][:coerce]` flag (Task 2).
- Produces: inbound `provided_data` values for coerce-flagged fields are coerced (wire→Ruby) before `preprocess`, defaults, and validation run.

- [ ] **Step 1: Write the failing test (append to `spec/axn/core/coercion_spec.rb`)**

```ruby
  describe "runtime coercion" do
    it "coerces a wire string into the declared Ruby type" do
      action = build_axn do
        expects :on, coerce: Date
        exposes :klass, allow_blank: true
        def call = expose(klass: self.on.class.name)
      end
      result = action.call(on: "2026-07-08")
      expect(result).to be_ok
      expect(result.klass).to eq("Date")
    end

    it "leaves a value that is already the Ruby type untouched" do
      action = build_axn do
        expects :on, coerce: Date
        exposes :day, allow_blank: true
        def call = expose(day: self.on.day)
      end
      result = action.call(on: Date.new(2026, 7, 8))
      expect(result).to be_ok
      expect(result.day).to eq(8)
    end

    it "runs coercion BEFORE a user preprocess: on the same field" do
      action = build_axn do
        expects :on, coerce: Date, preprocess: ->(v) { v.is_a?(Date) ? v + 1 : v }
        exposes :day, allow_blank: true
        def call = expose(day: self.on.day)
      end
      result = action.call(on: "2026-07-08")
      expect(result).to be_ok
      expect(result.day).to eq(9) # preprocess saw a coerced Date and added a day
    end

    it "does not clobber a real-object default" do
      action = build_axn do
        expects :on, coerce: Date, default: -> { Date.new(2000, 1, 1) }
        exposes :day, allow_blank: true
        def call = expose(day: self.on.day)
      end
      result = action.call
      expect(result).to be_ok
      expect(result.day).to eq(1)
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/core/coercion_spec.rb -e "runtime coercion"`
Expected: FAIL — first example: `result.klass` is `"String"` (coercion not yet applied), so validation rejects the String as not a Date and `result` is not ok.

- [ ] **Step 3: Add the executor step and wire it in**

In `lib/axn/executor.rb`, call coercion first in `with_contract` (a pure string-parse can't raise `EarlyCompletion`, so it needs no wrapper):

```ruby
    def with_contract(&block)
      apply_inbound_coercion!
      return if handle_early_completion_if_raised { apply_inbound_preprocessing! }
      return if handle_early_completion_if_raised { apply_defaults!(:inbound) }

      validate_contract!(:inbound)
```

(the rest of `with_contract` is unchanged)

Add the method in the CONTRACT section (e.g. just above `apply_inbound_preprocessing!`):

```ruby
    # Wire→Ruby coercion for declared-inbound fields that opted in via `coerce:` (a `coerce: true`
    # flag inside the type bag). Runs first in the inbound pipeline — before any user preprocess:,
    # defaults, and validation — so downstream stages see the Ruby value. Coerce-or-leave
    # (Axn::Reflection::Coercion): only String values are transformed, an unparseable string passes
    # through to the normal TypeValidator error, and a present real object is untouched. Top-level
    # fields only (subfields reject coerce: at declaration); absent keys are not materialized.
    def apply_inbound_coercion!
      @action_class.send(:internal_field_configs).each do |config|
        type_opt = config.validations[:type]
        next unless type_opt.is_a?(Hash) && type_opt[:coerce]
        next unless @context.provided_data.key?(config.field)

        klasses = Axn::Reflection::Coercion.coercible_klasses(type_opt)
        @context.provided_data[config.field] =
          Axn::Reflection::Coercion.coerce_value(@context.provided_data[config.field], klasses)
      end
    end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/axn/core/coercion_spec.rb`
Expected: PASS.

- [ ] **Step 5: Verify reflection is unaffected (coerce has zero schema effect)**

Append this test to `spec/axn/core/coercion_spec.rb`:

```ruby
  describe "schema" do
    it "reflects a coerce: field identically to a plain type: field" do
      coerced = build_axn { expects :on, coerce: Date }
      plain   = build_axn { expects :on, type: Date }
      expect(coerced.input_schema).to eq(plain.input_schema)
    end
  end
```

Run: `bundle exec rspec spec/axn/core/coercion_spec.rb -e schema`
Expected: PASS (coercion is runtime-only; the `coerce` key in the type bag is ignored by `Reflection::Schema`).

- [ ] **Step 6: Commit**

```bash
git add lib/axn/executor.rb spec/axn/core/coercion_spec.rb
git commit -m "PRO-2873: Apply inbound coercion before preprocess/defaults/validation"
```

---

## Task 5: Coercion-aware failure message in `TypeValidator`

**Files:**
- Modify: `lib/axn/core/validation/validators/type_validator.rb`
- Test: `spec/axn/core/coercion_spec.rb` (append)

**Interfaces:**
- Consumes: `options[:coerce]` (present on a coerce field's type bag, Task 2).
- Produces: when a coerce field is left holding an unparseable `String`, the validation error reads `could not be coerced to a Date` (single) / `could not be coerced to one of Date, Integer` (union); a non-string wrong-type value keeps `is not a Date`; an explicit `message:` still overrides.

- [ ] **Step 1: Write the failing test (append to `spec/axn/core/coercion_spec.rb`)**

```ruby
  describe "coercion-failure message" do
    it "reports an uncoerceable string distinctly from a wrong-type value" do
      action = build_axn { expects :on, coerce: Date }

      uncoerceable = action.call(on: "nope")
      expect(uncoerceable).not_to be_ok
      expect(uncoerceable.exception.message).to match(/could not be coerced to a Date/)

      wrong_type = action.call(on: 123)
      expect(wrong_type).not_to be_ok
      expect(wrong_type.exception.message).to match(/is not a Date/)
      expect(wrong_type.exception.message).not_to match(/could not be coerced/)
    end

    it "does not emit the coercion message when a String branch validates the value" do
      action = build_axn { expects :on, coerce: [Date, String] }
      expect(action.call(on: "nope")).to be_ok
    end

    it "honors an explicit message: override" do
      action = build_axn { expects :on, type: { klass: Date, coerce: true, message: "bad date" } }
      result = action.call(on: "nope")
      expect(result).not_to be_ok
      expect(result.exception.message).to match(/bad date/)
      expect(result.exception.message).not_to match(/could not be coerced/)
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/core/coercion_spec.rb -e "coercion-failure message"`
Expected: FAIL — the uncoerceable case reports `is not a Date` (no `could not be coerced` branch yet).

- [ ] **Step 3: Sharpen the failure message**

In `lib/axn/core/validation/validators/type_validator.rb`, route the default message through a coercion-aware helper:

```ruby
      def validate_each(record, attribute, value)
        # Custom allow_blank logic: only skip validation for nil, not other blank values
        return if value.nil? && (options[:allow_nil] || options[:allow_blank])

        # Check if any of the types are valid
        valid = types.any? do |type|
          self.class.value_matches?(value, klass: type, allow_blank: options[:allow_blank])
        end

        record.errors.add attribute, (options[:message] || failure_message(value)) unless valid
      end
```

Then, in the `private` section, add `failure_message`/`coercion_msg` next to `msg`:

```ruby
      private

      def types = Array(options[:klass])
      def msg = types.size == 1 ? "is not a #{types.first}" : "is not one of #{types.join(', ')}"

      # A field that opted into coercion but is still holding a String means the string couldn't be
      # parsed into any target type — distinguish that from a plain wrong-type value (a non-String
      # that was never a coercion candidate). Value-free, like `msg`, so no sensitive input leaks.
      def failure_message(value)
        return coercion_msg if options[:coerce] && value.is_a?(String)

        msg
      end

      def coercion_msg
        types.size == 1 ? "could not be coerced to a #{types.first}" : "could not be coerced to one of #{types.join(', ')}"
      end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/axn/core/coercion_spec.rb`
Expected: PASS. Then `bundle exec rspec spec/axn/core/validations/validators/type_validator_spec.rb` to confirm the plain `is not a` messages are unchanged for non-coerce fields.

- [ ] **Step 5: Commit**

```bash
git add lib/axn/core/validation/validators/type_validator.rb spec/axn/core/coercion_spec.rb
git commit -m "PRO-2873: Distinguish uncoerceable strings from wrong-type values in TypeValidator"
```

---

## Task 6: Documentation

**Files:**
- Modify: `docs/reference/class.md` (the `preprocess` section ~`:265-272`; the known-limitation warning ~`:662-664`)

**Interfaces:** none (docs only).

- [ ] **Step 1: Add a `coerce` feature section and update the `preprocess` example**

In `docs/reference/class.md`, update the `#### preprocess` section so the manual date example points at the new standard, and add a `#### coerce` section after it. Replace the existing `preprocess` block:

```markdown
#### `preprocess`
`expects` also supports a `preprocess` option that, if set to a callable, will be executed _before_ applying any defaults or validations. Use it for a custom, field-specific transform. For the common case of turning a wire string into a Ruby type (`Date`/`Symbol`/…), prefer `coerce:` (below), which is the shared, standard inverse of the output serializer. If the preprocess callable raises an exception, that'll be swallowed and the action failed.

#### `coerce`
`expects` supports a `coerce:` option that parses an inbound wire string into its declared Ruby type _before_ your `preprocess`, defaults, and validation run — the inbound inverse of how a `Date`/`Symbol` result serializes on the way out. This closes the round-trip gap: a JSON client (or a Rails form) sending `"2026-07-08"` or `"active"` is accepted for a `Date`/`Symbol` field, rather than rejected for not already being the Ruby object.

```ruby
expects :on, coerce: Date                          # "2026-07-08"  → Date
expects :mode, coerce: Symbol, inclusion: { in: %i[a b] }  # "a" → :a, then validated
expects :count, coerce: Integer                    # "123" → 123 (base 10)
expects :on, type: { klass: Date, coerce: true }   # explicit form (use with sibling type options like message:)
expects :on, coerce: [Date, String]                # union: parse a date if possible, else keep the string
```

The supported types are `Date`, `DateTime`, `Time`, `Symbol`, `Integer`, and `Float` — those with a strict, unambiguous string parse. Coercion is **coerce-or-leave**: only strings are transformed (a value already of the right type, or a JSON-native number, is untouched), and an unparseable string passes through to a normal validation error (reported as "could not be coerced to a Date", distinct from a wrong-type "is not a Date"). `coerce:` is opt-in per field, so a direct Ruby caller's strictness is unchanged, and it is valid on top-level `expects` fields only.
```

- [ ] **Step 2: Replace the known-limitation warning**

Replace the `::: warning Ruby-object input types need coercion` block (~`:662-664`) with a tip that points at the feature:

```markdown
::: tip Ruby-object input types are coercible
The schema advertises each `type:` as its JSON wire form — so `expects :on, type: Date` shows `{ type: "string", format: "date" }` and `expects :mode, type: Symbol` shows `{ type: "string" }`. Add `coerce:` (see [`coerce`](#coerce) above) so a JSON client sending the string `"2026-07-08"` or `"active"` is parsed into the declared `Date`/`Symbol` — the inbound inverse of how the value serializes on output. Without `coerce:`, core still validates strictly against the Ruby type (a direct Ruby caller must pass a real `Date`).
:::
```

- [ ] **Step 3: Verify no manual line breaks were introduced**

Confirm each paragraph above is a single line (repo convention). Visually check the diff:

Run: `git diff docs/reference/class.md`
Expected: added paragraphs are each one line; no mid-paragraph hard wraps.

- [ ] **Step 4: Commit**

```bash
git add docs/reference/class.md
git commit -m "PRO-2873: Document coerce: and retire the coercion known-limitation note"
```

---

## Final verification

- [ ] **Run the full suite (non-Rails):** `bundle exec rspec` — all green.
- [ ] **Run the Rails suite:** `bundle exec rspec spec_rails` — all green (coercion adds no Rails coupling; this confirms no regression).
- [ ] **Lint:** `bundle exec rubocop lib/axn/reflection/coercion.rb lib/axn/core/contract.rb lib/axn/core/contract_for_subfields.rb lib/axn/core/validation/validators/type_validator.rb lib/axn/executor.rb` — clean.
- [ ] **Manual sanity (optional):** in `bin/console`, `A = Class.new { include Axn; expects :on, coerce: Date; def call = expose_something }` and confirm `A.call(on: "2026-07-08")` resolves `on` to a `Date`, `A.call(on: "nope")` fails with a "could not be coerced" message, and `A.input_schema` matches the `type: Date` schema.

## Self-review notes (spec coverage)

- Engine (`Coercion`) → Task 1. DSL sugar + explicit form + guards 1/2/3 → Task 2. Boundary guard 4 → Task 3. Executor step + ordering + no-clobber + zero-schema-effect → Task 4. §3a coercion-failure message → Task 5. Docs (warning + preprocess example) → Task 6.
- Deferred items (`:boolean`, `BigDecimal`, bulk adapter walk, `klass`/`class` rename, `date_select`) are intentionally out of scope and covered by the not-yet-supported guard (Task 2) — no task implements them.
