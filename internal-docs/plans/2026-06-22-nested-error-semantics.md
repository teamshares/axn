# Clearer Nested Error Semantics — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `Axn::Failure` mean exactly "this action called `fail!`" everywhere (nested or not), and add a predictable, self-describing error-prefix feature so a declared base `error` contextualizes the action's failure reasons.

**Architecture:** Three phases that keep the test suite green throughout. **Phase A** (additive) adds base-`error` prefixing — `prefixed:` (default `true` for conditional/dynamic reasons, gated by a declared base) and `delimiter:` (default `": "`) — plus `success`/`done!` parity, while the old `error from:`/per-message `prefix:`/nested-`call!`-wrapping machinery still works. **Phase B** migrates the only internal consumers (`step`, `use :model`) onto the new mechanism. **Phase C** removes the now-unused old machinery (`error from:`, per-message `prefix:`, nested wrapping, `Axn::Failure#source`, the `result.rb` cause-hack) and simplifies the resolver.

**Tech Stack:** Ruby, RSpec, the Axn gem. Tests use `Axn::Testing::SpecHelpers#build_axn { ... }` and run with `bundle exec rspec`.

## Global Constraints

- **Works outside Rails.** No hard dependency on Rails — guard every Rails/ActiveRecord reference with `defined?(...)`. `spec/` runs without Rails; `spec_rails/dummy_app/` is the Rails app. Rails-adjacent changes (the `use :model` task) are tested in **both**.
- **TDD.** Failing test first, then implementation. Run `bundle exec rspec` after each implementation step.
- **CHANGELOG every user-visible change** under `## Unreleased`, tagged `[FEAT]`/`[BREAKING]`/`[BUGFIX]`/`[INTERNAL]`.
- **Fail at declaration, not runtime** for DSL misuse — `raise` with a message saying how to fix it.
- **Reuse the seams** — the `_messages_registry`, `MessageDescriptor`, `MessageResolver`, `Invoker`. No parallel paths.
- Design doc: `internal-docs/specs/2026-06-22-nested-error-semantics-design.md`.

---

## File Structure

| File | Responsibility | Phase |
|---|---|---|
| `lib/axn/core/flow/messages.rb` | `error`/`success` DSL; `_add_message` accepts `prefixed:`/`delimiter:`, defaults & validation | A (add), C (remove `prefix:`/`from:` validation) |
| `lib/axn/core/flow/handlers/descriptors/message_descriptor.rb` | Stores `prefixed?`/`delimiter`; (C) drops `prefix`/`from` matcher | A, C |
| `lib/axn/core/flow/handlers/resolvers/message_resolver.rb` | Identifies the base; prefixes `prefixed` reasons; `default_*` returns base | A, C |
| `lib/axn/exceptions.rb` | `Axn::Failure` carries `prefixed`; (C) drops `source` | A, C |
| `lib/axn/core.rb` | `fail!`/`done!` accept `prefixed:`; (C) `call!` drops nested wrapping | A, C |
| `lib/axn/internal/early_completion` (in `exceptions.rb`) | `EarlyCompletion` carries `prefixed` | A |
| `lib/axn/context.rb` | `__record_early_completion(message, prefixed:)` | A |
| `lib/axn/executor.rb` | passes `e.prefixed` through to `__record_early_completion` | A |
| `lib/axn/result.rb` | `error`/`success` apply base prefix to `fail!`/`done!` messages; (C) drop cause-hack | A, C |
| `lib/axn/mountable/mounting_strategies/step.rb` | rewrite to `call` + `fail!` | B |
| `lib/axn/strategies/model.rb` | drop `error_prefix:`; validation body `prefixed: true` | B |
| `spec/axn/core/messages_prefix_spec.rb` | NEW — all prefixing behavior | A |
| `spec/axn/core/messages_from_filter_spec.rb` | DELETE | C |

**Note on rollout:** os-app migration (the `error from:` / `prefix:` sites + Zendesk `rescue` cleanup) happens in the os-app repo during version bump, per the spec's rollout section. It is **not** a task in this gem-only plan.

---

# PHASE A — Additive prefixing feature

### Task A1: `prefixed:` / `delimiter:` DSL acceptance + declaration validation

**Files:**
- Modify: `lib/axn/core/flow/messages.rb:23-44`
- Modify: `lib/axn/core/flow/handlers/descriptors/message_descriptor.rb:11-25`
- Test: `spec/axn/core/messages_prefix_spec.rb` (new)

**Interfaces:**
- Produces: `MessageDescriptor#prefixed?` → Boolean, `MessageDescriptor#delimiter` → String|nil.
- Produces: `error`/`success` accept `prefixed: true|false` and `delimiter: String`.
- Validation rules (raise `ArgumentError` at declaration):
  - `prefixed: true` requires a condition (`if:`/`unless:`) **or** a dynamic message (block/Symbol/callable).
  - `delimiter:` only on a base message (no `if:`/`unless:`, not prefixed, static handler).

- [ ] **Step 1: Write the failing tests**

```ruby
# spec/axn/core/messages_prefix_spec.rb
# frozen_string_literal: true

RSpec.describe "Axn error_prefix DSL" do
  describe "declaration validation" do
    it "raises when prefixed: true on a static unconditional error" do
      expect {
        build_axn { error "Headline", prefixed: true }
      }.to raise_error(ArgumentError, /prefixed: true requires a condition .* or a dynamic message/)
    end

    it "allows prefixed: true with a condition" do
      expect {
        build_axn { error "boom", if: ArgumentError, prefixed: true }
      }.not_to raise_error
    end

    it "allows prefixed: true with a dynamic (block) message and no condition" do
      expect {
        build_axn { error(prefixed: true, &:message) }
      }.not_to raise_error
    end

    it "raises when delimiter: is given on a conditional reason" do
      expect {
        build_axn { error "x", if: ArgumentError, delimiter: " - " }
      }.to raise_error(ArgumentError, /delimiter: only applies to a base error/)
    end

    it "allows delimiter: on a base error" do
      expect {
        build_axn { error "Headline", delimiter: " - " }
      }.not_to raise_error
    end
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bundle exec rspec spec/axn/core/messages_prefix_spec.rb -e "declaration validation"`
Expected: FAIL (kwargs not accepted / no validation).

- [ ] **Step 3: Add `prefixed`/`delimiter` to `MessageDescriptor`**

```ruby
# lib/axn/core/flow/handlers/descriptors/message_descriptor.rb
class MessageDescriptor < BaseDescriptor
  attr_reader :prefix, :delimiter

  def initialize(matcher:, handler:, prefix: nil, prefixed: false, delimiter: nil)
    @prefix = prefix
    @prefixed = prefixed
    @delimiter = delimiter
    super(matcher:, handler:)
  end

  def prefixed? = @prefixed

  def self.build(handler: nil, if: nil, unless: nil, prefix: nil, prefixed: false, delimiter: nil, from: nil, **)
    new(
      handler:,
      prefix:,
      prefixed:,
      delimiter:,
      matcher: _build_matcher(if:, unless:, from:),
    )
  end
  # ... _build_matcher / _build_rule_for_from_condition unchanged (removed in Phase C)
end
```

- [ ] **Step 4: Add defaults + validation in `_add_message`**

```ruby
# lib/axn/core/flow/messages.rb  (replace _add_message)
def _add_message(kind, message:, prefixed: nil, delimiter: nil, **kwargs, &block)
  raise Axn::UnsupportedArgument, "calling #{kind} with both :if and :unless" if kwargs.key?(:if) && kwargs.key?(:unless)
  raise Axn::UnsupportedArgument, "Combining from: with if: or unless:" if kwargs.key?(:from) && (kwargs.key?(:if) || kwargs.key?(:unless))
  raise ArgumentError, "Provide either a message or a block, not both" if message && block_given?
  raise ArgumentError, "Provide a message, block, or prefix" unless message || block_given? || kwargs[:prefix] || kwargs[:from]
  raise ArgumentError, "from: only applies to error messages" if kwargs.key?(:from) && kind != :error

  conditional = kwargs.key?(:if) || kwargs.key?(:unless) || kwargs.key?(:from)
  dynamic     = block_given? || message.is_a?(Symbol) || message.respond_to?(:call)
  reason      = conditional || dynamic # only "reasons" (not the base headline) may be prefixed

  effective_prefixed = prefixed.nil? ? reason : prefixed
  raise ArgumentError, "prefixed: true requires a condition (if:/unless:) or a dynamic message" if effective_prefixed && !reason
  raise ArgumentError, "delimiter: only applies to a base error message" if delimiter && reason

  entry = if message.is_a?(Axn::Core::Flow::Handlers::Descriptors::MessageDescriptor)
            raise ArgumentError, "Cannot pass additional configuration with prebuilt descriptor" if kwargs.any? || block_given? || !prefixed.nil? || delimiter
            message
          else
            Axn::Core::Flow::Handlers::Descriptors::MessageDescriptor.build(
              handler: block_given? ? block : message,
              prefixed: effective_prefixed,
              delimiter:,
              **kwargs,
            )
          end

  self._messages_registry = _messages_registry.register(event_type: kind, entry:)
  true
end
```

- [ ] **Step 5: Run to verify pass**

Run: `bundle exec rspec spec/axn/core/messages_prefix_spec.rb -e "declaration validation"`
Expected: PASS. Then `bundle exec rspec` — full suite still green (descriptor gained optional kwargs; nothing else changed yet).

- [ ] **Step 6: Commit**

```bash
git add lib/axn/core/flow/messages.rb lib/axn/core/flow/handlers/descriptors/message_descriptor.rb spec/axn/core/messages_prefix_spec.rb
git commit -m "PRO-2746 Accept + validate prefixed:/delimiter: on message DSL

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task A2: Base-prefix resolution for declared reasons

**Files:**
- Modify: `lib/axn/core/flow/handlers/resolvers/message_resolver.rb`
- Test: `spec/axn/core/messages_prefix_spec.rb`

**Interfaces:**
- Consumes: `MessageDescriptor#prefixed?`, `#delimiter` (Task A1).
- Produces: `MessageResolver#resolve_message` prefixes a matched `prefixed` reason with the base; `#base_message` → String|nil; `#with_base_prefix(reason)` → String (used by Task A3); `#resolve_default_message` returns base.
- Behavior: base = the unconditional, non-`prefixed`, static-handler error descriptor (last-defined wins via registry order). No base → reasons render standalone.

- [ ] **Step 1: Write the failing tests**

```ruby
# spec/axn/core/messages_prefix_spec.rb  (add)
RSpec.describe "Axn error_prefix resolution" do
  subject(:error) { action.call.error }

  context "declared reason with a base (prefixed by default)" do
    let(:action) do
      build_axn do
        error "Couldn't sync user"
        error "is invalid", if: ArgumentError
        def call = raise ArgumentError, "boom"
      end
    end
    it { is_expected.to eq("Couldn't sync user: is invalid") }
  end

  context "reason opted out with prefixed: false" do
    let(:action) do
      build_axn do
        error "Couldn't sync user"
        error "Vendor not found", if: ArgumentError, prefixed: false
        def call = raise ArgumentError, "boom"
      end
    end
    it { is_expected.to eq("Vendor not found") }
  end

  context "no base declared (gate closed)" do
    let(:action) do
      build_axn do
        error "is invalid", if: ArgumentError
        def call = raise ArgumentError, "boom"
      end
    end
    it { is_expected.to eq("is invalid") }
  end

  context "custom delimiter on the base" do
    let(:action) do
      build_axn do
        error "Couldn't sync user", delimiter: " — "
        error "is invalid", if: ArgumentError
        def call = raise ArgumentError, "boom"
      end
    end
    it { is_expected.to eq("Couldn't sync user — is invalid") }
  end

  context "unconditional dynamic detail with a base" do
    let(:action) do
      build_axn do
        error "Couldn't sync user"
        error(prefixed: true, &:message)
        def call = raise ArgumentError, "boom"
      end
    end
    it { is_expected.to eq("Couldn't sync user: boom") }
  end

  context "no reason matches → base shown alone" do
    let(:action) do
      build_axn do
        error "Couldn't sync user"
        error "is invalid", if: TypeError
        def call = raise ArgumentError, "boom"
      end
    end
    it { is_expected.to eq("Couldn't sync user") }
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bundle exec rspec spec/axn/core/messages_prefix_spec.rb -e "resolution"`
Expected: FAIL (no base-prefix logic; e.g. first case returns "is invalid").

- [ ] **Step 3: Implement base-prefix resolution**

```ruby
# lib/axn/core/flow/handlers/resolvers/message_resolver.rb  (replace body)
class MessageResolver < BaseResolver
  DEFAULT_ERROR = "Something went wrong"
  DEFAULT_SUCCESS = "Action completed successfully"

  def resolve_message
    descriptor = matching_entries.detect { |d| !base?(d) && body_for(d).present? }
    return base_message || fallback_message unless descriptor

    reason = body_for(descriptor)
    descriptor.prefixed? ? with_base_prefix(reason) : reason
  end

  def resolve_default_message = base_message || fallback_message

  # Prefix an externally-supplied reason (e.g. a fail!/done! message) with the base.
  def with_base_prefix(reason)
    return reason unless base_message.present?

    "#{base_message}#{delimiter}#{reason}"
  end

  def base_message
    return @base_message if defined?(@base_message)

    @base_message = base_descriptor ? body_for(base_descriptor) : nil
  end

  private

  def base_descriptor
    return @base_descriptor if defined?(@base_descriptor)

    @base_descriptor = candidate_entries.detect { |d| d.static? && !d.prefixed? && d.handler }
  end

  def base?(descriptor) = base_descriptor && descriptor.equal?(base_descriptor)

  def delimiter = base_descriptor&.delimiter.presence || ": "

  def body_for(descriptor)
    return nil unless descriptor

    raw =
      if descriptor.handler
        Invoker.call(operation: "determining message callable", action:, handler: descriptor.handler, exception:).presence
      elsif exception
        exception.message
      end
    return nil unless raw.present?

    # Per-message prefix:, retained for Phase A coexistence; removed in Phase C.
    "#{resolved_prefix(descriptor)}#{raw}"
  end

  def resolved_prefix(descriptor)
    return nil unless descriptor.prefix
    return descriptor.prefix if descriptor.prefix.is_a?(String)

    Invoker.call(action:, handler: descriptor.prefix, exception:, operation: "determining prefix callable")
  rescue StandardError
    nil
  end

  def fallback_message = event_type == :success ? DEFAULT_SUCCESS : DEFAULT_ERROR
end
```

- [ ] **Step 4: Run to verify pass**

Run: `bundle exec rspec spec/axn/core/messages_prefix_spec.rb -e "resolution"`
Expected: PASS. Then `bundle exec rspec spec/axn/core/messages_spec.rb` — existing message behavior still green (static error/success, conditionals, fallback unchanged; `prefixed` defaults false on static-string messages, so base-only actions are unaffected).

- [ ] **Step 5: Run full suite**

Run: `bundle exec rspec`
Expected: PASS. (`messages_from_filter_spec.rb` still green — `from:` matcher + per-message `prefix:` retained for now.)

- [ ] **Step 6: Commit**

```bash
git add lib/axn/core/flow/handlers/resolvers/message_resolver.rb spec/axn/core/messages_prefix_spec.rb
git commit -m "PRO-2746 Prefix declared reasons with the base error message

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task A3: `fail!` prefixing + `prefixed:` opt-out

**Files:**
- Modify: `lib/axn/exceptions.rb:9-28`
- Modify: `lib/axn/core.rb:73-76`
- Modify: `lib/axn/result.rb:50-54,132-138`
- Test: `spec/axn/core/messages_prefix_spec.rb`

**Interfaces:**
- Consumes: `MessageResolver#with_base_prefix` (Task A2).
- Produces: `Axn::Failure#prefixed?` → Boolean (default `true`); `fail!(message = nil, prefixed: nil, **exposures)`.

- [ ] **Step 1: Write the failing tests**

```ruby
# spec/axn/core/messages_prefix_spec.rb  (add)
RSpec.describe "Axn error_prefix on fail!" do
  subject(:error) { action.call.error }

  context "fail! prefixed by the base by default" do
    let(:action) do
      build_axn do
        error "Couldn't sync user"
        def call = fail!("email taken")
      end
    end
    it { is_expected.to eq("Couldn't sync user: email taken") }
  end

  context "fail! opting out with prefixed: false" do
    let(:action) do
      build_axn do
        error "Couldn't sync user"
        def call = fail!("Account is locked.", prefixed: false)
      end
    end
    it { is_expected.to eq("Account is locked.") }
  end

  context "fail! with no base declared" do
    let(:action) do
      build_axn { def call = fail!("email taken") }
    end
    it { is_expected.to eq("email taken") }
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bundle exec rspec spec/axn/core/messages_prefix_spec.rb -e "on fail!"`
Expected: FAIL (first case returns "email taken").

- [ ] **Step 3: Carry `prefixed` on `Axn::Failure`**

```ruby
# lib/axn/exceptions.rb
class Failure < StandardError
  DEFAULT_MESSAGE = "Execution was halted"

  attr_reader :source # removed in Phase C

  def initialize(message = nil, source: nil, prefixed: true)
    @source = source
    @message = message
    @prefixed = prefixed
    super(message)
  end

  def prefixed? = @prefixed
  def message = @message.presence || DEFAULT_MESSAGE
  def default_message? = message == DEFAULT_MESSAGE
  def inspect = "#<#{self.class.name} '#{message}'>"
end
```

- [ ] **Step 4: `fail!` accepts `prefixed:`**

```ruby
# lib/axn/core.rb
def fail!(message = nil, prefixed: nil, **exposures)
  expose(**exposures) if exposures.any?
  raise Axn::Failure.new(message, prefixed: prefixed.nil? ? true : prefixed)
end
```

- [ ] **Step 5: Apply base prefix to the `fail!` message in `result.error`**

```ruby
# lib/axn/result.rb
def error
  return if ok?

  reason = _user_provided_error_message
  return _msg_resolver(:error, exception:).resolve_message unless reason

  _fail_prefixed? ? _msg_resolver(:error, exception:).with_base_prefix(reason) : reason
end

# ... keep _user_provided_error_message as-is for now (cause-hack removed in Phase C)

def _fail_prefixed?
  exception.is_a?(Axn::Failure) ? exception.prefixed? : true
end
```

- [ ] **Step 6: Run to verify pass + full suite**

Run: `bundle exec rspec spec/axn/core/messages_prefix_spec.rb && bundle exec rspec`
Expected: PASS. (Actions without a declared base error are unchanged — `with_base_prefix` returns the reason untouched.)

- [ ] **Step 7: Commit**

```bash
git add lib/axn/exceptions.rb lib/axn/core.rb lib/axn/result.rb spec/axn/core/messages_prefix_spec.rb
git commit -m "PRO-2746 Prefix fail! messages with the base error (prefixed: false opts out)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task A4: `success` / `done!` parity

**Files:**
- Modify: `lib/axn/exceptions.rb` (`EarlyCompletion`)
- Modify: `lib/axn/core.rb:78-81` (`done!`)
- Modify: `lib/axn/context.rb:40-46`
- Modify: `lib/axn/executor.rb:253,426`
- Modify: `lib/axn/result.rb:56-60,128-130`
- Test: `spec/axn/core/messages_prefix_spec.rb`

**Interfaces:**
- Produces: `EarlyCompletion#prefixed?`; `done!(message = nil, prefixed: nil, **exposures)`; `Context#__record_early_completion(message, prefixed:)`.

- [ ] **Step 1: Write the failing tests**

```ruby
# spec/axn/core/messages_prefix_spec.rb  (add)
RSpec.describe "Axn success prefixing parity" do
  subject(:success) { action.call.success }

  context "done! prefixed by base success" do
    let(:action) do
      build_axn do
        success "User synced"
        def call = done!("from cache")
      end
    end
    it { is_expected.to eq("User synced: from cache") }
  end

  context "done! opting out" do
    let(:action) do
      build_axn do
        success "User synced"
        def call = done!("Already current.", prefixed: false)
      end
    end
    it { is_expected.to eq("Already current.") }
  end

  context "conditional success reason prefixed" do
    let(:action) do
      build_axn do
        expects :n, type: Integer
        success "Computed"
        success "via fast path", if: -> { n.zero? }
        def call = nil
      end
    end
    it { expect(action.call(n: 0).success).to eq("Computed: via fast path") }
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bundle exec rspec spec/axn/core/messages_prefix_spec.rb -e "success prefixing parity"`
Expected: FAIL (`done!` does not accept `prefixed:` / no success prefixing).

- [ ] **Step 3: `EarlyCompletion` carries `prefixed`**

```ruby
# lib/axn/exceptions.rb
module Internal
  class EarlyCompletion < StandardError
    attr_reader :prefixed

    def initialize(message = nil, prefixed: true)
      @prefixed = prefixed
      super(message)
    end
  end
end
```

- [ ] **Step 4: `done!` + context + executor wiring**

```ruby
# lib/axn/core.rb
def done!(message = nil, prefixed: nil, **exposures)
  expose(**exposures) if exposures.any?
  raise Axn::Internal::EarlyCompletion.new(message, prefixed: prefixed.nil? ? true : prefixed)
end
```

```ruby
# lib/axn/context.rb
def __record_early_completion(message, prefixed: true)
  unless message == Axn::Internal::EarlyCompletion.new.message
    @early_completion_message = message
    @early_completion_prefixed = prefixed
  end
  @early_completion = true
  @finalized = true
end

def __early_completion_message = @early_completion_message.presence
def __early_completion_prefixed = @early_completion_prefixed.nil? ? true : @early_completion_prefixed
```

```ruby
# lib/axn/executor.rb  (both rescue sites — lines ~253 and ~426)
rescue Internal::EarlyCompletion => e
  @context.__record_early_completion(e.message, prefixed: e.prefixed)
```

- [ ] **Step 5: Apply base prefix to the success message**

```ruby
# lib/axn/result.rb
def success
  return unless ok?

  reason = _user_provided_success_message
  return _msg_resolver(:success, exception: nil).resolve_message unless reason

  @context.__early_completion_prefixed ? _msg_resolver(:success, exception: nil).with_base_prefix(reason) : reason
end
```

- [ ] **Step 6: Run to verify pass + full suite**

Run: `bundle exec rspec spec/axn/core/messages_prefix_spec.rb && bundle exec rspec`
Expected: PASS. (`done!` with no base success → reason alone, unchanged.)

- [ ] **Step 7: Commit**

```bash
git add lib/axn/exceptions.rb lib/axn/core.rb lib/axn/context.rb lib/axn/executor.rb lib/axn/result.rb spec/axn/core/messages_prefix_spec.rb
git commit -m "PRO-2746 success/done! prefixing parity

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task A5: CHANGELOG + docs for the additive feature

**Files:**
- Modify: `CHANGELOG.md` (under `## Unreleased`)
- Modify: docs for the messages DSL (search `docs/` for the messages/error page; if none, add a short section to the relevant existing messages doc)

- [ ] **Step 1: Add CHANGELOG entry**

```markdown
* [FEAT] A declared base `error "…"` now prefixes the action's specific failure *reasons* — conditional `error … if:`, dynamic `error` blocks, and `fail!` messages — rendered as `"<base><delimiter><reason>"`. Prefixing is on by default for reasons (`prefixed: true`) and **gated by a declared base** (no base ⇒ reasons render standalone, unchanged). Opt a single reason out with `prefixed: false` (on the declaration or on `fail!`). The join string is `delimiter:` on the base (default `": "`). `success`/`done!` mirror this. A static unconditional `error` is the base and is never itself prefixed (`prefixed: true` on it raises at declaration); `error(prefixed: true, &:message)` is the unconditional-dynamic detail form.
```

- [ ] **Step 2: Find + update the messages doc**

Run: `grep -rl "success\|error message" docs/ | head` — add a "Prefixing failure reasons" subsection with the `error "Headline"` + `prefixed:`/`delimiter:` examples mirroring the spec's Mental Model.

- [ ] **Step 3: Commit**

```bash
git add CHANGELOG.md docs/
git commit -m "PRO-2746 Document base-error prefixing

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

# PHASE B — Migrate internal consumers onto the new mechanism

### Task B1: Migrate `use :model` off per-message `prefix:`

**Files:**
- Modify: `lib/axn/strategies/model.rb:16,25,30,32,45,189-210`
- Test: `spec/axn/strategies/model_spec.rb` (+ `spec_rails/` model coverage)

**Interfaces:**
- Removes the `use :model, error_prefix:` kwarg (still `## Unreleased`). Validation body becomes `prefixed: true`; a user-declared base `error "…"` prefixes it.

- [ ] **Step 1: Update tests to the new behavior**

In `spec/axn/strategies/model_spec.rb`, replace any `use :model, error_prefix: "X: "` example with a base-error declaration, asserting the composed message:

```ruby
let(:action) do
  build_axn do
    use :model, create: Widget   # or the spec's existing model setup
    error "Couldn't save widget"
  end
end

it "prefixes the validation body with the declared base error" do
  result = action.call(params: { name: "" }) # triggers RecordInvalid
  expect(result).not_to be_ok
  expect(result.error).to eq("Couldn't save widget: Name can't be blank")
end

it "renders the validation body standalone when no base error is declared" do
  # action without `error "…"` → "Name can't be blank"
end
```
Remove the old `error_prefix:`-kwarg test(s).

- [ ] **Step 2: Run to verify they fail**

Run: `bundle exec rspec spec/axn/strategies/model_spec.rb`
Expected: FAIL (base not prefixing the body / `error_prefix:` still wired).

- [ ] **Step 3: Drop `error_prefix:` from the strategy, mark body `prefixed: true`**

```ruby
# lib/axn/strategies/model.rb — remove :error_prefix from delegated attrs (line 16),
# from the params signature (line 32) and the value object build (line 45), and the @param doc.

def self.install_messages!(base, _config)
  base.class_eval do
    define_method(:__axn_invalid_record) do |exception = nil|
      if exception.is_a?(ActiveRecord::RecordInvalid) && exception.record
        exception.record
      elsif instance_variable_defined?(:@__axn_model)
        @__axn_model
      end
    end
    private :__axn_invalid_record

    # Clean validation body, prefixed by the action's base error when one is declared.
    error(if: ->(exception: nil) { (rec = __axn_invalid_record(exception)) && rec.errors.any? }, prefixed: true) do |exception = nil|
      __axn_invalid_record(exception).errors.full_messages.to_sentence
    end

    success { "#{__axn_model.previously_new_record? ? 'Created' : 'Updated'} #{__axn_model.class.model_name.human}" }
    fails_on(ActiveRecord::RecordInvalid)
  end
end
```

- [ ] **Step 4: Run to verify pass**

Run: `bundle exec rspec spec/axn/strategies/model_spec.rb`
Expected: PASS. Then the Rails dummy-app model coverage: `bundle exec rspec spec_rails` (or the targeted model spec there).
Expected: PASS.

- [ ] **Step 5: Update CHANGELOG `use :model` entry**

In the `## Unreleased` `use :model` `[FEAT]` line, replace the `error_prefix:` clause with: "declare a base `error \"…\"` after `use :model` to prefix the validation body."

- [ ] **Step 6: Commit**

```bash
git add lib/axn/strategies/model.rb spec/axn/strategies/model_spec.rb spec_rails CHANGELOG.md
git commit -m "PRO-2746 Migrate use :model off per-message prefix: to base-error prefixing

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task B2: Migrate `step` off `error from:` to `call` + `fail!`

**Files:**
- Modify: `lib/axn/mountable/mounting_strategies/step.rb:40-72`
- Test: `spec/axn/mountable/steps/steps_spec.rb`

**Interfaces:**
- Keeps `step … error_prefix:` (default `"#{descriptor.name}: "`). The generated `#call` runs each child via non-bang `call` and `fail!("#{error_prefix}#{result.error}")` on failure (default `prefixed: true` ⇒ parent base cascades if declared).

- [ ] **Step 1: Add a cascade test (and confirm existing behavior)**

```ruby
# spec/axn/mountable/steps/steps_spec.rb  (add)
it "cascades the parent's base error into a step failure when declared" do
  failing = build_axn { error "Step boom"; def call = fail!("nope") }
  parent = build_axn do
    error "Onboarding failed"
    step "validate", failing
  end
  result = parent.call
  expect(result).not_to be_ok
  expect(result.error).to eq("Onboarding failed: validate: Step boom: nope")
end

it "renders step failures flat when no parent base error is declared" do
  failing = build_axn { def call = fail!("nope") }
  parent = build_axn { step "validate", failing }
  expect(parent.call.error).to eq("validate: nope")
end
```
Keep the existing `error_prefix:` default/override tests (lines 78-95) — they must still pass.

- [ ] **Step 2: Run to verify the cascade test fails**

Run: `bundle exec rspec spec/axn/mountable/steps/steps_spec.rb`
Expected: the new cascade test FAILS (current impl uses `error from:` + `call!`, no cascade); the rest still pass.

- [ ] **Step 3: Rewrite `mount_to_target`**

```ruby
# lib/axn/mountable/mounting_strategies/step.rb
def mount_to_target(descriptor:, target:)
  # Only define #call once; each step reads its own descriptor at runtime.
  return if target.instance_variable_defined?(:@_axn_call_method_defined_for_steps)

  target.define_method(:call) do
    step_descriptors = self.class._mounted_axn_descriptors.select { |d| d.mount_strategy.key == :step }

    step_descriptors.each do |step_descriptor|
      axn = step_descriptor.mounted_axn_for(target: self.class)
      error_prefix = step_descriptor.options[:error_prefix] || "#{step_descriptor.name}: "

      step_result = axn.call(**@__context.__combined_data)
      fail!("#{error_prefix}#{step_result.error}") unless step_result.ok?

      step_result.declared_fields.each do |field|
        @__context.exposed_data[field] = step_result.public_send(field)
      end
    end
  end
  target.instance_variable_set(:@_axn_call_method_defined_for_steps, true)
end
```
Note: the `target.error from: axn_klass do … end` declaration is **removed** — the prefix now lives in the `fail!`. `strategy_specific_kwargs` keeps `:error_prefix`.

- [ ] **Step 4: Run to verify pass + full suite**

Run: `bundle exec rspec spec/axn/mountable/steps/steps_spec.rb && bundle exec rspec`
Expected: PASS. (Step no longer depends on `error from:` or nested wrapping.)

- [ ] **Step 5: CHANGELOG**

```markdown
* [INTERNAL] `step` no longer uses `error from:` / the nested `call!` wrapping; it runs each child via `call` and `fail!`s with the step's `error_prefix:` (default `"<name>: "`). A parent orchestrator that declares a base `error` now has it cascade into step failures.
```

- [ ] **Step 6: Commit**

```bash
git add lib/axn/mountable/mounting_strategies/step.rb spec/axn/mountable/steps/steps_spec.rb CHANGELOG.md
git commit -m "PRO-2746 Rewrite step off error from: to call + fail!

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

# PHASE C — Remove the old machinery

### Task C1: Remove nested `call!` wrapping, `Axn::Failure#source`, cause-hack

**Files:**
- Modify: `lib/axn/core.rb:36-45`
- Modify: `lib/axn/exceptions.rb` (drop `source`)
- Modify: `lib/axn/result.rb:132-138` (drop cause-hack)
- Test: `spec/axn/core/callbang_spec.rb` (or wherever `call!` nesting is tested) + `spec/axn/core/messages_prefix_spec.rb`

**Interfaces:**
- `call!` re-raises `result.exception` (no nesting branch). `Axn::Failure.new(message, prefixed: true)` (no `source:`).

- [ ] **Step 1: Write/adjust tests for parity + the explicit idiom**

```ruby
# spec/axn/core/messages_prefix_spec.rb  (add)
RSpec.describe "Nested call! parity" do
  it "re-raises the inner's original exception (no wrapping, no source)" do
    inner = build_axn { def call = raise ArgumentError, "boom" }
    outer = build_axn(inner: inner) do
      expects :inner
      def call = inner.call!
    end
    expect { outer.call!(inner: inner) }.to raise_error(ArgumentError, "boom")
  end

  it "composes a child's error via the explicit call + fail! idiom" do
    inner = build_axn { error "Charge failed"; def call = fail!("card declined") }
    outer = build_axn(inner: inner) do
      expects :inner
      error "Onboarding failed"
      def call
        r = inner.call
        fail!("charging: #{r.error}") unless r.ok?
      end
    end
    expect(outer.call(inner: inner).error).to eq("Onboarding failed: charging: Charge failed: card declined")
  end
end
```
Audit `spec/axn/core/callbang_spec.rb` for any assertion that a nested `call!` raises a wrapped `Axn::Failure` / inspects `.source` / `.cause`; update those to expect the original exception.

- [ ] **Step 2: Run to verify they fail**

Run: `bundle exec rspec spec/axn/core/messages_prefix_spec.rb -e "Nested call! parity"`
Expected: FAIL (currently raises a wrapped `Axn::Failure`, not `ArgumentError`).

- [ ] **Step 3: Remove the wrapping + source + cause-hack**

```ruby
# lib/axn/core.rb
def call!(**)
  result = call(**)
  return result if result.ok?

  raise result.exception
end
```

```ruby
# lib/axn/exceptions.rb — drop `attr_reader :source` and the `source:` param
class Failure < StandardError
  DEFAULT_MESSAGE = "Execution was halted"

  def initialize(message = nil, prefixed: true)
    @message = message
    @prefixed = prefixed
    super(message)
  end

  def prefixed? = @prefixed
  def message = @message.presence || DEFAULT_MESSAGE
  def default_message? = message == DEFAULT_MESSAGE
  def inspect = "#<#{self.class.name} '#{message}'>"
end
```

```ruby
# lib/axn/result.rb — drop the cause-hack line
def _user_provided_error_message
  return unless exception.is_a?(Axn::Failure)
  return if exception.default_message?

  exception.message.presence
end
```

- [ ] **Step 4: Run to verify pass + full suite**

Run: `bundle exec rspec`
Expected: PASS. If any spec still references `Axn::Failure#source`, remove/fix it (it should only be the from-filter spec, deleted in C2).

- [ ] **Step 5: CHANGELOG**

```markdown
* [BREAKING] A nested `call!` failure now re-raises the inner action's original exception, identical to a top-level `call!` (previously: a fresh `Axn::Failure` wrapping the inner's `result.error` with a `source:` pointer and `cause:`). `Axn::Failure` now means exactly "`fail!` was called" everywhere. `Axn::Failure#source` is removed. To reshape a child's error with context, run the child with non-bang `call` and `fail!("context: #{result.error}") unless result.ok?`.
```

- [ ] **Step 6: Commit**

```bash
git add lib/axn/core.rb lib/axn/exceptions.rb lib/axn/result.rb spec/axn/core CHANGELOG.md
git commit -m "PRO-2746 Remove nested call! wrapping + Axn::Failure#source

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task C2: Remove `error from:` and per-message `prefix:`

**Files:**
- Modify: `lib/axn/core/flow/messages.rb` (drop `from:`/`prefix:` validation)
- Modify: `lib/axn/core/flow/handlers/descriptors/message_descriptor.rb` (drop `from:` matcher + `prefix`)
- Modify: `lib/axn/core/flow/handlers/resolvers/message_resolver.rb` (drop `resolved_prefix`)
- Delete: `spec/axn/core/messages_from_filter_spec.rb`

**Interfaces:**
- `error`/`success` no longer accept `from:` or `prefix:` (passing them raises the generic "unknown keyword" or an explicit guard — see Step 3).

- [ ] **Step 1: Delete the from-filter spec + add a guard test**

```bash
git rm spec/axn/core/messages_from_filter_spec.rb
```
```ruby
# spec/axn/core/messages_prefix_spec.rb  (add)
RSpec.describe "removed error options" do
  it "rejects from:" do
    expect { build_axn { error "x", from: Object } }.to raise_error(ArgumentError, /from: is no longer supported/)
  end
  it "rejects per-message prefix:" do
    expect { build_axn { error "x", prefix: "P: " } }.to raise_error(ArgumentError, /prefix: is no longer supported/)
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bundle exec rspec spec/axn/core/messages_prefix_spec.rb -e "removed error options"`
Expected: FAIL (no guard yet).

- [ ] **Step 3: Drop `from:`/`prefix:` from the DSL with actionable guards**

```ruby
# lib/axn/core/flow/messages.rb — in _add_message, replace the from:/prefix-related lines:
raise ArgumentError, "from: is no longer supported — run the child with `call` and `fail!(\"context: #{'#'}{result.error}\") unless result.ok?`" if kwargs.key?(:from)
raise ArgumentError, "prefix: is no longer supported — declare a base `error \"…\"` (prefixes reasons by default; opt out with prefixed: false)" if kwargs.key?(:prefix)
# remove the old `unless message || block || prefix || from` clause's prefix/from terms:
raise ArgumentError, "Provide a message or a block" unless message || block_given?
```

```ruby
# lib/axn/core/flow/handlers/descriptors/message_descriptor.rb — drop prefix + from:
class MessageDescriptor < BaseDescriptor
  attr_reader :delimiter

  def initialize(matcher:, handler:, prefixed: false, delimiter: nil)
    @prefixed = prefixed
    @delimiter = delimiter
    super(matcher:, handler:)
  end

  def prefixed? = @prefixed

  def self.build(handler: nil, if: nil, unless: nil, prefixed: false, delimiter: nil, **)
    new(handler:, prefixed:, delimiter:, matcher: Matcher.build(if:, unless:))
  end
end
# delete _build_matcher + _build_rule_for_from_condition (Matcher.build covers if:/unless:)
```

```ruby
# lib/axn/core/flow/handlers/resolvers/message_resolver.rb — drop resolved_prefix; simplify body_for:
def body_for(descriptor)
  return nil unless descriptor

  if descriptor.handler
    Invoker.call(operation: "determining message callable", action:, handler: descriptor.handler, exception:).presence
  elsif exception
    exception.message.presence
  end
end
# remove the resolved_prefix method entirely
```

- [ ] **Step 4: Run to verify pass + full suite**

Run: `bundle exec rspec`
Expected: PASS. (The from-filter spec is gone; no internal consumer uses `from:`/`prefix:` after Phase B.)

- [ ] **Step 5: CHANGELOG**

```markdown
* [BREAKING] Removed `error from:` and the per-message `prefix:` option on `error`/`success`. Use a declared base `error "…"` (prefixes failure reasons by default — see the prefixing FEAT entry) and the explicit `call` + `fail!` idiom for cross-action message shaping. Passing `from:`/`prefix:` now raises at declaration with the migration hint.
```

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "PRO-2746 Remove error from: and per-message prefix:

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task C3: Document `fails_on` for the reporting case + final sweep

**Files:**
- Modify: docs (the exceptions/reporting page) + `CHANGELOG.md`

- [ ] **Step 1: Add a "Suppressing reports for expected failures" doc section**

Document: an expected error (e.g. `Faraday::BadRequestError` for "email already used") should be declared `fails_on Faraday::BadRequestError` on the **inner** action — it reclassifies into the failure bucket (fires `on_failure`, skips `Axn.config.on_exception`, preserves `result.exception`), so a handling outer never produces a spurious Honeybadger report. Contrast with `fail!` (always a failure, never reported) and unhandled exceptions (reported). Reference that nested `call!` now behaves identically to top-level.

- [ ] **Step 2: Grep for stale references**

Run: `grep -rn "from:\|\.source\|error_prefix" lib/ docs/ | grep -vi "enqueues_each\|from: ->\|step"`
Expected: no remaining `error from:` / `Axn::Failure#source` / `use :model` `error_prefix:` references. Fix any stragglers.

- [ ] **Step 3: Final full suite (both runners)**

Run: `bundle exec rspec && bundle exec rspec spec_rails && bundle exec rubocop`
Expected: all PASS/clean.

- [ ] **Step 4: Commit**

```bash
git add docs/ CHANGELOG.md
git commit -m "PRO-2746 Document fails_on for expected-failure reporting

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- Mental model / `prefixed:`/`delimiter:` → A1 (DSL+validation), A2 (resolution), A3 (`fail!`), A4 (success/`done!`). ✓
- `prefixed:` validity (static-unconditional raises; condition-or-dynamic) → A1. ✓
- Remove `error from:` / per-message `prefix:` → C2. ✓
- Remove nested `call!` wrapping / `Axn::Failure#source` / cause-hack → C1. ✓
- `fails_on` reporting (docs only) → C3. ✓
- Internal migration: `use :model` (remove `error_prefix:`) → B1; `step` (keep `error_prefix:`, rewrite, cascade) → B2. ✓
- Rollout ordering (additive → migrate → remove, green throughout) → Phases A/B/C. ✓
- CHANGELOG `[FEAT]`/`[BREAKING]`/`[INTERNAL]` → A5, B1, B2, C1, C2. ✓
- Open question "multiple unconditional `error` → last wins" → handled by registry order (`register` prepends; `detect` returns last-defined) in A2's `base_descriptor`. ✓

**Placeholder scan:** none — every code/test step shows actual code; doc steps name the exact grep/section.

**Type consistency:** `prefixed?` (Boolean) used consistently on `MessageDescriptor`, `Axn::Failure`, `EarlyCompletion`; `with_base_prefix(reason)`/`base_message`/`delimiter` consistent between A2 (definition) and A3/A4 (consumers); `__record_early_completion(message, prefixed:)` matches its A4 caller in `executor.rb`. ✓

**Note for the executor:** Phase A's `message_resolver.rb` deliberately retains `resolved_prefix`/per-message `prefix:` so the suite stays green while `from:`/`prefix:` still exist; C2 removes it. Don't delete it early.
