# Axn::Extensions namespace + best_effort + top-level shrink — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Promote the internal dev-loud/prod-quiet guard to a sanctioned block-form helper `Axn::Extensions.best_effort`, re-home the extension-config registry under `Axn::Extensions`, and relocate top-level runtime machinery (`Executor`, the context-facade family) under `Axn::Core`.

**Architecture:** New semi-public `Axn::Extensions` module holds `best_effort` (block sugar over the existing swallow-or-dev-raise logic) plus the re-homed `Extensions::Config`. `Axn::Internal::PipingError` is deleted after its ~21 call sites migrate to the block form. Machinery constants move under `Axn::Core`; genuinely-public constants (`Result`, `Failure`, `Factory`, `FormObject`, `Configuration`, exception classes, `Strategies`) stay top-level.

**Tech Stack:** Ruby, RSpec, ActiveSupport. Two suites: `spec/` (non-Rails) and `spec_rails/` (Rails dummy app).

## Global Constraints

- **Alpha, no back-compat.** Delete old names outright; no aliases, no deprecation shims.
- **Works outside Rails.** Guard any `Rails`/AR constant with `defined?()`. `spec/` runs without Rails; `spec_rails/dummy_app` runs the Rails path.
- **No manual line breaks in Markdown prose** — one line per paragraph (repo convention).
- **No historical comments** ("used to X / now Y", ticket labels). Comments describe current behavior + intrinsic why.
- **Behavior of the guard is unchanged:** log-in-prod/test, raise-in-dev only when the knob is set; return `nil` on rescue, block's value on success.
- **Config knob name:** `best_effort_raises_in_dev` (renamed from `raise_piping_errors_in_dev`).
- Run `bundle exec rspec` for `spec/`; run the Rails suite with `bundle exec rake spec_rails` (the canonical runner — it `chdir`s into `spec_rails/dummy_app` and runs `BUNDLE_GEMFILE=Gemfile bundle exec rspec spec/`). Do NOT run `rspec spec_rails` from the repo root — it fails to load Rails and is not the real suite.
- Frequent commits — one per task.

---

### Task 1: Introduce `Axn::Extensions.best_effort` + rename the knob

**Files:**
- Create: `lib/axn/extensions.rb`
- Create: `spec/axn/extensions_spec.rb`
- Modify: `lib/axn.rb` (add `require "axn/extensions"`)
- Modify: `lib/axn/core.rb:3` (the `require "axn/internal/piping_error"` stays for now)
- Modify: `lib/axn/configuration.rb:28` (rename setting)
- Modify: `lib/axn/internal/piping_error.rb` (make `.swallow` delegate)
- Modify: `lib/axn/async/batch_enqueue.rb:115` (comment mentions old knob)
- Modify: `docs/reference/configuration.md` (lines ~237, 243, 496), `docs/reference/async.md:459`
- Delete: `spec/axn/internal/piping_error_spec.rb`

**Interfaces:**
- Produces: `Axn::Extensions.best_effort(desc, action: nil, &block)` → runs block; on `StandardError` logs+swallows returning `nil`, except re-raises in dev when `Axn.config.best_effort_raises_in_dev`; returns the block's value on success.

- [ ] **Step 1: Write `spec/axn/extensions_spec.rb`** (port of the deleted piping spec, block form)

```ruby
# frozen_string_literal: true

RSpec.describe Axn::Extensions do
  describe ".best_effort" do
    let(:boom) { -> { raise StandardError, "fail message" } }
    let(:logger) { double(:logger) }

    before do
      allow(Axn).to receive_message_chain(:config, :logger).and_return(logger)
      allow(Axn).to receive_message_chain(:config, :best_effort_raises_in_dev).and_return(false)
      allow(logger).to receive(:warn)
      # backtrace shape for the "from" extraction
      allow_any_instance_of(StandardError).to receive(:backtrace).and_return(["/foo/bar/baz.rb:42:in `block'"])
    end

    it "returns the block's value on success" do
      allow(Axn).to receive_message_chain(:config, :env, :production?).and_return(true)
      expect(described_class.best_effort("foo") { 7 }).to eq(7)
    end

    context "in production" do
      before { allow(Axn).to receive_message_chain(:config, :env, :production?).and_return(true) }

      it "logs a concise warning and returns nil" do
        expect(logger).to receive(:warn).with(/Ignoring exception raised while foo/)
        expect(described_class.best_effort("foo", &boom)).to be_nil
      end
    end

    context "in non-production" do
      before { allow(Axn).to receive_message_chain(:config, :env, :production?).and_return(false) }

      it "logs a verbose warning and returns nil" do
        expect(logger).to receive(:warn).with(/IGNORING EXCEPTION RAISED WHILE FOO/)
        expect(described_class.best_effort("foo", &boom)).to be_nil
      end
    end

    context "with a custom action warn-target" do
      let(:action) { double(:action) }

      it "warns on the action instead of the config logger" do
        allow(Axn).to receive_message_chain(:config, :env, :production?).and_return(true)
        expect(action).to receive(:warn).with(/Ignoring exception raised while foo/)
        described_class.best_effort("foo", action:, &boom)
      end
    end

    context "with best_effort_raises_in_dev enabled" do
      before { allow(Axn).to receive_message_chain(:config, :best_effort_raises_in_dev).and_return(true) }

      it "re-raises in development" do
        allow(Axn).to receive_message_chain(:config, :env, :development?).and_return(true)
        allow(Axn).to receive_message_chain(:config, :env, :production?).and_return(false)
        expect(logger).not_to receive(:warn)
        expect { described_class.best_effort("foo", &boom) }.to raise_error(StandardError, "fail message")
      end

      it "logs (does not raise) in test" do
        allow(Axn).to receive_message_chain(:config, :env, :development?).and_return(false)
        allow(Axn).to receive_message_chain(:config, :env, :production?).and_return(false)
        expect(logger).to receive(:warn)
        expect { described_class.best_effort("foo", &boom) }.not_to raise_error
      end
    end
  end
end
```

- [ ] **Step 2: Run it, expect failure** — `bundle exec rspec spec/axn/extensions_spec.rb`
Expected: FAIL, `uninitialized constant Axn::Extensions`.

- [ ] **Step 3: Create `lib/axn/extensions.rb`**

```ruby
# frozen_string_literal: true

module Axn
  # The extension-author surface: "for gems building on axn," distinct from
  # Axn::Internal (private) and the user-facing DSL. Not Ruby core-ext/refinements —
  # this is the API sibling gems (Axn::Webhooks, Axn::MCP, ...) may rely on.
  module Extensions
    class << self
      # Runs the block, guarding a best-effort side effect (a hook, callback, observability
      # facet, or a reporter that itself throws). On StandardError the error is logged and
      # swallowed (returning nil) so it never breaks the main action flow — EXCEPT in
      # development when Axn.config.best_effort_raises_in_dev is set, where it re-raises.
      # `desc` names the intent ("resolving webhook subscribers"); `action` is an optional
      # warn-target (an action instance/class responding to :warn), defaulting to the config logger.
      def best_effort(desc, action: nil)
        yield
      rescue StandardError => e
        raise e if Axn.config.best_effort_raises_in_dev && Axn.config.env.development?

        # Extract just filename/line number from backtrace
        src = e.backtrace.first.split.first.split("/").last.split(":")[0, 2].join(":")

        message = if Axn.config.env.production?
                    "Ignoring exception raised while #{desc}: #{e.class.name} - #{e.message} (from #{src})"
                  else
                    msg = "!! IGNORING EXCEPTION RAISED WHILE #{desc.upcase} !!\n\n" \
                          "\t* Exception: #{e.class.name}\n" \
                          "\t* Message: #{e.message}\n" \
                          "\t* From: #{src}"
                    "#{'⌵' * 30}\n\n#{msg}\n\n#{'^' * 30}"
                  end

        (action || Axn.config.logger).send(:warn, message)

        nil
      end
    end
  end
end
```

- [ ] **Step 4: Wire the require** — in `lib/axn.rb`, add after line 13 (`require "axn/exceptions"`):

```ruby
require "axn/extensions"
```

- [ ] **Step 5: Rename the config knob** — `lib/axn/configuration.rb:28`

```ruby
    setting :best_effort_raises_in_dev
```

- [ ] **Step 6: Make `PipingError.swallow` delegate** — replace the body of `lib/axn/internal/piping_error.rb` with:

```ruby
# frozen_string_literal: true

module Axn
  module Internal
    # Transitional delegator: the guard now lives at Axn::Extensions.best_effort.
    # Remaining internal call sites migrate to the block form; this module is deleted afterward.
    module PipingError
      def self.swallow(desc, exception:, action: nil)
        Axn::Extensions.best_effort(desc, action:) { raise exception }
      end
    end
  end
end
```

- [ ] **Step 7: Update the knob name in prose** — `lib/axn/async/batch_enqueue.rb:115` comment, `docs/reference/configuration.md` (heading `## raise_piping_errors_in_dev` → `## best_effort_raises_in_dev`, the code sample `c.raise_piping_errors_in_dev = true`, and the table row), `docs/reference/async.md:459`. Replace every `raise_piping_errors_in_dev` with `best_effort_raises_in_dev`. Verify none remain:

```bash
grep -rn "raise_piping_errors_in_dev" lib docs
# Expected: no output
```

- [ ] **Step 8: Delete the old spec** — `git rm spec/axn/internal/piping_error_spec.rb`

- [ ] **Step 9: Run both suites**

```bash
bundle exec rspec
bundle exec rake spec_rails
```
Expected: PASS. (Un-migrated sites route through `swallow` → `best_effort`; the old-knob stub in remaining specs is retargeted in Task 2.)

Note: some existing specs stub `receive_message_chain(:config, :raise_piping_errors_in_dev)`. Because `swallow` now reads the block path, those stubs no longer influence behavior but do not error (message-chain stubbing defines the method). Any spec that asserts the *dev-raise* behavior via the old knob is retargeted in Task 2; if one fails here, note it and let Task 2 fix it rather than patching twice.

- [ ] **Step 10: Commit**

```bash
git add -A
git commit -m "PRO-2950: add Axn::Extensions.best_effort; rename knob to best_effort_raises_in_dev"
```

---

### Task 2: Flip test spying from `PipingError.swallow` to `Axn::Extensions.best_effort`

Because `swallow` delegates to `best_effort`, spying `best_effort` observes both migrated and un-migrated sites — so this flip is safe before the call sites move.

**Files:**
- Modify: `spec/spec_helper.rb:38-50` (`expect_piping_error_called` → `expect_best_effort_called`)
- Modify every spec that references `Axn::Internal::PipingError` or `expect_piping_error_called`:
  `spec/axn/core/on_exception_spec.rb`, `spec/axn/core/global_on_exception_spec.rb`,
  `spec/axn/core/messages_spec.rb`, `spec/axn/core/validations/validators/validate_validator_spec.rb`,
  `spec/axn/async/batch_enqueue_spec.rb`, `spec/axn/mountable/enqueue_all_spec.rb`,
  `spec/axn/internal/tracing/tagging_spec.rb`

**Interfaces:**
- Produces: `expect_best_effort_called(message_substring:, action: nil, times: 1)` — asserts `Axn::Extensions.best_effort` was called with a desc including `message_substring` (and `action:` when given). The swallowed exception's class/message are no longer asserted here (they live inside the block); specs that need them assert observable behavior (`result.exception`) instead, which they already do.

- [ ] **Step 1: Redefine the helper** — replace `spec/spec_helper.rb:38-50` with:

```ruby
def expect_best_effort_called(message_substring:, action: nil, times: 1)
  args = [a_string_including(message_substring)]
  args << hash_including(action:) unless action.nil?
  expect(Axn::Extensions).to have_received(:best_effort).with(*args).exactly(times).times
end
```

- [ ] **Step 2: Retarget the spy setups** — in each listed spec, replace:
  - `allow(Axn::Internal::PipingError).to receive(:swallow).and_call_original` → `allow(Axn::Extensions).to receive(:best_effort).and_call_original`
  - `expect(Axn::Internal::PipingError).to receive(:swallow).with(...)` → `expect(Axn::Extensions).to receive(:best_effort).with(a_string_including("<the desc substring>"))` (drop the `exception:`/`action_class:` hash matcher; keep `action:` only where asserted)
  - `expect_piping_error_called(message_substring: X, error_class: Y, error_message: Z)` → `expect_best_effort_called(message_substring: X)` (drop `error_class:`/`error_message:`; keep `action:`/`times:` when present)

  Find them all:

```bash
grep -rn "Axn::Internal::PipingError\|expect_piping_error_called\|piping_error" spec
```

- [ ] **Step 3: Run both suites**

```bash
bundle exec rspec
bundle exec rake spec_rails
```
Expected: PASS. Confirm no `piping` references remain in specs except intentional none:

```bash
grep -rn "PipingError\|piping_error" spec
# Expected: no output
```

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "PRO-2950: retarget specs to spy Axn::Extensions.best_effort"
```

---

### Task 3: Migrate the simple call sites to block form

All sites here are plain `rescue StandardError => e; swallow(...); [nil/false]`. Wrap the guarded work in `best_effort { ... }` and drop the boilerplate rescue. Suite stays green (behavior identical; `best_effort` still spied via Task 2).

**Files (each with the guarded expression):**
- `lib/axn/executor.rb:59, 107, 144, 162, 287, 368`
- `lib/axn/core/tagging.rb:39`
- `lib/axn/core/field_resolvers/model.rb:26-49`
- `lib/axn/core/validation/validators/validate_validator.rb:45`
- `lib/axn/core/flow/handlers/matcher.rb:19, 84`
- `lib/axn/async/exception_reporting.rb:62, 91`
- `lib/axn/async/adapters/sidekiq.rb:160`
- `lib/axn/async/enqueue_all_orchestrator.rb:169, 348`
- `lib/axn/internal/call_logger.rb:75`
- `lib/axn/async.rb:125` (also fixes the `action_class:` bug)

- [ ] **Step 1: Convert method-level rescues** — pattern (example `executor.rb:55-60`):

Before:
```ruby
    def prepare_inbound_for_facets!
      _clear_pre_pipeline_memos!
    rescue StandardError => e
      Internal::PipingError.swallow("preparing inbound context for async facet resolution", action: @action, exception: e)
    end
```
After:
```ruby
    def prepare_inbound_for_facets!
      Axn::Extensions.best_effort("preparing inbound context for async facet resolution", action: @action) do
        _clear_pre_pipeline_memos!
      end
    end
```
Apply the same shape to the other executor sites (107, 144, 162, 287, 368), `tagging.rb:39`, `validate_validator.rb:45`, `exception_reporting.rb:62, 91`, `sidekiq.rb:160`, `enqueue_all_orchestrator.rb:169`, and `call_logger.rb:75` — wrap the previously-guarded body, keep the same `desc` string and `action:` (where present). For each, delete the now-empty `rescue StandardError => e` clause.

- [ ] **Step 2: Convert `matcher.rb` (return value preserved)** — `lib/axn/core/flow/handlers/matcher.rb:15-20`:

Before:
```ruby
          def call(exception:, action:)
            result = matches?(exception:, action:)
            @invert ? !result : result
          rescue StandardError => e
            Axn::Internal::PipingError.swallow("determining if handler applies to exception", action:, exception: e)
          end
```
After:
```ruby
          def call(exception:, action:)
            Axn::Extensions.best_effort("determining if handler applies to exception", action:) do
              result = matches?(exception:, action:)
              @invert ? !result : result
            end
          end
```
`best_effort` returns `nil` on rescue, matching the old `swallow` return. Apply identically at the second `matcher.rb` site (line ~84).

- [ ] **Step 3: Convert `model.rb` and drop the dead rescue** — `lib/axn/core/field_resolvers/model.rb:26-49`. `id_value` (which raises the `MethodCallNotPermittedError` contract bug) is evaluated in the top guard, outside the block, so the bug stays loud without an explicit rescue:

```ruby
        def derive_value
          return nil if id_value.blank?

          finder_name = finder.is_a?(Method) ? finder.name : finder
          Axn::Extensions.best_effort("finding #{field} with #{finder_name}") do
            if finder.is_a?(Method)
              finder.call(id_value)
            elsif klass.respond_to?(finder)
              klass.public_send(finder, id_value)
            else
              raise "Unknown finder: #{finder}"
            end
          end
        end
```
The former `rescue Axn::ContractViolation::MethodCallNotPermittedError; raise` clause is removed: that exception now surfaces from `id_value.blank?` above, before the guarded block, so it propagates naturally.

- [ ] **Step 4: Convert `enqueue_all_orchestrator.rb:348` (filter block)** — `false`→`nil` on error is behavior-equivalent (`next unless filter_result` treats both as falsy):

```ruby
            if config.filter_block
              filter_result = Axn::Extensions.best_effort("filter block for :#{config.field}") do
                config.filter_block.call(item)
              end
              next unless filter_result
            end
```

- [ ] **Step 5: Convert `async.rb:125` and fix the kwarg bug** — the call passes `action_class:`, which `swallow`/`best_effort` do not accept (`action:` only); this path currently raises `ArgumentError` if it ever fires. Normalize to `action:`:

Before:
```ruby
        Axn::Internal::PipingError.swallow("emitting notification for axn.call_async", action_class: self, exception: e)
```
After (wrap the guarded emit; use the enclosing rescued expression as the block — inspect the surrounding `begin`/`rescue` at `async.rb` ~120-127 and wrap the notification-emit call):
```ruby
        Axn::Extensions.best_effort("emitting notification for axn.call_async", action: self) do
          # <the notification-emit expression that was in the begin block>
        end
```
Confirm `self` here responds to `:warn` (it is the action class); if it does not, drop `action:` so it falls back to `Axn.config.logger`. Verify against `lib/axn/async.rb:118-128` before finalizing.

- [ ] **Step 6: Run both suites**

```bash
bundle exec rspec
bundle exec rake spec_rails
```
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "PRO-2950: migrate simple best-effort call sites to block form"
```

---

### Task 4: Migrate the bespoke call sites

These keep their custom rescue selection (flow-control exceptions, loop `next`) and feed the already-caught exception into `best_effort` via `{ raise <caught> }`, which routes it through the same log/dev-raise path.

**Files:**
- `lib/axn/core/flow/handlers/invoker.rb:20-31`
- `lib/axn/async/enqueue_all_orchestrator.rb:362` (now ~:356 after Task 3 line shifts)
- Delete the now-unused `expect_piping_error_called` helper from `spec_rails/dummy_app/spec/spec_helper.rb` (no longer called by any spec; it references `Axn::Internal::PipingError`, deleted in Task 5).

- [ ] **Step 1: Convert `invoker.rb`** — preserve the two-rescue structure and `allow_flow_control` re-raise:

```ruby
          def call(action:, handler:, exception: nil, operation: "executing handler", allow_flow_control: false)
            return call_symbol_handler(action:, symbol: handler, exception:) if symbol?(handler)
            return call_callable_handler(action:, callable: handler, exception:) if callable?(handler)

            literal_value(handler)
          rescue Axn::Internal::EarlyCompletion, Axn::Failure
            raise if allow_flow_control

            Axn::Extensions.best_effort(operation, action:) { raise $ERROR_INFO }
          rescue StandardError => e
            Axn::Extensions.best_effort(operation, action:) { raise e }
          end
```

- [ ] **Step 2: Convert `enqueue_all_orchestrator.rb:362` (via extraction with `next`)** — keep the `begin/rescue` so `next` (skip item) still applies:

```ruby
            value = if config.via
                      begin
                        item.public_send(config.via)
                      rescue StandardError => e
                        Axn::Extensions.best_effort("via extraction (:#{config.via}) for :#{config.field}") { raise e }
                        next
                      end
                    else
                      item
                    end
```

- [ ] **Step 3: Run both suites**

```bash
bundle exec rspec
bundle exec rake spec_rails
```
Expected: PASS. Confirm no call sites remain on the old API:

```bash
grep -rn "PipingError" lib
# Expected: only lib/axn/internal/piping_error.rb (deleted next task) and its two requires
```

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "PRO-2950: migrate bespoke best-effort call sites (invoker, via-extraction)"
```

---

### Task 5: Delete `Axn::Internal::PipingError`

**Files:**
- Delete: `lib/axn/internal/piping_error.rb`
- Modify: `lib/axn.rb:28` (remove `require "axn/internal/piping_error"`)
- Modify: `lib/axn/core.rb:3` (remove `require "axn/internal/piping_error"`)

- [ ] **Step 1: Remove the requires** — delete both `require "axn/internal/piping_error"` lines.

- [ ] **Step 2: Delete the file** — `git rm lib/axn/internal/piping_error.rb`

- [ ] **Step 3: Verify no references remain**

```bash
grep -rn "PipingError\|piping_error" lib spec spec_rails docs
# Expected: no output
```

- [ ] **Step 4: Run both suites**

```bash
bundle exec rspec
bundle exec rake spec_rails
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "PRO-2950: delete Axn::Internal::PipingError (superseded by best_effort)"
```

---

### Task 6: Re-home the extension-config registry under `Axn::Extensions`

`Axn::ExtensionConfig` → `Axn::Extensions::Config`; `Axn.extension_config` → `Axn::Extensions.config`. `register_semantic_hint` / field-metadata methods stay on the config object.

**Files:**
- Move: `lib/axn/extension_config.rb` → `lib/axn/extensions/config.rb`
- Modify: `lib/axn.rb` (require path + delete `Axn.extension_config` method at lines 51-53)
- Modify: `lib/axn/extensions.rb` (add `.config` accessor)
- Modify: `lib/axn/core/semantic_hints.rb:23` and comment at `:8`, `lib/axn/core/contract.rb:802`
- Modify specs: `grep -rln "Axn::ExtensionConfig\|Axn.extension_config" spec`

**Interfaces:**
- Consumes: `Axn::Extensions` (Task 1).
- Produces: `Axn::Extensions::Config` (renamed from `Axn::ExtensionConfig`); `Axn::Extensions.config` → memoized singleton `Config` instance (replaces `Axn.extension_config`).

- [ ] **Step 1: Move + renamespace the class** — `git mv lib/axn/extension_config.rb lib/axn/extensions/config.rb`, then change the module nesting so the constant is `Axn::Extensions::Config`:

```ruby
# frozen_string_literal: true

module Axn
  module Extensions
    class Config
      # ... existing body unchanged (registered_semantic_hints, register_semantic_hint,
      #     registered_field_metadata_keys, etc.) ...
    end
  end
end
```

- [ ] **Step 2: Add the `.config` accessor** — in `lib/axn/extensions.rb`, inside `class << self`:

```ruby
      def config
        @config ||= Config.new
      end
```

- [ ] **Step 3: Fix requires + remove old accessor** — in `lib/axn.rb`: change `require "axn/extension_config"` to `require "axn/extensions/config"` (place it after `require "axn/extensions"`), and delete the `def self.extension_config … end` block (lines ~51-53).

- [ ] **Step 4: Update the two core readers** —
  `lib/axn/core/semantic_hints.rb:23`: `Axn.extension_config.registered_semantic_hints` → `Axn::Extensions.config.registered_semantic_hints` (and the comment at line 8).
  `lib/axn/core/contract.rb:802`: `Axn.extension_config.registered_field_metadata_keys` → `Axn::Extensions.config.registered_field_metadata_keys`.

- [ ] **Step 5: Update specs** — replace `Axn::ExtensionConfig` → `Axn::Extensions::Config` and `Axn.extension_config` → `Axn::Extensions.config` in every spec found by:

```bash
grep -rln "Axn::ExtensionConfig\|Axn\.extension_config" spec
```

- [ ] **Step 6: Verify + run both suites**

```bash
grep -rn "ExtensionConfig\|extension_config" lib spec
# Expected: only the new Axn::Extensions::Config / Axn::Extensions.config forms
bundle exec rspec
bundle exec rake spec_rails
```
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "PRO-2950: re-home extension config to Axn::Extensions::Config / .config"
```

---

### Task 7: Move `Executor` under `Axn::Core`

**Files:**
- Move: `lib/axn/executor.rb` → `lib/axn/core/executor.rb`
- Modify: `lib/axn.rb` (require path)
- Modify: every `Axn::Executor` / bare `Executor` reference.

**Interfaces:**
- Produces: `Axn::Core::Executor` (was `Axn::Executor`).

- [ ] **Step 1: Move the file + renamespace** — `git mv lib/axn/executor.rb lib/axn/core/executor.rb`, then wrap the class in `module Core`:

```ruby
module Axn
  module Core
    class Executor # rubocop:disable Metrics/ClassLength
      # ... body unchanged; internal bare references to Internal::/Core:: constants
      #     still resolve because they are looked up under Axn:: via Core's nesting ...
    end
  end
end
```

- [ ] **Step 2: Update the require** — in `lib/axn.rb`, change `require "axn/executor"` to `require "axn/core/executor"`.

- [ ] **Step 3: Update all references** — find and update:

```bash
grep -rn "Axn::Executor\b" lib spec
```
Replace `Axn::Executor` → `Axn::Core::Executor`. Also check for bare `Executor` used from top-level `Axn::` scope (e.g. in `lib/axn/core.rb` or `core/*`) that would now fail to resolve, and qualify them as `Core::Executor` or `Executor` as appropriate for their nesting. Verify:

```bash
grep -rn "\bExecutor\b" lib | grep -v "Core::Executor\|module Core\|class Executor"
# Inspect each remaining hit; qualify if it referenced the top-level constant.
```

- [ ] **Step 4: Run both suites**

```bash
bundle exec rspec
bundle exec rake spec_rails
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "PRO-2950: move Executor under Axn::Core"
```

---

### Task 8: Move the context-facade family under `Axn::Core`

Move `Context`, `ContextFacade`, `ContextFacadeInspector`, `InternalContext` into `Axn::Core`. `Result` stays top-level but its superclass reference updates.

**Files:**
- `lib/axn/context.rb` → `lib/axn/core/context.rb` (`Axn::Context` → `Axn::Core::Context`)
- `lib/axn/core/context/facade.rb` (`Axn::ContextFacade` → `Axn::Core::ContextFacade`)
- `lib/axn/core/context/facade_inspector.rb` (`Axn::ContextFacadeInspector` → `Axn::Core::ContextFacadeInspector`)
- `lib/axn/core/context/internal.rb` (`Axn::InternalContext` → `Axn::Core::InternalContext`)
- `lib/axn/result.rb` (`Axn::Result < ContextFacade` → `< Axn::Core::ContextFacade`; `Result` stays `Axn::Result`)
- `lib/axn.rb` (require path for context.rb)
- All references across `lib/` and `spec/`.

**Interfaces:**
- Produces: `Axn::Core::Context`, `Axn::Core::ContextFacade`, `Axn::Core::ContextFacadeInspector`, `Axn::Core::InternalContext`. `Axn::Result` unchanged (public), now `< Axn::Core::ContextFacade`.

- [ ] **Step 1: Renamespace the four machinery files** — wrap each class in `module Core`. For `facade.rb`, `facade_inspector.rb`, `internal.rb` (already under `lib/axn/core/context/`) change `module Axn` / `class ContextFacade` to `module Axn; module Core; class ContextFacade` (and siblings). For `internal.rb`, `class InternalContext < ContextFacade` now resolves `ContextFacade` as a `Core` sibling — keep the bare name.

- [ ] **Step 2: Move + renamespace `context.rb`** — `git mv lib/axn/context.rb lib/axn/core/context.rb`; wrap `class Context` in `module Core`; update `require "axn/context"` → `require "axn/core/context"` in `lib/axn.rb`.

- [ ] **Step 3: Update `Result`'s superclass** — `lib/axn/result.rb`: `class Result < Axn::Core::ContextFacade`. `Result` itself stays `Axn::Result` (top-level, public).

- [ ] **Step 4: Update all references** —

```bash
grep -rn "Axn::Context\b\|Axn::ContextFacade\b\|Axn::ContextFacadeInspector\b\|Axn::InternalContext\b" lib spec
```
Replace each with the `Axn::Core::` form. Then scan for bare references that resolved via top-level nesting and now need `Core::` qualification:

```bash
grep -rn "\bContextFacade\b\|\bInternalContext\b\|\bContextFacadeInspector\b" lib | grep -v "Core::"
# Inspect each; qualify if it named the top-level constant from outside Core's nesting.
```

- [ ] **Step 5: Run both suites**

```bash
bundle exec rspec
bundle exec rake spec_rails
```
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "PRO-2950: move Context facade family under Axn::Core (Result stays public)"
```

---

### Task 9: Document the namespace policy + reserved-constants guard

**Files:**
- Modify: `AGENTS.md`
- Create: `spec/axn/namespace_policy_spec.rb`

- [ ] **Step 1: Add the policy to `AGENTS.md`** — under an appropriate "Namespaces" heading, one line per paragraph:

```markdown
## Namespace policy

Sibling gems own their own `Axn::<GemName>` namespace (`Axn::Webhooks`, `Axn::MCP`, `Axn::RubyLLM`) — core never defines constants there.

axn-core reserves the top-level public constants (`Result`, `Failure`, `Factory`, `FormObject`, `Configuration`, `RailsConfiguration`, `Strategies`, and the exception classes) plus the module namespaces `Core`, `Internal`, `Async`, `Extensions`, `Tools`, `Reflection`, `Validation`, `Configurable`, `Mountable`, `Extras`, `FieldDeclarations`, `Testing`, `Util`.

`Axn::Extensions` is the extension-author surface (for gems building on axn — e.g. `Axn::Extensions.best_effort`, `Axn::Extensions.config`), distinct from `Axn::Internal` (private) and the user-facing DSL. `Axn::Core` holds action-assembly and runtime machinery (`Executor`, the context-facade family); it is not a public surface.
```

- [ ] **Step 2: Write the reserved-constants guard** — `spec/axn/namespace_policy_spec.rb`:

```ruby
# frozen_string_literal: true

RSpec.describe "Axn top-level namespace" do
  # Public constants + module namespaces core reserves at Axn::. A future accidental
  # clobber (or a machinery constant leaking back to top-level) fails this.
  RESERVED = %i[
    Result Failure Factory FormObject Configuration RailsConfiguration
    Strategies StrategyNotFound DuplicateStrategyError
    ContractViolation DuplicateFieldError ValidationError
    InboundValidationError OutboundValidationError UnsupportedArgument
    Core Internal Async Extensions Tools Reflection Validation
    Configurable Mountable Extras FieldDeclarations Testing Util
  ].freeze

  it "defines every reserved constant" do
    missing = RESERVED.reject { |c| Axn.const_defined?(c, false) }
    expect(missing).to be_empty, "missing top-level Axn constants: #{missing.inspect}"
  end

  it "no longer exposes the relocated machinery at top level" do
    %i[Executor Context ContextFacade ContextFacadeInspector InternalContext ExtensionConfig].each do |c|
      expect(Axn.const_defined?(c, false)).to be(false), "#{c} should not be a top-level Axn constant"
    end
  end
end
```

- [ ] **Step 3: Run it**

```bash
bundle exec rspec spec/axn/namespace_policy_spec.rb
```
Expected: PASS. (If `const_defined?(..., false)` still finds a relocated constant, a reference/renamespace in Task 6-8 was missed — fix there.)

- [ ] **Step 4: Run both suites**

```bash
bundle exec rspec
bundle exec rake spec_rails
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "PRO-2950: document namespace policy + reserved-constants guard spec"
```

---

## Post-plan: CHANGELOG + sibling adoption prompts

- Add a CHANGELOG entry (BREAKING, alpha) covering: `Axn::Extensions.best_effort` (new), `Axn::Internal::PipingError` removed, knob `raise_piping_errors_in_dev` → `best_effort_raises_in_dev`, `Axn::ExtensionConfig`/`Axn.extension_config` → `Axn::Extensions::Config`/`Axn::Extensions.config`, and the `Executor`/context-family moves under `Axn::Core`. Follow the repo's existing CHANGELOG format.
- Produce the three ready-to-paste sibling-session prompts (axn-webhooks, axn-mcp, axn-ruby_llm) — delivered to the user at the end, not part of the axn-core PR.

## Self-Review

- **Spec coverage:** item 1 (Extensions surface) → Tasks 1, 6; item 2 (best_effort + knob + call sites + async.rb fix) → Tasks 1, 3, 4, 5; item 3 (top-level shrink) → Tasks 7, 8; item 4 (policy + guard) → Task 9; item 5 (downstream) → post-plan prompts (out of scope, per spec). All covered.
- **Placeholder scan:** every code step shows real code; the one intentionally-inspect-first spot (`async.rb:125` block body) points at exact lines to read because the surrounding `begin` body must be lifted verbatim.
- **Type consistency:** `best_effort(desc, action: nil, &block)` used identically across Tasks 1/3/4; `Axn::Extensions.config` / `Axn::Extensions::Config` consistent across Tasks 6/9; relocated constants (`Axn::Core::Executor`, `Axn::Core::ContextFacade`, …) consistent across Tasks 7/8/9.
