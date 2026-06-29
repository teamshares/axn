---
outline: deep
---

# How to _build_ an Action

The core boilerplate is pretty minimal:

```ruby
class Foo
  include Axn

  def call
    # ... do some stuff here?
  end
end
```

## Declare the interface

The first step is to determine what arguments you expect to be passed into `call`.  These are declared via the `expects` keyword.

If you want to expose any results to the caller, declare that via the `exposes` keyword.

Both of these optionally accept `type:`, `optional:`, `allow_nil:`, `allow_blank:`, and any other ActiveModel validation (see: [reference](/reference/class)).


```ruby
class Foo
  include Axn

  expects :name, type: String # [!code focus:2]
  expects :email, type: String, optional: true # [!code focus:2]
  exposes :meaning_of_life

  def call
    # ... do some stuff here?
  end
end
```

## Implement the action

Once the interface is defined, you're primarily focused on defining the `call` method.

To abort execution with a specific error message, call `fail!`. You can also provide exposures as keyword arguments.

To complete execution early with a success result, call `done!` with an optional success message and exposures as keyword arguments.

If you declare that your action `exposes` anything, you need to actually `expose` it — unless you're re-exposing a field you also `expects`, in which case axn auto-copies it for you (see below).

```ruby
class Foo
  include Axn

  expects :name, type: String
  exposes :meaning_of_life

  def call
    fail! "Douglas already knows the meaning" if name == "Doug" # [!code focus]

    msg = "Hello #{name}, the meaning of life is 42"
    expose meaning_of_life: msg # [!code focus]
  end
end
```

See [the reference doc](/reference/instance) for a few more handy helper methods (e.g. `#log`).

### Re-exposing an expected field (auto-copy)

When a field is declared with both `expects` and `exposes`, axn automatically copies it from the input into the result — no manual `expose` call needed. This works on **all outcome paths**: success, `done!`, `fail!`, and unhandled exceptions.

This is particularly useful when an action mutates an ActiveRecord object in-place (e.g. `user.valid?` populates `user.errors`) and the caller needs to inspect the object after a failure:

```ruby
class UpdateUser
  include Axn

  expects :user, model: true
  exposes :user               # auto-copied — no expose call needed

  def call
    user.assign_attributes(params)
    fail! unless user.save    # user.errors is available on result.user even on failure
  end
end

result = UpdateUser.call(user:, params:)
result.user.errors.full_messages  # populated on both ok? and !ok?
```

### Forwarding to a nested action (facades)

When an action is a thin facade over another — forwarding most inputs and re-exposing the child's outputs — use `inputs` to forward arguments and `expose(result)` to forward outputs:

```ruby
class Assignments::Create
  include Axn

  expects :user, :company, :role, :started_at, optional: true
  exposes :user, :employment, optional: true
  error "Unable to create assignment"

  def call
    result = Employment::AddEmployeeToCompany.call(**inputs) # [!code focus]
    expose(result)              # forwards (child's exposures ∩ this action's exposes) # [!code focus]
    fail! unless result.ok?     # a declared base `error` provides the message # [!code focus]
  end
end
```

- `inputs` is the resolved declared-inbound fields (defaults and preprocessing applied, and `model:` fields resolved to their record — even when supplied by `<field>_id`) as a Hash; fields whose resolved value is `nil` are omitted so a nested action still applies its own absent/default handling. Splat it, and use plain Hash methods to inject or drop fields: `Child.call(**inputs.except(:role), role: ROLE)`.
- `expose(result)` forwards the intersection of the child's declared exposures and this action's own `exposes`, and works even when the child failed (so an errors-bearing record the child exposed is still forwarded for form display). It raises `Axn::ContractViolation::NoMatchingExposures` if there is nothing in common to forward.

### Convenient failure with context

Both `fail!` and `done!` can accept keyword arguments to expose data before halting execution:

```ruby
class UserValidator
  include Axn

  expects :email
  exposes :error_code, :field

  def call
    if email.blank?
      fail!("Email is required", error_code: 422, field: "email")
    end

    # ... validation logic
  end
end
```

## Early completion with `done!`

The `done!` method allows you to complete an action early with a success result, bypassing the rest of the execution:

```ruby
class UserLookup
  include Axn

  expects :user_id
  exposes :user, :cached

  def call
    # Check cache first
    cached_user = Rails.cache.read("user:#{user_id}")
    if cached_user
      done!("User found in cache", user: cached_user, cached: true) # Early completion with exposures
    end

    # This won't execute if done! was called above
    user = User.find(user_id)
    expose user: user, cached: false
  end
end
```

### Important behavior notes

**Hook execution:**
- `done!` **skips** any `after` hooks (or `call` method if called from a `before` hook)
- `around` hooks **will complete** normally, allowing transactions and tracing to finish properly
- If you want code that executes on both normal AND early success, use an `on_success` callback instead of an `after` hook

**Transaction handling:**
- `done!` is implemented internally via an exception, so it **will roll back** manually applied `ActiveRecord::Base.transaction` blocks
- Use the [`use :transaction` strategy](/strategies/transaction) instead - transactions applied via this strategy will **NOT** be rolled back by `done!`
- This ensures database consistency while allowing early completion

**Validation:**
- Outbound validation (required `exposes`) still runs even with early completion
- If required fields are not provided, the action will fail despite the early completion

```ruby
class BadExample
  include Axn

  expects :user_id
  exposes :user  # Required field

  def call
    done!("Early completion") # This will FAIL - user not exposed
  end
end

BadExample.call(user_id: 123).ok? # => false
BadExample.call(user_id: 123).exception # => Axn::OutboundValidationError
```

## Customizing messages

The default `error` and `success` message strings ("Something went wrong" / "Action completed successfully", respectively) _are_ technically safe to show users, but you'll often want to set them to something more useful.

There are `success` and `error` declarations for that -- you can set strings (most common) or a callable (note for the error case, if you give it a callable that expects a single argument, the exception that was raised will be passed in).

For instance, configuring the action like this:

```ruby
class Foo
  include Axn

  expects :name, type: String
  exposes :meaning_of_life

  success { "Revealed to #{name}: #{result.meaning_of_life}" } # [!code focus:2]
  error { |e| "No secret of life for you: #{e.message}" }

  def call
    fail! "Douglas already knows the meaning" if name == "Doug"

    msg = "Hello #{name}, the meaning of life is 42"
    expose meaning_of_life: msg
  end
end
```

Would give us these outputs:

```ruby
Foo.call.error # => "No secret of life for you: Name can't be blank"
Foo.call(name: "Doug").error # => "Douglas already knows the meaning"
Foo.call(name: "Adams").success # => "Revealed to Adams: Hello Adams, the meaning of life is 42"
Foo.call(name: "Adams").meaning_of_life # => "Hello Adams, the meaning of life is 42"
```

### Prefixing failure reasons

An **unconditional** `error "Headline"` acts as the **base**: it becomes the headline shown when no more specific reason matches, and it automatically prefixes every failure *reason* — a conditional `error … if:`/`unless:`, an entry explicitly marked `prefixed: true`, and `fail!` messages — joined as `"Headline: reason"`. `success "…"` / `done!` work the same way.

What sets the role is **conditionality, not whether you pass a string or a block**: `error "..."` and `error { "..." }` are both unconditional headlines and behave identically. Reach for `if:`/`unless:` (a conditional reason) or `prefixed: true` (which promotes an unconditional entry to a prefixed reason) when you want something prefixed rather than treated as the headline.

```ruby
class SyncUser
  include Axn

  error "Couldn't sync user"                      # base — also the fallback
  error "email already taken", if: ArgumentError  # prefixed reason
  error "account is locked", if: RuntimeError     # prefixed reason

  def call
    raise ArgumentError, "duplicate" if email_taken?
    fail! "missing required field"                # also prefixed
  end
end

result = SyncUser.call(...)
result.error  # => "Couldn't sync user: email already taken"
              # or "Couldn't sync user: missing required field"
              # or "Couldn't sync user"  (base alone, when no reason matched)
```

**Key behaviours:**

| | |
|---|---|
| **Gated by a base** | No base declaration ⇒ reasons render standalone, unchanged |
| **`prefixed: false` opt-out** | `error "Vendor not found", if: ArgumentError, prefixed: false` — or `fail!("msg", prefixed: false)` — renders the reason without the base prefix. Scoped to the action: a bubbled child `fail!(..., prefixed: false)` still receives the *caller's* base prefix |
| **Custom join** | `error "Headline", join: " — "` changes the separator string (default is `": "`); or pass a Proc `join: ->(base, reason) { … }` for full control (wrapping, recasing). Only valid on the base — `join:` on a reason raises at declaration |
| **Literal vs block** | No semantic difference — `error "x"` and `error { "x" }` are both headlines. A block is just a headline whose text is computed at runtime |
| **Promote to an always-on reason** | `error(prefixed: true, &:message)` (or `error "detail", prefixed: true`) — `prefixed: true` makes an otherwise-headline entry a prefixed reason, e.g. an always-on detail rendered under the base |

```ruby
# Reasons are checked last-declared-first.
class SyncUser
  include Axn

  error "Couldn't sync user", join: " — "              # base (custom separator)
  error(prefixed: true, &:message)                     # dynamic detail — declared 2nd
  error "vendor not found", if: ArgumentError, prefixed: false  # opt-out — declared last → highest priority

  def call
    raise ArgumentError, "lookup failed"
  end
end

# ArgumentError raised — prefixed: false entry wins (declared last → checked first):
SyncUser.call.error  # => "vendor not found"

# If a non-ArgumentError is raised instead — conditional doesn't match; dynamic detail wins:
# SyncUser.call.error  # => "Couldn't sync user — <exception.message>"
# e.g. RuntimeError "timeout" → "Couldn't sync user — timeout"
```

::: tip result.error vs Axn::Failure#message
`result.error` is the uniform, user-facing presentation string (base prefix + reason, aggregated across all levels). For **Axn-owned** failures (`fail!`, and user-facing validation failures), the raised exception's `#message` is stamped to equal `result.error`, so rescuing the exception from `call!` gives you the same string. Only **foreign** exceptions reclassified via `fails_on` carry a different (technical) `#message` — `result.error` still shows the resolved presentation, but `exception.message` reflects the original exception text.
:::

::: tip Header aggregation across nested call!
When an inner action fails and the outer action calls it with `call!`, the outer action's base header is prepended to whatever the inner action already produced, joined by the outer action's own `join:`. The outermost header comes first — every level contributes its base in order from outside in.

```ruby
class ChargeCard
  include Axn
  error "Charge failed"

  def call
    fail! "card declined"
  end
end

class Onboarding
  include Axn
  error "Onboarding failed"

  def call
    ChargeCard.call!(**inputs)  # propagates the inner failure upward
  end
end

Onboarding.call(...).error  # => "Onboarding failed: Charge failed: card declined"
```

Each level uses *its own* `join:` for the segment it joins — so `error "Onboarding failed", join: " — "` would produce `"Onboarding failed — Charge failed: card declined"`.

For full control over the combination — wrapping, recasing — pass a Proc instead of a string:

```ruby
error "Onboarding failed", join: ->(base, reason) { "#{base} (#{reason})" }
# => "Onboarding failed (Charge failed: card declined)"
```

The Proc receives `(base, reason)` — this level's base header and the already-resolved segment below it — and returns the combined string. It runs per-segment, so each level controls its own join. If the Proc raises or returns a non-String, the framework falls back to the default `": "` join. `success`/`done!` use the same mechanism.

This composition is **bucket-independent**: it applies whether the inner action failed via `fail!`, a `fails_on`-classified exception, or an *unexpected* exception (a bug). For an unexpected exception there is no authored leaf, so only the declared base headers chain (`"Onboarding failed: Charge failed"`) — the raw exception message never enters `result.error` (it stays the technical `#message` on `result.exception`), and a level that declares no base contributes nothing (no `"…: Something went wrong"` noise).
:::

::: tip Composing nested actions: `call!` vs explicit `.call` + `fail!`
Reach for **`inner.call!`** when the inner action *must* succeed for the outer to continue. Its failure aborts the outer transparently, and `result.error` cascades automatically — the outer's base is prepended to the inner's already-resolved presentation (the aggregation above), with no per-call-site wiring. This is the default for a straight-line dependency.

Reach for the explicit **`r = inner.call; fail!(…) unless r.ok?`** idiom when the outer needs a say *before* failing:

- **Inspect or forward the child result** — read `r.error`, `expose(r)` partial outputs (see [Forwarding to a nested action](#forwarding-to-a-nested-action-facades)), log, or run compensating logic.
- **Author a different message** — a custom string (`fail!("Charge step failed: #{r.error}")`), or pass the child's message through *standalone* with `fail!(r.error, prefixed: false)` to skip the outer's base (see [Opting out of a caller's prefix](#opting-out-of-a-caller-s-prefix)).
- **Recover instead of aborting** — branch on `r.ok?` and continue without failing.
- **Orchestrate several children** — collect multiple results, then decide.

Neither replaces the other: `call!` is transparent propagation with automatic cascade; `.call` + `fail!` is for when the outer must intervene. And when you're chaining several sub-actions in sequence, [`steps`](/usage/steps) is the purpose-built tool — it runs each child and composes the messages for you (prefixing each child's `result.error` with a step label, then the parent base), so you don't hand-write the per-step `call`/`fail!` at all.
:::

::: warning Error/success message bodies are not redacted
Message text is treated as authored, user-facing copy — it is **not** passed through the sensitive-field filtering that protects `inspect` output and the `context:` payload sent to `on_exception`. Because a base now composes with reasons, and a `step` cascade interpolates a child's `result.error` into the parent's failure (`"Parent base: Step 1: child reason"`), any detail you interpolate into an `error`/`success`/`fail!` body propagates outward to every ancestor's `result.error` — and onward to logs and error trackers. **Do not interpolate secrets or PII into message bodies.** Put sensitive values in `expects`/`exposes` fields (which are filterable) instead.
:::

::: tip Declaration order
The base is identified by shape (an unconditional `error`/`success`, literal or block), so a single base's position among declarations doesn't matter. When **more than one reason** could match the same failure — or if you declare more than one unconditional headline — the last-declared one wins (entries are checked in reverse-declaration order), so declare the most-specific reasons last.

```ruby
class Foo
  include Axn

  error "Default error message"             # the base — found by shape, any position
  error "Special error", if: ArgumentError  # most-specific reasons last → highest priority
end
```
:::

### Overriding an inherited base

When a subclass inherits from an action that declares an `error` base, the subclass can replace it with its own `error` declaration — the last-declared unconditional entry wins (same last-declared-first-checked rule as reasons). A literal string and a context-derived block are both valid:

```ruby
class BaseTool
  include Axn
  error "Tool failed"
end

class RubyLlmTool < BaseTool
  error "RubyLLM tool failed"                 # literal override # [!code focus]
end

class DynamicTool < BaseTool
  error { "#{tool_name} tool failed" }        # context-derived block override # [!code focus]
end
```

::: warning A header block must describe the action, not the failure reason
A block passed to `error` — whether as an override or a base — is evaluated to produce the **header** for the action (the "who failed" part). It must **not** interpolate the exception's message:

```ruby
# BAD — doubles the reason in every failure message
error { |e| "#{tool_name} tool failed: #{e.message}" }  # [!code warning]

# GOOD — the reason is appended automatically
error { "#{tool_name} tool failed" }                    # [!code focus]
```

The exception message is already appended as the *reason* segment; interpolating it into the header prints it twice — `"MyTool tool failed: card declined: card declined"`.

The same caution applies to a **reason block** (`error(->(e){ … }, if: …)`) that reads `e.message`: when the failure bubbled up from a nested `call!`, `e.message` is the child's **already-accumulated presentation** (e.g. `"Charge failed: card declined"`), not the raw reason — so interpolating it re-embeds the whole child chain. Read `e.message` in a message block only if you genuinely want the resolved presentation so far.
:::

### Default with specific overrides

A common pattern — used in integrations like `teamshares_api` — is to declare an unconditional base as the fallback, and then overlay specific `prefixed: false` reasons for known error classes. `prefixed: false` renders those specific messages **standalone** (without the base prefix), keeping them clean for user display:

```ruby
class CallExternalApi
  include Axn

  error "External API request failed"                                  # fallback base
  error "Record not found", if: RecordNotFoundError, prefixed: false  # standalone # [!code focus:2]
  error "Permission denied", if: PermissionError, prefixed: false     # standalone

  def call
    ExternalApi.fetch!(resource_id)
  end
end

CallExternalApi.call(...).error
# RecordNotFoundError raised  → "Record not found"          (prefixed: false — standalone)
# PermissionError raised      → "Permission denied"         (prefixed: false — standalone)
# any other error             → "External API request failed"  (fallback base)
```

Use this when specific error classes deserve their own user-facing copy and you don't want the base headline prepended to them.

::: tip Base vs. conditional, and how each treats a bubbled child
These are two different jobs, and the difference matters most when a failure bubbles up through `call!`:

- A **base** (unconditional `error "X"`) is the **headline** — it *prefixes* whatever the failure resolved to, **including a nested child's whole chain**. Use it for uniform copy that *preserves* what failed: `error "Checkout failed"` over a child yields `"Checkout failed: Charge failed: card declined"`.
- A **conditional reason** (`error "X", if: …`, or `fails_on [K], "X"`) is an **override for a matched failure mode** — when its condition matches the failure (yours *or a bubbled child's*), it *becomes* the message, **replacing** the child's chain, and the base then prefixes it (unless `prefixed: false`). Use it to *translate* a specific failure into your own copy: `error "Record not found", if: NotFoundError` over a child yields `"Checkout failed: Record not found"` — the child's own message is intentionally dropped.

Because a conditional matches the *failure*, a **catch-all** `error "…", if: ->(_e){ true }` will override **every** bubbled child (and it doesn't even fire for your own `fail!("msg")`, which always wins at its own level). If you want "one friendly message for any failure" *while keeping* the child context, that's a **base**, not a catch-all conditional.
:::

### Opting out of a caller's prefix

By default a child action's `result.error` is prepended by every ancestor's base header as it bubbles up through `call!`. There are two ways to opt out:

**Drop the base entirely.** If an action declares no unconditional `error`, its failures render without their own header — the raw reason surfaces as the segment a caller will prefix. A caller's base still applies; it sees the inner action's already-rendered string as the reason and prepends its own header as usual.

**Pass `prefixed: false` when re-raising.** Inspect the inner result with non-bang `call`, then re-raise with `prefixed: false` to keep the inner message standalone at the current level:

```ruby
def call
  r = InnerAction.call(**inputs)       # [!code focus:2]
  fail!(r.error, prefixed: false) unless r.ok?  # inner message shown as-is, no caller prefix
end
```

Note this only suppresses the *current* action's base prefix — the inner action's own aggregation (its base + reason) is already baked into `r.error` before you re-raise.

## Reclassifying exceptions as failures

Axn sorts every non-success outcome into one of two buckets:

- **failure** — from `fail!`. Expected and user-facing. Fires `on_failure`, sets `result.error`, and is **not** reported to the global handler (`Axn.config.on_exception`).
- **exception** — any other raised error. Unexpected. Fires `on_exception` and **is** reported globally (e.g. to Honeybadger).

Some exception classes are really expected failure modes, not bugs — `ActiveRecord::RecordInvalid` from a validation, say. `fails_on` moves the listed exception classes from the **exception** bucket into the **failure** bucket: a matching raised exception settles as a failed result (firing `on_failure`, skipping `on_exception` and the global report) while the original exception is preserved on `result.exception` and the usual message resolution still applies.

```ruby
class SubmitOrder
  include Axn

  fails_on ActiveRecord::RecordInvalid

  def call
    order.save!   # raises RecordInvalid on validation failure
  end
end

result = SubmitOrder.call(order:)
result.ok?              # => false
result.outcome.failure? # => true   (not .exception?)
result.exception        # => the original ActiveRecord::RecordInvalid
# Axn.config.on_exception was NOT called
```

`fails_on` rides the same muscle memory as `fail!` and `error` — pass a message positionally or as a block (which receives the exception), or omit it to fall back to the default/your own `error` declaration:

```ruby
fails_on ActiveRecord::RecordInvalid, "Unable to submit"
fails_on(ActiveRecord::RecordInvalid) { |e| e.record.errors.full_messages.to_sentence }
fails_on [ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique], "Couldn't save"
```

The message integrates with the standard message DSL (ordering, base-prefix semantics, etc.), so it composes with — and can be overridden by — your other `error` declarations.

::: tip Callbacks receive the original exception
Inside `on_failure` / `on_error`, the `exception` argument (and `result.exception`) is the **original** raised object — e.g. the `ActiveRecord::RecordInvalid` — not an `Axn::Failure`. So a handler can read `exception.record.errors` directly. You can branch on `exception.is_a?(Axn::Failure)` to distinguish an explicit `fail!` from a `fails_on` reclassification.
:::

::: warning Async: a reclassified exception is terminal (no retry)
When an action runs as a background job, a `fails_on` exception is treated exactly like `fail!` — it settles as a **failure**, so the adapter does **not** re-raise it and the job is **not** retried (retries are for *unexpected* errors). That's usually what you want: a `RecordInvalid` won't pass on a retry. Only reclassify exception classes that are **deterministic / non-transient** — don't `fails_on` something genuinely transient (a lock timeout, a rate limit) or you'll forfeit the retry that would have recovered it.
:::

::: tip
For the common "save an ActiveRecord model" case, reach for the [Model strategy](/strategies/model), which wires `fails_on ActiveRecord::RecordInvalid` (and the save/expose boilerplate) for you.
:::

### Suppressing reports for expected failures in composed actions

When one action calls another, `fails_on` belongs on the **inner** action — the one that knows the exception class is an expected business outcome.

Consider an outer `SyncUser` that calls an inner `CreateZendeskTicket`. The inner action may raise `Faraday::BadRequestError` when the email address is already registered — a predictable, non-bug outcome. Without `fails_on`, that exception lands in the **exception** bucket: `Axn.config.on_exception` fires, and `SyncUser` receives a spurious Honeybadger report even though it handles the failure gracefully.

```ruby
class CreateZendeskTicket
  include Axn

  fails_on Faraday::BadRequestError   # "email already used" is expected, not a bug

  def call
    ZendeskClient.create_ticket(email:)  # raises Faraday::BadRequestError if duplicate
  end
end

class SyncUser
  include Axn

  def call
    result = CreateZendeskTicket.call(email:)
    # result.ok? is false; result.outcome.failure? is true
    # result.exception holds the original Faraday::BadRequestError
    # Axn.config.on_exception was NOT called — no spurious report
    fail!("Could not create ticket: #{result.error}") unless result.ok?
  end
end
```

The three outcomes, contrasted:

| How the inner action fails | `on_failure` fires | `on_exception` / global report | `result.exception` |
|---|---|---|---|
| `fail!` | yes | **no** | `Axn::Failure` |
| `fails_on`-matched exception | yes | **no** | original exception |
| Unhandled exception | no | **yes** | original exception |

Both `fail!` and `fails_on` land in the failure bucket and are never reported. Only an unhandled, unclassified exception reaches `on_exception`.

**Nested `call!` behaves identically to top-level.** When `SyncUser` above uses `call!` instead of `call`, a `fails_on`-reclassified exception still settles as a failure and re-raises as the **original exception** (e.g. `Faraday::BadRequestError`) — not an `Axn::Failure`. `Axn::Failure` is raised by `call!` only when the failure came from `fail!`. An unhandled exception is re-raised as-is, same as at the top level. There is one consistent mental model regardless of nesting depth: `Axn::Failure` means "`fail!` was called"; anything else re-raises whatever was originally raised.

**The `fails_on` classification is sticky.** Once an action's `fails_on` reclassifies an exception as an expected failure, that decision travels with the exception object: even bubbled up through `call!` to an ancestor that knows nothing about that exception class, it stays a **failure** (the ancestor fires `on_failure`, not `on_exception`, and its `result.outcome` is `failure`). So `fails_on` suppresses the report whether the caller inspects `result` (via `call`) or lets it raise (via `call!`). This is keyed to the specific exception object — an unrelated exception of the same class raised elsewhere in an ancestor is still a bug (an `exception` outcome, reported).

**Stickiness flows outward, not inward — `fails_on` must live where the exception is raised.** Each action classifies an exception in its *own* frame, and the global report fires at the *innermost* action that treats the exception as a bug. So `fails_on` on an **ancestor** does **not** suppress a report from an inner action that raised the exception without its own `fails_on`: by the time the exception bubbles up to the ancestor, the inner action has already reported it, and that report can't be un-sent — the ancestor only reclassifies its own `result.outcome` to `failure` from that point upward. The consequence is the sharp edge to watch for: an ancestor whose `result.outcome` is `failure` can still have produced a Honeybadger report from a deeper level. **To suppress the global report, declare `fails_on` on the action that actually raises the exception** (or absorb it with non-bang `call` + `fail!` there) — declaring it only on a caller is too late.

Note the *message* follows the standard aggregation rule: when a `fails_on` failure bubbles up via `call!`, the ancestor's base prefixes the inner action's resolved `result.error` (the **Header aggregation across nested `call!`** rule above), so the inner's message **is** woven in — a baseless ancestor passes the inner's presentation through unchanged. The original exception is still preserved on `result.exception` with its own (technical) `#message`. Reach for non-bang `call` + `fail!("context: #{result.error}")` only when you want to author a *different* message than the automatic aggregation.

::: tip Place `fails_on` on the action that owns the contract
The inner action that makes the API call or database write is the right home for `fails_on` — it's the one that knows which exception classes are routine. An outer caller that knows nothing about `Faraday::BadRequestError` doesn't need to suppress it; the inner already has.
:::

### Reporting a nested bug once

Distinct from `fails_on` (which decides whether an *expected* failure is reported at all): a genuine, unhandled exception is reported to `Axn.config.on_exception` **once** — from the innermost action that treats it as a reportable exception — however deeply it propagates through nested `call!`s. Each action's own `on_exception` callback still fires at its level; the single global report is sent from where the exception first surfaced as a bug. So a bug that bubbles up through `call!`, and one you absorb into a parent `fail!` via non-bang `call`, each produce a single report.

Delivery is **best-effort, attempted exactly once**: if your `on_exception` handler itself raises, the failure is logged (via the internal piping-error path) and the report is *not* retried from an ancestor — so behavior is deterministic regardless of nesting depth.

### User-facing contract violations

A failed `expects` validation is dev-facing by default: a caller who omits a required field has a **bug**, so the violation lands in the **exception** bucket (pages the global handler, `result.error` is the generic `"Something went wrong"`). That's the right call when the input comes from your own code.

But some inputs are genuinely user-supplied, where a missing or invalid value is the *caller's* fault, not a bug. Mark that field `user_facing:` and a violation of it settles in the **failure** bucket instead — firing `on_failure`, skipping `on_exception` / the global report, and surfacing a meaningful message on `result.error`:

```ruby
expects :note, user_facing: true            # surfaces the field's own message ("Note can't be blank")
expects :note, user_facing: "Add a note"    # override the surfaced message
expects :note, user_facing: :note_message   # call an action method to compute it
expects :note, user_facing: ->(e) { ... }   # compute it from the InboundValidationError
```

The value rides the same muscle memory as `fail!` / `error` / `fails_on` — `true`, a String, a Symbol naming an action method, or a block receiving the exception. (A String/Symbol/block that resolves blank falls back to the field's own validation message, so a user-facing failure never surfaces the generic dev-facing message.) The structured `InboundValidationError` is preserved on `result.exception` either way.

The surfaced message is a failure **reason**, so it composes with a declared base `error` exactly like a `fail!` message — [prefixed by the headline](#prefixing-failure-reasons) by default, standalone when no base is declared:

```ruby
error "Couldn't save note"
expects :note, user_facing: true
# result.error → "Couldn't save note: Note can't be blank"
```

`user_facing:` changes *who is blamed* for a violation, not *whether* the field is validated — the field stays **required** (unlike `optional: true`, which removes the check). It's a per-field decision: scope it to the inputs a user actually controls, and leave the rest dev-facing. (If *every* input is user-supplied, reach for [`use :form`](/strategies/form) instead.)

::: warning Dev-facing wins in a mixed failure
If a single call fails validation on both a `user_facing:` field **and** a plain one, the violation stays **dev-facing** (exception bucket) — a real contract bug always pages, and is never masked behind a friendly message. The user-facing path is taken only when *every* failing field is `user_facing:`.
:::

::: tip Top-level fields only
`user_facing:` is a top-level concern. It can't be declared on a subfield (`on:`), and it's rejected on a field that carries nested expectations — [subfields](/reference/class#nested-subfield-expectations) or a shape block — whose member/structural checks (and model-consistency checks) are always dev-facing (a malformed nested shape is a bug in the calling code). Keep `user_facing:` for the flat, caller-controlled inputs; if you need it on a structured payload, validate the specific leaf you care about as its own top-level field. (Support for `user_facing:` on fields with nested expectations is deliberately deferred until a concrete need appears.)
:::

## Lifecycle methods

In addition to `#call`, there are a few additional pieces to be aware of:



### Hooks

`before`, `after`, and `around` hooks are supported. They can receive a block directly, or the symbol name of a local method.

Note execution is halted whenever `fail!` is called, `done!` is called, or an exception is raised (so a `before` block failure won't execute `call` or `after`, while an `after` block failure will make `result.ok?` be false even though `call` completed successfully). The `done!` method specifically skips `after` hooks and any remaining `call` method execution, but allows `around` hooks to complete normally.

#### Around hooks

Around hooks wrap the entire action execution, including before and after hooks. They receive a block that represents the next step in the chain:

```ruby
class Foo
  include Axn

  around :with_timing
  around do |chain|
    log("outer around start")
    chain.call
    log("outer around end")
  end

  def call
    log("in call")
  end

  private

  def with_timing(chain)
    start = Time.current
    chain.call
    log("Took #{Time.current - start}s")
  end
end
```

#### Before/After example

For instance, given this configuration:

```ruby
class Foo
  include Axn

  before { log("before hook") } # [!code focus:2]
  after :log_after

  def call
    log("in call")
  end

  private

  def log_after
    log("after hook")
    raise "oh no something borked"
    log("after after hook raised")
  end
end
```

`Foo.call` would fail (because of the raise), but along the way would end up logging:

```text
before hook
in call
after hook
```

**Hook Ordering with Inheritance:**
- **Around hooks**: Parent wraps child (parent outside, child inside)
- **Before hooks**: Parent → Child (general setup first, then specific)
- **After hooks**: Child → Parent (specific cleanup first, then general)

This follows the natural pattern of setup (general → specific) and teardown (specific → general).

### Callbacks

A number of custom callback are available for you as well, if you want to take specific actions when a given Axn succeeds or fails. See the [Class Interface docs](/reference/class#callbacks) for details.

## Strategies

A number of [Strategies](/strategies/index), which are <abbr title="Don't Repeat Yourself">DRY</abbr>ed bits of commonly-used configuration, are available for your use as well.

::: info Optional Peer Libraries
Axn provides enhanced functionality when certain peer libraries are available:

- **Rails**: Automatic engine loading, autoloading for `app/actions`, and generators
- **Faraday**: Enables the [Client Strategy](/strategies/client) for HTTP API integrations
- **memo_wise**: Extends built-in `memo` helper to support methods with arguments (see [Memoization recipe](/recipes/memoization))

These are all optional—Axn works great without them, but they unlock additional features when present.
:::

## Advanced: Default call behavior

::: tip For Experienced Users
This section covers an advanced shortcut. If you're new to Axn, start by explicitly defining your `call` method.
:::

If you don't define a `call` method, Axn provides a default implementation that automatically exposes all declared exposures by calling methods with matching names. This allows you to simplify actions that only need to compute and expose values:

```ruby
class CertificatesByDestination
  include Axn
  exposes :certs_by_destination, type: Hash

  private

  def certs_by_destination
    # Your logic here - automatically exposed
    { "dest1" => "cert1", "dest2" => "cert2" }
  end
end
```

This is equivalent to:

```ruby
class CertificatesByDestination
  include Axn
  exposes :certs_by_destination, type: Hash

  def call
    expose certs_by_destination: certs_by_destination
  end

  private

  def certs_by_destination
    { "dest1" => "cert1", "dest2" => "cert2" }
  end
end
```

**Important notes:**
- The default `call` requires a method matching each declared exposure (unless a `default` is provided)
- If a method is missing and no default is provided, the action will fail with a helpful error message
- You can still override `call` to implement custom logic when needed
- If a method returns `nil` for an exposed-only field with no default, it's treated as missing (user-defined methods that legitimately return `nil` should use `expose` explicitly or provide a default)
