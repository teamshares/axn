# PRO-3050: Low-Hanging Performance Improvements — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Recover the recoverable half of alpha-5's per-call allocation regression (the [PRO-3050](https://linear.app/teamshares/issue/PRO-3050) ticket) by caching declaration-time-derived facts that were being recomputed on every `.call`, without reopening any of the correctness holes the prototype hit.

**Architecture:** Three independent per-class identity-keyed caches, all mirroring the existing `Redaction#_contract_redaction` / `ContractForSubfields#_resolved_subfields` pattern (outer key: `equal?` on the copy-on-write `*_field_configs` arrays; inner key, where needed: a `compare_by_identity` Hash keyed on the frozen `FieldConfig`/`ShapeConfig` object itself — never on `validations`, which is not stably identical across calls or reads). Plus one early-return in the logging path keyed on the configured logger's own severity predicate.

**Tech Stack:** Ruby, ActiveModel (validators), RSpec.

**Spec source:** The Linear ticket (PRO-3050) already **is** the spec for this work — it names the exact design (config-identity keying, not `[field, validations]`), the exact hazard it must avoid (the prototype broke 6 examples in `option_bag_keys_spec`/`property_name_collision_spec`/`stored_shape_traversal_spec`), and explicitly scopes item 4 (the per-facade reader-definition redesign) out unless items 1–3 disappoint. This plan does not re-derive that design; it sequences building it.

## Global Constraints

- **TDD**: failing test first, then implementation (AGENTS.md, CONTRIBUTING.md). Every task below writes/extends a spec before touching `lib/`.
- **Never key a cache on `config.validations`** (object identity OR content): `_with_effective_coerce` mints a fresh merged Hash every call when `coerce_input_types` is on, and a config reached via `internal_field_configs=`/`subfield_configs=` can return a **different** Hash object on every `#validations` read (`stored_shape_traversal_spec`'s generative member). Key on the `FieldConfig`/`ShapeConfig` object itself, via `compare_by_identity`, never via `hash`/`eql?`.
- **Never call `hash`/`eql?`/`==` on a stored validations Hash's contents** — a stored option value may be a caller-supplied object with hostile `hash`/`eql?`/`==` (`option_bag_keys_spec.rb:176`, "leaves an option's value the caller's own object").
- **Outer cache key = `equal?` on the copy-on-write config arrays** (`internal_field_configs`, `external_field_configs`, `subfield_configs`), exactly as `_contract_redaction`/`_resolved_subfields` do — self-invalidating on any redeclaration, subclass, or `Mountable`/`Factory` rebuild, with no invalidation hook to maintain.
- **Leave `ShapeValidator`'s own per-member cache (`@member_validator_classes`) untouched.** That is the "shape-member path" the ticket says to leave compiling per call (or key separately on `ShapeConfig`) — it is a different mechanism (instance-lived, keyed on `member.field` Symbol) protecting a different invariant (the per-call traversal bound over a possibly-generative stored shape graph).
- **Run `bundle exec rspec`, the relevant `spec_rails` specs (`BUNDLE_GEMFILE=spec_rails/dummy_app/Gemfile bundle exec rspec` from `spec_rails/dummy_app`), and `rake benchmark:check`** before claiming any task done — CONTRIBUTING.md / AGENTS.md "Testing".
- **CHANGELOG**: alpha-5 is tagged (`v0.1.0.pre.alpha.5` exists in `git tag`), so `## 0.1.0-alpha.5` is a shipped section, not the unreleased one. Add a new `## Unreleased` heading above it (CHANGELOG.md currently has none) and log every user-visible-enough change there, `[INTERNAL]`-tagged (pure perf, no behavior change).

---

## File Structure

| File | Responsibility |
| --- | --- |
| `lib/axn/core/contract/validator_class_cache.rb` (new) | Item 1: per-class `{[config, coerce] => compiled validator class}` table, identity-keyed. |
| `lib/axn/core/contract.rb` (modify) | `require` + `include ValidatorClassCache` into `ClassMethods`; add cached `_model_fields`; memoize `_declared_fields`. |
| `lib/axn/core/executor.rb` (modify) | Both `Fields.collect_errors` call sites (`validate_contract!` outbound, `_collect_contract_failures` inbound) route through the new cache instead of building a fresh class every call. |
| `lib/axn/core/validation/fields.rb` (modify) | Remove `collect_errors` (dead once both callers are moved) and refresh the doc comments that describe who uses the reuse hook. |
| `lib/axn/core/context/facade.rb` (modify) | `_model_fields` delegates to the new per-class cached method instead of rebuilding the Hash on every reader definition. |
| `lib/axn/internal/call_logger.rb` (modify) | Item 2: early-return from `log_at_level` when the configured logger's own severity predicate (`info?`/`warn?`/…) says it wouldn't emit. |
| `spec/axn/core/validations/validator_class_cache_spec.rb` (new) | Item 1's cache: hit/miss, coerce-axis, redeclaration invalidation, subclass isolation, Mountable/Factory-rebuilt-class isolation, and (regression-critical) confirms the 6 previously-broken examples still pass. |
| `spec/axn/core/context/model_fields_cache_spec.rb` (new) | Item 3a: `_model_fields` cache hit/miss + redeclaration invalidation. |
| `spec/axn/core/contract_declared_fields_cache_spec.rb` (new) | Item 3b: `_declared_fields` cache hit/miss + redeclaration invalidation, both directions. |
| `spec/axn/internal/call_logger_spec.rb` (new) | Item 2: logger-level laziness — a logger reporting `info?: false` short-circuits before context is built. |
| `CHANGELOG.md` (modify) | New `## Unreleased` section, `[INTERNAL]` entries. |

No file is restructured beyond these additions — `contract.rb`/`executor.rb` stay the size they are; the new cache is its own small file (mirrors `redaction.rb` being its own file rather than living inline in `contract.rb`).

---

## Task 1: Validator-class cache (item 1 — the correctness-sensitive one)

**Files:**
- Create: `lib/axn/core/contract/validator_class_cache.rb`
- Modify: `lib/axn/core/contract.rb:9` (require), `lib/axn/core/contract.rb:366-367` (include)
- Modify: `lib/axn/core/executor.rb:1050-1061` (outbound), `lib/axn/core/executor.rb:1131-1148` (inbound)
- Modify: `lib/axn/core/validation/fields.rb:8-11,47-54,56-58` (drop `collect_errors`, refresh comments)
- Test: `spec/axn/core/validations/validator_class_cache_spec.rb`

**Interfaces:**
- Consumes: `internal_field_configs`, `external_field_configs`, `subfield_configs` (existing copy-on-write `class_attribute`s on the action class); `Axn::Validation::Fields.validator_class_for(field:, validations:)` / `.errors_for(validator_class, source:, validations:, action:, reader:, config:, permit_method_call:)` (existing, unchanged).
- Produces: `ActionClass._cached_validator_class_for(config:, effective_validations:, coerce:)` → a `Class` (the compiled one-off validator). Public class method (cross-file caller: `Executor`), like `_declared_fields`/`_resolved_subfields`.

- [ ] **Step 1: Write the failing spec for the cache's hit/miss/invalidation semantics**

```ruby
# spec/axn/core/validations/validator_class_cache_spec.rb
# frozen_string_literal: true

RSpec.describe "validator class cache" do
  it "reuses the same compiled validator class across two calls with the same config" do
    action = build_axn { expects :name, type: String }
    config = action.internal_field_configs.first

    first = action._cached_validator_class_for(config:, effective_validations: config.validations, coerce: false)
    second = action._cached_validator_class_for(config:, effective_validations: config.validations, coerce: false)

    expect(first).to be(second)
  end

  it "builds a distinct class per coerce state for the same config" do
    action = build_axn { expects :name, type: String }
    config = action.internal_field_configs.first

    off = action._cached_validator_class_for(config:, effective_validations: config.validations, coerce: false)
    on = action._cached_validator_class_for(config:, effective_validations: config.validations.merge(type: { klass: String, coerce: true }), coerce: true)

    expect(off).not_to be(on)
  end

  it "does not reuse a class across two distinct FieldConfigs for the same field name" do
    first_class = build_axn { expects :name, type: String }
    second_class = build_axn { expects :name, type: Integer }
    first_config = first_class.internal_field_configs.first
    second_config = second_class.internal_field_configs.first

    first_built = first_class._cached_validator_class_for(config: first_config, effective_validations: first_config.validations, coerce: false)
    second_built = second_class._cached_validator_class_for(config: second_config, effective_validations: second_config.validations, coerce: false)

    expect(first_built).not_to be(second_built)
  end

  it "invalidates when the class redeclares the field" do
    action = build_axn { expects :name, type: String }
    original_config = action.internal_field_configs.first
    original_class = action._cached_validator_class_for(config: original_config, effective_validations: original_config.validations, coerce: false)

    # Simulate Mountable/a downstream gem replacing the array wholesale (identity-keyed caching relies
    # on replacement — see contract.rb's comment on `self.internal_field_configs =`).
    action.internal_field_configs = [original_config].freeze
    rebuilt_class = action._cached_validator_class_for(config: original_config, effective_validations: original_config.validations, coerce: false)

    expect(rebuilt_class).not_to be(original_class)
  end

  it "gives a subclass its own cache rather than inheriting the parent's" do
    parent = build_axn { expects :name, type: String }
    child = Class.new(parent)
    parent_config = parent.internal_field_configs.first
    child_config = child.internal_field_configs.first

    parent_built = parent._cached_validator_class_for(config: parent_config, effective_validations: parent_config.validations, coerce: false)
    child_built = child._cached_validator_class_for(config: child_config, effective_validations: child_config.validations, coerce: false)

    expect(parent_built).not_to be(child_built)
  end
end
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `bundle exec rspec spec/axn/core/validations/validator_class_cache_spec.rb`
Expected: `NoMethodError: undefined method '_cached_validator_class_for'` on every example.

- [ ] **Step 3: Implement the cache module**

```ruby
# lib/axn/core/contract/validator_class_cache.rb
# frozen_string_literal: true

module Axn
  module Core
    module Contract
      # Per-class cache of the one-off validator classes `Axn::Validation::Fields.validator_class_for`
      # would otherwise compile fresh on every `.call` for every declared top-level field and subfield
      # (PRO-3050). Mirrors `Redaction#_contract_redaction` exactly: outer key is `equal?` on the three
      # copy-on-write config arrays (self-invalidating on any redeclaration, subclass, or
      # Mountable/Factory rebuild — see redaction.rb's doctrine comment, which this reuses verbatim),
      # inner key is the `FieldConfig`/`ShapeConfig` object's own IDENTITY.
      #
      # Identity, never `validations`: a config's `#validations` is not a stable object across reads.
      # `Executor#_with_effective_coerce` mints a fresh merged Hash every call when `coerce_input_types`
      # resolves on, and a config reached only via `internal_field_configs=`/`subfield_configs=` (never
      # declared) can answer a DIFFERENT Hash on every `#validations` read (stored_shape_traversal_spec's
      # generative member) — keying on either would never hit, or worse, would grow the table forever.
      # The config object itself has neither problem: it is a frozen `Data`, minted once and replaced
      # wholesale on redeclaration, never mutated.
      #
      # The SAME config can legitimately need two different compiled classes in one process — the
      # `coerce_input_types` gate is per-call/per-class/global and can flip between calls — so the inner
      # table is keyed on [config, coerce] rather than on config alone.
      module ValidatorClassCache
        def _validator_class_cache
          internals = internal_field_configs
          externals = external_field_configs
          subfields = subfield_configs
          memo = @_axn_validator_class_cache
          return memo if memo&.current?(internals, externals, subfields)

          @_axn_validator_class_cache = ValidatorClassCacheTable.new(internals:, externals:, subfields:)
        end

        # The compiled validator class for one config under one coerce state, built once per class per
        # (config, coerce) pair and reused across every `.call`. `effective_validations` is the caller's
        # already-resolved Hash (with `_with_effective_coerce` applied if relevant) — computed by the
        # caller regardless of hit/miss, same as before this cache existed, so a hit only saves the
        # `Class.new` + `validates` compilation, not the coerce merge.
        def _cached_validator_class_for(config:, effective_validations:, coerce:)
          _validator_class_cache.fetch(config:, coerce:) do
            Axn::Validation::Fields.validator_class_for(field: config.field, validations: effective_validations)
          end
        end
      end

      # The table `_validator_class_cache` hands out. Mutable (so not a `Data`), one Hash slot written
      # once per (config, coerce) pair. `||=` is safe here (unlike `_contract_redaction`'s `dynamic`
      # flag): a compiled Class is always truthy, so there is no false/nil tri-state to guard.
      class ValidatorClassCacheTable
        def initialize(internals:, externals:, subfields:)
          @internals = internals
          @externals = externals
          @subfields = subfields
          # Per config, by identity — a FieldConfig/ShapeConfig defines no `hash`/`eql?` axn would want
          # to run (its `validations` Hash may hold a caller-supplied option container that does), and
          # identity is the right question anyway: the stored config is the one axn built.
          @classes = {}.compare_by_identity
        end

        def current?(internals, externals, subfields)
          @internals.equal?(internals) && @externals.equal?(externals) && @subfields.equal?(subfields)
        end

        def fetch(config:, coerce:)
          by_coerce = (@classes[config] ||= {})
          by_coerce[coerce] ||= yield
        end
      end
    end
  end
end
```

- [ ] **Step 4: Wire it into `Contract`**

In `lib/axn/core/contract.rb:9`, add beside the existing `redaction` require:

```ruby
require "axn/core/contract/redaction"
require "axn/core/contract/validator_class_cache"
```

In `lib/axn/core/contract.rb`'s `ClassMethods` (around line 366-367):

```ruby
        include ShapeDeclaration
        include Redaction
        include ValidatorClassCache
```

`_cached_validator_class_for` and `_validator_class_cache` must stay **public** (not moved under the `private` call at contract.rb:554) — `Executor` calls `_cached_validator_class_for` on `@action_class` from another file, the same reason `_declared_fields`/`_resolved_subfields` stay public. Add both names to the doctrine comment at contract.rb:552-553 that lists the public exceptions.

- [ ] **Step 5: Run the new spec — confirm it passes**

Run: `bundle exec rspec spec/axn/core/validations/validator_class_cache_spec.rb`
Expected: 5 examples, 0 failures.

- [ ] **Step 6: Wire the cache into the two real call sites — outbound first**

In `lib/axn/core/executor.rb`, replace `validate_contract!`'s outbound branch (currently lines 1055-1059):

```ruby
        failures = @action_class.send(:external_field_configs).filter_map do |config|
          validator_class = @action_class._cached_validator_class_for(config:, effective_validations: config.validations, coerce: false)
          errors = Axn::Validation::Fields.errors_for(validator_class, source: @action.result, validations: config.validations, action: @action,
                                                       permit_method_call: true)
          ContractFailure.new(config:, path: nil, errors:, stranded_at: nil) if errors.any?
        end
```

(`coerce: false` because `exposes` already rejects `coerce:` outright — "coerce: is not supported on exposes" — so outbound has no coerce axis; passing a constant `false` just gives it its own cache slot, distinct from any inbound use of the same field name in a different config.)

- [ ] **Step 7: Wire the cache into `_collect_contract_failures` (inbound)**

Replace `_collect_contract_failures` (currently lines 1131-1148):

```ruby
      def _collect_contract_failures
        coerce_input_types = _coerce_input_types?

        _inbound_configs.filter_map do |config|
          effective_validations = coerce_input_types ? _with_effective_coerce(config.validations) : config.validations
          validator_class = @action_class._cached_validator_class_for(config:, effective_validations:, coerce: coerce_input_types)
          errors = Axn::Validation::Fields.errors_for(
            validator_class,
            source: config.subfield? ? _resolved_parent_value(config) : @action.internal_context,
            validations: effective_validations,
            action: @action,
            reader: config.subfield? ? config.reader_as : nil,
            config: config.subfield? ? config : nil,
            permit_method_call: true,
          )
          next if errors.empty?

          path = _resolved_path_for(config)
          ContractFailure.new(config:, path:, errors:, stranded_at: path && _stranded_ancestor_path(path, config))
        end
      end
```

This preserves every existing runtime kwarg to `errors_for` exactly (`config:`/`reader:` still nil for a non-subfield, `permit_method_call: true` as `collect_errors` always passed) — only the validator class itself now comes from the cache instead of a fresh `Class.new` per call.

- [ ] **Step 8: Remove the now-dead `collect_errors` and refresh the surrounding comments**

In `lib/axn/core/validation/fields.rb`, delete the `collect_errors` method (lines 47-54) — confirm first that nothing else calls it:

Run: `grep -rn "Fields.collect_errors\|\.collect_errors(" lib/ spec/ spec_rails/`
Expected: no matches after this change (only the two executor.rb call sites you just replaced, and they're gone).

Update the class-level doc comment (lines 8-11) and the `validator_class_for` comment (lines 56-58) to say the top-level field path caches through `Contract::ValidatorClassCache` now too, not only `ShapeValidator`:

```ruby
    # THE one-off validator collector, for every declared config at every level: a top-level field
    # validates against the context facade (which resolves model records and reads by wire key), a
    # subfield against its canonically-resolved parent value. One (field, validations) pair per
    # one-off class. The top-level/subfield path (Executor) and ShapeValidator both cache the compiled
    # class and reuse it across calls/sources — see Contract::ValidatorClassCache and
    # ShapeValidator#member_validator_classes respectively; raising/settling is the caller's concern
    # (see Executor#_validate_inbound!).
```

```ruby
      # Builds the one-off validator class for a (field, validations) pair. Every caller that validates
      # the same contract repeatedly builds this ONCE and reuses it across sources via .errors_for:
      # Contract::ValidatorClassCache for a top-level field/subfield (keyed on the FieldConfig's
      # identity), ShapeValidator for a shape member (keyed on the member's field name, scoped to one
      # compiled parent class).
```

- [ ] **Step 9: Run the full validation + executor spec suites**

Run: `bundle exec rspec spec/axn/core/validations/ spec/axn/core/executor_spec.rb spec/axn/core/contract_spec.rb`
Expected: all green, no new failures.

- [ ] **Step 10: Prove the previously-broken 6 examples still pass**

Run: `bundle exec rspec spec/axn/core/validations/option_bag_keys_spec.rb spec/axn/core/validations/property_name_collision_spec.rb spec/axn/core/validations/stored_shape_traversal_spec.rb`
Expected: all green. If anything fails, re-read the failing example against the "Global Constraints" section above before changing anything — these three files encode exactly the three hazards this design was chosen to avoid.

- [ ] **Step 11: Run the whole non-Rails suite plus `spec_rails`**

Run: `bundle exec rspec`
Run: `cd spec_rails/dummy_app && BUNDLE_GEMFILE=Gemfile bundle exec rspec ../../ && cd -` (per AGENTS.md's `project_axn_run_spec_rails` note — `spec_rails` needs the dummy app's own bundle, not the root one).
Expected: all green.

- [ ] **Step 12: Commit**

```bash
git add lib/axn/core/contract/validator_class_cache.rb lib/axn/core/contract.rb lib/axn/core/executor.rb lib/axn/core/validation/fields.rb spec/axn/core/validations/validator_class_cache_spec.rb
git commit -m "PRO-3050: cache the one-off contract validator class per FieldConfig identity"
```

---

## Task 2: Logger-level laziness (item 2)

**Files:**
- Modify: `lib/axn/internal/call_logger.rb:34-48` (add early return), around line 94 (`private` section)
- Test: `spec/axn/internal/call_logger_spec.rb`

**Interfaces:**
- Consumes: `Axn.config.logger` (existing config accessor); the logger's own severity predicate methods (`debug?`/`info?`/`warn?`/`error?`/`fatal?`) — the same ones Ruby's stdlib `Logger` and `SemanticLogger::Logger` already define.
- Produces: `Axn::Internal::CallLogger.would_log?(level)` — `true`/`false`. `log_at_level` returns early (before `Axn::Extensions.best_effort` — before building any context) when it's `false`.

This is a narrower, safer fix than literally switching to `logger.info { msg }` block form: that would silently DROP a message for any custom logger whose `info`/`warn`/etc. methods take a positional argument only and ignore a block passed alongside it (Ruby doesn't error when a block is passed to a method that doesn't declare one — it's just unused). A severity-predicate pre-check achieves the same "pay nothing when the level is off" property without changing how the message is ultimately delivered, so a non-conforming custom logger loses nothing (falls back to "assume it would log," i.e. today's behavior).

- [ ] **Step 1: Write the failing spec**

```ruby
# spec/axn/internal/call_logger_spec.rb
# frozen_string_literal: true

RSpec.describe Axn::Internal::CallLogger do
  describe "#would_log?" do
    it "asks the configured logger's own severity predicate" do
      logger = instance_double(Logger, info?: false)
      allow(Axn.config).to receive(:logger).and_return(logger)

      expect(described_class.would_log?(:info)).to be(false)
    end

    it "assumes yes when the logger doesn't expose a severity predicate" do
      logger = double("bare logger") # rubocop:disable RSpec/VerifiedDoubles -- deliberately non-conforming
      allow(Axn.config).to receive(:logger).and_return(logger)

      expect(described_class.would_log?(:info)).to be(true)
    end
  end

  describe "#log_at_level" do
    it "skips building the log context entirely when the logger reports the level disabled" do
      logger = instance_double(Logger, info?: false)
      allow(Axn.config).to receive(:logger).and_return(logger)
      action_class = build_axn { expects :name; def call; end }

      expect(described_class).not_to receive(:format_context)
      expect(action_class).not_to receive(:info)

      action_class.call(name: "x")
    end
  end
end
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `bundle exec rspec spec/axn/internal/call_logger_spec.rb`
Expected: `NoMethodError: undefined method 'would_log?'` (first two examples); third example fails because `action_class.info`/`format_context` ARE still called today.

- [ ] **Step 3: Implement `would_log?` and wire it into `log_at_level`**

In `lib/axn/internal/call_logger.rb`, change the top of `log_at_level` (currently line 48, `return unless level`):

```ruby
        return unless level
        return unless would_log?(level)

        Axn::Extensions.best_effort(error_context, action: action_class) do
```

And add the predicate near `semantic_logger?` (which is already `public` for the same cross-call reason — the Executor gates on it too):

```ruby
      # Whether the configured logger would actually emit at `level`, read via the logger's OWN
      # severity predicate (`debug?`/`info?`/`warn?`/`error?`/`fatal?` — the same query Ruby's stdlib
      # `Logger` and `SemanticLogger::Logger` already expose). A logger that doesn't respond to the
      # predicate is assumed to emit, which matches today's behavior exactly — a custom logger
      # implementing only the plain level methods loses nothing. Public: the Executor's before/after
      # hooks are the only callers, from another file, same as `semantic_logger?`.
      def would_log?(level)
        logger = Axn.config.logger
        predicate = :"#{level}?"
        !logger.respond_to?(predicate) || logger.public_send(predicate)
      end
```

- [ ] **Step 4: Run the spec — confirm it passes**

Run: `bundle exec rspec spec/axn/internal/call_logger_spec.rb`
Expected: 3 examples, 0 failures.

- [ ] **Step 5: Run the full logging-adjacent suites**

Run: `bundle exec rspec spec/axn/core/automatic_logging_spec.rb spec/axn/internal/call_logger_facets_spec.rb spec/axn/extensions_spec.rb spec/axn/self_referential_values_spec.rb spec/axn/aborted_runs_spec.rb`
Expected: all green — the test-env logger (`Logger.new(File::NULL)`, default level `DEBUG`) answers every `<level>?` predicate `true`, so nothing before this change changes behavior for any spec that doesn't override `Axn.config.logger`.

- [ ] **Step 6: Run the whole suite**

Run: `bundle exec rspec`
Expected: all green.

- [ ] **Step 7: Commit**

```bash
git add lib/axn/internal/call_logger.rb spec/axn/internal/call_logger_spec.rb
git commit -m "PRO-3050: skip building the auto_log payload when the logger's own level is off"
```

---

## Task 3: Per-class `_model_fields` and `_declared_fields` caches (item 3)

**Files:**
- Modify: `lib/axn/core/contract.rb` (add cached `_model_fields` near `_declared_fields`, memoize `_declared_fields`)
- Modify: `lib/axn/core/context/facade.rb:46-50`
- Test: `spec/axn/core/context/model_fields_cache_spec.rb`, `spec/axn/core/contract_declared_fields_cache_spec.rb`

**Interfaces:**
- Consumes: `internal_field_configs`, `external_field_configs` (existing).
- Produces: `ActionClass._model_fields` → `{field_symbol => model_options}` Hash (moved from `ContextFacade#_model_fields`, now class-level and cached). `ActionClass._declared_fields(direction)` keeps its existing signature/return shape (`Array<Symbol>`) — only its body gets memoized, callers are unaffected.

- [ ] **Step 1: Write the failing spec for `_model_fields`**

```ruby
# spec/axn/core/context/model_fields_cache_spec.rb
# frozen_string_literal: true

RSpec.describe "_model_fields cache" do
  it "returns the same Hash object across calls when the contract hasn't changed" do
    action = build_axn { expects :company, model: { klass: -> { Struct.new(:id) } } }

    first = action._model_fields
    second = action._model_fields

    expect(first).to equal(second)
  end

  it "rebuilds after the class redeclares a field" do
    action = build_axn { expects :company, model: { klass: -> { Struct.new(:id) } } }
    first = action._model_fields

    action.internal_field_configs = action.internal_field_configs.dup.freeze
    second = action._model_fields

    expect(second).not_to equal(first)
    expect(second).to eq(first) # same content, new object — the array identity changed, the fact didn't
  end

  it "gives a subclass its own cache rather than inheriting the parent's cached Hash" do
    parent = build_axn { expects :company, model: { klass: -> { Struct.new(:id) } } }
    child = Class.new(parent)

    expect(child._model_fields).not_to equal(parent._model_fields)
    expect(child._model_fields).to eq(parent._model_fields)
  end
end
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `bundle exec rspec spec/axn/core/context/model_fields_cache_spec.rb`
Expected: `NoMethodError: undefined method '_model_fields'` on the action CLASS (today it only exists as a private instance method on `ContextFacade`).

- [ ] **Step 3: Implement the class-level cache in `contract.rb`**

Add a `Data` cache-entry type near `_declared_fields` (contract.rb, in `ClassMethods`, before the `private` at line 554):

```ruby
        ModelFieldsCacheEntry = Data.define(:internal_field_configs, :value)

        # Field => model options for every internal field carrying `model:`, cached per class: a pure
        # function of `internal_field_configs`, rebuilt only when that array's identity changes (any
        # redeclaration, subclass, or Mountable/Factory rebuild — see Redaction's doctrine comment).
        # Moved here from the context facade instance (was rebuilt from scratch on every reader
        # definition — O(fields defined × contract size) per action instance, since both the outbound
        # Result facade and the inbound InternalContext facade instantiate one per call).
        def _model_fields
          fields = internal_field_configs
          cached = @_axn_model_fields
          return cached.value if cached && cached.internal_field_configs.equal?(fields)

          value = fields.each_with_object({}) { |config, hash| hash[config.field] = config.validations[:model] if config.validations.key?(:model) }
          @_axn_model_fields = ModelFieldsCacheEntry.new(internal_field_configs: fields, value:)
          value
        end
```

- [ ] **Step 4: Run the spec — confirm it passes**

Run: `bundle exec rspec spec/axn/core/context/model_fields_cache_spec.rb`
Expected: 3 examples, 0 failures.

- [ ] **Step 5: Point the context facade at the new cache**

In `lib/axn/core/context/facade.rb`, replace the `_model_fields` instance method (currently lines 46-50):

```ruby
      def _model_fields = action.class._model_fields
```

(Delete the old body — the class-level cached version is a drop-in replacement: same field set, same values, `action.internal_field_configs` and `action.class.internal_field_configs` already read the same `class_attribute`.)

- [ ] **Step 6: Write the failing spec for `_declared_fields`**

```ruby
# spec/axn/core/contract_declared_fields_cache_spec.rb
# frozen_string_literal: true

RSpec.describe "_declared_fields cache" do
  it "returns the same Array object across calls for the same direction" do
    action = build_axn { expects :name; exposes :greeting }

    expect(action._declared_fields(:inbound)).to equal(action._declared_fields(:inbound))
    expect(action._declared_fields(:outbound)).to equal(action._declared_fields(:outbound))
    expect(action._declared_fields(nil)).to equal(action._declared_fields(nil))
  end

  it "still returns the correct fields per direction" do
    action = build_axn { expects :name; exposes :greeting }

    expect(action._declared_fields(:inbound)).to eq([:name])
    expect(action._declared_fields(:outbound)).to eq([:greeting])
    expect(action._declared_fields(nil)).to contain_exactly(:name, :greeting)
  end

  it "rebuilds (new object, same content) after redeclaration" do
    action = build_axn { expects :name }
    first = action._declared_fields(:inbound)

    action.internal_field_configs = action.internal_field_configs.dup.freeze
    second = action._declared_fields(:inbound)

    expect(second).not_to equal(first)
    expect(second).to eq(first)
  end

  it "still raises for an invalid direction" do
    action = build_axn { expects :name }

    expect { action._declared_fields(:sideways) }.to raise_error(ArgumentError, /Invalid direction/)
  end
end
```

- [ ] **Step 7: Run it to confirm it fails**

Run: `bundle exec rspec spec/axn/core/contract_declared_fields_cache_spec.rb`
Expected: the `equal?` examples fail (today's `configs.map(&:field)` allocates a fresh Array every call); the content/error examples already pass (existing behavior).

- [ ] **Step 8: Memoize `_declared_fields`**

Replace `_declared_fields` in `contract.rb` (currently lines 537-548):

```ruby
        DeclaredFieldsCacheEntry = Data.define(:internal_field_configs, :external_field_configs, :fields)

        # `configs.map(&:field)` was a fresh Array on every call — `redaction.rb`'s `_context_slice`
        # alone calls this twice per logged line (inbound + outbound), and the context facade calls it
        # twice per action call. Cached per direction, invalidated by the identity of WHICHEVER config
        # arrays that direction depends on; tracking both arrays for every direction (rather than only
        # the one a given direction reads) is simpler and only means an outbound-only redeclaration
        # occasionally invalidates the (unaffected) :inbound slot too — never a wrong answer, just an
        # occasional avoidable rebuild.
        def _declared_fields(direction)
          raise ArgumentError, "Invalid direction: #{direction}" unless direction.nil? || %i[inbound outbound].include?(direction)

          internals = internal_field_configs
          externals = external_field_configs
          cache = (@_axn_declared_fields_cache ||= {})
          cached = cache[direction]
          return cached.fields if cached && cached.internal_field_configs.equal?(internals) && cached.external_field_configs.equal?(externals)

          configs = case direction
                    when :inbound then internals
                    when :outbound then externals
                    else (internals + externals)
                    end

          cache[direction] = DeclaredFieldsCacheEntry.new(internal_field_configs: internals, external_field_configs: externals, fields: configs.map(&:field))
          cache[direction].fields
        end
```

- [ ] **Step 9: Run the spec — confirm it passes**

Run: `bundle exec rspec spec/axn/core/contract_declared_fields_cache_spec.rb`
Expected: 4 examples, 0 failures.

- [ ] **Step 10: Run the broader contract/facade/redaction/mountable suites**

Run: `bundle exec rspec spec/axn/core/contract_spec.rb spec/axn/core/context/ spec/axn/core/validations/ spec/axn/mountable/ spec/axn/core/redaction_spec.rb`
(adjust paths to whatever the actual redaction/facade spec files are named if these globs miss — `grep -rl "_context_slice\|inputs_for_logging" spec/` to find them if so)
Expected: all green.

- [ ] **Step 11: Run the whole suite plus `spec_rails`**

Run: `bundle exec rspec`
Run: `cd spec_rails/dummy_app && BUNDLE_GEMFILE=Gemfile bundle exec rspec ../../ && cd -`
Expected: all green.

- [ ] **Step 12: Commit**

```bash
git add lib/axn/core/contract.rb lib/axn/core/context/facade.rb spec/axn/core/context/model_fields_cache_spec.rb spec/axn/core/contract_declared_fields_cache_spec.rb
git commit -m "PRO-3050: cache _model_fields and _declared_fields per class"
```

---

## Task 4: Benchmark, CHANGELOG, PR

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: A/B the `basic` benchmark scenario against `main`**

Run (from AGENTS.md's methodology section — each side from its OWN checkout):

```bash
git worktree add -f --detach /tmp/axn-pro3050-baseline main
(cd /tmp/axn-pro3050-baseline && bundle install --quiet && BUNDLE_GEMFILE=/tmp/axn-pro3050-baseline/Gemfile bundle exec rake benchmark:check 2>&1 | tee /tmp/axn-pro3050-baseline.out)
BUNDLE_GEMFILE=Gemfile bundle exec rake benchmark:check 2>&1 | tee /tmp/axn-pro3050-after.out
diff /tmp/axn-pro3050-baseline.out /tmp/axn-pro3050-after.out
git worktree remove --force /tmp/axn-pro3050-baseline
```

Expected: the `basic` scenario's objects/call drops from alpha-5's ~506 (or ~488 with the dotless-read fix already on `main`) toward the ticket's ~256-per-call prototype figure — record the actual number, don't assume it hits exactly 256 (items 2/3 weren't in the prototype's number, and item 4 is explicitly out of scope). If a scenario regresses instead, stop and diagnose before continuing — CONTRIBUTING.md's gate exists precisely to catch this before release, and `rake benchmark:accept` is only for a reviewed, deliberate regression, never a default response to a red gate.

- [ ] **Step 2: Add the CHANGELOG entry**

`CHANGELOG.md` has no `## Unreleased` heading yet (alpha-5 is tagged: `v0.1.0.pre.alpha.5`). Add one above `## 0.1.0-alpha.5`:

```markdown
# Changelog

## Unreleased

### Performance

* [INTERNAL] The one-off ActiveModel validator class for a declared field/subfield is now compiled once per class and reused across every `.call`, instead of being recompiled (and its ActiveModel validator machinery re-instantiated) on every call. `auto_log` no longer builds its before/after payload when the configured logger's own severity level would discard it. `_model_fields` and `_declared_fields` are now cached per class instead of being rebuilt from the full contract on every reader definition / every read. Recovers roughly half of alpha-5's per-call allocation increase on the `basic` benchmark scenario (see PRO-3050 for the measured before/after).

## 0.1.0-alpha.5
```

- [ ] **Step 3: Final full verification**

Run: `bundle exec rspec`
Run: `cd spec_rails/dummy_app && BUNDLE_GEMFILE=Gemfile bundle exec rspec ../../ && cd -`
Run: `bundle exec rubocop lib/axn/core/contract/validator_class_cache.rb lib/axn/core/contract.rb lib/axn/core/executor.rb lib/axn/core/validation/fields.rb lib/axn/core/context/facade.rb lib/axn/internal/call_logger.rb`
Expected: all green, zero offenses.

- [ ] **Step 4: Commit the CHANGELOG**

```bash
git add CHANGELOG.md
git commit -m "PRO-3050: changelog entry for the low-hanging perf fixes"
```

- [ ] **Step 5: Push and open the PR**

```bash
git push -u origin kali/pro-3050-axn-low-hanging-performance-improvements
gh pr create --title "PRO-3050: low-hanging performance improvements" --body "$(cat <<'EOF'
## Summary
- Cache the one-off contract validator class per `FieldConfig`/`ShapeConfig` identity instead of recompiling it on every `.call` (the ticket's item 1 — the one with the correctness surface: keyed on config *identity*, never on `validations` content, per the prototype's 6-example breakage).
- Skip building `auto_log`'s before/after payload when the configured logger's own severity level would discard it anyway (item 2).
- Cache `_model_fields` and `_declared_fields` per class instead of rebuilding them from the full contract on every reader definition / every read (item 3).
- Item 4 (redesigning the context facade to define readers once per class) is left out per the ticket's explicit scope.

https://linear.app/teamshares/issue/PRO-3050/axn-low-hanging-performance-improvements

## Test plan
- [ ] Confirm the `basic` benchmark scenario's objects/call dropped and no scenario regressed (see the A/B numbers in the PR description below, filled in from Task 4 Step 1).
EOF
)"
```

---

## Self-Review Notes

- **Spec coverage**: item 1 → Task 1; item 2 → Task 2; item 3 → Task 3; item 4 → explicitly out of scope per the ticket, not a gap. The ticket's own risk checklist (config-identity not `[field, validations]`, leave ShapeValidator's member path alone, check per-config-object vs per-action-class, check Mountable mid-process rewrite) is covered by Task 1's design (per-class table, `equal?`-keyed on the three arrays) and its subclass/redeclaration/coerce-axis spec examples.
- **Placeholder scan**: no TBD/"handle edge cases"/"similar to Task N" — every step has real code.
- **Type consistency**: `_cached_validator_class_for(config:, effective_validations:, coerce:)` is defined once in Task 1 Step 3 and called identically in Task 1 Steps 6–7; `_model_fields`/`_declared_fields` signatures in Task 3 match their existing callers (`ContextFacade`, `Redaction#_context_slice`, `Mountable::MountingStrategies::Step`) with no signature change, only memoization added.
