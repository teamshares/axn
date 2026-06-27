# Error message presentation: `call!` parity, header composition, and override ergonomics

**Ticket:** PRO-2820
**Status:** Design — decided. Implementation plan: `internal-docs/plans/2026-06-26-error-message-presentation.md`
**Builds on:** PR #109 (`2026-06-22-nested-error-semantics-design.md`)

## Context

PR #109 established one mental model for `Axn::Failure` ("this action called `fail!`") and added base-`error` prefixing, where a declared headline contextualizes an action's specific failure reasons. Three pieces of downstream feedback surfaced while implementing consumers (axn-ruby_llm, teamshares-rails) that all probe the *presentation* boundary the PR drew. This note collects them, records what was verified empirically against the merged code, and frames the decisions that are genuinely the maintainers' to make.

The unifying question across all three: **what does each observation channel carry — `result.error`, `result.success`, `Axn::Failure#message`, and a `rescue`d exception — and should they agree?** Today they deliberately diverge in ways that are defensible in isolation but add up to "behavior depends on how you called it," which is the exact unpredictability #109 set out to remove.

## Thread 1 — `call!` message parity

### Problem

`result.error` (non-bang path) is the prefixed, presentation-layer string. The raised `Axn::Failure#message` (bang path) carries the raw reason. So the *same* action, on the *same* failure, presents differently depending on whether you called `.call` or `.call!`:

```ruby
MyAction.call.error    # => "Couldn't sync user: email taken"
MyAction.call!         # raises Axn::Failure "email taken"   ← own base dropped
```

This is documented (`docs/usage/writing.md`, "result.error vs Axn::Failure#message") and asserted, so it is intentional — but at the top level there is no idempotency justification for it: the originating action *is* the resolving action, so its own declared base should apply. A consumer that does `rescue => e; flash[e.message]` (which they will) loses the context the action author declared. The new mental model the release promotes — "fail with a specific detail, trust the headline to add context" — actively encourages authors to rely on that headline, which makes its absence on the bang path a sharper footgun than it was pre-#109.

### Key correction: rawness is load-bearing only for *string re-prefixing*

It is tempting to call the asymmetry "load-bearing" because the raw reason on the exception is what lets each ancestor re-prefix without doubling. But that is an artifact of representing the prefix as a *flattened string*. If the framework reads a raw reason and applies the prefix at resolution time, the exception's *human-facing* `#message` can carry the prefixed form independently — the two consumers (the framework re-prefixing, vs. a human reading `#message`) simply want different things from the same accessor. Split them and the constraint disappears.

### Orthogonality #109 bundled

PR #109 fused two independent decisions:

1. **Transparent re-raise** — re-raise the *same* exception object, no wrapper, reported once. This is what fixed the "mysterious `Axn::Failure` wrappers in Honeybadger" and duplicate-report complaints.
2. **Raw `#message`** — the exception carries the unprefixed reason.

You can keep #1 and still stamp a presentation string onto `#message`. Stamping a message is not wrapping an exception — one object, one report, richer message. The wins #109 secured do not depend on the raw-`#message` choice.

### Proposed design

1. **Split raw from presentation on `Axn::Failure`.** Keep the raw reason as the internal source of truth (`raw_reason`), add a presentation slot, and `#message` returns `presentation || raw_reason || DEFAULT`.
2. **The framework reads raw, never `#message`.** `_user_provided_error_message` (`lib/axn/result.rb:182`) must read `exception.raw_reason`, not `exception.message`. This is the load-bearing change that keeps nested `.call` resolution idempotent — each ancestor re-prefixes the raw detail with its own base exactly once.
3. **`call!` stamps the resolving level's `result.error`.** It already has both `result.exception` and `result.error` at the raise point (`lib/axn/core.rb:36-41`), so the stamp is a one-line insertion — no lazy resolution, no running user blocks inside `rescue`:

```ruby
def call!(**)
  result = call(**)
  return result if result.ok?
  result.exception.__present_as(result.error) if Axn.owns_failure_exception?(result.exception)
  raise result.exception
end
```

Stamping is scoped to **Axn-owned failure exceptions** — `Axn::Failure` (from `fail!`) and user-facing `Axn::ValidationError`. Foreign exceptions reclassified via `fails_on` are never stamped (see "Ownership: which exceptions get stamped"). Because every `call!` boundary stamps *its own* `result.error`, the invariant becomes: **`X.call!` raises a Failure whose `#message == X.call.error`**, at every level — for the exceptions we own.

### The residual — can we fix it?

The residual: on the non-bang path, `result.exception.message` can show a stale framing while `result.error` shows the correct resolved form. It arises because stamping *mutates a shared exception object* while `result.error` is computed *per level* — one object cannot simultaneously reflect every level's distinct framing. Concretely: `outer` calls `inner.call!`; `inner.call!` stamps `"inner: detail"` and the exception bubbles; the top-level caller does `outer.call` (non-bang), so nothing re-stamps at the outer level; now `outer.call.error` resolves to `"outer: detail"` but `outer.call.exception.message` is still `"inner: detail"`.

Whether it is fixable depends on the Thread 2 choice, and that is the interesting part:

- **Under single-header (overwrite):** intrinsic. Each level wants its *own* base on the shared object, so they fight; the last stamp wins. The only "fix" is to pick which level wins and accept the others diverge. The cleanest variant is to **not stamp at all**, and instead make `#message` *lazily compute* the originating action's framing from `__originating_action` (stable, never stale, no mutation) — but that always shows the innermost framing, which breaks the `X.call! == X.call.error` invariant at outer levels. So under single-header, you trade the residual for a different divergence.
- **Under aggregation (Thread 2):** the residual largely *dissolves*. If the exception carries the raw leaf plus an append-only chain of pre-rendered header strings — each level appending its base as the failure bubbles — then both `#message` and `result.error` render the *same* chain, so they agree at every level. Append-only means no overwrite, so nothing goes stale. This also **merges stamping and aggregation into one mechanism**: there is no separate "stamp in `call!`" step; the chain is already on the exception, and `#message` just joins pre-rendered strings + leaf (no user blocks at read time, since each base is rendered when appended, in normal execution context).

So "can we fix the residual" is really "do we pick aggregation?" — if yes, it comes nearly for free; if no, it is a genuine tradeoff rather than a clean fix. This is a strong secondary reason aggregation is attractive (see Thread 2).

### Ownership: which exceptions get stamped (decision 3 — resolved)

The dividing line for the exception channel is **ownership**, not `fail!` vs `fails_on`. The user-facing presentation (`result.error`) is already uniform across both paths — the only divergence is what the *exception object* carries, and for a foreign exception that divergence is load-bearing.

| channel | `fails_on` (foreign exception) | `fail!` / user-facing validation (Axn-owned) |
|---|---|---|
| `result.error` | uniform user-facing presentation | uniform user-facing presentation |
| `result.exception` / rescued `#message` | the original **technical cause** (e.g. `"ECONNREFUSED …"`) | the resolved presentation (stamped) |

For `fails_on`, the exception's `#message` and `result.error` are *two genuinely different things* — a technical cause and a user-facing string. Rewriting the foreign `#message` would be **lossy** (destroys the debugging signal) and **wrong** (mutating an object we don't own). For `fail!` there is no separate technical cause — the author wrote one message — so stamping our own exception loses nothing.

**Rule:**

- **Stamp Axn-owned failure exceptions only** — `Axn::Failure` and user-facing `Axn::ValidationError` (this also satisfies the `user_facing` parity item). `#message` carries the resolved presentation.
- **Never rewrite a foreign (`fails_on`) exception's `#message`.** It keeps its technical cause. The user-facing message lives in `result.error`.
- **`result.error` is the uniform user-facing channel** for all of them. Documented guidance: "for display, read `result.error`; an exception's `#message` is its most authentic identity — technical cause for foreign exceptions, the authored/prefixed message for `fail!`."

**Future-proofing (build nothing now):** if rescue-time access to the resolved message off a *foreign* exception is ever needed, the only correct mechanism is **additive** — a side channel like `Axn.error_message(e)` that returns the resolved string while leaving `#message` (the technical cause) intact. Overwriting `#message` is permanently off the table for foreign exceptions. We ship the documented "use `result.error`" answer now; the additive accessor stays the upgrade path.

## Thread 2 — header composition: single vs. aggregate

### The real fork

Given a nested failure, what is the canonical `result.error`?

- **Single header (today):** each resolving level applies only *its own* base to the leaf detail. `outer.call.error` => `"outer header: leaf detail"`; intermediate headers are dropped.
- **Aggregated chain:** the failure carries the raw leaf plus an ordered chain of headers, each level appending its base as the failure bubbles. `"outer header: inner header: leaf detail"` — a sentence of narrowing scope.

### `call!` is already the odd one out

`step` and the explicit `.call` + interpolate idiom **already aggregate** — that is exactly why the spec shows `"Onboarding failed: charging: Charge failed: card declined"` (the outer interpolated the child's *resolved* `result.error`, which already carried the child's own header). So today's state is not "headers don't aggregate" — it is "headers aggregate everywhere except `call!`." That is the same family of inconsistency as Thread 1: behavior diverging by which tool you reached for.

### Argument for aggregating `call!`

- Removes the `call!`-vs-`step` divergence — one mental model: nesting composes headers, however you nest.
- Matches the release premise (each layer adds its specificity); the chain reads as a causal path, not just the outermost framing.
- Orthogonal to the single-report / no-wrapper guarantees — a header chain is accumulated metadata, not an exception wrapper.
- No double-prefixing: a *chain* (list) appended once per level is idempotent by construction, unlike re-prefixing a string.

### Argument against (plainly)

Every layer that declares a base adds another segment to the message. With specific headers and shallow nesting that reads as a helpful trail, but headers are often generic ("Sync failed", "Operation failed"), and aggregation concatenates them all — "Sync failed: Operation failed: timeout" — burying the leaf detail, the only part that says what actually happened, behind a stack of vague prefixes. Single-header guarantees the message is exactly "the header of the boundary you called, plus the detail": short and predictable no matter how deep the internals nest. Aggregation also makes the user-facing string depend on *private* implementation details — how many intermediate axns happen to declare a base — so refactoring an internal action (adding or removing a base) silently changes the message a caller sees. Single-header keeps presentation a function of only the level you called, so internal refactors don't leak outward.

In practice, though, this concern is weak today: nesting is rarely deeper than one level (os-app has the most cases — at most an axn that wraps a client call being itself called inside another axn). The verbosity/leakage problem is real only for deep chains we don't actually build yet, which is why the consistency argument currently wins.

Other counts against:

- Walks back a just-shipped deliberate decision (`call!` = transparent re-raise, identical to top-level); wants the original author's eyes.
- Mechanism change: each level *appends its base to a chain* as the failure propagates — the executor's failure path becomes the accumulation point, not just lazy resolution at `result.error` read time. (This is the same mechanism that dissolves the Thread 1 residual.)
- A coherent philosophy keeps `call!` a strict control-flow primitive you match on by type/raw reason and never display — but Thread 1's decision to stamp `#message` already erodes that stance.

### Opting out of a caller's prefix — no new API

Sometimes an outer action needs a base for its own failures but wants one specific nested call surfaced *without* its prefix. This is already expressible — no new sugar required:

- **Drop the base** if it isn't wanted at all (coarsest — suppresses the prefix for every failure of that action).
- **Per call site:** `r = inner.call; fail!(r.error, prefixed: false) unless r.ok?`. Verified to surface the inner's own resolved message ("Inner base: leaf detail") with the outer base suppressed, and it works regardless of the single-vs-aggregate choice. This is the same idiom `step` uses.

We considered sugar (`without_message_prefix { inner.call! }` or a `call!` kwarg) for the niche where you want `call!`'s *transparent re-raise* (same exception object, `fails_on` stickiness, report-once) *and* prefix suppression. **Decision: drop it.** The idiom above covers the need; a `call!` kwarg would also collide with the inner action's input namespace (the hazard that made `prefixed` a reserved exposure in #109). Document the two options instead.

### Decision: aggregate. Data model and the per-segment delimiter rule

We are going with aggregation. The concrete model:

The failure carries the raw **leaf** reason plus an append-only chain of `(headerText, delimiter)` pairs. As the failure bubbles, each level that has a non-opted-out base resolves it *at that level* (in execution context, so block bases run where their context is valid) and contributes one pair. Both `result.error` and `#message` render by folding the chain over the leaf — and because the header text is pre-rendered when appended, the read-time render is a pure string join (no user blocks execute during `rescue`).

**Delimiter is per-segment, not global.** Today `delimiter:` is a property of the base and governs how it joins to its reason (`resolver.rb:77`). The chain generalizes this: each level's delimiter governs how *that level's header* attaches to the segment immediately below it (the next header, or the leaf). No global delimiter, no conflict.

```
A (delimiter: ": ")  →  B (delimiter: " > ")  →  C (delimiter: " | ")  →  fail!("leaf")
chain = [("A", ": "), ("B", " > "), ("C", " | ")], leaf = "leaf"
render = "A" + ": " + ("B" + " > " + ("C" + " | " + "leaf"))  =>  "A: B > C | leaf"
```

Each level stays self-consistent: `A.call.error => "A: B > C | leaf"`, `B.call.error => "B > C | leaf"`, `C.call.error => "C | leaf"`. At a single level it is identical to today's `with_base_prefix`, so this is a strict generalization — no change to the non-nested case.

Edge cases, all under the same rule:

- **No base at a level** → no pair contributed (skipped).
- **`prefixed: false`** → that level's header is omitted from the chain (existing opt-out, now per-segment).
- **Block base** → rendered at its own level, stored as `(renderedText, declaredDelimiter)`.
- **`delimiter: ""`** → honored per-segment (no separator at that join).
- **Multiple headlines at one level** → resolved to one pair via the existing within-level fallback logic, then folded across levels.

### Implementation risk to scope

`step` already aggregates by interpolating the child's `result.error` into a new `fail!` — its leaf is *already* the composed child string. Auto-accumulation must not double-count: a `step`-created failure's leaf already contains the child chain, so only the parent's pair should be appended. Spec coverage must pin the `step` + `call!` interaction explicitly.

### How it composes with Thread 1

These decisions stack cleanly and in order: Thread 2 defines what `result.error` *is* in a nested failure (the folded chain); Thread 1's stamping mirrors it (and the append-only chain dissolves the Thread 1 residual — `result.exception.message` renders the same chain as `result.error` at every level). So Thread 2 was the real fork, and Thread 1 follows it.

## Thread 3 — inheritance override and `prefixed: false` (verified working)

### Finding: subclass header override already works — no resolution change needed

A subclass overriding an inherited base works today, for both literal and context-derived dynamic headers, with copy-on-write isolation (the parent is not mutated) and inheritance to grandchildren. This is documented intended behavior (`docs/usage/writing.md:296`, "the last-declared one wins"): the subclass's `error` prepends onto the inherited registry (`lib/axn/core/flow/handlers/registry.rb:19`), so it is "most recent" and wins; the base is found by *shape* (unconditional `error`, literal or block), so position does not matter.

```ruby
class Parent
  include Axn
  error "tool call failed"
  def call = fail!("rate limited")
end

class LiteralOverride < Parent
  error "RubyLLM tool failed"            # => "RubyLLM tool failed: rate limited"
end

class DynamicOverride < Parent
  expects :tool_name
  error { "#{tool_name} tool failed" }   # => "weather tool failed: rate limited"
end
```

### Footgun to document (the one real action item for Thread 3)

An unconditional `error` *block* is classified as the base/headline and is invoked **with the exception**. If a header block restates the failure reason, it doubles:

```ruby
error { |e| "dynamic: #{e.message}" }   # => "dynamic: rate limited: rate limited"
```

The rule: **a header describes the action/class, not the failure reason** — derive it from action context (`tool_name`, config), never from the exception argument. This belongs in the docs near the override guidance.

### The teamshares-rails / `teamshares_api/base.rb` case

The reported "can't override the headline" was really the inverse: a `ServerError` catch-all acting as a de-facto default that the three specific messages were never expressed to compete with. The clean #109-native fix expresses the default as a base and the specifics as `prefixed: false` reasons:

```ruby
error "Something went wrong. Please try again."                                            # base = default for ANY failure
error "Please sign in again.",                       if: AuthorizationError, prefixed: false
error "You don't have permission to access this.",   if: ForbiddenError,     prefixed: false
error "That item wasn't found.",                     if: NotFoundError,      prefixed: false
# (drop the ServerError catch-all — the base now covers it, and more)
```

Verified against the resolver:

```
401 Authorization  => "Please sign in again."
403 Forbidden      => "You don't have permission to access this."
404 NotFound       => "That item wasn't found."
500 ServerError    => "Something went wrong. Please try again."
fail!/validate!    => "Something went wrong. Please try again."
```

Notes:

- `prefixed: false` is **mandatory, not stylistic.** This is exactly the static-base + conditional-reason pairing the #109 CHANGELOG flagged as behavior-changing — without the opt-out, the polished strings become `"Something went wrong. Please try again.: Please sign in again."`. So the fix lands only in lockstep with the #109 bump, and must not be "simplified" later.
- This is a **pre-existing bug**, independent of the alpha-5 validation.
- **Separate axis — bucket classification.** For 401/403/404 to resolve their messages *and* not be reported to Honeybadger as bugs, they need `fails_on`. The message resolves either way, but reporting expected client errors as bugs is its own noise problem; confirm `base.rb` already classifies them, or fold it in.
- This is the concrete instance of Thread 1's open gap: the polished strings live only in `result.error`; a `rescue`d `AuthorizationError` carries its original message, and Thread 1's `Axn::Failure`-only stamping would not reach it.

## Decisions for maintainers

1. **Thread 1 — stamp `call!`'s `#message` with `result.error`? — DECIDED: yes.** The raw/presentation split makes it safe. The residual is **resolved by decision 2**: aggregation's append-only chain renders identically for `#message` and `result.error` at every level, so there is no stale framing to document.

2. **Thread 2 — aggregate the header chain, or stay single-header? — DECIDED: aggregate.** Replaces the accidental "outermost-only" behavior with a coherent rule, unifies `call!` with `step`, and dissolves the Thread 1 residual. Verbosity is the main counter and is weak while nesting stays shallow; `prefixed: false` is the per-layer opt-out. Data model and per-segment delimiter rule are specified under Thread 2. Implementation risk to scope: the `step` double-count interaction.

3. **Exception path — DECIDED: ownership-based, document "use `result.error`."** Stamp only Axn-owned exceptions (`Axn::Failure`, user-facing `Axn::ValidationError`); never rewrite a foreign (`fails_on`) exception's `#message` (it keeps its technical cause). `result.error` is the uniform user-facing channel. No side channel built now; if ever needed for foreign exceptions it must be additive (`Axn.error_message(e)`), never a rewrite. See "Ownership: which exceptions get stamped."

4. **Thread 3 — no decision needed; document.** Override already works. Add the "a header describes the action/class, not the failure reason" footgun callout and the `base + prefixed: false` default-with-overrides pattern to `docs/usage/writing.md`.

## Appendix — reproduction

Scripts used to produce the empirical results above live in the session scratchpad (`inherit_test.rb`, `block_test.rb`, `ctx_header.rb`, `api_base.rb`); each runs against `lib/` directly with `include Axn`. Re-run before relying on any result if the resolver changes.
