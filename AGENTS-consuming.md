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
| `type:` | `is_a?` check. `type: :boolean` (no Ruby Boolean class; also defines a `field?` predicate), `type: :uuid`, `type: :params` (a Hash or any `ActionController::Parameters`). Union: `type: [String, Symbol]`. |
| `optional: true` | Don't fail when the field is missing or nil (≡ `allow_blank: true`); removes the auto presence check. **Preferred** spelling. Caveat: a *typed* field still type-checks a non-nil blank — `type: Hash, optional: true` still rejects `""` (a `type: String` field accepts it, since `"".is_a?(String)`). |
| `allow_nil:` / `allow_blank:` | Finer-grained than `optional:`. |
| `default:` | Used when the field is missing or explicitly `nil` (**not** for blank values). |
| `sensitive: true` | Filter the value in logs / error reports / `inspect`. Accepts a proc/symbol for runtime decisions. |
| `of:` | For `type: Array` **only** — validates each element's class (`of: String`, `of: [String, Numeric]`). Errors report the failing index. |
| `validate:` | Custom: `validate: ->(v) { "must be > 10" unless v > 10 }` — return a string (or raise) to fail. |
| any ActiveModel validation | e.g. `length:`, `format:`, `numericality:` — passed through as if to `validates`. |

`expects`-only extras: `model:` (auto-hydrate a record, below), `on:` (subfields, below),
`as:`/`prefix:` (rename the reader), `preprocess:` (coerce before validation/defaults),
`user_facing:` (blame the caller, see Failure semantics).

These validations are the **developer contract** (how the action is called) — not pretty
user-facing copy. For user-facing input validation reach for `use :form`. Full option detail:
<https://teamshares.github.io/axn/reference/class>.

## Inside `call`

| Helper | Effect |
| --- | --- |
| `expose key: val` / `expose :key, val` | Set an exposed field on the result. Only declared `exposes` keys are allowed. |
| `fail!("msg", **kw)` | Abort now as a **failure**; `result.error` = msg; optional kwargs exposed first. |
| `done!("msg", **kw)` | Abort now as **success** (early return); skips remaining `call` + `after` hooks. |
| `log("msg", level: :info)` | Log via `Axn.config.logger`, prefixed with the class name. |
| field readers | Read any `expects` field by name; `result.<field>` reads exposures (rare inside `call`). |

If you declare `exposes :x` you must `expose x: …` on every success path — **unless** `x` is also an
`expects` field, in which case Axn auto-copies it (see Gotchas). Outbound validation still runs on
`done!`, so a required exposure that's unset makes the action fail with `OutboundValidationError`.

Hooks: `before`, `after`, `around` (block or symbol method). A `fail!`/raise in a hook fails the
action. `done!` skips `after` hooks but lets `around` finish. Callbacks (`on_success`, `on_error`,
`on_failure`, `on_exception`) run *after* `call` and do **not** flip `ok?`.
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
input is a developer error. Source: `lib/axn/core/field_resolvers/model.rb`.

**`on:` — subfields (the `:extract` resolver).** Declare expectations about nested data and get a
flat reader:

```ruby
expects :event, type: Hash
expects :data, type: Hash, on: :event
expects :id, :type, on: :data            # readers: id, type (extract event[:data][:id], ...)
expects :zip, on: "address.billing"      # dotted path; reader: zip
```

Subfields support all the normal options and `default:`; `readers: false` skips reader creation;
`as:`/`prefix:` rename. `default:`/`preprocess:`/`sensitive:` are **not** allowed on a *nested
parent*. Subfield hashes accept string **or** symbol keys (indifferent). Source:
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

Composing actions: a base `error` on the parent automatically prefixes a child failure surfaced via
`call!`. Reach for explicit `call` + `fail!("context: #{child.error}")` only when you need per-call
context or to absorb a child's raised exception into a parent *failure*.

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
- **`sensitive:` proc timing.** For `expects`, the `sensitive:` callable runs *before* defaults are
  applied — guard against `nil` if it depends on another field.

## Strategies (DRYed configuration via `use`)

- **`use :model, create: Widget` / `update: :widget` / `as: :widget`** — build/find an
  ActiveRecord record, assign `model_params` (defaults to `params`), save in a `before` hook, expose
  it (as `result.model` or the field name). Validation failures become clean failures with
  `record.errors` (wires `fails_on ActiveRecord::RecordInvalid`); no global report. `call` runs
  post-save. `model_params` must return a plain Hash or **permitted** params (mass-assignment
  protection — raw controller params raise; `params.permit(...)` or override `model_params`).
  <https://teamshares.github.io/axn/strategies/model>.
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

## Pointers

Human docs — <https://teamshares.github.io/axn/>:
build (`/usage/writing`), use (`/usage/using`), class DSL (`/reference/class`), instance helpers
(`/reference/instance`), result (`/reference/axn-result`), strategies (`/strategies/`), steps
(`/usage/steps`), async (`/reference/async`), config (`/reference/configuration`).

Source entry points (resolve with `bundle show axn`):
- `lib/axn.rb` — `include Axn` wiring.
- `lib/axn/core/contract.rb` — `expects`/`exposes` declaration.
- `lib/axn/core/field_resolvers/` — `model.rb` (`model:`), `extract.rb` (`on:` subfields).
- `lib/axn/core/validation/validators/` — `type`, `of`, `model`, `validate`, `shape` validators.
- `lib/axn/core/flow/` — `messages.rb`, `fails_on.rb`, `handlers/` (failure/message/callback resolution).
- `lib/axn/result.rb`, `lib/axn/core/context/facade.rb` — the `Result` surface.
- `lib/axn/strategies/` — `model.rb`, `form.rb`, `transaction.rb`.
