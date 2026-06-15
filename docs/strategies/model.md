# Model Strategy

The `model` strategy standardizes the common "build or find an ActiveRecord model, apply attributes, save it, and settle validation failures cleanly" action. It is the sibling of the [Form strategy](/strategies/form): use `form` to validate user input through a form object; use `model` when there's a real ActiveRecord model and you want to validate-and-save it directly.

::: tip When to Use
Use the model strategy for create/update actions backed by a single ActiveRecord model. Validation failures become clean, user-facing failures (with `record.errors`) instead of exceptions reported to your global handler.
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
| `error_prefix` | `nil` | Prefix prepended to the validation-error message |
| `success` | mode-aware | Override the success message |

### Automatic contract

The strategy declares the contract for you — you don't write `expects :params` or `expects :widget`:

- `expects :params` (override the key with `expect:`).
- The model field (`update:`/`as:`) as a `model: true` input — **required** for `update`, optional for `upsert`. If you've already declared that field yourself (e.g. with a custom `finder:`), the strategy respects your declaration.

The record is exposed under the field name, or — when no field is named (create mode without `as:`) — as `result.model`. Pass `as:` to choose the exposure name explicitly.

## Supplying attributes: `model_params`

Define `model_params` to control what gets assigned. It runs in full instance context, so it can reference other fields and helpers. It defaults to the full `params` hash.

```ruby
use :model, create: Distribution, as: :distribution

def model_params
  params.slice(:amount).merge(created_by: Current.user)
end
```

For the common "merge a context field" case, `inject:` is sugar that merges named fields on top of `model_params` (whether or not you override it):

```ruby
use :model, create: Widget, inject: [:company]
# model_params is merged with { company: company }
```

## Messages

The strategy ships sensible defaults, resolved through the normal [message DSL](/usage/writing#customizing-messages):

- **Success** (mode-aware): `"Created <Model>"` / `"Updated <Model>"`.
- **Error**: the model's `errors.full_messages.to_sentence` (clean — not the raw `"Validation failed: …"`).

Override just the prefix while keeping the validation body:

```ruby
use :model, update: :user, error_prefix: "Unable to update profile: "
# => "Unable to update profile: Name can't be blank"
```

Override the success string:

```ruby
use :model, create: Widget, success: "Your widget is ready!"
```

For a full override, declare your own `success` / `error` / [`fails_on`](/usage/writing#reclassifying-exceptions-as-failures) **after** `use :model` — later declarations win.

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
