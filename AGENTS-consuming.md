# Axn — agent guide

For an LLM writing code that **calls** or **declares** Axn actions (not modifying Axn internals).
Covers the contract, result/failure behavior, idioms, and gotchas; points out to the docs and source
for depth. On an edge case, read the source — paths below, via `bundle show axn`.
Docs: <https://teamshares.github.io/axn/>.

## Mental model

An Axn (Action) is a callable service object with a declared contract: inbound fields (`expects`),
outbound fields (`exposes`), and a `call` body. `Foo.call(...)` **always** returns an `Axn::Result`
— it never raises for ordinary failures (exceptions are swallowed and reported). You branch on
`result.ok?`. Business logic aborts with `fail!`; unexpected errors raise and are caught for you.

```ruby
class CreateWidget
  include Axn

  expects :name, type: String
  expects :category, type: String, optional: true
  exposes :widget

  # Idiom: set meaningful messages — the generic fallbacks ("Action completed successfully" /
  # "Something went wrong") are almost never what a caller should see. Do this by default.
  success "Widget created"
  error "Couldn't create widget"

  def call
    fail!("Name is taken") if Widget.exists?(name:)
    expose widget: Widget.create!(name:, category:)
  end
end

result = CreateWidget.call(name: "Sprocket")
result.ok?      # => true
result.widget   # => #<Widget ...>                            (reader for the exposed field)
result.success  # => "Widget created"

result = CreateWidget.call(name: "Existing")  # name taken → fail!
result.ok?      # => false
result.error    # => "Couldn't create widget: Name is taken"  (base headline prefixes the reason)
```

Each declared field gets a reader **inside** the action (`name`, `category`) and each exposed field
gets a reader **on the result** (`result.widget`). Inside `call` you never touch a raw params hash —
you read the named fields.

## Declaring the contract

`expects` declares inbound fields; `exposes` declares outbound. Both take one or more field names
plus shared options. Validation runs automatically (inbound before `call`, outbound after).

```ruby
expects :email, type: String
expects :role, inclusion: { in: %w[admin member] }, optional: true
exposes :user
```

Common options (same for `expects` and `exposes`):

| Option | Meaning |
| --- | --- |
| `type:` | `is_a?` check. `type: :boolean` (no Ruby Boolean class; also defines a `field?` predicate), `type: :uuid`, `type: :params` (a Hash or any `ActionController::Parameters`). Union: `type: [String, Symbol]`. A token outside that grammar (`type: false`, `type: [String, nil]`) raises `ArgumentError` at declaration. |
| `optional: true` | Don't fail when the field is missing or nil (≡ `allow_blank: true`); removes the auto presence check. **Preferred** spelling. Caveat: a *typed* field still type-checks a non-nil blank — `type: Hash, optional: true` still rejects `""` (a `type: String` field accepts it, since `"".is_a?(String)`). |
| `allow_empty: true` | Accept an empty collection or string but **not** `nil` — the field stays required. Needs a `type:` whose values can be empty — `Array`/`Hash`/`Set`/`String`/`:params`, or any class or module defining `empty?`; raises otherwise, as does any value other than `true`/`false`/`nil`. Pair with a tolerance flag inverted (`optional: true, allow_empty: false`) for "may be omitted, but not empty". Don't also declare `presence:` — the two answer the same question, and a disagreement raises. |
| `allow_nil:` / `allow_blank:` | Finer-grained than `optional:`. |
| `default:` | Used when the field is missing or explicitly `nil` (**not** for blank values). |
| `sensitive: true` | Filter the value in logs / error reports / `inspect`. Accepts a proc/symbol for runtime decisions. |
| `of:` | Names what is INSIDE a container. `type: Array`: each element's class (`of: String`, `of: [String, Numeric]`), errors reporting the failing index. `type: Hash`: a map (`of: { keys: Symbol, values: Integer }`) — either axis may be omitted to leave it unconstrained, and a failing entry is reported by its ordinal, never its key. Refused on any other type, a union `type: [Array, Hash]` included. It **nests**: an element or an axis may take an inner-contract bag carrying `klass:`/`of:`/`shape:`/`message:` — `of: { klass: Array, of: Integer }` (an array of arrays), `of: { values: { klass: Hash, shape: … } }` (a map of shaped records; members at an axis must be objects answering `field`/`validations`, e.g. a `Struct.new(:field, :validations)`, since no block form reaches an axis). On a Hash, `of:` may sit beside a `shape:` or a block, which names specific keys: those keys are **exempt** from the map contract, exactly as JSON Schema's `additionalProperties` applies only to keys `properties` does not match. |
| `validate:` | Custom: `validate: ->(v) { "must be > 10" unless v > 10 }` — return a string (or raise) to fail. |
| any ActiveModel validation | e.g. `length:`, `format:`, `numericality:` — passed through as if to `validates`. |

`expects`-only extras: `model:` (auto-hydrate a record, below), `on:` (subfields, below),
`as:`/`prefix:` (rename the reader), `preprocess:` (coerce before validation/defaults),
`user_facing:` (blame the caller, see Failure semantics).

These validations are the **developer contract** (how the action is called) — not pretty
user-facing copy. For user-facing input validation reach for `use :form`. Full option detail:
<https://teamshares.github.io/axn/reference/class>.

If this action runs as a tool (via `Axn::Tools::Invoker`, an adapter's runtime for model-supplied
args), declare a `type:` on every field rather than a defensive per-field `coerce: true` — tool
calls always coerce, and coercion plus schema reflection (`input_schema`) both key off `type:`.
See <https://teamshares.github.io/axn/reference/tool-invoker>.

## Inside `call`

| Helper | Effect |
| --- | --- |
| `expose key: val` / `expose :key, val` | Set an exposed field on the result. Only declared `exposes` keys are allowed. |
| `fail!("msg", **kw)` | Abort now as a **failure**; `result.error` = msg; optional kwargs exposed first. |
| `done!("msg", **kw)` | Abort now as **success** (early return); skips remaining `call` + `after` hooks. |
| `log("msg", level: :info)` | Log via `Axn.config.logger`, prefixed with the class name. |
| field readers | Read any `expects` field by name; `result.<field>` reads exposures (rare inside `call`). |
| `Axn::Extensions::Tracing.annotate_span(**attrs)` | Write vendor-namespaced OTel attributes onto axn's own `axn.call` span — for a gem, not an app (apps use `tag`/`dimension`); never `OpenTelemetry::Trace.current_span`. |

If you declare `exposes :x` you must `expose x: …` on every success path — **unless** `x` is also an
`expects` field, in which case Axn auto-copies it (see Gotchas). Outbound validation still runs on
`done!`, so a required exposure that's unset makes the action fail with `OutboundValidationError`.

Hooks: `before`, `after`, `around` (block or symbol method). A `fail!`/raise in a hook fails the
action. `done!` skips `after` hooks — and because it unwinds via an exception, statements *after*
`chain.call` in an `around` hook are skipped too (`fail!` and an unhandled raise unwind the same
way). Put such teardown in an `ensure` inside the `around`, or use `use :transaction`, which rescues
the signal so the transaction still commits. Note the `around` hook (and its `ensure`) covers only
halts raised **after the hook chain is entered** — an inbound `expects` failure, or an *inbound*
`preprocess:`/`default:` callable that raises, settles before the hooks run, so neither fires. The
`exposes` side is bounded too: outbound resolution (an `exposes` `default:`, outbound validation)
runs *after* the hook body returns, so the hooks complete **normally** and never observe a raise from
it — an `around` that rescues to record failures misses them. Use the callbacks for per-call
observability that must not miss either end. Callbacks
(`on_success`, `on_error`, `on_failure`, `on_exception`) fire once the action **settles** — which is
not the same as "after `call`": they fire even when `call` never ran, as on an inbound validation
failure. That is what makes them the seam that sees every call. `on_error` is a superset, co-firing
with whichever of `on_failure`/`on_exception` applies. A raise in a callback does **not** flip `ok?` —
it is swallowed, logged, and reported to `Axn.config.on_ignored_exception` (which defaults to your
`on_exception` handler) carrying `context[:axn_ignored]`.
<https://teamshares.github.io/axn/usage/writing>.

## Using a result

`Axn::Result` is uniform across every action:

| Member | Meaning |
| --- | --- |
| `ok?` | Succeeded? |
| `error` | User-facing error string when `!ok?` (else nil). |
| `success` / `message` | Success string when `ok?`; `message` is always set (success or error). |
| `outcome` | String inquirer: `outcome.success?` / `failure?` / `exception?`. |
| `exception` | The swallowed exception, if any (mostly for tests/diagnostics). |
| `<exposed field>` | Reader for each declared exposure. |

```ruby
result = Actions::Slack::Post.call(channel: "#eng", message: text)
if result.ok?
  @thread_id = result.thread_id
else
  flash[:alert] = result.error
end
```

Invocation variants:

- `Foo.call(**kw)` → always returns a `Result`; exceptions swallowed. **Default.**
- `Foo.call!(**kw)` → returns a `Result` on success; a `fail!` raises `Axn::Failure`, any other
  error re-raises as-is. Use in scripts / when you want failures to bubble.
- `Foo.call_async(**kw)` → enqueue as a background job (configure with `async :sidekiq` /
  `async :active_job`). See <https://teamshares.github.io/axn/reference/async>.

`Result` supports pattern matching (`in ok: true, user: User => u`).

## Field resolvers (`model:` and `on:`)

**`model:` — hydrate a record from an id.** `expects :user, model: true` adds expectations that
`user_id` is supplied (derived from the field name) and `User.find(user_id)` returns a record, and
defines both a `user` reader (the record) and a `user_id` reader. Variants: `model: User`,
`model: { klass: User, finder: :find_by_slug }`.

```ruby
expects :user, model: true
# called with user_id: 5   → user_id == 5,      user resolves the record
# called with user: <rec>  → user_id == rec.id, user is that record
```

`user_id` always means *the record's primary key*, on every path. Passing both a record and a
disagreeing `user_id` (default `:find` finder) raises `InboundValidationError` — contradictory
input is a developer error. `klass:` must be a single Class/Module (no union, no `type:`-style
pseudo-type); anything else raises `ArgumentError` at declaration. Source:
`lib/axn/core/field_resolvers/model.rb`.

**`on:` — subfields (the `:extract` resolver).** Declare expectations about nested data and get a
flat reader:

```ruby
expects :event, type: Hash
expects :data, type: Hash, on: :event
expects :id, :type, on: :data            # readers: id, type (extract event[:data][:id], ...)
expects :zip, on: "address.billing"      # dotted path; reader: zip
```

Subfields support all the normal options and `default:`; `readers: false` skips reader creation;
`as:`/`prefix:` rename. `default:`/`preprocess:`/`sensitive:` work on a *nested parent* too (whether
reached by dotted path or by pointing `on:` at another subfield). `default:`/`preprocess:` resolve on
the **read path**, when the subfield is read; `sensitive:` is not part of that read — it resolves
only when something requests redaction (see Gotchas). Either way the parent is never mutated and
intermediates are never materialized; on an ambient parent (`on: :ambient_context`) only
`user_facing:` is unsupported. Subfield hashes accept string **or** symbol keys (indifferent). Source:
`lib/axn/core/field_resolvers/extract.rb`. Reference:
<https://teamshares.github.io/axn/reference/class>.

## Failure semantics (read this — most subtle bugs live here)

Every non-success outcome lands in exactly one bucket:

| How it ends | `outcome` | `on_failure` | `on_exception` + **global report** | `result.exception` |
| --- | --- | --- | --- | --- |
| `fail!("…")` | `failure` | fires | **no** | `Axn::Failure` |
| `fails_on`-matched raise | `failure` | fires | **no** | the original exception |
| any other raised error | `exception` | — | **yes** (e.g. Honeybadger) | the original exception |

So `fail!` is for **expected, user-facing** outcomes; an unhandled raise is treated as a **bug** and
reported to `Axn.config.on_exception`. Key consequences:

- **`fails_on ExceptionClass`** reclassifies a raised exception from *bug* to *expected failure*
  (fires `on_failure`, skips the global report, keeps the original on `result.exception`). Put it on
  the action that **raises** the exception — it doesn't suppress a report from a deeper action. Only
  reclassify deterministic/non-transient errors (e.g. `ActiveRecord::RecordInvalid`), never a
  transient one you'd want retried. In async, a `fails_on` failure is terminal (no retry).
  `result.error` never defaults to the exception's own (technical) `#message`; opt a specific class
  in with `fails_on ExceptionClass, &:message` when that message is genuinely user-facing. This is
  the idiom for the "save an ActiveRecord model" case — a plain action plus
  `fails_on ActiveRecord::RecordInvalid, &:message` surfaces the record's validation errors as the
  failure message (and, e.g., `fails_on Stripe::CardError, &:message` for a card-declined message).
  `if:`/`unless:` (evaluated against the action at settlement, same mechanism as `error`/callbacks)
  gate the reclassification itself, not just the message — a condition living *inside* the message
  block never did that, which is the footgun `if:`/`unless:` exist to close.
- **`expects` violations are dev-facing by default** → exception bucket, pages, generic
  `"Something went wrong"`. A missing required input is your bug. Mark a genuinely caller-supplied
  field `user_facing: true` (or a String/Symbol/Proc message) to move *its* violations to the
  failure bucket with a meaningful `result.error`. The field stays required. In a mixed failure
  (a `user_facing:` field *and* a plain one), dev-facing wins and it still pages.
- **A nested bug is reported once**, from the innermost action that treats it as a bug, however deep
  the `call!` chain.

**Messages — declare `success` and `error` by default.** The fallbacks are the generic
`"Action completed successfully"` / `"Something went wrong"`; declare a meaningful `success "…"` and
`error "…"` on every action whose result a caller surfaces. Both accept a string, a symbol (action
method), or a block (evaluated in instance context: `error { "Failed for #{name}" }`).

**Base/reason model.** An *unconditional* `error "Headline"` is the **base**: it's the fallback and it
auto-prefixes every failure reason as `"Headline: reason"` (a conditional `error … if:`, a
`prefixed: true` entry, and `fail!` strings). A *conditional* `error "…", if: SomeError` is a reason.
Most-recently-declared matching reason wins. `success`/`done!` work the same. A literal and a block
behave identically — conditionality (not string-vs-block) sets the role.

```ruby
error "Couldn't sync user"                       # base / fallback + prefix
error "email already taken", if: ArgumentError   # reason → "Couldn't sync user: email already taken"
fail! "missing field"                            # reason → "Couldn't sync user: missing field"
```

Composing actions: a base `error` on the parent auto-prefixes the child's **resolved `result.error`**
surfaced via `call!`, and this is **bucket-independent** — it applies whether the child failed via
`fail!`, a `fails_on`-classified exception, or an unexpected exception. What differs by bucket is the
*exception object*, not the message: `fail!` re-raises as `Axn::Failure`, while a `fails_on`-matched
or unhandled exception bubbles as the **original** exception. Either way the child's message is woven
in (`"Onboarding failed: Charge failed: card declined"`) — **unless the parent itself declares a
matching conditional reason**, which *replaces* the child's presentation rather than prefixing it
(`error "Record not found", if: NotFoundErr` on the parent yields `"Onboarding failed: Record not
found"`, and `standalone: true` drops the parent's base too, leaving `"Record not found"`). So a
parent that authors its own reason for an exception class opts out of carrying the child's context.
An *unexpected* exception still picks up a
leaf if a conditional `error "…", if: SomeError` matches it — reason matching is independent of
`fails_on` — giving `"Onboarding failed: Charge failed: retry later"` while the outcome stays
`exception`. Only with **no matching reason** is there no leaf, and then just the declared base
headers chain (`"Onboarding failed: Charge failed"`). The raw exception message never enters
`result.error` **by default** — it stays the technical `#message` on `result.exception` — but you can
opt a class in explicitly with `error(if: SomeError, &:message)` or `fails_on SomeError, &:message`,
and once opted in it aggregates like any other reason (`"Onboarding failed: Charge failed: <raw
message>"`). Only do that where the message is genuinely user-facing. A level declaring no base
contributes nothing. Reach for non-bang `call` +
`fail!("context: #{child.error}")` when you want to author a *different* message than this automatic
aggregation, or to add per-call context — not to carry the child's message through.

⚠️ **Message bodies are NOT redacted** and propagate outward to every ancestor's `result.error`,
logs, and error trackers. Never interpolate secrets/PII into `error`/`success`/`fail!` text — put
sensitive values in `sensitive:` fields. Detail:
<https://teamshares.github.io/axn/usage/writing#prefixing-failure-reasons>. Source:
`lib/axn/core/flow/messages.rb`, `lib/axn/core/flow/fails_on.rb`.

## Gotchas

- **Indifferent access is top-level only.** Declared keys, call-arg keys, and `expose` keys are all
  symbolized, so `expects :note` matches `.call("note" => x)` (the `.call(**params)` case). But field
  **values** — including nested hashes — are untouched: reach into a nested value with the key type
  it actually has (or declare an `on:` subfield, which *is* indifferent).
- **Auto-copy of `expects` + `exposes` fields.** A field declared with *both* is copied from input to
  result automatically on **all** paths — success, `done!`, `fail!`, and exception. Lets a caller
  read `result.user.errors` after a failed save without a manual `expose`. Don't redundantly
  `expose` it.
- **`done!` rolls back a manual `ActiveRecord::Base.transaction`** (it's implemented via an
  exception). Use `use :transaction` for transaction-safe early completion.
- **Default `call`.** Omit `call` entirely and Axn synthesizes one that exposes each declared
  `exposes` by calling a same-named method. A method returning `nil` (no default) counts as missing.
- **`call` vs `call!`.** With `call!`, a `fail!` raises `Axn::Failure`; any *other* error re-raises
  unchanged (not wrapped). `fails_on` reclassification is sticky across `call!` boundaries.
- **Hooks vs callbacks.** A raise/`fail!` in a `before`/`after`/`around` hook flips `ok?` to false; a
  raise in a callback (`on_success` etc.) is reported but does **not** change `ok?`.
- **Callable-option timing.** A `sensitive:` Proc is `instance_exec`'d with **no arguments** (write
  `sensitive: -> { !include_pii }`, reading other fields by name — a lambda declaring a parameter
  raises), and it resolves lazily, only when something actually redacts. By then `default:`s are
  applied, so it reads another field's *defaulted* value. `preprocess:` is the opposite: it runs
  *before* defaults, seeing `nil` for an omitted top-level field. Only a **non-nil** result bypasses
  the `default:` — return `nil` and the default still applies, so an intentional nil does not survive
  (`false` does, matching `default:`'s missing-or-nil rule). On a **subfield** the preprocessor runs
  only when the leaf's immediate parent is present: `parent: {}` still invokes it with `nil`, but an
  absent or `nil` parent skips it entirely. The subfield's own `default:` still resolves in that case
  — the reader returns the default, and is `nil` only when there is none. So don't rely on a nested
  `preprocess:` to manufacture a value when the parent is missing; declare a `default:` for that.

## Strategies (DRYed configuration via `use`)

- **`use :form do … end`** — validate user input via an `Axn::FormObject` (full ActiveModel
  validations) before `call`; exposes `form`. For genuinely user-facing input.
  <https://teamshares.github.io/axn/strategies/form>.
- **`use :transaction`** — wrap the action in a DB transaction that `done!` won't roll back.
- **`use :client`** (Faraday) for HTTP APIs.

## Composition (steps)

`step :name, expects: […], exposes: […] do … end` defines inline sequential steps; `steps(A, B, C)`
chains existing action classes. Data flows via the shared context; a step failure fails the parent
with the step name prefixed (`"validate: Email is invalid"`).
<https://teamshares.github.io/axn/usage/steps>.

## Declaring your entry point

If you're building a gem that dispatches Axns on behalf of an external trigger (an inbound webhook, a
scheduled job runner, a queue consumer) rather than calling them straight from app code, wrap your
dispatch in `Axn::Extensions::InvokedVia.with(:your_gem) { handler.call!(**args) }`. The value becomes
the `invoked_via` dimension on the whole call tree — every nested sub-Axn, span, log line, metric, and
exception report — so an app can tell "traffic that came in through your gem" apart from ordinary
direct calls without touching the classes it dispatches. A tool-adapter gem gets this automatically
through `Axn::Tools::Invoker`'s `adapter:` kwarg; everyone else calls `InvokedVia.with` once, at the
outermost point they control. `dimension :invoked_via` / `tag :invoked_via` are reserved — declaring
either raises. See `docs/recipes/declaring-entry-points.md` for the full recipe.

## Pointers

Human docs — <https://teamshares.github.io/axn/>:
build (`/usage/writing`), use (`/usage/using`), class DSL (`/reference/class`), instance helpers
(`/reference/instance`), result (`/reference/axn-result`), strategies (`/strategies/`), steps
(`/usage/steps`), async (`/reference/async`), config (`/reference/configuration`), tool invoker
(`/reference/tool-invoker`), entry points (`/recipes/declaring-entry-points`).

Source entry points (resolve with `bundle show axn`):
- `lib/axn.rb` — `include Axn` wiring.
- `lib/axn/core/contract.rb` — `expects`/`exposes` declaration.
- `lib/axn/core/field_resolvers/` — `model.rb` (`model:`), `extract.rb` (`on:` subfields).
- `lib/axn/core/validation/validators/` — `type`, `of`, `model`, `validate`, `shape` validators.
- `lib/axn/core/flow/` — `messages.rb`, `fails_on.rb`, `handlers/` (failure/message/callback resolution).
- `lib/axn/result.rb`, `lib/axn/core/context/facade.rb` — the `Result` surface.
- `lib/axn/strategies/` — `form.rb`, `transaction.rb`; `lib/axn/extras/strategies/client.rb` (`use :client`).
