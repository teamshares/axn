# Axn::Extensions namespace + best_effort helper + top-level shrink (PRO-2950)

/ Linear: https://linear.app/teamshares/issue/PRO-2950

## Problem

Every axn-* sibling gem needs axn-core's dev-loud/prod-quiet guard for best-effort side effects (hooks, callbacks, observability, a reporter that itself throws). Today that guard lives at `Axn::Internal::PipingError.swallow` — and `Internal::` signals "private, don't depend on this," so each sibling re-rolls a shim (axn-webhooks currently ships `Axn::Webhooks.swallow_soft_error`). There is no sanctioned surface for gems building *on* axn.

Separately, the top-level `Axn::` namespace mixes genuinely-public constants with runtime machinery (`Executor`, the context-facade family). As each sibling gem claims an `Axn::<GemName>` slot, keeping the top level to public API + namespace modules lowers collision/confusion risk.

## Decisions (settled during brainstorming)

The Linear description proposed relocating `ClassMethods, NamespaceWriter, ClassConfigWriter, Settings, PerClassOverrides`. Audit found those already nested under `Axn::Configurable::` / `Axn::Core::` — that part is effectively done. The real top-level machinery is a different set; item 3 below re-targets it.

## Scope

### 1. Introduce `Axn::Extensions` — the extension-author surface

New file `lib/axn/extensions.rb`, module `Axn::Extensions`: the semi-public "for gems building on axn" surface, distinct from `Axn::Internal` (private) and the user-facing DSL. It holds:

- `Axn::Extensions.best_effort` (the promoted guard, see item 2).
- The extension-config registry, re-homed: the class `Axn::ExtensionConfig` becomes `Axn::Extensions::Config`, and the accessor `Axn.extension_config` becomes `Axn::Extensions.config`. `register_semantic_hint`, `registered_semantic_hints`, and the field-metadata-key registration stay as methods on that config object — downstream calls `Axn::Extensions.config.register_semantic_hint(...)`.

Chosen over `Axn::SDK` (reserved for a possible future curated, semver'd stability façade — a larger, more specific thing than a two-helper guard module) and `Axn::Support` (rejected in the ticket; `Extensions` names *downstream-extension* intent rather than "supporting core itself"). Note in the module doc: this is the extension-**author** API, not Ruby core-ext/refinements.

Core itself reads this registry (`semantic_hints.rb`, `contract.rb:802`) and calls `best_effort` ~20×; that dogfooding is expected. The name signals *why the surface is public* (so extension authors may rely on it), not that only extensions use it.

### 2. Promote the non-critical-error helper as `Axn::Extensions.best_effort`

Block form, naming the *intent* (not the swallow-or-raise outcome, since it can re-raise in dev):

```ruby
Axn::Extensions.best_effort("resolving webhook subscribers") { Subscription.urls_for(event) }
# runs the block; on StandardError -> log + swallow, EXCEPT re-raise in dev when the knob is set
```

- Signature: `best_effort(desc, action: nil, &block)`. `action:` stays (the warn target — an action instance or class responding to `:warn`, else `Axn.config.logger`). The body is the current `PipingError.swallow` logic verbatim (prod/test log, dev-raise when configured), moved into `Axn::Extensions`; the block runs inside a `rescue StandardError => e`.
- Chosen over `swallow_*` / `report_and_swallow` / `soft_error`: every action-verb name lies in the dev-raise case; `best_effort` describes *why* the code is guarded and is true whether it swallows or raises.
- Kills the manual `rescue => e; PipingError.swallow(...)` boilerplate at every call site.
- **No back-compat (alpha):** move the impl into `Axn::Extensions`, **delete** `Axn::Internal::PipingError` (and its file + dedicated spec), and update all ~20 internal call sites to the block form.
- Rename the config knob `raise_piping_errors_in_dev` → `best_effort_raises_in_dev` (public but alpha; rename freely). Update `configuration.rb`, `docs/reference/configuration.md`, `docs/reference/async.md`, the `batch_enqueue.rb` comment, and specs.
- While migrating, fix a latent inconsistency: `async.rb:125` passes `action_class:` to `swallow`, which the signature does not accept (`action:` only). The block form normalizes it to `action:`.

### 3. Shrink the top-level `Axn::` namespace

Relocate genuine runtime machinery under `Axn::Core` (structural — the action's execution/context machinery):

- `Executor` → `Axn::Core::Executor`
- `Context` → `Axn::Core::Context`
- `ContextFacade` → `Axn::Core::ContextFacade`
- `ContextFacadeInspector` → `Axn::Core::ContextFacadeInspector`
- `InternalContext` → `Axn::Core::InternalContext`

`Result` stays public at top-level and continues to inherit from the relocated base: `Axn::Result < Axn::Core::ContextFacade`. `InternalContext < ContextFacade` likewise. axn-mcp's only `Axn::Context` reference is a code comment (no runtime dependency), so this move is nearly free downstream.

Keep genuinely-public constants at top-level, unchanged:

- Return/rescue types: `Result`, `Failure`, and the exception classes (`ContractViolation` + nested, `DuplicateFieldError`, `ValidationError`/`InboundValidationError`/`OutboundValidationError`, `UnsupportedArgument`).
- Public helpers: `Factory` (`Axn::Factory.build`), `FormObject` (documented; `docs/reference/form-object.md`). os-app uses its own `TS::FormObject`, not `Axn::FormObject`, so `FormObject` is a documented public helper on the same tier as `Result`/`Factory` — not machinery — and stays put.
- Strategy registry: `Strategies`, `StrategyNotFound`, `DuplicateStrategyError` (user extension point + rescue targets).
- `Configuration` / `RailsConfiguration` stay top-level (Option 1). They are the concrete type behind the public `Axn.config` / `Axn.configure`; every alternative home is worse (`Core` dilutes its "class-assembly" meaning; `Configurable` collides with the existing `Configurable::Config` value class). Moving them does not reduce the `Axn::<GemName>` collision risk that motivates the shrink.
- Namespace modules: `Async`, `Configurable`, `Core`, `Extensions` (new), `Extras`, `FieldDeclarations`, `Internal`, `Mountable`, `Reflection`, `Testing`, `Tools`, `Util`, `Validation`, `Validators`.

Mechanical rename-and-update-refs pass across `lib/` and `spec/`; safe in alpha.

### 4. Document + reserve the namespace policy

In axn-core `AGENTS.md`: sibling gems own `Axn::<GemName>` (`Axn::Webhooks`, `Axn::MCP`, `Axn::RubyLLM`); core reserves its public constant list plus the module namespaces `Core` / `Internal` / `Async` / `Extensions` / `Tools` / `Reflection` / etc. Optional: a small spec asserting core's reserved top-level constants, so a future accidental clobber is caught.

### 5. Adopt downstream — OUT OF SCOPE for this PR

The three siblings (`axn-webhooks`, `axn-mcp`, `axn-ruby_llm`) are separate repos with their own in-flight release PRs and version pins, and this change deletes the old API outright. They cannot pin the new axn until it is released. So adoption lands as companion work in each sibling's own session after axn-core merges/releases: replace `Axn::Webhooks.swallow_soft_error` with `Axn::Extensions.best_effort`; adopt at axn-mcp / axn-ruby_llm best-effort points; update `Axn::Context` (comment) / `Axn::ExtensionConfig` → `Axn::Extensions::Config` references; bump the `axn` pin. This spec's deliverable for item 5 is a ready-to-paste prompt per sibling, produced at the end.

## Non-goals

- No behavior change to the guard itself (still log-in-prod/test, raise-in-dev-when-configured).
- Not grouping public errors under `Axn::Errors` (bigger blast radius; separate ticket).
- Not moving `Configuration`/`FormObject`; not introducing `Axn::Support`; not a broader public-helper regrouping.

## Testing

- `Axn::Extensions.best_effort` gets the dedicated spec (ported from `spec/axn/internal/piping_error_spec.rb`): swallows-and-logs in prod/test, re-raises in dev when `best_effort_raises_in_dev`, returns `nil` on rescue, block return value on success, `action:` warn-target routing.
- The shared `expect_piping_error_called` helper in `spec_helper.rb` is renamed/retargeted to the new API; all call-site specs updated to expect `Axn::Extensions.best_effort` (or unchanged behavior).
- Optional reserved-top-level-constants spec (item 4).
- Full suite green in both `spec/` (non-Rails) and `spec_rails/` (dummy app) — the constant moves touch load order.
