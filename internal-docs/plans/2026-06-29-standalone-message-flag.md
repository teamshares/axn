# `prefixed:` → `standalone:` Message Flag Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the `prefixed:` message kwarg with `standalone:` (inverted, opt-out-only) plus an undocumented `bare:` alias, drop the promotion direction, and migrate the one internal consumer (model strategy) — all unreleased, so no back-compat.

**Architecture:** `prefixed:` conflated two concepts — render opt-out and headline→reason promotion. We keep only the render opt-out, inverted: `standalone: true` renders a reason without the base. Role (headline vs reason) collapses to pure conditionality. The boolean is inverted across every internal site (`MessageDescriptor`, `Axn::Failure`/`EarlyCompletion`, the `Context` early-completion flag, `Result`, the resolver) in one atomic change so the suite is green at a single commit.

**Tech Stack:** Ruby, RSpec. Rails-optional (no AR/Rails constants outside `defined?` guards).

## Global Constraints

- `standalone:` is **opt-out-only** and **reason-only**: legal on a conditional `error`/`success` or a `fail!`/`done!` message; on an unconditional headline it **raises at declaration** ("standalone: only applies to a reason"). This mirrors `join:` being base-only.
- Default is **attached** (`standalone` defaults `false` for reasons). `standalone: true` opts out. The opt-out is **action-scoped** (a bubbled child still gets an ancestor's base via `call!`).
- **`bare:` is an undocumented alias** for `standalone:` everywhere `standalone:` is accepted (`error`/`success` DSL, `fail!`, `done!`). When both are given, `bare:` wins (coalesce `effective = bare.nil? ? standalone : bare`). Docs never mention `bare:`. To be collapsed to one name before the first non-alpha release.
- **Promotion is removed.** No `prefixed: true`/`standalone: false` on an unconditional entry. The model strategy's default success migrates to an always-on conditional reason.
- All unreleased → **no `[BREAKING]` note**, no deprecation shims, no `REMOVED_OPTION_MESSAGES` entry for `prefixed:` (it falls through to the generic unknown-option error).
- Run the suite with `bundle exec rspec`; a single file with `bundle exec rspec <path>`.

---

## File Structure

**lib (rename + invert):** `exceptions.rb`, `core.rb`, `executor.rb`, `context.rb`, `result.rb`, `core/flow/messages.rb`, `core/flow/handlers/descriptors/message_descriptor.rb`, `core/flow/handlers/resolvers/message_resolver.rb`, `strategies/model.rb`, `core/contract.rb`.

**specs (port):** `messages_prefix_spec.rb` (→ rename to `messages_standalone_spec.rb`), `messages_aggregation_spec.rb`, `messages_spec.rb`, `flow/handlers/resolvers/message_resolver_spec.rb`, `reserved_attribute_names_spec.rb`, `user_facing_spec.rb`, `mountable/steps/failure_semantics_spec.rb`, `internal/async_serialization_spec.rb`, plus any other spec a full grep surfaces.

**docs:** `docs/usage/writing.md`, `CHANGELOG.md` (Task 2).

---

### Task 1: Rename `prefixed:` → `standalone:` (invert, opt-out-only) + `bare:` alias + drop promotion

This is one atomic change — a half-renamed boolean won't compile/pass. Update the specs to the new API first (RED), then rename across lib (GREEN). Provide complete before/after for each lib file; specs follow mechanical transformation rules plus the explicit add/remove list.

**Files:** all lib + spec files listed above.

**Interfaces:**
- Produces: `MessageDescriptor#standalone?`, `MessageDescriptor.build(..., standalone: nil)`; `Axn::Failure#standalone?` / `EarlyCompletion#standalone`; `Context#__early_completion_standalone`; `Result#_fail_standalone?`; `MessageResolver#with_base` (renamed from `with_base_prefix`); DSL `error`/`success`/`fail!`/`done!` accept `standalone:` and `bare:`.
- Consumes: existing `join:`/`combine`/`with_base_prefix` machinery from the merged `join:` work.

- [ ] **Step 1: Port specs to the new API (RED)**

Mechanical transformation across all spec files (apply everywhere the message-presentation flag appears — do NOT touch the unrelated field-namespacing `prefix:` kwarg):
- `prefixed: false` → `standalone: true`
- `prefixed: true` on a **conditional** entry → drop it (conditional reasons attach by default)
- `fail!(..., prefixed: false)` / `done!(..., prefixed: false)` → `standalone: true`
- `.prefixed?` stub/expectation → `.standalone?` (and invert the stubbed boolean)
- `build_descriptor(..., prefixed:)` helper param → `standalone:`

Then make these explicit edits:

In `spec/axn/core/messages_prefix_spec.rb` — **rename the file to `spec/axn/core/messages_standalone_spec.rb`** (`git mv`), update the top-level `RSpec.describe` string to `"Axn standalone message resolution"`, and:
- **Remove** the promotion tests (the contexts exercising `error(prefixed: true, &:message)` and `error "detail", prefixed: true` as headline→reason promotion) — that behavior is gone.
- **Add** a declaration-error test:
```ruby
  it "raises when standalone: is given on an unconditional headline" do
    expect do
      build_axn { error "Headline", standalone: true }
    end.to raise_error(ArgumentError, /standalone: only applies to a reason/)
  end
```
- **Add** `bare:` parity tests (the only `bare:` coverage):
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

In `spec/axn/core/flow/handlers/resolvers/message_resolver_spec.rb` — the `build_descriptor` helper's `prefixed: nil` param → `standalone: nil` (and pass `standalone:` to `build`); rename the `with_base_prefix` describe/stub usage to `with_base`; invert any `prefixed?` stub to `standalone?`.

In `spec/axn/core/reserved_attribute_names_spec.rb` (lines ~74-76) — update the comment to reference `standalone`/`bare` as the `fail!`/`done!` control kwargs, and change the list `%w[outcome exception elapsed_time finalized? __action__ prefixed]` → `%w[outcome exception elapsed_time finalized? __action__ standalone bare]`.

Run: `bundle exec rspec spec/axn/core/messages_standalone_spec.rb` (and the others touched) — Expected: FAIL (`Unknown :standalone option` / `with_base` undefined / reserved-name mismatches).

- [ ] **Step 2: `MessageDescriptor` — standalone, reason-only, drop promotion (GREEN begins)**

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

`build` — accept `standalone:`, reject it on a headline, default false; role is pure conditionality (no promotion):

```ruby
            def self.build(handler: nil, if: nil, unless: nil, standalone: nil, join: nil, **unsupported)
              reject_unsupported_options!(unsupported)
              matcher = Matcher.build(if:, unless:)

              # standalone: opts a *reason* out of the base, so it only applies to a conditional entry.
              # An unconditional entry is the base headline (role is pure conditionality now — there is
              # no promotion). Reject standalone: on a headline rather than silently ignore it.
              raise ArgumentError, "standalone: only applies to a reason (a conditional error/success)" if !standalone.nil? && matcher.static?

              standalone = false if standalone.nil?

              # join: combines the base with its reasons, so it only belongs on the base (an
              # unconditional headline). A conditional reason is rejected rather than silently ignored.
              raise ArgumentError, "join: only applies to the base (an unconditional headline)" if join && !matcher.static?
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

- [ ] **Step 4: `MessageResolver` — invert resolution, drop promotion terms, rename `with_base_prefix` → `with_base`**

In `lib/axn/core/flow/handlers/resolvers/message_resolver.rb`:

`resolve_message` (attach unless standalone):
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

`base_candidates` — all unconditional entries are headlines now (no promotion), so drop the `!d.prefixed?` term:
```ruby
            def base_candidates = @base_candidates ||= candidate_entries.select { |d| d.static? && d.handler }
```

`reason?` — a reason is just a conditional entry now (drop the `prefixed?` term):
```ruby
            def reason?(descriptor)
              return true unless base_descriptor

              !descriptor.static?
            end
```

Update the surrounding comments that say "prefixed"/"non-prefixed" to describe conditionality (e.g. "Unconditional entries are headlines; conditional entries are reasons").

- [ ] **Step 5: `fail!`/`done!`, exceptions, executor, context — invert the runtime flag + alias**

`lib/axn/core.rb`:
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
(Match the exact bodies already present around the existing `_expose_data`/raise lines — only the signature + coalesce + keyword change.)

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

- [ ] **Step 7: Migrate the model strategy off promotion**

In `lib/axn/strategies/model.rb`:
- line ~208: drop the redundant `prefixed: true` (a conditional reason already attaches):
```ruby
          error(if: ->(exception: nil) { (rec = __axn_invalid_record(exception)) && rec.errors.any? }) do |exception = nil|
            __axn_invalid_record(exception).errors.full_messages.to_sentence
          end
```
- line ~215: replace promotion with an always-on conditional reason, and update the comment:
```ruby
          # Default mode-aware success, installed as an always-on *reason* (not a headline) via an
          # always-true condition, so a base `success "…"` declared after `use :model` attaches it
          # ("<base>: Created Widget"), parallel to the error body above. Declare a conditional/
          # standalone success to replace it instead.
          success(if: ->(*) { true }) { "#{__axn_model.previously_new_record? ? 'Created' : 'Updated'} #{__axn_model.class.model_name.human}" }
```

- [ ] **Step 8: Reserved exposure names**

In `lib/axn/core/contract.rb`, `RESERVED_FIELD_NAMES_FOR_EXPOSURES` (around line 331): remove `prefixed`, add `standalone` and `bare` (both are now `fail!`/`done!` control kwargs). Check `RESERVED_FIELD_NAMES_FOR_EXPECTATIONS` too; if `prefixed` is not there, leave it. (The spec edit in Step 1 already matches this.)

- [ ] **Step 9: Run the full suite (GREEN)**

Run: `bundle exec rspec`
Expected: PASS. Then `grep -rn "prefixed\|with_base_prefix" lib/ spec/` — Expected: no message-presentation hits remain (the only `prefix` hits left are the unrelated field-namespacing `prefix:` feature in `contract.rb`/`subfields`/`strategies/model` field logic, `_aj_`-prefixed comments, etc.). If a stray promotion test or `prefixed:` reference remains, fix and re-run.

- [ ] **Step 10: Commit**

```bash
git add lib spec
git commit -m "refactor(messages): rename prefixed: to standalone: (opt-out-only) + bare: alias

Inverts the flag, drops promotion (model strategy migrates to an always-on
conditional reason), renames with_base_prefix -> with_base.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Documentation + CHANGELOG

Update user-facing docs to `standalone:`; `bare:` stays undocumented.

**Files:** `docs/usage/writing.md`, `CHANGELOG.md`. (Also scan `docs/reference/instance.md`, `docs/reference/class.md` for message-`prefixed` references — update any to `standalone:`; leave field-namespacing `prefix:` mentions alone.)

**Interfaces:** none (docs only).

- [ ] **Step 1: `docs/usage/writing.md`**

Read the current message-presentation section, then:
- Replace the `prefixed: false` opt-out row/examples with `standalone: true` (the message renders on its own; action-scoped — a bubbled child still gets an ancestor's base).
- **Remove** the promotion row/example (`error(prefixed: true, &:message)` / "Promote to an always-on reason") — that capability is gone. If an always-on detail under the base is still worth documenting, show the base-block form: `error { "Couldn't sync user: #{exception.message}" }`.
- Note that `standalone:` is reason-only (raises on a base headline), mirroring `join:` being base-only.
- Do **not** mention `bare:`.

- [ ] **Step 2: `CHANGELOG.md` (Unreleased)**

Amend the prefixing entry: the opt-out flag is `standalone:` (render a reason on its own; default attached; action-scoped), promotion is removed, base-only/reason-only symmetry with `join:`. Add a one-line note: "`bare:` is accepted as an undocumented alias for `standalone:`, to be collapsed to one name before the first non-alpha release." No `[BREAKING]` (unreleased).

- [ ] **Step 3: Verify + commit**

Run: `grep -rn "prefixed" docs --include="*.md" | grep -v "/.vitepress/"` → Expected: no message-presentation hits. Run the docs link-check if present (`npm run docs:check-links`). Run `bundle exec rspec` to confirm docs edits touched nothing.

```bash
git add docs/usage/writing.md CHANGELOG.md docs/reference
git commit -m "docs(messages): document standalone: (opt-out), retire prefixed:/promotion

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- `prefixed:` → `standalone:` rename + invert → Task 1 (Steps 2-6). ✓
- `bare:` undocumented alias → Task 1 (Steps 1 bare-parity tests, 3, 5). ✓
- Opt-out-only / promotion dropped / reason-only raise → Task 1 (Step 2 validation, Step 1 raise test + promotion-test removal). ✓
- Model strategy migration → Task 1 (Step 7). ✓
- `with_base_prefix` → `with_base` rename → Task 1 (Steps 4, 6). ✓
- Reserved exposure name update → Task 1 (Steps 1, 8). ✓
- Action-scoping preserved → `_fail_standalone?` keeps the `__originating_action` guard (Step 6). ✓
- Docs + CHANGELOG, no `[BREAKING]`, bare undocumented → Task 2. ✓

**Placeholder scan:** none — lib hotspots have full before/after; spec ports have explicit transformation rules + named add/remove tests.

**Type consistency:** `standalone?`/`standalone:` used consistently across descriptor, DSL, exceptions, context, result; `with_base` replaces `with_base_prefix` at all three Result call sites and in the resolver; `__early_completion_standalone` reader matches its setter; `_fail_standalone?` matches its single call site.

**Note for the executor:** the model strategy's always-true success condition (`if: ->(*) { true }`) is invoked with the success-event arity (exception: nil); `->(*) { true }` accepts any args. If the suite surfaces an arity error there, that's the place to look.
