# Positional Tolerance in an `of:` Bag — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make an `of:` bag's `optional:`/`allow_nil:`/`allow_blank:` govern the position it describes, by first moving axn's own tolerance record out of the validator entries and onto the declaration.

**Architecture:** Two independent halves. Part A relocates the `allow_blank:`/`allow_nil:` pair from every validator entry to the top level of `validations`, where ActiveModel's own defaults tier already reads it — this is what makes a bag's keys author-only. Part B then teaches `OfValidator`, the declaration guards and the schema emitter to read the bag's tolerance as the position's, reusing the field's helpers rather than mirroring them.

**Tech Stack:** Ruby 3.2/3.3/3.4, ActiveModel 7.2.2.2 (validators, `_validates_default_keys`), RSpec.

**Spec:** `internal-docs/specs/2026-08-27-positional-tolerance-in-an-of-bag-design.md`

## Global Constraints

- **axn must work outside Rails.** Guard any `ActiveRecord`/`Rails` reference with `defined?()`. Use core-Ruby `Hash#delete`/`Hash#except` over ActiveSupport `Hash#except!` — the core_ext may never be loaded. `spec/` is non-Rails; `spec_rails/` has the dummy app.
- **Never assert `Hash#inspect` text** in a spec. The CI matrix is Ruby 3.2/3.3/3.4 and the rendering differs.
- **Read a caller-supplied value non-dispatchingly.** Classify a bag with `Axn::Internal::ShapeGraph.hash_or_nil`, ask for a key with `ShapeGraph.carries_key?`, read type tokens with `ShapeGraph.type_tokens` — never `is_a?(Hash)`, `Hash#key?` on an unclassified value, or `Kernel#Array` on a declared token. Declaration guards run at class-definition time, so a token whose method raises stops the class being defined.
- **The shared-option list is AM's own**, read through `Axn::Validation::Base.shared_validation_option_keys` (= `_validates_default_keys` = `[:if, :unless, :on, :allow_blank, :allow_nil, :strict, :except_on]`). Never restate it.
- **One definition per judgment.** Where the field path already answers a question, the bag path calls the same method rather than growing a second copy.
- **No historical comments in code.** No "used to X / now Y", no ticket numbers as justification-by-citation, no "(Codex review)". Describe the mechanism as it stands.
- **Run the suite with `bundle exec rspec`** from the worktree root, in the FOREGROUND with a generous timeout (600000 ms). Full suite is ~4 minutes / 7251 examples. Do not background it and poll — that is how a run gets abandoned half-finished.
- **Locate code by name, never by this plan's line numbers.** Five tasks edit `lib/axn/core/contract.rb` in sequence, so every line reference below is stale the moment an earlier task lands. The line numbers are provenance — they say where the thing was when the plan was written. Find the method or constant by name.
- **Two things write into an `of:` bag**, and both must stop for the bag to be author-only: the tolerance push in `_parse_field_validations`' tolerant branch, and `_apply_nil_skip_to_non_type_validators!`, which merges `allow_nil: true` into every non-`type:` entry whenever the field's `type:` rejects nil — i.e. on every *required* container field. Task 1 handles both.

---

### Task 1: Move the tolerance record to the top level

The load-bearing change. Everything else depends on a bag no longer carrying keys axn wrote.

**Files:**
- Modify: `lib/axn/core/contract.rb` — the tolerant branch of `_parse_field_validations`
- Modify: `lib/axn/core/contract.rb` — `_apply_nil_skip_to_non_type_validators!` (exempt `:of`)
- Modify: `lib/axn/core/contract.rb` — `_tolerance_exempt_validator?`'s comment (the exemption now works by overriding, not by skipping)
- Modify: `lib/axn/core/contract.rb` — `_confirmation_companion_configs`' comment about the inherited tolerance
- Test: `spec/axn/core/validations/recursive_of_spec.rb` (rewrite the "writes the tolerance pair onto the map bag" example), `spec/axn/core/validations/confirmation_spec.rb` (the three-base-shape block), and new examples in `spec/axn/core/validations/of_bag_value_validators_spec.rb`

**Interfaces:**
- Produces: `validations` carries `allow_blank:`/`allow_nil:` at its top level on a tolerant declaration, and no validator entry carries a copy. An `of:` bag carries no tolerance axn wrote, on a required or an optional field. `Axn::Validation::Base.nil_accepted?`, `optional?`, `effective_entry_options` and every emitter read it from the top level unchanged — no new method.

- [ ] **Step 1: Write the failing test — the pair lands once, at the top level**

Add to `spec/axn/core/validations/of_bag_value_validators_spec.rb`, in a new top-level `describe`:

```ruby
  # A field's tolerance is a fact about the DECLARATION, so it is recorded there — once — rather than
  # copied into every validator entry. ActiveModel applies a declaration's shared options to each
  # validator itself (`defaults.merge(_parse_validates_options(options))`), which is the tier
  # `effective_entry_options` and `nil_accepted?` already resolve against. Recording it per entry made
  # axn's copies indistinguishable from an author's, which is what stopped a bag's own keys meaning the
  # position they describe.
  describe "where a field's tolerance is recorded" do
    it "states the pair on the declaration and writes it into no validator entry" do
      action = build_axn { expects :f, type: Array, of: Integer, optional: true }
      validations = action.internal_field_configs.first.validations

      expect(validations).to include(allow_blank: true, allow_nil: false)
      expect(validations[:type]).to eq(klass: Array)
      expect(validations[:of]).to eq(klass: Integer, container: Array)
    end

    it "keeps optional? reading true off the declaration tier alone" do
      action = build_axn { expects :f, type: Array, of: Integer, optional: true }

      expect(action.internal_field_configs.first.optional?).to be(true)
    end

    it "leaves a required field's bag free of any tolerance axn did not write" do
      action = build_axn { expects :f, type: Array, of: Integer }

      expect(action.internal_field_configs.first.validations[:of]).to eq(klass: Integer, container: Array)
    end
  end
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `bundle exec rspec spec/axn/core/validations/of_bag_value_validators_spec.rb -e "where a field's tolerance is recorded"`

Expected: FAIL. The first example reports `validations` missing `allow_blank`/`allow_nil` at the top level and `validations[:type]` carrying `{allow_blank: true, allow_nil: false, klass: Array}`.

- [ ] **Step 3: Replace the per-entry push with a top-level pair**

In `lib/axn/core/contract.rb`, the tolerant branch of `_parse_field_validations`. Replace the loop body and the restore with:

```ruby
          if tolerant
            # ActiveModel's shared "default" options (`if:`/`unless:`/`on:`/`strict:`/`allow_blank:`/
            # `allow_nil:`/`except_on:`) ride the hash as sibling keys of the validators but are NOT
            # validators. Sliced out (through AM's own canonical list, so the set cannot drift) and
            # restored verbatim, because normalizing one as a scalar would corrupt it — `if: :flag` would
            # become `if: { with: :flag }`, a Hash the callback machinery cannot resolve, so the gate would
            # stop deciding anything. Core-Ruby delete rather than ActiveSupport's `Hash#except!`: axn runs
            # outside Rails, where that core_ext may never be loaded.
            shared_option_keys = Axn::Validation::Base.shared_validation_option_keys
            shared_options = validations.slice(*shared_option_keys)
            shared_option_keys.each { |key| validations.delete(key) }

            # `confirmation:` is the one validator a tolerance must not reach, and it is held out by
            # OVERRIDING the declaration tier rather than by being skipped: the pair is stated on the
            # declaration below, so `validates` applies it to every entry, and an entry's own value wins per
            # key (AM merges `defaults.merge(entry)`). Every other validator judges the field's own value, so
            # a tolerance stands it down — there is nothing to check when the value the author called optional
            # is absent. `confirmation:`'s subject is the RELATIONSHIP between the field and its companion,
            # and a supplied companion is compared against the base whatever the base holds: `password: ""`
            # beside `password_confirmation: "x"` is a mismatch the caller must see, not a blank to wave
            # through. A snapshot of the keys, since the loop reassigns entries as it goes.
            validations.keys.each do |key|
              v = validations[key]
              next unless v
              next unless _tolerance_exempt_validator?(key)

              validations[key] = Axn::Validation::Base.normalize_validator_options(v)
                                                      .merge(allow_blank: false, allow_nil: false)
            end

            validations.merge!(shared_options)
            # The declaration's own tier, stated once. An author who wrote the key directly among the
            # validations is authoritative — that spelling arrived in `shared_options` above — so it is not
            # overwritten here.
            validations[:allow_blank] = allow_blank unless shared_options.key?(:allow_blank)
            validations[:allow_nil] = allow_nil unless shared_options.key?(:allow_nil)
          else
            _apply_default_presence!(validations, allow_empty:, tolerant:)
          end
```

- [ ] **Step 4: Run the new examples**

Run: `bundle exec rspec spec/axn/core/validations/of_bag_value_validators_spec.rb -e "where a field's tolerance is recorded"`

Expected: PASS, all three.

- [ ] **Step 5: Run the full suite and confirm exactly the three expected failures**

Run: `bundle exec rspec 2>&1 | tail -20`

Expected: 3 failures, and no others —
1. `spec/axn/core/validations/recursive_of_spec.rb:1506` "writes the tolerance pair onto the map bag and never into an axis"
2. `spec/axn/core/validations/confirmation_spec.rb[1:2:13:1]` "with an allow_nil: base still requires the companion once the base is present"
3. `spec/axn/core/validations/confirmation_spec.rb[1:2:14:1]` "with an optional: base still requires the companion once the base is present"

If any OTHER example fails, stop and report it — the whole plan is priced on this being the complete set.

- [ ] **Step 6: Rewrite the `recursive_of_spec` measurement to pin the new mechanism**

Replace the body of the example at `spec/axn/core/validations/recursive_of_spec.rb:1506` (keeping it in place, renaming it) with:

```ruby
    it "states the tolerance pair on the declaration and writes it into neither the map bag nor an axis" do
      action = build_axn do
        expects :f, type: Hash, of: { values: { klass: Integer } }, optional: true
      end
      validations = action.internal_field_configs.first.validations

      expect(validations).to include(allow_blank: true, allow_nil: false)
      expect(validations[:of]).to eq(container: Hash, shaped_keys: [], values: { klass: Integer })
      expect(validations[:of][:values]).not_to include(:allow_blank, :allow_nil)
    end
```

- [ ] **Step 7: Update the two confirmation expectations and the comment above them**

In `spec/axn/core/validations/confirmation_spec.rb`, the block at `:118-136`. The companion no longer inherits the base's tolerance, so a TYPED tolerant base reports through its inherited type — which is already what the strictly-typed base two examples above expects.

Change the comment above the hash from its current wording to:

```ruby
    # Requiredness is the companion's own `presence:`, not a side effect of the inherited `type:` — so a base
    # whose type accepts nil (or declares none at all) enforces its confirmation exactly as a strict one does.
    # WHICH clause reports it depends on whether there is a type to report through. The companion inherits the
    # base's `type:` but not the base's tolerance (a field's tolerance is recorded on its declaration, not
    # inside its type bag), so an inherited nil-rejecting type reports the omission itself and
    # `_apply_nil_skip_to_non_type_validators!` relaxes the companion's `presence:` so the type error stands
    # alone. An untyped base has no type to inherit, so its `presence:` reports.
```

Then split the shared example so each case states its own expected clause:

```ruby
    {
      # `proc`, not `->`: `build_axn` class_evals the block, which yields the class to it.
      "an untyped base" => [proc { expects :password, confirmation: true }, "Password confirmation can't be blank"],
      "an allow_nil: base" => [proc { expects :password, type: String, allow_nil: true, confirmation: true },
                               "Password confirmation is not a String"],
      "an optional: base" => [proc { expects :password, type: String, optional: true, confirmation: true },
                              "Password confirmation is not a String"],
    }.each do |label, (declaration, expected_clause)|
      context "with #{label}" do
        let(:klass) { build_axn(&declaration) }

        it "still requires the companion once the base is present" do
          result = klass.call(password: "s3cret")
          expect(result).not_to be_ok
          expect(result.exception.message).to include(expected_clause)
        end

        it "still compares the pair" do
          expect(klass.call(password: "s3cret", password_confirmation: "nope")).not_to be_ok
          expect(klass.call(password: "s3cret", password_confirmation: "s3cret")).to be_ok
        end
      end
    end
```

- [ ] **Step 8: Correct the two stale comments in `contract.rb`**

At `lib/axn/core/contract.rb:1818-1830`, `_confirmation_companion_configs`' `type:` bullet currently says the inherited tolerance "is inert on the companion" and "still has to travel with `type:`, since the two live in one bag and copying one without the other isn't an option". Both clauses are now false — the tolerance is not in the bag, and it is not inert (it selects which clause reports). Replace that bullet's tolerance sentences with:

```ruby
        #     `type:` (which carries the parsed `coerce:` flag — `_expand_coerce_sugar!` folds the option into
        #     the type bag, so there is no separate key left to copy) keeps the emitted schema and the runtime
        #     agreeing about what the companion may be, and keeps a coerced pair comparable: a form post of
        #     `count: "5", count_confirmation: "5"` against `coerce: Integer` compares 5 to "5" and reports a
        #     mismatch the caller cannot act on unless the companion coerces too. The base's TOLERANCE is
        #     deliberately not inherited with it: a field's tolerance is recorded on its own declaration, not
        #     inside its type bag, and a companion that tolerated what the base tolerates would accept the
        #     omission the companion exists to reject. So a tolerant typed base reports its missing companion
        #     through the inherited type, exactly as a strict one does.
```

At `lib/axn/core/contract.rb:2289-2308`, `_tolerance_exempt_validator?`'s comment says the exempt entry "takes NO tolerance from the declaration-level push-down". Reword the opening sentence to describe the override:

```ruby
        # Whether a validator entry must be held OUT of the declaration's `optional:`/`allow_blank:`/
        # `allow_nil:` tolerance. Exactly one is. The pair is stated on the declaration, so `validates` applies
        # it to every validator; an exempt entry is given an explicit `allow_blank: false, allow_nil: false`,
        # which overrides the declaration tier per key exactly as ActiveModel's own merge order does.
```

Leave the rest of that comment (the ConfirmationValidator measurement, and the note that `_apply_nil_skip_to_non_type_validators!` does not check this predicate) as it stands — both are still true.

- [ ] **Step 9: Run the full suite green**

Run: `bundle exec rspec 2>&1 | tail -8`

Expected: 0 failures.

- [ ] **Step 10: Commit**

```bash
git add lib/axn/core/contract.rb spec/axn/core/validations/of_bag_value_validators_spec.rb \
        spec/axn/core/validations/recursive_of_spec.rb spec/axn/core/validations/confirmation_spec.rb
git commit -m "PRO-3225: record a field's tolerance on its declaration, not in every entry"
```

---

### Task 2: Admit `optional:` in a bag, canonicalized to the pair

**Files:**
- Modify: `lib/axn/core/contract.rb:1236-1245` (`OF_OPTION_KEYS` and the comment above it), `:1252` (`MAP_OF_OPTION_KEYS`)
- Modify: `lib/axn/core/contract.rb:2508-2517` (`_check_inner_contract_bag!` — add the canonicalization first)
- Test: `spec/axn/core/validations/option_bag_keys_spec.rb`

**Interfaces:**
- Consumes: nothing from Task 1 beyond the bag being author-only.
- Produces: `_canonicalize_bag_tolerance!(bag)` — mutates `bag`, turning a truthy `optional:` into `allow_blank: true` and deleting the `optional:` key. Idempotent. Every downstream reader (Tasks 4–7) therefore sees only `allow_nil:`/`allow_blank:`, never three keys.

- [ ] **Step 1: Write the failing test**

Add to `spec/axn/core/validations/option_bag_keys_spec.rb`:

```ruby
  # `optional:` is how a NAMED position spells its tolerance — a shape member takes it today, alongside
  # `allow_nil:`/`allow_blank:`, with the granularity those names imply. A bag describes an UNNAMED position,
  # so it takes the same three, and the sugar is canonicalized into the pair at declaration exactly as
  # `_parse_field_configs` canonicalizes a field's (`allow_blank ||= optional`) — nothing downstream reads
  # three keys where the field reads two.
  describe "a bag's tolerance vocabulary" do
    it "canonicalizes optional: into allow_blank: at an element position" do
      action = build_axn { expects :f, type: Array, of: { klass: String, optional: true } }
      bag = action.internal_field_configs.first.validations[:of]

      expect(bag).to include(allow_blank: true)
      expect(bag).not_to include(:optional)
    end

    it "canonicalizes optional: at a map axis" do
      action = build_axn { expects :f, type: Hash, of: { values: { klass: String, optional: true } } }
      axis = action.internal_field_configs.first.validations[:of][:values]

      expect(axis).to include(allow_blank: true)
      expect(axis).not_to include(:optional)
    end

    it "canonicalizes optional: inside a nested bag" do
      action = build_axn { expects :f, type: Array, of: { klass: Array, of: { klass: String, optional: true } } }
      inner = action.internal_field_configs.first.validations[:of][:of]

      expect(inner).to include(allow_blank: true)
      expect(inner).not_to include(:optional)
    end

    it "leaves an author-written allow_nil: alone rather than widening it to blank" do
      action = build_axn { expects :f, type: Array, of: { klass: String, allow_nil: true } }
      bag = action.internal_field_configs.first.validations[:of]

      expect(bag).to include(allow_nil: true)
      expect(bag).not_to include(:allow_blank)
    end

    it "still refuses a bag that constrains nothing but its own tolerance" do
      expect { build_axn { expects :f, type: Array, of: { optional: true } } }
        .to raise_error(ArgumentError, /of: must constrain something/)
    end
  end
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `bundle exec rspec spec/axn/core/validations/option_bag_keys_spec.rb -e "a bag's tolerance vocabulary"`

Expected: FAIL with `ArgumentError: of: does not support optional: (supported: klass:, of:, shape:, message:, …)` — `optional:` is currently refused as an unknown key at every bag position.

- [ ] **Step 3: Add `optional:` to both whitelists**

In `lib/axn/core/contract.rb`, add the key to the grammar half of each set and record why in the comment above `OF_OPTION_KEYS`. Replace the paragraph beginning "`on:` and `strict:` are admitted here" with:

```ruby
        # `on:`, `except_on:` and `strict:` are admitted here and refused by the bag-level twins of the field's
        # own scans (`_reject_inner_contract_context_scope!`, `_reject_inner_contract_except_on!`,
        # `_reject_inner_contract_strict!`) — the ones that reach a bag at every position — which name the
        # actual problem (axn has no validation contexts, and no strict-raising mode) instead of reporting the
        # key as unknown.
        #
        # `allow_nil:`/`allow_blank:`/`optional:` are the position's TOLERANCE: the same three spellings a
        # named shape member takes, meaning the same three things about the value at this position.
        # `_canonicalize_bag_tolerance!` folds the sugar into the pair before any of them is read, so the pair
        # is the only form stored. Whether `if:`/`unless:` then do anything depends on the position, which is
        # `AXIS_INERT_OPTION_KEYS` below.
```

and the two constants:

```ruby
        OF_OPTION_KEYS = (Set.new(%i[klass of shape message optional]) | POSITIONAL_VALIDATOR_KEYS |
                          Axn::Validation::Base.shared_validation_option_keys).freeze
```

```ruby
        MAP_OF_OPTION_KEYS = (Set.new(%i[keys values]) | Axn::Validation::Base.shared_validation_option_keys).freeze
```

`MAP_OF_OPTION_KEYS` is deliberately unchanged: the map's own `of:` bag holds only the two axes, and a tolerance there would be a field-level fact wearing the map's key. The tolerance lives on each AXIS bag, which is an `OF_OPTION_KEYS` position.

- [ ] **Step 4: Write the canonicalization and call it first**

Add the method beside `_check_inner_contract_bag!` in `lib/axn/core/contract.rb`:

```ruby
        # `optional:` is the sugar a NAMED position takes, canonicalized here into the pair the runtime and the
        # emitter read — the same fold `_parse_field_configs` performs for a field (`allow_blank ||= optional`),
        # through the same meaning: "optional" is blank-tolerance, which subsumes nil.
        #
        # Runs ahead of every other check on the bag, so none of them ever judges a bag carrying two spellings
        # of one fact. Idempotent, which the walk requires: this seam runs over a shape member's bag twice, and
        # the second pass finds the key already folded away.
        #
        # A FALSY `optional:` is dropped rather than written as `allow_blank: false`. It is the absence of
        # tolerance, which is the default, and writing the negative would make an explicit `allow_nil: true`
        # beside it read as a contradiction the author did not declare.
        def _canonicalize_bag_tolerance!(bag)
          return unless Internal::ShapeGraph.carries_key?(bag, :optional)

          optional = bag.delete(:optional)
          bag[:allow_blank] = true if optional
        end
```

and call it as the first line of `_check_inner_contract_bag!`:

```ruby
        def _check_inner_contract_bag!(bag, fields)
          _canonicalize_bag_tolerance!(bag)
          _canonicalize_positional_validator_options!(bag, fields)
          _reject_unknown_of_keys!(bag, OF_OPTION_KEYS)
          _reject_unconstraining_of_bag!(bag)
          _reject_unsupported_of_klass!(bag)
          _reject_inner_contract_context_scope!(bag, fields)
          _reject_inner_contract_strict!(bag, fields)
          _reject_unusable_of_message!(bag, fields)
          _reject_positional_bag_validators!(bag, fields)
        end
```

`_check_inner_contract_bag!` is reached from `_canonical_array_of!` (the element bag), from `_canonicalize_map_axes!` (both axes), and from the declaration walk's `_canonicalize_inner_contract!` (every nested rung) — so one call covers all four positions.

- [ ] **Step 5: Run the new examples**

Run: `bundle exec rspec spec/axn/core/validations/option_bag_keys_spec.rb -e "a bag's tolerance vocabulary"`

Expected: PASS, all five.

- [ ] **Step 6: Run the suite**

Run: `bundle exec rspec 2>&1 | tail -8`

Expected: 0 failures. Nothing reads the tolerance positionally yet, so this task changes only the grammar.

- [ ] **Step 7: Commit**

```bash
git add lib/axn/core/contract.rb spec/axn/core/validations/option_bag_keys_spec.rb
git commit -m "PRO-3225: a bag takes optional:, canonicalized into the tolerance pair"
```

---

### Task 3: Lift the axis refusal of the tolerance pair

**Files:**
- Modify: `lib/axn/core/contract.rb:2727-2742` (`AXIS_INERT_OPTION_KEYS` and its comment), `:2746-2756` (`_reject_inert_axis_options!`'s message)
- Test: `spec/axn/core/validations/recursive_of_spec.rb`

**Interfaces:**
- Produces: `AXIS_INERT_OPTION_KEYS` narrows to `[:if, :unless, :except_on]`. An axis bag may now carry `allow_nil:`/`allow_blank:`/`optional:`.

- [ ] **Step 1: Write the failing test**

Add to `spec/axn/core/validations/recursive_of_spec.rb`, inside the describe that covers axis options:

```ruby
    # An axis bag is never handed to ActiveModel, which is why a GATE written there is refused: nothing reads
    # it. Tolerance is different — `OfValidator` reads the position's tolerance itself, at every position — so
    # an axis states it exactly as an element bag does.
    it "accepts the tolerance pair on an axis" do
      expect { build_axn { expects :f, type: Hash, of: { values: { klass: String, allow_nil: true } } } }
        .not_to raise_error
    end

    it "accepts optional: on an axis" do
      expect { build_axn { expects :f, type: Hash, of: { keys: { klass: Symbol, optional: true } } } }
        .not_to raise_error
    end

    it "still refuses a gate on an axis, since nothing there reads one" do
      expect { build_axn { expects :f, type: Hash, of: { values: { klass: String, if: :flag } } } }
        .to raise_error(ArgumentError, /of: values: does not support if:/)
    end
```

- [ ] **Step 2: Run it to confirm the first two fail**

Run: `bundle exec rspec spec/axn/core/validations/recursive_of_spec.rb -e "on an axis"`

Expected: the two acceptance examples FAIL with `of: values: does not support allow_nil:` / `does not support optional:`; the gate example PASSES already.

- [ ] **Step 3: Narrow the constant and rewrite its comment**

In `lib/axn/core/contract.rb`, replace the comment above `AXIS_INERT_OPTION_KEYS` and the constant with:

```ruby
        # The shared ActiveModel options an AXIS bag cannot honour, and so may not carry. Every OTHER position a
        # bag sits at is an ActiveModel validator entry, where AM reads these and they are live: the field's own
        # `of:` bag is an entry on the field, and a nested ELEMENT bag becomes one on the next level's
        # `ContainerContents` validator, since `OfValidator#inner_contract_validations` hands it over verbatim
        # under `:of`. An axis bag is never handed to AM at all — `OfValidator#axis_contract` reads it directly
        # — so a GATE written there is dropped rather than applied, and the axis constrains less than its
        # declaration says. Measured: `of: { klass: Array, of: { klass: Integer, if: -> { false } } }` lets
        # `[["x"]]` through, while `of: { values: { klass: Integer, if: -> { false } } }` still rejects
        # `{a: "x"}`.
        #
        # The TOLERANCE keys are not here, because they are not read by ActiveModel at any position: they state
        # what the position itself admits, and `OfValidator` resolves them off the bag directly through
        # `position_contract`. So an axis states its tolerance exactly as an element bag does.
        #
        # `on:` and `strict:` are left out because `_check_inner_contract_bag!` has already refused each a step
        # earlier, naming the real problem — axn has no validation contexts, and no strict-raising mode — both
        # of which are true at every position rather than at this one. Listing either here would offer "drop it,
        # the axis reads nothing" where the messages above name what axn does not have.
        AXIS_INERT_OPTION_KEYS = (Axn::Validation::Base.shared_validation_option_keys -
                                  %i[on strict allow_nil allow_blank]).freeze
```

Two things to get right here, both of which the plan originally muddled:

- **Derive the set, never list it.** The subtraction keeps it in step with ActiveModel's own `_validates_default_keys`; a literal `%i[if unless]` would silently stop covering a key AM adds.
- **`except_on:` stays IN this set for now**, which is why the comment above names only `on:` and `strict:` as the ones refused elsewhere. Task 7 is what gives `except_on:` a message of its own and subtracts it here. Do not pre-empt that, and do not write a comment claiming `except_on:` is already refused a step earlier — it is not, until Task 7.

The value today is therefore `[:if, :unless, :except_on]`.

- [ ] **Step 4: Run the new examples**

Run: `bundle exec rspec spec/axn/core/validations/recursive_of_spec.rb -e "on an axis"`

Expected: PASS, all three.

- [ ] **Step 5: Run the suite**

Run: `bundle exec rspec 2>&1 | tail -8`

Expected: 0 failures.

- [ ] **Step 6: Commit**

```bash
git add lib/axn/core/contract.rb spec/axn/core/validations/recursive_of_spec.rb
git commit -m "PRO-3225: an axis may state its own tolerance"
```

---

### Task 4: `OfValidator` honours the position's tolerance

**Files:**
- Modify: `lib/axn/core/validation/validators/of_validator.rb` — `PositionContract`, `position_contract`, `bare_type_contract`, `validate_position`, `validate_each`
- Modify: `lib/axn/core/validation/base.rb` — add `tolerance_options`
- Test: `spec/axn/core/validations/of_bag_value_validators_spec.rb`

**Interfaces:**
- Consumes: `_canonicalize_bag_tolerance!` from Task 2 (so only `allow_nil:`/`allow_blank:` reach here).
- Produces:
  - `Axn::Validation::Base.tolerance_options(bag)` → `Hash` — the tolerance pair a bag carries, `{}` when it carries neither. THE single definition, also used by Tasks 6 and 7.
  - `PositionContract#tolerates?(value)` → `Boolean`.

- [ ] **Step 1: Write the failing test**

Add to `spec/axn/core/validations/of_bag_value_validators_spec.rb`:

```ruby
  # A bag's tolerance governs the POSITION it describes: it stands that position's own checks down for a
  # value it admits, which is what `optional:` does at a named shape member. Without it there is no spelling
  # for "a nil element, alongside another validator": widening the class (`klass: [String, NilClass]`) widens
  # only the type check, and ActiveModel runs `format:`/`length:`/`inclusion:`/`numericality:` on a nil
  # regardless of what the type permits.
  describe "positional tolerance" do
    describe "an Array's element position" do
      it "admits a nil element beside another validator under allow_nil:" do
        action = build_axn do
          expects :codes, type: Array, of: { klass: String, format: { with: /\A[A-Z]{2}\z/ }, allow_nil: true }
        end

        expect(action.call(codes: ["AB", nil])).to be_ok
        expect(action.call(codes: ["AB"])).to be_ok
        expect(action.call(codes: ["ab"])).not_to be_ok
        expect(action.call(codes: [1])).not_to be_ok
      end

      it "admits a blank element only under allow_blank:" do
        nil_only = build_axn do
          expects :codes, type: Array, of: { klass: String, format: { with: /\A[A-Z]{2}\z/ }, allow_nil: true }
        end
        blank_too = build_axn do
          expects :codes, type: Array, of: { klass: String, format: { with: /\A[A-Z]{2}\z/ }, allow_blank: true }
        end

        expect(nil_only.call(codes: ["AB", ""])).not_to be_ok
        expect(blank_too.call(codes: ["AB", ""])).to be_ok
        expect(blank_too.call(codes: ["AB", nil])).to be_ok
      end

      it "stands the position's own type check down too, not only its value validators" do
        action = build_axn { expects :codes, type: Array, of: { klass: String, allow_nil: true } }

        expect(action.call(codes: ["AB", nil])).to be_ok
        expect(action.call(codes: [1])).not_to be_ok
      end

      it "stands the position's contents descent down as well" do
        action = build_axn do
          expects :rows, type: Array, of: { klass: Hash, allow_nil: true, shape: { members: [] } }
        end

        expect(action.call(rows: [{}, nil])).to be_ok
      end

      it "leaves a bag with no tolerance rejecting a nil element" do
        action = build_axn { expects :codes, type: Array, of: { klass: String } }

        expect(action.call(codes: ["AB", nil])).not_to be_ok
      end
    end

    describe "a map's axes" do
      it "admits a nil value under the values axis's own tolerance" do
        action = build_axn { expects :m, type: Hash, of: { values: { klass: String, allow_nil: true } } }

        expect(action.call(m: { a: "x", b: nil })).to be_ok
        expect(action.call(m: { a: 1 })).not_to be_ok
      end

      it "keeps the two axes independent" do
        action = build_axn do
          expects :m, type: Hash, of: { keys: { klass: Symbol }, values: { klass: String, allow_nil: true } }
        end

        expect(action.call(m: { a: nil })).to be_ok
        expect(action.call(m: { "a" => nil })).not_to be_ok
      end
    end

    describe "a nested bag" do
      it "tolerates at the rung that declares it, not at its parent" do
        action = build_axn do
          expects :f, type: Array, of: { klass: Array, of: { klass: String, allow_nil: true } }
        end

        expect(action.call(f: [["AB", nil]])).to be_ok
        expect(action.call(f: [nil])).not_to be_ok
      end
    end
  end
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `bundle exec rspec spec/axn/core/validations/of_bag_value_validators_spec.rb -e "positional tolerance"`

Expected: FAIL. The first example reports `codes element at index 1 is invalid` — `format:` runs on the nil.

- [ ] **Step 3: Add the shared tolerance read to `Validation::Base`**

In `lib/axn/core/validation/base.rb`, beside `shared_validation_options`:

```ruby
      # The TOLERANCE a bag states about its own position — the two keys that mean "a value this position
      # admits without asking anything else of it". THE single definition, shared by the runtime that stands a
      # position down (`OfValidator#position_contract`), the declaration guards that judge a bag's validators,
      # and the emitter that projects the position — so none of the three can disagree about what a bag
      # tolerates.
      #
      # A subset of the shared options rather than all of them: the rest (`if:`/`unless:`/`on:`/`strict:`/
      # `except_on:`) are read by ActiveModel where a bag is an entry and by nothing where it is an axis, and
      # they say nothing about the position's value. Read non-dispatchingly, since a bag reaches this at
      # class-definition time.
      def self.tolerance_options(bag)
        graph = Axn::Internal::ShapeGraph
        hash = graph.hash_or_nil(bag)
        return {} if nil.equal?(hash)

        TOLERANCE_OPTION_KEYS.each_with_object({}) do |key, out|
          out[key] = hash[key] if graph.carries_key?(hash, key)
        end
      end

      TOLERANCE_OPTION_KEYS = %i[allow_nil allow_blank].freeze
```

Place `TOLERANCE_OPTION_KEYS` above the method so the constant is defined before first use at load time.

- [ ] **Step 4: Teach `PositionContract` the tolerance**

In `lib/axn/core/validation/validators/of_validator.rb`:

```ruby
      PositionContract = Data.define(:klasses, :message, :contents, :validator_class, :contents_node, :tolerance) do
        # Whether this position admits the value without asking anything else of it — the positional reading of
        # `allow_nil:`/`allow_blank:`, which is what those keys mean at a named shape member too.
        #
        # Blankness is asked through `NativeMethods.blank_literal?`, the seam that answers "would ActiveModel's
        # `allow_blank:` skip this?" without dispatching to the value. That matters more here than at a field:
        # the value is an ELEMENT of the caller's container, so a String or Array subclass overriding `blank?`
        # would otherwise decide whether its own position gets validated. The seam errs toward NOT blank, which
        # is the safe direction — a missed tolerance validates a value ActiveModel would have skipped, while a
        # false one waves through a value the position constrains.
        #
        # Nil is asked by identity as well, because `allow_nil:` alone tolerates nil while `allow_blank:`
        # subsumes it — the same two-key reading `nil_tolerant_validation?` applies at a field.
        def tolerates?(value)
          return true if nil.equal?(value) && (tolerance[:allow_nil] || tolerance[:allow_blank])

          !!tolerance[:allow_blank] && Axn::Internal::NativeMethods.blank_literal?(value)
        end
      end
      private_constant :PositionContract
```

Add `require "axn/internal/native_methods"` to the file's requires if it is not already there (it currently requires `cycle_guard` and `shape_graph`).

Then thread the tolerance through both constructors:

```ruby
      def position_contract(declared)
        bag = Axn::Internal::ShapeGraph.hash_or_nil(declared)
        return bare_type_contract(declared) if nil.equal?(bag)

        contents = inner_contract_validations(bag)
        PositionContract.new(
          klasses: Array(bag[:klass]),
          message: bag[:message],
          contents:,
          validator_class: contents && Axn::Validation::ContainerContents.validator_class_for(
            field: :__axn_contents__, validations: contents,
          ),
          contents_node: contents && (bag[:of] || bag[:shape]),
          tolerance: Axn::Validation::Base.tolerance_options(bag),
        )
      end

      def bare_type_contract(declared)
        PositionContract.new(klasses: Array(declared), message: nil, contents: nil, validator_class: nil,
                             contents_node: nil, tolerance: {})
      end
```

- [ ] **Step 5: Stand the position down in `validate_position`, and drop the field-level nil-skip**

```ruby
      def validate_each(record, attribute, value)
        options[:container] == ::Hash ? validate_entries(record, attribute, value) : validate_elements(record, attribute, value)
      end
```

The removed line was `return if value.nil? && (options[:allow_nil] || options[:allow_blank])`. Those options are the ELEMENT position's tolerance now, and a nil-tolerant position must not excuse a nil FIELD. It was not load-bearing in its own right either: both branches `return unless value.is_a?(…)` and no-op on a nil field regardless.

```ruby
      # One position of one value: its own type check, then whatever its inner contract says about what is
      # inside it. A position that TOLERATES the value asks nothing of it — the same standing-down `optional:`
      # performs at a named shape member, and the only thing in ActiveModel's vocabulary that means "skip this
      # value's other checks". Asked before the type check, because tolerance is what makes a nil legal HERE
      # rather than a type the position happens also to admit.
      #
      # The type verdict does NOT gate the contents check — a wrong-typed element still reports what could not
      # be read out of it, which is what an author fixing a payload needs.
      #
      # A custom `message:` replaces the type description but the POSITION is always reported — an ordinal is
      # the only locating info an unnamed position has. Built only on the failure path.
      def validate_position(record, attribute, contract, value, position)
        return if contract.tolerates?(value)

        record.errors.add(attribute, "#{position} #{position_mismatch(contract)}") unless matches_axis?(value, contract.klasses)
        return if nil.equal?(contract.contents)

        add_contents_errors(record, attribute, contract, value, "#{position}: ")
      end
```

Also update `inner_contract_validations`' comment, whose last paragraph currently says a bag's tolerance is "a separate question, and not one this method may answer by accident". Replace that paragraph with:

```ruby
      # The shared ActiveModel options come out through `validator_entries`, which is what "these are not
      # validators" already means everywhere else. The position's TOLERANCE leaves with them, and deliberately
      # does not travel into the forwarded contents: `validate_position` stands the whole position down for a
      # tolerated value in one place, rather than re-expressing the same fact as a flag on every forwarded
      # entry.
```

- [ ] **Step 6: Run the new examples**

Run: `bundle exec rspec spec/axn/core/validations/of_bag_value_validators_spec.rb -e "positional tolerance"`

Expected: PASS, all nine.

- [ ] **Step 7: Run the suite**

Run: `bundle exec rspec 2>&1 | tail -20`

Expected: 0 failures. If the schema wire audit (`spec/**/schema_wire_audit_spec.rb`) fails here, that is Task 5's work arriving early — note the failure and continue to Task 5 rather than patching the emitter inside this task.

- [ ] **Step 8: Commit**

```bash
git add lib/axn/core/validation/base.rb lib/axn/core/validation/validators/of_validator.rb \
        spec/axn/core/validations/of_bag_value_validators_spec.rb
git commit -m "PRO-3225: a bag's tolerance stands its own position down"
```

---

### Task 5: The emitter projects a tolerant position

Lands immediately after Task 4 so the runtime and the document never disagree across a commit boundary.

**Files:**
- Modify: `lib/axn/internal/reflection/schema.rb:2715-2725` (`bag_value_constraints`)
- Test: `spec/axn/internal/reflection/schema_spec.rb`

**Interfaces:**
- Consumes: `Axn::Validation::Base.tolerance_options` from Task 4.
- Produces: no new method. The bag's tolerance now rides in the validations hash the existing emitters read, so `bag_nullable?`, `declared_size_minimum` and `apply_value_constraints!` resolve it through `shared_validation_options` exactly as they do for a field.

- [ ] **Step 1: Write the failing test**

Add to `spec/axn/internal/reflection/schema_spec.rb`:

```ruby
  # A position's tolerance is projected exactly as a FIELD's is, by the same helpers — which is the
  # requirement, not a convenience: the field-level behaviour is precise and non-obvious (an `allow_blank`
  # DROPS a length floor because the empty value passes, while an `allow_nil` KEEPS it because the empty value
  # still fails), and a second implementation would drift from it.
  describe "a tolerant of: bag's projection" do
    def items_for(&declaration)
      klass = build_axn(&declaration)
      described_class.build_input(klass.internal_field_configs, klass.subfield_configs)[:properties][:f][:items]
    end

    it "adds a null branch for a nil-tolerant element position" do
      expect(items_for { expects :f, type: Array, of: { klass: String, allow_nil: true } })
        .to include(type: %w[string null])
    end

    it "keeps a length floor under allow_nil:, which does not admit the empty value" do
      expect(items_for { expects :f, type: Array, of: { klass: String, length: { minimum: 2 }, allow_nil: true } })
        .to include(type: %w[string null], minLength: 2)
    end

    it "drops the length floor under allow_blank:, which does admit the empty value" do
      node = items_for { expects :f, type: Array, of: { klass: String, length: { minimum: 2 }, allow_blank: true } }

      expect(node).to include(type: %w[string null])
      expect(node).not_to include(:minLength)
    end

    it "leaves an untolerant position unchanged" do
      expect(items_for { expects :f, type: Array, of: { klass: String, length: { minimum: 2 } } })
        .to eq(type: "string", minLength: 2)
    end

    it "projects a tolerant values axis through additionalProperties" do
      klass = build_axn { expects :f, type: Hash, of: { values: { klass: String, allow_nil: true } } }
      node = described_class.build_input(klass.internal_field_configs, klass.subfield_configs)[:properties][:f]

      expect(node[:additionalProperties]).to include(type: %w[string null])
    end
  end
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `bundle exec rspec spec/axn/internal/reflection/schema_spec.rb -e "a tolerant of: bag's projection"`

Expected: FAIL. `bag_value_constraints` strips the tolerance through `validator_entries`, so the first example emits `type: "string"` with no null branch.

- [ ] **Step 3: Retain the tolerance in `bag_value_constraints`**

```ruby
        # A bag's VALUE constraints as a validations hash the field-level emitters can read: its validator
        # entries, minus what describes the position rather than constrains it.
        #
        # The position's TOLERANCE is kept, and it is the reason this is a merge rather than a slice: it rides
        # in as the declaration tier every emitter already resolves against (`shared_validation_options`), so
        # nullability, the emptiness floor and the value keywords all read it here exactly as they read a
        # field's. That is what keeps `of: { klass: String, length: { minimum: 2 }, allow_blank: true }`
        # emitting the same shape as the field it mirrors — no floor, plus a null branch — without a second
        # implementation of the rule.
        #
        # The other shared options do NOT come through. A gate is reduced away by `effective_validations` on
        # output and means nothing to the document on input, and the context/strict options are refused at
        # declaration.
        def bag_value_constraints(bag, for_output:)
          constraints = Axn::Validation::Base.validator_entries(bag)
                                             .except(*Axn::Internal::ShapeGraph::POSITION_DESCRIPTION_KEYS,
                                                     *Axn::Internal::ShapeGraph::INNER_CONTRACT_EDGES)
          # On OUTPUT a self-gated entry promises nothing — the action may successfully expose a value the entry
          # would have rejected — so it is reduced away exactly as `effective_validations` reduces a named
          # field's. `emitted_contents_edge` already does this for the bag's `of:`/`shape:` edges; this is the
          # same reduction for its validators.
          effective_validations(constraints, for_output:)
            .merge(Axn::Validation::Base.tolerance_options(bag))
        end
```

The merge is applied AFTER `effective_validations` so the reduction cannot drop the tolerance tier it needs to see.

- [ ] **Step 4: Run the new examples**

Run: `bundle exec rspec spec/axn/internal/reflection/schema_spec.rb -e "a tolerant of: bag's projection"`

Expected: PASS, all five.

- [ ] **Step 5: Run the schema wire audit and the full suite**

Run: `bundle exec rspec spec/**/schema_wire_audit_spec.rb && bundle exec rspec 2>&1 | tail -8`

Expected: 0 failures in both. The wire audit validates the emitted schema against a real JSON Schema validator, so it is the gate on runtime/document agreement for the new tolerant nodes.

- [ ] **Step 6: Commit**

```bash
git add lib/axn/internal/reflection/schema.rb spec/axn/internal/reflection/schema_spec.rb
git commit -m "PRO-3225: project a tolerant bag position through the field's own emitters"
```

---

### Task 6: Refuse tolerance beside an explicit `presence:` at a bag position

**Files:**
- Modify: `lib/axn/core/contract.rb:5232-5244` (extract the inline raise)
- Modify: `lib/axn/core/contract.rb:2880-2900` (`_reject_positional_bag_validators!` — call it, and pass the bag's real tolerance to the two guards)
- Test: `spec/axn/core/validations/of_bag_value_validators_spec.rb`

**Interfaces:**
- Consumes: `Axn::Validation::Base.tolerance_options` from Task 4.
- Produces: `_reject_tolerant_presence!(validations, where:, tolerance:)` — raises `ArgumentError` when the tolerance is truthy and `validations[:presence]` is truthy. Called from both the field path and the bag path.

- [ ] **Step 1: Write the failing test**

Add to `spec/axn/core/validations/of_bag_value_validators_spec.rb`, inside the `positional tolerance` describe:

```ruby
    describe "a contradiction the position cannot hold" do
      # The same rule the field carries, for the same reason: the tolerance is applied to every check at the
      # position, so the presence check could never fail. Dead machinery, refused where it is written.
      it "refuses a tolerance beside an explicit presence: at an element position" do
        expect { build_axn { expects :f, type: Array, of: { klass: String, presence: true, allow_blank: true } } }
          .to raise_error(ArgumentError, /cannot be combined with an explicit `presence:`/)
      end

      it "refuses it under the optional: spelling too" do
        expect { build_axn { expects :f, type: Array, of: { klass: String, presence: true, optional: true } } }
          .to raise_error(ArgumentError, /cannot be combined with an explicit `presence:`/)
      end

      it "refuses it at a map axis" do
        expect do
          build_axn { expects :f, type: Hash, of: { values: { klass: String, presence: true, allow_nil: true } } }
        end.to raise_error(ArgumentError, /cannot be combined with an explicit `presence:`/)
      end

      it "still accepts a presence: with no tolerance beside it" do
        expect { build_axn { expects :f, type: Array, of: { klass: String, presence: true } } }.not_to raise_error
      end

      it "still refuses the same contradiction at a field" do
        expect { build_axn { expects :f, type: String, presence: true, optional: true } }
          .to raise_error(ArgumentError, /cannot be combined with an explicit `presence:`/)
      end
    end
```

- [ ] **Step 2: Run it to confirm the first three fail**

Run: `bundle exec rspec spec/axn/core/validations/of_bag_value_validators_spec.rb -e "a contradiction the position cannot hold"`

Expected: the three bag examples FAIL (they declare cleanly); the last two PASS already.

- [ ] **Step 3: Extract the field's inline raise into a shared guard**

Add beside `_reject_positional_bag_validators!` in `lib/axn/core/contract.rb`:

```ruby
        # A truthy `presence:` under a tolerance is dead machinery: the tolerance is applied to every check at
        # the position, so the presence validator would accept exactly the values it exists to reject. Refused
        # at declaration, at a field and at every bag position, through one function — the alternative is two
        # statements of one rule that can come to disagree about which combinations are legal.
        #
        # `presence: false` is coherent and untouched: explicit suppression, the same intent as the tolerance.
        # The tolerance is passed rather than read out of `validations`, because at a field it is still a
        # declaration KWARG when this runs, and at a bag it is the bag's own pair.
        def _reject_tolerant_presence!(validations, where:, tolerance:)
          return unless tolerance[:allow_blank] || tolerance[:allow_nil]
          return unless validations[:presence]

          raise ArgumentError,
                "optional:/allow_blank:/allow_nil: on #{where} cannot be combined with an explicit " \
                "`presence:` — the tolerance is applied to every check at that position, so the presence " \
                "check could never fail. For \"may be nil, but not empty\", declare `allow_empty: false` " \
                "alongside the tolerance; otherwise declare one requiredness signal (drop the tolerance, or " \
                "drop presence:)."
        end
```

Replace the inline raise in `_parse_field_validations` with a call to it:

```ruby
          _reject_tolerant_presence!(validations, where: _declared_fields_label(fields),
                                                  tolerance: { allow_nil:, allow_blank: })
```

Placed exactly where the inline `if tolerant && validations[:presence]` block was — after `_validate_allow_empty!` and before `_reconcile_emptiness_axis!` — so the ordering the emptiness axis depends on is unchanged.

`allow_empty: false` is named in the message as the remedy, so keep that clause: it is the spelling that still works.

- [ ] **Step 4: Call it from the bag path, with the bag's own tolerance**

In `_reject_positional_bag_validators!`, replace the `tolerance: {}` arguments and their comment:

```ruby
        def _reject_positional_bag_validators!(bag, fields)
          # Nothing to judge for a bag that names only what it holds — which is every `of: Integer` — so the
          # ordinary declaration reaches neither guard and allocates nothing beyond the emptiness check.
          return unless _bag_carries_positional_validator?(bag)

          validations = _bag_as_validations(bag)
          tolerance = Axn::Validation::Base.tolerance_options(bag)

          where = "an `of:` bag on #{_declared_fields_label(fields)}"
          _reject_tolerant_presence!(validations, where:, tolerance:)
          _reject_container_position_validators!(validations, where:, nested: true)
          # The bag's own tolerance, read the way the field's is: a tolerated value PASSES, so it can rescue a
          # contract that would otherwise admit nothing, and it discounts the literals ActiveModel would skip.
          _reject_unsatisfiable_value_constraints!(validations, where:, nested: true, tolerance:)
          # Its mirror, in the same order the field path runs the pair: the unsatisfiable contract is reported
          # first, so a declaration broken both ways names the defect that rejects every call ahead of the one
          # that rejects none. Both guards run at all four positions — a validator is judged where it is
          # declared, and an INVERTED one that forbids literals no value of the position's class could be
          # enforces nothing there just as surely as it does at a field.
          _reject_vacuous_value_constraints!(validations, where:, nested: true, tolerance:)
        end
```

Also update `_bag_as_validations`' comment, whose last paragraph justifies stripping the tolerance so `nil_accepted?` cannot read it out of the bag. Replace that paragraph with:

```ruby
        # The shared ActiveModel options come out through `validator_entries`, exactly as they do for the
        # runtime's own forwarding (`OfValidator#inner_contract_validations`): they are not validators. The
        # position's TOLERANCE is handed to the guards separately, as the tier they resolve per entry — the
        # same shape the field path passes — rather than left in the hash, so a guard reads it as tolerance
        # and never as a validator.
```

- [ ] **Step 5: Run the new examples**

Run: `bundle exec rspec spec/axn/core/validations/of_bag_value_validators_spec.rb -e "a contradiction the position cannot hold"`

Expected: PASS, all five.

- [ ] **Step 6: Run the suite, watching the satisfiability specs**

Run: `bundle exec rspec 2>&1 | tail -20`

Expected: 0 failures. `spec/axn/core/validations/unsatisfiable_size_interval_spec.rb`, `unsatisfiable_size_soundness_spec.rb`, `vacuity_over_restriction_matrix_spec.rb` and `degenerate_literals_spec.rb` exercise the two guards whose tolerance argument just changed — if one fails, the bag's tolerance is standing a guard down where it should not, and the failing example names the case.

- [ ] **Step 7: Commit**

```bash
git add lib/axn/core/contract.rb spec/axn/core/validations/of_bag_value_validators_spec.rb
git commit -m "PRO-3225: judge a bag's validators against the bag's own tolerance"
```

---

### Task 7: Refuse `except_on:` at every position

**Files:**
- Modify: `lib/axn/core/validation/base.rb` (add `entry_declares_except_on?` beside `entry_declares_strict?`)
- Modify: `lib/axn/core/contract.rb` — add `_reject_validator_except_on!` beside `_reject_strict_validation!`, `_reject_inner_contract_except_on!` beside `_reject_inner_contract_strict!`, `_raise_validator_except_on!` beside `_raise_validator_context_scope!`; call the first from `_parse_field_validations` and the second from `_check_inner_contract_bag!`
- Modify: `lib/axn/core/contract.rb` `AXIS_INERT_OPTION_KEYS` (subtract `except_on` at the source, now that it has a message of its own)
- Test: `spec/axn/core/validations/strict_validation_spec.rb` (the file that already covers this class of refusal)

**Interfaces:**
- Produces: `Axn::Validation::Base.entry_declares_except_on?(entry_opts)` → `Boolean`.

- [ ] **Step 1: Write the failing test**

Add to `spec/axn/core/validations/strict_validation_spec.rb`:

```ruby
  # ActiveModel's other context option, and axn has no validation contexts at any position. It is inert in the
  # OPPOSITE direction to `on:`: `validate` installs it as `unless: -> { Array(options[:except_on]).include?(
  # validation_context) }`, and axn calls `valid?` with no context, so the exclusion excludes nothing and the
  # entry runs on every call. An option whose only effect is to look like one.
  describe "except_on:" do
    it "is refused on a field's validator entry" do
      expect { build_axn { expects :f, type: String, format: { with: /x/, except_on: :publish } } }
        .to raise_error(ArgumentError, /`except_on:`.*excludes nothing/m)
    end

    it "is refused inside an of: bag" do
      expect { build_axn { expects :f, type: Array, of: { klass: String, except_on: :publish } } }
        .to raise_error(ArgumentError, /`except_on:`.*excludes nothing/m)
    end

    it "is refused at a map axis" do
      expect { build_axn { expects :f, type: Hash, of: { values: { klass: String, except_on: :publish } } } }
        .to raise_error(ArgumentError, /`except_on:`.*excludes nothing/m)
    end

    it "is refused inside a nested bag" do
      expect do
        build_axn { expects :f, type: Array, of: { klass: Array, of: { klass: String, except_on: :publish } } }
      end.to raise_error(ArgumentError, /`except_on:`.*excludes nothing/m)
    end

    it "leaves a supported gate alone" do
      expect { build_axn { expects :f, type: String, format: { with: /x/, if: :flag } } }.not_to raise_error
    end
  end
```

- [ ] **Step 2: Run it to confirm four of the five fail**

Run: `bundle exec rspec spec/axn/core/validations/strict_validation_spec.rb -e "except_on:"`

Expected: the field, element-bag and nested-bag examples FAIL (they declare cleanly). The axis example may pass with the WRONG message (the inert-axis refusal) — after Step 3 it must match the new one.

- [ ] **Step 3: Add the predicate**

In `lib/axn/core/validation/base.rb`, directly after `entry_declares_strict?`:

```ruby
      # Whether a validator ENTRY carries ActiveModel's `except_on:`, which names a validation context axn has
      # not got. THE definition behind the declaration guards that refuse one at a field entry
      # (`_reject_validator_except_on!`) and at every bag position (`_reject_inner_contract_except_on!`) — their
      # only consumers, so no judgment downstream ever meets one.
      #
      # Only the key's presence is asked, for the reason `on:` asks only that: `validate` installs the gate on
      # the key, whatever the value. The direction is the opposite of `on:`'s, though, and that is why it is a
      # separate question rather than a widening of `entry_context_scoped?`. AM installs it as
      # `unless: -> { Array(options[:except_on]).include?(validation_context) }`, and axn validates with no
      # context, so `[:publish].include?(nil)` is false and the entry runs on EVERY call — the exclusion
      # excludes nothing, where an `on:` makes the check run on nothing. Two inert options, two accounts of why.
      def self.entry_declares_except_on?(entry_opts) = entry_carries_option?(entry_opts, :except_on)
```

- [ ] **Step 4: Add the two refusals and the message**

In `lib/axn/core/contract.rb`, beside `_reject_strict_validation!`:

```ruby
        def _reject_validator_except_on!(validations, where:)
          offenders = Axn::Validation::Base.validator_entries(validations).filter_map do |key, entry|
            "#{key}:" if Axn::Validation::Base.entry_declares_except_on?(entry)
          end
          return if offenders.empty?

          _raise_validator_except_on!(offenders.join(" / "), where)
        end
```

beside `_reject_inner_contract_strict!`:

```ruby
        # The bag-level twin of the scan above, for the reason that pair exists on the context-scope and strict
        # sides: the field's own `of:` IS an entry, so the scan sees it, but a bag nested inside one and a map's
        # axis are reached only by the declaration walk. Asked of the bag directly here, through the same
        # predicate the scan uses, so one rule decides it at every position.
        def _reject_inner_contract_except_on!(bag, fields)
          return unless Axn::Validation::Base.entry_declares_except_on?(bag)

          _raise_validator_except_on!("an `of:` bag", _declared_fields_label(fields))
        end
```

and beside `_raise_validator_context_scope!`:

```ruby
        def _raise_validator_except_on!(inside, where)
          raise ArgumentError,
                "`except_on:` inside #{inside} on #{where} names an ActiveModel validation context to skip, " \
                "and axn validates with no context — so the exclusion excludes nothing and the check runs on " \
                "every call, which is what it would do with the option absent. Axn has no validation " \
                "contexts: drop `except_on:`, or gate the check with `if:`/`unless:`, which axn does support."
        end
```

- [ ] **Step 5: Wire both in, and subtract the key from the axis set**

In `_parse_field_validations`, beside the strict refusal:

```ruby
          _reject_validator_context_scope!(validations, where: fields.map(&:to_s).inspect)
          _reject_validator_except_on!(validations, where: fields.map(&:to_s).inspect)
          _reject_strict_validation!(validations, where: fields.map(&:to_s).inspect)
```

In `_check_inner_contract_bag!`, beside the bag's strict refusal:

```ruby
          _reject_inner_contract_context_scope!(bag, fields)
          _reject_inner_contract_except_on!(bag, fields)
          _reject_inner_contract_strict!(bag, fields)
```

And narrow the axis set at the source, since `except_on:` now has a message that names the real problem:

```ruby
        AXIS_INERT_OPTION_KEYS = (Axn::Validation::Base.shared_validation_option_keys -
                                  %i[on except_on strict allow_nil allow_blank]).freeze
```

Add to that constant's comment, in the paragraph listing what is left out:

```ruby
        # `on:`, `except_on:` and `strict:` are left out because `_check_inner_contract_bag!` has already
        # refused each a step earlier, naming the real problem — axn has no validation contexts, and no
        # strict-raising mode — both of which are true at every position rather than at this one.
```

- [ ] **Step 6: Run the new examples**

Run: `bundle exec rspec spec/axn/core/validations/strict_validation_spec.rb -e "except_on:"`

Expected: PASS, all five, the axis one now reporting the new message.

- [ ] **Step 7: Run the suite**

Run: `bundle exec rspec 2>&1 | tail -8`

Expected: 0 failures.

- [ ] **Step 8: Commit**

```bash
git add lib/axn/core/validation/base.rb lib/axn/core/contract.rb \
        spec/axn/core/validations/strict_validation_spec.rb
git commit -m "PRO-3225: refuse except_on:, which excludes nothing at any position"
```

---

### Task 8: Retract the five statements that say this cannot be done

**Files:**
- Modify: `docs/reference/class.md:106`
- Modify: `CHANGELOG.md` (the PRO-3193 entry's final paragraph at `:15`, plus a new entry)
- Modify: `spec/axn/core/validations/of_bag_value_validators_spec.rb:353` (stale comment)
- Verify: no `PRO-3225` reference survives in `lib/`

**Interfaces:**
- Consumes: the behaviour from Tasks 1–7.

- [ ] **Step 1: Confirm the full list of stale statements**

Run:

```bash
grep -rn "PRO-3225" lib/ spec/ docs/ CHANGELOG.md AGENTS.md
grep -rn "allow_nil" docs/reference/class.md
```

Expected: the `lib/` hits at `contract.rb` (`_bag_as_validations`) and `of_validator.rb` were rewritten in Tasks 4 and 6, so they should be gone. Any remaining `lib/` hit is a comment this task must fix. Per house rule, no ticket numbers survive in code comments as justification.

- [ ] **Step 2: Rewrite the docs paragraph**

Replace the bullet at `docs/reference/class.md:106` with:

```markdown
  * A bag's `optional:` / `allow_nil:` / `allow_blank:` govern **the position**, exactly as they do on a named shape member. `of: { klass: String, format: /\A[A-Z]{2}\z/, allow_nil: true }` accepts `["AB", nil]` and rejects `["ab"]`: a tolerated value is admitted without the position asking anything else of it. `allow_nil:` admits `nil` only; `allow_blank:` (and its `optional:` sugar) admits `nil` and blank. Widening the class instead — `of: { klass: [String, NilClass] }` — widens only the type check, so ActiveModel still runs `format:`/`length:`/`inclusion:`/`numericality:` on the `nil` and rejects it; reach for the tolerance rather than the union whenever the bag carries another validator.
```

Check the surrounding list for a manual line break mid-paragraph — this repo keeps one line per Markdown paragraph.

- [ ] **Step 3: Amend the PRO-3193 CHANGELOG paragraph and add the new entry**

Delete the paragraph at `CHANGELOG.md:15` beginning "Two things a bag's shared options still do **not** do" — every claim in it is now false. Add a new entry in the unreleased section:

```markdown
- **[BREAKING] An `of:` bag's tolerance governs its position.** `optional:`, `allow_nil:` and `allow_blank:` in an `of:` bag now mean what they mean on a named shape member: the position admits the value without asking anything else of it. `of: { klass: String, format: /\A[A-Z]{2}\z/, allow_nil: true }` accepts `["AB", nil]`, which had no spelling before — widening the class widens only the type check, and ActiveModel runs every other validator on a `nil` regardless. A map axis may now state its own tolerance too.

  Enabled by a change to where a field's tolerance is RECORDED: `optional:` is stated once on the declaration rather than copied into every validator entry, which is the tier ActiveModel applies to each validator itself. `config.validations` therefore carries `allow_blank:`/`allow_nil:` at its top level, and no validator entry carries a copy. `optional?`, requiredness, nullability and every emitted schema are unchanged.

  Breaking, at declaration time only. `of: { …, presence: true, allow_blank: true }` is refused as the contradiction it is, on the same rule that already refuses it at a field. `except_on:` is refused at a field entry and in a bag — axn has no validation contexts, so the exclusion excluded nothing and the entry ran on every call. And a typed base carrying `allow_nil:`/`optional:` beside `confirmation:` now reports a missing companion through its inherited type (`"is not a String"`) rather than its own presence check (`"can't be blank"`), which is what a strictly typed base already reported; requiredness is unchanged.
```

Confirm which heading is the unreleased section before editing: a bumped-yet-uncut version heading IS the unreleased section. Verify with `git tag --list | tail -5` and the published versions on rubygems, per the repo's changelog convention.

- [ ] **Step 4: Fix the stale spec comment**

At `spec/axn/core/validations/of_bag_value_validators_spec.rb:353`, the comment says a bag's `allow_nil:`/`allow_blank:` are not positional and so rescue nothing. Rewrite it to state what the example now measures — check the example body first and describe that, rather than assuming.

- [ ] **Step 5: Run the docs build and the full suite**

Run:

```bash
bundle exec rspec 2>&1 | tail -8
npm --prefix docs run build 2>&1 | tail -5 || true
```

Expected: 0 spec failures. The docs build is a smoke check on the Markdown edit; if the repo has no npm docs script, skip it and confirm the file renders as intended by eye.

- [ ] **Step 6: Commit**

```bash
git add docs/reference/class.md CHANGELOG.md spec/axn/core/validations/of_bag_value_validators_spec.rb
git commit -m "PRO-3225: retract the statements that said positional tolerance was unspellable"
```

---

### Task 9: Close out — downstream contracts and the interface sweep

**Files:**
- Verify: `spec/downstream_contracts/`
- Verify: `spec_rails/dummy_app`

- [ ] **Step 1: Run the downstream contract specs explicitly**

Run: `bundle exec rspec spec/downstream_contracts/`

Expected: 0 failures. These are the gate on Task 1's change to `config.validations`, because a consumer doing its own per-entry tolerance read is what the relocation could break. `axn_mcp_interface_spec.rb`'s "optional? still works on a field with of: present" is the specific example the design was priced against.

- [ ] **Step 2: Run the Rails-side suite**

Run: `cd spec_rails/dummy_app && BUNDLE_GEMFILE=Gemfile bundle exec rspec; cd -`

Expected: 0 failures. `BUNDLE_GEMFILE=Gemfile` is required from that directory.

- [ ] **Step 3: Confirm the reported grid by hand**

Run this probe and check every row against the spec's failure grid:

```bash
cat > /tmp/pro3225-grid.rb <<'RUBY'
$LOAD_PATH.unshift "lib"
require "axn"
Axn.config.logger.level = :fatal
PAY = { 'nil' => nil, '[]' => [], '["AB"]' => ["AB"], '["AB",nil]' => ["AB", nil],
        '["AB",""]' => ["AB", ""], '["ab"]' => ["ab"], '[1]' => [1] }
def row(label, bag)
  k = Class.new { include Axn }
  k.class_eval { expects :f, type: Array, of: bag }
  puts format("%-30s %s", label, PAY.values.map { |p| k.call(f: p).ok? ? "ok" : "NO" }.join(" "))
rescue ArgumentError => e
  puts format("%-30s refused: %s", label, e.message[0, 60])
end
BAG = { klass: String, format: { with: /\A[A-Z]{2}\z/ } }
puts format("%-30s %s", "", PAY.keys.map { |s| s[0, 2] }.join(" "))
row("no tolerance", BAG.dup)
row("allow_nil: true", BAG.merge(allow_nil: true))
row("allow_blank: true", BAG.merge(allow_blank: true))
row("optional: true", BAG.merge(optional: true))
row("presence + allow_blank", BAG.merge(presence: true, allow_blank: true))
RUBY
ruby /tmp/pro3225-grid.rb
```

Expected:

```
                               ni [] [" [" [" [" [1
no tolerance                   NO NO ok NO NO NO NO
allow_nil: true                NO NO ok ok NO NO NO
allow_blank: true              NO NO ok ok ok NO NO
optional: true                 NO NO ok ok ok NO NO
presence + allow_blank         refused: optional:/allow_blank:/allow_nil: on an `of:` bag …
```

The `["ab"]` and `[1]` columns must stay `NO` in every row — a tolerance admits the values it names and must not loosen the position's constraints for anything else.

- [ ] **Step 4: Run RuboCop**

Run: `bundle exec rubocop lib spec`

Expected: no offenses. If a method grew past a length cop, extract rather than adding an inline disable.

- [ ] **Step 5: Commit any fixes and push**

```bash
git add -A
git commit -m "PRO-3225: close out — downstream contracts, Rails suite, grid probe"
git push -u origin kali/pro-3225-axn-positional-tolerance-in-an-of-bag-and-the-tolerance-push
```

---

## Self-Review

**Spec coverage.** Every spec section maps to a task: Part A → Task 1 (including all three named consequences); Part B "Grammar" → Tasks 2 and 3; "Runtime" → Task 4; "Declaration guards" → Task 6; "Emission" → Task 5; the `if:`/`unless:`/`strict:`/`except_on:` settlement → Task 7 (`except_on:` is the only one needing code; the other three are measured no-change and are asserted by the Task 3 and Task 7 examples that pin them); "Breaking-change assessment" → the Task 8 CHANGELOG entry; "Retractions" → Task 8, all five statements; "Not in scope" → excluded, with the `allow_blank`+`pattern` divergence explicitly inherited via Task 5's reuse of the field's emitters.

**Ordering.** Task 1 must be first — every later task depends on the bag being author-only. Task 5 follows Task 4 immediately so no commit leaves the runtime accepting a value the emitted document rejects. Task 6 could precede Task 5 without harm but is placed after so the two guard-facing changes (emission, then satisfiability) land in the order the spec argues them.

**Type consistency.** `Axn::Validation::Base.tolerance_options(bag)` is defined once in Task 4 and consumed by name in Tasks 5 and 6. `_canonicalize_bag_tolerance!` is defined in Task 2 and relied on (not re-called) by Task 4. `_reject_tolerant_presence!(validations, where:, tolerance:)` is defined in Task 6 and called from both paths in the same task. `PositionContract#tolerates?` is defined and used only in Task 4. `entry_declares_except_on?` is defined and used only in Task 7.

**Verified seams.** Every method the plan calls by name was confirmed to exist before the plan was written: `Base.shared_validation_option_keys` / `validator_entries` / `effective_entry_options` / `nil_accepted?` / `entry_carries_option?` / `entry_declares_strict?`, `ShapeGraph.hash_or_nil` / `carries_key?` / `POSITION_DESCRIPTION_KEYS` / `INNER_CONTRACT_EDGES`, `NativeMethods.blank_literal?`, `Schema.bag_value_constraints` / `bag_nullable?` / `declared_size_minimum` / `effective_validations`, and `build_axn` (from `axn/testing/spec_helpers`, globally available in `spec/`).

**Measured baselines the plan asserts.** Task 1 Step 5's "exactly three failures" and Task 9 Step 3's grid are both taken from probes run against this worktree, not estimated. If Task 1 produces a fourth failure, the design's cost estimate is wrong and the task should stop rather than absorb it.
