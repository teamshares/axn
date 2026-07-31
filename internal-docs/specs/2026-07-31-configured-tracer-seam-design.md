# Give tracing a configured seam (`Axn.config.tracer`)

[PRO-3017](https://linear.app/teamshares/issue/PRO-3017/axn-give-tracing-a-configured-seam-axnconfigtracer-instead-of-an)

## Problem

There is no supported way to supply or replace axn's tracer. `Axn.config` has no tracing setting at all: `Internal::Tracing.tracer` auto-detects from OpenTelemetry, and `Core::Executor#with_tracing` gates the whole span on `defined?(OpenTelemetry)`.

The consequence showed up as a boundary violation — `axn-ruby_llm`'s spec reaches into `Axn::Internal::Tracing` to fake a tracer, the only place any downstream gem names `Axn::Internal::` across `axn-mcp`, `axn-openapi`, `axn-ruby_llm`, and `axn-webhooks`. But the production need is the reason to fix it: a custom provider, a differently-named instrumentation scope, or a no-op tracer to turn axn's spans off without unloading OpenTelemetry are all legitimate and none are expressible today. `Axn.config` keys are public API, so the shape wants to be right before release.

## The seam

`Axn.config.tracer`, declared through the ordinary `setting` kernel:

```ruby
# The tracer that receives axn's `axn.call` spans. Three states:
#   unset          → auto-detect: the OpenTelemetry tracer when OTel is loaded, else nil (no spans)
#   nil            → no tracing, even with OpenTelemetry loaded
#   a tracer       → that object, whether or not OpenTelemetry is loaded
# `Axn.config.reset!(:tracer)` returns to auto-detection.
#
# The default is dynamic — re-derived on every read — because OpenTelemetry may load after axn does.
# Caching "absent" at gem load (plausible under Bundler.require) would permanently disable tracing
# for an app that configures OTel in an initializer.
setting :tracer,
        default: -> { Axn::Internal::Tracing.autodetected_tracer },
        validate: ->(v) { v.nil? || v.respond_to?(:in_span) || "must respond to #in_span, or be nil to disable tracing" }
```

`tracer?` and the validating writer come from the kernel. `overridable:` is deliberately not set — see non-goals.

**Config owns policy; `Internal::Tracing` owns mechanism.** `Axn.config.tracer` returns the tracer actually in use, so the public reader is honest about all three states rather than being a raw slot that returns `nil` for both "unset" and "disabled". `Internal::Tracing.tracer` is **removed** rather than kept as a delegate — two names for one value invites the next gem to name the internal one. This also dissolves the provider-change hazard structurally: a configured tracer is returned by `Axn.config` without ever reaching the auto-detection path, so there is no code path from which `OpenTelemetry.tracer_provider` changing could clobber it. No guard clause needed.

## Kernel changes to `Axn::Configurable`

The tracer setting needs a tri-state (unset / explicit nil / value) that the kernel already supports via `callable: true` plus a Proc `default:` — but only accidentally, and the accident has already produced a wrong comment in a downstream gem. `slack_sender/lib/slack_sender/configuration.rb` documents its `sandbox_mode` setting as "an explicit true/false wins; nil/unset re-derives", which is false: unset re-derives, an explicit `nil` is stored and read back as `nil`, so `sandbox_mode?` becomes `false` — sandbox off, real Slack messages sent in non-production. Four changes make the behavior match what a reader expects.

**1. Drop `callable:`; infer dynamism from a Proc `default:`.** The flag's name points at values while its only real meaning is defaults — `bin/support/gem_generator.rb` teaches it as "`callable: true` for a lambda default", and `emit_metrics`, the one genuinely proc-valued setting in the repo, deliberately omits it because its proc must be called with arguments at the call site rather than resolved on read. So the "callable value" half is not merely unused; it would be wrong for the only setting shaped like it. `Setting` loses its `callable` member and gains `dynamic_default?` (`default.is_a?(Proc)`).

`Setting#resolve` goes away entirely, since dynamic defaults are now handled by the reader and nothing else needs it. That has one consequence to state explicitly: `resolve` currently also runs on per-class override values (`_define_override_methods`' `resolve_override`), so a Proc stored as an override is invoked today. After this change override values are literal. Nothing uses a Proc override, and the dynamic default still reaches an un-overridden class through the fallback, which reads the config's own reader.

**2. Stop memoizing a resolved dynamic default into the setting's ivar.** Today the reader writes `dup_default` into the ivar on first read, which poisons `defined?(@ivar)` as an "explicitly assigned" sentinel. Read Proc defaults fresh and never store them:

```ruby
define_method(name) do
  return instance_variable_get(ivar) if instance_variable_defined?(ivar)
  return setting.default.call if setting.dynamic_default?

  instance_variable_set(ivar, setting.dup_default)
end
```

Literal defaults keep memoizing, deliberately: in-place mutation of an array default is a relied-upon path (`adapter.config.tool_roots << "actions"`, `additional_includes`), and un-memoizing would make `<<` silently mutate a throwaway dup. The module-singleton flavor's `Config#_read` gets the same treatment against its `@values` hash.

No `memoize_default:` flag. Both dynamic defaults that exist — `tracer` and slack_sender's `sandbox_mode` — *must* re-derive for lazy-boot reasons, so "memoize forever", the only semantics such a flag can offer, would break its own use cases. Measured cost of a dynamic read is 164ns against 80ns for a memoized literal, and `tracer` is read once per action execution. Where a dynamic default is genuinely expensive, the working pattern is memoizing inside the callee where invalidation is knowable, as `autodetected_tracer` does against the provider. Adding the flag later is purely additive.

**3. Add `reset!(*names)`.** Returning a setting to its declared default currently requires `remove_instance_variable` — the ivar-poking this ticket exists to eliminate, and the reason an explicit `nil` looks like the way to reset. `reset!` drops the named settings' ivars (no arguments → every setting declared on the class that extended `Settings`) and raises `ArgumentError` on a name that isn't a declared setting, so a typo can't silently no-op. The module-singleton flavor's `Config` gets the symmetric method against `@values`; its existing `reset_config!` stays as the whole-bag reset.

This also gives the config surface its first supported test-isolation path. `spec_helper.rb` has none today and cannot get one otherwise: `Axn.config` memoizes into `@config` and `Axn` never defines `config=`, so `Axn.configure`'s `self.config ||= Configuration.new` only works because `||=` short-circuits before reaching the writer that isn't there.

**4. Let `validate:` return a String as the rejection reason.** `Setting#validate!` currently raises a bare `"<name> got invalid value: <value>"`, which does not tell someone assigning a non-tracer what a tracer needs to be. A validator returning a truthy String supplies the detail; `true` and other truthy values pass as before, so existing boolean validators are unaffected (no validator in axn or slack_sender returns a truthy non-boolean).

## `Internal::Tracing` becomes mechanism-only

```ruby
# The OpenTelemetry tracer, when OpenTelemetry is loaded. Mechanism only: whether axn traces at all,
# and with which tracer, is Axn.config.tracer's decision.
def autodetected_tracer
  return nil unless defined?(OpenTelemetry)

  current_provider = OpenTelemetry.tracer_provider
  return @tracer if defined?(@tracer) && defined?(@tracer_provider) && @tracer_provider == current_provider

  @tracer_provider = current_provider
  @tracer = current_provider.tracer("axn", Axn::VERSION)
end
```

Same body as today's `tracer`, renamed to say what it is. The `defined?(OpenTelemetry)` check per call and the provider-change re-fetch both stay: OTel loads lazily, and the re-fetch is what lets a test swap providers.

`supports_record_exception_option?` takes the tracer as an argument and probes the object actually being called, because an injected tracer's signature is its own and the class-level answer (`OpenTelemetry::Trace::Tracer.instance_method(:in_span)`) can be wrong in both directions:

```ruby
def supports_record_exception_option?(tracer)
  return false if tracer.nil?
  return @supports_record_exception if defined?(@supports_record_exception) && @probed_tracer.equal?(tracer)

  @probed_tracer = tracer
  @supports_record_exception = begin
    tracer.method(:in_span).parameters.any? { |type, name| name == :record_exception && %i[key keyreq].include?(type) }
  rescue StandardError
    false
  end
end
```

Only an explicitly-named keyword counts. A tracer declaring `**opts` reports `:keyrest` and is read as unsupported, so axn omits the option and an OTel >= 1.7 tracer underneath records the exception in addition to axn's own `span.record_exception`, producing a duplicate event. That is the safe direction: over-detecting sends `record_exception:` to a strict-arity tracer, and `in_span` is called outside `best_effort`, so the resulting `ArgumentError` would take down the call. The type restriction is behavior-preserving for auto-detected tracers, where the parameter is a `:key`.

The memo is a single identity-keyed slot rather than a map: there is one tracer per process, so a map models N tracers that never exist, and the slot holds no reference `Axn.config` isn't already holding. `ObjectSpace::WeakKeyMap` is 3.3+ and the gem supports 3.2.1, but that is not the reason — a one-element cache is the right shape on any Ruby.

`reset!` drops `@tracer`, `@tracer_provider`, `@supports_record_exception`, and `@probed_tracer`, replacing the ivar-poking in the existing tracing specs' teardown.

## Executor

The gate at `lib/axn/core/executor.rb:124` becomes tracer-presence rather than constant-presence, reading the tracer once:

```ruby
tracer = Axn.config.tracer
if tracer
  in_span_kwargs = { attributes: { "axn.resource" => resource } }
  in_span_kwargs[:record_exception] = false if Internal::Tracing.supports_record_exception_option?(tracer)

  tracer.in_span("axn.call", **in_span_kwargs) do |span|
    instrument_block.call
  ensure
    finalize_span(span)
  end
else
  instrument_block.call
end
```

`finalize_span` has a second OTel constant the ticket does not mention: `OpenTelemetry::Trace::Status.error` at line 156. With an injected tracer and OTel unloaded that raises `NameError`, which `best_effort` swallows — but it aborts the rest of that block, and the `resolved_tags` / `resolved_dimensions` attribute loops are *below* it. An injected tracer would silently lose every `axn.tag.*` and `axn.dimension.*` attribute on any failure or exception. The existing spec misses this because `spec/axn/internal/tracing/opentelemetry_spec.rb` hand-builds a fake `Trace::Status` const specifically to satisfy that line.

Guard the assignment, and only the assignment:

```ruby
if %w[failure exception].include?(outcome) && result.exception
  span.record_exception(result.exception)
  # The only OTel constant left in this path, and a configured tracer can be in use with OTel
  # unloaded. There is no vendor-neutral way to construct a Status.
  if defined?(OpenTelemetry::Trace::Status)
    error_message = result.exception.message || result.exception.class.name
    span.status = OpenTelemetry::Trace::Status.error(error_message)
  end
end
```

Guarding rather than reordering is deliberate. Hoisting the facet loops above the error branch would also fix the stranding, but it puts the user-supplied facet procs first, so a facet proc that raises would newly strand `record_exception` — trading one stranding for another. `span.record_exception` is duck-typed on the span and stays unconditional, so an injected non-OTel tracer gets the exception and every facet attribute, losing only the status object, which is the one thing that genuinely requires OTel.

Out of scope: a raising facet proc still strands whatever follows it inside that single `best_effort`. That is pre-existing, affects OTel users today, and per-line `best_effort` is a different change.

## Tests

OpenTelemetry is not a dependency of this gem — every tracing spec `stub_const`s it — so "injected tracer, OTel unloaded" is the suite's default state and the proof cases are cheap.

- An injected tracer receives `in_span("axn.call", attributes: {"axn.resource" => …})` with OpenTelemetry not loaded. This is the case that proves the gate changed.
- A **failing** action with an injected tracer and OTel unloaded still gets its `axn.tag.*` / `axn.dimension.*` span attributes, and its exception recorded. This is the case that proves the `Trace::Status` guard.
- `Axn.config.tracer = nil` produces no span even with OpenTelemetry stubbed present, and does not call `autodetected_tracer`.
- Unset auto-detects: existing behavioural assertions in `spec/axn/internal/tracing/opentelemetry_spec.rb` stand unchanged. Only their teardown changes, from ivar-poking to `Internal::Tracing.reset!`.
- A configured tracer survives an `OpenTelemetry.tracer_provider` change.
- `supports_record_exception_option?` answers from the injected tracer's own signature in both directions (a tracer declaring `record_exception:` receives the kwarg; one that doesn't, doesn't), a `**opts` tracer is read as unsupported, and the memo does not leak an answer across two different tracers.
- The writer raises on a non-nil object without `in_span`, and the message names `#in_span`.
- `Axn.config.reset!(:tracer)` restores auto-detection; `reset!` with no arguments clears every declared setting; `reset!(:nope)` raises.
- Kernel: a Proc `default:` re-derives per read and is never written to the ivar; a literal mutable default still memoizes so `<<` persists; an explicit `nil` reads back as `nil` rather than re-deriving.

## Docs

`docs/reference/configuration.md`'s "OpenTelemetry Tracing" section currently opens with spans being created "when OpenTelemetry is available", which stops being the whole truth. Add a "Supplying or disabling the tracer" subsection covering the three states, with the no-op-tracer case (turning axn's spans off without unloading OTel) called out since it is the one people will look for. Note that a fully non-OTel tracer receives spans, attributes, and `record_exception` but not an error `Status`.

CHANGELOG entry in the current section, matching the practice in #206/#207.

## Downstream snippets

Both land after this PR merges; neither is edited from this repo.

**`axn-ruby_llm`**, branch `kali/pro-2771-axn-ruby_llm-adopt-axn-configuration-dsl`, replacing `spec/axn/ruby_llm/ask_spec.rb:550`. With `verify_partial_doubles` on, the old stub fails loudly once `Internal::Tracing.tracer` is gone rather than silently no-opping.

```ruby
# was: allow(Axn::Internal::Tracing).to receive(:tracer).and_return(fake_axn_tracer)
let(:fake_axn_tracer) do
  # `in_span` must be stubbed BEFORE the assignment below: the config writer validates
  # `respond_to?(:in_span)`, and a verifying double only responds to what it has been stubbed with.
  instance_double("OpenTelemetry::Trace::Tracer").tap do |tracer|
    allow(tracer).to receive(:in_span).and_yield(fake_axn_span)
  end
end

before { Axn.config.tracer = fake_axn_tracer }
after  { Axn.config.reset!(:tracer) }
```

**`slack_sender`**, into its currently-open upgrade PR. Drops the removed kwarg and corrects the comment, whose current claim about `nil` is wrong today and stays wrong after this change.

```ruby
# Whether messages are redirected/suppressed for non-production. A dynamic default derives from
# Rails.env on each read while unset; an explicit true/false wins. An explicit nil is a VALUE, not a
# reset — it reads back as nil, making `sandbox_mode?` false (sandbox off). Use
# `SlackSender.config.reset!(:sandbox_mode)` to return to derivation. Marked overridable so an
# individual action can opt in/out of sandbox for its own sends via `configure(:slack_sender)`
# (resolved in the strategy and threaded down to DeliveryAxn).
setting :sandbox_mode,
        default: -> { defined?(Rails) && Rails.respond_to?(:env) ? !Rails.env.production? : true },
        overridable: true
```

Worth checking in that PR whether anything actually assigns `sandbox_mode = nil`; if so it is a live bug independent of this work.

## Non-goals

- **`Internal::Tracing` stays internal.** Only the configuration becomes public, consistent with the namespace policy in PRO-3005: `Internal::` is axn's own, `Extensions::` is the only namespace a gem should name.
- **No lazy/callable tracer value.** `c.tracer = -> { … }` is rejected by the validator. Auto-detection already covers the lazy-OTel case, and a Proc value would be ambiguous against a tracer that happens to respond to `call`.
- **No per-class override.** The span is process-level infrastructure. `overridable: true` is now a one-word change if that ever becomes wanted.
- **Ruby 3.2.1 stays the floor.** `ObjectSpace::WeakKeyMap` is not a reason to move it, since the single-slot memo is the better shape anyway. Whether axn should still support a Ruby that reached end-of-life in March is a real question, but it is a `required_ruby_version` bump that needs a survey of what os-app and the adapter gems run, and it belongs in its own pre-release ticket that enumerates the payoff.
- **Migrating the other hand-written accessors is a follow-up.** `logger`, `env`, `rails`, and `_enqueue_all_async_*` are all "dynamic/computed default", which a Proc `default:` now expresses, so each could collapse onto the kernel. Not here: `logger` memoizes a real host logger but deliberately not its stdout fallback (PRO-2891), `env` wraps a fresh `StringInquirer` per call, and `rails` hands back a mutable object where `dup_default` semantics matter. Each needs its own thought.
