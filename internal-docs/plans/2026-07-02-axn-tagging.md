# Axn tagging (`tag` + `dimension`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two class-level macros — `tag` (high-cardinality) and `dimension` (bounded) — that let an action declare domain facets which resolve once per execution and attach to the observability Axn already emits: the `axn.call` OpenTelemetry span, the `axn.call` `ActiveSupport::Notifications` payload, and (for `dimension`) the `emit_metrics` hook.

**Architecture:** A new `Axn::Core::Tagging` concern stores two per-class maps (`_tags`, `_dimensions`) via `class_attribute` and exposes the `tag`/`dimension` DSL (dual form mirroring `expose`). `Axn::Executor#with_tracing` resolves each declared map once, at span close (where `axn.outcome` is already set — the settled-result point where inputs, outputs, and result are all available), then routes: tags → `axn.tag.<name>` span attributes + `payload[:tags]`; dimensions → `axn.dimension.<name>` span attributes + `payload[:dimensions]` + an `emit_metrics` `dimensions:` kwarg.

**Tech Stack:** Ruby, RSpec. The gem targets non-Rails too — guard any Rails/OpenTelemetry constants with `defined?`.

## Global Constraints

- **Two metadata-free macros**, both with the same three-form signature (positional pair / single-name-with-block / hash-of-many), mirroring `Contract#expose` (`lib/axn/core/contract.rb:582`). No per-tag options (no `metric:`, no `if:`).
- **Resolver shapes:** proc (arity 0, `instance_exec`'d on the action), symbol (an action method name), or literal (static value).
- **Names symbolized at declaration** (symbol-canonical contract, PRO-2790).
- **Span attribute namespaces:** `axn.tag.<name>` and `axn.dimension.<name>` — distinct, so `tag :x` and `dimension :x` coexist with no collision.
- **Payload keys:** `payload[:tags]`, `payload[:dimensions]` — separate, plain `{name => value}` hashes, present **only when the macro was declared** (absent otherwise, never empty-hash-when-undeclared).
- **`emit_metrics` gains a `dimensions:` kwarg**, always passed (default `{}`). Backward-compatible: it flows through `Internal::Callable.call_with_desired_shape`, which passes only the kwargs the block declares, so existing `proc { |resource:, result:| }` blocks are unaffected. `tag`s are **never** passed to `emit_metrics`.
- **Value coercion:** `nil` → skip the facet entirely (attribute, payload entry, and — for dimensions — the `emit_metrics` entry). `String`/`Numeric`/`true`/`false`/`Array` → passed through. Anything else → `to_s`.
- **Per-facet raise-safety:** each resolver runs independently; one that raises is swallowed via `Axn::Internal::PipingError.swallow(message, action:, exception:)` and skipped, leaving the others intact. Resolution is on the settled-result (outside) path and must never itself raise.
- Run the full suite with `bundle exec rspec`; a single file with `bundle exec rspec <path>`; a single example with `bundle exec rspec <path>:<line>`.
- Commit after each task (the repo is on a feature branch, not `gitbutler/worktree`, so `git commit` is fine).

---

## File Structure

- `lib/axn/core/tagging.rb` — **new.** Module `Axn::Core::Tagging`: `included` hook declares `_tags`/`_dimensions` `class_attribute`s; `ClassMethods#tag` / `#dimension` parse the dual form and merge; module functions `resolve`, `resolve_one`, `coerce` do the settled-result resolution. One responsibility: declaring and resolving facet maps.
- `lib/axn/core.rb` — **modify** (`:61`–`:72` include block): add `include Core::Tagging` and the matching `require`.
- `lib/axn/executor.rb` — **modify** (`#with_tracing`, `:53`–`:108`): resolve the maps once (memoized), attach to span + payload + `emit_metrics`.
- `spec/axn/core/tagging_spec.rb` — **new.** Class-level DSL: declaration forms, merge/override, inheritance/mixin accumulation, via `_tags`/`_dimensions` introspection.
- `spec/axn/internal/tracing/tagging_spec.rb` — **new.** Integration through the executor: span attributes (OTel mock harness), payload keys (notifications harness), `emit_metrics` `dimensions:` kwarg, coercion, nil-skip, isolation, zero-overhead, no-OTel path.
- `docs/reference/configuration.md`, `docs/recipes/datadog-dashboards.md`, `CHANGELOG.md` — **modify.** Document both macros, the attribute/payload mappings, the `emit_metrics` `dimensions:` kwarg, and the cardinality mapping note.

---

### Task 1: `Axn::Core::Tagging` — the `tag`/`dimension` DSL and resolution helpers

Create the concern with both macros, per-class storage, and the resolution/coercion functions. This task's tests cover only the class-level declaration surface (storage, dual form, merge, inheritance); resolution correctness is observed end-to-end in Task 2/3 through the executor, where a real running action instance exists.

**Files:**
- Create: `lib/axn/core/tagging.rb`
- Modify: `lib/axn/core.rb` (add `require "axn/core/tagging"` near the other `require "axn/core/*"` lines, and `include Core::Tagging` in the `included` block at `:61`–`:69`)
- Test: `spec/axn/core/tagging_spec.rb`

**Interfaces:**
- Produces:
  - `Axn::Core::Tagging` (module, included into the Axn base).
  - Class methods on any action: `tag(*args, **kwargs, &block)`, `dimension(*args, **kwargs, &block)`.
  - Class readers: `_tags` → `{Symbol => (Proc|Symbol|Object)}`, `_dimensions` → same shape.
  - Module functions: `Axn::Core::Tagging.resolve(map, action:)` → `{Symbol => (String|Numeric|true|false|Array)}` (nil-valued facets omitted, per-facet errors swallowed); `Axn::Core::Tagging.coerce(value)` → coerced scalar.
- Consumes: `Axn::Internal::PipingError.swallow` (existing).

- [ ] **Step 1: Write the failing test**

Create `spec/axn/core/tagging_spec.rb`:

```ruby
# frozen_string_literal: true

RSpec.describe Axn::Core::Tagging do
  describe ".tag / .dimension declaration forms" do
    it "accepts a name + positional resolver" do
      action = build_axn { tag :company_id, -> { 1 } }
      expect(action._tags.keys).to eq([:company_id])
    end

    it "accepts a name + block" do
      action = build_axn { tag(:region) { "us5" } }
      expect(action._tags.keys).to eq([:region])
    end

    it "accepts a hash of many at once" do
      action = build_axn { tag company_id: -> { 1 }, plan: -> { "pro" } }
      expect(action._tags.keys).to eq(%i[company_id plan])
    end

    it "accepts a literal value" do
      action = build_axn { tag :region, "us5" }
      expect(action._tags[:region]).to eq("us5")
    end

    it "symbolizes string keys" do
      action = build_axn { tag "company_id" => -> { 1 } }
      expect(action._tags.keys).to eq([:company_id])
    end

    it "stores dimensions separately from tags" do
      action = build_axn do
        tag :company_id, -> { 1 }
        dimension :plan_tier, -> { "pro" }
      end
      expect(action._tags.keys).to eq([:company_id])
      expect(action._dimensions.keys).to eq([:plan_tier])
    end

    it "raises when positional args are not exactly a name/value pair" do
      expect { build_axn { tag :a, :b, :c } }.to raise_error(ArgumentError)
    end
  end

  describe "inheritance / mixin merge" do
    it "accumulates parent and subclass declarations, subclass overriding same key" do
      parent = build_axn { tag :a, -> { 1 } }
      child = Class.new(parent)
      child.tag :b, -> { 2 }
      child.tag :a, -> { 99 } # override
      expect(parent._tags.keys).to eq([:a])          # parent unchanged
      expect(child._tags.keys).to eq(%i[a b])
      expect(child._tags[:a].call).to eq(99)
    end

    it "accumulates declarations from an included module" do
      concern = Module.new do
        def self.included(base) = base.tag(:from_concern, -> { 1 })
      end
      action = build_axn { include concern }
      expect(action._tags.keys).to include(:from_concern)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/core/tagging_spec.rb`
Expected: FAIL — `NoMethodError: undefined method 'tag'` (the concern doesn't exist yet).

- [ ] **Step 3: Write the concern**

Create `lib/axn/core/tagging.rb`:

```ruby
# frozen_string_literal: true

module Axn
  module Core
    # Declarative per-action observability facets. `tag` (high-cardinality) and
    # `dimension` (bounded) share parsing/resolution; they differ only in which
    # sinks the executor routes them to.
    module Tagging
      def self.included(base)
        base.class_eval do
          extend ClassMethods
          class_attribute :_tags, default: {}
          class_attribute :_dimensions, default: {}
        end
      end

      # Resolve a declared map against a running action instance, at the
      # settled-result point. Each resolver runs independently; a nil result
      # omits the facet, a raised error is swallowed and that facet skipped.
      def self.resolve(map, action:)
        map.each_with_object({}) do |(name, resolver), acc|
          value = resolve_one(resolver, action:)
          acc[name] = coerce(value) unless value.nil?
        rescue StandardError => e
          Axn::Internal::PipingError.swallow("resolving observability facet #{name}", action:, exception: e)
        end
      end

      def self.resolve_one(resolver, action:)
        case resolver
        when Proc then action.instance_exec(&resolver)
        when Symbol then action.send(resolver)
        else resolver
        end
      end

      # OpenTelemetry attributes accept only String / Numeric / Boolean / arrays
      # of those. Pass those through; coerce anything else to a String.
      def self.coerce(value)
        case value
        when String, Numeric, true, false, Array then value
        else value.to_s
        end
      end

      module ClassMethods
        def tag(*args, **kwargs, &block)
          self._tags = _tags.merge(_parse_facets(args, kwargs, block))
        end

        def dimension(*args, **kwargs, &block)
          self._dimensions = _dimensions.merge(_parse_facets(args, kwargs, block))
        end

        # Dual form, mirroring Contract#expose: a name + positional/block value,
        # or a hash of name => resolver. Returns a symbol-keyed hash.
        def _parse_facets(args, kwargs, block)
          if args.any?
            raise ArgumentError, "expected a name and a single resolver (or a hash)" unless args.size <= 2

            name = args.first
            value = block || (args.size == 2 ? args.last : nil)
            raise ArgumentError, "provide a resolver (positional, block, or hash), not both" if args.size == 2 && block
            kwargs = kwargs.merge(name => value)
          end

          kwargs.transform_keys(&:to_sym)
        end
      end
    end
  end
end
```

- [ ] **Step 4: Wire it into the base**

In `lib/axn/core.rb`, add the require alongside the other core requires (e.g. after `require "axn/core/automatic_logging"`):

```ruby
require "axn/core/tagging"
```

And in the `included` block (after `include Core::AutomaticLogging` at `:63`):

```ruby
        include Core::Tagging
```

- [ ] **Step 5: Run the tests and make sure they pass**

Run: `bundle exec rspec spec/axn/core/tagging_spec.rb`
Expected: PASS (all examples).

- [ ] **Step 6: Run the full suite to confirm no regressions**

Run: `bundle exec rspec`
Expected: PASS (the new `include` must not disturb existing behavior).

- [ ] **Step 7: Commit**

```bash
git add lib/axn/core/tagging.rb lib/axn/core.rb spec/axn/core/tagging_spec.rb
git commit -m "feat(tagging): add tag/dimension DSL and resolution helpers (PRO-2850)"
```

---

### Task 2: Attach `tag`s to the span and notification payload

Wire resolution into `Executor#with_tracing`: resolve `_tags` once (memoized), set `axn.tag.<name>` span attributes, and add `payload[:tags]` — only when the action declared tags. This task proves resolution end-to-end (proc/symbol/literal, nil-skip, coercion, per-facet isolation) through the observable outputs.

**Files:**
- Modify: `lib/axn/executor.rb` (`#with_tracing`, `:53`–`:108`; add private `resolved_tags` helper)
- Test: `spec/axn/internal/tracing/tagging_spec.rb`

**Interfaces:**
- Consumes: `Axn::Core::Tagging.resolve` and class reader `_tags` (Task 1).
- Produces: `Executor#resolved_tags` (private) → memoized `{Symbol => scalar}`; `payload[:tags]` on the `axn.call` notification; `axn.tag.<name>` span attributes.

- [ ] **Step 1: Write the failing test**

Create `spec/axn/internal/tracing/tagging_spec.rb`. This mirrors the existing OTel mock harness (`spec/axn/internal/tracing/opentelemetry_spec.rb`) and notifications harness (`spec/axn/internal/tracing/active_support_notifications_spec.rb`):

```ruby
# frozen_string_literal: true

RSpec.describe "Axn tagging integration" do
  # --- Notification payload (no OpenTelemetry needed) ---
  describe "payload[:tags]" do
    let(:notifications) { [] }

    before do
      ActiveSupport::Notifications.subscribe("axn.call") do |name, _start, _finish, _id, payload|
        notifications << payload
      end
    end

    after { ActiveSupport::Notifications.unsubscribe("axn.call") }

    it "includes resolved tags from proc, symbol, and literal resolvers" do
      action = build_axn do
        expects :n
        tag :from_proc, -> { n * 2 }
        tag :from_symbol, :computed
        tag :from_literal, "us5"
        def computed = 42
        def call; end
      end
      action.call(n: 5)
      expect(notifications.first[:tags]).to eq(from_proc: 10, from_symbol: 42, from_literal: "us5")
    end

    it "omits a tag whose resolver returns nil (conditional escape hatch)" do
      action = build_axn do
        tag(:present) { "yes" }
        tag(:absent) { nil }
        def call; end
      end
      action.call
      expect(notifications.first[:tags]).to eq(present: "yes")
    end

    it "isolates a raising resolver — siblings still land" do
      allow(Axn::Internal::PipingError).to receive(:swallow)
      action = build_axn do
        tag(:good) { "ok" }
        tag(:bad) { raise "boom" }
        def call; end
      end
      result = action.call
      expect(result).to be_ok
      expect(notifications.first[:tags]).to eq(good: "ok")
    end

    it "coerces non-primitive values to strings" do
      action = build_axn do
        tag(:sym) { :active }
        def call; end
      end
      action.call
      expect(notifications.first[:tags]).to eq(sym: "active")
    end

    it "sets no :tags key when no tags are declared" do
      build_axn { def call; end }.call
      expect(notifications.first).not_to have_key(:tags)
    end
  end

  # --- Span attributes (OpenTelemetry mock harness) ---
  describe "axn.tag.<name> span attributes" do
    let(:mock_tracer) { instance_double("OpenTelemetry::Trace::Tracer") }
    let(:mock_span) { instance_double("OpenTelemetry::Trace::Span") }
    let(:mock_tracer_provider) { instance_double("OpenTelemetry::Trace::TracerProvider") }

    before do
      @original_otel = defined?(OpenTelemetry) ? OpenTelemetry : nil
      otel_module = Module.new { def self.tracer_provider; end }
      trace_module = Module.new
      status_class = Class.new
      mock_status = instance_double("Status")
      status_class.define_singleton_method(:error) { |_msg| mock_status }
      trace_module.const_set(:Status, status_class)
      otel_module.const_set(:Trace, trace_module)
      stub_const("OpenTelemetry", otel_module)
      allow(OpenTelemetry).to receive(:tracer_provider).and_return(mock_tracer_provider)
      allow(mock_tracer_provider).to receive(:tracer).with("axn", Axn::VERSION).and_return(mock_tracer)
      allow(mock_tracer).to receive(:in_span).and_yield(mock_span)
      allow(mock_span).to receive(:set_attribute)
      allow(mock_span).to receive(:record_exception)
      allow(mock_span).to receive(:status=)
    end

    after do
      Axn::Internal::Tracing.instance_variable_set(:@tracer, nil)
      Axn::Internal::Tracing.instance_variable_set(:@tracer_provider, nil)
      Axn::Internal::Tracing.instance_variable_set(:@supports_record_exception, nil)
      if @original_otel && defined?(OpenTelemetry) && @original_otel != OpenTelemetry
        RSpec::Mocks.space.proxy_for(OpenTelemetry).reset
        Object.send(:remove_const, :OpenTelemetry) if defined?(OpenTelemetry)
        Object.const_set(:OpenTelemetry, @original_otel)
      end
    end

    it "sets each declared tag as an axn.tag.<name> attribute" do
      action = build_axn do
        tag :company_id, -> { 123 }
        def call; end
      end
      action.call
      expect(mock_span).to have_received(:set_attribute).with("axn.tag.company_id", 123)
    end

    it "sets no axn.tag.* attribute when none declared" do
      build_axn { def call; end }.call
      expect(mock_span).not_to have_received(:set_attribute).with(a_string_starting_with("axn.tag."), anything)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/internal/tracing/tagging_spec.rb`
Expected: FAIL — `payload[:tags]` is `nil` / `set_attribute` with `axn.tag.*` never received.

- [ ] **Step 3: Add the `resolved_tags` helper and wire it in**

In `lib/axn/executor.rb`, add a private memoized helper (place it in the private section near `with_tracing`):

```ruby
    def resolved_tags
      return @resolved_tags if defined?(@resolved_tags)

      @resolved_tags = @action_class._tags.any? ? Core::Tagging.resolve(@action_class._tags, action: @action) : {}
    end
```

In `with_tracing`, inside `update_payload` (after the existing `payload[:exception] = ...` line, still inside the `begin`):

```ruby
        payload[:tags] = resolved_tags if @action_class._tags.any?
```

And in the OpenTelemetry `in_span` block's `ensure`, inside the existing `begin` (after the `span.set_attribute("axn.outcome", outcome)` / exception block):

```ruby
            resolved_tags.each { |name, value| span.set_attribute("axn.tag.#{name}", value) }
```

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `bundle exec rspec spec/axn/internal/tracing/tagging_spec.rb`
Expected: PASS.

- [ ] **Step 5: Run the existing tracing specs to confirm no regressions**

Run: `bundle exec rspec spec/axn/internal/tracing`
Expected: PASS (existing `axn.outcome`/`axn.resource`/payload/emit_metrics specs unaffected).

- [ ] **Step 6: Commit**

```bash
git add lib/axn/executor.rb spec/axn/internal/tracing/tagging_spec.rb
git commit -m "feat(tagging): attach tags to span (axn.tag.*) and notification payload (PRO-2850)"
```

---

### Task 3: Route `dimension`s to span, payload, and `emit_metrics`

Add the parallel dimension path plus the `emit_metrics` `dimensions:` kwarg (backward-compatible), and prove independent namespaces (`tag :x` + `dimension :x`).

**Files:**
- Modify: `lib/axn/executor.rb` (`#with_tracing`; add private `resolved_dimensions` helper; extend `emit_metrics` kwargs)
- Test: `spec/axn/internal/tracing/tagging_spec.rb` (add a `describe`)

**Interfaces:**
- Consumes: `Axn::Core::Tagging.resolve` and class reader `_dimensions` (Task 1); `resolved_tags` pattern (Task 2).
- Produces: `Executor#resolved_dimensions` (private) → memoized `{Symbol => scalar}`; `payload[:dimensions]`; `axn.dimension.<name>` span attributes; `dimensions:` kwarg on `emit_metrics`.

- [ ] **Step 1: Write the failing test**

Append to `spec/axn/internal/tracing/tagging_spec.rb`:

```ruby
  describe "dimensions" do
    describe "emit_metrics dimensions: kwarg" do
      let(:calls) { [] }
      after { Axn.configure { |c| c.emit_metrics = nil } }

      it "passes resolved dimensions to a block that declares dimensions:" do
        Axn.configure { |c| c.emit_metrics = proc { |resource:, result:, dimensions:| calls << { resource:, dimensions: } } }
        action = build_axn do
          dimension :plan_tier, -> { "pro" }
          def call; end
        end
        action.call
        expect(calls.first[:dimensions]).to eq(plan_tier: "pro")
      end

      it "leaves an existing resource:/result: block untouched (backward compatible)" do
        Axn.configure { |c| c.emit_metrics = proc { |resource:, result:| calls << { resource:, result: } } }
        action = build_axn { dimension :plan_tier, -> { "pro" }; def call; end }
        expect { action.call }.not_to raise_error
        expect(calls.first.keys.sort).to eq(%i[resource result])
      end

      it "passes an empty dimensions hash when none declared" do
        Axn.configure { |c| c.emit_metrics = proc { |dimensions:| calls << dimensions } }
        build_axn { def call; end }.call
        expect(calls.first).to eq({})
      end

      it "never passes tags to emit_metrics" do
        Axn.configure { |c| c.emit_metrics = proc { |dimensions:| calls << dimensions } }
        action = build_axn { tag :company_id, -> { 1 }; def call; end }
        action.call
        expect(calls.first).to eq({})
      end
    end

    describe "payload[:dimensions]" do
      let(:notifications) { [] }
      before { ActiveSupport::Notifications.subscribe("axn.call") { |*, payload| notifications << payload } }
      after { ActiveSupport::Notifications.unsubscribe("axn.call") }

      it "keeps tags and dimensions in separate payload keys and namespaces" do
        action = build_axn do
          tag :company_id, -> { 1 }
          dimension :company_id, -> { "bounded" } # same name, independent
          def call; end
        end
        action.call
        expect(notifications.first[:tags]).to eq(company_id: 1)
        expect(notifications.first[:dimensions]).to eq(company_id: "bounded")
      end

      it "sets no :dimensions key when none declared" do
        build_axn { def call; end }.call
        expect(notifications.first).not_to have_key(:dimensions)
      end
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/axn/internal/tracing/tagging_spec.rb -e dimensions`
Expected: FAIL — `emit_metrics` block raises `ArgumentError: missing keyword: :dimensions` / `payload[:dimensions]` is `nil`.

- [ ] **Step 3: Add the `resolved_dimensions` helper and wire it in**

In `lib/axn/executor.rb`, add the memoized helper next to `resolved_tags`:

```ruby
    def resolved_dimensions
      return @resolved_dimensions if defined?(@resolved_dimensions)

      @resolved_dimensions = @action_class._dimensions.any? ? Core::Tagging.resolve(@action_class._dimensions, action: @action) : {}
    end
```

In `update_payload` (right after the `payload[:tags]` line from Task 2):

```ruby
        payload[:dimensions] = resolved_dimensions if @action_class._dimensions.any?
```

In the `in_span` `ensure` `begin` (right after the `axn.tag.*` loop from Task 2):

```ruby
            resolved_dimensions.each { |name, value| span.set_attribute("axn.dimension.#{name}", value) }
```

In the outer `ensure`, extend the `emit_metrics` kwargs (currently `kwargs: { resource:, result: }` at `:103`):

```ruby
          Internal::Callable.call_with_desired_shape(emit_metrics_proc, kwargs: { resource:, result:, dimensions: resolved_dimensions })
```

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `bundle exec rspec spec/axn/internal/tracing/tagging_spec.rb`
Expected: PASS (all `describe`s, including Task 2's).

- [ ] **Step 5: Run the tracing suite and full suite**

Run: `bundle exec rspec spec/axn/internal/tracing && bundle exec rspec`
Expected: PASS — **except** the `**kwargs` example in `spec/axn/internal/tracing/emit_metrics_spec.rb` (`:164`–`:170`), which now also receives `:dimensions`. Update exactly that example:

```ruby
    it "receives resource:, result:, and dimensions: keyword arguments" do
      result = action.call
      expect(received_args.length).to eq(1)
      expect(received_args.first.keys.sort).to eq(%i[dimensions resource result])
      expect(received_args.first[:resource]).to eq("AnonymousClass")
      expect(received_args.first[:result]).to eq(result)
      expect(received_args.first[:dimensions]).to eq({})
    end
```

The `|resource:|`, `|result:|`, and `|resource:, result:|` examples are unaffected — `call_with_desired_shape` passes each block only the keywords it declares.

- [ ] **Step 6: Commit**

```bash
git add lib/axn/executor.rb spec/axn/internal/tracing/tagging_spec.rb spec/axn/internal/tracing/emit_metrics_spec.rb
git commit -m "feat(tagging): route dimensions to span, payload, and emit_metrics (PRO-2852)"
```

---

### Task 4: Documentation and CHANGELOG

Document both macros where Axn's observability is already documented, including the cardinality mapping note that neutralizes the `tag`-means-high-card-here reversal.

**Files:**
- Modify: `docs/reference/configuration.md` (OpenTelemetry Tracing section `:175`+; `emit_metrics` section `:249`+)
- Modify: `docs/recipes/datadog-dashboards.md`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Document the macros in the OpenTelemetry Tracing section**

In `docs/reference/configuration.md`, after the list of automatic span attributes in the OpenTelemetry Tracing section, add a subsection. Use one line per paragraph (repo convention — no manual line wrapping):

````markdown
### Tagging spans with domain context (`tag` / `dimension`)

Any action can declare domain facets that are resolved once per execution and attached to its `axn.call` span (and notification payload). Use `tag` for high-cardinality facets (ids, references) and `dimension` for bounded ones (a small, known set of values).

```ruby
class ChargeCompany
  include Axn
  expects :company

  tag :company_id, -> { company.id }        # → span attribute axn.tag.company_id
  dimension :plan_tier, -> { company.plan } # → span attribute axn.dimension.plan_tier (+ emit_metrics)
end
```

Each facet takes a resolver: a block/lambda (evaluated in the action's context, so `expects`/`exposes` readers are in scope), a symbol naming an action method, or a literal. Resolvers run at completion, so both input- and result-derived values are available. A resolver returning `nil` omits that facet for the call; a resolver that raises is swallowed and that one facet skipped, leaving the others intact.

**Cardinality mapping.** An Axn `tag` is high-cardinality and becomes a span attribute (and, later, a log field / exception detail) — safe for per-call values like ids. An Axn `dimension` is bounded and additionally flows to indexing sinks — today `emit_metrics`, later Sentry/Sidekiq tags — where unbounded values are costly. This is the reverse of "tag" in Datadog/Sentry/Sidekiq (where a tag is the bounded thing); pick the Axn macro by cardinality, not by the downstream tool's word.
````

- [ ] **Step 2: Document the `emit_metrics` `dimensions:` kwarg**

In the `emit_metrics` section of `docs/reference/configuration.md`, add `dimensions:` to the list of available keyword arguments and show it merged into metric tags:

````markdown
`emit_metrics` also receives `dimensions:` — the resolved `dimension` facets for the action (an empty hash if none). Merge them into your metric tags to get per-action bounded dimensions for free:

```ruby
c.emit_metrics = proc do |resource:, result:, dimensions:|
  TS::Metrics.increment("axn.call", tags: { resource:, outcome: result.outcome.to_s, **dimensions })
end
```

`dimensions:` is opt-in: existing blocks that only declare `resource:`/`result:` are unaffected. Keep dimension values bounded (see the cardinality note above) — they become metric tags.
````

- [ ] **Step 3: Mention `tag`/`dimension` in the datadog-dashboards recipe**

In `docs/recipes/datadog-dashboards.md`, after the "stable metric + tag schema" section, add a short paragraph:

```markdown
Per-action facets ride on top of this schema. A `dimension` declared on an action flows into `emit_metrics` as `dimensions:`, so merging it into your tag set adds a bounded, per-action metric dimension without touching the global hook. A `tag` (high-cardinality) does not reach metrics — it lands on the `axn.tag.*` span attributes instead, for filtering traces in APM.
```

- [ ] **Step 4: Add a CHANGELOG entry**

In `CHANGELOG.md`, under the `## Unreleased` section (create it at the top if absent, matching the existing entry style):

```markdown
- Added `tag` and `dimension` class-level macros for declaring per-action observability facets. `tag` (high-cardinality) attaches to the `axn.call` OpenTelemetry span as `axn.tag.<name>` and to the notification payload as `tags:`. `dimension` (bounded) attaches as `axn.dimension.<name>`, as payload `dimensions:`, and is passed to `emit_metrics` via a new backward-compatible `dimensions:` keyword.
```

- [ ] **Step 5: Verify docs build / links (if the repo builds docs locally)**

Run: `git grep -n "axn.tag\." docs && git grep -n "dimensions:" docs`
Expected: the new references are present and consistent (`axn.tag.<name>`, `axn.dimension.<name>`, `dimensions:`).

- [ ] **Step 6: Commit**

```bash
git add docs/reference/configuration.md docs/recipes/datadog-dashboards.md CHANGELOG.md
git commit -m "docs(tagging): document tag/dimension macros and emit_metrics dimensions: kwarg"
```

---

## Self-Review

**Spec coverage:**
- `tag`/`dimension` DSL, dual form, symbolized keys, resolver shapes, inheritance/mixin merge → Task 1.
- Single evaluation at span close; resolve-only-when-declared → Task 2 (tags), Task 3 (dimensions), via the `@action_class._<map>.any?` guard and memoized helpers.
- `axn.tag.<name>` span attr + `payload[:tags]` → Task 2. `axn.dimension.<name>` span attr + `payload[:dimensions]` + `emit_metrics` `dimensions:` → Task 3.
- Independent namespaces (`tag :x` + `dimension :x`) → Task 3 payload test.
- Value coercion + nil-skip + per-facet isolation → implemented in Task 1 `resolve`/`coerce`, observed in Task 2 tests.
- `emit_metrics` backward compatibility → Task 3 tests (both the `resource:/result:` and the exact-keys cases; the existing `emit_metrics_spec.rb` `**kwargs` example is updated in Task 3 Step 5).
- Non-goals (no `expects tag:` sugar, no `result.tags`, deferred Sentry/Sidekiq/logging sinks, boundedness unenforced) → nothing to implement; not contradicted by any task.
- Docs + CHANGELOG + cardinality mapping note → Task 4.

**Placeholder scan:** No TBD/TODO/"handle edge cases"/"similar to Task N" — every code and test step shows complete content.

**Type consistency:** `_tags`/`_dimensions` (class readers), `Core::Tagging.resolve(map, action:)`, `coerce(value)`, `resolve_one(resolver, action:)`, `Executor#resolved_tags`/`#resolved_dimensions`, span keys `axn.tag.<name>`/`axn.dimension.<name>`, payload keys `:tags`/`:dimensions`, and the `dimensions:` emit_metrics kwarg are named identically everywhere they appear across Tasks 1–4.
