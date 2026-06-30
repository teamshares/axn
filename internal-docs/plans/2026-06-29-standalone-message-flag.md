# `prefixed:` → `standalone:` Message Flag Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the `prefixed:` message kwarg with `standalone:` — a pure rename with **inverted polarity** — plus an undocumented `bare:` alias. No feature removed: promotion is retained, now expressed as `standalone: false`. All unreleased, so no back-compat.

**Architecture:** `prefixed:` controls whether a message attaches to the base. We rename it to `standalone:` (the inverse: `standalone: true` ⟺ old `prefixed: false`; `standalone: false` ⟺ old `prefixed: true`) and invert every internal site in one atomic change so the suite is green at a single commit. Mechanically: the descriptor's stored flag, its default rule, the resolver's `base_candidates`/`reason?`/resolution polarity, the `Failure`/`EarlyCompletion` flag, the `Context` early-completion flag, and `Result`'s call sites all flip together.

**Tech Stack:** Ruby, RSpec. Rails-optional (no AR/Rails constants outside `defined?` guards).

## Global Constraints

- `standalone:` replaces `prefixed:` with **inverted polarity** and is valid on **any** entry (no reason-only restriction, no new raises). `standalone: true` renders a message on its own; `standalone: false` attaches it to the base.
- **Default follows conditionality:** `standalone = matcher.static? if standalone.nil?` — an unconditional entry defaults to standalone (the base headline); a conditional entry defaults to attached (a reason). So `standalone: false` on an unconditional entry **promotes** it to an attached reason (the old `prefixed: true`); `standalone: true` on a conditional reason opts it out (the old `prefixed: false`).
- The opt-out is **action-scoped** (a bubbled child still gets an ancestor's base via `call!`).
- **`bare:` is an undocumented alias** for `standalone:` everywhere `standalone:` is accepted (`error`/`success` DSL, `fail!`, `done!`). When both are given, `bare:` wins: `standalone = bare unless bare.nil?`. Docs never mention `bare:`. To be collapsed to one name before the first non-alpha release.
- Rename the resolver's `with_base_prefix` → `with_base` ("prefix" is inaccurate now that `join:` can wrap); update its three `Result` call sites.
- `prefixed` is a reserved exposure name (it's a `fail!`/`done!` control kwarg) → replace with `standalone` + `bare`.
- All unreleased → **no `[BREAKING]` note**, no deprecation shims, no `REMOVED_OPTION_MESSAGES` entry for `prefixed:` (it falls through to the generic unknown-option error).
- Do **not** touch the unrelated field-namespacing `prefix:` kwarg (contract.rb subfield logic, strategies' field prefixing). Only the message-presentation tokens: `prefixed`/`prefixed?`/`with_base_prefix`/`__early_completion_prefixed`/`_fail_prefixed?`.
- Run the suite with `bundle exec rspec`; a single file with `bundle exec rspec <path>`.

---

## File Structure

**lib (rename + invert):** `exceptions.rb`, `core.rb`, `executor.rb`, `context.rb`, `result.rb`, `core/flow/messages.rb`, `core/flow/handlers/descriptors/message_descriptor.rb`, `core/flow/handlers/resolvers/message_resolver.rb`, `strategies/model.rb`, `core/contract.rb`.

**specs (port):** `messages_prefix_spec.rb` (→ rename to `messages_standalone_spec.rb`), `messages_aggregation_spec.rb`, `messages_spec.rb`, `flow/handlers/resolvers/message_resolver_spec.rb`, `reserved_attribute_names_spec.rb`, `user_facing_spec.rb`, `mountable/steps/failure_semantics_spec.rb`, `internal/async_serialization_spec.rb`, plus any other spec a full grep surfaces.

**docs:** `docs/usage/writing.md`, `CHANGELOG.md` (Task 2).

---

### Task 1: Rename `prefixed:` → `standalone:` (invert polarity) + `bare:` alias

This is one atomic change — a half-renamed boolean won't compile/pass. Update the specs to the new API first (RED), then rename across lib (GREEN). Complete before/after for each lib file; specs follow mechanical transformation rules plus the explicit add list.

**Files:** all lib + spec files listed above.

**Interfaces:**
- Produces: `MessageDescriptor#standalone?`, `MessageDescriptor.build(..., standalone: nil)`; `Axn::Failure#standalone?` / `EarlyCompletion#standalone`; `Context#__early_completion_standalone`; `Result#_fail_standalone?`; `MessageResolver#with_base` (renamed from `with_base_prefix`); DSL `error`/`success`/`fail!`/`done!` accept `standalone:` and `bare:`.
- Consumes: the merged `join:`/`combine`/`with_base_prefix` machinery.

- [ ] **Step 1: Port specs to the new API (RED)**

Mechanical transformation across all spec files (apply only to the message-presentation flag; never the field-namespacing `prefix:` kwarg). The polarity inverts:
- `prefixed: false` → `standalone: true`
- `prefixed: true` → `standalone: false`
- `fail!(..., prefixed: false)` / `done!(..., prefixed: false)` → `standalone: true`
- `.prefixed?` stub/expectation → `.standalone?` (and invert the stubbed boolean)
- `build_descriptor(..., prefixed:)` helper param → `standalone:`
- `with_base_prefix` references in specs → `with_base`

Then make these explicit edits:

In `spec/axn/core/messages_prefix_spec.rb` — **rename the file to `spec/axn/core/messages_standalone_spec.rb`** (`git mv`) and update the top-level `RSpec.describe` string to `"Axn standalone message resolution"`. The existing promotion contexts stay — port `error(prefixed: true, &:message)` → `error(standalone: false, &:message)` and `error "detail", prefixed: true` → `error "detail", standalone: false`, asserting the **same** `"<base>: <detail>"` output. Add `bare:` parity tests (the only `bare:` coverage):
```ruby
  it "bare: is an alias for standalone: (fail!)" do
    action = build_axn do
      error "Couldn't sync user"
      def call = fail!("card declined", bare: true)
    end
    expect(action.call.error).to eq("card declined")
  end

  it "bare: is an alias for standalone: (conditional error)" do
    action = build_axn do
      error "Couldn't sync user"
      error "Vendor not found", if: ArgumentError, bare: true
      def call = raise ArgumentError, "boom"
    end
    expect(action.call.error).to eq("Vendor not found")
  end
```

In `spec/axn/core/flow/handlers/resolvers/message_resolver_spec.rb` — the `build_descriptor` helper's `prefixed: nil` param → `standalone: nil` (pass `standalone:` to `build`); rename the `with_base_prefix` describe/stub to `with_base`; invert any `prefixed?` stub to `standalone?`.

In `spec/axn/core/reserved_attribute_names_spec.rb` (lines ~74-76) — update the comment to reference `standalone`/`bare` as the `fail!`/`done!` control kwargs, and change `%w[outcome exception elapsed_time finalized? __action__ prefixed]` → `%w[outcome exception elapsed_time finalized? __action__ standalone bare]`.

Run: `bundle exec rspec spec/axn/core/messages_standalone_spec.rb` (and the others touched) — Expected: FAIL (`Unknown :standalone option` / `with_base` undefined / reserved-name mismatches).

- [ ] **Step 2: `MessageDescriptor` — invert to `standalone` (GREEN begins)**

In `lib/axn/core/flow/handlers/descriptors/message_descriptor.rb`:

```ruby
            REMOVED_OPTION_MESSAGES = {
              from: "from: is no longer supported — run the child with `call` and " \
                    '`fail!("context: #{result.error}") unless result.ok?`',
              prefix: "prefix: is no longer supported — declare a base `error \"…\"` " \
                      "(attaches reasons by default; opt out with standalone: true)",
            }.freeze

            attr_reader :join

            def initialize(matcher:, handler:, standalone: false, join: nil)
              @standalone = standalone
              @join = join
              super(matcher:, handler:)
            end

            def standalone? = @standalone
```

`build` — invert the default rule; `base` now means "unconditional AND standalone":
```ruby
            def self.build(handler: nil, if: nil, unless: nil, standalone: nil, join: nil, **unsupported)
              reject_unsupported_options!(unsupported)
              matcher = Matcher.build(if:, unless:)

              # Default by conditionality: an unconditional entry is the standalone base headline; a
              # conditional entry is an attached reason. standalone: false on an unconditional entry
              # promotes it into an attached reason (renders under the base); standalone: true on a
              # conditional reason opts it out (renders on its own).
              standalone = matcher.static? if standalone.nil?

              # join: combines the base with its reasons, so it only belongs on the base — an
              # unconditional, standalone headline. A reason (conditional, or a promoted standalone:false
              # entry) is rejected rather than silently ignored.
              base = matcher.static? && standalone
              raise ArgumentError, "join: only applies to the base (an unconditional headline)" if join && !base
              raise ArgumentError, "join: must be a String or a callable ->(base, reason) {}" if join && !(join.is_a?(String) || join.respond_to?(:call))

              new(handler:, standalone:, join:, matcher:)
            end
```

- [ ] **Step 3: DSL — thread `standalone:` + `bare:` alias**

In `lib/axn/core/flow/messages.rb`:
```ruby
          def _add_message(kind, message:, standalone: nil, bare: nil, join: nil, **kwargs, &block)
            Axn::Core::Flow::Handlers::Descriptors::MessageDescriptor.reject_unsupported_options!(kwargs.slice(:from, :prefix))
            raise Axn::UnsupportedArgument, "calling #{kind} with both :if and :unless" if kwargs.key?(:if) && kwargs.key?(:unless)
            raise ArgumentError, "Provide either a message or a block, not both" if message && block_given?
            raise ArgumentError, "Provide a message or a block" unless message || block_given?

            standalone = bare unless bare.nil? # bare: is an undocumented alias for standalone:
            entry = _build_entry(message, standalone:, join:, kwargs:, block:, block_given: block_given?)

            self._messages_registry = _messages_registry.register(event_type: kind, entry:)
            true
          end

          def _build_entry(message, standalone:, join:, kwargs:, block:, block_given:)
            if message.is_a?(Axn::Core::Flow::Handlers::Descriptors::MessageDescriptor)
              raise ArgumentError, "Cannot pass additional configuration with prebuilt descriptor" if kwargs.any? || block_given || !standalone.nil? || join

              return message
            end

            Axn::Core::Flow::Handlers::Descriptors::MessageDescriptor.build(
              handler: block_given ? block : message,
              standalone:,
              join:,
              **kwargs,
            )
          end
```

- [ ] **Step 4: `MessageResolver` — invert resolution, rename `with_base_prefix` → `with_base`**

In `lib/axn/core/flow/handlers/resolvers/message_resolver.rb`:

`resolve_message` (render alone when standalone, else attach):
```ruby
            def resolve_message
              descriptor, reason = matched_reason
              return base_message || fallback_message unless descriptor

              descriptor.standalone? ? reason : with_base(reason)
            end
```

Rename the public method (update its comment to say "the base", not "prefix"):
```ruby
            # Combine an externally-supplied reason (e.g. a fail!/done! message) with the base.
            def with_base(reason)
              return reason unless base_message.present?

              combine(base_message, reason)
            end
```

`base_candidates` — a headline is unconditional AND standalone (a promoted `standalone: false` entry is excluded):
```ruby
            def base_candidates = @base_candidates ||= candidate_entries.select { |d| d.static? && d.standalone? && d.handler }
```

`reason?` — invert the `prefixed?` term:
```ruby
            def reason?(descriptor)
              return true unless base_descriptor

              !descriptor.standalone? || !descriptor.static?
            end
```

Update surrounding comments that say "prefixed"/"non-prefixed" to the `standalone` framing (e.g. "an unconditional, standalone entry is the base headline; a conditional or `standalone: false` entry is a reason").

- [ ] **Step 5: `fail!`/`done!`, exceptions, executor, context — invert the runtime flag + alias**

`lib/axn/core.rb` (match the existing bodies; change only signature + coalesce + keyword):
```ruby
    def fail!(message = nil, standalone: false, bare: nil, **exposures)
      _expose_data(exposures, source: "fail!") if exposures.any?
      standalone = bare unless bare.nil?
      raise Axn::Failure.new(message, standalone:, action: self)
    end

    def done!(message = nil, standalone: false, bare: nil, **exposures)
      _expose_data(exposures, source: "done!") if exposures.any?
      standalone = bare unless bare.nil?
      raise Axn::Internal::EarlyCompletion.new(message, standalone:)
    end
```

`lib/axn/exceptions.rb`:
```ruby
    class EarlyCompletion < StandardError
      attr_reader :standalone

      def initialize(message = nil, standalone: false)
        @standalone = standalone
        super(message)
      end
    end
```
```ruby
    # `standalone:` is scoped to that action: an ancestor that catches a bubbled child Failure still
    # applies its OWN base (the child's opt-out is local).
    def initialize(message = nil, standalone: false, action: nil)
      @raw_reason = message
      @presentation = nil
      @standalone = standalone
      @__originating_action = action
      super(message)
    end
    # ...
    def standalone? = @standalone
```
(Update the two comment blocks referencing `prefixed:`/`_fail_prefixed?` to `standalone:`/`_fail_standalone?`.)

`lib/axn/executor.rb` (lines ~294 and ~625, both identical):
```ruby
      @context.__record_early_completion(e.message, standalone: e.standalone)
```

`lib/axn/context.rb`:
```ruby
      @early_completion_standalone = false           # (line ~19, initializer default)
    # ...
    def __record_early_completion(message, standalone: false)
      @early_completion_message = message unless message == Axn::Internal::EarlyCompletion.new.message
      @early_completion_standalone = standalone
    end
    # ...
    def __early_completion_standalone = @early_completion_standalone
```
(Update the comment on `__record_early_completion` to describe the standalone opt-out.)

- [ ] **Step 6: `Result` — invert resolution call sites + `_fail_standalone?`**

In `lib/axn/result.rb`:
- line ~41 (the `Axn::Result.error` factory): `fail! msg, prefixed: false` → `fail! msg, standalone: true`
- line ~180: `return descriptor.prefixed? ? resolver.with_base_prefix(matched) : matched if descriptor` → `return descriptor.standalone? ? matched : resolver.with_base(matched) if descriptor`
- line ~182: `resolver.with_base_prefix(carried)` → `resolver.with_base(carried)`
- line ~189: `_fail_prefixed? ? resolver.with_base_prefix(reason) : reason` → `_fail_standalone? ? reason : resolver.with_base(reason)`
- line ~200: `@context.__early_completion_prefixed ? resolver.with_base_prefix(reason) : reason` → `@context.__early_completion_standalone ? reason : resolver.with_base(reason)`
- `_fail_prefixed?` → `_fail_standalone?`:
```ruby
    def _fail_standalone?
      # A user-facing validation reason attaches by default (no per-field opt-out yet — deferred),
      # so anything that isn't a fail! Failure is NOT standalone.
      return false unless exception.is_a?(Axn::Failure)
      # standalone: is scoped to the action that called fail!. A bubbled child Failure resolved at an
      # ancestor still gets the ancestor's base (child opt-out is local) → not standalone here.
      return false unless exception.__originating_action.equal?(action)

      exception.standalone?
    end
```
(Update the comments at ~174, ~197 that mention `prefixed:`.)

- [ ] **Step 7: Model strategy — port promotion to `standalone: false`**

In `lib/axn/strategies/model.rb`:
- line ~208: `error(if: ->..., prefixed: true)` → drop the now-redundant flag (a conditional reason already attaches by default):
```ruby
          error(if: ->(exception: nil) { (rec = __axn_invalid_record(exception)) && rec.errors.any? }) do |exception = nil|
            __axn_invalid_record(exception).errors.full_messages.to_sentence
          end
```
- line ~215: `success(prefixed: true) { ... }` → `success(standalone: false) { ... }` (promote the unconditional default into an attached reason); keep the comment's intent, updating the wording:
```ruby
          # Default mode-aware success, installed as an attached *reason* (standalone: false, not a
          # headline) so a base `success "…"` declared after `use :model` attaches it ("<base>: Created
          # Widget"), parallel to the error body above. Declare a standalone success to replace it instead.
          success(standalone: false) { "#{__axn_model.previously_new_record? ? 'Created' : 'Updated'} #{__axn_model.class.model_name.human}" }
```

- [ ] **Step 8: Reserved exposure names**

In `lib/axn/core/contract.rb`, `RESERVED_FIELD_NAMES_FOR_EXPOSURES` (around line 331): remove `prefixed`, add `standalone` and `bare` (both are now `fail!`/`done!` control kwargs). Check `RESERVED_FIELD_NAMES_FOR_EXPECTATIONS`; if `prefixed` isn't there, leave it. (Matches the Step 1 spec edit.)

- [ ] **Step 9: Run the full suite (GREEN)**

Run: `bundle exec rspec`
Expected: PASS. Then `grep -rn "prefixed\|with_base_prefix" lib/ spec/` — Expected: no message-presentation hits remain (the only `prefix` hits left are the unrelated field-namespacing `prefix:` feature, `_aj_`-prefixed comments, etc.). Fix any stray `prefixed:` reference and re-run.

- [ ] **Step 10: Commit**

```bash
git add lib spec
git commit -m "refactor(messages): rename prefixed: to standalone: (inverted) + bare: alias

Pure rename + polarity inversion (standalone: true == old prefixed: false;
standalone: false == old prefixed: true, the promotion form). Renames
with_base_prefix -> with_base. No behavior change.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Documentation + CHANGELOG

Update user-facing docs to `standalone:`; `bare:` stays undocumented.

**Files:** `docs/usage/writing.md`, `CHANGELOG.md`. (Also scan `docs/reference/instance.md`, `docs/reference/class.md` for message-`prefixed` references — update any to `standalone:`; leave field-namespacing `prefix:` mentions alone.)

**Interfaces:** none (docs only).

- [ ] **Step 1: `docs/usage/writing.md`**

Read the current message-presentation section, then:
- Replace the `prefixed: false` opt-out row/examples with `standalone: true` (renders the reason on its own; action-scoped — a bubbled child still gets an ancestor's base).
- Replace the promotion row/example (`prefixed: true`) with `standalone: false` ("attach an otherwise-headline entry under the base as a reason" — e.g. `error(standalone: false, &:message)` for an always-on detail rendered under the base).
- Frame the flag as: `standalone: true` = render on its own; `standalone: false` = attach to the base; default follows conditionality.
- Do **not** mention `bare:`.

- [ ] **Step 2: `CHANGELOG.md` (Unreleased)**

Amend the prefixing entry: the flag is `standalone:` (inverted — `standalone: true` renders a reason on its own; `standalone: false` attaches/promotes; default by conditionality). Add a one-line note: "`bare:` is accepted as an undocumented alias for `standalone:`, to be collapsed to one name before the first non-alpha release." No `[BREAKING]` (unreleased).

- [ ] **Step 3: Verify + commit**

Run: `grep -rn "prefixed" docs --include="*.md" | grep -v "/.vitepress/"` → Expected: no message-presentation hits. Run the docs link-check if present (`npm run docs:check-links`). Run `bundle exec rspec` to confirm docs edits touched nothing.

```bash
git add docs/usage/writing.md CHANGELOG.md docs/reference
git commit -m "docs(messages): document standalone: (inverted prefixed:)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- `prefixed:` → `standalone:` rename + invert, valid on any entry → Task 1 (Steps 2-6). ✓
- Default by conditionality; `standalone: false` promotes → Task 1 (Step 2 default rule; ported promotion tests Step 1). ✓
- `bare:` undocumented alias → Task 1 (Steps 1 parity tests, 3, 5). ✓
- Model strategy ports to `standalone: false` (no hack, no behavior change) → Task 1 (Step 7). ✓
- `with_base_prefix` → `with_base` rename → Task 1 (Steps 4, 6). ✓
- Reserved exposure name update → Task 1 (Steps 1, 8). ✓
- Action-scoping preserved → `_fail_standalone?` keeps the `__originating_action` guard (Step 6). ✓
- Docs + CHANGELOG, no `[BREAKING]`, bare undocumented → Task 2. ✓

**Placeholder scan:** none — lib hotspots have full before/after; spec ports have explicit transformation rules + named add tests.

**Type/polarity consistency:** every site inverts together — `standalone? ? reason : with_base(reason)` (resolution), `static? && standalone?` (base_candidates), `!standalone? || !static?` (reason?), `standalone = matcher.static? if standalone.nil?` (default). `with_base` replaces `with_base_prefix` at all three `Result` call sites and in the resolver. `__early_completion_standalone` reader matches its setter; `_fail_standalone?` matches its single call site. No raises added (the flag is universal), so no new error-path tests.
