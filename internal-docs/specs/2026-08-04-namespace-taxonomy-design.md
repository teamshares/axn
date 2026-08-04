# Namespace taxonomy: Reflection membership, the Extensions boundary, and a rescuable error root (PRO-2997)

/ Linear: https://linear.app/teamshares/issue/PRO-2997

The ticket was written before PRO-3005, PRO-3018, PRO-3026 and PRO-3028 landed, and three of its four sections have moved under it. This spec records what is actually left, and what the audit found instead.

## What the ticket asked for, and what survived validation

| Ticket section | Status after validating against main |
| --- | --- |
| §1 `Axn::Reflection` membership | Half done by PRO-3028 (the whole namespace moved to `Axn::Internal::Reflection`). The membership question is real and now **cheap** — the expensive module stays put. |
| §2 `Axn::Extensions` boundary audit | **Nothing to move.** Every candidate on the list was resolved by an earlier ticket. The audit surfaced one genuine gap instead. |
| §3 Consolidate errors under `Axn::Error::` | Rejected as written. The real defect is not placement — it is that there is no way to rescue "an axn error," and six public classes inherit from `Axn::Internal`. |
| §4 A rule for adding to the reserved list | Already done at AGENTS.md:61–70. One line of it is falsified by §1 and needs editing. |

## §1 — Reflection membership

`Axn::Internal::Reflection` holds seven modules (PRO-2995 added `PropertyNames` after the ticket was written). Four of them are not reflection by any reading, and their callers prove it: nothing outside `Core::` and `Reflection::PropertyNames` touches any of the four.

| Module | Runs | Callers |
| --- | --- | --- |
| `Schema` | off the execution path, with one narrow foothold on it | the `input_schema`/`output_schema` projection; `ContractForSubfields`'s memoized `<field>_id` default check |
| `Values` | off the execution path | `Extensions::Serialization.render` |
| `PropertyNames` | declaration, plus narrow runtime footholds | `Schema`, the contract's declaration walk, the subfield-contradiction check; `CallLogger`, the executor's validation-failure messages, the shape validator |
| `Coercion` | **inside validation** | `Core::{contract, contract_for_subfields, executor}` |
| `SubfieldContradictions` | declaration | `Core::{contract_for_subfields, ambient_context}` |
| `SubfieldTree` | declaration + read path | `Core::ambient_context`, `Reflection::PropertyNames` |
| `ResolvedSubfields` | declaration + read path | `Core::contract_for_subfields` |

### Destinations, decided by AGENTS.md:63–67 rather than by taste

`Internal::Coercion` — the inbound wire→Ruby decoder is a value-level mechanism with no presence in the action's surface, which is exactly the `Internal::X` rule. It sits beside `ShapeGraph`, `Text` and `Rendering`. Splitting it from its encoder counterpart (`Reflection::Values.serialize_value`) reveals an asymmetry rather than creating one: the encoder renders output for adapters, the decoder runs inside validation, and they are genuinely different audiences. The shared class set that must not drift between them is stated in both headers, which is where that obligation belongs — a namespace never enforced it.

`Internal::SubfieldTree` and `Internal::ResolvedSubfields` — used by `Core::` **and** by `Reflection::PropertyNames`, so the `Core::Contract::X` test ("machinery one layer owns and that is meaningless outside it") fails on its own terms. Two layers means `Internal::X`.

`Core::Contract::SubfieldContradictions` — declaration-time validation of a contract, called only from `Core::`. Meaningless outside the contract layer, so this one does satisfy the `Core::Contract::X` test.

### Two corrections that ride along

`coercion.rb`'s module header claims the module is "Read-only, off the execution path" and that "adapters (bulk, by walking configs) both call this rather than reinventing it." Both are false: it runs inside validation from three `Core::` call sites, and no adapter calls it — verified across all four sibling gems. This is the same defect PRO-2992 corrected in the `Reflection` module doc one file over.

AGENTS.md:64 lists `SubfieldTree` as one of the modules that "derives a JSON view of a contract." This move falsifies that; the line becomes `Schema`, `Values`, `PropertyNames`.

### Cost

64 references across roughly 30 files. `Schema`, `Values` and `PropertyNames` account for 228 references and **do not move**, so the ticket's stated fear ("`schema_spec.rb` alone is ~5k lines") does not apply — that file is untouched.

Landed as two commits, per the repo convention: `git mv` plus require-path updates first, then constants and nesting. A rename that also re-indents defeats git's rename detection.

## §2 — The Extensions boundary

### The audit's answer is "nothing to move," and it is now provable

Every candidate the ticket listed was resolved by an earlier ticket:

| Ticket's candidate | Where it actually lives |
| --- | --- |
| `Axn.owns_failure_exception?` | `Extensions.owned_failure?` — already an Extensions member |
| `Axn.register_tool_adapter` | `Tools.register_adapter` (PRO-3005) |
| `input_schema` / `output_schema` | `Core::SchemaReflection` class methods on the action |
| `tool_name(:adapter)` | `Core::ToolDeclaration` class method on the action |
| `_semantic_hints`, `external_field_configs` | class methods on the action |
| `Tools::Invoker` | `Axn::Tools`, which is the adapter-facing namespace by design |
| `Configurable` + `config_namespace` | `Axn::Configurable`, extended onto each gem's own module |

Grepping executable Ruby across all six sibling gems, their in-flight worktrees, and the three apps confirms the ticket's own preamble more strongly than it was written. Three apparent reaches into `Core::` are **explanatory comments, not code**: axn-openapi naming `Core::Contract::RESERVED_FIELD_NAMES_FOR_EXPOSURES` in two spec comments, axn-webhooks naming `Core::Tagging.resolve` in one, axn-mcp naming `Core::Context` in one. No sibling gem reaches into a core namespace in code at all.

This finding is the deliverable for §2. Recording it is what stops the next person re-running the audit.

### The one genuine gap: host-app specs have no supported reset

The only real reach into a private namespace is teamshares-rails' spec suite doing ivar surgery on `Axn::Internal::Tracing` to clear a memoized tracer between examples. A supported seam is strictly less exposure than encouraging that.

The process-global state that actually survives an example:

| State | Seam today |
| --- | --- |
| `Internal::Tracing` — `@tracer_entry`, `@probe_entry` | `reset!` |
| `Async::Adapters::Sidekiq::AutoConfigure` — `@middleware_registered`, `@death_handler_registered` | `reset!` |
| `Core::NestingTracking` — `@_isolation_mismatch_warned` | none; needs one |
| `Tools::Registry` — `@adapter_sources` | `reset_adapters!` |

Two candidates were examined and excluded because they are **self-cleaning**: `Internal::ExceptionClassification` and `Internal::CarriedPresentation` both store in `ActiveSupport::IsolatedExecutionState` and are already reset by `NestingTracking` when the outermost action finishes. Resetting them from a spec hook would be theatre.

`Axn::Testing.reset!` drops that derived state and nothing else. The exclusions are load-bearing and belong in its docstring:

- **Not `Axn.config`.** A host app configures axn in an initializer. A suite-wide `before { Axn::Testing.reset! }` that reset config would silently un-configure every example after the first — a footgun that would present as unrelated failures deep in someone else's suite.
- **Not `Axn::Extensions.config`**, for the same reason.
- **Not the registries** (`Strategies`, `Async::Adapters`, `Mountable::MountingStrategies`). `clear!` restores built-ins and discards deliberate registrations, which is axn's own suite's business, not a host app's.

`Tools::Registry.reset_adapters!` folds in, which lets axn's own `spec_helper.rb:35` call `Axn::Testing.reset!` instead of the registry directly. The gem then dogfoods the seam and the covered list cannot drift from what the suite needs.

It lands in a new `lib/axn/testing.rb` rather than in `testing/spec_helpers.rb`, which today is the only file defining `Axn::Testing` and which exists to be `include`d into an RSpec config. A host app wanting the reset should not have to load RSpec-shaped helpers to get it, so `require "axn/testing"` gives `Axn::Testing.reset!` alone and `spec_helpers.rb` requires it. Both stay opt-in — `require "axn"` does not define `Axn::Testing` today, and that does not change.

`@classes` on `Tools::Registry` is deliberately **not** reset: it accumulates every action class ever defined, and clearing it mid-suite would make `Axn.tools_for` blind to classes that are still loaded.

## §3 — A rescuable error root, not a relocation

### What the inventory found

Loading the gem and walking every `Exception` subclass under `Axn::` gives 31 classes across **five unrelated roots**:

```
StandardError            → Failure, ContractViolation, UnreraisableException,
                           Internal::EarlyCompletion, Async::MissingEnqueuesEachError,
                           Async::Adapters::Sidekiq::ConfigurationError,
                           Internal::Registry::{NotFound, DuplicateError}
ArgumentError            → UnsupportedArgument, Mountable::MountingError,
                           Async::UnserializableArgument,
                           Extensions::Serialization::UnserializableValue
ContractViolation        → 8 nested, plus DuplicateFieldError, ValidationError,
                           Tools::InvalidContract
Internal::Registry::NotFound        → StrategyNotFound, Async::AdapterNotFound,
                                      Mountable::MountingTypeNotFound
Internal::Registry::DuplicateError  → DuplicateStrategyError, Async::DuplicateAdapterError,
                                      Mountable::DuplicateMountingTypeError
```

Two defects the ticket does not name. **Six public exception classes have an `Internal::` class in their public ancestry** — `Axn::StrategyNotFound.superclass` is `Axn::Internal::Registry::NotFound`, and that internal constant is the only way to express "any registry lookup miss." And **there is no `Axn::Error`**: a consuming app cannot express "catch anything axn threw."

Placement is not the defect. Gems own `Axn::<GemName>`, so exception constants at the `Axn::` root never collide with a future gem — §4's namespace-scarcity argument does not motivate §3 at all. And suffix uniformity is not achievable as a rule: Ruby core is mixed (`ArgumentError` beside `Interrupt`), as is Rails (`RecordNotFound` beside `StatementInvalid`). Renaming `InboundValidationError`, which has 141 call sites in os-app alone, to satisfy a suffix rule is pure cost.

### `Axn::Error` is a marker module, and the marker *is* the public boundary

```ruby
rescue Axn::Error => e   # catches InboundValidationError, UnsupportedArgument,
                         # Webhooks::RetryLater, MCP::SchemaError — everything public
```

`rescue` accepts a module and matches by `is_a?` (verified on 3.3.6), so a marker gives the root with no inheritance surgery. That matters twice over. Four core errors are deliberately `< ArgumentError`, and — the deciding reason for an extension-author surface — an adapter gem may need its base to be `< Faraday::Error` or `< Timeout::Error` for its own ecosystem's interop. A marker module is the only shape that lets a gem keep the superclass it needs *and* be catchable as an axn error. A base class forces that choice.

The three shapes the ticket and discussion floated, and why each loses:

- **`Axn::Error::Foo`, with `Error` as a namespace module** — actively harmful. `Axn::Error` is the name a user reflexively reaches for in a `rescue`; as a bare namespace it is legal there and matches nothing, so it fails silently rather than loudly. It also contradicts the gems, two of which already ship `Axn::Webhooks::Error` and `Axn::OpenAPI::Error` as classes.
- **`Axn::Errors::Foo`, plural** — safe but buys nothing. A plural container reads as un-rescuable, so a separate root is still needed: two concepts instead of one, prescribed against three existing gem precedents.
- **`Axn::Error` as a base class** — the idiomatic Ruby choice (`Faraday::Error`, `Octokit::Error`), and rejected only for the interop reason above.

The rule that makes the marker safe, and answers "won't this expose internal-only exceptions?":

> Every `Exception` subclass reachable under `Axn::` either includes `Axn::Error` — public, documented, rescuable, breaking to remove — or lives under `Axn::Internal` and does not include it.

Tagging is therefore the boundary *declaration*, not a blanket sweep. This is better than a namespace for the job because it is per-class and explicit rather than inferred from file location, and it is enforceable by a spec in the shape of `namespace_policy_spec.rb`. Today "which axn exceptions may I rescue?" has no answer; afterwards it is the marker's inclusion list, and the spec fails both on an untagged public error and on a tagged internal one.

One constraint to accept: the marker is inherited, so a tagged class cannot have an untagged subclass. That is healthy — a public error family should not have secretly-internal members.

### `Axn::Failure` is deliberately **not** tagged

`Failure` is a control-flow signal raised by `call!`, not a fault. Tagging it would make `rescue Axn::Error` around a `call!` catch the *intended* outcome (`fail!`) while still missing an unintended `NoMethodError` from the action body — a partial net whose partiality is the confusing part. Untagged, the three outcomes stay legible: `Axn::Error` means axn itself objected, `Axn::Failure` means the action deliberately failed, and anything else means the body blew up. A caller who wants all three writes `rescue StandardError`.

### The gem convention

```ruby
module Axn::Webhooks
  class Error < StandardError
    include Axn::Error          # the whole convention
  end
  class RetryLater < Error; end
end
```

Two of the three gems with error hierarchies already have that class and need only the `include`. axn-mcp has `SchemaError` with no base and should grow one.

### The three surgical changes

**Delete the `Internal::Registry::*` ancestry.** All three registries override both error classes (`strategies.rb:16-17`, `async/adapters.rb:18-19`, `mounting_strategies.rb:17-18`), and nothing in `lib/`, `spec/`, or any downstream gem or app ever raises or rescues `Internal::Registry::{NotFound, DuplicateError}`. They exist *only* as ancestors, and the ancestry is the leak. The six public classes become `< StandardError` with the marker; the two bases stay as the registry's own defaults, now genuinely unreachable. "Rescue any registry miss" is lost, which nothing does today and which `rescue Axn::Error` covers anyway. This closes the leak by removal rather than by coining a public name for an unused capability — the same doctrine as the tombstone convention.

**`Axn::DuplicateFieldError` → `Axn::ContractViolation::DuplicateFieldError`**, joining its eight siblings instead of sitting alone at top level.

**`Axn::UnreraisableException` → `Axn::ReraiseFailed`.** The current name describes the *original* exception (the one `raise` could not hand back) while the object it names is the *substitute*, so `rescue Axn::UnreraisableException` reads as "catch the exception that could not be re-raised" — precisely the thing that cannot be caught, because it was replaced. `Unreraisable` also stacks un- + re- + raisable, which CamelCase gives no help parsing. `ReraiseFailed` names what happened. `BestEffortError` was considered and rejected as misleading: `best_effort` did not fail, only the re-raise fidelity degraded.

## §4 — The reserved-list rule

Already stated at AGENTS.md:61–70, which the ticket predates. The only work is editing line 64 for §1's move, plus adding the `Axn::Error` rule from §3 and the exception-tagging invariant.

## Not doing

**Moving `Reflection::Schema`/`Values` into `Extensions`.** Recorded in the ticket as rejected and still rejected: adapters call them zero times, so filing them under "you may depend on this" re-creates PRO-2992's defect with the sign flipped.

**Relocating the public exception constants.** No namespace pressure justifies it, and rescue-by-name is a class of edit where a missed site is a silently-unrescued exception in production rather than a `NameError` at boot.

**Suffix uniformity across the exception classes.** Not achievable as a rule, and the most-rescued names downstream are the ones it would rename.

## Downstream

Nothing here breaks a sibling gem's *code*. Grepping executable Ruby across all six gems and three apps for each moved or renamed constant — `DuplicateFieldError`, `UnreraisableException`, `StrategyNotFound`, `DuplicateStrategyError`, `Async::AdapterNotFound`, `Async::DuplicateAdapterError`, `Mountable::MountingTypeNotFound`, `Mountable::DuplicateMountingTypeError` — returns **zero references to all eight**, and no gem reaches into a moved `Internal::Reflection` module either. The port work is additive, plus two pre-existing breaks this audit found:

- Every gem: add `include Axn::Error` to its base error class (axn-mcp needs the base first).
- axn-openapi references `Axn::Reflection::UnserializableValue` in `lib/`, in both its main checkout and the `clean-serialization` worktree. PRO-2992 already moved that constant to `Extensions::Serialization::UnserializableValue`; that gem is broken on its next bump independently of this ticket.
- teamshares-rails `spec/lib/axn/opentelemetry_integration_spec.rb:10-11` sets `@tracer` and `@tracer_provider` on `Axn::Internal::Tracing`. Those are not the real ivar names (`@tracer_entry`, `@probe_entry`), so **the setup is a silent no-op today** — the memo is never cleared. Replace with `Axn::Testing.reset!`.
