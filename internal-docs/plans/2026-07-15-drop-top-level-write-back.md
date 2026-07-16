# Drop top-level write-back Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Resolve top-level `coerce:`/`preprocess:`/`default:` on the shared read-path seam (`ContractForSubfields.resolve_value` at depth 0) and delete the inbound write-back passes, so axn never mutates `provided_data` during inbound validation.

**Architecture:** A top-level field is the depth-0 case of a subfield (parent = `provided_data`, `wire_path == [field]`, `ancestors == []`). Teach `resolve_parent` that one branch; `resolve_value` then resolves top-level transforms unchanged. Reroute the **inbound** context facade (`InternalContext`) and the `<field>_id` reader through the seam, unify top-level model resolution through a shared `resolve_model_value`, then delete `apply_inbound_coercion!`/`apply_inbound_preprocessing!`/`apply_inbound_defaults!` and reroute the remaining raw-`provided_data` consumers. The reroute and the delete land in **one atomic commit** — while write-back still mutates `provided_data`, a rerouted reader re-reading it would double-apply non-idempotent `preprocess:`.

**Tech Stack:** Ruby, RSpec, ActiveModel. Runs with and without Rails.

**Spec:** `internal-docs/specs/2026-07-15-drop-top-level-write-back-design.md`

## Global Constraints

- **Works outside Rails.** Guard every Rails/ActiveRecord reference with `defined?(...)`. `spec/` runs without Rails; `spec_rails/dummy_app/` is the Rails app. Model behavior is exercised in **both**.
- **TDD.** Failing test first, then implementation.
- **Reuse the seam.** No parallel top-level resolver — extend `resolve_value`/`resolve_parent`/`resolve_model_via_sibling_id` to depth 0. A parallel path is a new thing to keep consistent forever.
- **Frequent commits**; internal helpers prefixed `_`; framework state double-underscored (`@__context`).
- **Comments describe current behavior only** — no "used to X / now Y" historical notes.
- **Verify against real output** (`bundle exec rspec`) before claiming done. Rails specs run from `spec_rails/dummy_app` (`BUNDLE_GEMFILE=spec_rails/dummy_app/Gemfile`).

---

## File Structure

- `lib/axn/core/contract_for_subfields.rb` — the seam. Add depth-0 to `resolve_parent`, extract `resolve_model_value`, add depth-0 to `resolve_model_via_sibling_id`, collapse `_define_subfield_model_reader` onto the shared helper.
- `lib/axn/core/context/facade.rb` — abstract facade. Extract the per-field reader definition into an overridable `_define_reader_for(field)` seam (default = read the data source directly, unchanged for the outbound Result facade).
- `lib/axn/core/context/internal.rb` — `InternalContext` overrides `_define_reader_for` to resolve declared fields through the read path.
- `lib/axn/core/contract.rb` — reroute the `<field>_id` reader's raw-id read through the read path.
- `lib/axn/executor.rb` — delete the three write-back passes + their depth-0 helpers; reroute model-consistency (top-level), the outbound copy-forward, and the strand diagnostic; drop the pre-materialization calls in `prepare_inbound_for_facets!`.
- `spec/axn/core/top_level_write_back_spec.rb` — **new**: mutation-free acceptance test, `inputs`-forwards-transformed, exception-report-shows-raw.
- `CHANGELOG.md`, `docs/` — changelog entry + comment/reference updates.

---

## Task 1: Depth-0 `resolve_parent` (commit 1a — additive, no reroute)

Teach the seam that a top-level field's parent is `provided_data`. Nothing reads through it yet, so behavior is unchanged and the proof is a direct unit call.

**Files:**
- Modify: `lib/axn/core/contract_for_subfields.rb` (`self.resolve_parent`, ~35-52)
- Test: `spec/axn/core/top_level_write_back_spec.rb` (create)

**Interfaces:**
- Consumes: `action.class._resolved_subfields.index[config]` → `ResolvedPath` with `ancestors == []` for a top-level config; `action` exposes `@__context` (an `Axn::Context` with `#provided_data`).
- Produces: `ContractForSubfields.resolve_value(action, top_level_config)` returns the field's resolved value (`coerce → preprocess → default`) reading from `provided_data`, without mutating it.

- [ ] **Step 1: Write the failing test**

Create `spec/axn/core/top_level_write_back_spec.rb`:

```ruby
# frozen_string_literal: true

RSpec.describe "top-level read-path resolution (PRO-2908)" do
  describe "ContractForSubfields.resolve_value at depth 0" do
    it "resolves a top-level preprocess without mutating provided_data" do
      action = build_axn do
        expects :name, preprocess: ->(v) { v.strip }
      end
      instance = action.send(:new, name: "  hi  ")
      config = action.internal_field_configs.find { |c| c.field == :name }

      resolved = Axn::Core::ContractForSubfields.resolve_value(instance, config)

      expect(resolved).to eq("hi")
      # provided_data is untouched by the read-path resolution:
      expect(instance.instance_variable_get(:@__context).provided_data[:name]).to eq("  hi  ")
    end

    it "resolves a top-level default when the value is absent" do
      action = build_axn { expects :count, default: 99 }
      instance = action.send(:new)
      config = action.internal_field_configs.find { |c| c.field == :count }

      expect(Axn::Core::ContractForSubfields.resolve_value(instance, config)).to eq(99)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/core/top_level_write_back_spec.rb -e "resolve_value at depth 0"`
Expected: FAIL — `resolve_parent` walks `path.ancestors` (empty at depth 0) and raises `NoMethodError` on `nil.first` / returns wrong value.

- [ ] **Step 3: Add the depth-0 branch to `resolve_parent`**

In `lib/axn/core/contract_for_subfields.rb`, `self.resolve_parent`, immediately after the `path.nil?` recipe guard:

```ruby
def self.resolve_parent(action, config)
  path = action.class._resolved_subfields.index[config]
  return _resolve_parent_by_recipe(action, config.on) if path.nil?

  # A top-level field is the depth-0 case: its parent IS the raw provided_data hash (no ancestor
  # chain to walk). Reading its leaf from here applies coerce/preprocess/default on the read path
  # without ever writing back — the same non-materializing model the deeper subfields use.
  return action.instance_variable_get(:@__context).provided_data if path.ancestors.empty?

  reader_index = deepest_reader_index(path)
  # ...unchanged...
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/axn/core/top_level_write_back_spec.rb -e "resolve_value at depth 0"`
Expected: PASS (both examples).

- [ ] **Step 5: Run the full seam suite (no regressions)**

Run: `bundle exec rspec spec/axn/core/contract_for_subfields_spec.rb spec/axn/core/on_subfields_spec.rb spec/axn/core/resolved_subfields_cache_spec.rb`
Expected: PASS (depth-0 branch doesn't affect subfield paths — they have non-empty `ancestors`).

- [ ] **Step 6: Commit**

```bash
git add lib/axn/core/contract_for_subfields.rb spec/axn/core/top_level_write_back_spec.rb
git commit -m "PRO-2908: resolve_parent handles the depth-0 (top-level) case

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Shared `resolve_model_value` + depth-0 sibling-id (commit 1b — additive)

Extract the subfield model-reader body into a shared `resolve_model_value` and give `resolve_model_via_sibling_id` a depth-0 branch (the sibling `<field>_id` is another top-level root, not a `leaf_parent_node` child). Still additive: the facade isn't rerouted yet, so the subfield path must stay byte-identical.

**Files:**
- Modify: `lib/axn/core/contract_for_subfields.rb` (`resolve_model_via_sibling_id` ~133-172; `_define_subfield_model_reader` ~455-478; new `self.resolve_model_value`)
- Test: `spec/axn/core/top_level_write_back_spec.rb`

**Interfaces:**
- Produces: `ContractForSubfields.resolve_model_value(action, config, options)` → resolves the record (`resolve_parent` → model resolve → sibling-id rescue → record-supplying `default:` fallback); works at depth 0 and deeper. `options` is the already-syntactic-sugar-processed model options (top-level: `config.validations[:model]`; subfield: `_subfield_model_options(config)`).

- [ ] **Step 1: Write the failing test**

Append to `spec/axn/core/top_level_write_back_spec.rb`. Uses the non-Rails PORO+finder `model:` pattern (mirror an existing `model_id_reader_spec` fixture — a class with `self.find(id)`):

```ruby
  describe "ContractForSubfields.resolve_model_value at depth 0" do
    it "resolves a top-level model record from a sibling <field>_id default" do
      widget_klass = Class.new do
        def self.all = @all ||= {}
        def self.find(id) = all[id]
        attr_reader :id
        def initialize(id) = (@id = id)
      end
      w = widget_klass.new(7)
      widget_klass.all[7] = w
      stub_const("Widget", widget_klass)

      action = build_axn do
        expects :widget, model: true
        expects :widget_id, default: 7
      end
      instance = action.send(:new) # neither widget nor widget_id supplied

      config = action.internal_field_configs.find { |c| c.field == :widget }
      resolved = Axn::Core::ContractForSubfields.resolve_model_value(instance, config, config.validations[:model])

      expect(resolved).to eq(w)
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/core/top_level_write_back_spec.rb -e "resolve_model_value at depth 0"`
Expected: FAIL — `resolve_model_value` undefined (NoMethodError).

- [ ] **Step 3: Extract `resolve_model_value`; add depth-0 to `resolve_model_via_sibling_id`**

In `lib/axn/core/contract_for_subfields.rb`, add the shared resolver (near `resolve_value`):

```ruby
# THE model-field value read — the facade's top-level model reader and _define_subfield_model_reader
# share it, so top-level and subfield model resolution can't drift. Resolve the parent (provided_data
# at depth 0), resolve the record, fall back to a sibling-<field>_id-supplied lookup (value-level id
# default), then to a record-supplying default:. Non-materializing — the parent's own value stays
# untouched. `options` is the syntactic-sugar-processed model options for this config.
def self.resolve_model_value(action, config, options)
  parent = resolve_parent(action, config)
  record = Axn::Core::FieldResolvers.resolve(type: :model, field: config.field, options:,
                                             provided_data: parent, permit_method_call: config.method_call)
  record ||= resolve_model_via_sibling_id(action, config, options, parent)
  record.nil? && config.applied_default? ? Axn::Internal::FieldConfig.resolve_default(action, config) : record
end
```

In `resolve_model_via_sibling_id`, after `path = action.class._resolved_subfields.index[config]; return nil if path.nil?`, branch the sibling lookup on depth. Replace the `leaf_key`/`sibling` block:

```ruby
        leaf_key = path.leaf_key
        id_key = Axn::Internal::FieldConfig.model_id_key(leaf_key)
        sibling_config =
          if path.ancestors.empty?
            # Top-level: the sibling <field>_id is another top-level root (a declared field), not a
            # child of leaf_parent_node.
            action.class.internal_field_configs.find do |c|
              c.field == id_key && Axn::Reflection::Schema.usable_id_token_default?(c)
            end
          else
            sibling = path.leaf_parent_node.children[id_key.to_sym]
            sibling&.configs&.find { |c| Axn::Reflection::Schema.usable_id_token_default?(c) }
          end
        return nil if sibling_config.nil?
```

(The subsequent `sibling_value` / synthetic-resolve block is unchanged.)

- [ ] **Step 4: Collapse `_define_subfield_model_reader` onto the shared helper**

Replace the body so the subfield reader delegates (proves the extraction is faithful):

```ruby
def _define_subfield_model_reader(config)
  processed_options = _subfield_model_options(config)
  Axn::Internal::Memoization.define_memoized_reader_method(self, config.reader_as) do
    Axn::Core::ContractForSubfields.resolve_model_value(self, config, processed_options)
  end
end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bundle exec rspec spec/axn/core/top_level_write_back_spec.rb spec/axn/core/on_subfields_spec.rb spec/axn/core/model_id_reader_spec.rb`
Expected: PASS — new depth-0 example green; subfield model resolution unchanged.

- [ ] **Step 6: Run the Rails model specs**

Run: `BUNDLE_GEMFILE=spec_rails/dummy_app/Gemfile bundle exec rspec spec_rails` (model resolution against real AR).
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/axn/core/contract_for_subfields.rb spec/axn/core/top_level_write_back_spec.rb
git commit -m "PRO-2908: shared resolve_model_value + depth-0 sibling-id resolution

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Flip the facade + consumers onto the seam, delete write-back (commit 2 — atomic)

The reroute and the delete land together. Write the acceptance tests first, then make the change, then the **full suite** is the gate. This is a single commit.

**Files:**
- Modify: `lib/axn/core/context/facade.rb`, `lib/axn/core/context/internal.rb`, `lib/axn/core/contract.rb`, `lib/axn/executor.rb`
- Test: `spec/axn/core/top_level_write_back_spec.rb`

**Interfaces:**
- Consumes: `ContractForSubfields.resolve_value` / `resolve_model_value` (Tasks 1-2).
- Produces: `InternalContext` readers, `inputs`, inbound validation, and the `<field>_id` reader all resolve through the read path; `@context.provided_data` is never mutated by the inbound pipeline.

- [ ] **Step 1: Write the failing acceptance tests**

Append to `spec/axn/core/top_level_write_back_spec.rb`:

```ruby
  describe "no write-back to provided_data (the acceptance wedge)" do
    it "leaves the caller's provided_data byte-for-byte raw while the reader returns transformed" do
      captured = nil
      action = build_axn do
        expects :name, preprocess: ->(v) { v.strip }
        expects :count, default: 99
        exposes :seen_name, :raw, optional: true
        define_method(:call) do
          captured = @__context.provided_data.dup
          expose(seen_name: name, raw: captured)
        end
      end

      result = action.call(name: "  hi  ")

      expect(result.seen_name).to eq("hi")           # reader → transformed
      expect(result.raw[:name]).to eq("  hi  ")      # provided_data → raw, unmutated
      expect(result.raw).not_to have_key(:count)     # default never materialized into provided_data
    end

    it "does not mutate a caller-supplied settable object referenced by an input" do
      require "ostruct"
      obj = OpenStruct.new(touched: false)
      action = build_axn do
        expects :thing, preprocess: ->(v) { v.tap { |o| o } } # returns same object; must not be mutated in place
      end
      action.call(thing: obj)
      expect(obj.touched).to eq(false)
    end
  end

  describe "#inputs forwards transformed values to a nested action" do
    it "a nested action receiving **inputs sees the parent's coerced/preprocessed/defaulted values" do
      child = build_axn do
        expects :name
        expects :count
        exposes :got, optional: true
        def call = expose(got: [name, count])
      end
      stub_const("ChildAxn", child)

      parent = build_axn do
        expects :name, preprocess: ->(v) { v.strip }
        expects :count, default: 99
        exposes :child_got, optional: true
        def call = expose(child_got: ChildAxn.call!(**inputs).got)
      end

      expect(parent.call(name: "  hi  ").child_got).to eq(["hi", 99])
    end
  end

  describe "exception-report inputs show RAW caller input" do
    it "reports the raw invocation arg for a field with a declared transform" do
      captured = nil
      Axn.config.on_exception = ->(e, action:, context:) { captured = context[:inputs] }
      action = build_axn do
        expects :name, preprocess: ->(v) { v.strip }
        def call = raise "boom"
      end
      action.call(name: "  hi  ")
      expect(captured[:name]).to eq("  hi  ")
    ensure
      Axn.config.on_exception = nil
    end

    it "still redacts a sensitive: top-level field in the raw report (filtering keys off the name)" do
      captured = nil
      Axn.config.on_exception = ->(e, action:, context:) { captured = context[:inputs] }
      action = build_axn do
        expects :token, sensitive: true, preprocess: ->(v) { v.strip }
        def call = raise "boom"
      end
      action.call(token: "  secret  ")
      expect(captured[:token]).to eq("[FILTERED]")
    ensure
      Axn.config.on_exception = nil
    end
  end
```

- [ ] **Step 2: Run to verify failures**

Run: `bundle exec rspec spec/axn/core/top_level_write_back_spec.rb`
Expected: the four new examples FAIL — `provided_data[:name]` currently reads `"hi"` (write-back mutated it), `count` is materialized, exception `:inputs` shows `"hi"`. (Tasks 1-2 examples still pass.)

- [ ] **Step 3: Add the `_define_reader_for` seam to the abstract facade**

In `lib/axn/core/context/facade.rb`, replace the inline loop body with a call to an overridable method:

```ruby
      (@declared_fields + Array(implicitly_allowed_fields)).each do |field|
        _define_reader_for(field)
      end
    end

    attr_reader :declared_fields
```

Add, in the `private` section:

```ruby
    # Define one field's reader. The base (outbound Result) facade reads the data source directly;
    # InternalContext overrides this to resolve declared inbound fields through the read path.
    def _define_reader_for(field)
      if _model_fields.key?(field)
        _define_model_field_method(field, _model_fields[field])
      else
        singleton_class.define_method(field) do
          _context_data_source[field]
        end
      end
    end
```

- [ ] **Step 4: Override `_define_reader_for` in `InternalContext`**

In `lib/axn/core/context/internal.rb`, add (private section):

```ruby
    # Inbound fields resolve through the read-path seam (coerce/preprocess/default applied on read,
    # provided_data never mutated). A field with no config (implicitly-allowed) keeps the raw source
    # read. Model fields resolve through the shared resolve_model_value (record + sibling-id + default).
    def _define_reader_for(field)
      config = action.internal_field_configs.find { |c| c.field == field }
      return super if config.nil?

      if config.validations.key?(:model)
        Axn::Internal::Memoization.define_memoized_reader_method(singleton_class, field) do
          Axn::Core::ContractForSubfields.resolve_model_value(action, config, config.validations[:model])
        end
      else
        singleton_class.define_method(field) do
          Axn::Core::ContractForSubfields.resolve_value(action, config)
        end
      end
    end
```

- [ ] **Step 5: Reroute the `<field>_id` reader through the read path**

In `lib/axn/core/contract.rb`, `_define_model_id_reader` (~837), resolve a declared `<field>_id` through the seam so a defaulted/preprocessed id is visible; an undeclared id (the common caller-supplied case) still reads raw:

```ruby
        def _define_model_id_reader(reader, source_field, model_options)
          by_primary_key = model_options.is_a?(Hash) && model_options[:finder] == :find
          _define_model_id_reader_from(reader:, source_field:, by_primary_key:) do |id_key|
            id_config = self.class.internal_field_configs.find { |c| c.field == id_key }
            id_config ? Axn::Core::ContractForSubfields.resolve_value(self, id_config) : @__context.provided_data[id_key]
          end
        end
```

- [ ] **Step 6: Delete the write-back passes and their depth-0 helpers**

In `lib/axn/executor.rb`:
- Delete methods `apply_inbound_coercion!`, `apply_inbound_preprocessing!`, `apply_inbound_defaults!`, `_id_default_would_conflict_with_present_record?`, `_sibling_model_route_for_id`, `_current_value_at`, `_write_value_at!`.
- In `with_contract`, delete the first three pipeline lines and their `handle_early_completion_if_raised` wrappers:

```ruby
    def with_contract(&block)
      _clear_pre_pipeline_memos!

      return if handle_early_completion_if_raised { validate_contract!(:inbound) }
      # ...rest unchanged (facet log context, outbound defaults/validation, finalize)...
```

(The `_clear_pre_pipeline_memos!` call moves to the top — it must still run before validation resolves readers. The comment block above `validate_contract!(:inbound)` about early completion during resolution stays.)
- In `apply_defaults!` keep only the `:outbound` branch (remove the `return apply_inbound_defaults! if direction == :inbound` line and the direction guard's inbound half — it is now outbound-only; simplify to assert `:outbound`).
- In `prepare_inbound_for_facets!` (~55), remove the three write-back calls; it becomes a no-op preparation that relies on lazy read-path resolution:

```ruby
    def prepare_inbound_for_facets!
      _clear_pre_pipeline_memos!
    rescue StandardError => e
      Internal::PipingError.swallow("preparing inbound context for async facet resolution", action: @action, exception: e)
    end
```

- [ ] **Step 7: Reroute the outbound copy-forward**

In `lib/axn/executor.rb`, `apply_defaults!` (outbound branch, ~723), forward the **resolved** inbound value:

```ruby
      @action_class.send(:external_field_configs).each do |config|
        field = config.field
        if !@context.exposed_data.key?(field) && @action_class.send(:internal_field_configs).any? { |c| c.field == field }
          @context.exposed_data[field] = @action.internal_context.public_send(field)
        end

        next if config.default.nil?
        next if @context.exposed_data.key?(field) && !@context.exposed_data[field].nil?

        @context.exposed_data[field] = _resolve_default(config)
      end
```

(Rationale: the copy-forward only applies to a field that is both `expects` and `exposes`; reading through `internal_context` gives the resolved value, matching what write-back forwarded. A pure-exposes field has no inbound config, so the guard skips it — do NOT `public_send` a non-inbound field.)

- [ ] **Step 8: Reroute top-level model-consistency**

In `lib/axn/executor.rb`, `_model_consistency_mismatches` top-level loop, read the **resolved** id (a preprocessed/defaulted `<field>_id` read raw would fabricate a conflict the readers don't have) while the record stays raw (no forced lookup):

```ruby
      @action_class.send(:internal_field_configs).each do |config|
        next unless _id_based_model?(config)
        next if _model_gate_closed?(config) { @action.internal_context }

        record = Core::FieldResolvers.extract_or_nil(field: config.field, provided_data: @context.provided_data,
                                                     permit_method_call: config.method_call)
        raw_id = _resolved_top_level_id(config.field)
        msg = _record_id_mismatch(field: config.field, record:, raw_id:)
        mismatches << msg if msg
      end
```

Refactor `_model_record_id_mismatch` into a source-agnostic `_record_id_mismatch(field:, record:, raw_id:)` (the comparison core) and keep the subfield caller passing values extracted from `_resolved_parent_value`. Add:

```ruby
    # The read-path-resolved <field>_id for a top-level model route: a declared <field>_id resolves
    # through the seam (its default:/preprocess: applied), matching what the <field>_id reader returns;
    # an undeclared id is the caller's raw token.
    def _resolved_top_level_id(field)
      id_key = Internal::FieldConfig.model_id_key(field)
      id_config = @action_class.send(:internal_field_configs).find { |c| c.field == id_key }
      id_config ? Axn::Core::ContractForSubfields.resolve_value(@action, id_config) : @context.provided_data[id_key]
    end

    def _record_id_mismatch(field:, record:, raw_id:)
      return nil if record.nil? || raw_id.nil? || raw_id.to_s.strip.empty?
      return nil unless record.respond_to?(:id)
      return nil if record.id.to_s == raw_id.to_s

      "#{field}: provided record (id=#{record.id.inspect}) conflicts with #{field}_id=#{raw_id.inspect} — pass one, or matching values"
    end
```

Update the subfield loop to call `_record_id_mismatch(field: config.field, record:, raw_id:)` with `record`/`raw_id` extracted from `_resolved_parent_value(config)` (preserving today's subfield behavior — extract both off the resolved parent).

- [ ] **Step 9: Reroute the strand diagnostic**

In `lib/axn/executor.rb`, `_stranded_ancestor_path` (~557), resolve the top-level root through the seam so the diagnostic agrees with runtime resolution:

```ruby
    def _stranded_ancestor_path(path)
      root_config = @action_class.send(:internal_field_configs).find { |c| c.field == path.wire_path.first }
      value = root_config ? Axn::Core::ContractForSubfields.resolve_value(@action, root_config) : @context.provided_data[path.wire_path.first]
      return nil if value.nil?
      # ...rest unchanged...
```

- [ ] **Step 10: Run the acceptance tests**

Run: `bundle exec rspec spec/axn/core/top_level_write_back_spec.rb`
Expected: PASS (all examples, including the four from Step 1).

- [ ] **Step 11: Run the full top-level regression suite**

Run:
```bash
bundle exec rspec spec/axn/core/coercion_spec.rb spec/axn/core/validations/preprocessing_spec.rb \
  spec/axn/core/validations/default_assignment_spec.rb spec/axn/core/inputs_reader_spec.rb \
  spec/axn/core/model_id_reader_spec.rb spec/axn/core/logging_spec.rb spec/axn/core/on_exception_spec.rb \
  spec/axn/executor_spec.rb spec/axn/core/malformed_input_matrix_spec.rb
```
Expected: PASS. If any fail, diagnose per the spec's consumer audit (each failure is a consumer that read raw `provided_data` and needs its resolved-value reroute, or a spec asserting the old write-back mutation that must be re-pinned to the new raw-`provided_data` behavior). Do NOT weaken an assertion without confirming it against the spec's stated behavior.

- [ ] **Step 12: Run the entire suite (non-Rails + Rails)**

Run: `bundle exec rspec` then `BUNDLE_GEMFILE=spec_rails/dummy_app/Gemfile bundle exec rspec spec_rails`
Expected: PASS. Fix fallout the same way. Run `bundle exec rubocop` and clear any new offenses (scoped disables only if genuinely unavoidable).

- [ ] **Step 13: Commit (atomic reroute + delete)**

```bash
git add lib/axn/core/context/facade.rb lib/axn/core/context/internal.rb lib/axn/core/contract.rb lib/axn/executor.rb spec/axn/core/top_level_write_back_spec.rb
git commit -m "PRO-2908: resolve top-level fields on the read path, delete write-back

Reroute the inbound context facade + <field>_id reader through resolve_value/
resolve_model_value; delete apply_inbound_coercion!/preprocessing!/defaults!
and reroute model-consistency, outbound copy-forward, and the strand
diagnostic. provided_data is never mutated by the inbound pipeline.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Docs, CHANGELOG, and comment cleanup

**Files:**
- Modify: `CHANGELOG.md`; `lib/axn/executor.rb`, `lib/axn/core/context/facade.rb`, `lib/axn/core/contract.rb`, `spec/axn/core/inputs_reader_spec.rb` (stale write-back comments); any `docs/` reference framing top-level resolution as write-back.

- [ ] **Step 1: CHANGELOG entry**

Add under the unreleased section (a `FEAT`/refinement, not `[BREAKING]`):

```markdown
- Top-level `coerce:`/`preprocess:`/`default:` now resolve on the read path (unified with subfields); axn no longer mutates `provided_data` during inbound validation. Marginal refinements: a validator-less, never-read top-level `preprocess:` side-effect no longer fires eagerly; an inter-field `preprocess:`/`default:` proc that reads another field now triggers that field's full read-path resolution; exception-report `:inputs` show the raw caller input for a field with declared transforms (matching the "About to execute with:" log).
```

- [ ] **Step 2: Update stale comments**

Grep and fix comments that frame top-level resolution as write-back (describe current behavior only, no historical "used to"):

```bash
grep -rn "write.back\|writes back\|is its own root, so its result always writes\|top-level reader memos are deliberately NOT cleared\|apply_inbound_preprocessing!\|apply_inbound_coercion!\|apply_inbound_defaults!" lib/ spec/
```

Rewrite each hit to describe the read-path model. In particular: `spec/axn/core/inputs_reader_spec.rb`'s comment referencing `apply_inbound_preprocessing!` writing back; `lib/axn/core/context/facade.rb` / `internal.rb` reader comments; any `_clear_pre_pipeline_memos!` comment mentioning top-level exclusion.

- [ ] **Step 3: Run the doc/comment-adjacent specs**

Run: `bundle exec rspec spec/axn/core/inputs_reader_spec.rb spec/rubocop 2>/dev/null; bundle exec rubocop lib spec`
Expected: PASS / no offenses.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "PRO-2908: CHANGELOG + comment cleanup for read-path top-level resolution

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-review notes (for the executor)

- **Double-application guard:** never leave a commit where a reader is rerouted through `resolve_value` while a write-back pass still mutates `provided_data` — `preprocess:` would run twice. Task 3 is atomic for this reason.
- **Outbound facade untouched:** the reroute lives in `InternalContext#_define_reader_for`, not the abstract facade. If a `result.<field>` read starts returning inbound values, the override leaked to the outbound facade — check the class the override is defined on.
- **`_clear_pre_pipeline_memos!` still runs before validation** (it clears `@__resolve_value_cache` so validation resolves against settled inputs) — it moved to the top of `with_contract`, it wasn't deleted.
- **Model-consistency reads resolved id, raw record:** reading the record through its reader would trigger a finder the current check avoids; reading the id raw would fabricate a conflict a `preprocess:`/`default:` id resolves away. Pin both with tests (conflicting record+id still raises; a preprocessed id that matches does not).
