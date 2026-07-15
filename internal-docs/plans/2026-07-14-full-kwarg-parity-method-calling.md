# Full kwarg parity for method-calling expectations (PRO-2903) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `preprocess:`/`coerce:` compose with `method_call:` subfields, then move *all* subfield `coerce:`/`preprocess:`/`default:` resolution onto the read path and delete the subfield write-back apparatus.

**Architecture:** Subfield values resolve through `ContractForSubfields.resolve_value` (the shared reader + validation path). PRO-2889 already put subfield `default:` there as value-level, non-materializing resolution. This plan extends that model to `coerce:`/`preprocess:` and removes the redundant pre-validation write-back passes for subfields. Top-level fields keep their write-back (they read `provided_data` directly with no `resolve_value` indirection — see follow-up PRO-2908).

**Tech Stack:** Ruby, RSpec. Non-Rails `spec/` (guard AR/Rails constants with `defined?`). Run specs with `bundle exec rspec`.

## Global Constraints

- Comments describe *current* behavior + intrinsic why — never "used to X / now Y" or "(PRO-nnnn review)". (repo convention)
- Reflection stays side-effect-free; this work is on the execution path, not reflection.
- axn must work outside Rails: `spec/` is non-Rails.
- Shared logic is single-sourced so the write-back path and the read path can't drift (mirrors how `Internal::FieldConfig.resolve_default` single-sources defaults).
- Commit only when the user asks; this plan's `git commit` steps are the natural commit points, and the branch is not `gitbutler/worktree`, so `git commit` is fine.
- Two git commits, one PR: Commit 1 = Tasks 1–5 (method_call parity, non-breaking). Commit 2 = Tasks 6–9 (flip all subfields to read path, delete write-back, `[BREAKING]`).

---

## Files

- Modify: `lib/axn/reflection/coercion.rb` — add `field_coerces?` + `coerce_config_value` shared helpers.
- Modify: `lib/axn/internal/field_config.rb` — add `resolve_preprocess` shared helper.
- Modify: `lib/axn/core/contract_for_subfields.rb` — `resolution_crosses_method_call?` predicate; read-path transforms in `resolve_value`.
- Modify: `lib/axn/executor.rb` — route write-back through shared helpers; delegate the crossing predicate; (Commit 2) make passes top-level-only and delete the materialization apparatus.
- Modify: `spec/axn/core/method_call_spec.rb` — rewrite the "inert" block + coerce_input_types examples to assert composition.
- Modify: `spec/axn/core/subfield_write_back_matrix_spec.rb` — (Commit 2) rewrite the 4 parent-materialization examples.
- Modify: `docs/reference/class.md`, `CHANGELOG.md` — remove "inert/planned" notes; add composition + `[BREAKING]` entries.

---

# COMMIT 1 — read-path parity for method-call-crossing subfields

## Task 1: Shared coercion helpers

**Files:**
- Modify: `lib/axn/reflection/coercion.rb`
- Modify: `lib/axn/executor.rb:437-462` (`apply_inbound_coercion!`, `coerce_field_inbound?`)

**Interfaces:**
- Produces: `Axn::Reflection::Coercion.field_coerces?(type_opt, coerce_input_types) -> Boolean`; `Axn::Reflection::Coercion.coerce_config_value(value, config, coerce_input_types:) -> value` (coerced or original).

- [ ] **Step 1: Add the helpers** to `lib/axn/reflection/coercion.rb`, after `coercible_klasses`:

```ruby
# Whether a field coerces this run: its own `coerce:` tri-state wins (explicit true/false), else the
# resolved coerce_input_types flag. Single-sourced so the write-back pass and the read path
# (ContractForSubfields.resolve_value) decide identically.
def field_coerces?(type_opt, coerce_input_types)
  explicit = type_opt.is_a?(Hash) ? type_opt[:coerce] : nil
  explicit.nil? ? coerce_input_types : explicit
end

# Coerce a config's value when the field has ≥1 coercible member AND opts in (field_coerces?);
# otherwise return it untouched. The one place both the write-back coercion pass and the read path
# decide-and-coerce, so they can't drift.
def coerce_config_value(value, config, coerce_input_types:)
  type_opt = config.validations[:type]
  klasses = coercible_klasses(type_opt)
  return value if klasses.empty?
  return value unless field_coerces?(type_opt, coerce_input_types)

  coerce_value(value, klasses)
end
```

- [ ] **Step 2: Route the write-back pass through the helper.** Replace `apply_inbound_coercion!` body (executor.rb:437-453) and delete `coerce_field_inbound?` (455-462):

```ruby
def apply_inbound_coercion!
  coerce_input_types = Axn::Configuration.resolve_override_for(@action_class, :coerce_input_types)

  _inbound_configs.each do |config|
    next if _resolution_crosses_method_call?(config) # method-derived value: resolved on the read path, not coerced here
    next unless (path = _resolved_path_for(config))

    current = _current_value_at(path)
    coerced = Axn::Reflection::Coercion.coerce_config_value(current, config, coerce_input_types:)
    _write_value_at!(path, coerced) unless coerced.equal?(current)
  end
end
```

- [ ] **Step 3: Run coercion + method_call specs** — `bundle exec rspec spec/axn/core/coercion_spec.rb spec/axn/core/method_call_spec.rb`. Expected: all PASS (pure refactor).

- [ ] **Step 4: Run full suite** — `bundle exec rspec`. Expected: all PASS.

- [ ] **Step 5: Commit** — staged with Task 2/3/4 (single Commit 1 at Task 5).

## Task 2: Shared preprocess helper

**Files:**
- Modify: `lib/axn/internal/field_config.rb`
- Modify: `lib/axn/executor.rb:485-508` (`apply_inbound_preprocessing!`)

**Interfaces:**
- Produces: `Axn::Internal::FieldConfig.resolve_preprocess(action, config, value) -> preprocessed value` (raises `ContractViolation::PreprocessingError` on failure).

- [ ] **Step 1: Add the helper** to `lib/axn/internal/field_config.rb`, after `resolve_default`:

```ruby
# Run a config's preprocess proc against an action instance, wrapping failures as
# PreprocessingError. Single source for the write-back pass AND the read-path resolution
# (ContractForSubfields.resolve_value), so the two can't drift on error semantics — mirrors
# resolve_default.
def resolve_preprocess(action, config, value)
  descriptor = config.subfield? ? "subfield '#{config.field}' on '#{config.on}'" : "field '#{config.field}'"
  identifier = config.subfield? ? "#{config.field} on #{config.on}" : config.field
  Axn::Internal::ContractErrorHandling.with_contract_error_handling(
    exception_class: Axn::ContractViolation::PreprocessingError,
    message: ->(_field, error) { "Error preprocessing #{descriptor}: #{error.message}" },
    field_identifier: identifier,
  ) do
    action.instance_exec(value, &config.preprocess)
  end
end
```

- [ ] **Step 2: Route the write-back pass through the helper.** Replace `apply_inbound_preprocessing!` body (executor.rb:485-508):

```ruby
def apply_inbound_preprocessing!
  _inbound_configs.each do |config|
    next unless config.preprocess
    next if _resolution_crosses_method_call?(config)
    next unless (path = _resolved_path_for(config))

    current_value = _current_value_at(path)
    preprocessed_value = Internal::FieldConfig.resolve_preprocess(@action, config, current_value)
    # The write may synthesize missing IMPLICIT intermediates (never the root — a nil root drops
    # the value, see _write_value_at!), so it obeys the same synthesis gate as defaults: an
    # intermediate whose declared types/shape members can't hold an object is not created, and the
    # preprocess result is dropped (nowhere to land).
    _write_value_at!(path, preprocessed_value) if _write_chain_materializable?(path)
  end
end
```

- [ ] **Step 3: Run preprocess + matrix specs** — `bundle exec rspec spec/axn/core/subfield_write_back_matrix_spec.rb spec/axn/core/validations/default_assignment_spec.rb`. Expected: all PASS.

- [ ] **Step 4: Run full suite** — `bundle exec rspec`. Expected: all PASS.

## Task 3: Single-source the method_call-crossing predicate

**Files:**
- Modify: `lib/axn/core/contract_for_subfields.rb`
- Modify: `lib/axn/executor.rb:621-626` (`_resolution_crosses_method_call?`)

**Interfaces:**
- Produces: `Axn::Core::ContractForSubfields.resolution_crosses_method_call?(action, config) -> Boolean`.
- Consumes: `action.class._resolved_subfields.index[config]` → a ResolvedPath with `.ancestors` (array of `[node, seg]`); `node.configs` responds to `.any?(&:method_call)`.

- [ ] **Step 1: Add the module function** to `lib/axn/core/contract_for_subfields.rb` (top-level `module ContractForSubfields`, near `resolve_parent`):

```ruby
# Whether resolving this config's value crosses any method_call hop — the config itself, or any
# ancestor on its chain. A method-derived value is resolved on the READ path (resolve_value),
# never written back into provided_data, so the executor's write-back passes skip such configs and
# resolve_value applies coerce:/preprocess: to the resolved value instead. Single-sourced here so
# the skip and the read-path branch stay exact complements. An unindexed config (ambient) has no
# path, so only its own flag applies.
def self.resolution_crosses_method_call?(action, config)
  return true if config.method_call

  path = action.class._resolved_subfields.index[config]
  return false if path.nil?

  path.ancestors.any? { |node, _seg| node.configs.any?(&:method_call) }
end
```

- [ ] **Step 2: Delegate from the executor.** Replace `_resolution_crosses_method_call?` (executor.rb:621-626) with:

```ruby
def _resolution_crosses_method_call?(config)
  Axn::Core::ContractForSubfields.resolution_crosses_method_call?(@action, config)
end
```

- [ ] **Step 3: Run full suite** — `bundle exec rspec`. Expected: all PASS (pure refactor).

## Task 4: Apply coerce/preprocess on the read path for method-call-crossing subfields

**Files:**
- Modify: `lib/axn/core/contract_for_subfields.rb:85-104` (`resolve_value`)
- Test: `spec/axn/core/method_call_spec.rb`

**Interfaces:**
- Consumes: `Axn::Reflection::Coercion.coerce_config_value` (Task 1), `Axn::Internal::FieldConfig.resolve_preprocess` (Task 2), `resolution_crosses_method_call?` (Task 3).

- [ ] **Step 1: Rewrite the failing tests.** Replace the `describe "preprocess:/coerce: are inert (not yet composed — PRO-2903)"` block (method_call_spec.rb:48-99) with a composition block:

```ruby
describe "preprocess:/coerce: compose on the read path" do
  let(:event_class) do
    Class.new do
      attr_reader :data

      def initialize(data) = (@data = data)
    end
  end

  it "runs preprocess on the resolved (post-dispatch) value" do
    ran = false
    action = build_axn do
      expects :event
      expects :data, on: :event, method_call: true, preprocess: lambda { |v|
        ran = true
        "processed:#{v}"
      }
      exposes :out
      def call = expose(out: data)
    end
    result = action.call(event: event_class.new("raw"))
    expect(result).to be_ok
    expect(ran).to be(true)
    expect(result.out).to eq("processed:raw")
  end

  it "surfaces a PreprocessingError when the proc raises on the resolved value" do
    action = build_axn do
      expects :event
      expects :data, on: :event, method_call: true, preprocess: ->(_v) { raise "boom" }
      exposes :out, allow_nil: true
      def call = expose(out: data)
    end
    Axn.config.instance_variable_set(:@on_exception, nil)
    result = action.call(event: event_class.new("raw"))
    expect(result).not_to be_ok
    expect(result.exception).to be_a(Axn::ContractViolation::PreprocessingError)
  ensure
    Axn.config.instance_variable_set(:@on_exception, nil)
  end

  it "coerces the resolved value (coerce: Integer on a String result)" do
    action = build_axn do
      expects :event
      expects :data, on: :event, method_call: true, coerce: Integer # coerce: sets type: Integer
      exposes :out
      def call = expose(out: data)
    end
    result = action.call(event: event_class.new("42"))
    expect(result).to be_ok
    expect(result.out).to eq(42)
  end

  it "does not mutate the caller's object on the read path" do
    obj = event_class.new("42")
    action = build_axn do
      expects :event
      expects :data, on: :event, method_call: true, coerce: Integer
      exposes :out
      def call = expose(out: data)
    end
    action.call(event: obj)
    expect(obj.data).to eq("42") # the caller's object is untouched
  end
end
```

- [ ] **Step 2: Run to verify they fail** — `bundle exec rspec spec/axn/core/method_call_spec.rb -e "compose on the read path"`. Expected: FAIL (values un-transformed / un-coerced).

- [ ] **Step 3: Implement the read-path branch.** Replace `resolve_value` (contract_for_subfields.rb:85-104) — keep the cache preamble verbatim, change the resolution body:

```ruby
def self.resolve_value(action, config)
  cache = if action.instance_variable_defined?(:@__resolve_value_cache)
            action.instance_variable_get(:@__resolve_value_cache)
          else
            action.instance_variable_set(:@__resolve_value_cache, {}.compare_by_identity)
          end
  return cache[config] if cache.key?(config)

  parent = resolve_parent(action, config)
  value = Axn::Core::FieldResolvers.extract_or_nil(field: config.field, provided_data: parent,
                                                   permit_method_call: config.method_call)
  # A method-derived value is never written back into provided_data, so the write-back coercion/
  # preprocess passes skip it; apply them here, to the resolved value, in the top-level pass order
  # (coerce → preprocess). Non-mutating: transforms the resolved value, never the caller's object.
  value = _apply_read_path_transforms(action, config, value, parent) if resolution_crosses_method_call?(action, config)
  value = Axn::Internal::FieldConfig.resolve_default(action, config) if value.nil? && config.applied_default?
  cache[config] = value
end

# coerce → preprocess, applied to a resolved subfield value on the read path (the top-level pass
# order, minus default: which the caller applies after). Preprocess is skipped when the parent is
# absent (nil): an absent subfield has no value to transform, matching the write-back's
# drop-on-nil-parent. coerce_value no-ops on a nil/non-String value, so coercion needs no guard.
def self._apply_read_path_transforms(action, config, value, parent)
  coerce_input_types = Axn::Configuration.resolve_override_for(action.class, :coerce_input_types)
  value = Axn::Reflection::Coercion.coerce_config_value(value, config, coerce_input_types:)
  value = Axn::Internal::FieldConfig.resolve_preprocess(action, config, value) if config.preprocess && !parent.nil?
  value
end
```

- [ ] **Step 4: Run the new tests** — `bundle exec rspec spec/axn/core/method_call_spec.rb`. Expected: all PASS.

- [ ] **Step 5: Update the coerce_input_types method_call examples.** In method_call_spec.rb, replace the `describe "with coerce_input_types enabled globally"` example (originally 148-158) and the nested `"does not crash coerce_input_types..."` example (originally 215-232) so they assert coercion NOW applies to a coercible String result:

```ruby
describe "with coerce_input_types enabled globally" do
  before { Axn.config.coerce_input_types = true }
  after { Axn.config.coerce_input_types = false }

  it "coerces a coercible-typed method_call subfield's String result" do
    obj = Class.new { def raw_count = "3" }.new
    action = build_axn do
      expects :payload
      expects :raw_count, on: :payload, type: Integer, method_call: true
      exposes :out
      def call = expose(out: raw_count)
    end
    result = action.call(payload: obj)
    expect(result).to be_ok
    expect(result.out).to eq(3)
  end
end
```

For the nested `"a subfield nested UNDER a method_call parent"` coerce_input_types example (originally 215-232), assert the coercible leaf is coerced through the method_call parent:

```ruby
it "coerces a coercible subfield under a method_call parent (coerce_input_types)" do
  Axn.config.coerce_input_types = true
  action = build_axn do
    expects :event
    expects :data, on: :event, method_call: true
    expects :n, on: :data, type: Integer
    exposes :out
    def call = expose(out: n)
  end
  result = action.call(event: event_class_returning.call({ n: "3" }))
  expect(result).to be_ok
  expect(result.out).to eq(3)
ensure
  Axn.config.coerce_input_types = false
end
```

- [ ] **Step 6: Update the executor skip-comments** (executor.rb:614-620, 441, 491, 753) to drop the "keeps them inert (PRO-2903)" framing — state the current fact: the write-back can't reach a method-derived value, which resolve_value coerces/preprocesses on the read path. Example replacement for the `_resolution_crosses_method_call?` doc block above the delegator kept in Task 3 (executor.rb:614-620):

```ruby
# The write-back pre-validation passes (defaults/preprocess/coercion) skip a config whose value is
# method-derived: it is resolved on the READ path (ContractForSubfields.resolve_value, which applies
# coerce:/preprocess:/default: there), never read back from provided_data, so a write-back can't
# affect it.
```

- [ ] **Step 7: Update docs for composition.** In `docs/reference/class.md:247` remove the "do **not** yet apply / skipped entirely / planned (PRO-2903)" sentence and replace with: `preprocess:` and `coerce:` compose with `method_call:` — the method is invoked and its result is coerced then preprocessed (the same order as a top-level field), all on the read path. In `CHANGELOG.md:4` (the PRO-2898 entry) remove the "`preprocess:`/`coerce:` don't yet apply … planned (PRO-2903)" clause.

- [ ] **Step 8: Run full suite** — `bundle exec rspec`. Expected: all PASS.

## Task 5: Commit 1

- [ ] **Step 1: Add a CHANGELOG line** under the unreleased FEAT section of `CHANGELOG.md`:

```markdown
* `preprocess:` and `coerce:` now compose with `method_call:` subfields — the invoked method's result is coerced then preprocessed on the read path, and `coerce_input_types` reaches coercible method-call-crossing subfields (PRO-2903).
```

- [ ] **Step 2: Commit**

```bash
git add lib spec docs CHANGELOG.md
git commit -m "$(printf 'PRO-2903: Compose preprocess:/coerce: with method_call: on the read path\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

# COMMIT 2 — flip all subfields to the read path; delete write-back apparatus (`[BREAKING]`)

## Task 6: Rewrite the parent-materialization matrix examples (failing first)

**Files:**
- Test: `spec/axn/core/subfield_write_back_matrix_spec.rb`

- [ ] **Step 1: Rewrite the 4 examples** that assert a synthesized parent to assert the new non-materializing behavior (child resolves, parent unchanged). Replace matrix:8-21 ("materializes a nil untyped parent"):

```ruby
it "resolves a nil-parent subfield default without materializing the parent" do
  action = build_axn do
    expects :payload, allow_nil: true
    expects :note, on: :payload, optional: true, type: String, default: "d"
    exposes :got, :parent, optional: true, allow_nil: true

    def call = expose(got: note, parent: payload)
  end

  result = action.call(payload: nil)
  expect(result).to be_ok
  expect(result.got).to eq("d")       # child resolves via the read path (value-level default)
  expect(result.parent).to be_nil     # parent is the caller's value, unmaterialized
end
```

Replace matrix:98-108 ("creates intermediate hashes for a dotted-name default under a present parent"):

```ruby
it "resolves a dotted-name default under a present parent without adding the intermediate" do
  action = build_axn do
    expects :payload, type: Hash
    expects "meta.note", on: :payload, optional: true, default: "d"
    exposes :parent, optional: true

    def call = expose(parent: payload)
  end

  expect(action.call(payload: { other: 1 }).parent).to eq({ other: 1 })
end
```

Replace matrix:110-120 ("materializes the whole chain … under a nil parent"):

```ruby
it "resolves a dotted-name default under a nil parent without materializing the chain" do
  action = build_axn do
    expects :payload, type: Hash, optional: true, allow_nil: true
    expects "meta.note", on: :payload, optional: true, default: "d"
    exposes :parent, optional: true, allow_nil: true

    def call = expose(parent: payload)
  end

  expect(action.call.parent).to be_nil
end
```

Replace matrix:122-135 ("applies interacting dotted defaults in declaration order"):

```ruby
it "does not materialize the parent for interacting dotted defaults under a nil parent" do
  action = build_axn do
    expects :payload, type: Hash, optional: true, allow_nil: true
    expects "meta.x", on: :payload, optional: true, default: 1
    expects :meta, on: :payload, optional: true, type: Hash, default: { y: 2 }
    exposes :parent, optional: true, allow_nil: true

    def call = expose(parent: payload)
  end

  expect(action.call.parent).to be_nil
end
```

Replace matrix:137-148 ("writes through a setter when the parent is an object") — the setter write-through is intentionally gone; assert the child resolves without mutating the caller's object:

```ruby
it "resolves a default off an object parent without mutating it (no setter write-back)" do
  holder = Struct.new(:note, :other)
  action = build_axn do
    expects :payload, type: holder
    expects :note, on: :payload, optional: true, default: "d"
    exposes :got, optional: true

    def call = expose(got: note)
  end

  obj = holder.new(nil, 1)
  expect(action.call(payload: obj).got).to eq("d")
  expect(obj.note).to be_nil # the caller's object is untouched
end
```

- [ ] **Step 2: Update the file's header comment** (matrix:3-5) to describe current behavior — the matrix pins subfield resolution on the read path (non-materializing) — not "before the PRO-2883 refactor / must hold identically before and after".

- [ ] **Step 3: Run to verify the rewritten examples fail** — `bundle exec rspec spec/axn/core/subfield_write_back_matrix_spec.rb`. Expected: the 5 rewritten examples FAIL (current write-back still materializes the parent); the other 12 PASS.

## Task 7: Move coerce/preprocess/default fully onto the read path

**Files:**
- Modify: `lib/axn/core/contract_for_subfields.rb` (`resolve_value`, `_apply_read_path_transforms`)
- Modify: `lib/axn/executor.rb` (`apply_inbound_coercion!`, `apply_inbound_preprocessing!`, `apply_inbound_defaults!`)

- [ ] **Step 1: Ungate the read-path transforms.** In `resolve_value` (contract_for_subfields.rb), drop the `if resolution_crosses_method_call?(action, config)` guard so it applies to every subfield, and update the comment:

```ruby
  parent = resolve_parent(action, config)
  value = Axn::Core::FieldResolvers.extract_or_nil(field: config.field, provided_data: parent,
                                                   permit_method_call: config.method_call)
  # coerce:/preprocess:/default: all resolve here, on the read path (non-materializing, value-level
  # — the model PRO-2889 established for subfield defaults). No wire write-back and the parent's own
  # value stays untouched, so axn never mutates a caller-supplied object during resolution.
  value = _apply_read_path_transforms(action, config, value, parent)
  value = Axn::Internal::FieldConfig.resolve_default(action, config) if value.nil? && config.applied_default?
  cache[config] = value
```

- [ ] **Step 2: Make the three write-back passes top-level-only.** Replace `apply_inbound_coercion!`:

```ruby
def apply_inbound_coercion!
  coerce_input_types = Axn::Configuration.resolve_override_for(@action_class, :coerce_input_types)

  @action_class.send(:internal_field_configs).each do |config|
    next unless (path = _resolved_path_for(config))

    current = _current_value_at(path)
    coerced = Axn::Reflection::Coercion.coerce_config_value(current, config, coerce_input_types:)
    _write_value_at!(path, coerced) unless coerced.equal?(current)
  end
end
```

Replace `apply_inbound_preprocessing!`:

```ruby
def apply_inbound_preprocessing!
  @action_class.send(:internal_field_configs).each do |config|
    next unless config.preprocess
    next unless (path = _resolved_path_for(config))

    current_value = _current_value_at(path)
    _write_value_at!(path, Internal::FieldConfig.resolve_preprocess(@action, config, current_value))
  end
end
```

Replace `apply_inbound_defaults!`:

```ruby
def apply_inbound_defaults!
  @action_class.send(:internal_field_configs).each do |config|
    next unless config.applied_default?
    next unless (path = _resolved_path_for(config))
    next unless _current_value_at(path).nil?
    next if _id_default_would_conflict_with_present_record?(path)

    _write_value_at!(path, _resolve_default(config))
  end
end
```

- [ ] **Step 3: Simplify the top-level-only depth-0 helpers.** Replace `_current_value_at`:

```ruby
# The current inbound value at a top-level field (depth 0): the root wire key's value.
def _current_value_at(path)
  @context.provided_data[path.wire_path.first]
end
```

Replace `_write_value_at!`:

```ruby
# A top-level field (depth 0): the value IS the root key — assign directly (key-materializing).
def _write_value_at!(path, new_value)
  @context.provided_data[path.wire_path.first] = new_value
end
```

Replace `_sibling_model_route_for_id` (only the top-level branch remains):

```ruby
# The sibling top-level `model:` route whose companion `<field>_id` this path is — matched by
# model_id_key on the field — or nil. Guards a top-level `<field>_id` default from being written
# when the sibling record is already present (a fabricated consistency mismatch).
def _sibling_model_route_for_id(path)
  id_key = path.leaf_key
  @action_class.send(:internal_field_configs).find do |c|
    c.validations[:model] && Internal::FieldConfig.model_id_key(c.field) == id_key
  end
end
```

- [ ] **Step 4: Run the matrix + method_call + coercion specs** — `bundle exec rspec spec/axn/core/subfield_write_back_matrix_spec.rb spec/axn/core/method_call_spec.rb spec/axn/core/coercion_spec.rb spec/axn/core/validations/on_subfields_spec.rb spec/axn/core/validations/default_assignment_spec.rb`. Expected: all PASS (the 5 rewritten matrix examples now pass; others unchanged).

- [ ] **Step 5: Run full suite** — `bundle exec rspec`. Expected: all PASS. If a failure surfaces a raw-`provided_data` subfield read not covered by the design's audit, STOP and report it (do not paper over).

## Task 8: Delete the dead materialization apparatus

**Files:**
- Modify: `lib/axn/executor.rb`
- Modify: `lib/axn/core/contract_for_subfields.rb`

- [ ] **Step 1: Delete the now-unused executor methods.** After Task 7 these have no callers — verify each with `grep -n`, then remove: `_write_chain_materializable?`, `_synthesizable_node?`, `_default_clobbers_model_route?`, `_default_chain_hash_writable?`, `_cow_write`, `_resolution_crosses_method_call?`. Verification per method:

```bash
grep -n "_write_chain_materializable?\|_synthesizable_node?\|_default_clobbers_model_route?\|_default_chain_hash_writable?\|_cow_write\|_resolution_crosses_method_call?" lib/axn/executor.rb
```

Expected after deletion: only the `def`-less references inside comments remain (remove those comment references too). No live call sites.

- [ ] **Step 2: Delete the now-unused predicate** in `contract_for_subfields.rb`: `resolution_crosses_method_call?` (its only caller — the `resolve_value` gate — is gone). Verify:

```bash
grep -rn "resolution_crosses_method_call?" lib/
```

Expected: no matches after deletion.

- [ ] **Step 3: Reword remaining comments** that referenced the deleted apparatus (e.g. the `_stranded_ancestor_path` / `_current_value_at` doc comments that described the depth-generalized walk) so they describe the current top-level-only / read-path split. No "used to / now" phrasing.

- [ ] **Step 4: Update `prepare_inbound_for_facets!` comment** (executor.rb:47-62): the passes now prepare top-level fields; subfields resolve lazily on read (like `model:` readers). Adjust the wording accordingly.

- [ ] **Step 5: Run full suite** — `bundle exec rspec`. Expected: all PASS.

## Task 9: Docs, CHANGELOG, commit

**Files:**
- Modify: `docs/reference/class.md`, `CHANGELOG.md`

- [ ] **Step 1: Scan docs for stale write-back/materialization claims.** `grep -rn "materiali\|write-back\|synthes" docs/reference/`. Update any statement that a subfield `default:`/`preprocess:` materializes or is written into the parent to reflect read-path (non-materializing) resolution.

- [ ] **Step 2: Add the `[BREAKING]` CHANGELOG entry:**

```markdown
* [BREAKING] Subfield `default:` and `preprocess:` no longer materialize or mutate their parent (PRO-2903). Resolution moved fully onto the read path: a subfield's declared default/preprocessed value is resolved when the subfield is read (value-level, as PRO-2889 established for defaults), and the parent reader returns the caller's value unchanged. Previously a subfield default synthesized its parent (`expects :note, on: :payload, default: "d"` with `payload: nil` made `payload` read back `{note: "d"}`) and a settable-object parent was written through its setter in place; both are gone. The child value still resolves (`note` reads `"d"`).
```

- [ ] **Step 3: Run full suite once more** — `bundle exec rspec`. Expected: all PASS.

- [ ] **Step 4: Commit**

```bash
git add lib spec docs CHANGELOG.md
git commit -m "$(printf 'PRO-2903: Move all subfield resolution to the read path; delete write-back apparatus\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

## Self-Review Notes (for the implementer)

- **Order invariant:** read-path is `coerce → preprocess → default`, matching `apply_inbound_coercion!` → `apply_inbound_preprocessing!` → `apply_defaults!`. Keep them aligned.
- **Preprocess parent guard:** `config.preprocess && !parent.nil?` — preprocess is skipped on an absent parent (matches matrix "drops … when the parent is nil"); `default:` has NO parent guard (value-level, applies even under a refused/nil parent — PRO-2889); coerce needs no guard (`coerce_value` no-ops on nil/non-String).
- **Commit 1 stays non-breaking:** only method-call-crossing subfields change (they were inert before). All existing non-method-call subfield behavior is untouched until Commit 2.
- **Commit 2 breaking surface** is exactly the 5 rewritten matrix examples; if any *other* existing example changes, that's an unaudited raw-`provided_data` read — STOP and report per the design's commit-2 hazard.
