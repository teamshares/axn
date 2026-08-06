# Confirmation Companion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `confirmation:` enforce a confirmation, by declaring an implicit `<field>_confirmation` companion input that is required exactly when the base field is present.

**Architecture:** `confirmation:` on a top-level field or subfield injects a companion `FieldConfig` at declaration, inheriting `type:`/`coerce:`/`preprocess:`/`method_call:`/`sensitive:` from the base and gated with `if: :<base reader>`. At validation, `Fields.errors_for` assigns the ActiveModel-generated `@<field>_confirmation` ivar from the companion config's resolved value, which is the entire runtime hook — ActiveModel's own `ConfirmationValidator` does the comparison. The companion is threaded through the same five surfaces `model:`'s `<field>_id` companion already occupies. `confirmation:` is refused on `exposes` and on shape members.

**Tech Stack:** Ruby, RSpec, RuboCop, ActiveModel validations. No new dependencies, no new `lib/` files.

**Ticket:** [PRO-3023](https://linear.app/teamshares/issue/PRO-3023/axn-confirmation-is-accepted-but-enforces-nothing)
**Spec:** `internal-docs/specs/2026-08-06-confirmation-companion-design.md`

## Global Constraints

- **The companion is a real `FieldConfig`, not a virtual attribute.** Every surface that enumerates declared fields must see it, because that is what makes redaction, the undeclared-input gate, and schema emission work without special-casing.
- **`default:` is never inherited.** A defaulted companion would silently satisfy its own comparison. Exclude it explicitly; do not merely omit it.
- **`sensitive:` inheritance is security-critical.** A sensitive base whose companion logs in the clear is a credential leak. It has its own test.
- **An explicit declaration wins.** If the author declares `<field>_confirmation` themselves, the implicit one stands down — `||=` for the emitted property, `_reader_name_available?` for the reader. Never raise on the collision.
- **The gate must be a Symbol**, never a Proc: `conditional_requiredness_clause` (`schema.rb:669`) only emits an exact `allOf` clause for a Symbol naming another declared field's framework-generated reader. A Proc silently degrades the schema to unconditional `required`.
- Comments describe current behavior and intrinsic why. No "used to X / now Y", no ticket numbers, no review references.
- No manual line breaks in Markdown prose — one line per paragraph.
- Never assert `Hash#inspect` text in a spec: Ruby 3.4 changed its spacing and CI runs 3.2/3.3/3.4.
- Guard anything ActiveRecord/Rails with `defined?()` — `spec/` runs outside Rails.
- Run `bundle exec rubocop` before each commit. Relevant maxima: `Layout/LineLength` 160, `Metrics/MethodLength` 70, `Metrics/AbcSize` 60, `Metrics/ClassLength` 250. Multiline argument lists require a trailing comma; `Style/HashSyntax` requires shorthand for symbol keys.
- Full suite: `bundle exec rspec`. The Rails dummy app is a separate bundle, run from the repo root via `rake spec_rails`. Run it in Task 5 (redaction) and Task 6 (schema).
- CHANGELOG entries go under the existing `## Unreleased` section (`0.1.0-alpha.5.1` is tagged and released). Do not open a new version heading.

## File Structure

| File | Responsibility | Change |
| --- | --- | --- |
| `lib/axn/core/validation/fields.rb` | The one-off validator collector | Modify: `errors_for` (L80) — accept and assign the companion value |
| `lib/axn/core/executor.rb` | Inbound/outbound validation runs, undeclared-input gate | Modify: `_collect_contract_failures` (L1152), `validate_contract!` (L1075), add a `_confirmation_top_level_keys` beside `_model_id_top_level_keys` (L1393) |
| `lib/axn/core/contract.rb` | The declaration DSL, reader generation, nil-skip push-down | Modify: `expects` (L465), `_define_field_readers!` (L1361), `_type_rejects_nil?` (L1783); add companion builder + `exposes` rejection |
| `lib/axn/core/contract_for_subfields.rb` | Subfield declaration path | Modify: `_expects_subfields` — inject the companion on the subfield route |
| `lib/axn/core/contract/shape_declaration.rb` | Shape member declaration | Modify: add `_raise_member_confirmation_unsupported!` beside `_raise_member_model_unsupported!` (L434) |
| `lib/axn/core/contract/redaction.rb` | Sensitive-key collection | Modify: `_sensitive_field_keys` (L187) |
| `lib/axn/internal/reflection/schema.rb` | Schema derivation | Modify: companion requiredness in the second pass beside `apply_model_id_requiredness!` (L181-183) |
| `lib/axn/core/validation/base.rb` | Shared validator judgments | Modify: comment on the `confirmation` carve-out (L130) only |
| `spec/axn/core/validations/confirmation_spec.rb` | The feature's behavior at every supported level | **Create** |
| `spec/axn/core/validations/gated_nil_message_spec.rb` | The one-message collapse for conditionally-required fields | **Create** |
| `docs/reference/class.md` | User-facing reference | Modify: document `confirmation:` and its difference from the AM default |
| `CHANGELOG.md` | Release notes | Modify: entries under `## Unreleased` |

---

### Task 1: The runtime hook — a hand-declared pair actually compares

The smallest change that makes `confirmation:` do anything. Proves the mechanism before any declaration machinery exists.

**Files:**
- Modify: `lib/axn/core/validation/fields.rb` (L80 `errors_for`)
- Modify: `lib/axn/core/executor.rb` (L1152 `_collect_contract_failures`)
- Create: `spec/axn/core/validations/confirmation_spec.rb`

**Interfaces:**
- Produces: `Axn::Validation::Fields.errors_for(..., confirmation: nil)` — an extra keyword taking a `[field_name, resolved_value]` pair, or `nil` when the field declares no confirmation. When a pair is given, `errors_for` sets `@<field_name>_confirmation` on the validator instance. Consumed by Tasks 3 and 6.
- Produces: `Axn::Core::ContractForSubfields.sibling_confirmation_config(action, config) → FieldConfig | nil` — the declared `<field>_confirmation` on the same route. Consumed by Task 3.
- Produces: `Axn::Core::Executor#_confirmation_pair_for(config) → [Symbol, Object] | nil`.

- [ ] **Step 1: Write the failing test**

This repo has no shared action-building helper — specs construct classes inline (see `spec/axn/core/schema_reflection_spec.rb:154` for the idiom). Define one local helper in this file so the examples stay about confirmation rather than about class construction.

Create `spec/axn/core/validations/confirmation_spec.rb`:

```ruby
# frozen_string_literal: true

RSpec.describe "confirmation:" do
  # Mirrors the inline `Class.new { include Axn; def call = nil }` idiom the rest of the suite uses.
  def build_axn(&declaration)
    Class.new do
      include Axn
      def call = nil
    end.tap { |klass| klass.class_eval(&declaration) }
  end

  describe "a declared pair at the top level" do
    let(:action) do
      build_axn do
        expects :password, type: String, confirmation: true
        expects :password_confirmation, type: String, optional: true
      end
    end

    it "passes when the confirmation matches" do
      expect(action.call(password: "s3cret", password_confirmation: "s3cret")).to be_ok
    end

    it "fails when the confirmation does not match" do
      result = action.call(password: "s3cret", password_confirmation: "nope")
      expect(result).not_to be_ok
      expect(result.exception.message).to include("Password confirmation doesn't match Password")
    end

    it "compares the companion's transformed value, not its raw wire value" do
      klass = build_axn do
        expects :password, type: String, confirmation: true
        expects :password_confirmation, type: String, optional: true, preprocess: ->(s) { s&.strip }
      end
      expect(klass.call(password: "s3cret", password_confirmation: "  s3cret  ")).to be_ok
    end
  end
end
```

Check `spec/spec_helper.rb` for the project's existing action-building helper and use that name rather than `build_axn` if it differs.

- [ ] **Step 2: Run it to verify it fails**

Run: `bundle exec rspec spec/axn/core/validations/confirmation_spec.rb`
Expected: the mismatch example FAILS (the action is `ok?`), because nothing populates the confirmation accessor.

- [ ] **Step 3: Add the sibling lookup**

In `lib/axn/core/contract_for_subfields.rb`, beside `sibling_id_configs` (L411), add:

```ruby
# The declared `<field>_confirmation` config on the SAME route as `config`, or nil. A confirmation
# pair is one route's contract: unlike `sibling_id_configs`, which falls through to a defaulted or
# sole route because an id may legitimately be declared beside a different model, a confirmation
# compares against the companion declared beside THIS field and nothing else.
def self.sibling_confirmation_config(action, config)
  key = :"#{config.field}_confirmation"
  candidates =
    if config.on.nil?
      action.class.internal_field_configs.select { |c| c.field == key }
    else
      action.class.send(:subfield_configs).select { |c| c.field == key }
    end

  candidates.find { |c| c.on.to_s == config.on.to_s }
end
```

- [ ] **Step 4: Assign the ivar in `errors_for`**

In `lib/axn/core/validation/fields.rb`, add a keyword to `errors_for` (L80) and assign it. ActiveModel's `ConfirmationValidator#setup!` defines a real `attr_reader :<attr>_confirmation` on the one-off class, and that reader reads the ivar — so setting it is the whole hook, and `read_attribute_for_validation` is deliberately not involved.

```ruby
def self.errors_for(validator_class, source:, validations:, action: nil, reader: nil, config: nil, permit_method_call: false,
                    shape_ancestry: nil, confirmation: nil)
  validator = validator_class.new(source)

  validator.instance_variable_set(:@action, action)
  validator.instance_variable_set(:@validations, validations)
  validator.instance_variable_set(:@reader, reader)
  validator.instance_variable_set(:@config, config)
  validator.instance_variable_set(:@permit_method_call, permit_method_call)
  validator.instance_variable_set(:@shape_ancestry, shape_ancestry)

  # ActiveModel's ConfirmationValidator#setup! defines a real `attr_reader :<attr>_confirmation` on
  # this one-off class, and compares only when that reader answers non-nil. The reader reads an ivar,
  # so supplying the companion's resolved value here is the whole of the wiring — the caller resolves
  # it, because only the caller knows which config the companion is.
  validator.instance_variable_set(:"@#{confirmation.first}_confirmation", confirmation.last) if confirmation

  validator.valid?
  validator.errors
end
```

`confirmation:` is a `[field, value]` pair rather than a bare value so that a `nil` companion is still assigned (which is a no-op for AM, but keeps the caller from having to distinguish absent-from-nil).

- [ ] **Step 5: Resolve and pass it from the executor**

In `lib/axn/core/executor.rb`, inside `_collect_contract_failures` (L1152), before the `errors_for` call:

```ruby
confirmation = _confirmation_pair_for(config)
```

and pass `confirmation:` through to `errors_for`. Add the helper below it:

```ruby
# The `[field, value]` pair a `confirmation:` field's validator compares against — the sibling
# `<field>_confirmation`'s RESOLVED value, so the comparison sees the same coerce:/preprocess:
# result the sibling's own reader and validation see, rather than the raw wire value.
def _confirmation_pair_for(config)
  return nil unless config.validations[:confirmation]

  sibling = Axn::Core::ContractForSubfields.sibling_confirmation_config(@action, config)
  return nil unless sibling

  [config.field, Axn::Core::ContractForSubfields.resolve_value(@action, sibling)]
end
```

- [ ] **Step 6: Run the new spec**

Run: `bundle exec rspec spec/axn/core/validations/confirmation_spec.rb`
Expected: PASS, all three examples.

- [ ] **Step 7: Run the full suite and rubocop**

Run: `bundle exec rspec && bundle exec rubocop`
Expected: 0 failures, no offenses.

- [ ] **Step 8: Commit**

```bash
git add lib/axn/core/validation/fields.rb lib/axn/core/executor.rb lib/axn/core/contract_for_subfields.rb spec/axn/core/validations/confirmation_spec.rb
git commit -m "PRO-3023: confirmation: compares against a declared sibling"
```

---

### Task 2: Refuse `confirmation:` where it cannot work

Fence the supported surface before building on it. Both refusals are declaration-time.

**Files:**
- Modify: `lib/axn/core/contract.rb` (`exposes`, L482)
- Modify: `lib/axn/core/contract/shape_declaration.rb` (beside `_raise_member_model_unsupported!`, L434)
- Modify: `spec/axn/core/validations/confirmation_spec.rb`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `ArgumentError` at declaration for both positions. Task 3 relies on never having to build a companion for an exposure or a member.

- [ ] **Step 1: Write the failing tests**

Append to `spec/axn/core/validations/confirmation_spec.rb`:

```ruby
  describe "positions where it cannot be honored" do
    it "refuses confirmation: on exposes" do
      expect do
        build_axn { exposes :token, type: String, confirmation: true }
      end.to raise_error(ArgumentError, /does not support confirmation:/)
    end

    it "refuses confirmation: on a shape member" do
      expect do
        build_axn do
          expects :payload, type: Hash do
            field :password, type: String, confirmation: true
          end
        end
      end.to raise_error(ArgumentError, /shape member `password` does not support confirmation:/)
    end
  end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bundle exec rspec spec/axn/core/validations/confirmation_spec.rb -e "cannot be honored"`
Expected: FAIL — both declarations currently succeed.

- [ ] **Step 3: Reject on `exposes`**

In `lib/axn/core/contract.rb`, in `exposes` (L482), after `_validate_user_facing!` and before `_partition_field_options`:

```ruby
# A confirmation pair is an inbound form contract: the caller supplies both halves and they are
# compared. An exposure's companion would be a result property the action never sets, so it would
# resolve nil on every call and the comparison would never run — an option that reads as enforcing
# something and enforces nothing, which is the defect this option was fixed for.
if validations_include_confirmation
  raise ArgumentError,
        "`exposes` does not support confirmation: — a confirmation compares a caller-supplied value " \
        "against a caller-supplied companion, and an exposure has neither. Declare the pair with " \
        "`expects` if the confirmation is an input."
end
```

Read the flag off the keyword splat before `_partition_field_options` consumes it; the surrounding code already destructures `**` into `validations`, so hoist that call above this guard rather than reading the raw splat twice.

- [ ] **Step 4: Reject on a shape member**

In `lib/axn/core/contract/shape_declaration.rb`, add beside `_raise_member_model_unsupported!` (L434):

```ruby
# A member's requiredness rule for a confirmation companion cannot be written: the companion is
# required only when the member is present, and a member's if:/unless: condition resolves against
# the ACTION rather than the element (validate_members_of threads the action deliberately), so it
# cannot name a sibling member at all. An injected gate raises NoMethodError on every call, and an
# ungated companion is either required when the member is absent or never enforced — so the option
# is refused here rather than honored in a shape-only variant an author cannot see from the
# declaration.
def _raise_member_confirmation_unsupported!(name)
  label = _shape_member_label(name)
  raise ArgumentError,
        "shape member `#{label}` does not support confirmation: — the companion is required only when " \
        "the member is present, and a member's `if:` condition resolves against the action rather than " \
        "the element, so it cannot refer to a sibling member. Declare the pair as subfields " \
        "(`expects :#{label}, on: :<parent>`) to get the confirmation contract."
end
```

Call it from the same place `_raise_member_model_unsupported!` is called, keyed on the member's validations carrying a truthy `:confirmation`. Add `:confirmation` handling to `_check_member_option_keys!`'s classification (`contract.rb:985`) so the named message wins over the generic unknown-key path.

- [ ] **Step 5: Run to verify they pass**

Run: `bundle exec rspec spec/axn/core/validations/confirmation_spec.rb`
Expected: PASS.

- [ ] **Step 6: Full suite, rubocop, commit**

```bash
bundle exec rspec && bundle exec rubocop
git add lib/axn/core/contract.rb lib/axn/core/contract/shape_declaration.rb spec/axn/core/validations/confirmation_spec.rb
git commit -m "PRO-3023: refuse confirmation: on exposes and shape members"
```

---

### Task 3: Inject the implicit companion

The declaration change: `expects :password, confirmation: true` alone now declares the companion.

**Files:**
- Modify: `lib/axn/core/contract.rb` (`expects` L465-478, `_define_field_readers!` L1361)
- Modify: `lib/axn/core/contract_for_subfields.rb` (`_expects_subfields`)
- Modify: `spec/axn/core/validations/confirmation_spec.rb`

**Interfaces:**
- Consumes: `sibling_confirmation_config` and the `errors_for` keyword from Task 1 — both work unchanged once the companion is a real declared config.
- Produces: `_confirmation_companion_configs(configs) → Array<FieldConfig>`, called from both declaration routes.

- [ ] **Step 1: Write the failing tests**

Append to `spec/axn/core/validations/confirmation_spec.rb`:

```ruby
  describe "the implicit companion" do
    let(:action) { build_axn { expects :password, type: String, confirmation: true } }

    it "fails a mismatch with no companion declared by the author" do
      result = action.call(password: "s3cret", password_confirmation: "nope")
      expect(result).not_to be_ok
      expect(result.exception.message).to include("Password confirmation doesn't match Password")
    end

    it "passes a match with no companion declared by the author" do
      expect(action.call(password: "s3cret", password_confirmation: "s3cret")).to be_ok
    end

    it "inherits coerce: so both sides compare in the same space" do
      klass = build_axn { expects :count, type: Integer, coerce: true, confirmation: true }
      expect(klass.call(count: "5", count_confirmation: "5")).to be_ok
    end

    it "inherits preprocess: so both sides compare in the same space" do
      klass = build_axn { expects :name, type: String, preprocess: ->(s) { s&.strip }, confirmation: true }
      expect(klass.call(name: " kd ", name_confirmation: " kd ")).to be_ok
    end

    it "does not inherit default:, which would satisfy its own comparison" do
      klass = build_axn { expects :password, type: String, default: "fallback", confirmation: true }
      expect(klass.call).not_to be_ok
    end

    it "names the reader off the aliased reader and the wire key off the field" do
      klass = build_axn { expects :password, as: :pw, type: String, confirmation: true }

      expect(klass.instance_methods).to include(:pw_confirmation)
      companion = klass.internal_field_configs.find { |c| c.field == :password_confirmation }
      expect(companion).not_to be_nil
      expect(companion.reader_as).to eq(:pw_confirmation)
    end

    it "stands down when the author declares the companion explicitly" do
      klass = build_axn do
        expects :password, type: String, confirmation: true
        expects :password_confirmation, type: String, optional: true
      end
      expect(klass.call(password: "s3cret", password_confirmation: "s3cret")).to be_ok
    end

    it "works on a subfield" do
      klass = build_axn do
        expects :payload, type: Hash
        expects :password, on: :payload, type: String, confirmation: true
      end
      expect(klass.call(payload: { password: "a", password_confirmation: "b" })).not_to be_ok
      expect(klass.call(payload: { password: "a", password_confirmation: "a" })).to be_ok
    end
  end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bundle exec rspec spec/axn/core/validations/confirmation_spec.rb -e "implicit companion"`
Expected: FAIL — no companion is declared, so nothing compares.

- [ ] **Step 3: Build the companion configs**

In `lib/axn/core/contract.rb`, near `_parse_field_configs` (L1284):

```ruby
# The companion `FieldConfig` a `confirmation:` field declares implicitly — the same treatment a
# `model:` field's `<field>_id` gets, and for the same reason: the option names a second wire key,
# so the contract has to carry it or nothing downstream (redaction, the undeclared-input gate, the
# emitted schema) can see it.
#
# What it inherits is what has to match for the comparison to mean anything. `type:`/`coerce:`/
# `preprocess:` put both sides in the same space — an uncoerced companion compares 5 against "5"
# and reports a mismatch the caller cannot act on. `method_call:` is an enabler the base already
# required for the same object. `sensitive:` must carry or a confirmed secret logs in the clear.
# `default:` must NOT carry: a defaulted companion would satisfy its own comparison.
#
# Gated on the base field's own reader, as a Symbol rather than a Proc, because only a Symbol naming
# a declared field's framework-generated reader emits an exact conditional-requiredness clause
# (Internal::Reflection::Schema.conditional_requiredness_clause) — a Proc degrades the schema to
# unconditionally required while the runtime stays conditional.
def _confirmation_companion_configs(configs)
  configs.filter_map do |config|
    next unless config.validations[:confirmation]

    companion = :"#{config.field}_confirmation"
    next if configs.any? { |c| c.field == companion }

    FieldConfig.new(
      field: companion,
      validations: config.validations.slice(:type, :coerce).merge(if: config.reader_as),
      on: config.on,
      default: nil,
      preprocess: config.preprocess,
      sensitive: config.sensitive,
      metadata: {},
      reader_as: :"#{config.reader_as}_confirmation",
      user_facing: config.user_facing,
      method_call: config.method_call,
    )
  end
end
```

- [ ] **Step 4: Inject on both declaration routes**

In `expects` (L465), change the `.tap` block to append companions before the duplicate check, skipping any the author already declared:

```ruby
_parse_field_configs(...).then { |configs| configs + _confirmation_companion_configs(configs) }.tap do |configs|
  ...
end
```

Filter out a companion whose field is already present in `internal_field_configs` — the author's own declaration is authoritative, and re-declaring it must not trip `_reject_duplicate_fields!`. Apply the identical treatment in `_expects_subfields` in `lib/axn/core/contract_for_subfields.rb`, comparing against `subfield_configs` on the same `on:` route.

- [ ] **Step 5: Generate the companion reader**

In `_define_field_readers!` (L1361), the companion is an ordinary config in `configs`, so `_define_field_reader` already covers it. Verify by running the `as:` example; if the companion needs the deferral behavior, route it through `_reader_name_available?(name, kind: "confirmation")` exactly as `_define_model_id_reader` does.

- [ ] **Step 6: Run the spec**

Run: `bundle exec rspec spec/axn/core/validations/confirmation_spec.rb`
Expected: PASS. The `default:` example should fail the action because the base's default does not reach the companion.

- [ ] **Step 7: Full suite, rubocop, commit**

```bash
bundle exec rspec && bundle exec rubocop
git add lib/axn/core/contract.rb lib/axn/core/contract_for_subfields.rb spec/axn/core/validations/confirmation_spec.rb
git commit -m "PRO-3023: confirmation: declares its companion implicitly"
```

---

### Task 4: One message for a missing companion

Narrowing `_type_rejects_nil?` so a conditionally-required field reports one clause, as an unconditionally-required one already does. Independently valuable — every gated field in axn benefits — so it gets its own spec file and its own changelog line.

**Files:**
- Modify: `lib/axn/core/contract.rb` (L1783 `_type_rejects_nil?`)
- Create: `spec/axn/core/validations/gated_nil_message_spec.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: no new API. Changes the error text of every conditionally-required field with a `type:`.

- [ ] **Step 1: Write the failing test**

Create `spec/axn/core/validations/gated_nil_message_spec.rb`:

```ruby
# frozen_string_literal: true

RSpec.describe "a conditionally-required field's message for a nil" do
  it "reports the type error alone, as an unconditionally-required field does" do
    klass = build_axn do
      expects :flag, type: String
      expects :name, type: String, if: :flag
    end
    result = klass.call(flag: "x")
    expect(result).not_to be_ok
    expect(result.exception.message).to eq("Name is not a String")
  end

  it "still lets a sibling reject the nil when the gate is on the TYPE ENTRY alone" do
    klass = build_axn do
      expects :flag, type: String, optional: true
      expects :name, type: { klass: String, if: :flag }, presence: true
    end
    result = klass.call
    expect(result).not_to be_ok
    expect(result.exception.message).to include("Name can't be blank")
  end
end
```

- [ ] **Step 2: Run to verify the first fails**

Run: `bundle exec rspec spec/axn/core/validations/gated_nil_message_spec.rb`
Expected: the first example FAILS with `"Name is not a String and Name can't be blank"`; the second PASSES already.

- [ ] **Step 3: Narrow the predicate**

In `lib/axn/core/contract.rb`, replace the `decl_gates` branch in `_type_rejects_nil?` (L1793-1794) with:

```ruby
          # A NESTED gate key on ANY entry — blank or not — can desynchronize the type check from its
          # siblings under ActiveModel's per-key merge, in either direction: a non-blank one ties an entry
          # to a different condition than the rest, while a blank same-key one DROPS the shared gate for
          # that entry alone. Either way some other validator can run on a call where the type check does
          # not, which makes that validator's nil rejection the only account of a nil and so not one to
          # relax. A DECLARATION-level gate does neither: it opens and closes every validator on the
          # declaration together, presence included, so it decides whether an account is given, never
          # whose. Key PRESENCE is the test rather than effective gatedness, for the blank case — the same
          # question `Internal::Reflection::Schema.entry_mentions_gate_key?` asks for the same reason.
          gate_keys = Internal::FieldConfig::CONDITIONAL_GATE_KEYS
          mentions_gate = ->(opt) { opt.is_a?(Hash) && gate_keys.any? { |key| opt.key?(key) } }
          return false if Axn::Validation::Base.validator_entries(validations).any? { |_key, opt| mentions_gate.call(opt) }
```

Update the method's leading comment: the third bullet currently says "an effective if:/unless: gate on the type entry" — it is now a nested gate key on any entry, and the reason is desynchronization rather than a closed gate.

- [ ] **Step 4: Run to verify both pass**

Run: `bundle exec rspec spec/axn/core/validations/gated_nil_message_spec.rb`
Expected: PASS.

- [ ] **Step 5: Run the full suite**

Run: `bundle exec rspec`
Expected: 0 failures. If specs around a "blank same-key nested override" fail, the predicate has been written with `entry_self_gated?` (which ignores blank gates) instead of key presence — re-read Step 3.

- [ ] **Step 6: Rubocop and commit**

```bash
bundle exec rubocop
git add lib/axn/core/contract.rb spec/axn/core/validations/gated_nil_message_spec.rb
git commit -m "PRO-3023: a declaration-level gate no longer doubles a nil's message"
```

---

### Task 5: Redaction and the undeclared-input gate

The two surfaces where an unthreaded companion is a real defect rather than a cosmetic one: a leaked secret, and a tool call rejected for sending exactly what the schema asked for.

**Files:**
- Modify: `lib/axn/core/contract/redaction.rb` (L187 `_sensitive_field_keys`)
- Modify: `lib/axn/core/executor.rb` (beside `_model_id_top_level_keys`, L1393)
- Modify: `spec/axn/core/validations/confirmation_spec.rb`

**Interfaces:**
- Consumes: the companion config from Task 3.
- Produces: nothing new.

- [ ] **Step 1: Write the failing tests**

Append to `spec/axn/core/validations/confirmation_spec.rb`:

```ruby
  describe "the companion on the sensitive and tool surfaces" do
    it "redacts the companion when the base field is sensitive" do
      klass = build_axn { expects :password, type: String, sensitive: true, confirmation: true }
      companion = klass.internal_field_configs.find { |c| c.field == :password_confirmation }

      expect(companion.sensitive).to be(true)
    end

    it "accepts the companion under reject_undeclared_inputs" do
      klass = build_axn { expects :password, type: String, confirmation: true }
      result = klass.call(password: "s3cret", password_confirmation: "s3cret")

      expect(result).to be_ok
    end
  end
```

Two of these need their assertion style taken from existing specs rather than invented, because both surfaces are easy to assert wrongly:

**The redaction example** above only proves the config carries the flag. Add a second example asserting the value is actually masked in output, mirroring `spec/axn/core/dynamic_sensitive_spec.rb` — read that file and copy its assertion form. The masking surface differs by output path (log line vs `inspect` vs the `ParameterFilter` key set), and a hand-written assertion can pass while the real path still leaks.

**The `reject_undeclared_inputs` example** above calls the action plainly, which does not exercise the gate at all — the flag is per-call and only the tool `Invoker` sets it in production (`lib/axn/tools/invoker.rb:22`, threading through `lib/axn/internal/current_call_options.rb`). Rewrite it to set the flag the way the tool-invocation specs already do; find them with `grep -rln "reject_undeclared_inputs" spec/` and mirror the setup. Without that, this example passes vacuously.

- [ ] **Step 2: Run to verify they fail**

Run: `bundle exec rspec spec/axn/core/validations/confirmation_spec.rb -e "sensitive and tool surfaces"`
Expected: FAIL — the companion is neither redacted nor exempt.

- [ ] **Step 3: Thread redaction**

Because the companion is a real config carrying its own inherited `sensitive:`, `_sensitive_field_keys` may already cover it. Run the first example before changing anything. If it passes, delete nothing and note it in the commit message; if it fails, the companion's `sensitive:` is not reaching the collector and `_sensitive_field_keys` needs the companion key added the way it adds `model_id_key`.

- [ ] **Step 4: Thread the undeclared-input gate**

In `lib/axn/core/executor.rb`, beside `_model_id_top_level_keys` (L1393):

```ruby
# A `confirmation:` field declares a companion wire key implicitly, so a caller may legitimately
# supply it. It is a declared config, so the gate sees it — but only at the top level, matching the
# model-id exemption: a subfield companion's key is nested, not a top-level provided key.
```

Verify whether the gate reads declared configs (in which case the companion is already exempt and no code is needed) or a separately-built key list (in which case add the companion keys). `_undeclared_input_messages` (L1367) is the reader; follow it and change the minimum.

- [ ] **Step 5: Run the spec and the Rails dummy app**

Run: `bundle exec rspec spec/axn/core/validations/confirmation_spec.rb`
Run: `rake spec_rails`
Expected: PASS. `spec_rails` exercises redaction against a real Rails app and must be run for this task.

- [ ] **Step 6: Full suite, rubocop, commit**

```bash
bundle exec rspec && bundle exec rubocop
git add lib/axn/core/contract/redaction.rb lib/axn/core/executor.rb spec/axn/core/validations/confirmation_spec.rb
git commit -m "PRO-3023: thread the confirmation companion through redaction and the input gate"
```

---

### Task 6: Schema emission and conditional requiredness

The tool surface has to advertise the companion, and its requiredness must be resolved independently of declaration order.

**Files:**
- Modify: `lib/axn/internal/reflection/schema.rb` (second pass, L181-183)
- Modify: `spec/axn/core/validations/confirmation_spec.rb`

**Interfaces:**
- Consumes: the companion config from Task 3, whose `if:` gate is a Symbol naming the base reader.
- Produces: nothing new.

- [ ] **Step 1: Write the failing test**

Append to `spec/axn/core/validations/confirmation_spec.rb`:

```ruby
  describe "the emitted input schema" do
    it "advertises the companion, conditionally required on the base field" do
      klass = build_axn { expects :password, type: String, confirmation: true }
      schema = klass.input_schema

      expect(schema[:properties]).to have_key(:password_confirmation)
      expect(schema[:required]).to contain_exactly("password")
      expect(schema[:allOf]).to eq(
        [{ if: { required: ["password"], properties: { password: { not: { enum: [false, nil] } } } },
           then: { required: ["password_confirmation"] } }],
      )
    end

    it "resolves requiredness independently of declaration order" do
      a = build_axn do
        expects :password, type: String, confirmation: true
        expects :other, type: String, optional: true
      end
      b = build_axn do
        expects :other, type: String, optional: true
        expects :password, type: String, confirmation: true
      end
      expect(a.input_schema[:allOf]).to eq(b.input_schema[:allOf])
    end
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bundle exec rspec spec/axn/core/validations/confirmation_spec.rb -e "emitted input schema"`
Expected: FAIL or PASS — run it before writing any code. Because the companion is a real config with a Symbol gate, `conditional_requiredness_clause` (L669) may already emit the clause. If both examples pass, this task is verification only: keep the spec, write no production code, and say so in the commit message.

- [ ] **Step 3: Resolve the companion's requiredness in the second pass, if needed**

Only if Step 2 failed. In `build_input` (L179-184), the model-id pass runs "after all properties exist, so it's independent of declaration order". Add the companion's resolution alongside it, in the same pass, for the same reason. Do not add a separate walk — declaration-order independence is the property the shared pass exists to guarantee.

- [ ] **Step 4: Run the spec**

Run: `bundle exec rspec spec/axn/core/validations/confirmation_spec.rb`
Expected: PASS.

- [ ] **Step 5: Full suite, dummy app, rubocop, commit**

```bash
bundle exec rspec && rake spec_rails && bundle exec rubocop
git add lib/axn/internal/reflection/schema.rb spec/axn/core/validations/confirmation_spec.rb
git commit -m "PRO-3023: emit the confirmation companion in the input schema"
```

---

### Task 7: Documentation and changelog

**Files:**
- Modify: `docs/reference/class.md`
- Modify: `lib/axn/core/validation/base.rb` (L130 comment only)
- Modify: `CHANGELOG.md`

**Interfaces:** none.

- [ ] **Step 1: Correct the nil-tolerance comment**

In `lib/axn/core/validation/base.rb`, the `confirmation` clause at L89-90 and the carve-out at L130 stay — a `confirmation` entry on the base field genuinely rejects no nil of its own, because ActiveModel skips the comparison when the companion is nil. Rewrite only the justification, which currently rests on the accessor being unpopulated. Replace the parenthetical at L89-90 with:

```
      # `confirmation` (ActiveModel compares only when the `<attr>_confirmation` accessor is non-nil, so the
      # check adds no error of its own on a nil — the companion's OWN requiredness is a separate question,
      # carried by the gate on the companion config),
```

- [ ] **Step 2: Document the option**

In `docs/reference/class.md`, near the validation reference (the "anything else … as ActiveModel validations" row at L23 and the custom-validator list at L84), add a `confirmation:` section covering: it declares a `<field>_confirmation` input implicitly; the companion inherits `type:`/`coerce:`/`preprocess:`/`method_call:`/`sensitive:` and never `default:`; an explicit declaration of the companion wins; it is required exactly when the base field is present; and it is unsupported on `exposes` and on shape members.

State the difference from the ActiveModel default plainly, and give the reason rather than only the rule: ActiveModel skips the comparison when the confirmation is nil because its confirmation attribute is a virtual accessor on a persistent record, which carries nil on every save that does not touch the field. An axn call is one inbound message, so that constraint does not apply, and the Rails guides already tell you to add the presence check by hand.

One line per paragraph, no manual line breaks. Only use `[!code focus]` in a full-scaffold block.

- [ ] **Step 3: Changelog**

Under `## Unreleased`, add to `### Fixed`:

```markdown
* [BUGFIX] `confirmation:` now enforces a confirmation. It was accepted at declaration and could never fire in any spelling: ActiveModel's `ConfirmationValidator` defines a real `<field>_confirmation` accessor on the one-off validator class axn builds, nothing ever populated it, and because the accessor is real it also shadowed the fallback that would have let a hand-declared companion field supply the value. `expects :password, confirmation: true` now declares a `password_confirmation` input implicitly — inheriting the base field's `type:`, `coerce:`, `preprocess:`, `method_call:` and `sensitive:`, never its `default:` — and requires it exactly when the base field is present. Unsupported on `exposes` and on shape members, both of which now raise at declaration. Note the deliberate difference from ActiveModel, whose default accepts an omitted confirmation (see PRO-3023).
* [BUGFIX] A conditionally-required field (`expects :name, type: String, if: :flag`) now reports one message for a `nil` rather than two, matching an unconditionally-required field. The nil-skip that collapses a nil's account to its type error stood down for any effectively-gated type entry, including a declaration-level gate — which gates every validator on the declaration together and so cannot produce the divergence the guard exists for.
```

- [ ] **Step 4: Verify the changelog section is still current**

Run: `git tag --list | tail -3` and confirm no tag matches a version heading above `## Unreleased`. If a release was cut while this branch was open, move the entries under the new topmost unreleased heading.

- [ ] **Step 5: Full suite, dummy app, rubocop, commit**

```bash
bundle exec rspec && rake spec_rails && bundle exec rubocop
git add docs/reference/class.md lib/axn/core/validation/base.rb CHANGELOG.md
git commit -m "PRO-3023: document the confirmation companion"
```

---

## Self-Review Notes

Spec sections and the task that implements each: decision 1 (implicit companion) → Task 3; decision 2 (inheritance table) → Task 3, with `sensitive:` re-verified in Task 5; decision 3 (gated requiredness) → Task 3 (the gate) and Task 6 (its schema clause); decision 4 (reader vs wire key) → Task 3 Step 1's `as:` example; decision 5 (explicit wins) → Task 3; decision 6 (both rejections) → Task 2; decision 7 (order-independent second pass) → Task 6 Step 2's order example; decision 8 (nil-tolerance comment) → Task 7; decision 9 (one message) → Task 4.

Two tasks deliberately begin by running a test before writing code, because the companion being a real `FieldConfig` may make the surface work with no change at all: Task 5 Step 3 (redaction) and Task 6 Step 2 (schema). Both say what to do in either outcome. That is a genuine unknown rather than a placeholder — resolving it by reading the code was not possible without tracing `_sensitive_field_keys` and `conditional_requiredness_clause` against a config that does not exist yet.
