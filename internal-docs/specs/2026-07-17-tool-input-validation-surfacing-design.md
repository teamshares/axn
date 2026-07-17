# Tool input validation: structured, non-reported inbound surfacing for adapters

Linear: [PRO-2943](https://linear.app/teamshares/issue/PRO-2943/axn-tool-validation-improvements) (parent PRO-1610).

## Context

`axn-ruby_llm` and `axn-mcp` wrap any Axn as an LLM/MCP tool: the model supplies the arguments, and a malformed tool call should come back to the model as a clean, correctable "invalid arguments: <what's wrong>" — not as a generic failure, and not reported as an application bug (a bad LLM tool call isn't a bug in our code).

Today a non-`user_facing:` inbound-contract violation is treated as a dev-facing exception. In `Executor#with_exception_handling` (executor.rb:300) an `InboundValidationError` that is neither a `Failure`, `fails_on`-matched, sticky-failure, nor `user_facing?` falls to `trigger_on_exception` — so it fires the global `on_exception` report and `result.error` shows the generic headline, with no indication of which field or why. For an LLM/MCP boundary that is doubly wrong: (a) routine bad tool calls page `on_exception` as if our code were buggy — a false-positive firehose that erodes the one channel meant to catch real bugs; and (b) the model gets "Something went wrong" instead of an actionable per-field reason it could self-correct from.

The current downstream workaround (to be retired) is a shallow pre-check in `axn-ruby_llm`'s `tool_argument_validator` against the reflected `input_schema`: required-keys, unknown-keys, and top-level JSON type only. It deliberately skips enum/nested/items/format because covering them means re-implementing (and risking divergence from) the validation Axn already performs. So deep violations still fall through to the generic-message + `on_exception` behavior.

## The stance we are NOT changing

Direct `.call` from ordinary app code keeps treating bad inbound data as a **dev issue**: it fires `on_exception` and surfaces the generic error exactly as today. `MyAction.call(name: 123)` from app code genuinely is a programming bug, and the report is the safety net that catches it. The framework's existing stance — inbound violations are dev-facing by default, opt individual fields in with `expects ..., user_facing:` — stands. This work is purely **additive** and **opt-in**; it never sniffs "am I in an adapter" and never globally reclassifies inbound validation.

## Architecture: two layers

The design splits cleanly into a framework-general lower layer and a tool-specific upper layer:

1. **Core (general, per-call gates).** The executor gains per-call gates carried on an execution-context object (`IsolatedExecutionState`, the same pattern as `Async::CurrentRetryContext`) — so nothing rides on `.call`'s kwargs and there is no collision with user field names. These gates are framework-general behaviors, not tool concepts.
2. **Tools (the profile).** `Axn::Tools::Invoker` — a small value object holding an adapter's chosen profile. Its `#call(axn_class, args, ambient_context:)` sets the core gates for that one invocation, applies the reserved-key guard, runs `.call`, and returns a plain `Axn::Result`.

The public surface added to `Axn::Result` is **nothing**. Detection and per-field detail already live on the exception (`result.exception`), which is already public.

## Part 1 — core per-call gates

A per-call options object (working name `Axn::Internal::CurrentCallOptions`, an `IsolatedExecutionState`-backed current-attributes holder with a `with(**opts) { ... }` block API that saves/restores the prior value). The executor reads it at inbound-validation time. Three gates:

### 1a. `coerce_input_types` (per-call override of the existing setting)

`coerce_input_types` already exists as an overridable setting (PRO-2884); the executor reads it at `_collect_contract_failures` (executor.rb:505) and applies `_with_effective_coerce` to every coercible typed field lacking an explicit `coerce:`. This gate adds a per-call layer above the class/global resolution: the effective value becomes `per_call.nil? ? Configuration.resolve_override_for(@action_class, :coerce_input_types) : per_call`. Tools only ever set it to `true`, so a simpler `per_call || resolve_override_for(...)` is equivalent, but the explicit-nil form documents that per-call is a distinct layer.

**Precedence (unchanged mechanics, one new layer):**

1. Field-level explicit `coerce: true/false` — always wins. `_with_effective_coerce` already returns a field's validations untouched when its `type:` hash carries a `:coerce` key, so a field can opt out of coercion (`coerce: false`) even under a tool invocation.
2. Per-call gate (set by the invoker) — forces whole-action coercion on for the invoker's path.
3. Class-level `coerce_input_types` — governs the direct `.call` path.
4. Global default.

The class/global setting therefore keeps its full value: it governs the **direct** `.call` path (which coexists with the tool path — a tool class is commonly also callable directly), and it remains the general switch for non-tool stringly-typed boundaries (CLI/Thor/Rake args, HTTP `params`, CSV/ETL cells, ENV-driven config). Tools are simply one more such boundary — one that always wants coercion, so the invoker opts in on the author's behalf.

### 1b. `user_facing_input_errors` (downgrade the whole inbound contract to user-facing)

When set, `_validate_inbound!` composes **every** failing config's message as user-facing and settles the `InboundValidationError` as a non-reported failure — no new classification concept, just the existing `user_facing` settling applied contract-wide for one call. Today `_validate_inbound!` (executor.rb:474) raises the dev-facing aggregate unless `mismatches.empty? && failures.all? { |f| _failure_fully_user_facing?(f) }`; with this gate set, it composes and raises `_composed_user_facing_error(failures)` unconditionally (model-consistency mismatches included in the composed message). The resulting `InboundValidationError` is `user_facing?`, so the executor routes it to the failure bucket (no `on_exception`), and `result.error` carries the composed per-field sentence via the existing `_user_provided_error_message` path (result.rb:210).

The name mirrors `expects ..., user_facing:` — this is the tool-invocation analog applied to the whole contract. It conveys both halves the behavior actually has (downgrade-to-failure **and** attach-the-message); a plain "downgrade to failure" framing would read like `fails_on`, which downgrades but leaves `result.error` generic.

Default off. Only inbound violations are affected — a `fail!` in the body, an outbound violation, or a genuine `StandardError` all behave exactly as today (real bugs still page), satisfying the acceptance criterion that genuine unexpected exceptions report exactly as before.

### 1c. `reject_undeclared_inputs` (treat unknown top-level keys as a normal inbound error)

axn stores all provided kwargs and silently ignores undeclared ones (`Context` keeps them; this is necessary in some contexts). When this gate is set, undeclared **top-level** keys become normal inbound validation errors, flowing through the *same* aggregation and (with 1b also set) the same user-facing composition — so an unknown argument surfaces to the model identically to a type/enum violation.

Implementation: in the inbound collection pass, compute `undeclared = provided_data.keys - declared_top_level_fields - framework_reserved_input_keys` and add one error per undeclared key (message: `"unknown input: <key>"`). `declared_top_level_fields` is the set of `internal_field_configs` fields; `framework_reserved_input_keys` is the set of keys the contract recognizes beyond declared fields — currently `:ambient_context` (the reserved always-present parent, ambient_context.rb). The check is **top-level only**: nested keys inside a Hash field are not the top-level contract's concern (an undeclared-subfield policy is out of scope). These errors classify as inbound (user-facing under 1b) and aggregate with the rest.

Default off. This is the opt-in that lets an adapter give the model "unknown input: foo" feedback that the shallow pre-check used to provide, without re-implementing schema depth.

### Public setter for the gates

The gates are framework-general, but for this ticket the **only** sanctioned public way to set 1b/1c is via `Axn::Tools::Invoker` (below). `coerce_input_types` retains its existing class/global setter. We deliberately do **not** add class-level DSL for `user_facing_input_errors` / `reject_undeclared_inputs` now (YAGNI); exposing them per-class later is additive if a real non-tool need appears.

## Part 2 — surfacing (no `Axn::Result` changes)

Detection and detail both come off the already-public exception, so `Axn::Result` — used everywhere, not just by tools — gains nothing (and avoids any risk of shadowing a user's `exposes :input_errors`).

- **Detection:** `result.exception.is_a?(Axn::InboundValidationError)`. `Axn::InboundValidationError` is already a public top-level constant. The predicate is **mode-independent**: true whether the violation was reported as a bug (normal `.call`) or downgraded to a user-facing failure (tool mode). The gate changes reporting and `result.error`'s message, not what the exception *is*. Outbound violations (`OutboundValidationError`) are a different class and are correctly excluded — a bad *output* is always a bug.
- **Composed message:** `result.error` (already the per-field sentence in user-facing mode).
- **Structured per-field detail:** `InboundValidationError#errors` is already an iterable `ActiveModel::Errors`. Add one convenience **on the exception** (its natural owner, a low-traffic class): `InboundValidationError#field_errors → [{ field:, message: }]`, mapping `errors` via `{ field: e.attribute, message: e.full_message }` (`full_message` so each entry is standalone-readable; base-level errors surface with `field == :base`).
- **Optional tool-namespace sugar:** `Axn::Tools::Invoker.input_invalid?(result)` wraps the `is_a?` check, so adapters need not name the exception class directly and the tool concern stays in the tool layer.

## Part 3 — `Axn::Tools::Invoker`

A small value object (class, not a bare method) that owns the per-adapter profile, the reserved-key guard, and the set/clear-gates dance, and returns a plain `Axn::Result` so downstream result-mapping is unchanged. It is a class for cohesion and independent testability (not for speculative flexibility): an adapter constructs one with its profile and reuses it at its single call site.

```ruby
module Axn
  module Tools
    class Invoker
      NOT_SET = Object.new.freeze

      # axn framework-reserved input keys that untrusted (model-supplied) args may not set.
      # Currently just :ambient_context. NOT server_context — that is an mcp transport concept
      # the mcp adapter extracts itself and passes in as the trusted ambient_context below.
      RESERVED_INPUT_KEYS = %i[ambient_context].freeze

      def initialize(user_facing_input_errors: false, reject_undeclared_inputs: false)
        @user_facing_input_errors = user_facing_input_errors
        @reject_undeclared_inputs = reject_undeclared_inputs
      end

      # args: the untrusted, model-supplied argument hash.
      # ambient_context: the adapter's OWN trusted ambient context (optional) — merged after the guard.
      def call(axn_class, args = {}, ambient_context: NOT_SET)
        clean = args.reject { |k, _| RESERVED_INPUT_KEYS.include?(k.to_sym) }
        clean = clean.merge(ambient_context:) unless ambient_context.equal?(NOT_SET)

        Axn::Internal::CurrentCallOptions.with(
          coerce_input_types: true,                              # always on for tools
          user_facing_input_errors: @user_facing_input_errors,
          reject_undeclared_inputs: @reject_undeclared_inputs,
        ) do
          axn_class.call(**clean)
        end
      end

      def self.input_invalid?(result) = result.exception.is_a?(Axn::InboundValidationError)
    end
  end
end
```

**Profile knobs / defaults:**

| knob | default | current adapters |
|---|---|---|
| coerce inputs | **on for all tools** (not a knob) | on |
| `user_facing_input_errors` | off | ruby_llm + mcp → **on** |
| `reject_undeclared_inputs` | off | opt-in per adapter |
| reserved-key guard (`ambient_context`) | **always on** (untrusted args) | — |

"Configurable per adapter" means each adapter constructs its invoker with the profile it wants; a future adapter (event consumer PRO-2938, OpenAPI PRO-2936) picks its own — an event consumer that *wants* to page on a malformed payload simply does not set `user_facing_input_errors`.

**Reserved-key guard vs normal calls:** direct `ambient_context:` passing stays a valid override for normal `.call` (unchanged — ambient_context.rb resolution honors an explicit kwarg). The guard lives *only* in the invoker: model-supplied args can't set `ambient_context`, forcing the ambient-resolution pipeline for tool calls. The adapter injects its own trusted `ambient_context:` through the `call` kwarg, which is merged *after* the guard strips any smuggled one.

## Downstream migration (separate PRs, adapter repos — not this PR)

Captured here for completeness; each lands in its own repo.

- **axn-ruby_llm** (`tool_adapter.rb`): delete `tool_argument_validator`, `schema_value_matches?`, `json_types_for`, and `JSON_TYPE_PREDICATES` (the shallow pre-check). Build one `Axn::Tools::Invoker.new(user_facing_input_errors: true, reject_undeclared_inputs: …)` in `build_tool_class`; in `execute`, call it and branch:
  ```ruby
  result = invoker.call(axn_class, args, **(ambient_context.equal?(NOT_SET) ? {} : { ambient_context: }))
  next({ error: "Invalid tool arguments: #{result.error}" }) if Axn::Tools::Invoker.input_invalid?(result)
  next({ error: result.error }) unless result.ok?
  # … existing payload serialization unchanged
  ```
  Keep `normalize_nullable_types` — that is schema wire-shape (Gemini `anyOf` nullability), not argument validation.
- **axn-mcp** (`invocation.rb`, `serializer.rb`): `Invocation.perform` keeps extracting `server_context` (its transport concern) and passes it as the trusted `ambient_context: { server_context: }` to `invoker.call(axn_class, rest, ambient_context: { server_context: })`; the invoker's guard subsumes the manual `ambient_context` reject in `rest`. Teach `Serializer.result_to_mcp_response` the `input_invalid?` branch so a contract violation maps to a clean "Invalid tool arguments" response rather than the generic error.

## Non-goals / scope guardrails

- Only **inbound** violations reclassify. `fail!`, outbound violations, and genuine `StandardError`s are untouched — they page/behave exactly as today.
- No global reclassification and no auto-detection of "tool context." Everything is explicit per-call via the invoker.
- No new `Axn::Result` public methods.
- No class-level DSL for `user_facing_input_errors` / `reject_undeclared_inputs` (invoker-only for now; additive later).
- Undeclared-input rejection is top-level only; a nested/subfield unknown-key policy is out of scope.

## Testing

Non-Rails `spec/` (the mechanism has no Rails dependency), mirrored into `spec_rails/` where model-consistency mismatches under `user_facing_input_errors` are involved (models need AR). Cover:

- **Core gates, direct `.call` with each gate set via `CurrentCallOptions.with` (unit-level):**
  - `user_facing_input_errors`: a type violation, an inclusion violation, a nested-subfield violation, a coerce failure, and a model-consistency mismatch each settle as a non-reported failure (`on_exception` does NOT fire — assert via a config `on_exception` spy), `result.ok?` false, `result.outcome` `failure`, `result.error` the composed per-field sentence, `result.exception` an `InboundValidationError` with `#field_errors` populated.
  - Gate **off** (default / normal `.call`): identical inputs still fire `on_exception` and surface the generic `result.error` — proving no change to normal semantics.
  - `coerce_input_types` per-call: a stringly `"42"` for `type: Integer` coerces and passes; a field with explicit `coerce: false` still rejects `"42"` even under the gate (per-field precedence); the class-level setting is unaffected on a direct call without the gate.
  - `reject_undeclared_inputs`: an undeclared top-level key produces an `"unknown input: <key>"` inbound error (and composes user-facing when 1b is also set); `ambient_context` and declared fields are exempt; nested unknown keys are NOT rejected. Gate off → undeclared keys silently ignored as today.
  - A `fail!` body, an `OutboundValidationError`, and a raw `StandardError` under all gates still behave as today (`fail!` → failure/no report; outbound → reported bug; StandardError → reported bug); `input_invalid?` is false for each.
- **`Axn::Tools::Invoker`:** reserved-key guard strips a smuggled `ambient_context:` from `args` while honoring an explicit trusted `ambient_context:` kwarg; profile flags map to the right gates; returns a plain `Axn::Result`; `Invoker.input_invalid?` true only for inbound violations. `coerce_input_types` is on regardless of the wrapped class's own setting; `CurrentCallOptions` is restored after the block (including on exception).
- **`InboundValidationError#field_errors`:** shape `[{field:, message:}]`, base-level errors surface with `field == :base`, empty when there are no errors.
