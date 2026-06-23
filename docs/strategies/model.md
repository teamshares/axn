# Model Strategy

The `model` strategy standardizes the common "build or find an ActiveRecord model, apply attributes, save it, and settle validation failures cleanly" action. It is the sibling of the [Form strategy](/strategies/form): use `form` to validate user input through a form object; use `model` when there's a real ActiveRecord model and you want to validate-and-save it directly.

::: tip When to Use
Use the model strategy for create/update actions backed by a single ActiveRecord model. Validation failures become clean, user-facing failures (with `record.errors`) instead of exceptions reported to your global handler.
:::

::: warning Requires ActiveRecord
The strategy is built on ActiveRecord persistence (`save`, `previously_new_record?`, the `model: true` finder, `ActiveRecord::RecordInvalid`), so `use :model` raises `NotImplementedError` at declaration time if ActiveRecord isn't loaded — same as [`use :transaction`](/strategies/transaction).
:::

## Basic Usage

```ruby
class CreateWidget
  include Axn

  use :model, create: Widget

  # Supply the attributes (defaults to `params` if omitted)
  def model_params = params.slice(:name, :category)
end

CreateWidget.call(params: { name: "Sprocket" })
# => ok; result.model is the persisted Widget, result.success == "Created Widget"

CreateWidget.call(params: { name: "" })
# => not ok; result.outcome.failure?; result.error == "Name can't be blank"
#    (no exception reported to Axn.config.on_exception)
```

The save happens in a `before` hook (mirroring the form strategy's validate-in-`before`), so `call` is reserved for **post-save** logic — and is optional. For a plain create/update you write no `call` at all.

## Modes

Pick the mode that matches the action:

| Declaration | Mode | Behavior |
| ----------- | ---- | -------- |
| `use :model, create: Widget` | create | Builds `Widget.new(model_params)` and saves it |
| `use :model, update: :widget` | update | Updates the passed-in `:widget` record (input **required**) |
| `use :model, as: :widget` | upsert | Updates `:widget` if provided/found, otherwise creates one |

```ruby
# Update — the record is fed in and re-exposed
class UpdateWidget
  include Axn
  use :model, update: :widget

  def model_params = params.slice(:name)
end

UpdateWidget.call(widget: existing, params: { name: "New name" })
# => ok; result.widget.name == "New name"; result.success == "Updated Widget"
```

In **upsert** mode the model class is derived from the field name (`:widget → Widget`); the record is found via the standard `model: true` contract (e.g. a provided `widget:` or a `widget_id:`), and built fresh when absent.

You can force a mode at a call-site where only one is valid with `persist: :create` / `persist: :update`.

## Configuration Options

| Option | Default | Description |
| ------ | ------- | ----------- |
| `create` | — | Create-mode: the model class to instantiate |
| `update` | — | Update-mode: the (required) input field holding the record |
| `as` | — | Upsert-mode: input field; class derived from the name |
| `expect` | `:params` | The params field name to read from |
| `persist` | inferred | Force `:create` or `:update` |
| `inject` | `nil` | Context field(s) merged into `model_params` |

### Automatic contract

The strategy declares the contract for you — you don't write `expects :params` or `expects :widget`:

- `expects :params` (override the key with `expect:`).
- The model field (`update:`/`as:`) as a `model: true` input — **required** for `update`, optional for `upsert`. If you need custom options on that field (e.g. a custom `finder:`), declare it **before** `use :model` and the strategy will respect your declaration. (Declaring it *after* `use :model` raises `DuplicateFieldError` — the strategy has already declared it.)

The record is exposed under the field name, or — when no field is named (create mode without `as:`) — as `result.model`. Pass `as:` to choose the exposure name explicitly.

## Supplying attributes: `model_params`

Define `model_params` to control what gets assigned. It runs in full instance context, so it can reference other fields and helpers. It defaults to the full `params` hash.

```ruby
use :model, create: Distribution, as: :distribution

def model_params
  params.slice(:amount).merge(created_by: Current.user)
end
```

For the common "merge a context field" case, `inject:` is sugar that merges named context fields into the attributes — regardless of whether you override `model_params`:

```ruby
use :model, create: Widget, inject: [:company]
# attributes include { company: company }
```

If an injected field collides with a key your `model_params` already sets, the explicit `model_params` value wins. (`inject:` is meant for scalar/model context fields like `Current.user` — don't inject a raw params object.)

::: warning Strong parameters
`model_params` must return a plain `Hash` or **permitted** `ActionController::Parameters`. The default returns `params` as-is, which is fine for a plain Hash or already-permitted params — but raw, unpermitted controller params raise an actionable error directing you to permit them (`params.permit(...)`) or override `model_params`. This preserves Rails' mass-assignment protection rather than silently bypassing it.
:::

## Imperative pre-save tweaks: `prepare_model`

`model_params` is for the *declarative* attributes hash. For tweaks that don't fit a flat hash — mutating a nested association, deriving one field from another, conditional assignment — define `prepare_model(record)`. It runs once, after `model_params` is assigned and always **before** the save (so it can fix the record up), with the record passed in:

```ruby
use :model, update: :company

def model_params = params.slice(:closed_at, :display_name)

def prepare_model(company)
  return if company.initial_valuation.blank?

  company.initial_valuation.valuation_type ||= Valuation::FLOOR_VALUATION_TYPE
  company.initial_valuation.effective_at = company.closed_at
end
```

Use it for record-level manipulation; keep plain attribute assignment in `model_params`. (For post-**save** work — notifications, sub-actions, state transitions — use `call`, which runs after the record is persisted.)

## Messages

The strategy ships sensible defaults, resolved through the normal [message DSL](/usage/writing#customizing-messages):

- **Success** (mode-aware): `"Created <Model>"` / `"Updated <Model>"`.
- **Error**: the model's `errors.full_messages.to_sentence` (clean — not the raw `"Validation failed: …"`).

To prefix the validation-error message, declare a base `error` after `use :model` — the strategy's validation body is prefixed automatically:

```ruby
use :model, update: :user
error "Unable to update profile"
# => "Unable to update profile: Name can't be blank"
```

For a custom `success` string or [`fails_on`](/usage/writing#reclassifying-exceptions-as-failures), declare it with the normal DSL **after** `use :model` (later declarations win):

```ruby
use :model, create: Widget
success "Your widget is ready!"
```

A declared `error` is the **base** that *prefixes* the validation body (as shown above), not a replacement. To render a fixed message *without* the validation detail, opt that reason out of prefixing — e.g. `error "Could not save the widget", if: ActiveRecord::RecordInvalid, prefixed: false`.

## Validation failures are failures, not exceptions

A failed `save` settles the result as a **failure** (`result.outcome.failure?`), with `record.errors` populated for re-rendering and **no** report sent to `Axn.config.on_exception`. The strategy also wires [`fails_on ActiveRecord::RecordInvalid`](/usage/writing#reclassifying-exceptions-as-failures) as a safety net, so a *raised* `RecordInvalid` (e.g. a `save!` in your `call`, association autosave, or a nested action) is reclassified the same way.

## Transactions

The model strategy does **not** wrap your action in a transaction. If `call` does post-save work that should roll back the save on failure, compose it explicitly:

```ruby
use :model, create: Widget
use :transaction
```

This keeps `:model` single-purpose and avoids implicitly wrapping non-DB side effects (enqueuing jobs, sending email) in a transaction.

## Composing with custom `call`

Because the save runs in `before`, `call` runs only after the record is persisted — ideal for follow-on work:

```ruby
class PublishPost
  include Axn
  use :model, update: :post
  use :transaction

  def model_params = params.slice(:title, :body, :published_at)

  def call
    # post is already saved here
    NotifySubscribers.call!(post:)
  end
end
```
