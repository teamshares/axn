# Message join customization (`join:`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the string-only `delimiter:` base-header kwarg with a `join:` kwarg that accepts either a `String` (the infix separator, as before) or a `Proc` `(base, reason) → String` for full control over how a base header combines with its reason (wrapping, recasing), applied identically for `error` and `success`.

**Architecture:** All base↔reason combination already funnels through `MessageResolver#with_base_prefix`, which both `Result#_resolve_error` and `Result#_resolve_success` call, and across nested `call!` each level runs its own `with_base_prefix` (per-segment). We rename the `delimiter` attribute/option to `join`, generalize the single join site to apply a String or a Proc, and make the Proc path raise-safe (it runs on the error-presentation path, which must never itself raise).

**Tech Stack:** Ruby, RSpec. The gem targets non-Rails too — no Rails/AR constants.

## Global Constraints

- `delimiter:` was never released (introduced in #109, in no release tag; appears only under `## Unreleased` in CHANGELOG). **Zero backward-compat work** — remove it cleanly, no `REMOVED_OPTION_MESSAGES` entry, no `[BREAKING]` note.
- `join:` is legal **only on a base** (an unconditional, unprefixed headline). On a reason (conditional, or explicitly `prefixed:`) it raises at declaration — same rule `delimiter:` had.
- Default join when unset is `": "`. An explicit `String` (including `""`) is honored verbatim; only an unset (`nil`) join falls back to the default.
- Proc signature is exactly `(base, reason)`, both positional. `base` is this level's resolved base text; `reason` is the already-resolved segment below.
- The error/success presentation path must never raise: a Proc that raises, has wrong arity, or returns a non-String falls back to the default `": "` join (and logs a warning via `action.warn`).
- No `downcase:`/`wrap:` sugar — casing/wrapping live in the user's Proc.
- Run the full suite with `bundle exec rspec`; run a single file with `bundle exec rspec <path>`.

---

## File Structure

- `lib/axn/core/flow/handlers/descriptors/message_descriptor.rb` — rename `@delimiter`→`@join`; `build` accepts `join:`, enforces base-only placement. `REMOVED_OPTION_MESSAGES` untouched.
- `lib/axn/core/flow/messages.rb` — DSL thread `delimiter:`→`join:` through `_add_message`/`_build_entry`.
- `lib/axn/core/flow/handlers/resolvers/message_resolver.rb` — `#delimiter`→`#join` (reads `descriptor.join`); `with_base_prefix` delegates to a new `combine(base, reason)` that applies String or Proc, with raise-safety on the Proc path.
- Specs: `spec/axn/core/messages_prefix_spec.rb`, `spec/axn/core/messages_aggregation_spec.rb`, `spec/axn/core/flow/handlers/resolvers/message_resolver_spec.rb`, `spec/axn/core/user_facing_spec.rb` — rename existing `delimiter:` cases to `join:`; add Proc, success-parity, and raise-safety cases.
- `docs/usage/writing.md`, `CHANGELOG.md` — `delimiter:`→`join:`, document the Proc form.

---

### Task 1: Rename `delimiter:` → `join:` (String form, behavior parity)

Mechanical rename across descriptor, DSL, and resolver. After this task every existing `delimiter:` behavior works verbatim under `join:` (string form), and `delimiter:` is no longer a recognized option.

**Files:**
- Modify: `lib/axn/core/flow/handlers/descriptors/message_descriptor.rb`
- Modify: `lib/axn/core/flow/messages.rb`
- Modify: `lib/axn/core/flow/handlers/resolvers/message_resolver.rb`
- Test: `spec/axn/core/messages_prefix_spec.rb`, `spec/axn/core/messages_aggregation_spec.rb`, `spec/axn/core/flow/handlers/resolvers/message_resolver_spec.rb`, `spec/axn/core/user_facing_spec.rb`

**Interfaces:**
- Produces: `MessageDescriptor#join` (reader, returns `String | Proc | nil`); `MessageDescriptor.build(..., join: nil, ...)`; DSL `error`/`success` accept `join:`; `MessageResolver#join` and `MessageResolver#combine(base, reason)`.
- Consumes: nothing new.

- [ ] **Step 1: Port the existing delimiter specs to `join:` (these are the failing tests for the rename)**

In `spec/axn/core/messages_prefix_spec.rb`, replace every `delimiter:` with `join:` and update the validation message matcher. Concretely:

```ruby
# context "custom delimiter on the base" (was line ~38)
error "Couldn't sync user", join: " — "
# expectation unchanged: "Couldn't sync user — is invalid"

# context "explicit empty delimiter (join with no separator)" (was line ~49)
error "Failed", join: ""
# expectation unchanged: "Failedreason"

# context "delimiter comes from the headline that actually resolved" (was line ~118)
error(join: "") { "" }
# expectation unchanged: "Base: detail"
```

And the validation block (was lines ~377-420) becomes:

```ruby
    it "raises when join: is given on a conditional reason" do
      expect do
        build_axn { error "x", if: ArgumentError, join: " - " }
      end.to raise_error(ArgumentError, /join: only applies to the base/)
    end

    it "raises when join: is given on a conditional reason that opted out with prefixed: false" do
      expect do
        build_axn { error "x", if: ArgumentError, prefixed: false, join: " - " }
      end.to raise_error(ArgumentError, /join: only applies to the base/)
    end

    it "allows join: on a base error (an unconditional headline)" do
      expect do
        build_axn { error "Headline", join: " - " }
      end.not_to raise_error
    end

    it "raises when join: is combined with prefixed: true (which makes it a reason, not the base)" do
      expect do
        build_axn { error "x", join: " - ", prefixed: true }
      end.to raise_error(ArgumentError, "join: only applies to the base (an unprefixed headline)")
    end

    describe "direct MessageDescriptor.build path" do
      let(:described) { Axn::Core::Flow::Handlers::Descriptors::MessageDescriptor }

      it "raises when join: is given on a conditional reason" do
        expect do
          described.build(handler: "x", if: ArgumentError, join: " - ")
        end.to raise_error(ArgumentError, /join: only applies to the base/)
      end

      it "allows prefixed: true on an unconditional headline (promotes it to a prefixed reason)" do
        expect { described.build(handler: "Headline", prefixed: true) }.not_to raise_error
      end

      it "allows join: on a base (unconditional headline) descriptor" do
        expect { described.build(handler: "Headline", join: " - ") }.not_to raise_error
      end
    end
```

In `spec/axn/core/messages_aggregation_spec.rb`, the "Per-segment delimiters in aggregation" block (was line ~59):

```ruby
RSpec.describe "Per-segment joins in aggregation" do
  it "uses each level's own join for its own segment" do
    inner = build_axn do
      error "C", join: " | "
      def call = fail!("leaf")
    end
    stub_const("Inner", inner)
    mid = build_axn do
      error "B", join: " > "
      def call = Inner.call!
    end
    stub_const("Mid", mid)
    outer = build_axn do
      error "A" # default ": "
      def call = Mid.call!
    end

    expect(outer.call.error).to eq("A: B > C | leaf")
  end
end
```

In `spec/axn/core/user_facing_spec.rb` (was line ~164), `error "Couldn't save widget", delimiter: " — "` → `join: " — "`.

In `spec/axn/core/flow/handlers/resolvers/message_resolver_spec.rb`: the `build_descriptor` helper signature `delimiter: nil` → `join: nil` and the body `delimiter:,` → `join:,`; and line ~141 `allow(error_resolver).to receive(:delimiter).and_return(": ")` → `receive(:join).and_return(": ")`.

- [ ] **Step 2: Run the ported specs to verify they fail**

Run: `bundle exec rspec spec/axn/core/messages_prefix_spec.rb spec/axn/core/messages_aggregation_spec.rb spec/axn/core/flow/handlers/resolvers/message_resolver_spec.rb spec/axn/core/user_facing_spec.rb`
Expected: FAIL — `Unknown :join option for error/success message` (and the validation specs fail because the message still says "delimiter:").

- [ ] **Step 3: Rename in `MessageDescriptor`**

In `lib/axn/core/flow/handlers/descriptors/message_descriptor.rb`, change the attr, initializer, and `build`:

```ruby
            attr_reader :join

            def initialize(matcher:, handler:, prefixed: false, join: nil)
              @prefixed = prefixed
              @join = join
              super(matcher:, handler:)
            end
```

```ruby
            def self.build(handler: nil, if: nil, unless: nil, prefixed: nil, join: nil, **unsupported)
              reject_unsupported_options!(unsupported)
              matcher = Matcher.build(if:, unless:)

              prefixed = !matcher.static? if prefixed.nil?

              # join: (a String separator or a ->(base, reason) {} Proc) is how a base combines with its
              # reasons, so it only belongs on the base — an unconditional, non-prefixed headline.
              # Anything conditional or prefixed is a reason, so reject join: there rather than ignore it.
              base = matcher.static? && !prefixed
              raise ArgumentError, "join: only applies to the base (an unprefixed headline)" if join && !base

              new(handler:, prefixed:, join:, matcher:)
            end
```

(Leave the `REMOVED_OPTION_MESSAGES` map and the `from:`/`prefix:` comment block unchanged — no `delimiter:` entry.)

- [ ] **Step 4: Rename in the DSL**

In `lib/axn/core/flow/messages.rb`, thread `join:` instead of `delimiter:`:

```ruby
          def _add_message(kind, message:, prefixed: nil, join: nil, **kwargs, &block)
            Axn::Core::Flow::Handlers::Descriptors::MessageDescriptor.reject_unsupported_options!(kwargs.slice(:from, :prefix))
            raise Axn::UnsupportedArgument, "calling #{kind} with both :if and :unless" if kwargs.key?(:if) && kwargs.key?(:unless)
            raise ArgumentError, "Provide either a message or a block, not both" if message && block_given?
            raise ArgumentError, "Provide a message or a block" unless message || block_given?

            entry = _build_entry(message, prefixed:, join:, kwargs:, block:, block_given: block_given?)

            self._messages_registry = _messages_registry.register(event_type: kind, entry:)
            true
          end

          def _build_entry(message, prefixed:, join:, kwargs:, block:, block_given:)
            if message.is_a?(Axn::Core::Flow::Handlers::Descriptors::MessageDescriptor)
              raise ArgumentError, "Cannot pass additional configuration with prebuilt descriptor" if kwargs.any? || block_given || !prefixed.nil? || join

              return message
            end

            Axn::Core::Flow::Handlers::Descriptors::MessageDescriptor.build(
              handler: block_given ? block : message,
              prefixed:,
              join:,
              **kwargs,
            )
          end
```

- [ ] **Step 5: Rename in the resolver and introduce `combine` (string form only)**

In `lib/axn/core/flow/handlers/resolvers/message_resolver.rb`, add a default constant, route `with_base_prefix` through `combine`, and rename `#delimiter`→`#join`:

```ruby
            DEFAULT_ERROR = "Something went wrong"
            DEFAULT_SUCCESS = "Action completed successfully"
            DEFAULT_JOIN = ": "
```

```ruby
            # Prefix an externally-supplied reason (e.g. a fail!/done! message) with the base.
            def with_base_prefix(reason)
              return reason unless base_message.present?

              combine(base_message, reason)
            end
```

Replace the `delimiter` method (was line ~85) with:

```ruby
            # The join comes from the headline whose body we're actually showing (resolved_base), NOT
            # the most-recent declared one. nil → default; an explicit "" String is honored verbatim.
            def join = resolved_base&.first&.join

            # Combine base and reason. A String join is the infix separator (default DEFAULT_JOIN when
            # unset); other shapes are handled in later tasks.
            def combine(base, reason)
              j = join
              return "#{base}#{j}#{reason}" if j.is_a?(String)

              "#{base}#{DEFAULT_JOIN}#{reason}"
            end
```

- [ ] **Step 6: Run the ported specs to verify they pass**

Run: `bundle exec rspec spec/axn/core/messages_prefix_spec.rb spec/axn/core/messages_aggregation_spec.rb spec/axn/core/flow/handlers/resolvers/message_resolver_spec.rb spec/axn/core/user_facing_spec.rb`
Expected: PASS.

- [ ] **Step 7: Run the full suite to catch any stray `delimiter:` references**

Run: `bundle exec rspec` and `grep -rn "delimiter" lib/ spec/`
Expected: suite PASS; grep returns no message-related hits (the only remaining `delimiter`/`separator` hits are unrelated — `async.rb`, `executor.rb`, `class_builder.rb`).

- [ ] **Step 8: Commit**

```bash
git add lib/axn/core/flow spec/axn/core
git commit -m "refactor(messages): rename delimiter: to join: (string parity)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Proc form — `join:` accepts `(base, reason) → String`

Add the Proc branch to `combine` plus a build-time type guard, and prove wrapping, recasing, mixed-aggregation, and success parity.

**Files:**
- Modify: `lib/axn/core/flow/handlers/resolvers/message_resolver.rb`
- Modify: `lib/axn/core/flow/handlers/descriptors/message_descriptor.rb`
- Test: `spec/axn/core/messages_prefix_spec.rb`, `spec/axn/core/messages_aggregation_spec.rb`

**Interfaces:**
- Consumes: `MessageResolver#combine` from Task 1.
- Produces: `combine` applies a Proc join; `MessageDescriptor.build` rejects a `join:` that is neither `String` nor callable.

- [ ] **Step 1: Write the failing tests**

Append to `spec/axn/core/messages_prefix_spec.rb`:

```ruby
RSpec.describe "Axn join: Proc form" do
  it "wraps the reason (error)" do
    action = build_axn do
      error "Outer error", join: ->(base, reason) { "#{base} (#{reason})" }
      def call = fail!("inner error")
    end
    expect(action.call.error).to eq("Outer error (inner error)")
  end

  it "recases the reason's first letter (error)" do
    action = build_axn do
      error "Outer error", join: ->(base, reason) { "#{base}: #{reason[0].downcase}#{reason[1..]}" }
      def call = fail!("Inner error")
    end
    expect(action.call.error).to eq("Outer error: inner error")
  end

  it "applies for success/done! identically" do
    action = build_axn do
      success "User synced", join: ->(base, reason) { "#{base} (#{reason})" }
      def call = done!("from cache")
    end
    expect(action.call.success).to eq("User synced (from cache)")
  end

  it "raises at declaration when join: (Proc) is given on a reason" do
    expect do
      build_axn { error "x", if: ArgumentError, join: ->(b, r) { "#{b} #{r}" } }
    end.to raise_error(ArgumentError, /join: only applies to the base/)
  end

  it "raises at declaration when join: is neither a String nor callable" do
    expect do
      build_axn { error "Base", join: 5 }
    end.to raise_error(ArgumentError, /join: must be a String or a callable/)
  end
end
```

Append to `spec/axn/core/messages_aggregation_spec.rb`:

```ruby
RSpec.describe "Mixed String and Proc joins in aggregation" do
  it "uses each level's own join (Proc and String compose per-segment)" do
    inner = build_axn do
      error "C"                                            # default ": "
      def call = fail!("leaf")
    end
    stub_const("Inner", inner)
    outer = build_axn do
      error "A", join: ->(base, reason) { "#{base} [#{reason}]" }
      def call = Inner.call!
    end

    expect(outer.call.error).to eq("A [C: leaf]")
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bundle exec rspec spec/axn/core/messages_prefix_spec.rb -e "Proc form" spec/axn/core/messages_aggregation_spec.rb -e "Mixed"`
Expected: FAIL — wrapping/recasing render with the default `": "` (Proc ignored), and the `join: 5` guard does not yet raise.

- [ ] **Step 3: Add the type guard in `build`**

In `lib/axn/core/flow/handlers/descriptors/message_descriptor.rb`, after the base-placement check in `build`:

```ruby
              base = matcher.static? && !prefixed
              raise ArgumentError, "join: only applies to the base (an unprefixed headline)" if join && !base
              raise ArgumentError, "join: must be a String or a callable ->(base, reason) {}" if join && !(join.is_a?(String) || join.respond_to?(:call))

              new(handler:, prefixed:, join:, matcher:)
```

- [ ] **Step 4: Add the Proc branch to `combine`**

In `lib/axn/core/flow/handlers/resolvers/message_resolver.rb`:

```ruby
            def combine(base, reason)
              j = join
              return j.call(base, reason) if j.respond_to?(:call)
              return "#{base}#{j}#{reason}" if j.is_a?(String)

              "#{base}#{DEFAULT_JOIN}#{reason}"
            end
```

- [ ] **Step 5: Run to verify they pass**

Run: `bundle exec rspec spec/axn/core/messages_prefix_spec.rb spec/axn/core/messages_aggregation_spec.rb`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/axn/core/flow spec/axn/core
git commit -m "feat(messages): join: accepts a (base, reason) Proc

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Raise-safety on the Proc path

A Proc runs on the presentation path, which must never raise. A Proc that raises, has the wrong arity, or returns a non-String falls back to the default join and warns.

**Files:**
- Modify: `lib/axn/core/flow/handlers/resolvers/message_resolver.rb`
- Test: `spec/axn/core/flow/handlers/resolvers/message_resolver_spec.rb`

**Interfaces:**
- Consumes: `MessageResolver#combine` from Task 2 (`action` reader is already available on the resolver — used today by `body_for`/`Invoker.call`).
- Produces: `combine` never propagates an exception from a join Proc.

- [ ] **Step 1: Write the failing tests**

Append to `spec/axn/core/flow/handlers/resolvers/message_resolver_spec.rb` an integration-style block (uses `build_axn` so a real `action` backs `action.warn`):

```ruby
RSpec.describe "join: Proc raise-safety" do
  it "falls back to the default join when the Proc raises" do
    action = build_axn do
      error "Outer", join: ->(_base, _reason) { raise "kaboom in join" }
      def call = fail!("inner")
    end
    expect(action.call.error).to eq("Outer: inner")
  end

  it "falls back to the default join when the Proc has the wrong arity (lambda)" do
    action = build_axn do
      error "Outer", join: ->(only_one) { only_one }
      def call = fail!("inner")
    end
    expect(action.call.error).to eq("Outer: inner")
  end

  it "falls back to the default join when the Proc returns a non-String" do
    action = build_axn do
      error "Outer", join: ->(_base, _reason) { 42 }
      def call = fail!("inner")
    end
    expect(action.call.error).to eq("Outer: inner")
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bundle exec rspec spec/axn/core/flow/handlers/resolvers/message_resolver_spec.rb -e "raise-safety"`
Expected: FAIL — the raising and wrong-arity Procs propagate `RuntimeError`/`ArgumentError` out of `result.error`; the non-String Proc yields `42` instead of the fallback string.

- [ ] **Step 3: Make the Proc path raise-safe**

In `lib/axn/core/flow/handlers/resolvers/message_resolver.rb`, split the Proc application into a guarded helper:

```ruby
            def combine(base, reason)
              j = join
              return apply_join_proc(j, base, reason) if j.respond_to?(:call)
              return "#{base}#{j}#{reason}" if j.is_a?(String)

              "#{base}#{DEFAULT_JOIN}#{reason}"
            end

            # A join Proc runs on the presentation path, which must never raise. A Proc that raises,
            # mismatches arity, or returns a non-String falls back to the default join (and warns) —
            # mirroring how a base-header block that raises falls back down the headline chain.
            def apply_join_proc(proc, base, reason)
              result = proc.call(base, reason)
              return result if result.is_a?(String)

              action.warn("join: Proc returned #{result.class} (expected String) — using default join")
              "#{base}#{DEFAULT_JOIN}#{reason}"
            rescue StandardError => e
              action.warn("join: Proc raised #{e.class}: #{e.message} — using default join")
              "#{base}#{DEFAULT_JOIN}#{reason}"
            end
```

- [ ] **Step 4: Run to verify they pass**

Run: `bundle exec rspec spec/axn/core/flow/handlers/resolvers/message_resolver_spec.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/axn/core/flow spec/axn/core
git commit -m "fix(messages): join: Proc is raise-safe (fall back to default join)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Documentation + CHANGELOG

Update the user-facing docs and the Unreleased CHANGELOG entries to describe `join:` (String|Proc) instead of `delimiter:`. No `[BREAKING]` note — `delimiter:` never shipped.

**Files:**
- Modify: `docs/usage/writing.md`
- Modify: `CHANGELOG.md`

**Interfaces:** none (docs only).

- [ ] **Step 1: Update `docs/usage/writing.md`**

Replace the "Custom delimiter" table row (was line ~262):

```markdown
| **Custom join** | `error "Headline", join: " — "` changes the separator string (default is `": "`); or pass a Proc `join: ->(base, reason) { … }` for full control (wrapping, recasing). Only valid on the base — `join:` on a reason raises at declaration |
```

In the example block (was line ~271), `error "Couldn't sync user", delimiter: " — "` → `join: " — "`.

In the "Header aggregation across nested call!" tip, update the `delimiter:` references (was lines ~293, ~317) to `join:` — e.g. "joined by the outer action's own `join:`" and "Each level uses *its own* `join:` for the segment it joins — so `error "Onboarding failed", join: " — "` would produce `"Onboarding failed — Charge failed: card declined"`."

After that sentence, add a Proc example:

````markdown
For full control over the combination — wrapping, recasing — pass a Proc instead of a string:

```ruby
error "Onboarding failed", join: ->(base, reason) { "#{base} (#{reason})" }
# => "Onboarding failed (Charge failed: card declined)"
```

The Proc receives `(base, reason)` — this level's base header and the already-resolved segment below it — and returns the combined string. It runs per-segment, so each level controls its own join. If the Proc raises or returns a non-String, the framework falls back to the default `": "` join. `success`/`done!` use the same mechanism.
````

- [ ] **Step 2: Update `CHANGELOG.md` (Unreleased section only)**

Line ~4 (aggregation entry): `Each segment uses its own `delimiter:`.` → `Each segment uses its own `join:`.`

Line ~31 (prefixing entry): replace `The join string is `delimiter:` on the base (default `": "`; `delimiter:` on a reason raises at declaration).` with:

```
The base↔reason combination is controlled by `join:` on the base — either a `String` separator (default `": "`) or a `->(base, reason) {}` Proc for full control such as wrapping or recasing (raise-safe: a Proc that raises or returns a non-String falls back to the default join); `join:` on a reason raises at declaration.
```

Line ~35 (internal entry): replace the two `delimiter:` mentions — `the same `prefixed:`/`delimiter:` validation` → `the same `prefixed:`/`join:` validation`, and `e.g. `delimiter:` on a conditional reason raises at declaration` → `e.g. `join:` on a conditional reason raises at declaration`.

- [ ] **Step 3: Verify no stale `delimiter` references remain in docs**

Run: `grep -rn "delimiter" docs/usage/writing.md CHANGELOG.md`
Expected: no message-related hits.

- [ ] **Step 4: Run the docs link checker if present, then the full suite**

Run: `bundle exec rspec`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add docs/usage/writing.md CHANGELOG.md
git commit -m "docs(messages): document join: (String|Proc), retire delimiter:

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- `join:` String|Proc API → Tasks 1 (String) + 2 (Proc). ✓
- Single join site / success parity → Task 1 routes `with_base_prefix` through `combine`; Task 2 success test. ✓
- Per-segment aggregation → Task 1 ported per-segment test + Task 2 mixed-join test. ✓
- Base-only placement rule → Task 1 validation specs + Task 2 Proc-on-reason spec. ✓
- Raise-safety → Task 3. ✓
- No migration / `delimiter:` removed cleanly → Task 1 (no `REMOVED_OPTION_MESSAGES` entry; `delimiter:` falls through to the generic unknown-option error). ✓
- Docs + CHANGELOG (no `[BREAKING]`) → Task 4. ✓
- Casing in user Proc, no sugar → Task 2 recasing test; no flag added. ✓

**Placeholder scan:** none — every code/step shows actual content.

**Type consistency:** `join` reader and `join:` kwarg used consistently across descriptor, DSL, resolver; `combine(base, reason)` and `apply_join_proc(proc, base, reason)` signatures match between Tasks 1–3; `DEFAULT_JOIN` introduced in Task 1 and reused in Tasks 2–3.
