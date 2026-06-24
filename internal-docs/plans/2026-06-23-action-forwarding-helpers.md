# Forwarding helpers for facade actions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two small composable helpers — `expose(result)` and `inputs` — that remove the manual input-forwarding and output-re-exposing boilerplate in thin facade actions.

**Architecture:** Both are additive instance-method changes in `lib/axn/core/contract.rb`'s `InstanceMethods`. `expose` gains a single-positional-`Axn::Result` overload that forwards the intersection of declared contracts; `inputs` is a new reader returning resolved declared-inbound values as a `Hash`. One new `ContractViolation` subclass and one new reserved field name support them.

**Tech Stack:** Ruby, RSpec. Tests run via `bundle exec rspec`. Actions in specs are built with the `build_axn { … }` helper (non-Rails `spec/` suite).

## Global Constraints

- Spec design source of truth: `internal-docs/specs/2026-06-23-action-forwarding-helpers-design.md` (Linear PRO-2781).
- Pre-1.0 / alpha: breaking changes are acceptable but MUST be noted in `CHANGELOG.md`.
- `expose(result)` forwards `result.declared_fields ∩ self.class._declared_fields(:outbound)`; empty intersection raises; it never reads `ok?`/`error` or calls `fail!`.
- `inputs` returns declared-inbound wire keys only, mapped to resolved values (post-default/preprocess), as a plain `Hash`; absent optional fields are omitted.
- `inputs` is a reserved field name for both expectations and exposures.
- Commit messages are prefixed `PRO-2781` and end with the `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>` trailer.

---

### Task 1: `expose(result)` — re-expose a nested result

**Files:**
- Modify: `lib/axn/exceptions.rb` (add `ContractViolation::NoMatchingExposures`)
- Modify: `lib/axn/core/contract.rb` (overload `expose`, add private `_expose_from_result`)
- Test: `spec/axn/core/expose_result_spec.rb` (create)

**Interfaces:**
- Consumes: `Axn::Result#declared_fields` (public reader), `self.class._declared_fields(:outbound)` (class method, already called from `_build_context_facade`), `@__context.exposed_data` (already written by `expose`).
- Produces: `expose(result)` — when given exactly one positional `Axn::Result` and no kwargs, forwards the declared-field intersection into `exposed_data` and returns; raises `Axn::ContractViolation::NoMatchingExposures` on empty intersection. All other `expose` call shapes are unchanged.

- [ ] **Step 1: Write the failing test**

Create `spec/axn/core/expose_result_spec.rb`:

```ruby
# frozen_string_literal: true

RSpec.describe "expose(result) forwarding" do
  let(:child) do
    build_axn do
      expects :x, optional: true
      exposes :doubled, :echoed, optional: true
      def call
        expose doubled: (x || 0) * 2, echoed: x
      end
    end
  end

  it "forwards the intersection of declared exposures on an ok result" do
    c = child
    parent = build_axn do
      exposes :doubled, optional: true # deliberately NOT echoed
      define_method(:call) { expose(c.call(x: 3)) }
    end

    result = parent.call
    expect(result).to be_ok
    expect(result.doubled).to eq(6)
    expect(result).not_to respond_to(:echoed)
  end

  it "forwards what a failed child managed to expose, without raising" do
    failing = build_axn do
      exposes :record, optional: true
      def call
        expose record: "partial"
        fail! "boom"
      end
    end
    f = failing
    parent = build_axn do
      exposes :record, optional: true
      define_method(:call) { expose(f.call) } # no fail! — isolate forwarding
    end

    expect(parent.call.record).to eq("partial")
  end

  it "forwards nil for a declared field the child never exposed" do
    early_fail = build_axn do
      exposes :record, optional: true
      def call
        fail! "boom before expose"
      end
    end
    e = early_fail
    parent = build_axn do
      exposes :record, optional: true
      define_method(:call) { expose(e.call) }
    end

    expect(parent.call.record).to be_nil
  end

  it "raises when there is no field in common to forward" do
    c = child
    parent = build_axn do
      exposes :unrelated, optional: true
      define_method(:call) { expose(c.call(x: 1)) }
    end

    expect { parent.call }.to raise_error(Axn::ContractViolation::NoMatchingExposures)
  end

  it "still exposes a Result as a value via the two-positional form" do
    c = child
    parent = build_axn do
      exposes :child_result, optional: true
      define_method(:call) { expose(:child_result, c.call(x: 1)) }
    end

    expect(parent.call.child_result).to be_a(Axn::Result)
  end

  it "still raises ArgumentError for a lone non-Result positional" do
    parent = build_axn do
      exposes :foo, optional: true
      def call = expose("not a result")
    end

    expect { parent.call }.to raise_error(ArgumentError)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/core/expose_result_spec.rb`
Expected: FAIL — first example errors because `expose(c.call(x: 3))` (single positional, non-`NoMatchingExposures` path) raises the existing `ArgumentError` ("exactly two positional arguments"), and `NoMatchingExposures` is an uninitialized constant.

- [ ] **Step 3: Add the exception class**

In `lib/axn/exceptions.rb`, inside `class ContractViolation`, after the `UnknownExposure` class (around line 67):

```ruby
    class NoMatchingExposures < ContractViolation
      def initialize(declared:, exposed:)
        @declared = declared
        @exposed = exposed
        super()
      end

      def message
        "expose(result): the result exposes #{@exposed.inspect} but this action declares " \
          "#{@declared.inspect} — no fields in common to forward"
      end
    end
```

- [ ] **Step 4: Overload `expose` and add the forwarder**

In `lib/axn/core/contract.rb`, replace the existing `expose` method (currently around lines 501-517) with:

```ruby
        # Accepts:
        # - a single Axn::Result: forwards (result.declared_fields & own outbound declared fields)
        # - two positional arguments (key, value)
        # - a hash of key/value pairs
        def expose(*args, **kwargs)
          if args.size == 1 && kwargs.empty? && args.first.is_a?(Axn::Result)
            return _expose_from_result(args.first)
          end

          if args.any?
            if args.size != 2
              raise ArgumentError,
                    "expose must be called with exactly two positional arguments (or a hash of key/value pairs)"
            end

            kwargs.merge!(args.first => args.last)
          end

          kwargs.each do |key, value|
            raise Axn::ContractViolation::UnknownExposure, key unless result.respond_to?(key)

            @__context.exposed_data[key] = value
          end
        end

        # Forward the intersection of a nested result's declared exposures and this action's own
        # declared exposures. Reads declared fields (static contract) so it is safe on a failed
        # result — it forwards whatever the child managed to expose (nil for the rest) and never
        # inspects ok?/error or calls fail!. An empty intersection is always a wiring mistake.
        private def _expose_from_result(source_result)
          forwardable = source_result.declared_fields & self.class._declared_fields(:outbound)

          if forwardable.empty?
            raise Axn::ContractViolation::NoMatchingExposures.new(
              declared: self.class._declared_fields(:outbound),
              exposed: source_result.declared_fields,
            )
          end

          forwardable.each do |field|
            @__context.exposed_data[field] = source_result.public_send(field)
          end
        end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bundle exec rspec spec/axn/core/expose_result_spec.rb`
Expected: PASS (6 examples, 0 failures)

- [ ] **Step 6: Run the full contract/messages suite to check for regressions**

Run: `bundle exec rspec spec/axn/core`
Expected: PASS (no regressions in existing `expose` behavior)

- [ ] **Step 7: Commit**

```bash
git add lib/axn/exceptions.rb lib/axn/core/contract.rb spec/axn/core/expose_result_spec.rb
git commit -m "PRO-2781 Add expose(result) to forward a nested result's exposures

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: `inputs` reader + reserved name

**Files:**
- Modify: `lib/axn/core/contract.rb` (add `inputs` to both reserved-name lists; add `inputs` reader)
- Test: `spec/axn/core/inputs_reader_spec.rb` (create)
- Test: `spec/axn/core/reserved_attribute_names_spec.rb` (extend)

**Interfaces:**
- Consumes: `self.class._declared_fields(:inbound)` (wire keys), `@__context.provided_data` (resolved inbound values — defaults/preprocess already applied by the executor before `call`).
- Produces: `inputs` — instance method returning a `Hash{Symbol => Object}` of declared inbound wire keys present in `provided_data`, mapped to their resolved values. Splat into a child call: `Child.call(**inputs)`; subset/override with `Hash` methods.

- [ ] **Step 1: Write the failing reader test**

Create `spec/axn/core/inputs_reader_spec.rb`:

```ruby
# frozen_string_literal: true

RSpec.describe "#inputs reader" do
  it "returns declared inbound fields with resolved defaults" do
    action = build_axn do
      expects :a
      expects :b, default: 99
      exposes :captured, optional: true
      def call = expose(captured: inputs)
    end

    expect(action.call(a: 1).captured).to eq(a: 1, b: 99)
  end

  it "applies preprocessing to the returned values" do
    action = build_axn do
      expects :a, preprocess: ->(v) { v * 10 }
      exposes :captured, optional: true
      def call = expose(captured: inputs)
    end

    expect(action.call(a: 2).captured).to eq(a: 20)
  end

  it "excludes undeclared passthrough keys" do
    action = build_axn do
      expects :a
      exposes :captured, optional: true
      def call = expose(captured: inputs)
    end

    expect(action.call(a: 1, z: 99).captured).to eq(a: 1)
  end

  it "omits absent optional fields" do
    action = build_axn do
      expects :a
      expects :b, optional: true
      exposes :captured, optional: true
      def call = expose(captured: inputs)
    end

    expect(action.call(a: 1).captured).to eq(a: 1)
  end

  it "round-trips through a child call via splat" do
    child = build_axn do
      expects :a, :b
      exposes :sum, optional: true
      def call = expose(sum: a + b)
    end
    c = child
    parent = build_axn do
      expects :a, :b
      exposes :sum, optional: true
      define_method(:call) { expose(c.call(**inputs)) }
    end

    expect(parent.call(a: 2, b: 3).sum).to eq(5)
  end

  it "supports subsetting and override with Hash methods" do
    child = build_axn do
      expects :a, :b
      exposes :pair, optional: true
      def call = expose(pair: [a, b])
    end
    c = child
    parent = build_axn do
      expects :a, :b
      exposes :pair, optional: true
      define_method(:call) { expose(c.call(**inputs.except(:b), b: 0)) }
    end

    expect(parent.call(a: 1, b: 9).pair).to eq([1, 0])
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/core/inputs_reader_spec.rb`
Expected: FAIL with `NoMethodError: undefined method 'inputs'`

- [ ] **Step 3: Add the `inputs` reader**

In `lib/axn/core/contract.rb`, inside `module InstanceMethods`, add immediately after the `result` reader (around line 497):

```ruby
        # Resolved declared-inbound fields as a Hash (defaults/preprocess applied), keyed by wire
        # key. Splat into a nested action to forward inputs: `Child.call(**inputs, override: x)`.
        def inputs
          self.class._declared_fields(:inbound).each_with_object({}) do |field, hash|
            hash[field] = @__context.provided_data[field] if @__context.provided_data.key?(field)
          end
        end
```

- [ ] **Step 4: Run reader test to verify it passes**

Run: `bundle exec rspec spec/axn/core/inputs_reader_spec.rb`
Expected: PASS (6 examples, 0 failures)

- [ ] **Step 5: Reserve the `inputs` name**

In `lib/axn/core/contract.rb`, add `inputs` to both reserved lists.

In `RESERVED_FIELD_NAMES_FOR_EXPECTATIONS` (around line 259):

```ruby
        RESERVED_FIELD_NAMES_FOR_EXPECTATIONS = %w[
          fail! ok?
          inspect default_error
          each_pair
          default_success
          action_name
          inputs
        ].freeze
```

In `RESERVED_FIELD_NAMES_FOR_EXPOSURES` (around line 267):

```ruby
        RESERVED_FIELD_NAMES_FOR_EXPOSURES = %w[
          fail! ok?
          inspect each_pair default_error
          ok error success message
          result
          outcome
          exception
          elapsed_time
          finalized?
          __action__
          prefixed
          inputs
        ].freeze
```

- [ ] **Step 6: Write the failing reserved-name test**

In `spec/axn/core/reserved_attribute_names_spec.rb`, add an example to the existing `.expects` "other reserved expectation field names" iteration by extending its name list, and one under `.exposes`. Concretely, change the `.expects` iteration list from `%w[default_success action_name]` to `%w[default_success action_name inputs]`, and add this context under the `.exposes` describe block (mirror the file's existing exposure reserved-name examples — match the surrounding style):

```ruby
    context "with inputs reserved exposure name" do
      let(:action) do
        build_axn do
          exposes :inputs, type: String
        end
      end

      it { expect { action }.to raise_error(Axn::ContractViolation::ReservedAttributeError) }
    end
```

Note: confirm whether `.exposes` reserved-name examples in this file raise at declaration (`expect { action }`) or at call time (`expect { action.call(...) }`) and match that form — the `.expects` examples raise at call time, exposures typically raise at declaration.

- [ ] **Step 7: Run the reserved-name test to verify it passes**

Run: `bundle exec rspec spec/axn/core/reserved_attribute_names_spec.rb`
Expected: PASS

- [ ] **Step 8: Run the full core suite**

Run: `bundle exec rspec spec/axn/core`
Expected: PASS

- [ ] **Step 9: Commit**

```bash
git add lib/axn/core/contract.rb spec/axn/core/inputs_reader_spec.rb spec/axn/core/reserved_attribute_names_spec.rb
git commit -m "PRO-2781 Add inputs reader for forwarding resolved inbound fields

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Documentation + CHANGELOG

**Files:**
- Modify: `CHANGELOG.md`
- Modify: `docs/usage/steps.md` OR a contract/usage doc page (see Step 2) — add a short "facade / forwarding" subsection

**Interfaces:**
- Consumes: the shipped `expose(result)` and `inputs` behaviors from Tasks 1-2.
- Produces: user-facing docs; no code.

- [ ] **Step 1: Add CHANGELOG entries**

In `CHANGELOG.md`, under the current unreleased section (match the file's existing heading style), add:

```markdown
- Added `expose(result)`: forward a nested action result's declared exposures (the intersection with the current action's `exposes`) in one call. Failure-tolerant; raises `Axn::ContractViolation::NoMatchingExposures` when there is no field in common.
- Added `inputs`: a reader returning the action's resolved declared-inbound fields as a Hash, for splatting into nested calls (`Child.call(**inputs, role: ROLE)`).
- **Breaking:** `inputs` is now a reserved expectation/exposure field name. An action declaring `expects :inputs` / `exposes :inputs` will raise `Axn::ContractViolation::ReservedAttributeError`.
```

- [ ] **Step 2: Locate the right usage doc page**

Run: `ls docs/usage && grep -rl "expose" docs/usage | head`
Expected: a list of usage pages. Pick the page documenting `expose`/contract usage (e.g. `docs/usage/writing.md` or similar). If none cleanly fits, add the subsection to `docs/usage/steps.md` immediately after its intro, since facades are the non-pipeline composition story.

- [ ] **Step 3: Add a short forwarding subsection**

Add to the page chosen in Step 2 (adjust heading level to match siblings):

````markdown
## Forwarding to a nested action (facades)

When an action is a thin facade over another — forwarding most inputs and re-exposing the
child's outputs — use `inputs` to forward arguments and `expose(result)` to forward outputs:

```ruby
class Assignments::Create
  include Axn

  expects :user, :company, :role, :started_at, optional: true
  exposes :user, :employment, optional: true
  error "Unable to create assignment"

  def call
    result = Employment::AddEmployeeToCompany.call(**inputs)
    expose(result)              # forwards (child's exposures ∩ this action's exposes)
    fail! unless result.ok?     # a declared base `error` provides the message
  end
end
```

- `inputs` is the resolved declared-inbound fields as a Hash — splat it, and use plain Hash
  methods to inject or drop fields: `Child.call(**inputs.except(:role), role: ROLE)`.
- `expose(result)` forwards the intersection of the child's declared exposures and this
  action's own `exposes`, and works even when the child failed (so an errors-bearing record
  the child exposed is still forwarded for form display). It raises if there is nothing in
  common to forward.
````

- [ ] **Step 4: Commit**

```bash
git add CHANGELOG.md docs/
git commit -m "PRO-2781 Document expose(result) and inputs forwarding helpers

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

- **Spec coverage:** `expose(result)` overload + intersection + failure-tolerance + empty-intersection raise (Task 1); `inputs` resolved-values + declared-only + Hash subsetting + reserved name (Task 2); CHANGELOG breaking-change note + usage docs (Task 3). The os-app facade cleanup is intentionally out of scope (separate repo / post-release bump, noted in spec).
- **Placeholder scan:** none — all steps carry concrete code/commands. Step 2 of Task 3 is a locate-the-file step with an explicit command and a fallback, not a placeholder.
- **Type consistency:** `_expose_from_result` / `NoMatchingExposures.new(declared:, exposed:)` / `inputs` returning `Hash` are referenced consistently across tasks; `Axn::Result#declared_fields` and `_declared_fields(:inbound|:outbound)` match the existing codebase signatures verified during design.
- **Open confirmation for the executor:** Task 2 Step 6 notes that `.exposes` reserved-name examples may raise at declaration rather than call time — match the file's existing form when adding the example.
