# Explicitly flag the sharp edge of method-calling expectations — Design

**Ticket:** [PRO-2898](https://linear.app/teamshares/issue/PRO-2898/axn-explicitly-flag-sharp-edge-of-method-calling-expectations)
**Builds on:** [PRO-2886](https://linear.app/teamshares/issue/PRO-2886/axn-extract-resolver-typeerrors-on-a-nested-array-in-a-dotted-subfield) (PR #162 — `Axn::Core::FieldResolvers::Extract` resolves dotted paths segment-by-segment, with arity/`source_location`-aware handling of arg-requiring readers)
**Audit set:** os-app, axn-mcp, axn-ruby_llm, data_shifter, slack_sender (the five known axn consumers, audited 2026-07-14)

## Context

`Axn::Core::FieldResolvers::Extract` resolves a subfield's value from its parent, one dotted segment at a time, re-dispatching on the type reached at each step. It has two mechanisms:

* **Key/member read** — the parent responds to `dig` and is not an Array (`Hash`, `HashWithIndifferentAccess`, `Struct`, `OpenStruct`): the segment is used as a **key/member index** (`dig(segment)`). Also `Data`, which today falls through to the method branch (see below) but is conceptually a member read.
* **Method dispatch** — anything else (`Array`, plain PORO, `Data`): the segment is used as a **method name** and invoked via `public_send(segment)`.

The method-dispatch branch is what makes `expects "items.count", on: :payload` reach `Array#count`, and what makes `expects :data, on: :event` reach `event.data`. It is powerful — you can contract on *derived/computed* properties, not just stored data — but it is sharp in three ways the type system can't see:

1. **Side effects.** `public_send` will call *any* zero-arg public method the segment names. Nothing distinguishes a pure reader (`count`, `data`) from a mutating or computing one (`pop`, `checkout!`). Resolution runs during inbound validation, so a mis-aimed subfield can mutate caller state *while validating it*.
2. **No wire representation.** A method result has no JSON-schema form, so a method-based subfield is meaningful only to an in-process Ruby caller; [PRO-2883](https://linear.app/teamshares/issue/PRO-2883/axn-design-spike-subfieldtree-as-the-canonical-resolved-subfield) already drops-and-warns such paths in reflection. The value is silently absent from `input_schema`.
3. **Silent, spelling-dependent divergence.** Whether a segment is a key or a method depends on the runtime type of the parent, so the same field name can mean two different things.

The framework cannot tell a benign method read from a dangerous one, so today it silently does whatever `public_send` does. This design makes method dispatch an **explicit opt-in**, so the safe default is "read declared data" and reaching for behavior is a conscious, greppable choice.

## Audit — why a hard break is viable

Every known consumer was audited for subfield declarations (`on:` kwarg or dotted-string field name) that resolve via method dispatch rather than a key/member read:

* **data_shifter, slack_sender** — zero subfield declarations at all.
* **axn-ruby_llm** — 2 subfields, both Hash-key reads off `ambient_context`.
* **axn-mcp** — 18 subfields, all Hash-key reads (`on: :ambient_context` — `ambient_context` is always the Hash `{ server_context: … }` built at `invocation.rb:31`) or `Data`-attribute reads (array-element shape blocks over `Data.define` records). The `MCP::ServerContext` method_missing object is only ever the *value* returned by a key read, never itself a resolution parent — no `on: :server_context` exists.
* **os-app** — exactly **one** sharp production usage: `lib/event_handlers/loans/base.rb:8`, `expects :data, on: :event`, where `event` is a `RubyEventStore::Event` exposing `data` via `attr_reader` (no `dig`/`[]`), plus its spec scaffolding. Everything else reads `JSON.parse` Hashes or uses the Model resolver's `[]`.

One production line, in pre-alpha, all consumers owned in-org. That is few enough to hard-break now — gate the sharp path with no deprecation window — and migrate os-app's one line in the in-flight PR, rather than carry a deprecation warning. Cleaning it up before axn goes public is worth the effort.

`event.data` is instructive: it is a benign, side-effect-free `attr_reader`, exactly the read we'd *like* to keep implicit. But a plain-object `attr_reader` is not distinguishable from a computed/mutating method by any clean reflection predicate (no `.members`; `attr_reader` methods aren't tagged; `parameters`/`source_location` look identical to any zero-arg method). An ivar-name heuristic (`obj.instance_variables.include?(:@data)`) could bless it, but that reintroduces exactly the fuzzy heuristic the PR #162 review worked to remove. So `event.data` correctly lands on the sharp side and opts in explicitly.

## The seam (organizing principle)

The safe/sharp boundary is one crisp axis:

> **Is the segment name used as DATA (a key/member lookup) or as BEHAVIOR (a method to invoke)?**

To make that axis honest at the mechanism level (not just at the usage surface), the safe path must never invoke the segment as a method. `Data` is the one wrinkle: it isn't diggable, so today its member reads go through `public_send`. But `Data#to_h` gives member access with no method dispatch — `d.to_h[:zip]` is a member lookup; a *behavioral* method (`d.computed`) is not in `to_h` and so misses. So safe `Data` member reads move to `to_h[member]`, and only genuinely behavioral calls remain on `public_send`.

| Source | Segment used as | Path | `method_call:`? |
| -- | -- | -- | -- |
| Hash / HashWithIndifferentAccess | key | `dig(segment)` | no |
| Struct / OpenStruct | member | `dig(segment)` | no |
| `Data` — declared member | member | `to_h[member]` | no |
| `Data` — behavioral method | method | `public_send` | **yes** |
| Array method (`items.count`) | method | `public_send` | **yes** |
| PORO / `attr_reader` (`event.data`) | method | `public_send` | **yes** |

## Design

### 1. Safe path — segment as key/member

`resolve_segment` resolves a segment as data whenever it can:

* `source.respond_to?(:dig) && !source.is_a?(Array)` → `source.with_indifferent_access.dig(segment)` (or `source.dig(segment)` when not indifferent-capable), exactly as today (per-segment `#dig`, nil-safe for absent Struct members).
* `source.is_a?(Data) && source.class.members.include?(segment.to_sym)` → `source.to_h[segment.to_sym]`. A member read, no method invoked.

Neither invokes the segment as a method. A `nil` intermediate still reads as absent ([PRO-2857](https://linear.app/teamshares/issue/PRO-2857/axn-nilabsent-subfield-parent-raises-bare-runtimeerror-instead-of)).

### 2. Sharp path — segment as method, gated by `method_call: true`

Any remaining `source.respond_to?(segment)` case (Array methods, PORO methods, `Data` behavioral methods) is method dispatch. It runs **only** when the subfield config carries `method_call: true`. When permitted, the dispatch keeps the PR #162 arity/`source_location` handling verbatim (required-arg gate before dispatch; a Ruby reader's own `ArgumentError` re-raises; only a core-C reader's arity failure classifies as unextractable).

When method dispatch is reached **without** the flag, that is a contract-configuration error, and it must be **loud, never silent**.

### 3. Failure mode — loud, never silent, at resolution time

Detection is **resolution-time only**. The declaration-time early-warning was considered and dropped: the *only* statically-detectable case is a subfield whose `on:` parent is declared `type: Array`, and catching just that one shape would make *when* a developer is notified inconsistent (that case at boot, every other case — e.g. an untyped `expects :event` object parent — at runtime) for little gain. So the gate fires uniformly at the first resolution that would method-dispatch without the flag. This surfaces immediately when that path runs — acceptable for a developer-configuration bug.

The "you forgot `method_call:`" failure must NOT flow through `UnextractableError`, because `FieldResolvers.extract_or_nil` deliberately swallows that to "absent" — a gated `event.data` would then validate against `nil` and silently change semantics. So the gate raises a **distinct** error class (working name `Axn::ContractViolation::MethodCallNotPermittedError`) that `extract_or_nil` does *not* rescue. It is a plain `ContractViolation` — deliberately *not* a `ValidationError` and *not* `user_facing:` — so the executor's `with_exception_handling` (`executor.rb:295-306`) classifies it as a bug, not a graceful failure: it falls to `trigger_on_exception`, firing the **global** `on_exception`, and `result.error` resolves to the default headline (`"Something went wrong"` / configured `error_headline`) rather than the raw message. The actionable text — the field, the parent's runtime class, and the fix (`method_call: true`) — rides on the exception's own `#message`, so it reaches developers via `on_exception`/logs while the end user sees only the generic `result.error`.

Implementation must-verify: no intermediate broad `rescue StandardError` in the subfield-resolution machinery (`resolve_parent`, validation) swallows the distinct error before it reaches `with_exception_handling`. The normal path routes through `extract_or_nil` (catches only `UnextractableError`), so a distinct class propagates — asserted by test.

### 4. DSL — `method_call: true`

A boolean subfield option on `expects`/`exposes`:

```ruby
expects :data, on: :event, method_call: true
expects "items.count", on: :payload, type: Integer, method_call: true
```

It means exactly "resolve this segment by invoking it as a method." It is honest now that the safe path only does key/member lookups, greppable, and collides with nothing (notably not with the async `enqueues_each … via: :id`, nor with axn's own `.call`). It is a per-expectation property — not a per-class/global config — because whether a given subfield reaches into behavior is a fact about that declaration.

### 5. Threading the flag to the resolver (implementation weight)

`method_call:` is a per-declaration option, but method dispatch happens per-segment inside `Extract`, which is invoked from ~10 sites — most via `FieldResolvers.extract_or_nil(field:, provided_data:)`, which today passes **no** options. The flag must reach the resolver at the sites where a config-bearing read can hit the sharp path:

* **Leaf subfield validation read** — `Validation::Fields#read_attribute_for_validation` (`validation/fields.rb:29`) already holds the config's `@validations`, so it can forward the flag.
* **Reader resolution + dotted single-call** — the generated-reader path and a dotted `"a.b.c"` (resolved in one `Extract` call) both have the config; the flag applies to the whole call.
* **Model resolution / facade reads** — config-bearing; forward the flag.
* **Generic ancestor hops** — `resolve_parent` (`contract_for_subfields.rb:42,60`) walks the parent chain via option-less `extract_or_nil` without a specific config. Default here is the **safe** path (no method dispatch); a mid-chain hop that would method-dispatch is itself a sharp declaration whose own flag governs it. This edge must be pinned against live code during implementation.

Mechanism: extend `FieldResolvers.resolve`/`extract_or_nil` with a `permit_method_call:` keyword (default `false`), thread it from the config-bearing call sites, and have `resolve_segment` consult it at the method-dispatch branch. The exact per-site edits are traced during implementation.

## Naming rationale

The flag is a **boolean**, not a value-form (`via: :method` / `resolve: :method`), because the set of things needing an opt-in is exactly one — method dispatch. The only future resolution mode considered, **positional index into an Array** (`items.0`), is unambiguously auto-detectable (`source.is_a?(Array) && segment =~ /\A-?\d+\z/`; Arrays have no integer-named methods, so no collision with method dispatch) and therefore needs no flag. With no sibling mode to host, a value-form would be speculative surface. `method_call:` was chosen over `via:`/`dispatch:`/`invoke:`/`call:` on a clarity-first, then terseness, rubric: `via:` is already taken by `enqueues_each` (Symbol attribute name, applied as `item.public_send(via)`) and reusing it for a mode toggle would overload one keyword; `dispatch:`/`method_dispatch:` are framework jargon; `call:` collides with axn's core verb; `computed:`/`derived:` collide mentally with `default:`.

## Rollout

1. Land the seam + `method_call:` in axn on a fresh branch off updated `main` (the branch this design was drafted on is already merged).
2. In the same rollout, update os-app's one production site (`lib/event_handlers/loans/base.rb:8`) and its spec scaffolding to add `method_call: true` — the canonical real-world test case.
3. Changelog: `[BREAKING]` — method dispatch in subfield resolution now requires `method_call: true`; the safe default reads declared data (Hash keys, Struct/OpenStruct/Data members) only.
4. Docs: document `method_call:` on the `expects`/`on:` subfield reference page, with a cross-reference near the async `via:` so the two "extract by calling a method" ideas are distinguished. Docs updates are a deliverable, not an afterthought.

## Non-goals / future

* **Positional index into Arrays (`items.0`)** — a separate, additive, non-breaking ticket. It belongs in the *safe* bucket (auto-detected, no flag). Structure the safe branch so a numeric-segment→index check drops in cleanly ahead of the method gate. Deferred open calls: whether to honor negative indices (`items.-1`), and confirming array-element index reads are schema-representable.
* **Gem-level "safe reader target" registration** — a vague future possibility (e.g. if reads *through* an opaque object like `MCP::ServerContext` ever become a real, pervasive pattern). No surface designed or built now; the only obligation is that nothing here forecloses adding it later (a registry check would slot in immediately before the method gate). It would bypass only the *side-effect* gate — a registered read still has no schema representation.
* **Changing `enqueues_each`'s `via:`** — considered and rejected as churn on shipped/documented DSL with no payoff.
* **Auto-detecting benign `attr_reader`s as safe** — rejected; no clean predicate, and heuristics were deliberately removed in the PR #162 review.

## Testing

* Extract resolver unit specs: safe reads unchanged (Hash key, Struct/OpenStruct member, `Data` member via `to_h`); sharp reads (`items.count`, `event.data`-shaped PORO, `Data` behavioral method) raise the distinct error without `method_call:`, and resolve correctly with it (preserving the PR #162 arity edges).
* Loud-not-silent guarantee: assert the gate error is NOT swallowed by `extract_or_nil` (an optional subfield does not read as absent; a required one does not report a spurious presence error), and that it propagates to `with_exception_handling` rather than being caught by an intermediate rescue.
* Failure presentation: a gated subfield without the flag yields `result.error` == the default headline (not the raw message) and triggers the global `on_exception` (not `on_failure`); the exception's `#message` carries the actionable fix.
* Integration: reader-vs-dotted parity from PR #162 continues to hold with `method_call: true`.
* os-app: its event-handler specs pass once `method_call: true` is added.

## Open questions

* Exact name of the distinct error class (`MethodCallNotPermittedError` is a working name).
