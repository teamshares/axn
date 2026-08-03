# best_effort cannot be taken down by the exception it swallows (PRO-3018)

/ Linear: https://linear.app/teamshares/issue/PRO-3018

## Problem

`Axn::Extensions.best_effort` exists to guarantee that nothing in a side channel can take down the call it observes. It does not hold. `_warn_and_swallow` builds its warning from `exception.class.name` and `exception.message`, and `_source_location` walks `exception.backtrace`, all **inside** the rescue — so the swallowed exception gets a second chance to escape through the very code meant to contain it.

Eight escapes were verified directly against `Axn::Extensions.best_effort("probing") { raise … }`:

| input | what escapes instead |
| --- | --- |
| `def message = raise(…)` | the exception `message()` raised |
| `message` holds bytes with no UTF-8 rendering | `Encoding::CompatibilityError` |
| `message` returns a non-String whose `to_s` raises | the exception `to_s` raised |
| `def self.name = raise(…)` on the class | the exception `name()` raised |
| `def backtrace = raise(…)` | the exception `backtrace()` raised |
| `backtrace` returns a non-Array | `NoMethodError: first` |
| `backtrace` holds `Thread::Backtrace::Location`s | `NoMethodError: split` |
| `set_backtrace([""])` — a blank frame | `NoMethodError: split for nil` |

Plus one that is not about the exception at all: a non-String `desc` reaches `desc.upcase` in the non-production wording and raises `NoMethodError`.

The blank-frame row is the sharpest, because `_source_location`'s own comment names that scenario as the reason it tolerates an empty backtrace: "an exception reconstructed with `set_backtrace([])` (what a death handler rebuilding one from job data hands us)". It tolerates `nil` and `[]` and crashes on `[""]`.

Neither of the two shapes the ticket highlights needs a hostile author. `raise ArgumentError, <binary string>` is enough for the encoding half — the stored message of an ordinary exception is a String the raiser chose, and no `#message` override is involved.

### Reachable through ordinary usage, and the damage is a wrong result

The ticket recorded that it could not reach the defect through ordinary axn usage in two attempts and asked for the call sites to be enumerated rather than assumed safe. They are enumerated below, and one is reachable with three lines of ordinary DSL: a user `validate:` lambda that raises.

| `expects :n, validate: ->(_v) { … }` raises | `result.exception` today |
| --- | --- |
| an ordinary `StandardError` (control) | `Axn::InboundValidationError` |
| an exception whose `#message` raises | `NotImplementedError` — every environment, production included |
| `ArgumentError` with a binary stored message | `Encoding::CompatibilityError` in development and test |

`validate_validator.rb:50` reports the lambda's exception through `best_effort(…) { raise e }`. The reporting failure escapes the guard, the executor one layer out absorbs it, and it **replaces the real error on the result**: the user's `Axn::InboundValidationError` is destroyed, the per-field validation message is never added, and `result.exception` names a stack that has nothing to do with the failure. `.call` still returns a result, so this is a misattribution bug rather than an outage — but it is a live one, not merely a false stated guarantee.

### Why the encoding half is environment-dependent

Two ASCII-compatible Strings concatenate fine; the raise needs non-ASCII text on **both** sides. The production wording is pure ASCII, so joining a binary message succeeds and merely leaves the log line tagged with the message's encoding. The non-production wording decorates with `'⌵' * 30` (U+2335), which makes axn's own side non-ASCII — so the same input raises in development and test. `PropertyNames.renderable_label`'s comment already states this rule; the production path is not safe, it is silently mistagging.

### Why the fix is a layer move rather than a call to the existing renderer

`Reflection::PropertyNames.renderable_label` is exactly the right funnel, and `Axn._reported_message` is already the guarded exception-message reader built on it (added in #208 for the boot path). Neither is reachable from where the bug is.

`extensions.rb` requires one file today (`internal/identity`). Requiring `reflection/property_names` pulls in 12 — including `reflection/values`, which requires `axn/exceptions`. That is the cycle `Internal::ClassName`'s own comment describes: "the reflection layer requires THIS file: reaching back into it here would leave a message path NameError-ing under the standalone loads `spec/axn/standalone_require_spec.rb` pins." No hard cycle blocks the require today, but making the gem's lowest-level guard — the one `configurable.rb` uses during config boot — depend on the serialization stack is the wrong direction.

AGENTS.md already names the move this implies: "Two message paths deliberately still carry raw bytes, because they sit BELOW the renderer in the load order — `Reflection::Values`' colliding-key report and `UnserializableValue#message`, in the files the renderer is itself built on — so closing them means moving the byte primitive DOWN rather than reaching up from them." This ticket is that move, with `best_effort` as the third caller that needs it.

## Scope

### 1. `Axn::Internal::Text` — the byte primitive, moved down

New file `lib/axn/internal/text.rb`, module `Axn::Internal::Text`, **zero requires**. It owns what `Reflection::Values` owns today, moved rather than copied:

- The bound String methods `encoding`, `valid_encoding?`, `ascii_only?`, `encode`, and `inspect` (a String subclass can override any of them, and one whose `valid_encoding?` lies defeats the guard on precisely the value it exists to catch).
- `utf8_rendering(string)` — a UTF-8 String, or `nil` when the bytes have none. Verbatim from `Values`.
- `transcode_to_utf8(string)` — verbatim from `Values`.
- `escaped(string)` — the bound `String#inspect`.
- `renderable(string)` — `utf8_rendering(string) || escaped(string)`, returned as the frozen plain UTF-8 copy `canonical_wire_key` makes today (`String.new(utf8).force_encoding(UTF_8).freeze`). String-only by contract; callers type-test first.

Three owners then delegate instead of keeping their own copy:

- `Reflection::Values.utf8_rendering` delegates. `transcode_to_utf8` is DELETED there rather than delegated — it had no caller outside `utf8_rendering`, so `Text` becomes its only home. `canonical_wire_key` keeps its own copy-and-freeze so its output stays byte-identical.
- `Reflection::PropertyNames.field_name_spelling`'s String branch uses `Text.escaped`.
- `Internal::Identity.utf8_string` becomes `utf8_rendering(value) || <scrub fallback>`.

That last one is the consolidation worth having: two implementations of the same byte question exist today with different policies. Afterwards there is **one** primitive with two documented fallbacks — *scrub* where the text must always render (a `validate:` reason joined into a validation message), *escape* where it must be safe (a name or an exception message written into prose).

The consolidation was verified equivalent before being specified, over nine inputs — ASCII, valid multibyte UTF-8, transcodable Latin-1, untranscodable binary, UTF-8-tagged invalid bytes, UTF-16, empty, and an ASCII and a binary String subclass. Every one produces a byte-identical result in the same encoding.

It also keeps one behaviour deliberately: for an ASCII-only String **subclass** both the current `utf8_string` and `utf8_rendering` hand the subclass instance straight back, and neither needs to copy it, because `"#{}"` on a String never dispatches `to_s` (verified: a subclass whose `to_s` raises interpolates fine). Only `canonical_wire_key` copies and freezes into a plain String, and that copy stays at its call site rather than moving into the primitive — it is the wire-key contract, not a safety measure. The new `renderable` makes the same copy for the same reason, since what it returns is written into prose axn owns.

### 2. `Axn::Internal::Rendering` — the composed readers

New file `lib/axn/internal/rendering.rb`, requiring only `axn/exceptions` (for `Internal::ClassName`) and `axn/internal/text`. It holds every reader that composes the two halves an error path owes — do not dispatch, then render the bytes:

- `exception_message(exception)` — today's `Axn._raw_reported_message` guard (dispatch `#message` behind `rescue Exception`, type-test the result, fall back to a bound `Exception#to_s`, then to the class name), rendered through `Text.renderable`. `Axn._reported_message` and `_raw_reported_message` **move** here from `lib/axn.rb`, unchanged in behaviour.
- `class_name(value)` — `ClassName.of(value)` rendered. `PropertyNames.renderable_class_name` delegates.
- `module_name(mod)` — `ClassName.of_module(mod)` rendered. `PropertyNames.renderable_module_name` delegates.
- `exception_source_location(exception)` — the hardened `_source_location`: a bound `Exception#backtrace`, an Array type-test, a String type-test on the first frame, and a blank-frame check via `Identity.blank_string?`. Anything that does not yield a usable frame returns `"unknown location"`, which is the existing fallback for a nil backtrace.

`Axn._named_invalid_tool_contract` calls the moved reader, so #208's behaviour and its specs are unchanged and there is one owner rather than two.

**Why two files rather than one.** `Rendering` requires `axn/exceptions` for `ClassName`, and closing `UnserializableValue#message` means `exceptions.rb` itself needs the byte primitive — so the primitive cannot live beside `ClassName` (`exceptions.rb` would require the file that requires it) and cannot live in `Rendering` (same cycle). A call-time-only constant reference would not dodge it either: `spec/axn/standalone_require_spec.rb` derives references from each file's own parse tree and requires the file to declare them. So the byte half goes in a zero-require file **below** both, and the composed half sits above `exceptions.rb`. The split is forced by the load order, not chosen.

`Internal::ClassName` deliberately does **not** start rendering its own output. Its contract is "does not dispatch", and callers that write into prose compose the two halves — that separation is what its comment draws, and collapsing it would change every caller's contract to buy nothing.

### 3. `best_effort` — the invariant, held by construction

`_warn_and_swallow` builds its message from `Rendering.exception_message`, `Rendering.class_name`, and `Rendering.exception_source_location` rather than interpolating raw. `desc` is type-tested and rendered the same way (`Text.renderable` for a String, `ClassName.of` otherwise), which closes the `desc.upcase` escape.

Then a final backstop around the whole report path, so the guarantee holds by construction rather than by enumeration:

> **The only exception `best_effort` can raise is the exception the block raised** — re-raised under `best_effort_raises_in_dev`, or passed through when it is not swallowable. Never a third exception manufactured while reporting.

The backstop covers only the *reporting*, never the block, and it is narrow on exactly the terms `best_effort` itself is: `StandardError` plus `SWALLOWABLE_BEYOND_STANDARD_ERROR`, which is what `_emit_warning` already does with its nested rescue. Within that set, a lost log line is strictly better than a lost exception — the policy `Identity.describe` states ("on an error path the exception being reported has to win over anything raised while describing it"), and `describe` can absorb every class because what it guards is one `inspect` on a value rather than a path a signal travels through. Absorbing everything HERE would be wrong: a signal, an `exit`, or another library's control-flow exception arriving mid-report is not axn's to eat, and swallowing one to save a warning breaks control flow somebody else owns. So the guarantee is "never a third exception manufactured while reporting", not "nothing but the block's exception can ever leave".

### 4. The rest of the class

Two members escape **outside** the guard and are not fixed by anything above:

- `Core::Context::FacadeInspector` (`facade_inspector.rb:28,31`) reads `context.exception.message` and `.class.name` to build `Result#inspect`. Verified: `result.inspect` raises today on a failed result carrying a hostile exception. It does not take down `.call`, but it poisons every logger, debugger, and spec failure message that touches the result. A THIRD read on the failure branch is worse than either, because it needs no hostile object at all: `context.exception.default_message?` is axn's own predicate on `Axn::Failure`, and a failed result's exception is frequently not an `Axn::Failure` — `fails_on Boom` and `expects …, user_facing: true` both settle into the failure bucket carrying their own class, and `result.inspect` raises a bare `NoMethodError` for each. So the predicate is only asked of an exception that answers it, behind the undispatched type test `Result#_resolve_error` already puts on the identical read.
- `executor.rb:852` builds `best_effort("settling #{settling.class} onto the result", …)`. `desc` is evaluated **before** the guard is entered, so dispatching `class` on the caller's exception there is covered by no rescue at all. Becomes `ClassName.of`.

Two are the #208 leftovers this move exists to unblock, both now reachable because the primitive is below them:

- `Axn::Reflection::UnserializableValue#message` (in `exceptions.rb`).
- `Reflection::Values.describe_key_classes` — the colliding-key report.

Then the funnel sweep over the remaining dispatched reads that write a foreign exception into prose. None of these escape today — each already sits inside a guard — but each is a misattribution source of the identical shape, and `renderable` is byte-identical for ASCII so no existing message text changes:

`configuration.rb:239-244` (the default `on_exception` log line), `executor.rb:666` (span error message), `message_resolver.rb:121`, `tools/registry.rb:156,161,249` (tool-load skip lines), `contract_error_handling.rb:30`, `field_config.rb:51,66`, `validate_validator.rb:52`.

One deliberate non-change: `field_resolvers/extract.rb:110` matches `error.message.start_with?("wrong number of arguments", …)`. That is a predicate, not prose — it gets the guarded read (so a raising `#message` cannot escape it) and the matching itself is left alone.

### 5. The call-site enumeration the ticket asks for

31 `best_effort` call sites. The question "which could raise these shapes" has a blunt answer: the binary-message shape needs no override, so **any** site whose block can raise from code axn did not write qualifies. The useful distinction is how directly.

**Group A — the block re-raises a caller-supplied exception (`{ raise e }`), so the exception is authored by whoever wrote the handler.** Highest value, and where the verified reachable path lives.

| site | whose exception |
| --- | --- |
| `validate_validator.rb:50` | a user `validate:` lambda — **verified reachable, misattributes the result** |
| `invoker.rb:26,28,38` | any user handler: hooks, callbacks, message blocks, `user_facing:` |
| `matcher.rb:23,90` | a user `rescues`/`fails_on` predicate |
| `executor.rb:514,520` | a configured tracer or `emit_metrics` observer |
| `executor.rb:852` | the exception being settled, via user callback machinery |
| `enqueue_all_orchestrator.rb:373` | a user `via:` extraction |

**Group B — the block runs user, config, or third-party code, so it can raise either shape freshly.** `executor.rb:241,351,480,627,649,718,721,860,909`; `tagging.rb:39` (facet blocks); `async.rb:120`; `exception_reporting.rb:21,84`; `enqueue_all_orchestrator.rb:154,349,360`; `sidekiq.rb:156` (job tag sources); `call_logger.rb:50`; `model.rb:38`; `configurable.rb:243,580`.

**Group C — `desc` dispatches on a caller object, before the guard is entered.** `executor.rb:852` (`settling.class`) is the one that dispatches on an exception. `enqueue_all_orchestrator.rb:154` interpolates `target.name` — a `Module#name` dispatch on an action class, which an override could make raise; noted, and it takes the same `ClassName.of` treatment. Every other `desc` interpolates a declared Symbol or String from the contract.

### 6. Documentation

AGENTS.md needs two edits in the line-120 error-path rule, both factual:

- The "two message paths deliberately still carry raw bytes … so closing them means moving the byte primitive DOWN" sentence becomes the record that they were closed, by that move, into `Internal::Text`.
- Its closing sentence claims caller data is a different category because a lying value "runs per call inside `best_effort`/`CycleGuard`, and a value that lies degrades a log line or masks more than necessary — it does not replace a verdict with an exception that escapes the rescue meant to settle it." Inside `best_effort` that was false: a lying exception replaced the verdict. The rule survives, the example does not.

Add `Axn::Extensions`, `Internal::Text`, and `Internal::Rendering` to the list of layers that hold the no-dispatch-while-reporting property.

No user-facing docs change: for every well-behaved exception the warning text is byte-identical.

## Done when

- All eight escapes above are swallowed and warned about, in every environment, with the original call unaffected.
- The `validate:` misattribution is gone: a lambda raising either shape yields `result.exception` of `Axn::InboundValidationError`, with the per-field message present, exactly as the well-behaved control does.
- A valid-UTF-8 multibyte message (`"café"`) appears verbatim in the warning, and a Latin-1 one reads as its text rather than as escapes.
- `result.inspect` renders a failed result carrying any of the eight shapes without raising.
- A spec asserts the invariant as a property — for a table of block-raised exceptions covering all eight shapes plus well-behaved controls, `best_effort` either swallows or re-raises *that same exception object*, and never a third one — rather than asserting the two inputs from the ticket.
- The moved primitive is proven equivalent: `Identity.utf8_string` and `Values.canonical_wire_key` keep their current outputs for ASCII, valid UTF-8, transcodable, invalid-UTF-8, and untranscodable inputs.
- `spec/axn/standalone_require_spec.rb` still passes, with the new files' requires declared explicitly rather than inherited from the entry point's load order.
- The full suite passes under Ruby 3.4 locally, not just the pinned 3.3.6 (`Hash#inspect` spacing differs, and these specs assert message text).

## Out of scope

- `Axn.config.env` set to a value `ActiveSupport::StringInquirer.new` refuses (a Symbol) makes `raises_in_dev?` raise, taking `best_effort` down before it reaches any of this. That is a broken global config failing loudly and identically everywhere, not a hostile exception, and belongs to config validation.
- The 0-arg `#exception` that `raise` itself calls on the object it is handed. `_warn_and_swallow`'s dev-loud `raise exception` dispatches it, and Ruby has no re-raise that skips it. #208 settled the doctrine for the boot path — avoid the dispatch by only ever handing `raise` an object whose class does not own `#exception` — and applying it here means the dev-loud path stops re-raising the original object in that case, which is a behaviour change to the dev-loud contract rather than a hardening of the report. Dev-loud is deliberately loud; the exception is already in flight.
