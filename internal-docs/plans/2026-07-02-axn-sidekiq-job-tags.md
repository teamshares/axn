# Surface Axn facets as Sidekiq job tags — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When an Axn action is enqueued as a Sidekiq job, surface its declared `tag`/`dimension` facets (input-derived only) as Sidekiq per-job `tags`, so jobs are findable/filterable in the Sidekiq web UI.

**Architecture:** A new global config knob (`Axn.config.sidekiq_job_tag_sources`) selects which facet types participate. At enqueue, the Sidekiq adapter builds a throwaway, non-run action instance from the cleaned kwargs, runs the inbound coercion phase (swallowed) via a new `Axn::Executor#resolve_inbound_facets`, formats the resolved facets as `name:value` strings, and merges them into the job's `.set(tags:)`. Result-derived facets self-omit because the run hasn't happened.

**Tech Stack:** Ruby, RSpec, Sidekiq (real Sidekiq only in `spec_rails/`; pure `spec/` fakes/omits it). Facet foundation from PR #140 (`Axn::Core::Tagging`).

## Global Constraints

- **axn must work outside Rails.** Guard any AR/Rails constant with `defined?()`. Pure unit specs live in `spec/` (no Rails, Sidekiq not a dependency — faked/omitted); Rails+real-Sidekiq specs live in `spec_rails/dummy_app/spec/`. (See `project_axn_works_outside_rails`.)
- **Never break the enqueue.** All facet resolution/formatting at enqueue is best-effort: wrapped so a failure logs via `Axn::Internal::PipingError.swallow` and yields no tags, rather than raising.
- **Facet value coercion is already done** by `Axn::Core::Tagging.coerce` (resolved values are String / Integer / Float / Boolean, or a homogeneous array of those). Formatting must not re-coerce — just stringify into `name:value`.
- **Default is both facet types:** `sidekiq_job_tag_sources` defaults to `%i[tag dimension]`.
- **No manual line breaks in Markdown docs** — one line per paragraph (repo convention).
- Design spec: `internal-docs/specs/2026-07-02-axn-sidekiq-job-tags-design.md`. Follow-up: PRO-2856 (per-axn override).

---

### Task 1: Config knob `sidekiq_job_tag_sources`

Adds the global setting that selects which facet types become Sidekiq tags.

**Files:**
- Modify: `lib/axn/configuration.rb` (add setting near the other `setting` declarations, ~line 25)
- Test: `spec/axn/core/configuration_spec.rb` (add to the existing `RSpec.describe Axn::Configuration` block)

**Interfaces:**
- Produces: `Axn.config.sidekiq_job_tag_sources` → `Array<Symbol>`, a subset of `%i[tag dimension]`, default `%i[tag dimension]`. Assigning a non-array or an array containing anything other than `:tag`/`:dimension` raises `ArgumentError`.

- [ ] **Step 1: Write the failing tests**

Add inside `RSpec.describe Axn::Configuration do` in `spec/axn/core/configuration_spec.rb`:

```ruby
  describe "#sidekiq_job_tag_sources" do
    it "defaults to [:tag, :dimension]" do
      expect(config.sidekiq_job_tag_sources).to eq(%i[tag dimension])
    end

    it "accepts a bounded-only subset" do
      config.sidekiq_job_tag_sources = %i[dimension]
      expect(config.sidekiq_job_tag_sources).to eq(%i[dimension])
    end

    it "accepts an empty array (disables the sink)" do
      config.sidekiq_job_tag_sources = []
      expect(config.sidekiq_job_tag_sources).to eq([])
    end

    it "raises on an unknown source" do
      expect { config.sidekiq_job_tag_sources = %i[tag bogus] }.to raise_error(ArgumentError)
    end

    it "raises on a non-array value" do
      expect { config.sidekiq_job_tag_sources = :tag }.to raise_error(ArgumentError)
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec rspec spec/axn/core/configuration_spec.rb -e sidekiq_job_tag_sources`
Expected: FAIL — `NoMethodError: undefined method 'sidekiq_job_tag_sources'` (setting not defined yet).

- [ ] **Step 3: Add the setting**

In `lib/axn/configuration.rb`, immediately after the `setting :async_max_retries` line (~line 25), add:

```ruby
    # Which declared facet types surface as Sidekiq per-job `tags` at enqueue (PRO-2855).
    # Sidekiq tags are ephemeral job-payload strings shown/searched in the web UI — they carry
    # no metrics-billing cost, so high-cardinality `tag`s are welcome here (unlike metrics).
    # Default is both; set %i[dimension] for bounded-only, or [] to disable the sink.
    SIDEKIQ_JOB_TAG_SOURCES = %i[tag dimension].freeze
    setting :sidekiq_job_tag_sources,
            default: %i[tag dimension],
            validate: ->(v) { v.is_a?(Array) && v.all? { |s| SIDEKIQ_JOB_TAG_SOURCES.include?(s) } }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bundle exec rspec spec/axn/core/configuration_spec.rb -e sidekiq_job_tag_sources`
Expected: PASS (5 examples).

- [ ] **Step 5: Commit**

```bash
git add lib/axn/configuration.rb spec/axn/core/configuration_spec.rb
git commit -m "PRO-2855: add sidekiq_job_tag_sources config knob"
```

---

### Task 2: `Axn::Executor#resolve_inbound_facets`

Adds the inputs-only resolution pass: run the inbound coercion phase (swallowed), then resolve the requested facet maps against the non-run instance.

**Files:**
- Modify: `lib/axn/executor.rb` (add a public method; the coercion helpers `apply_inbound_preprocessing!`, `apply_defaults!`, `validate_contract!` and the memoized `resolved_tags`/`resolved_dimensions` already exist as private methods)
- Test: `spec/axn/executor_spec.rb` (new file)

**Interfaces:**
- Consumes: an `Axn::Executor` built around a throwaway instance — `Axn::Executor.new(action_instance)`.
- Produces: `#resolve_inbound_facets(sources)` where `sources` is a subset of `%i[tag dimension]`; returns a `Hash{Symbol => (scalar|Array)}` — the merged resolved facets for the enabled sources (dimensions merged last, so on a name collision the dimension wins). Never raises for coercion/validation failures (swallowed); result-derived resolvers are omitted.

- [ ] **Step 1: Write the failing tests**

Create `spec/axn/executor_spec.rb`:

```ruby
# frozen_string_literal: true

RSpec.describe Axn::Executor do
  describe "#resolve_inbound_facets" do
    # Build a throwaway (non-run) instance and resolve, mirroring the enqueue path.
    def resolve(klass, sources: %i[tag dimension], **inputs)
      instance = klass.send(:new, **inputs)
      described_class.new(instance).resolve_inbound_facets(sources)
    end

    it "resolves input-derived tags and dimensions" do
      klass = build_axn do
        expects :company_id
        tag(:company_id) { company_id }
        dimension(:plan) { "pro" }
        def call; end
      end
      expect(resolve(klass, company_id: 42)).to eq(company_id: 42, plan: "pro")
    end

    it "filters by requested sources" do
      klass = build_axn do
        expects :company_id
        tag(:company_id) { company_id }
        dimension(:plan) { "pro" }
        def call; end
      end
      expect(resolve(klass, sources: %i[dimension], company_id: 42)).to eq(plan: "pro")
    end

    it "applies inbound preprocess and defaults before resolving" do
      klass = build_axn do
        expects :name, preprocess: ->(v) { v.upcase }
        expects :region, default: "us5"
        tag(:name) { name }
        tag(:region) { region }
        def call; end
      end
      expect(resolve(klass, name: "acme")).to eq(name: "ACME", region: "us5")
    end

    it "omits result-derived facets (no run has happened)" do
      klass = build_axn do
        expects :company_id
        exposes :charge_id
        tag(:company_id) { company_id }
        dimension(:charge) { result.charge_id } # nil before any run → omitted
        def call; end
      end
      expect(resolve(klass, company_id: 42)).to eq(company_id: 42)
    end

    it "swallows an invalid-input failure and still resolves what it can" do
      klass = build_axn do
        expects :company_id # required; omitted below → inbound validation fails, swallowed
        tag(:region) { "us5" }
        def call; end
      end
      expect(resolve(klass)).to eq(region: "us5")
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec rspec spec/axn/executor_spec.rb`
Expected: FAIL — `NoMethodError: undefined method 'resolve_inbound_facets'`.

- [ ] **Step 3: Add the method**

In `lib/axn/executor.rb`, add this method just above the `private` keyword (line 47), so it is public:

```ruby
    # Inputs-only facet resolution for enqueue-time sinks (e.g. Sidekiq job tags), where there
    # is no run to hang completion-time resolution on. Runs ONLY the inbound coercion phase
    # (preprocess + inbound defaults + inbound validation), swallowing any failure so a bad-input
    # enqueue still succeeds, then resolves the requested facet maps. Result-derived resolvers
    # self-omit — reading result/an unexposed field returns nil or raises, and Core::Tagging.resolve
    # skips those per-facet. `sources` is a subset of %i[tag dimension]. See PRO-2855.
    def resolve_inbound_facets(sources)
      begin
        apply_inbound_preprocessing!
        apply_defaults!(:inbound)
        validate_contract!(:inbound)
      rescue StandardError => e
        Internal::PipingError.swallow("resolving inbound facets at enqueue", action: @action, exception: e)
      end

      facets = {}
      facets.merge!(resolved_tags) if sources.include?(:tag)
      facets.merge!(resolved_dimensions) if sources.include?(:dimension)
      facets
    end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bundle exec rspec spec/axn/executor_spec.rb`
Expected: PASS (5 examples).

- [ ] **Step 5: Commit**

```bash
git add lib/axn/executor.rb spec/axn/executor_spec.rb
git commit -m "PRO-2855: add Executor#resolve_inbound_facets (inputs-only pass)"
```

---

### Task 3: Sidekiq tag formatter `job_tags_for`

Pure formatter turning a resolved facet map into `name:value` Sidekiq tag strings. Kept pure and Sidekiq-independent so it unit-tests in `spec/` without loading Sidekiq.

**Files:**
- Modify: `lib/axn/async/adapters/sidekiq.rb` (add a `self.job_tags_for` module method alongside the other `self.` methods, e.g. after `self.default_worker`, ~line 48)
- Test: `spec/axn/async/adapters/sidekiq/job_tags_spec.rb` (new file)

**Interfaces:**
- Produces: `Axn::Async::Adapters::Sidekiq.job_tags_for(facets)` → `Array<String>`. Each `name => value` becomes `"name:value"`; an array value fans out to one tag per element (`plan: %w[a b]` → `["plan:a", "plan:b"]`). Empty map → `[]`.

- [ ] **Step 1: Write the failing tests**

Create `spec/axn/async/adapters/sidekiq/job_tags_spec.rb`:

```ruby
# frozen_string_literal: true

require "axn/async/adapters/sidekiq"

RSpec.describe Axn::Async::Adapters::Sidekiq do
  describe ".job_tags_for" do
    def format(facets) = described_class.job_tags_for(facets)

    it "formats scalar facets as name:value" do
      expect(format(company_id: 42, plan: "pro")).to eq(["company_id:42", "plan:pro"])
    end

    it "fans out an array value to one tag per element" do
      expect(format(plan: %w[trial paid])).to eq(["plan:trial", "plan:paid"])
    end

    it "stringifies boolean and numeric values" do
      expect(format(active: true, count: 3)).to eq(["active:true", "count:3"])
    end

    it "returns [] for an empty map" do
      expect(format({})).to eq([])
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bundle exec rspec spec/axn/async/adapters/sidekiq/job_tags_spec.rb`
Expected: FAIL — `NoMethodError: undefined method 'job_tags_for'`.

- [ ] **Step 3: Add the formatter**

In `lib/axn/async/adapters/sidekiq.rb`, inside `module Sidekiq`, after the `self.default_worker` method (~line 48), add:

```ruby
        # Format a resolved facet map ({name => scalar-or-array-of-scalars}) into Sidekiq job-tag
        # strings in "name:value" form. Array-valued facets fan out to one tag per element. Values
        # are already coerced to legal scalars by Core::Tagging.coerce, so this only stringifies.
        def self.job_tags_for(facets)
          facets.flat_map do |name, value|
            Array(value).map { |element| "#{name}:#{element}" }
          end
        end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bundle exec rspec spec/axn/async/adapters/sidekiq/job_tags_spec.rb`
Expected: PASS (4 examples).

- [ ] **Step 5: Commit**

```bash
git add lib/axn/async/adapters/sidekiq.rb spec/axn/async/adapters/sidekiq/job_tags_spec.rb
git commit -m "PRO-2855: add Sidekiq.job_tags_for facet formatter"
```

---

### Task 4: Wire facet tags into the Sidekiq enqueue

Compute facet tags at enqueue and attach them (merged with any static worker tags) to the job. Real-Sidekiq behavior is verified in the Rails dummy app.

**Files:**
- Modify: `lib/axn/async/adapters/sidekiq.rb` (rework the worker/`.set` section of `_enqueue_async_job`, ~lines 99-111; add private `_resolve_sidekiq_job_tags` in the `class_methods` private block)
- Create: `spec_rails/dummy_app/app/actions/async/test_action_sidekiq_tagged.rb`
- Create: `spec_rails/dummy_app/app/actions/async/test_action_sidekiq_tagged_with_static.rb`
- Test: `spec_rails/dummy_app/spec/axn/async/adapters/sidekiq_spec.rb` (add a `describe "job tags from facets"` block)

**Interfaces:**
- Consumes: `Axn.config.sidekiq_job_tag_sources` (Task 1), `Axn::Executor#resolve_inbound_facets` (Task 2), `Axn::Async::Adapters::Sidekiq.job_tags_for` (Task 3), and `self._tags`/`self._dimensions` (from `Axn::Core::Tagging`).
- Produces: on enqueue, the Sidekiq job carries `tags` = union (deduped) of the worker's static `sidekiq_options[:tags]` and the resolved facet tags, when any facet tags resolve; otherwise no `tags` key is added.

- [ ] **Step 1: Write the failing dummy actions + tests**

Create `spec_rails/dummy_app/app/actions/async/test_action_sidekiq_tagged.rb`:

```ruby
# frozen_string_literal: true

module Actions
  module Async
    # Declares both a high-card `tag` and a bounded `dimension`, plus an inbound default,
    # to exercise enqueue-time facet → Sidekiq job tag surfacing (PRO-2855).
    class TestActionSidekiqTagged
      include Axn
      async :sidekiq

      expects :company_id
      expects :plan, default: "free"

      tag(:company_id) { company_id }
      dimension(:plan) { plan }

      def call; end
    end
  end
end
```

Create `spec_rails/dummy_app/app/actions/async/test_action_sidekiq_tagged_with_static.rb`:

```ruby
# frozen_string_literal: true

module Actions
  module Async
    # Carries a static sidekiq_options tag alongside a facet, to verify the two are unioned
    # (not clobbered) at enqueue.
    class TestActionSidekiqTaggedWithStatic
      include Axn
      async :sidekiq do
        sidekiq_options tags: ["static"]
      end

      expects :company_id
      tag(:company_id) { company_id }

      def call; end
    end
  end
end
```

Add to `spec_rails/dummy_app/spec/axn/async/adapters/sidekiq_spec.rb`, inside the top-level `RSpec.describe "Axn::Async with Sidekiq adapter", :sidekiq do` block:

```ruby
  describe "job tags from facets (PRO-2855)" do
    around { |ex| Sidekiq::Testing.fake! { ex.run } }
    before { Sidekiq::Job.clear_all }

    let(:last_job_tags) { -> { Sidekiq::Job.jobs.last["tags"] } }

    it "surfaces tag + dimension facets as name:value job tags" do
      Actions::Async::TestActionSidekiqTagged.call_async(company_id: 42, plan: "pro")
      expect(last_job_tags.call).to contain_exactly("company_id:42", "plan:pro")
    end

    it "applies inbound defaults before resolving" do
      Actions::Async::TestActionSidekiqTagged.call_async(company_id: 7)
      expect(last_job_tags.call).to contain_exactly("company_id:7", "plan:free")
    end

    it "honors sidekiq_job_tag_sources = [:dimension] (bounded only)" do
      allow(Axn.config).to receive(:sidekiq_job_tag_sources).and_return(%i[dimension])
      Actions::Async::TestActionSidekiqTagged.call_async(company_id: 42, plan: "pro")
      expect(last_job_tags.call).to contain_exactly("plan:pro")
    end

    it "adds no tags key when the action declares no facets" do
      Actions::Async::TestActionSidekiq.call_async(name: "World", age: 25)
      expect(last_job_tags.call).to be_nil
    end

    it "unions facet tags with the worker's static sidekiq_options tags" do
      Actions::Async::TestActionSidekiqTaggedWithStatic.call_async(company_id: 42)
      expect(last_job_tags.call).to contain_exactly("static", "company_id:42")
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd spec_rails/dummy_app && bundle exec rspec spec/axn/async/adapters/sidekiq_spec.rb -e "job tags from facets"`
Expected: FAIL — the actions enqueue but no `tags` are attached (`expected [...] , got nil`).

- [ ] **Step 3: Rework the enqueue section**

In `lib/axn/async/adapters/sidekiq.rb`, replace the `job = if _async_via_default ... end` block (~lines 99-111) with:

```ruby
            # The generic worker for this enqueue: the shared DefaultWorker on the global-default
            # path, else this action's dedicated subclass. Inherited const lookup (no `false`) so a
            # child that inherits async config without redeclaring reuses the parent's subclass; the
            # generic perform(name, …) still runs THIS action by name. display_class keeps the Web
            # UI showing the real action name in both cases.
            worker = _async_via_default ? Axn::Async::Adapters::Sidekiq.default_worker : const_get(:AxnSidekiqWorker)

            set_options = { display_class: name }

            # Surface declared facets as Sidekiq job tags (enqueue-time, inputs-only — PRO-2855).
            # Union with any static tags the worker already carries: `.set` overrides the class
            # default, so re-include them explicitly rather than letting them be dropped.
            facet_tags = _resolve_sidekiq_job_tags(kwargs)
            set_options[:tags] = (Array(worker.get_sidekiq_options["tags"]) + facet_tags).uniq if facet_tags.any?

            job = worker.set(**set_options)
```

Then, in the `class_methods do` block's `private` section, immediately after `_enqueue_async_job` (before the closing `end` of `class_methods`), add:

```ruby
          # Resolve declared facets to Sidekiq job-tag strings at enqueue time. Inputs-only: builds a
          # throwaway (non-run) instance from the cleaned kwargs, runs the inbound coercion pass, and
          # resolves the facet maps enabled by Axn.config.sidekiq_job_tag_sources. Best-effort — never
          # breaks the enqueue. Skips all work (no instance, no coercion) when the sink is disabled or
          # the action declares no facets for the enabled sources. See PRO-2855.
          def _resolve_sidekiq_job_tags(kwargs)
            sources = Axn.config.sidekiq_job_tag_sources
            return [] if sources.empty?

            declares_facets = (sources.include?(:tag) && _tags.any?) || (sources.include?(:dimension) && _dimensions.any?)
            return [] unless declares_facets

            action = send(:new, **kwargs)
            facets = Axn::Executor.new(action).resolve_inbound_facets(sources)
            Axn::Async::Adapters::Sidekiq.job_tags_for(facets)
          rescue StandardError => e
            Axn::Internal::PipingError.swallow("resolving Sidekiq job tags at enqueue", exception: e)
            []
          end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd spec_rails/dummy_app && bundle exec rspec spec/axn/async/adapters/sidekiq_spec.rb -e "job tags from facets"`
Expected: PASS (5 examples).

- [ ] **Step 5: Run the full Sidekiq adapter spec to check for regressions**

Run: `cd spec_rails/dummy_app && bundle exec rspec spec/axn/async/adapters/sidekiq_spec.rb`
Expected: PASS (all examples — the new tags ride the existing `.set` without disturbing display_class, wait/wait_until, or GlobalID paths).

- [ ] **Step 6: Commit**

```bash
git add lib/axn/async/adapters/sidekiq.rb spec_rails/dummy_app/app/actions/async/test_action_sidekiq_tagged.rb spec_rails/dummy_app/app/actions/async/test_action_sidekiq_tagged_with_static.rb spec_rails/dummy_app/spec/axn/async/adapters/sidekiq_spec.rb
git commit -m "PRO-2855: surface facets as Sidekiq job tags at enqueue"
```

---

### Task 5: Documentation

Document the sink, the enqueue-time limitation, and the config knob; refine the cardinality mapping note to reflect that both facet types surface as Sidekiq tags.

**Files:**
- Modify: `docs/reference/configuration.md` (the `### Tagging spans with domain context (tag / dimension)` section, ~lines 249-265)

**Interfaces:** none (docs only).

- [ ] **Step 1: Refine the cardinality mapping note**

In `docs/reference/configuration.md`, replace the existing **Cardinality mapping.** paragraph (line 265) with:

```markdown
**Cardinality mapping.** An Axn `tag` is high-cardinality and becomes a span attribute (and, later, a log field / exception detail) — safe for per-call values like ids. An Axn `dimension` is bounded and additionally flows to **metrics-style** indexing sinks (`emit_metrics` today, Sentry tags later) where unbounded values are costly. This is the reverse of "tag" in Datadog/Sentry (where a tag is the bounded thing); pick the Axn macro by cardinality, not by the downstream tool's word. **Sidekiq job tags are the exception:** they carry no metrics-billing cost, so by default *both* `tag` and `dimension` surface there (see below).
```

- [ ] **Step 2: Add the Sidekiq job tags subsection**

Immediately after that paragraph (after line 265, before `## emit_metrics`), add:

```markdown

### Surfacing facets as Sidekiq job tags

When an action runs as a Sidekiq job, its declared facets are also attached to the enqueued job's Sidekiq `tags`, so you can find and filter jobs in the Sidekiq web UI (e.g. every job for a given company). Each facet becomes a `name:value` tag; an array-valued facet fans out to one tag per element.

```ruby
Axn.config.sidekiq_job_tag_sources # => default %i[tag dimension]
```

Because Sidekiq tags are ephemeral job-payload strings (gone when the job finishes) with no per-value metrics cost, both `tag` and `dimension` surface here by default — unlike the metrics sink. Set `%i[dimension]` for bounded-only, or `[]` to disable the sink entirely.

**Enqueue-time limitation (important).** Unlike the span/`emit_metrics` sinks — which resolve at completion, when results are available — Sidekiq `tags` are set at *enqueue*, before the job runs, in a different process. So only **input-derived** facets (resolvable from `expects` inputs, with `preprocess`/`default:` applied) become job tags; **result-derived** facets (`exposes`, `result.outcome`) cannot and are silently omitted. Resolution is best-effort: a failure never breaks the enqueue. This sink is **Sidekiq-specific** — ActiveJob has no native tag concept, and its per-execution facets are already carried on the `axn.call` APM span.
```

- [ ] **Step 3: Verify the docs render (link/format check)**

Run: `grep -n "sidekiq_job_tag_sources\|Surfacing facets as Sidekiq" docs/reference/configuration.md`
Expected: shows the new knob reference and the new `###` heading.

- [ ] **Step 4: Commit**

```bash
git add docs/reference/configuration.md
git commit -m "PRO-2855: document Sidekiq job tags sink + config knob"
```

---

### Task 6: Full-suite verification

Confirm nothing regressed across both suites.

**Files:** none (verification only).

- [ ] **Step 1: Run the pure (non-Rails) suite**

Run: `bundle exec rspec`
Expected: PASS (all examples, including the new `configuration_spec`, `executor_spec`, and `job_tags_spec`).

- [ ] **Step 2: Run the Rails dummy-app suite**

Run: `cd spec_rails/dummy_app && bundle exec rspec`
Expected: PASS (all examples, including the new facet-tags block).

- [ ] **Step 3: Run RuboCop on changed files**

Run: `bundle exec rubocop lib/axn/configuration.rb lib/axn/executor.rb lib/axn/async/adapters/sidekiq.rb`
Expected: no offenses (match surrounding style; `Metrics/ClassLength` on Executor already disabled inline).

---

## Self-Review

**Spec coverage** (against `internal-docs/specs/2026-07-02-axn-sidekiq-job-tags-design.md`):
- Config knob `sidekiq_job_tag_sources` (default both, subset-validated, `[]` disables) → Task 1. ✓
- Both `tag` and `dimension` surface by default → Task 1 default + Task 2 merge + Task 4 wiring. ✓
- Enqueue hook in `_enqueue_async_job`, throwaway non-run instance, inbound coercion swallowed → Task 4 `_resolve_sidekiq_job_tags` + Task 2 `resolve_inbound_facets`. ✓
- Result-derived facets self-omit → Task 2 test "omits result-derived facets". ✓
- Cheap guard (skip when disabled / no facets) → Task 4 `_resolve_sidekiq_job_tags` early returns. ✓
- `name:value` format + array fan-out → Task 3. ✓
- Merge (union, dedup) with static worker tags, not clobber → Task 4 wiring + "unions … static" test. ✓
- Never break enqueue → `PipingError.swallow` in Tasks 2 & 4; Global Constraints. ✓
- Docs (knob, limitation, mapping-note refinement) → Task 5. ✓
- Per-axn override deferred to PRO-2856 → out of scope by design; not a task. ✓
- ActiveJob unaffected (no native tags) → documented in Task 5; no code path touched. ✓

**Placeholder scan:** none — every step has concrete code/commands.

**Type consistency:** `resolve_inbound_facets(sources)` returns a `Hash`; `job_tags_for(facets)` consumes that `Hash` and returns `Array<String>`; `_resolve_sidekiq_job_tags` returns `Array<String>` and feeds `set_options[:tags]`. Names match across Tasks 2 → 3 → 4. ✓
