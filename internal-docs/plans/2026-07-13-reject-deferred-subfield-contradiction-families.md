# Reject Deferred Subfield Contradiction Families — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Value-level subfield defaults (a `default:` guarantees the resolved value even when wire write-back can't apply it), then declaration-time rejection of dead nil-tolerance (families 1+3) and unanswerable resolution segments (family 2), all reusing the canonical `SubfieldTree`/`Schema` derivations.

**Architecture:** Per the approved spec (`internal-docs/specs/2026-07-13-reject-deferred-subfield-contradiction-families-design.md`). Capability first (Tasks 2–5), so the detectors (Tasks 7–8) encode the new runtime truth. The detectors are thin walks over a candidate tree using the Schema predicates in a new `satisfiability:` mode (Task 6) — never parallel re-derivations.

**Tech Stack:** Ruby gem (axn), RSpec. Non-Rails specs in `spec/`; Rails mirrors in `spec_rails/dummy_app/`.

## Global Constraints

- **PR #162 (PRO-2886, per-segment Extract) must be merged and this branch rebased on it before Task 8** (family 2 mirrors its semantics). Tasks 1–7 don't depend on it.
- Works outside Rails: no unguarded Rails/AR references (`defined?(...)`).
- TDD: failing test first, every behavior change.
- Reflection/declaration checks are side-effect-free: never run user code (Procs, custom finders); `method_defined?`-style class reflection is allowed.
- Copy-on-write config stores: never mutate `internal_field_configs`/`subfield_configs` in place; declaration checks run **before** any class mutation.
- CHANGELOG entry under `## Unreleased` for every user-visible change, `[FEAT]`/`[BREAKING]` as specified per task.
- Comments explain *why*; no historical ("used to X") comments.
- Run non-Rails suite: `bundle exec rspec`. Rails suite: `(cd spec_rails/dummy_app && BUNDLE_GEMFILE=Gemfile bundle exec rspec)`.
- Commit messages end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: Preflight — verify base

**Files:** none (git only)

- [ ] **Step 1: Check PR #162 status**

Run: `gh pr view 162 --json state,mergedAt`

If MERGED: `git fetch origin && git rebase origin/main` and resolve trivially (this branch has only `internal-docs/` commits so far).
If OPEN: continue — Tasks 2–7 are independent of it; re-check before Task 8 and rebase then.

- [ ] **Step 2: Verify clean suite baseline**

Run: `bundle exec rspec --fail-fast`
Expected: PASS (green baseline before any change).

---

### Task 2: Shared default resolution + value-level fallback in readers

**Files:**
- Modify: `lib/axn/internal/field_config.rb` (add `resolve_default`)
- Modify: `lib/axn/executor.rb:721-729` (`_resolve_default` delegates)
- Modify: `lib/axn/core/contract_for_subfields.rb` (add `resolve_value`; reader bodies)
- Test: `spec/axn/core/validations/on_subfields_spec.rb` (new `describe "value-level default fallback (PRO-2889)"` block)

**Interfaces:**
- Produces: `Axn::Internal::FieldConfig.resolve_default(action, config)` → resolved default value (Proc `instance_exec`'d on action, wrapped in `DefaultAssignmentError` handling). `Axn::Core::ContractForSubfields.resolve_value(action, config)` → the subfield's resolved leaf value with default fallback. Tasks 3–4 consume both.

- [ ] **Step 1: Write the failing reader-fallback tests**

Append to `spec/axn/core/validations/on_subfields_spec.rb`:

```ruby
describe "value-level default fallback (PRO-2889)" do
  let(:company_class) do
    Class.new do
      attr_accessor :id, :name

      def initialize(id:, name: nil)
        @id = id
        @name = name
      end

      def self.fetch(id) = new(id:)
    end
  end

  before { stub_const("FallbackCompany", company_class) }

  let(:action) do
    build_axn do
      expects :company, model: { klass: FallbackCompany, finder: :fetch }, allow_nil: true
      expects :nickname, on: :company, type: String, optional: true, default: "anon"
      exposes :nick, allow_nil: true
      def call = expose(nick: nickname)
    end
  end

  it "falls back to the default when the parent record's attribute is nil" do
    expect(action.call(company: FallbackCompany.new(id: 1)).nick).to eq("anon")
  end

  it "falls back when the id-resolved record's attribute is nil" do
    expect(action.call(company_id: 7).nick).to eq("anon")
  end

  it "falls back when the model parent is omitted entirely" do
    expect(action.call.nick).to eq("anon")
  end

  it "prefers the resolved value when present" do
    expect(action.call(company: FallbackCompany.new(id: 1, name: "zed")).nick).to eq("anon")
  end

  context "with a record-supplying default on a model subfield" do
    let(:action) do
      build_axn do
        expects :payload, type: Hash, allow_nil: true
        expects :company, on: :payload, model: { klass: FallbackCompany, finder: :fetch },
                          optional: true, default: -> { FallbackCompany.new(id: 99, name: "dflt") }
        exposes :got_id, allow_nil: true
        def call = expose(got_id: company&.id)
      end
    end

    it "resolves the defaulted record when the chain is refused" do
      expect(action.call(payload: nil).got_id).to eq(99)
    end
  end
end
```

Note `nickname` reads its OWN wire key off the record — `FallbackCompany` has no `nickname` accessor, so extraction reads absent (`UnextractableError` → nil) and the fallback fires; the "prefers resolved value" case still expects `"anon"` for the same reason. That is deliberate: it exercises fallback-on-unanswerable-present-parent. Add one more case where the attribute exists:

```ruby
  context "when the parent answers the key" do
    let(:action) do
      build_axn do
        expects :company, model: { klass: FallbackCompany, finder: :fetch }, allow_nil: true
        expects :name, on: :company, type: String, optional: true, default: "anon"
        exposes :n, allow_nil: true
        def call = expose(n: name)
      end
    end

    it "prefers a present attribute over the default" do
      expect(action.call(company: FallbackCompany.new(id: 1, name: "zed")).n).to eq("zed")
    end

    it "falls back when the attribute is nil" do
      expect(action.call(company: FallbackCompany.new(id: 1)).n).to eq("anon")
    end
  end
```

- [ ] **Step 2: Run to verify failures**

Run: `bundle exec rspec spec/axn/core/validations/on_subfields_spec.rb -e "value-level default fallback" `
Expected: FAIL — resolved values are `nil` (today the default never applies on these paths).

- [ ] **Step 3: Implement `Internal::FieldConfig.resolve_default`**

In `lib/axn/internal/field_config.rb`, add below `model_id_key`:

```ruby
# Resolve a config's declared default against an action instance: a Proc is instance_exec'd (so
# it sees readers/context), anything else returned as-is, with failures wrapped as
# DefaultAssignmentError. Single source for the executor's write-back pass AND the value-level
# read fallback (PRO-2889), so the two can't drift on Proc/error semantics.
def resolve_default(action, config)
  descriptor = config.subfield? ? "subfield '#{config.field}' on '#{config.on}'" : "field '#{config.field}'"
  identifier = config.subfield? ? "#{config.field} on #{config.on}" : config.field
  Axn::Internal::ContractErrorHandling.with_contract_error_handling(
    exception_class: Axn::ContractViolation::DefaultAssignmentError,
    message: ->(_field, error) { "Error applying default for #{descriptor}: #{error.message}" },
    field_identifier: identifier,
  ) do
    config.default.respond_to?(:call) ? action.instance_exec(&config.default) : config.default
  end
end
```

(Check the file's existing requires; add `require "axn/internal/contract_error_handling"` only if constants aren't autoloaded — mirror how `executor.rb` reaches it.)

In `lib/axn/executor.rb`, replace `_resolve_default`'s body with delegation (keep `_field_descriptor`/`_field_identifier` — preprocess messages still use them):

```ruby
def _resolve_default(config)
  Internal::FieldConfig.resolve_default(@action, config)
end
```

- [ ] **Step 4: Implement `resolve_value` + reader bodies**

In `lib/axn/core/contract_for_subfields.rb`, add below `resolve_parent`:

```ruby
# THE subfield value read — readers and validation share it: leaf-extract from the canonically
# resolved parent, then value-level default fallback (PRO-2889). A declared default: guarantees
# the RESOLVED value is never nil-by-omission even when the wire write-back couldn't apply it (a
# refused chain under a model:/non-object parent, a parent record whose attribute is nil, a
# malformed parent). No wire data is written here and the parent's own value stays untouched, so
# a nil-tolerant parent remains genuinely nil.
def self.resolve_value(action, config)
  value = Axn::Core::FieldResolvers.extract_or_nil(field: config.field, provided_data: resolve_parent(action, config))
  return value unless value.nil? && config.applied_default?

  Axn::Internal::FieldConfig.resolve_default(action, config)
end
```

Replace the plain reader body in `_define_subfield_reader`:

```ruby
Axn::Internal::Memoization.define_memoized_reader_method(self, reader) do
  Axn::Core::ContractForSubfields.resolve_value(self, config)
end
```

Extend `_define_subfield_model_reader`'s memoized block:

```ruby
Axn::Internal::Memoization.define_memoized_reader_method(self, reader) do
  subfield_data = Axn::Core::ContractForSubfields.resolve_parent(self, config)
  record = Axn::Core::FieldResolvers.resolve(
    type: :model,
    field: source_field,
    options: processed_options,
    provided_data: subfield_data,
  )
  # A nil-resolving model subfield falls back to a record-supplying default (validated by
  # ModelValidator like any record) — the same value-level rule as plain subfields.
  record.nil? && config.applied_default? ? Axn::Internal::FieldConfig.resolve_default(self, config) : record
end
```

- [ ] **Step 5: Run the new tests**

Run: `bundle exec rspec spec/axn/core/validations/on_subfields_spec.rb -e "value-level default fallback"`
Expected: PASS. (These cases use `optional: true` subfields, so validation isn't in play yet — Task 3 covers it.)

- [ ] **Step 6: Full non-Rails suite**

Run: `bundle exec rspec`
Expected: PASS. If any existing spec asserted a nil reader on these paths, update it to the new (intended) value and note it in the commit message.

- [ ] **Step 7: Commit**

```bash
git add lib/axn/internal/field_config.rb lib/axn/executor.rb lib/axn/core/contract_for_subfields.rb spec/axn/core/validations/on_subfields_spec.rb
git commit -m "PRO-2889: Value-level default fallback in subfield readers"
```

---

### Task 3: Validation reads through the reader / shared resolution

**Files:**
- Modify: `lib/axn/core/validation/fields.rb` (`read_attribute_for_validation`, `collect_errors`, `errors_for`)
- Modify: `lib/axn/executor.rb:550-557` (pass `config:`)
- Test: `spec/axn/core/validations/on_subfields_spec.rb` (extend the PRO-2889 block)
- Modify: `CHANGELOG.md` (`[FEAT]` entry)

**Interfaces:**
- Consumes: `ContractForSubfields.resolve_value(action, config)` (Task 2).
- Produces: `Fields.collect_errors(field:, validations:, source:, action: nil, reader: nil, config: nil)` — new optional `config:` kwarg; validation value for any subfield now equals its reader value.

- [ ] **Step 1: Write the failing headline test**

Append inside the PRO-2889 describe block:

```ruby
  context "with a REQUIRED defaulted subfield under a nil-tolerant model parent (family 3 capability)" do
    let(:action) do
      build_axn do
        expects :company, model: { klass: FallbackCompany, finder: :fetch }, allow_nil: true
        expects :name, on: :company, type: String, default: "x"
        exposes :n, allow_nil: true
        def call = expose(n: name)
      end
    end

    it "succeeds on omission: the default satisfies validation and the parent stays nil" do
      result = action.call
      expect(result).to be_ok
      expect(result.n).to eq("x")
    end

    it "succeeds on explicit nil" do
      expect(action.call(company: nil)).to be_ok
    end

    it "still reads the record's value when id-resolved" do
      expect(action.call(company_id: 7).n).to eq("x") # fetch returns name: nil → default
    end

    it "does not rescue a BLANK default a presence validator rejects" do
      blank = build_axn do
        expects :company, model: { klass: FallbackCompany, finder: :fetch }, allow_nil: true
        expects :name, on: :company, type: String, default: ""
        def call = nil
      end
      result = blank.call
      expect(result).not_to be_ok
      expect(result.exception.message).to match(/Name can't be blank/)
    end
  end

  context "with a dotted-name defaulted subfield under a refused chain" do
    let(:action) do
      build_axn do
        expects :payload, type: Array, allow_nil: true
        expects "meta.count", on: :payload, type: Integer, default: 0
        def call = nil
      end
    end

    it "validates the fallback value (no reader exists for a dotted name)" do
      expect(action.call(payload: nil)).to be_ok
    end
  end
```

- [ ] **Step 2: Run to verify failures**

Run: `bundle exec rspec spec/axn/core/validations/on_subfields_spec.rb -e "family 3 capability" -e "dotted-name defaulted"`
Expected: FAIL — `Name can't be blank` on omission (validation still reads the raw extract).

- [ ] **Step 3: Implement the validation read path**

In `lib/axn/core/validation/fields.rb`:

```ruby
def read_attribute_for_validation(attr)
  # A subfield reads through the action's generated reader when one exists — the reader IS the
  # field's value (memoized, model-resolving, value-level-default-applying, PRO-2889), so
  # validation sees exactly what user code sees. A dotted-name subfield has no reader and
  # resolves through the same shared helper. Top-level fields keep reading their source facade.
  if @action && @reader && @action.respond_to?(@reader)
    @action.public_send(@reader)
  elsif @action && @config&.subfield?
    Axn::Core::ContractForSubfields.resolve_value(@action, @config)
  else
    # Malformed sources read as absent (one doctrine — see FieldResolvers.extract_or_nil):
    # this field's own validators report against nil while the source's own type validation
    # classifies the bad value.
    Axn::Core::FieldResolvers.extract_or_nil(field: attr, provided_data: @source)
  end
end

def self.collect_errors(field:, validations:, source:, action: nil, reader: nil, config: nil)
  errors_for(validator_class_for(field:, validations:), source:, validations:, action:, reader:, config:)
end

def self.errors_for(validator_class, source:, validations:, action: nil, reader: nil, config: nil)
  validator = validator_class.new(source)

  # Set the action context for model field resolution + symbol-argument delegation
  validator.instance_variable_set(:@action, action)
  validator.instance_variable_set(:@validations, validations)
  validator.instance_variable_set(:@reader, reader)
  validator.instance_variable_set(:@config, config)

  validator.valid?
  validator.errors
end
```

(The old `@validations&.key?(:model)` gate on the reader branch is deliberately removed — every subfield with a reader now reads through it.)

In `lib/axn/executor.rb` `_collect_contract_failures`, add `config:` to the call:

```ruby
errors = Axn::Validation::Fields.collect_errors(
  field: config.field,
  validations: coerce_input_types ? _with_effective_coerce(config.validations) : config.validations,
  source: config.subfield? ? _resolved_parent_value(config) : @action.internal_context,
  action: @action,
  reader: config.subfield? ? config.reader_as : nil,
  config: config.subfield? ? config : nil,
)
```

- [ ] **Step 4: Run new tests, then full suite**

Run: `bundle exec rspec spec/axn/core/validations/on_subfields_spec.rb` then `bundle exec rspec`
Expected: PASS. Watch for existing specs that asserted the OLD failure (`Name can't be blank` on omission with a defaulted subfield under a model) — those now succeed by design; update the assertions and cite PRO-2889 in the spec context name.

- [ ] **Step 5: CHANGELOG**

Add under `## Unreleased`:

```markdown
- [FEAT] Value-level subfield defaults (PRO-2889): a subfield `default:` now guarantees the *resolved* value — reader and validation both — even when the wire write-back cannot apply it (a `model:`/non-object parent, an id-resolved or caller-supplied record whose attribute is nil, a malformed parent). Previously the same declaration was silently dead on those paths and the call failed the subfield's own validation.
```

- [ ] **Step 6: Commit**

```bash
git add lib/axn/core/validation/fields.rb lib/axn/executor.rb spec/axn/core/validations/on_subfields_spec.rb CHANGELOG.md
git commit -m "PRO-2889: Validation reads subfield values through the shared resolution (value-level defaults)"
```

---

### Task 4: Defaults write only Hash chains (mutation removal)

**Files:**
- Modify: `lib/axn/executor.rb` (`apply_inbound_defaults!`, new `_default_chain_hash_writable?`)
- Test: `spec/axn/core/validations/on_subfields_spec.rb` (extend PRO-2889 block)
- Modify: `CHANGELOG.md` (`[BREAKING]` entry)

**Interfaces:**
- Consumes: value-level fallback (Tasks 2–3) — skipped writes are rescued at read.
- Produces: `default:` never mutates a caller-supplied non-Hash object; Proc defaults on skipped chains evaluate exactly once (at read).

- [ ] **Step 1: Write the failing tests**

```ruby
  context "write-path behavior (PRO-2889)" do
    it "never mutates a caller-supplied record with a default" do
      rec = FallbackCompany.new(id: 1)
      action = build_axn do
        expects :company, model: { klass: FallbackCompany, finder: :fetch }, allow_nil: true
        expects :name, on: :company, type: String, default: "x"
        def call = nil
      end
      expect(action.call(company: rec)).to be_ok
      expect(rec.name).to be_nil
    end

    it "evaluates a Proc default exactly once when the write chain is refused" do
      calls = 0
      counter = -> { calls += 1; "x" }
      action = build_axn do
        expects :company, model: { klass: FallbackCompany, finder: :fetch }, allow_nil: true
        expects :name, on: :company, type: String, default: counter
        exposes :n, allow_nil: true
        def call = expose(n: name)
      end
      expect(action.call.n).to eq("x")
      expect(calls).to eq(1)
    end

    it "still materializes fully-object-shaped chains over an explicit nil (unchanged)" do
      action = build_axn do
        expects :payload, type: Hash, allow_nil: true
        expects :id, on: "payload.meta", type: Integer, default: 42
        exposes :got
        def call = expose(got: id)
      end
      expect(action.call(payload: nil).got).to eq(42)
    end
  end
```

Note: the Proc-counter closure must be visible inside `build_axn` — follow the file's existing pattern for closures over spec-local variables (existing specs pass values via `let` + local capture; if `build_axn`'s block scoping blocks it, define the counter with a spec-level `$` — check neighbors first and match).

- [ ] **Step 2: Run to verify the mutation test fails**

Run: `bundle exec rspec spec/axn/core/validations/on_subfields_spec.rb -e "write-path behavior"`
Expected: `rec.name` is `"x"` today (mutation) → FAIL; Proc-once may also fail (evaluated by the write pass then again by the reader).

- [ ] **Step 3: Implement the gate**

In `lib/axn/executor.rb` `apply_inbound_defaults!`, after the `_write_chain_materializable?` guard, add:

```ruby
        next unless _default_chain_hash_writable?(path)
```

Add the helper next to `_write_chain_materializable?`:

```ruby
    # A default: writes only into Hash chains (copy-on-write) or materializes absent ones. A
    # PRESENT non-Hash level anywhere along the write path (a caller-supplied record, a Struct)
    # is never mutated by a declared default (PRO-2889) — the write is skipped (before the
    # default is even evaluated, so a Proc runs once, at read) and the value-level fallback
    # supplies the default to readers and validation instead. Depth 0 assigns the root key
    # directly (no object mutation), so it always writes.
    def _default_chain_hash_writable?(path)
      return true if path.wire_path.size == 1

      value = @context.provided_data[path.wire_path.first]
      path.wire_path[1..-2].each do |seg|
        return true if value.nil? # absent from here down — materialized fresh, nothing to mutate

        return false unless value.is_a?(Hash)

        value = Core::FieldResolvers.extract_or_nil(field: seg.to_s, provided_data: value)
      end
      value.nil? || value.is_a?(Hash)
    end
```

- [ ] **Step 4: Run new tests + full suite**

Run: `bundle exec rspec spec/axn/core/validations/on_subfields_spec.rb -e "write-path behavior" && bundle exec rspec`
Expected: PASS. Any existing spec asserting default-into-record mutation (search: `grep -rn "update_object\|name=" spec/axn/core/validations/default_assignment_spec.rb spec/axn/core/validations/on_subfields_spec.rb`) flips to the new behavior — update it to assert non-mutation + reader fallback.

- [ ] **Step 5: CHANGELOG**

```markdown
- [BREAKING] A subfield `default:` no longer writes into a caller-supplied non-Hash parent (e.g. setting an attribute on a passed-in record). Previously `expects :name, on: :company, default: "x"` mutated the caller's record when its attribute was nil; now the record is untouched and the default is visible through the axn's reader/validation only (value-level defaults). Read the axn's reader instead of the mutated object.
```

- [ ] **Step 6: Commit**

```bash
git add lib/axn/executor.rb spec/axn/core/validations/on_subfields_spec.rb CHANGELOG.md
git commit -m "PRO-2889: Defaults write only Hash chains; never mutate caller objects"
```

---

### Task 5: Reflection co-update — delete the model-subtree carve-out

**Files:**
- Modify: `lib/axn/reflection/schema.rb` (delete `node_omittable_without_synthesis?` at :139-145; rework `apply_model_id_requiredness!` at :845-859; thread `ann` from `build_input` :98-101)
- Test: `spec/axn/reflection/schema_spec.rb`

**Interfaces:**
- Consumes: value-level defaults runtime (Tasks 2–4) — the schema now mirrors it.
- Produces: `apply_model_id_requiredness!(config, children, field_configs, properties, required, ann)` (new `ann` param).

- [ ] **Step 1: Write the failing schema tests**

Add to `spec/axn/reflection/schema_spec.rb` (near the existing `apply_model_id_requiredness` coverage; use only forever-legal contracts — defaulted or Proc-defaulted descendants, NOT bare required ones, which Task 7 makes illegal):

```ruby
describe "model id requiredness with value-level defaults (PRO-2889)" do
  let(:model_class) do
    Class.new do
      def self.fetch(id) = nil
    end
  end

  before { stub_const("SchemaCo", model_class) }

  it "does not require the id when the nil-tolerant model's descendants are all defaulted/optional" do
    action = build_axn do
      expects :company, model: { klass: SchemaCo, finder: :fetch }, allow_nil: true
      expects :name, on: :company, type: String, default: "x"
      def call = nil
    end
    expect(action.input_schema[:required].to_a).not_to include("company_id")
  end

  it "keeps the id required for a Proc-defaulted descendant (strict mode: unknowable → required)" do
    action = build_axn do
      expects :company, model: { klass: SchemaCo, finder: :fetch }, allow_nil: true
      expects :name, on: :company, type: String, default: -> { "x" }
      def call = nil
    end
    expect(action.input_schema[:required]).to include("company_id")
  end
end
```

- [ ] **Step 2: Run to verify the first fails**

Run: `bundle exec rspec spec/axn/reflection/schema_spec.rb -e "value-level defaults"`
Expected: first FAILS (`company_id` currently required — the carve-out treats the defaulted child as non-omittable).

- [ ] **Step 3: Implement**

In `lib/axn/reflection/schema.rb`:

1. Delete `node_omittable_without_synthesis?` (:139-145) entirely.
2. `build_input`'s second pass passes `ann`:

```ruby
        field_configs.select { |config| config.validations[:model] }.each do |config|
          children = tree.roots[config.reader_as].children
          apply_model_id_requiredness!(config, children, field_configs, properties, required, ann)
        end
```

3. Rework `apply_model_id_requiredness!` — replace the `model_omittable` computation and its carve-out comment:

```ruby
      def apply_model_id_requiredness!(config, children, field_configs, properties, required, ann)
        id_field, = model_id_property(config)
        explicit_id = field_configs.find { |c| c.field == id_field }
        # A default at ANY depth under the model applies at read time (value-level defaults,
        # PRO-2889) — no synthesis is involved — so descendant omittability is the ordinary
        # annotation-derived rule, same as every other parent.
        model_omittable = optional_for_schema?(config) && !children_require_presence?(children, ann)
        return if model_omittable || (explicit_id && usable_default?(explicit_id, subfield: false))

        key = id_field.to_s
        required << key unless required.include?(key)
        reject_null!(properties[id_field]) if properties[id_field]
      end
```

Update the method's header comment: the omittability condition now reads "…AND no descendant requires presence per its own annotation (a defaulted descendant is self-rescuing at read time)". Delete the stale "no default anywhere in a model's subtree can ever apply" paragraph.

- [ ] **Step 4: Run schema suite + full suite**

Run: `bundle exec rspec spec/axn/reflection/schema_spec.rb && bundle exec rspec`
Expected: PASS. Existing specs asserting `company_id` required *because of* a defaulted descendant flip — update them (they document the pre-capability runtime, which no longer exists).

- [ ] **Step 5: Commit**

```bash
git add lib/axn/reflection/schema.rb spec/axn/reflection/schema_spec.rb
git commit -m "PRO-2889: Schema mirrors value-level defaults under model parents"
```

---

### Task 6: `satisfiability:` mode on the canonical derivation

**Files:**
- Modify: `lib/axn/reflection/schema.rb` (`derive_annotations` :214-218, `annotate_node!` :221-243, `node_optional?` :298-302, `field_optional?` :346-372, `usable_default?` :400-408, `subtree_has_usable_subfield_default?` :314-319, `optional_for_schema?` :379-383)
- Test: `spec/axn/reflection/schema_spec.rb`

**Interfaces:**
- Produces: every listed predicate accepts `satisfiability: false` keyword (default = today's strict behavior, zero call-site churn). Semantic delta in satisfiability mode, verbatim from the spec: **a Proc default counts as a rescue**; nothing else changes. Task 7 consumes `derive_annotations(roots, satisfiability: true)`, `field_optional?(config, children, ann, satisfiability: true)`, `node_optional?(node, ann, configs, satisfiability: true)`, `optional_for_schema?(config, satisfiability: true)`, `usable_default?(config, subfield:, satisfiability: true)`.

- [ ] **Step 1: Write the failing unit test**

```ruby
describe "satisfiability mode (PRO-2889)" do
  it "counts a Proc default as a rescue only in satisfiability mode" do
    action = build_axn do
      expects :payload, type: Hash, allow_nil: true
      expects :id, on: :payload, type: Integer, default: -> { 1 }
      def call = nil
    end
    resolved = action._resolved_subfields
    id_node = resolved.roots[:payload].children[:id]

    strict = Axn::Reflection::Schema.derive_annotations(resolved.roots)
    sat    = Axn::Reflection::Schema.derive_annotations(resolved.roots, satisfiability: true)

    expect(strict[id_node].required).to be(true)   # schema: unknowable → required (safe direction)
    expect(sat[id_node].required).to be(false)     # detector: the Proc DOES apply at runtime
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `bundle exec rspec spec/axn/reflection/schema_spec.rb -e "satisfiability mode"`
Expected: FAIL — `derive_annotations` doesn't accept the keyword.

- [ ] **Step 3: Thread the flag**

In `lib/axn/reflection/schema.rb`, change signatures and thread the keyword (bodies otherwise identical):

```ruby
def derive_annotations(roots, satisfiability: false)
  ann = {}.compare_by_identity
  roots.each_value { |node| annotate_node!(node, ann, satisfiability:) }
  ann
end

def annotate_node!(node, ann, satisfiability: false)
  node.children.each_value { |child| annotate_node!(child, ann, satisfiability:) }
  required = !node_optional?(node, ann, node.configs, satisfiability:)
  # ... nullable branch unchanged (nullability is a schema concern; the detector reads `required`)
```

```ruby
def node_optional?(node, ann, configs = node.configs, satisfiability: false)
  return !subtree_requires_presence?(node, ann) if node.implicit?

  configs.all? { |c| usable_default?(c, subfield: true, satisfiability:) || (nil_accepted?(c) && !subtree_requires_presence?(node, ann)) }
end
```

```ruby
def field_optional?(config, children, ann, satisfiability: false)
  # ...same body, with:
  return true if usable_default?(config, subfield: false, satisfiability:)
  # ...and:
  subtree_has_usable_subfield_default?(children, satisfiability:) && !has_required_child
end
```

```ruby
def subtree_has_usable_subfield_default?(children, satisfiability: false)
  children.values.any? do |node|
    node.configs.any? { |c| usable_default?(c, subfield: true, satisfiability:) } ||
      subtree_has_usable_subfield_default?(node.children, satisfiability:)
  end
end
```

```ruby
def optional_for_schema?(config, subfield: false, satisfiability: false)
  return true if usable_default?(config, subfield:, satisfiability:)

  nil_accepted?(config)
end
```

`usable_default?` — the one real change; replace the `return false if value.nil? || value.is_a?(Proc)` line and extend the header comment:

```ruby
def usable_default?(config, subfield:, satisfiability: false)
  return false unless config.respond_to?(:default)

  value = config.default
  return false if value.nil?
  # The governing split (PRO-2889): a Proc default is unknowable at declaration. Strict (schema)
  # mode resolves toward required — the safe direction — while satisfiability mode (the
  # declaration-rejection detector) resolves toward satisfiable: the Proc DOES apply at runtime,
  # and rejection is reserved for provably dead declarations.
  return satisfiability if value.is_a?(Proc)
  return false if presence_blank?(value) && presence_rejects_blank?(config)

  subfield ? config.applied_default? : true
end
```

- [ ] **Step 4: Run new test + full suite (default mode unchanged)**

Run: `bundle exec rspec spec/axn/reflection/schema_spec.rb -e "satisfiability mode" && bundle exec rspec`
Expected: PASS both — default-mode behavior is byte-identical.

- [ ] **Step 5: Commit**

```bash
git add lib/axn/reflection/schema.rb spec/axn/reflection/schema_spec.rb
git commit -m "PRO-2889: satisfiability mode on the omittability derivation"
```

---

### Task 7: Families 1+3 — the dead-nil-tolerance detector

**Files:**
- Create: `lib/axn/reflection/subfield_contradictions.rb`
- Create: `spec/axn/reflection/subfield_contradictions_spec.rb`
- Modify: `lib/axn/core/contract_for_subfields.rb` (require + wire into `_expects_subfields` after `_validate_subfield_reader_names!`, before the config commit)
- Modify: existing specs that declared now-illegal contracts (see Step 6)
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: `Schema.derive_annotations(roots, satisfiability: true)` and mode-flagged predicates (Task 6); `SubfieldTree.build`; `Internal::FieldConfig.model_id_key`.
- Produces: `Axn::Reflection::SubfieldContradictions.check!(field_configs, subfield_configs, new_configs:)` — raises `ArgumentError` on the first contradiction; Task 8 adds the family-2 check inside the same entry point (a private `check_dead_nil_tolerance!` stays; Task 8 prepends `check_unanswerable_segments!`).

- [ ] **Step 1: Write the failing detector specs**

Create `spec/axn/reflection/subfield_contradictions_spec.rb`:

```ruby
# frozen_string_literal: true

RSpec.describe Axn::Reflection::SubfieldContradictions do
  let(:company_class) do
    Class.new do
      attr_accessor :id, :name

      def initialize(id:, name: nil)
        @id = id
        @name = name
      end

      def self.fetch(id) = new(id:)
    end
  end

  before { stub_const("DeadCo", company_class) }

  describe "family 1: dead nil-tolerance" do
    it "rejects a nil-tolerant top-level parent with an unrescued required deep descendant" do
      expect do
        build_axn do
          expects :payload, type: Hash, allow_nil: true
          expects :id, on: "payload.meta", type: Integer
        end
      end.to raise_error(ArgumentError, /:payload is declared nil-tolerant.*:meta\.id.*required/m)
    end

    it "rejects a nil-tolerant INTERMEDIATE subfield with a required child" do
      expect do
        build_axn do
          expects :payload, type: Hash
          expects :meta, on: :payload, type: Hash, allow_nil: true
          expects :id, on: :meta, type: Integer
        end
      end.to raise_error(ArgumentError, /:meta is declared nil-tolerant/)
    end

    it "rejects optional: spelling the same way" do
      expect do
        build_axn do
          expects :payload, type: Hash, optional: true
          expects :id, on: :payload, type: Integer
        end
      end.to raise_error(ArgumentError, /:payload is declared nil-tolerant/)
    end

    # The rescue tail as living specs — all LEGAL:
    it "accepts a literal default on the stranded node" do
      expect do
        build_axn do
          expects :payload, type: Hash, allow_nil: true
          expects :id, on: "payload.meta", type: Integer, default: 42
        end
      end.not_to raise_error
    end

    it "accepts a Proc default on the stranded node (unknowable → satisfiable)" do
      expect do
        build_axn do
          expects :payload, type: Hash, allow_nil: true
          expects :id, on: "payload.meta", type: Integer, default: -> { 42 }
        end
      end.not_to raise_error
    end

    it "accepts a usable default on the parent itself" do
      expect do
        build_axn do
          expects :payload, type: Hash, allow_nil: true, default: { meta: { id: 1 } }
          expects :id, on: "payload.meta", type: Integer
        end
      end.not_to raise_error
    end

    it "rejects a blank default that an active presence validator would reject" do
      expect do
        build_axn do
          expects :payload, type: Hash, allow_nil: true
          expects :name, on: :payload, type: String, default: ""
        end
      end.to raise_error(ArgumentError, /:payload is declared nil-tolerant/)
    end
  end

  describe "family 3: the model flavor" do
    it "rejects a nil-tolerant model parent with an unrescued required descendant" do
      expect do
        build_axn do
          expects :company, model: { klass: DeadCo, finder: :fetch }, allow_nil: true
          expects :name, on: :company, type: String
        end
      end.to raise_error(ArgumentError, /:company is declared nil-tolerant.*model/m)
    end

    it "accepts a defaulted required descendant (value-level defaults make it satisfiable)" do
      expect do
        build_axn do
          expects :company, model: { klass: DeadCo, finder: :fetch }, allow_nil: true
          expects :name, on: :company, type: String, default: "x"
        end
      end.not_to raise_error
    end

    it "accepts a record-supplying default on the model itself" do
      expect do
        build_axn do
          expects :company, model: { klass: DeadCo, finder: :fetch }, allow_nil: true, default: -> { DeadCo.new(id: 9) }
          expects :name, on: :company, type: String
        end
      end.not_to raise_error
    end

    it "accepts a defaulted explicit id sibling declared FIRST" do
      expect do
        build_axn do
          expects :company_id, type: Integer, default: 42
          expects :company, model: { klass: DeadCo, finder: :fetch }, allow_nil: true
          expects :name, on: :company, type: String
        end
      end.not_to raise_error
    end
  end
end
```

- [ ] **Step 2: Run to verify failures**

Run: `bundle exec rspec spec/axn/reflection/subfield_contradictions_spec.rb`
Expected: FAIL — module doesn't exist; the "rejects" examples raise nothing.

- [ ] **Step 3: Implement the detector**

Create `lib/axn/reflection/subfield_contradictions.rb`:

```ruby
# frozen_string_literal: true

require "axn/reflection/subfield_tree"
require "axn/reflection/schema"

module Axn
  module Reflection
    # Declaration-time rejection of contradiction-only subfield contracts (PRO-2889). Walks a
    # CANDIDATE tree (prospective configs included; nothing committed) and raises ArgumentError on
    # the first provable contradiction. Every judgment reuses the canonical derivation in
    # satisfiability mode (unknowable-at-declaration counts as satisfiable) — never a parallel
    # re-derivation, the failure mode that sank PRO-2877's pulled detectors. Side-effect-free:
    # inspects declared configs only, never runs user code.
    module SubfieldContradictions
      module_function

      # `new_configs` is the prospective batch (consumed by the family-2 check added in a later
      # commit — earlier configs were judged at their own declaration; the dead-tolerance walk
      # re-scans the whole tree because a NEW required descendant can kill an OLD tolerance).
      def check!(field_configs, subfield_configs, new_configs:)
        tree = SubfieldTree.build(field_configs, subfield_configs)
        check_dead_nil_tolerance!(tree, field_configs)
      end

      # Families 1+3: a statically-declared nil-tolerance (allow_nil:/optional:/allow_blank:/
      # presence: false) whose omission unconditionally fails — the flag advertises an omission
      # the contract can never accept. Keyed on STATIC declarations only, so a future dynamic/
      # conditional requiredness signal (PRO-2881) is outside the reject set by construction.
      def check_dead_nil_tolerance!(tree, field_configs)
        ann = Schema.derive_annotations(tree.roots, satisfiability: true)

        field_configs.each do |config|
          next if Schema::EXCLUDED_FROM_INPUT_SCHEMA.include?(config.field)
          next unless Schema.nil_accepted?(config)

          node = tree.roots[config.reader_as]
          omittable = if config.validations[:model]
                        model_omittable?(config, node, field_configs, ann)
                      else
                        Schema.field_optional?(config, node.children, ann, satisfiability: true)
                      end
          raise_dead_tolerance!(config, config.field, node, ann) unless omittable
        end

        each_explicit_node(tree.roots) do |parent, key, node, wire_path|
          node.configs.each do |config|
            next unless Schema.nil_accepted?(config)
            next if Schema.node_optional?(node, ann, [config], satisfiability: true)
            next if config.validations[:model] && defaulted_id_sibling?(parent, key)

            raise_dead_tolerance!(config, wire_path.join("."), node, ann)
          end
        end
      end

      # Depth-first over every explicit subfield node, yielding (parent_node, key, node, wire_path).
      def each_explicit_node(roots, &block)
        roots.each do |root_key, root|
          walk_children(root, [root_key], &block)
        end
      end

      def walk_children(parent, prefix, &block)
        parent.children.each do |key, node|
          path = prefix + [key]
          yield(parent, key, node, path) unless node.implicit?
          walk_children(node, path, &block)
        end
      end

      # Mirrors apply_model_id_requiredness!'s omittability (satisfiability flavor): the model may
      # be omitted when it is itself optional-for-schema AND no child subtree requires presence —
      # OR a defaulted explicit `<field>_id` sibling supplies the lookup token on omission.
      def model_omittable?(config, node, field_configs, ann)
        explicit_id = field_configs.find { |c| c.field == Internal::FieldConfig.model_id_key(config.field) }
        return true if explicit_id && Schema.usable_default?(explicit_id, subfield: false, satisfiability: true)

        Schema.optional_for_schema?(config, satisfiability: true) && !Schema.children_require_presence?(node.children, ann)
      end

      # A model SUBFIELD's analog of the explicit-id-sibling rescue: a sibling `<field>_id` subfield
      # with a satisfiability-usable default supplies the token when the model key is omitted.
      def defaulted_id_sibling?(parent, key)
        sibling = parent.children[Internal::FieldConfig.model_id_key(key)]
        return false unless sibling

        sibling.configs.any? { |c| Schema.usable_default?(c, subfield: true, satisfiability: true) }
      end

      # The shallowest explicit required descendant's dotted path (for the message) — descends
      # through implicit intermediates that are required only transitively.
      def first_required_descendant(node, ann, prefix = [])
        node.children.each do |key, child|
          path = prefix + [key]
          return path if ann[child].required && !child.implicit?

          deeper = first_required_descendant(child, ann, path)
          return deeper if deeper
        end
        nil
      end

      def raise_dead_tolerance!(config, owner, node, ann)
        stranded = first_required_descendant(node, ann)&.join(".")
        model_hint = if config.validations[:model]
                       " For a model: field, a record-supplying default: on :#{owner} or a defaulted " \
                         "#{owner}_id sibling (declared first) also rescues omission."
                     else
                       ""
                     end
        raise ArgumentError,
              ":#{owner} is declared nil-tolerant (allow_nil:/optional:/allow_blank:), but " \
              "#{stranded ? ":#{stranded}" : 'its subtree'} is required and nothing rescues an omitted :#{owner} — " \
              "the tolerance can never be exercised (every nil/omitted :#{owner} fails validation). " \
              "Drop the tolerance on :#{owner}, or mark #{stranded ? ":#{stranded}" : 'the subtree'} optional: or give it a " \
              "default: (declare rescuing defaults BEFORE the dependent subfield).#{model_hint}"
      end
    end
  end
end
```

- [ ] **Step 4: Wire into declaration**

In `lib/axn/core/contract_for_subfields.rb`: add `require "axn/reflection/subfield_contradictions"` at the top (next to the existing `require "axn/reflection/resolved_subfields"`), and in `_expects_subfields` after `_validate_subfield_reader_names!(configs)` and before the `self.subfield_configs =` commit:

```ruby
            # Contradiction-only contracts raise BEFORE any class mutation (PRO-2889): the candidate
            # tree includes the prospective configs, so a new required descendant that kills an
            # already-declared tolerance is caught at the declaration that completes it.
            Axn::Reflection::SubfieldContradictions.check!(internal_field_configs, subfield_configs + configs, new_configs: configs)
```

- [ ] **Step 5: Run the detector specs**

Run: `bundle exec rspec spec/axn/reflection/subfield_contradictions_spec.rb`
Expected: PASS.

- [ ] **Step 6: Sweep newly-illegal in-repo contracts**

Run: `bundle exec rspec 2>&1 | tail -40` and iterate. Known hot spots: `spec/axn/core/validations/on_subfields_spec.rb` (nil-tolerant-parent contexts around lines 203, 372, 392, 634) and `spec/axn/reflection/schema_spec.rb` (nil-tolerant + required-descendant reflection contracts). Decision rules per failing spec:

- The spec asserted **runtime stranding** (`call(payload: nil)` fails on a required child under a tolerant parent): the contract is now illegal — move the coverage to `subfield_contradictions_spec.rb` as a rejection positive, and if the runtime behavior itself still needs coverage, respell with a **required** parent (tolerance removed) — stranding semantics under a nil value are unchanged there.
- The spec asserted **reflection overrides the tolerance** (required emitted despite `allow_nil:`): respell with a **Proc-defaulted** required child — the legal gap contract that still exercises the strict-mode override.
- The spec used the tolerant parent incidentally: mark the child `optional:` or give it a default.

Then: `bundle exec rspec`
Expected: PASS.

- [ ] **Step 7: CHANGELOG**

```markdown
- [BREAKING] A statically nil-tolerant field (`allow_nil:`/`optional:`/`allow_blank:`/`presence: false`) whose omission can never validate — an unrescued required subfield anywhere beneath it — now raises `ArgumentError` at class definition (PRO-2889, families 1+3). Previously the class loaded and every nil/omitted call failed on the buried descendant (the tolerance was a lie). The error names both declarations and the fixes; rescues (defaults at any depth, record-supplying model defaults, defaulted `<field>_id` siblings declared first) keep their contracts legal.
```

- [ ] **Step 8: Commit**

```bash
git add lib/axn/reflection/subfield_contradictions.rb lib/axn/core/contract_for_subfields.rb spec/ CHANGELOG.md
git commit -m "PRO-2889: Reject dead nil-tolerance at declaration (families 1+3)"
```

---

### Task 8: Family 2 — unanswerable-segment detector

**Pre-req:** PR #162 merged; `git rebase origin/main`; `bundle exec rspec` green.

**Files:**
- Modify: `lib/axn/reflection/schema.rb` (add `SEGMENT_JUDGED_SCALARS`, `branch_answers_segment?`, `config_answers_segment?`)
- Modify: `lib/axn/core/contract_for_subfields.rb` (extract `deepest_reader_index` from `resolve_parent` :33-45)
- Modify: `lib/axn/reflection/subfield_contradictions.rb` (add `check_unanswerable_segments!`, called FIRST in `check!`)
- Test: `spec/axn/reflection/subfield_contradictions_spec.rb`, `spec/axn/reflection/schema_spec.rb`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: `SubfieldTree::ResolvedPath` (`ancestors`, `parent_index`), `Schema.shape_members_at`, `Schema.object_type_branches`.
- Produces: `Schema.config_answers_segment?(config, segment)`, `ContractForSubfields.deepest_reader_index(path)` (nil-able Integer; `resolve_parent` reuses it).

- [ ] **Step 1: Write the failing specs**

Add to `spec/axn/reflection/subfield_contradictions_spec.rb`:

```ruby
  describe "family 2: unanswerable segments" do
    it "rejects a dotted name whose segment reads through a scalar shape member" do
      expect do
        build_axn do
          expects :payload, type: Hash do
            field :bar, type: String
          end
          expects "bar.baz", on: :payload, type: Integer
        end
      end.to raise_error(ArgumentError, /"bar\.baz".*can never resolve.*baz/m)
    end

    it "rejects a multi-segment name off a declared-scalar explicit parent" do
      expect do
        build_axn do
          expects :payload, type: Hash
          expects :bar, on: :payload, type: String
          expects "a.b", on: :bar, type: Integer
        end
      end.to raise_error(ArgumentError, /can never resolve/)
    end

    it "rejects an unanswerable segment via a dotted on: path" do
      expect do
        build_axn do
          expects :payload, type: Hash
          expects :bar, on: :payload, type: String
          expects :id, on: "payload.bar", type: Integer
        end
      end.to raise_error(ArgumentError, /can never resolve/)
    end

    it "rejects regardless of the subfield's own optional:/default: (dead machinery)" do
      expect do
        build_axn do
          expects :payload, type: Hash do
            field :bar, type: String
          end
          expects "bar.baz", on: :payload, type: Integer, optional: true, default: 1
        end
      end.to raise_error(ArgumentError, /can never resolve/)
    end

    # Legal reader patterns — the false-positives that killed the pulled detector:
    it "accepts a method-answerable segment on a scalar (Array#count)" do
      expect do
        build_axn do
          expects :payload, type: Hash
          expects :items, on: :payload, type: Array
          expects :count, on: :items, type: Integer
        end
      end.not_to raise_error
    end

    it "accepts String#length on a scalar shape member" do
      expect do
        build_axn do
          expects :payload, type: Hash do
            field :bar, type: String
          end
          expects "bar.length", on: :payload, type: Integer
        end
      end.not_to raise_error
    end

    it "accepts segments through unknown classes and model parents (optimistic)" do
      data_klass = Class.new { def self.fetch(id) = nil }
      stub_const("OpaqueThing", data_klass)
      expect do
        build_axn do
          expects :payload, type: Hash
          expects :thing, on: :payload, type: OpaqueThing
          expects "a.b", on: :thing, type: Integer, optional: true
          expects :company, on: :payload, model: { klass: OpaqueThing, finder: :fetch }, optional: true
          expects "x.y", on: :company, type: Integer, optional: true
        end
      end.not_to raise_error
    end
  end
```

- [ ] **Step 2: Run to verify failures**

Run: `bundle exec rspec spec/axn/reflection/subfield_contradictions_spec.rb -e "family 2"`
Expected: the "rejects" examples FAIL (nothing raises).

- [ ] **Step 3: Add the Schema answerability predicates**

In `lib/axn/reflection/schema.rb` (near `object_type_branches`):

```ruby
      # The builtin scalars whose reader-method surface is statically judgeable: for these exact
      # families, an instance answers a segment read iff the class publicly defines the method
      # (post-PRO-2886 extraction: a Hash-like source reads any key; everything else is a
      # public_send). Anything outside this list — Data/Struct/custom classes, model records —
      # may answer dynamically, so it is never judged (optimistic: rejection needs proof).
      SEGMENT_JUDGED_SCALARS = [String, Symbol, Integer, Float, Numeric, Array, Date, DateTime, Time, TrueClass, FalseClass].freeze

      # Whether ONE admissible declared branch can answer reading `segment` off its value.
      def branch_answers_segment?(branch, segment)
        return true if branch == :params

        klasses = case branch
                  when :uuid then [String]
                  when :boolean then [TrueClass, FalseClass]
                  else [branch]
                  end
        klasses.any? do |k|
          next true unless k.is_a?(Class)
          next true if k <= Hash

          judged = SEGMENT_JUDGED_SCALARS.any? { |s| k <= s }
          !judged || k.public_method_defined?(segment)
        end
      end

      # Whether a config's declared type admits SOME branch that can answer `segment`. A `model:`
      # route resolves to a record, whose method surface is never statically refutable.
      def config_answers_segment?(config, segment)
        return true if config.validations[:model]

        object_type_branches(config).any? { |branch| branch_answers_segment?(branch, segment) }
      end
```

- [ ] **Step 4: Extract `deepest_reader_index`**

In `lib/axn/core/contract_for_subfields.rb`, add next to `resolve_parent` and reuse it there:

```ruby
      # The chain index of the deepest reader-bearing ancestor at-or-before the `on:` target — the
      # node resolve_parent public_sends; the hops AFTER it are the ones the runtime actually digs.
      # Shared with the family-2 answerability check so the two can't disagree about which segments
      # are dig-read. Nil when no ancestor bears a reader (the recipe fallback path).
      def self.deepest_reader_index(path)
        (0..path.parent_index).select { |i| _reader_config(path.ancestors[i].first) }.max
      end
```

and in `resolve_parent` replace the inline computation:

```ruby
        reader_index = deepest_reader_index(path)
```

- [ ] **Step 5: Add the family-2 check to the detector**

In `lib/axn/reflection/subfield_contradictions.rb`, `check!` becomes:

```ruby
      def check!(field_configs, subfield_configs, new_configs:)
        tree = SubfieldTree.build(field_configs, subfield_configs)
        check_unanswerable_segments!(tree, new_configs) # first: its message is the more specific when both fire
        check_dead_nil_tolerance!(tree, field_configs)
      end
```

Add:

```ruby
      # Family 2: a subfield whose resolution provably cannot traverse some segment — for EVERY
      # contract-valid input, the read settles absent (post-PRO-2886: a failed dig/method read is
      # UnextractableError → nil). Judged only along the hops the runtime actually digs (after the
      # deepest reader-bearing ancestor — the same recipe resolve_parent uses), against each
      # position's enforced declarations: its explicit configs plus the shape members an implicit
      # position stands in for (ALL colliding members, nestable or not — answerability is about
      # reading through the member's value, not nesting under it). Rejected regardless of the
      # subfield's own optional:/default: — an unreachable path is dead machinery (the shipped
      # family-4 precedent), and with a default it degenerates to a constant field.
      def check_unanswerable_segments!(tree, new_configs)
        new_configs.each do |config|
          path = tree.index[config]
          next if path.nil? # ambient-anchored — resolved per-invocation, out of scope

          reader_index = Axn::Core::ContractForSubfields.deepest_reader_index(path)
          next if reader_index.nil?

          carried = []
          path.ancestors.each_with_index do |(node, seg), i|
            if i >= reader_index && (blocker = segment_blocker(node, carried, seg))
              raise_unanswerable!(config, blocker, seg)
            end
            carried = node.children[seg]&.implicit? ? Schema.shape_members_at(node.configs + carried, seg) : []
          end
        end
      end

      # The first enforced declaration at this position that provably cannot answer `segment`
      # (nil when the position is answerable). A position with any model: route resolves to a
      # record — never refutable.
      def segment_blocker(node, carried, segment)
        return nil if node.configs.any? { |c| c.validations[:model] }

        (node.configs + carried).find { |c| !Schema.config_answers_segment?(c, segment) }
      end

      def raise_unanswerable!(config, blocker, segment)
        types = Schema.object_type_branches(blocker).map { |b| b.is_a?(Class) ? b.name : b.inspect }.join(", ")
        raise ArgumentError,
              "subfield #{config.field.inspect} (on #{config.on.inspect}) can never resolve: segment #{segment.inspect} " \
              "is read from #{blocker.field.inspect}, declared #{types}, which cannot answer it (no key access, no such " \
              "method) — no contract-valid input ever reaches this subfield. Make #{blocker.field.inspect} object-shaped, " \
              "or drop the subfield."
      end
```

- [ ] **Step 6: Run the family-2 specs + full suite; sweep**

Run: `bundle exec rspec spec/axn/reflection/subfield_contradictions_spec.rb && bundle exec rspec`
Expected: PASS after sweeping any existing spec that declared a now-illegal unanswerable path (same decision rules as Task 7 Step 6 — most likely `dropped_deep_subfields`/shape-collision contexts in `schema_spec.rb` and `subfield_tree_spec.rb`; where a spec exercised the DROP analysis with a scalar shape member, keep it legal by making the colliding member's branch a union that includes Hash, e.g. `type: [Hash, String]` — still non-nestable for the drop pass, but answerable).

- [ ] **Step 7: CHANGELOG**

```markdown
- [BREAKING] A subfield whose resolution path provably cannot be answered by any contract-valid input — e.g. `expects "bar.baz", on: :payload` where the payload shape declares `field :bar, type: String` (and `String` has no `#baz`) — now raises `ArgumentError` at class definition (PRO-2889, family 2). Previously the class loaded and the subfield silently read as absent on every call. Reader-style scalar access (`:count` on an `Array`, `"bar.length"` on a `String` member) remains legal.
```

- [ ] **Step 8: Commit**

```bash
git add lib/axn/reflection/schema.rb lib/axn/reflection/subfield_contradictions.rb lib/axn/core/contract_for_subfields.rb spec/ CHANGELOG.md
git commit -m "PRO-2889: Reject unanswerable subfield segments at declaration (family 2)"
```

---

### Task 9: Rails mirrors, docs, consumer sweep, final verification

**Files:**
- Test: `spec_rails/dummy_app/spec/axn/core/validations/validators/model_validator_spec.rb` (+ any other dummy-app specs the rejections break)
- Create: `spec_rails/dummy_app/spec/axn/pro_2889_value_level_defaults_spec.rb`
- Modify: `docs/` pages mentioning subfield `default:` behavior (locate via `grep -rln "default" docs/reference docs/guides | xargs grep -ln "on:"`)
- Modify: `CHANGELOG.md` (final read-through)

- [ ] **Step 1: Rails suite sweep**

Run: `(cd spec_rails/dummy_app && BUNDLE_GEMFILE=Gemfile bundle exec rspec)`
Expected: failures where dummy-app contracts hit the new rejections (the `expects :data, optional: true` + `expects :user, model:, on: :data` shape PRO-2881's ticket cites, around `model_validator_spec.rb:254-320`). Apply the Task 7 Step 6 decision rules; contracts with genuinely conditional intent get the child marked `optional:` plus a `# TODO(PRO-2881): conditional requiredness` breadcrumb.

- [ ] **Step 2: Rails mirror specs for the capability**

Create `spec_rails/dummy_app/spec/axn/pro_2889_value_level_defaults_spec.rb` mirroring Task 2–4's headline cases against a real AR model (use an existing dummy-app model, e.g. `User`): id-resolved nil-attribute falls back; caller-supplied record is NOT mutated (assert `record.changed?` is false after the call); required defaulted subfield under `allow_nil:` model succeeds on omission. Follow the dummy app's existing spec conventions for model setup.

```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "PRO-2889 value-level subfield defaults", type: :model do
  let(:action) do
    build_axn do
      expects :user, model: User, allow_nil: true
      expects :nickname, on: :user, type: String, optional: true, default: "anon"
      exposes :nick, allow_nil: true
      def call = expose(nick: nickname)
    end
  end

  it "falls back when the model parent is omitted" do
    expect(action.call.nick).to eq("anon")
  end

  it "does not mutate a caller-supplied record" do
    user = User.create!(name: "x") # match the dummy app's factory/creation conventions
    expect { action.call(user:) }.not_to change { user.changed? }.from(false)
  end
end
```

(Adjust `User` creation to the dummy app's actual schema/factories; the assertions are the contract.)

Run: `(cd spec_rails/dummy_app && BUNDLE_GEMFILE=Gemfile bundle exec rspec)`
Expected: PASS.

- [ ] **Step 3: Docs touch-up**

Check the published docs for statements the change falsifies: `grep -rn "default" docs/reference/instance.md docs/reference/class.md | grep -i "subfield\|on:"`. Update any claim that a subfield default "writes into the parent" or is unsupported under model parents; add a sentence on value-level defaults where subfield `default:` is documented. One line per paragraph (no hard wrapping).

- [ ] **Step 4: Consumer sweep**

For each of the five consumers (os-app, axn-mcp, axn-ruby_llm, data_shifter, slack_sender — local checkouts under `~/code/`; skip any that aren't present and note it):

```bash
grep -rn "allow_nil: true\|optional: true" --include="*.rb" <repo> | grep -B2 -A2 "on:" | head -50
```

Inventory family-1-shaped declarations (tolerant parent + `on:`-descendants) and any code reading a mutated record attribute after a call. Report findings in the PR description; fix nothing outside this repo.

- [ ] **Step 5: Full final verification**

Run: `bundle exec rspec && bundle exec rubocop && (cd spec_rails/dummy_app && BUNDLE_GEMFILE=Gemfile bundle exec rspec)`
Expected: all PASS.

- [ ] **Step 6: CHANGELOG read-through + commit**

Verify the three entries (FEAT + two BREAKING) read as one coherent story; adjust wording once, then:

```bash
git add -A
git commit -m "PRO-2889: Rails mirrors, docs, consumer-sweep notes"
```

---

## Self-review notes (already applied)

- Spec coverage: Part 1 → Tasks 2–4; reflection co-update → Task 5; Part 2 → Task 6; Part 3 → Task 7; Part 4 → Task 8; testing/compat/sweep → Tasks 7–9. Order-dependence footguns are encoded in Task 7's messages and its "declared FIRST" negative specs.
- Task 5's schema tests deliberately use only forever-legal contracts so Task 7 doesn't invalidate them.
- Type consistency: `resolve_default(action, config)` (Task 2) is what Tasks 2/3 call; `collect_errors`' `config:` kwarg (Task 3) defaults to nil so ShapeValidator's `errors_for` calls (`shape_validator.rb:50`) are untouched; `deepest_reader_index` (Task 8) is the extraction `resolve_parent` reuses; `check!`'s signature is fixed in Task 7 and only gains an internal call in Task 8.
- `build_axn` closure scoping (Task 4 Proc counter) flagged in-task: match the file's existing pattern rather than assuming.
