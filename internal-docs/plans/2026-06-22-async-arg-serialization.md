# Async Argument Serialization via ActiveJob::Arguments — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make async argument serialization adapter-consistent within a deployment and fail loudly (never silently) on unserializable args.

**Architecture:** Introduce a thin dispatcher `Axn::Internal::AsyncSerialization` used by the Sidekiq adapter and `enqueue_all`. When ActiveJob is available it (de)serializes each arg through `ActiveJob::Arguments` (rich, lossless type set + clear errors); otherwise it falls back to today's `GlobalIdSerialization` (JSON-native + GlobalID), but now **raises** `Axn::Async::UnserializableArgument` on anything that wouldn't round-trip cleanly instead of passing it through. The ActiveJob *adapter* is left untouched (it already serializes natively via `ActiveJob::Arguments`, and our seam reuses AJ's own tags, so layering them would collide).

**Tech Stack:** Ruby, RSpec, ActiveJob (host-provided, `defined?`-guarded), Sidekiq (host-provided), GlobalID (host-provided).

## Global Constraints

- **Works outside Rails.** No hard dependency on Rails/ActiveJob/ActiveStorage/GlobalID being loaded — guard every such reference with `defined?(...)`. `spec/` runs without Rails; `spec_rails/dummy_app/` is the Rails app. Rails-adjacent changes are tested in **both**.
- **TDD.** Failing test first, then implementation. Run `bundle exec rspec` (and the relevant `spec_rails` specs) and verify real output before claiming done.
- **Fail at declaration/enqueue, not silently.** A misuse raises with a message that explains the problem **and** the fix (AGENTS.md `UnknownExposure` bar).
- **Additive at the seam.** `GlobalIdSerialization`'s existing wire format (`_as_global_id` suffix keys) and its public method signatures stay identical; new behavior is layered alongside.
- **CHANGELOG every user-visible change** under `## Unreleased`, tagged `[FEAT]`/`[BREAKING]`/`[BUGFIX]`/`[INTERNAL]`.
- **Ruby style:** `# frozen_string_literal: true`; endless methods for one-liners; internal helpers prefixed `_`; internal-only classes under `Axn::Internal`.

## File Structure

- **Create** `lib/axn/internal/async_serialization.rb` — the dispatcher: `serialize`/`deserialize` branching on ActiveJob availability; the ActiveJob per-value path; the fallback validator; the `Axn::Async::UnserializableArgument` exception + hint helpers.
- **Create** `spec/axn/internal/async_serialization_spec.rb` — unit specs for the fallback path (ActiveJob forced unavailable) + dispatch behavior.
- **Create** `spec_rails/dummy_app/spec/axn/internal/async_serialization_spec.rb` — unit specs for the ActiveJob path (rich-type round-trip + field-aware raise).
- **Create** `spec_rails/dummy_app/app/actions/async/test_action_sidekiq_rich_types.rb` — a Sidekiq action used by the integration test.
- **Modify** `lib/axn.rb:23` — add `require "axn/internal/async_serialization"` after the `global_id_serialization` require.
- **Modify** `lib/axn/async/adapters/sidekiq.rb:49,65` — call `AsyncSerialization` instead of `GlobalIdSerialization`.
- **Modify** `lib/axn/async/enqueue_all_orchestrator.rb:31,80` — call `AsyncSerialization` instead of `GlobalIdSerialization`.
- **Modify** `spec_rails/dummy_app/spec/axn/async/` — add an integration spec proving Sidekiq round-trips rich types.
- **Modify** `CHANGELOG.md` — `## Unreleased` entries.
- **Leave unchanged** `lib/axn/internal/global_id_serialization.rb` (now explicitly the fallback engine), `lib/axn/async/adapters/active_job.rb`.

---

### Task 1: `Axn::Async::UnserializableArgument` exception + hint helpers

**Files:**
- Create: `lib/axn/internal/async_serialization.rb`
- Test: `spec/axn/internal/async_serialization_spec.rb`

**Interfaces:**
- Produces: `Axn::Async::UnserializableArgument < ArgumentError`, constructed as `UnserializableArgument.new(field:, value:)`; `#message` returns a string containing the field name, the value's class, and a fix hint.
- Produces: `Axn::Internal::AsyncSerialization` module (methods added in later tasks).

- [ ] **Step 1: Write the failing test**

```ruby
# spec/axn/internal/async_serialization_spec.rb
# frozen_string_literal: true

require "tempfile"
require "stringio"

RSpec.describe Axn::Internal::AsyncSerialization do
  describe Axn::Async::UnserializableArgument do
    it "names the field, the class, and a generic fix hint" do
      error = described_class.new(field: :widget, value: Object.new)
      expect(error).to be_a(ArgumentError)
      expect(error.message).to include("widget")
      expect(error.message).to include("Object")
      expect(error.message).to include("GlobalID-able")
    end

    it "gives an IO-specific hint for file-like values" do
      error = described_class.new(field: :doc, value: StringIO.new("x"))
      expect(error.message).to include("ActiveStorage")
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/internal/async_serialization_spec.rb -e "UnserializableArgument"`
Expected: FAIL with `uninitialized constant Axn::Internal::AsyncSerialization` (or `Axn::Async::UnserializableArgument`).

- [ ] **Step 3: Write minimal implementation**

```ruby
# lib/axn/internal/async_serialization.rb
# frozen_string_literal: true

require "axn/internal/global_id_serialization"

module Axn
  module Async
    # Raised at enqueue when an async argument cannot be serialized for background
    # execution. Field-aware: names the offending field, its class, and how to fix it.
    # Lives here (not exceptions.rb) alongside the other Axn::Async errors
    # (AdapterNotFound, MissingEnqueuesEachError).
    class UnserializableArgument < ArgumentError
      def initialize(field:, value:)
        @field = field
        @value = value
        super()
      end

      def message
        "Cannot serialize argument `#{@field}` (#{@value.class}) for async execution. " \
          "#{Axn::Internal::AsyncSerialization._unserializable_hint(@value)}"
      end
    end
  end

  module Internal
    # Dispatcher for async argument serialization. See lib/axn/internal/async_serialization.rb
    # header comment / docs/superpowers/plans for the design.
    module AsyncSerialization
      GENERIC_HINT =
        "Async args must be JSON-native values (String, Integer, Float, true/false, nil, " \
        "Array/Hash of those) or GlobalID-able objects (e.g. ActiveRecord records, " \
        "ActiveStorage attachments)."

      class << self
        # Returns a fix hint tailored to common footguns (files/IO, ActiveStorage proxies).
        def _unserializable_hint(value)
          if _io_like?(value)
            "Persist it to ActiveStorage and pass the attachment, or otherwise convert it " \
              "to a serializable value. #{GENERIC_HINT}"
          elsif _active_storage_proxy?(value)
            "Pass its `.blob` (or `.attachment`) instead of the attachment proxy. #{GENERIC_HINT}"
          else
            GENERIC_HINT
          end
        end

        def _io_like?(value)
          value.respond_to?(:read) || (defined?(::Tempfile) && value.is_a?(::Tempfile))
        end

        def _active_storage_proxy?(value)
          return false unless defined?(::ActiveStorage::Attached)

          value.is_a?(::ActiveStorage::Attached::One) || value.is_a?(::ActiveStorage::Attached::Many)
        end
      end
    end
  end
end
```

- [ ] **Step 4: Add the require so the module loads**

Modify `lib/axn.rb` — add after line 23 (`require "axn/internal/global_id_serialization"`):

```ruby
require "axn/internal/async_serialization"
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bundle exec rspec spec/axn/internal/async_serialization_spec.rb -e "UnserializableArgument"`
Expected: PASS (2 examples).

- [ ] **Step 6: Commit**

```bash
git add lib/axn/internal/async_serialization.rb lib/axn.rb spec/axn/internal/async_serialization_spec.rb
git commit -m "feat(async): add UnserializableArgument exception + AsyncSerialization scaffold"
```

---

### Task 2: Fallback serialize/deserialize (ActiveJob unavailable)

**Files:**
- Modify: `lib/axn/internal/async_serialization.rb`
- Test: `spec/axn/internal/async_serialization_spec.rb`

**Interfaces:**
- Consumes: `Axn::Internal::GlobalIdSerialization.serialize/deserialize`; `Axn::Async::UnserializableArgument` (Task 1).
- Produces:
  - `AsyncSerialization.serialize(params) -> Hash` — string-keyed, ready for the backend. Raises `Axn::Async::UnserializableArgument` for any value that isn't fallback-serializable when ActiveJob is unavailable.
  - `AsyncSerialization.deserialize(params) -> Hash` — symbol-keyed, resolved.
  - `AsyncSerialization._active_job_available? -> Boolean` — stubbable seam (`defined?(::ActiveJob::Arguments)`).
  - `AsyncSerialization._fallback_serializable?(value) -> Boolean`.

- [ ] **Step 1: Write the failing test**

```ruby
# append to spec/axn/internal/async_serialization_spec.rb, inside the top-level describe

  describe "fallback path (ActiveJob unavailable)" do
    before { allow(described_class).to receive(:_active_job_available?).and_return(false) }

    it "passes JSON-native values through with stringified keys" do
      result = described_class.serialize(name: "World", age: 25, ok: true, tags: ["a", 1])
      expect(result).to eq("name" => "World", "age" => 25, "ok" => true, "tags" => ["a", 1])
    end

    it "serializes a GlobalID-able value via the _as_global_id suffix" do
      gid_able = Object.new
      def gid_able.to_global_id = "gid://app/User/1"
      result = described_class.serialize(user: gid_able)
      expect(result).to eq("user_as_global_id" => "gid://app/User/1")
    end

    it "raises a field-aware error for a Symbol (lossy stringification footgun)" do
      expect { described_class.serialize(status: :active) }
        .to raise_error(Axn::Async::UnserializableArgument, /`status`.*Symbol/m)
    end

    it "raises for a Tempfile with the IO hint" do
      require "tempfile"
      expect { described_class.serialize(doc: Tempfile.new("x")) }
        .to raise_error(Axn::Async::UnserializableArgument, /ActiveStorage/)
    end

    it "raises for Date/Time/Object (not round-trippable without ActiveJob)" do
      require "date"
      [Date.today, Time.now, Object.new].each do |value|
        expect { described_class.serialize(field: value) }
          .to raise_error(Axn::Async::UnserializableArgument)
      end
    end

    it "deserializes plain values by symbolizing keys" do
      expect(described_class.deserialize("name" => "World", "age" => 25))
        .to eq(name: "World", age: 25)
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/internal/async_serialization_spec.rb -e "fallback path"`
Expected: FAIL with `undefined method 'serialize'` (or `_active_job_available?`).

- [ ] **Step 3: Write minimal implementation**

Add to the `class << self` block in `lib/axn/internal/async_serialization.rb` (above the hint helpers):

```ruby
        def serialize(params)
          return {} if params.nil? || params.empty?
          return _serialize_via_active_job(params) if _active_job_available?

          params.each { |key, value| _assert_fallback_serializable!(key, value) }
          Axn::Internal::GlobalIdSerialization.serialize(params)
        end

        def deserialize(params)
          return {} if params.nil? || params.empty?
          return _deserialize_via_active_job(params) if _active_job_available?

          Axn::Internal::GlobalIdSerialization.deserialize(params)
        end

        def _active_job_available? = defined?(::ActiveJob::Arguments) ? true : false

        # Fallback (no ActiveJob) can only round-trip JSON-native scalars, top-level
        # GlobalID-able objects, and Arrays/Hashes of JSON-native scalars. Everything
        # else (Symbol, Date, Time, BigDecimal, files, custom objects, nested GIDs)
        # would corrupt or fail on the JSON round-trip, so it raises instead.
        def _assert_fallback_serializable!(field, value)
          raise Axn::Async::UnserializableArgument.new(field:, value:) unless _fallback_serializable?(value)
        end

        # Serializable iff it's JSON-native through-and-through, OR a top-level GlobalID-able
        # object (the only non-native value GlobalIdSerialization can convert in the fallback).
        # Nested GlobalID-ables are NOT supported in the fallback (GlobalIdSerialization only
        # converts top-level values), so an Array/Hash containing one fails _json_native? and raises.
        def _fallback_serializable?(value)
          _json_native?(value) || value.respond_to?(:to_global_id)
        end

        def _json_native?(value)
          case value
          when nil, true, false, Integer, Float, String then true
          when Array then value.all? { |v| _json_native?(v) }
          when Hash then value.all? { |k, v| _json_native?(k) && _json_native?(v) }
          else false
          end
        end
```

> NOTE: `_serialize_via_active_job` / `_deserialize_via_active_job` are added in Task 3. Define them now as stubs so the fallback specs (which never hit that branch) load cleanly:

```ruby
        def _serialize_via_active_job(params) = raise(NotImplementedError, "added in Task 3")
        def _deserialize_via_active_job(params) = raise(NotImplementedError, "added in Task 3")
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/axn/internal/async_serialization_spec.rb`
Expected: PASS (all examples, including Task 1's).

- [ ] **Step 5: Commit**

```bash
git add lib/axn/internal/async_serialization.rb spec/axn/internal/async_serialization_spec.rb
git commit -m "feat(async): fallback serializer raises on non-serializable args"
```

---

### Task 3: ActiveJob serialize/deserialize path (rich types + field-aware raise)

**Files:**
- Modify: `lib/axn/internal/async_serialization.rb`
- Test: `spec_rails/dummy_app/spec/axn/internal/async_serialization_spec.rb`

**Interfaces:**
- Consumes: `ActiveJob::Arguments.serialize/deserialize` (an array in, array out); `Axn::Async::UnserializableArgument`.
- Produces: real bodies for `_serialize_via_active_job(params)` (string-keyed; raises field-aware on `ActiveJob::SerializationError`) and `_deserialize_via_active_job(params)` (symbol-keyed).

- [ ] **Step 1: Write the failing test**

```ruby
# spec_rails/dummy_app/spec/axn/internal/async_serialization_spec.rb
# frozen_string_literal: true

require "rails_helper"
require "bigdecimal"
require "date"
require "tempfile"

RSpec.describe Axn::Internal::AsyncSerialization do
  describe "ActiveJob path (ActiveJob available)" do
    it "is using the ActiveJob branch in this suite" do
      expect(described_class._active_job_available?).to be(true)
    end

    it "round-trips rich types losslessly" do
      input = {
        sym: :active,
        date: Date.new(2026, 6, 22),
        time: Time.at(1_700_000_000),
        money: BigDecimal("1.5"),
        nested: { a: 1, "b" => [Date.new(2026, 1, 1), :x] },
      }
      output = described_class.deserialize(described_class.serialize(input))
      expect(output).to eq(input)
      expect(output[:sym]).to be_a(Symbol)
      expect(output[:date]).to be_a(Date)
      expect(output[:money]).to be_a(BigDecimal)
    end

    it "raises a field-aware UnserializableArgument for a Tempfile" do
      expect { described_class.serialize(doc: Tempfile.new("x")) }
        .to raise_error(Axn::Async::UnserializableArgument, /`doc`.*Tempfile/m)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd spec_rails/dummy_app && bundle exec rspec spec/axn/internal/async_serialization_spec.rb`
Expected: FAIL with `NotImplementedError: added in Task 3`.

- [ ] **Step 3: Write minimal implementation**

Replace the two Task-2 stubs in `lib/axn/internal/async_serialization.rb` with:

```ruby
        # Serialize value-by-value (keyed by field) so a SerializationError can be
        # re-raised naming the offending field. Keys are stringified for the backend.
        def _serialize_via_active_job(params)
          params.each_with_object({}) do |(key, value), hash|
            hash[key.to_s] = ::ActiveJob::Arguments.serialize([value]).first
          rescue ::ActiveJob::SerializationError
            raise Axn::Async::UnserializableArgument.new(field: key, value:)
          end
        end

        def _deserialize_via_active_job(params)
          params.each_with_object({}) do |(key, value), hash|
            hash[key.to_sym] = ::ActiveJob::Arguments.deserialize([value]).first
          end
        end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd spec_rails/dummy_app && bundle exec rspec spec/axn/internal/async_serialization_spec.rb`
Expected: PASS (3 examples).

- [ ] **Step 5: Re-run the non-Rails suite to confirm no regression**

Run: `bundle exec rspec spec/axn/internal/async_serialization_spec.rb`
Expected: PASS (fallback branch still forced via stub; AJ branch untouched there).

- [ ] **Step 6: Commit**

```bash
git add lib/axn/internal/async_serialization.rb spec_rails/dummy_app/spec/axn/internal/async_serialization_spec.rb
git commit -m "feat(async): ActiveJob serialization path with field-aware errors"
```

---

### Task 4: Route the Sidekiq adapter through AsyncSerialization

**Files:**
- Modify: `lib/axn/async/adapters/sidekiq.rb:49,65`
- Test: `spec/axn/async/adapters/sidekiq_spec.rb`

**Interfaces:**
- Consumes: `AsyncSerialization.serialize/deserialize`.

- [ ] **Step 1: Write the failing test**

```ruby
# append to spec/axn/async/adapters/sidekiq_spec.rb (inside the existing top-level describe)

  describe "argument serialization seam" do
    it "serializes enqueue kwargs through AsyncSerialization" do
      expect(Axn::Internal::AsyncSerialization).to receive(:serialize)
        .with(hash_including(name: "World", age: 25)).and_call_original
      action_class.call_async(name: "World", age: 25)
    end

    it "deserializes job args through AsyncSerialization in #perform" do
      expect(Axn::Internal::AsyncSerialization).to receive(:deserialize)
        .with("name" => "World", "age" => 25).and_call_original
      action_class.new.perform("name" => "World", "age" => 25)
    end
  end
```

> NOTE: the existing `action_class` in that spec stubs `perform_async`; confirm by reading the file head. If the local `let(:action_class)` differs, reuse whatever the file already defines rather than introducing a new one.

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/async/adapters/sidekiq_spec.rb -e "argument serialization seam"`
Expected: FAIL (`AsyncSerialization` does not receive `:serialize` — the adapter still calls `GlobalIdSerialization`).

- [ ] **Step 3: Write minimal implementation**

In `lib/axn/async/adapters/sidekiq.rb`, change line 49:

```ruby
            job_kwargs = Axn::Internal::AsyncSerialization.serialize(kwargs)
```

and line 65:

```ruby
          context = Axn::Internal::AsyncSerialization.deserialize(args.first)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/axn/async/adapters/sidekiq_spec.rb`
Expected: PASS (full file — confirm no existing example regressed).

- [ ] **Step 5: Commit**

```bash
git add lib/axn/async/adapters/sidekiq.rb spec/axn/async/adapters/sidekiq_spec.rb
git commit -m "refactor(async): Sidekiq adapter uses AsyncSerialization seam"
```

---

### Task 5: Route enqueue_all static_args through AsyncSerialization

**Files:**
- Modify: `lib/axn/async/enqueue_all_orchestrator.rb:31,80`
- Test: `spec/axn/async/batch_enqueue_spec.rb`

**Interfaces:**
- Consumes: `AsyncSerialization.serialize/deserialize`.

- [ ] **Step 1: Write the failing test**

```ruby
# append to spec/axn/async/batch_enqueue_spec.rb (inside the existing top-level describe)

  describe "static_args serialization seam" do
    it "serializes resolved static args through AsyncSerialization" do
      expect(Axn::Internal::AsyncSerialization).to receive(:serialize).and_call_original
      target = build_axn do
        expects :label
        enqueues_each :n, from: -> { [1, 2] }
        def call = nil
      end
      target.async(:sidekiq) rescue nil # ensure async configured for this build
      allow(target).to receive(:call_async)
      Axn::Async::EnqueueAllOrchestrator.enqueue_for(target, label: "batch")
    end
  end
```

> NOTE: `build_axn`/async setup conventions vary — read the top of `spec/axn/async/batch_enqueue_spec.rb` and reuse its existing helper for building an async-configured target rather than the sketch above. The assertion that matters: `AsyncSerialization.serialize` is invoked for the non-kwarg-iteration branch.

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/async/batch_enqueue_spec.rb -e "static_args serialization seam"`
Expected: FAIL (`AsyncSerialization` does not receive `:serialize`).

- [ ] **Step 3: Write minimal implementation**

In `lib/axn/async/enqueue_all_orchestrator.rb`, change line 31:

```ruby
        deserialized_static_args = Axn::Internal::AsyncSerialization.deserialize(static_args)
```

and line 80:

```ruby
            serialized_static_args = Axn::Internal::AsyncSerialization.serialize(resolved_static)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/axn/async/batch_enqueue_spec.rb`
Expected: PASS (full file).

- [ ] **Step 5: Commit**

```bash
git add lib/axn/async/enqueue_all_orchestrator.rb spec/axn/async/batch_enqueue_spec.rb
git commit -m "refactor(async): enqueue_all uses AsyncSerialization seam"
```

---

### Task 6: Rails integration — Sidekiq round-trips rich types end-to-end

**Files:**
- Create: `spec_rails/dummy_app/app/actions/async/test_action_sidekiq_rich_types.rb`
- Test: `spec_rails/dummy_app/spec/axn/async/sidekiq_rich_types_spec.rb`

**Interfaces:**
- Consumes: the full Sidekiq adapter + AsyncSerialization (ActiveJob present).

- [ ] **Step 1: Write the failing test**

First read an existing Sidekiq dummy action (`spec_rails/dummy_app/app/actions/async/test_action_sidekiq.rb`) and its spec to match the project's Sidekiq test-mode conventions (inline/fake, how `perform` is driven). Then:

```ruby
# spec_rails/dummy_app/app/actions/async/test_action_sidekiq_rich_types.rb
# frozen_string_literal: true

class Async::TestActionSidekiqRichTypes
  include Axn
  async :sidekiq

  expects :occurred_at, type: Time
  exposes :klass_name

  def call
    expose klass_name: occurred_at.class.name
  end
end
```

```ruby
# spec_rails/dummy_app/spec/axn/async/sidekiq_rich_types_spec.rb
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Async::TestActionSidekiqRichTypes do
  it "delivers a Time (not a String) to the worker through the Sidekiq payload" do
    serialized = Axn::Internal::AsyncSerialization.serialize(occurred_at: Time.at(1_700_000_000))
    context = Axn::Internal::AsyncSerialization.deserialize(serialized)
    result = described_class.call(**context)
    expect(result).to be_ok
    expect(result.klass_name).to eq("Time")
  end

  it "raises a field-aware error when enqueued with an unserializable arg" do
    expect { described_class.call_async(occurred_at: Tempfile.new("x")) }
      .to raise_error(Axn::Async::UnserializableArgument, /occurred_at/)
  end
end
```

> NOTE: if the dummy app uses Sidekiq testing inline mode, prefer driving `call_async` end-to-end over the manual serialize/deserialize in example 1 — mirror whatever `test_action_sidekiq_spec.rb` does. The behavioral assertion (`klass_name == "Time"`) is the point.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd spec_rails/dummy_app && bundle exec rspec spec/axn/async/sidekiq_rich_types_spec.rb`
Expected: FAIL initially if the action file isn't autoloaded yet / before earlier tasks land; once wired, both examples pass.

- [ ] **Step 3: Make it pass**

No new production code beyond Tasks 1–5. If example 1 fails because `type: Time` validation rejected a `String`, that is the regression this whole change fixes — confirm Tasks 3–4 are in place. Ensure the action file lives where the dummy app autoloads actions (mirror existing `async/test_action_sidekiq.rb`).

- [ ] **Step 4: Run test to verify it passes**

Run: `cd spec_rails/dummy_app && bundle exec rspec spec/axn/async/sidekiq_rich_types_spec.rb`
Expected: PASS (2 examples).

- [ ] **Step 5: Commit**

```bash
git add spec_rails/dummy_app/app/actions/async/test_action_sidekiq_rich_types.rb spec_rails/dummy_app/spec/axn/async/sidekiq_rich_types_spec.rb
git commit -m "test(async): Sidekiq round-trips rich types end-to-end (Rails)"
```

---

### Task 7: Full suite + CHANGELOG

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Run the full non-Rails suite**

Run: `bundle exec rspec`
Expected: PASS (green). Investigate and fix any example that asserted the old silent-passthrough behavior — update it to expect the new raise, and note it here.

- [ ] **Step 2: Run the Rails suite**

Run: `cd spec_rails/dummy_app && bundle exec rspec`
Expected: PASS (green).

- [ ] **Step 3: Add CHANGELOG entries**

Add under `## Unreleased` in `CHANGELOG.md` (match the prevailing dense, specific style):

```markdown
* [FEAT] Async argument serialization now uses `ActiveJob::Arguments` whenever ActiveJob is loaded — for **all** adapters, including Sidekiq. Within a deployment every backend now round-trips the same rich type set losslessly (GlobalID models, `Date`, `Time`, `DateTime`, `TimeWithZone`, `Duration`, `BigDecimal`, `Symbol`, `Range`, nested symbol-keyed hashes), fixing a latent bug where a Sidekiq-enqueued `expects :at, type: Time` arrived on the worker as a `String` (validation then failed) while the same action worked under the ActiveJob adapter. The one remaining asymmetry is documented: a deployment **without** ActiveJob accepts only JSON-native + GlobalID-able args (it has no rich serializer to use).
* [BUGFIX] Enqueuing an async action with an unserializable argument now raises a field-aware `Axn::Async::UnserializableArgument` (naming the field, its class, and the fix) at enqueue time — on both the ActiveJob path (wrapping `ActiveJob::SerializationError`) and the no-ActiveJob fallback path — instead of silently corrupting it (Sidekiq would JSON-stringify a `Symbol`/`Date`/`Time`, or dump a `Tempfile`/custom object into the payload).
* [BREAKING] The Sidekiq async payload format changed for the rich types above (ActiveJob's `_aj_*` tagging instead of the previous `_as_global_id` suffix / raw JSON values). Jobs enqueued before deploying this change and run after it may fail to deserialize — drain the Sidekiq queue across the deploy. The no-ActiveJob fallback wire format (`_as_global_id` suffix for GlobalID args) is unchanged. Separately, the fallback path now **raises** on `Symbol`/`Date`/`Time`/`BigDecimal`/files/custom objects that previously passed through (lossily); pass JSON-native or GlobalID-able values, or load ActiveJob for the richer set.
```

- [ ] **Step 4: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs(async): CHANGELOG for ActiveJob-based async serialization"
```

---

## Self-Review

**Spec coverage** (ticket PRO-2762 acceptance criteria):
- "With ActiveJob available, Sidekiq round-trips Date/Time/BigDecimal/Symbol/GID losslessly" → Task 3 (unit) + Task 6 (integration). ✅
- "Unserializable arg raises `Axn::Async::UnserializableArgument` naming field+class+fix at enqueue, on both AJ and fallback paths" → Task 1 (message), Task 2 (fallback raise), Task 3 (AJ-path raise). ✅
- "Fallback path raises on Symbol/Date/Time/BigDecimal/files/custom objects; still accepts JSON-native + GID-able" → Task 2. ✅
- "Covered in non-Rails `spec/` and Rails `spec_rails/`" → Task 2 (spec/), Tasks 3 & 6 (spec_rails/). ✅
- "CHANGELOG `## Unreleased`, `[BREAKING]` for wire-format" → Task 7. ✅
- Scope OUT (`type: :file`) — not implemented. ✅

**Placeholder scan:** Tasks 5 and 6 contain `NOTE:` callouts directing the implementer to match existing spec helpers rather than copy a sketch verbatim — these are guidance, not deferred work; the behavioral assertions are concrete. Task 2's `_serialize_via_active_job` stub is intentional scaffolding, replaced wholesale in Task 3. No TBD/TODO remain.

**Type consistency:** `AsyncSerialization.serialize/deserialize`, `_active_job_available?`, `_fallback_serializable?`, `_json_native?`, `_serialize_via_active_job`, `_deserialize_via_active_job`, `_unserializable_hint`, `_io_like?`, `_active_storage_proxy?`, and `UnserializableArgument.new(field:, value:)` are named identically across all tasks. Call sites (sidekiq.rb, enqueue_all_orchestrator.rb) use `serialize`/`deserialize` only. ✅
