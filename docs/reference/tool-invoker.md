---
outline: deep
---

# Tool Invoker

`Axn::Tools::Invoker` is the sanctioned entry point for running an Axn **as a tool** — the call path an adapter (MCP, an LLM function-calling bridge, an HTTP tool endpoint) uses to hand model-supplied, untrusted arguments to an Axn class and get back a result it can map into its own wire format.

An adapter builds one `Invoker` per behavior profile it wants (most build a single shared instance) and calls it instead of calling `.call` on the Axn class directly:

```ruby
invoker = Axn::Tools::Invoker.new(user_facing_input_errors: true, reject_undeclared_inputs: true)
result = invoker.call(ListCompanies, model_supplied_args, ambient_context: { current_user: })
```

## Why not just call `.call`?

A normal `Foo.call(**args)` is written for a trusted, in-process Ruby caller: types are asserted strictly (no wire-string coercion), an unrecognized key is silently ignored (a normal Ruby `**kwargs` behavior), and every inbound violation reports to `on_exception` as a developer-facing bug. A tool caller has different needs — the arguments came from a model, not a Ruby caller — and the Invoker is the seam that applies a different, adapter-chosen contract without touching what a direct `.call` does.

## The profile knobs

`Invoker.new` takes two keyword options, both defaulting to `false`:

| Option | Effect |
| --- | --- |
| `user_facing_input_errors:` | An inbound contract violation (a top-level or subfield `expects` failure, a `model:` consistency mismatch) settles as a non-reported, user-facing failure — `result.error` carries the composed violation message(s) instead of firing `on_exception`. |
| `reject_undeclared_inputs:` | A top-level key in `args` that isn't a declared `expects` field becomes an inbound validation error instead of being silently dropped. |

Both are per-call gates threaded through `Axn::Internal::CurrentCallOptions` — they apply to exactly the wrapped `.call` and are cleared before any nested `.call` inside it, so a tool calling another action internally sees ordinary default semantics for that inner call.

Coercion is **not** one of these knobs — it's always on for every `Invoker#call`, regardless of the profile. A tool's arguments are wire data by construction (JSON from a model, form-shaped params), so the Invoker forces `coerce_input_types: true` for the call. This is the one case where axn coerces without the author opting in at the class or global level: the trusted-JSON boundary already implies it. A field's own `coerce:` (or lack of a coercible `type:`) still governs that field — the Invoker only supplies the whole-action default. See [`type:` on every tool input](#type-on-every-tool-input) below for what this means for how you declare a tool's `expects`.

## `ambient_context` guard

An Axn's `ambient_context` (`current_user`, `company`, …) is framework-supplied, never something a caller passes directly — see [`ambient_context`](/reference/class#ambient-context-on-ambient-context) in the class reference. Since `args` is untrusted, model-supplied input, the Invoker strips any `ambient_context` key the model tried to set before the call runs, then merges in the adapter's own trusted `ambient_context:` keyword (if given) after the guard. This means a tool call always resolves ambient context through the adapter's own trusted channel, never through a value smuggled in the tool arguments.

```ruby
invoker.call(ListCompanies, { ambient_context: { current_user: attacker_id } }, ambient_context: { current_user: real_user })
# the model-supplied ambient_context is dropped; the call runs with ambient_context: { current_user: real_user }
```

## Return value and detection

`#call` returns a plain `Axn::Result` — the same object a direct `.call` returns, so an adapter's existing result-mapping code (turning a `Result` into an MCP tool response, an HTTP body, etc.) is unchanged. There is no new `Axn::Result` method for "was this an inbound-contract failure" — detect it via the exception class:

```ruby
result = invoker.call(ListCompanies, args)

Axn::Tools::Invoker.input_invalid?(result)
# equivalent to: Axn::ValidationError.user_facing?(result.exception)
```

`input_invalid?` answers `true` only when the inbound violation was surfaced as a **user-facing** caller error — a correctable, model-facing failure composed under `user_facing_input_errors:`. An inbound failure that stayed **dev-facing** (a normal reported bug, or one that occurred with the gate off) reported to `on_exception` and is **not** flagged `input_invalid?`, so the adapter returns its generic error rather than telling the model its arguments were wrong. It's also `false` for a deliberate `fail!`, an outbound (`exposes`) violation, or any other raised exception.

Ambient (`on: :ambient_context`) failures stay dev-facing even under `user_facing_input_errors:`. Ambient context is trusted, adapter-supplied input (the Invoker injects it — see the guard above), not model input, so a missing or malformed ambient value is an integration bug: it reports to `on_exception` and `input_invalid?` is `false`. When an ambient violation co-occurs with a model-supplied one, the whole set settles dev-facing and reports (a real bug always pages, with every co-occurring violation in one report).

## Per-field detail

`result.error` is the composed sentence (axn's normal message-composition rules — base headline plus reason). For a tool that wants to render field-by-field detail (e.g. an MCP client that highlights which argument was wrong), `Axn::InboundValidationError` exposes the individual violations:

```ruby
result.exception.field_errors
#=> [{ field: :limit, message: "Limit is not a number" }, { field: :company_id, message: "Company can't be blank" }]
```

`field_errors` is only defined on `ValidationError` (and its `InboundValidationError` subclass) — check `input_invalid?`/`result.exception.is_a?(Axn::InboundValidationError)` first.

## `type:` on every tool input

With coercion always on for a tool call, an `expects` field only benefits from that coercion if it declares a `type:` axn recognizes as coercible (`Date`, `DateTime`, `Time`, `Symbol`, `Integer`, `Float`, `:boolean` — see [`coerce`](/reference/class#coerce)) — and the same `type:` is what `input_schema` uses to build the JSON Schema an adapter hands to the model in the first place. Declare a `type:` on every tool input rather than reaching for a defensive per-field `coerce: true`: the Invoker's always-on coercion and the schema reflection both key off it, so one declaration does both jobs.

```ruby
class ListCompanies
  include Axn
  tool

  expects :limit, type: Integer, optional: true    # coerced from "25" and schema'd as integer
  expects :since, type: Date, optional: true        # coerced from "2026-07-08" and schema'd as string/date
end
```

## `coerce_input_types` still governs direct `.call`

The Invoker's always-on coercion is a per-call layer scoped to calls made through it — it does not change the class or global `coerce_input_types` setting (see [Coercing a whole action](/reference/class#coercing-a-whole-action-coerce-input-types)). A direct `SomeAxn.call(...)` from ordinary Ruby code still resolves coercion exactly as it did before: off by default, on only where the class or `Axn.config` opts in.
