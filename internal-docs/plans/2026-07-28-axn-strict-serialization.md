# Strict Outbound Value Serialization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `Axn::Reflection::Values` diagnose all four shapes of "this exposed value has no honest JSON representation" — adding an unconditional colliding-Hash-key raise and a `strict:` mode for default-`to_s` values and keys — so `axn-openapi` can delete the parallel walk it maintains to pre-check them.

**Architecture:** Every check lives inside `serialize_value`'s existing recursion, colocated with the rendering it predicts (the whole point: the adapter's separate walk drifted from it). `strict` threads through the recursion alongside `seen`, defaulting to `false`. All four defects reuse the existing `Axn::Reflection::UnserializableValue`, which gains a `reason:` kwarg, so no adapter's `rescue StandardError` needs a change.

**Tech Stack:** Ruby, RSpec, RuboCop. No new dependencies.

**Ticket:** [PRO-2988](https://linear.app/teamshares/issue/PRO-2988/axn-strict-mode-for-outbound-value-serialization-opaque-leaves-opaque)
**Spec:** `internal-docs/specs/2026-07-28-axn-strict-serialization-design.md`

## Global Constraints

- Two gates, and they are not interchangeable. **Colliding keys raise unconditionally** (the body would be *wrong* — a value silently vanishes). **Default-`to_s` value and key raise only under `strict: true`** (the body is complete, just ugly). Do not "simplify" by moving the collision check behind the flag; that reversal is the spec's central decision.
- `strict:` defaults to `false` everywhere. This is load-bearing beyond back-compat: `lib/axn/reflection/schema.rb:880` calls `serialize_value` to render a literal `default:` into a schema, and schema reflection must never raise on user data.
- Existing `UnserializableValue` messages stay **byte-identical**, and the existing `UnserializableValue.new(path:, value:)` call form keeps working (it is public API).
- Never assert `Hash#inspect` text in a spec — Ruby 3.4 changed its spacing and CI runs 3.2/3.3/3.4. Object addresses in messages need regex or substring matching, never equality.
- Comments describe current behavior and intrinsic why. No "used to X / now Y", no ticket numbers, no review references.
- No manual line breaks in Markdown prose — one line per paragraph.
- Run `bundle exec rubocop` before each commit. Relevant maxima: `Layout/LineLength` 160, `Metrics/MethodLength` 70, `Metrics/AbcSize` 60. `Style/IfUnlessModifier` will demand the one-line modifier form for any guard that fits in 160 columns, multiline argument lists require a trailing comma, and `Style/HashSyntax` requires shorthand for symbol keys even in a rocket-mixed literal.
- Two things the spec explicitly rules out, so no task should reach for them: do **not** add a new exception class (all four defects reuse `UnserializableValue`, so an adapter's existing `rescue StandardError` needs no change), and do **not** move or export `Axn::Internal::CycleGuard` to `Axn::Extensions` (this change deletes the adapter walk that motivated it, so the namespace stays private).
- Full suite: `bundle exec rspec`. The Rails dummy app is a separate bundle: `BUNDLE_GEMFILE=spec_rails/dummy_app/Gemfile bundle exec rspec spec_rails` (only needed if a task touches Rails-conditional behavior — none here do, but `spec_rails/dummy_app/spec/axn/reflection/values_spec.rb` exists and must keep passing).

## File Structure

| File | Responsibility | Change |
| --- | --- | --- |
| `lib/axn/exceptions.rb` | `UnserializableValue` — pure message formatter | Modify (~L159-179): add `reason:`, move cycle text to a private default |
| `lib/axn/reflection/values.rb` | The serializer and every strictness check | Modify: `strict:` kwarg, restructured `Hash` branch, three check helpers, three reason constants |
| `spec/axn/reflection/values_spec.rb` | Unit coverage for all four defects | Modify: add `describe` blocks |
| `docs/recipes/authoring-tool-adapters.md` | Adapter-author guidance | Modify L119-130 |
| `AGENTS-tool-adapters.md` | Terse adapter cheat-sheet | Modify L79-83 |
| `CHANGELOG.md` | Release notes | Modify `### Tools & adapters` under `## Unreleased` |

Cycle-case specs stay in `spec/axn/self_referential_values_spec.rb` — do not move them, and do not add the new defects there (that file is about `SystemStackError` escaping `.call`, a different concern).

---

### Task 1: `reason:` on `UnserializableValue`

Pure refactor. The exception becomes a formatter that takes a reason, with the cycle text as its default so nothing observable changes yet. Doing this first means Tasks 2-4 each add exactly one check.

**Files:**
- Modify: `lib/axn/exceptions.rb:159-179`
- Test: `spec/axn/reflection/values_spec.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `Axn::Reflection::UnserializableValue.new(path:, value:, reason: nil)`. `message` renders `"Cannot serialize exposed value at \`#{path}\` (#{value.class}): #{reason}"`, falling back to the cycle reason when `reason` is nil. Reason strings supply their own terminal punctuation; the format string adds none.

- [ ] **Step 1: Write the failing test**

Add to `spec/axn/reflection/values_spec.rb`, as a new `describe` block placed immediately before the existing `describe "self-referential values" do` block (around L188):

```ruby
  describe Axn::Reflection::UnserializableValue do
    it "renders a supplied reason verbatim after the path and the value's class" do
      error = described_class.new(path: "data (hash key :x)", value: :x, reason: "it is bad.")

      expect(error.message).to eq("Cannot serialize exposed value at `data (hash key :x)` (Symbol): it is bad.")
    end

    it "falls back to the cycle reason when none is supplied, so the two-kwarg call form keeps working" do
      error = described_class.new(path: "items[1]", value: [])

      expect(error.message).to eq(
        "Cannot serialize exposed value at `items[1]` (Array): it is self-referential (a Array cycle), " \
        "which has no JSON representation. Expose a finite projection of it instead " \
        "(e.g. ids rather than the objects that point back).",
      )
    end
  end
```

Note this block's `described_class` is the exception, not `Axn::Reflection::Values` — that is why it is its own `describe` with an explicit class argument rather than nested in the outer one.

- [ ] **Step 2: Run the test to verify it fails**

Run: `bundle exec rspec spec/axn/reflection/values_spec.rb -e "renders a supplied reason verbatim"`
Expected: FAIL with `ArgumentError: unknown keyword: :reason`. The second example passes already — it pins today's message so Step 3 cannot drift it.

- [ ] **Step 3: Write the implementation**

Replace `lib/axn/exceptions.rb:159-179` (the `module Reflection` block through the `end` of `UnserializableValue`) with:

```ruby
  module Reflection
    # Raised when an exposed value has no honest JSON representation, so a serializing adapter
    # (axn-openapi, axn-mcp, axn-ruby_llm) fails the call rather than emitting garbage or a placeholder
    # where data belongs. Four shapes, in two categories. The rendering would be WRONG: a
    # self-referential container (no JSON representation at all), or two Hash keys that stringify to
    # one JSON property (a value silently dropped). The rendering would be UGLY, rejected only under
    # `serialize_value(strict: true)`: a value or a Hash key whose only `to_s` is the inherited
    # Object#to_s, which renders an object address into a response body.
    #
    # An ArgumentError so an adapter's existing `rescue StandardError` maps it to an error response
    # with no adapter-side change; a SystemStackError, being outside StandardError, would escape the
    # adapter entirely. Names the path to the offending value.
    class UnserializableValue < ArgumentError
      # `reason:` names the specific defect, punctuation included. It defaults to the cycle case —
      # both the original meaning of this error and the only one an external caller is likely to
      # construct — so `new(path:, value:)` remains a complete call.
      def initialize(path:, value:, reason: nil)
        @path = path
        @value = value
        @reason = reason
        super()
      end

      def message
        "Cannot serialize exposed value at `#{@path}` (#{@value.class}): #{@reason || cycle_reason}"
      end

      private

      def cycle_reason
        "it is self-referential (a #{@value.class} cycle), which has no JSON representation. " \
          "Expose a finite projection of it instead (e.g. ids rather than the objects that point back)."
      end
    end
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bundle exec rspec spec/axn/reflection/values_spec.rb spec/axn/self_referential_values_spec.rb`
Expected: PASS, all examples. The pre-existing cycle examples in both files assert the old message text and must still pass untouched — that is the byte-identical guarantee.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec rubocop lib/axn/exceptions.rb spec/axn/reflection/values_spec.rb
git add lib/axn/exceptions.rb spec/axn/reflection/values_spec.rb
git commit -m "PRO-2988: give UnserializableValue a reason:, defaulting to the cycle text"
```

---

### Task 2: Colliding Hash keys raise unconditionally

`transform_keys(&:to_s)` collapses `{id: 1, "id" => 2}` into one property and drops a value with no signal. Detecting it needs the original keys, so the `Hash` branch is restructured to build the rendered Hash directly from the source in one pass — same allocations and the same one `to_s` per key as today, which makes the check an O(1) size comparison. The offending pair is located by re-scanning only on the error path, so the message can name both original keys without a per-key registry in the hot path.

**Files:**
- Modify: `lib/axn/reflection/values.rb:58-63` (the `when Hash` branch), plus a new private helper
- Test: `spec/axn/reflection/values_spec.rb`

**Interfaces:**
- Consumes: `UnserializableValue.new(path:, value:, reason:)` from Task 1.
- Produces: `raise_colliding_keys!(hash, path)` — always raises; called only when a size mismatch proves a collapse. Path format for a key defect: `"#{path} (hash key #{key.inspect})"`, with `value:` the offending key itself.

- [ ] **Step 1: Write the failing tests**

Add to `spec/axn/reflection/values_spec.rb` as a new top-level `describe` block inside the outer describe, immediately after the existing `describe ".serialize_exposed"` block (around L144):

```ruby
  # Stringifying a Hash's keys collapses two keys with the same #to_s into ONE JSON property, dropping
  # a value. Unlike an ugly rendering, the caller cannot tell from the output that anything went
  # missing — so this raises regardless of strictness.
  describe "colliding Hash keys" do
    it "raises rather than silently dropping a value" do
      expect { described_class.serialize_value({ id: 1, "id" => 2 }, path: "rec") }
        .to raise_error(
          Axn::Reflection::UnserializableValue,
          /`rec \(hash key "id"\)`.*two keys stringify to the same JSON property "id".*silently collapse and drop a value/m,
        )
    end

    it "names both original keys, so the caller can see which pair to fix" do
      expect { described_class.serialize_value({ id: 1, "id" => 2 }) }
        .to raise_error(Axn::Reflection::UnserializableValue, /\(:id and "id"\)/)
    end

    it "names the first colliding pair in insertion order when more than two keys collide" do
      third = Object.new.tap { |o| def o.to_s = "id" }

      expect { described_class.serialize_value({ "id" => 1, id: 2, third => 3 }) }
        .to raise_error(Axn::Reflection::UnserializableValue, /\("id" and :id\)/)
    end

    it "names the nested path of the offending Hash" do
      expect { described_class.serialize_value({ rows: [{ a: 1, "a" => 2 }] }, path: "out") }
        .to raise_error(Axn::Reflection::UnserializableValue, /`out\.rows\[0\] \(hash key "a"\)`/)
    end

    it "leaves a Hash whose keys stringify distinctly unchanged" do
      expect(described_class.serialize_value({ id: 1, "name" => "x", 2 => :b }))
        .to eq("id" => 1, "name" => "x", "2" => "b")
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec rspec spec/axn/reflection/values_spec.rb -e "colliding Hash keys"`
Expected: the four raise examples FAIL (no error raised — `serialize_value` returns `{"id"=>2}`); the last example PASSES already, pinning the unchanged rendering.

- [ ] **Step 3: Write the implementation**

In `lib/axn/reflection/values.rb`, replace the `when Hash` branch (currently L58-63):

```ruby
        when Hash
          within_container(value, path, seen) do |nested|
            rendered = value.each_with_object({}) do |(key, element), acc|
              wire_key = key.to_s
              acc[wire_key] = serialize_value(element, path: "#{path}.#{wire_key}", seen: nested)
            end

            # Built from the SOURCE keys rather than via transform_keys so a collapse is observable:
            # two keys with the same #to_s (`:id` and `"id"`) render as one JSON property, dropping a
            # value. Same allocations and the same one #to_s per key either way, and the size
            # comparison is O(1) — so the check costs nothing when there is nothing wrong.
            raise_colliding_keys!(value, path) unless rendered.size == value.size

            rendered
          end
```

Then add this method immediately after `within_container` (after its `end`, currently L100):

```ruby
      # A collapse is detected by size, which doesn't say WHICH keys collided — so re-walk the source
      # here, on the error path only, and name the first colliding pair. Insertion order makes the
      # reported pair deterministic.
      def raise_colliding_keys!(hash, path)
        wire_key, colliding = hash.each_key.group_by(&:to_s).find { |_, group| group.size > 1 }
        first, second = colliding

        raise Axn::Reflection::UnserializableValue.new(
          path: "#{path} (hash key #{second.inspect})", value: second,
          reason: "two keys stringify to the same JSON property #{wire_key.inspect} " \
                  "(#{first.inspect} and #{second.inspect}), which would silently collapse and drop a value.",
        )
      end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bundle exec rspec spec/axn/reflection/values_spec.rb spec/axn/self_referential_values_spec.rb spec/axn/reflection/schema_spec.rb`
Expected: PASS. `schema_spec.rb` is included deliberately — it exercises `serialize_value` through schema reflection (`schema.rb:880`), so it catches any rendering regression from the restructured `Hash` branch.

- [ ] **Step 5: Run the full suite**

Run: `bundle exec rspec`
Expected: PASS. Every walker that renders exposures goes through this branch, so a broken restructure surfaces broadly here rather than narrowly above.

- [ ] **Step 6: Lint and commit**

```bash
bundle exec rubocop lib/axn/reflection/values.rb spec/axn/reflection/values_spec.rb
git add lib/axn/reflection/values.rb spec/axn/reflection/values_spec.rb
git commit -m "PRO-2988: raise on Hash keys that collapse to one JSON property"
```

---

### Task 3: `strict:` mode and the default-`to_s` value

`serialize_value`'s final fallback is `value.to_s`, reached only when the value has no own `as_json` and no `to_h`. If that `to_s` is inherited from `Object`, the "rendering" is an object address. This task adds the `strict` kwarg, threads it through all four recursion sites, and adds the leaf check.

**Files:**
- Modify: `lib/axn/reflection/values.rb` — `serialize_exposed`, `serialize_value` signature and its four recursive calls, the `else` branch, plus two constants and one predicate
- Test: `spec/axn/reflection/values_spec.rb`

**Interfaces:**
- Consumes: `UnserializableValue.new(path:, value:, reason:)` from Task 1; the restructured `Hash` branch from Task 2.
- Produces: `serialize_exposed(result, field_configs, strict: false)`, `serialize_value(value, path:, seen: nil, strict: false)`, and the private predicate `default_to_s?(value)` → `true` when `value.method(:to_s).owner` is `Object` or `Kernel`. Task 4 calls `default_to_s?` for keys.

- [ ] **Step 1: Write the failing tests**

Add to `spec/axn/reflection/values_spec.rb` immediately after the `describe "colliding Hash keys"` block added in Task 2:

```ruby
  # serialize_value's last resort is `value.to_s`. When that #to_s is the one inherited from Object,
  # the result is an object address — complete, but useless in a response body or an LLM's tool
  # result. Strict callers reject it; the default keeps rendering it, since a lossless-but-ugly value
  # is not worth failing an MCP call over.
  describe "default-to_s values under strict:" do
    # No own as_json (spec/ is non-Rails, so Object gains none), no to_h, and #to_s owned by Object.
    let(:opaque) { Object.new }

    it "renders the object address by default" do
      expect(described_class.serialize_value(opaque, path: "owner")).to match(/\A#<Object:0x[0-9a-f]+>\z/)
    end

    it "raises under strict:, naming the path and how to fix it" do
      expect { described_class.serialize_value(opaque, path: "owner", strict: true) }
        .to raise_error(
          Axn::Reflection::UnserializableValue,
          /`owner` \(Object\).*only via the default Object#to_s.*declare it `type: String`/m,
        )
    end

    it "allows a value with a meaningful custom to_s under strict:" do
      money = Object.new.tap { |o| def o.to_s = "$5.00" }

      expect(described_class.serialize_value(money, strict: true)).to eq("$5.00")
    end

    it "checks inside an Array, naming the indexed path" do
      expect { described_class.serialize_value([1, opaque], path: "rows", strict: true) }
        .to raise_error(Axn::Reflection::UnserializableValue, /`rows\[1\]`/)
    end

    it "checks inside a Hash, naming the keyed path" do
      expect { described_class.serialize_value({ owner: opaque }, path: "rec", strict: true) }
        .to raise_error(Axn::Reflection::UnserializableValue, /`rec\.owner`/)
    end

    it "checks a value reached through a custom to_h, since the checks live inside the recursion" do
      wrapper = Object.new
      wrapper.instance_variable_set(:@inner, opaque)
      def wrapper.to_h = { inner: @inner }

      expect { described_class.serialize_value(wrapper, path: "w", strict: true) }
        .to raise_error(Axn::Reflection::UnserializableValue, /`w\.inner`/)
    end

    it "leaves every ordinary value untouched under strict:" do
      as_json_obj = Object.new.tap { |o| def o.as_json(*) = { "k" => "v" } }

      expect(described_class.serialize_value(:ok, strict: true)).to eq("ok")
      expect(described_class.serialize_value(BigDecimal("3.14"), strict: true)).to eq(3.14)
      expect(described_class.serialize_value(Date.new(2026, 7, 3), strict: true)).to eq("2026-07-03")
      expect(described_class.serialize_value({ a: [1, nil, true] }, strict: true)).to eq("a" => [1, nil, true])
      expect(described_class.serialize_value(as_json_obj, strict: true)).to eq("k" => "v")
    end

    it "still raises on a cycle under strict:, with the cycle reason rather than a to_s reason" do
      cyclic = [1]
      cyclic << cyclic

      expect { described_class.serialize_value(cyclic, path: "items", strict: true) }
        .to raise_error(Axn::Reflection::UnserializableValue, /self-referential/)
    end

    it "raises on colliding keys under either setting, since a dropped value is wrong output" do
      [false, true].each do |strict|
        expect { described_class.serialize_value({ id: 1, "id" => 2 }, strict:) }
          .to raise_error(Axn::Reflection::UnserializableValue, /silently collapse/)
      end
    end
  end
```

And add to the existing `describe ".serialize_exposed"` block (after its current single example, around L143):

```ruby
    it "threads strict: to the values it serializes" do
      klass = Class.new do
        include Axn
        auto_log false
        exposes :owner

        def call = expose(owner: Object.new)
      end
      result = klass.call

      expect(described_class.serialize_exposed(result, klass.external_field_configs)["owner"])
        .to match(/\A#<Object:0x[0-9a-f]+>\z/)
      expect { described_class.serialize_exposed(result, klass.external_field_configs, strict: true) }
        .to raise_error(Axn::Reflection::UnserializableValue, /`owner`/)
    end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec rspec spec/axn/reflection/values_spec.rb -e "default-to_s values under strict:" -e "threads strict:"`
Expected: FAIL with `ArgumentError: unknown keyword: :strict` on the strict examples. "renders the object address by default" and the two ordinary-value examples that don't pass `strict:` should pass.

- [ ] **Step 3: Write the implementation**

In `lib/axn/reflection/values.rb`:

**3a.** Add these constants directly below the existing `private_constant :CYCLE_DETECTED` (L25), before `module_function`:

```ruby
      # Both, defensively: a class that defines no #to_s of its own inherits Object's, and in practice
      # that is the owner reported — but Kernel is where several of Object's own hooks actually live.
      DEFAULT_TO_S_OWNERS = [::Object, ::Kernel].freeze
      private_constant :DEFAULT_TO_S_OWNERS

      OPAQUE_VALUE_REASON = "it serializes only via the default Object#to_s (it would render as garbage " \
                            'like "#<User:0x…>") — declare it `type: String` and format it, or give the ' \
                            "value an `as_json`/`to_h`."
      private_constant :OPAQUE_VALUE_REASON
```

**3b.** Change `serialize_exposed` (L30-34) to thread the kwarg:

```ruby
      def serialize_exposed(result, field_configs, strict: false)
        field_configs.each_with_object({}) do |config, hash|
          hash[config.field.to_s] = serialize_value(result.public_send(config.field), path: config.field.to_s, strict:)
        end
      end
```

**3c.** Change `serialize_value`'s signature, and extend its doc comment's `seen` sentence:

```ruby
      # `path` names the value being serialized, so a failure says WHICH exposure is at fault
      # (`items[1].parent`, not just "something"). `seen` carries the containers open on the current
      # path — see within_container. `strict` additionally rejects a value (or Hash key) that would
      # render only as an object address: honest output, but not presentable output, so it is the
      # caller's call rather than a universal one.
      def serialize_value(value, path: "(exposed value)", seen: nil, strict: false)
```

**3d.** Add `strict:` to all four recursive calls — the `Hash` branch's element call, the `Array` branch's element call, and both `within_container` blocks in the `else` branch:

```ruby
              acc[wire_key] = serialize_value(element, path: "#{path}.#{wire_key}", seen: nested, strict:)
```
```ruby
            value.each_with_index.map { |v, index| serialize_value(v, path: "#{path}[#{index}]", seen: nested, strict:) }
```
```ruby
            within_container(value, path, seen) { |nested| serialize_value(value.as_json, path:, seen: nested, strict:) }
```
```ruby
            within_container(value, path, seen) { |nested| serialize_value(value.to_h, path:, seen: nested, strict:) }
```

**3e.** Replace the `else`-branch fallback (currently the bare `value.to_s` at L82) with:

```ruby
            raise Axn::Reflection::UnserializableValue.new(path:, value:, reason: OPAQUE_VALUE_REASON) if strict && default_to_s?(value)

            value.to_s
```

**3f.** Add the predicate after `follow_as_json?`:

```ruby
      # Whether `value.to_s` would render an object address rather than anything meaningful — i.e. the
      # value inherits #to_s instead of defining one. Keying on the OWNER rather than respond_to? is
      # what lets a real `def to_s = "$#{cents / 100.0}"` through. Reached only from the `to_s`
      # fallback and from a Hash key, so the earlier branches have already routed away everything
      # that stringifies meaningfully.
      def default_to_s?(value)
        DEFAULT_TO_S_OWNERS.include?(value.method(:to_s).owner)
      end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bundle exec rspec spec/axn/reflection/values_spec.rb`
Expected: PASS, all examples.

- [ ] **Step 5: Verify the schema-reflection path is never strict**

Add to `spec/axn/reflection/schema_spec.rb`, at the end of the file inside the outer describe:

```ruby
  # Schema reflection renders a literal `default:` through Values.serialize_value (see
  # Schema.describe_default). Reflection must never raise on user data, so that call site stays
  # non-strict even for a value that has no presentable JSON form.
  it "reflects an opaque literal default rather than raising, since reflection is never strict" do
    klass = Class.new do
      include Axn
      expects :owner, default: Object.new
    end

    expect { klass.input_schema }.not_to raise_error
  end
```

Run: `bundle exec rspec spec/axn/reflection/schema_spec.rb`
Expected: PASS. If it fails, `strict` leaked into a default argument somewhere — do not "fix" it by rescuing in `Schema`.

- [ ] **Step 6: Run the full suite**

Run: `bundle exec rspec`
Expected: PASS.

- [ ] **Step 7: Lint and commit**

```bash
bundle exec rubocop lib/axn/reflection/values.rb spec/axn/reflection/values_spec.rb spec/axn/reflection/schema_spec.rb
git add lib/axn/reflection/values.rb spec/axn/reflection/values_spec.rb spec/axn/reflection/schema_spec.rb
git commit -m "PRO-2988: add strict: mode, rejecting a value that renders as an object address"
```

---

### Task 4: The default-`to_s` Hash key under `strict:`

A Hash's keys render via plain `to_s` and never touch the `as_json`/`to_h` chain, so an opaque key becomes an object address used as a JSON *property name* — the same defect as Task 3's, one level worse.

**Files:**
- Modify: `lib/axn/reflection/values.rb` — one line in the `Hash` branch, one constant, one helper
- Test: `spec/axn/reflection/values_spec.rb`

**Interfaces:**
- Consumes: `default_to_s?(value)` from Task 3; the restructured `Hash` branch from Task 2.
- Produces: `check_opaque_key!(key, path)` — raises when `strict` and the key has only the inherited `to_s`; returns nil otherwise.

- [ ] **Step 1: Write the failing tests**

Add to `spec/axn/reflection/values_spec.rb` immediately after the `describe "default-to_s values under strict:"` block:

```ruby
  # A Hash's keys render via `to_s` and never the as_json/to_h chain, so an opaque key becomes an
  # object address used as a JSON PROPERTY NAME.
  describe "default-to_s Hash keys under strict:" do
    let(:opaque_key) { Object.new }

    it "renders the object address as a property name by default" do
      expect(described_class.serialize_value({ opaque_key => 1 }).keys.first)
        .to match(/\A#<Object:0x[0-9a-f]+>\z/)
    end

    it "raises under strict:, naming the offending key in the path" do
      expect { described_class.serialize_value({ opaque_key => 1 }, path: "data", strict: true) }
        .to raise_error(
          Axn::Reflection::UnserializableValue,
          /`data \(hash key #<Object:0x[0-9a-f]+>\)` \(Object\).*a Hash key is rendered via #to_s/m,
        )
    end

    it "allows Symbol, String, and Integer keys under strict:" do
      expect(described_class.serialize_value({ a: 1, "b" => 2, 3 => 4 }, strict: true))
        .to eq("a" => 1, "b" => 2, "3" => 4)
    end

    it "allows a key with a meaningful custom to_s under strict:" do
      key = Object.new.tap { |o| def o.to_s = "custom" }

      expect(described_class.serialize_value({ key => 1 }, strict: true)).to eq("custom" => 1)
    end

    it "checks keys of a nested Hash, naming the nested path" do
      expect { described_class.serialize_value({ rows: [{ opaque_key => 1 }] }, path: "out", strict: true) }
        .to raise_error(Axn::Reflection::UnserializableValue, /`out\.rows\[0\] \(hash key #<Object:0x/)
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec rspec spec/axn/reflection/values_spec.rb -e "default-to_s Hash keys under strict:"`
Expected: the two raise examples FAIL (no error raised); the three others PASS already.

- [ ] **Step 3: Write the implementation**

**3a.** Add the constant next to `OPAQUE_VALUE_REASON`:

```ruby
      OPAQUE_KEY_REASON = "a Hash key is rendered via #to_s and this one has only the default " \
                          'Object#to_s (it would stringify to garbage like "#<…>").'
      private_constant :OPAQUE_KEY_REASON
```

**3b.** In the `Hash` branch, add the check as the first line of the `each_with_object` block, before `wire_key` is computed:

```ruby
            rendered = value.each_with_object({}) do |(key, element), acc|
              check_opaque_key!(key, path) if strict
              wire_key = key.to_s
              acc[wire_key] = serialize_value(element, path: "#{path}.#{wire_key}", seen: nested, strict:)
            end
```

**3c.** Add the helper next to `raise_colliding_keys!`:

```ruby
      # Names the key in the path (`data (hash key #<K:0x…>)`) rather than the Hash alone, so the
      # message points at which of several keys is at fault.
      def check_opaque_key!(key, path)
        return unless default_to_s?(key)

        raise Axn::Reflection::UnserializableValue.new(
          path: "#{path} (hash key #{key.inspect})", value: key, reason: OPAQUE_KEY_REASON,
        )
      end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bundle exec rspec spec/axn/reflection/values_spec.rb`
Expected: PASS, all examples.

- [ ] **Step 5: Run the full suite**

Run: `bundle exec rspec`
Expected: PASS.

- [ ] **Step 6: Lint and commit**

```bash
bundle exec rubocop lib/axn/reflection/values.rb spec/axn/reflection/values_spec.rb
git add lib/axn/reflection/values.rb spec/axn/reflection/values_spec.rb
git commit -m "PRO-2988: reject a Hash key that renders as an object address under strict:"
```

---

### Task 5: Documentation and changelog

The recipe currently tells adapter authors "You don't need your own cycle detection," which is now true of a wider family. That sentence is the reason `axn-openapi` kept its own walk, so getting it right is the deliverable, not an afterthought.

**Files:**
- Modify: `docs/recipes/authoring-tool-adapters.md:119-130`
- Modify: `AGENTS-tool-adapters.md:79-83`
- Modify: `CHANGELOG.md` — `### Tools & adapters` under `## Unreleased`

**Interfaces:**
- Consumes: the final `serialize_exposed(result, field_configs, strict: false)` signature from Task 3.
- Produces: nothing code-facing.

- [ ] **Step 1: Update the docs recipe**

In `docs/recipes/authoring-tool-adapters.md`, add a second example to the code block at L123-126 so it reads:

````markdown
```ruby
# axn-mcp/lib/axn/mcp/serializer.rb
exposed = Axn::Reflection::Values.serialize_exposed(result, axn_class.external_field_configs)

# An HTTP adapter, which must not ship an object address in a response body
exposed = Axn::Reflection::Values.serialize_exposed(result, configs, strict: config.strict_serialization)
```
````

Then replace L130 (the single paragraph beginning "It raises `Axn::Reflection::UnserializableValue`") with these three paragraphs — one line each, no hard wrapping:

```markdown
It raises `Axn::Reflection::UnserializableValue` (an `ArgumentError`) when an exposed value has no honest JSON representation, naming the path to it. Two cases raise always, because the body would be *wrong*: a self-referential value (a cycle has no JSON representation at all), and two Hash keys that stringify to the same JSON property (`{id: 1, "id" => 2}` renders one property, silently dropping a value).

Pass `strict: true` to also reject a value — or a Hash key — whose only `to_s` is the inherited `Object#to_s`, which would render an object address like `"#<User:0x000055…>"`. That output is complete but unpresentable, so whether it's a failure is the adapter's call: an HTTP contract shouldn't ship it in a response body, while an LLM tool result is arguably better off with an ugly string than a failed call. The default is `false`.

You don't need your own detection for any of the four — and shouldn't write one. A strictness check only stays correct while it's colocated with the rendering it predicts; a parallel walk has to mirror the leaf-type list, the `as_json`-before-`to_h` ordering, and key stringification, and will drift. Let the error reach whatever `rescue` already maps a failed serialization to your transport's error response, and keep any "how to turn this off" hint in your own config's voice — core's messages never mention an adapter's settings.
```

- [ ] **Step 2: Update the AGENTS cheat-sheet**

In `AGENTS-tool-adapters.md`, replace the `## Value serialization` bullet (L79-83) with:

```markdown
- Render a success result's exposures with
  `Axn::Reflection::Values.serialize_exposed(result, axn_class.external_field_configs)` → JSON-safe Hash.
  Don't hand-roll (it handles Symbol/BigDecimal/Time/`as_json`-vs-`to_h` so output matches `output_schema`).
- Raises `Axn::Reflection::UnserializableValue` (an `ArgumentError`) on a cycle or on two Hash keys that
  stringify to one JSON property. Add `strict: true` to also reject a value or key that would render as an
  object address (`"#<User:0x…>"`). Never write your own pre-pass — it drifts from the renderer.
```

- [ ] **Step 3: Update the changelog**

In `CHANGELOG.md`, append these two entries to the end of the `### Tools & adapters` list under `## Unreleased` (after the `tool_version`/`::Vn` entries, immediately before `### Other`):

```markdown
* [BREAKING] `Axn::Reflection::Values.serialize_exposed`/`serialize_value` now raise `Axn::Reflection::UnserializableValue` when two of a Hash's keys stringify to the same JSON property (`{id: 1, "id" => 2}`). Keys are rendered with `#to_s`, so such a pair collapsed into one property and silently dropped a value — a response body that was wrong rather than merely ugly, which no caller could detect from the output. The message names both original keys and the property they collapse to.
* [FEAT] `serialize_exposed`/`serialize_value` accept `strict: true`, which additionally rejects an exposed value — or a Hash key — whose only `to_s` is the inherited `Object#to_s`, rather than rendering an object address like `"#<User:0x000055…>"` into a response body. Off by default: that output is complete, just unpresentable, so an HTTP adapter can reject it while an LLM tool adapter keeps returning an ugly string instead of failing the call. Reuses `UnserializableValue` (an `ArgumentError`) with a `reason:` naming the defect, so an adapter's existing `rescue StandardError` covers all four cases with no change — and no adapter needs its own pre-pass over the value graph, which cannot stay in sync with the renderer's branch decisions.
```

- [ ] **Step 4: Verify the docs build and the prose lints**

Run: `bundle exec rubocop && yarn docs:check`
Expected: both succeed. `docs:check` is `vitepress build docs` plus the internal-link checker, so a broken code fence or a bad link fails here.

- [ ] **Step 5: Commit**

```bash
git add docs/recipes/authoring-tool-adapters.md AGENTS-tool-adapters.md CHANGELOG.md
git commit -m "PRO-2988: document strict: serialization for adapter authors"
```

---

## Final Verification

- [ ] `bundle exec rspec` — full suite passes.
- [ ] `BUNDLE_GEMFILE=spec_rails/dummy_app/Gemfile bundle exec rspec spec_rails` — passes. This is the only place the Rails-loaded generic `Object#as_json` exists, and `spec_rails/dummy_app/spec/axn/reflection/values_spec.rb` pins `to_h`-over-`as_json` preference through the branch Task 3 modified.
- [ ] `bundle exec rubocop` — clean.
- [ ] Confirm by inspection that `strict` is threaded to all four recursive `serialize_value` calls in `lib/axn/reflection/values.rb` (Hash element, Array element, `as_json` result, `to_h` result). A missed one silently stops checking below that point — no test failure, just lost coverage. `grep -n "serialize_value(" lib/axn/reflection/values.rb` should show `strict:` on every recursive call and on neither of the two public entry-point definitions' bodies beyond that.
- [ ] Confirm the four defect messages read well end to end by running the four raising cases in `bin/console` and reading the output as a downstream consumer would.
