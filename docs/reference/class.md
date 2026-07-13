---
outline: deep
---

# Class Methods

## `.expects` and `.exposes`

Actions have a _declarative interface_, whereby you explicitly declare both inbound and outbound arguments.  Specifically, variables you expect to receive are specified via `expects`, and variables you intend to expose are specified via `exposes`.

Both `expects` and `exposes` support the same core options:

| Option | Example (same for `exposes`) | Meaning |
| -- | -- | -- |
| `sensitive` | `expects :password, sensitive: true` | Filters the field's value when logging, reporting errors, or calling `inspect`
| `default` | `expects :foo, default: 123` | If `foo` is missing or explicitly `nil`, it'll default to this value (not applied for blank values)
| `optional` | `expects :foo, optional: true` | **Recommended**: Don't fail if the value is missing, nil, or blank. Equivalent to `allow_blank: true`
| `allow_nil` | `expects :foo, allow_nil: true` | Don't fail if the value is `nil` (but will fail for blank strings)
| `allow_blank` | `expects :foo, allow_blank: true` | Don't fail if the value is blank (nil, empty string, whitespace, etc.)
| `type` | `expects :foo, type: String` | Custom type validation -- fail unless `name.is_a?(String)`
| anything else | `expects :foo, inclusion: { in: [:apple, :peach] }` | Any other arguments will be processed [as ActiveModel validations](https://guides.rubyonrails.org/active_record_validations.html) (i.e. as if passed to `validates :foo, <...>` on an ActiveRecord model)

### Dynamic `sensitive` fields

The `sensitive` option can accept a proc or symbol in addition to a boolean, allowing you to conditionally filter fields based on runtime values:

```ruby
class MyAction
  include Axn

  expects :include_pii, type: :boolean
  expects :ssn, sensitive: -> { !include_pii } # [!code focus]

  exposes :api_response, sensitive: :should_redact? # [!code focus]

  def call
    expose api_response: fetch_data
  end

  private

  def should_redact?
    !include_pii || result.api_response[:contains_secrets]
  end
end

# When include_pii is false, ssn is filtered
MyAction.call(include_pii: false, ssn: "123-45-6789")
#=> inputs: { ssn: [FILTERED], include_pii: false }

# When include_pii is true, ssn is visible
MyAction.call(include_pii: true, ssn: "123-45-6789")
#=> inputs: { ssn: "123-45-6789", include_pii: true }
```

The callable receives no arguments and is evaluated via `instance_exec`, so it has access to:
- All `expects` field values (via their reader methods, e.g., `include_pii`)
- Exposed values via `result.field` (e.g., `result.api_response`) — bare field names are **not** available for `exposes`-only fields
- Any instance methods defined on the action

::: warning Timing: sensitive evaluated before defaults
For `expects` fields, the `sensitive` callable is evaluated **before** defaults are applied. This means if your sensitivity logic depends on another field's value, that field should either be required or you should handle `nil` explicitly:

```ruby
# CAUTION: mode may be nil if caller doesn't provide it
expects :mode, default: "public"
expects :api_key, sensitive: -> { mode != "debug" }  # mode could be nil here!

# SAFER: handle nil explicitly
expects :api_key, sensitive: -> { mode.nil? || mode != "debug" }
```

This is because automatic logging of inputs happens before defaults are applied in the execution flow. For `exposes` fields, this is not a concern since output logging happens after the action completes.
:::

### Validation details

::: warning
While we _support_ complex interface validations, in practice you usually just want a `type`, if anything.  Remember this is your validation about how the action is called, _not_ pretty user-facing errors (there's [a different pattern for that](/recipes/validating-user-input)).
:::

In addition to the [standard ActiveModel validations](https://guides.rubyonrails.org/active_record_validations.html), we also support five additional custom validators:
* `type: Foo` - fails unless the provided value `.is_a?(Foo)`
  * Edge case: use `type: :boolean` to handle a boolean field (since ruby doesn't have a Boolean class to pass in directly)
    * Boolean `expects` fields also define a predicate reader, so `expects :enabled, type: :boolean` provides both `enabled` and `enabled?` on the action instance. The same applies to subfield readers unless `readers: false` is set. Boolean `exposes` fields provide predicate readers on the result, so `exposes :enabled, type: :boolean` provides `result.enabled?`.
  * Edge case: use `type: :uuid` to handle a confirming given string is a UUID (with or without `-` chars)
  * Edge case: use `type: :params` to accept either a Hash or ActionController::Parameters (Rails-compatible)
* `of: Foo` - for `type: Array` fields, validates each element (fails unless every element `.is_a?(Foo)`)
  * Accepts the same forms as `type:`: a single class (`of: String`), a union array (`of: [String, Numeric]` — an element passes if it matches *any*), the `:boolean`/`:uuid`/`:params` symbols, or a `Data.define` class
  * Only valid alongside `type: Array` (exactly) — using it on any other type, including a union like `type: [Array, String]`, raises `ArgumentError` at declaration time
  * Error messages report the failing element's index (e.g. `element at index 2 is not a String`). Pass `of: { klass: Foo, message: "..." }` to override the type description while still reporting the index
* `validate: [callable]` - Support custom validations (fails if any string is returned OR if it raises an exception)
  * Example:
    ```ruby
    expects :foo, validate: ->(value) { "must be pretty big" unless value > 10 }
    ```
* `model: true` (or `model: TheModelClass` or `model: { klass: TheModelClass, finder: :find }`) - allows auto-hydrating a record when only given its ID
  * Example:
    ```ruby
    expects :user, model: true
    # or
    expects :user, model: User
    # or with custom finder
    expects :user, model: { klass: User, finder: :find }
    ```
    This line will add expectations that:
      * `user_id` is provided (automatically derived from field name)
      * `User.find(user_id)` (or custom finder) returns a record

    And, when used on `expects`, will create reader methods for you:
      * `user` (the auto-found record)
      * `user_id` (the record's primary key) — see below

    ::: info NOTES
    * The system automatically looks for `#{field}_id` (e.g., `:user` → `:user_id`)
    * The `klass` option defaults to the field name classified (e.g., `:user` → `User`)
    * The `finder` option defaults to `:find` but can be any method that takes an ID directly
    * This works with any class that has a finder method (e.g., `User.find`, `ApiService.find_by_id`, etc.)
    * For external APIs, you can pass a `Method` object as the finder
    :::

    **The `<field>_id` reader.** Alongside `user`, a `model:` field defines a `user_id` reader whose one meaning is *the primary key of the record* — regardless of whether you were called with `user:` or `user_id:`:

    ```ruby
    expects :user, model: true
    # called with user_id: 5  → user_id == 5,         user resolves the record
    # called with user: <rec> → user_id == rec.id,    user is that record
    ```

    It never triggers an extra lookup: for the default `:find` finder a supplied id *is* the pk and is returned as-is; otherwise it reads the (memoized) record's `.id`, reusing the same resolution `user` already does. So it's meaningful even with a custom finder — where the `user_id` *key* holds a finder-specific token, `user_id` still returns the resolved record's actual primary key. The reader is alias-aware (`as: :raw_user` → `raw_user_id`) and silently defers (with a debug-level log) to any same-named method you've already declared. (Composite primary keys are not supported by the singular `<field>_id` convention.)

    **Record / id consistency.** For the default `:find` finder, passing **both** a record and a `<field>_id` that disagree (`user: <rec id=5>, user_id: 9`) raises `InboundValidationError` rather than silently preferring one — contradictory input is a developer error. Passing just one, or both in agreement, is fine. The check is skipped for custom finders, where the `<field>_id` value is a lookup token, not a primary key, so a record-vs-id comparison would be meaningless.

#### Describing the shape of structured fields (block syntax)

For a structured field — `type: Array`, `type: Hash`, or a class such as a `Data.define` — you can pass a block to declare per-member contracts (types, enums, descriptions, nesting). This works on both `expects` and `exposes`:

```ruby
exposes :integrations, type: Array, of: IntegrationRecord do
  field :source, type: String
  field :status, type: String, inclusion: { in: %w[connected connected_with_issues needs_reconnect incomplete error] }

  field :config, type: Hash do                  # nested object
    field :region, type: String
  end
  field :endpoints, type: Array do              # nested array of objects
    field :url, type: String
  end
end
```

* The block requires a single, **structured** `type:` (Array, Hash, or a class). Declaring it on a scalar type (`String`, `Integer`, `:boolean`, …), a union (`type: [Array, String]`), or with no `type:` raises `ArgumentError` at declaration time.
* For `type: Array`, each element is validated and errors report the element's index (e.g. `element at index 2: status is not included in the list`). For a `type: Hash`/class, the single value's members are validated directly.
* Members accept validations (`type`, `inclusion`, …), `optional`/`allow_blank`/`allow_nil`, and `description`, and **recurse** — a member with its own block validates its nested members at any depth. Members are validation/schema-only, so `default:`, `preprocess:`, and `sensitive:` are **not** supported on a member (they raise at declaration time).
* Unlike `expects … on:` subfields, a shape block does **not** define reader methods — there is no single value to bind (an array has many elements). It is a contract on structure only.
* Composes with `of:`: `of:` checks each element's *class*, while the block describes the element's *fields*. `of:` is optional.

#### How `optional`, `allow_blank` and `allow_nil` work with validators

When you specify `optional: true`, `allow_blank: true`, or `allow_nil: true` on a field, these options are automatically passed through to **all validators** applied to that field. This means:

- **ActiveModel validations** (like `inclusion`, `length`, etc.) will respect these options
- **Custom validators** (`type`, `validate`, `model`, `of`) will also respect these options
- **Type validator edge case**: Note passing `allow_blank` is nonsensical for type: :params and type: :boolean
- **`of` validator note**: these options govern whether the whole Array field may be absent — they do **not** make individual elements optional. A `nil` (or blank) element is still validated against `of:` regardless.

**Recommended approach**: Use `optional: true` instead of `allow_blank: true` for better clarity. The `optional` parameter is equivalent to `allow_blank: true` and makes the intent clearer.

If neither `optional`, `allow_blank` nor `allow_nil` is specified, a default presence validation is automatically added (unless the type is `:boolean` or `:params`, which have their own validation logic as described above).

### Details specific to `.exposes`

For fields you declare via `exposes`, you'll need [a corresponding `expose` call](/reference/instance#expose) — unless the field is also declared via `expects`, in which case axn auto-copies it from the input into the result on all outcome paths (success, `fail!`, and exception). See [Re-exposing an expected field](/usage/writing#re-exposing-an-expected-field-auto-copy).


### Details specific to `.expects`

#### `user_facing:` — surface a violation to the caller

By default a failed `expects` validation is **dev-facing**: it lands in the exception bucket, pages the global handler, and `result.error` is the generic `"Something went wrong"`. Mark a field `user_facing:` and a violation of it settles as a **failure** instead — firing `on_failure`, skipping the global report, and surfacing a meaningful message on `result.error`:

```ruby
expects :note, user_facing: true            # surfaces the field's own message ("Note can't be blank")
expects :note, user_facing: "Add a note"    # override the surfaced message
expects :note, user_facing: :note_message   # call an action method to compute it
expects :note, user_facing: ->(e) { ... }   # compute it from the InboundValidationError
```

The value matches the `error`/`fail!`/`fails_on` handler shape — `true`, a String, a Symbol naming an action method, or a Proc; one that resolves blank falls back to the field's own validation message. The surfaced message is a failure **reason**, so a declared base `error` [attaches it under the base](/usage/writing#prefixing-failure-reasons) by default (standalone with no base), just like a `fail!` message. The field stays **required** (unlike `optional:`, which removes the check) — `user_facing:` changes who is blamed for a violation, not whether it's validated. In a mixed failure (a `user_facing:` field *and* a plain one both invalid), the dev-facing one dominates and the call still pages. **`user_facing:` is for top-level fields only:** it can't be declared on a subfield (`on:`), and it's rejected on a field that *has* nested expectations — subfields (`on:`) or a shape block (`do … end`). Those nested/member checks are always dev-facing, so mixing them with `user_facing:` is a declaration error. See [the narrative](/usage/writing#user-facing-contract-violations) for the full picture.

#### Nested/Subfield expectations

`expects` is for defining the inbound interface. Usually it's enough to declare the top-level fields you receive, but sometimes you want to make expectations about the shape of that data, and/or to define easy accessor methods for deeply nested fields. `expects` supports the `on` option for this (all the normal attributes can be applied as well):

```ruby
class Foo
  expects :event
  expects :data, type: Hash, on: :event  # [!code focus:2]
  expects :some, :random, :fields, on: :data
  expects :optional_field, on: :data, default: "default value"  # [!code focus]

  def call
    puts "THe event.data.random field's value is: #{random}"
  end
end
```

::: tip Subfield Defaults
Defaults work the same way for subfields as they do for top-level fields - they are applied when the subfield is missing or explicitly `nil`, but not for blank values.
:::

#### Reaching into nested parents

`on:` accepts a **dotted path** to declare a subfield of a deeply-nested parent, with a clean flat reader named after the field:

```ruby
expects :address, type: Hash
expects :zip, on: "address.billing", type: String  # validates address[:billing][:zip]; defines a `zip` reader
```

The **root** segment (`address`) must be a declared field (or subfield); intermediate segments are assumed to be hashes. The reader is named after the subfield (`zip`) — there's no ambiguity, since the field name itself has no dots.

::: warning
`default:`, `preprocess:`, and `sensitive:` are **not** supported on a **nested** parent (they raise at declaration time) — `default:`/`preprocess:` write into the parent, and `sensitive:` relies on the log filter matching a top-level field, neither of which handles a nested path yet. A parent is nested whether reached via a dotted path (`on: "address.billing"`) or by pointing `on:` at another subfield (whose value lives inside *its* parent). Use them on a subfield of a top-level field, or declare the intermediate levels explicitly.
:::

#### Disabling subfield readers

By default, subfields create top-level reader methods (e.g., `random` in the example above). You can disable this with `readers: false`:

```ruby
expects :data, type: Hash, on: :event, readers: false
```

This is useful when you have duplicate sub-keys across different parent fields, or when you want to access subfields only through the parent. Note that `readers: false` is only valid for subfields (i.e., when using `on:`) — using it on top-level fields will raise an `ArgumentError`.

#### Renaming the reader (`as:` / `prefix:`)

By default the generated reader is named after the field — `expects :channel` defines a `channel` reader. Use `as:` to give the reader a different name while keeping `channel` as the caller-facing contract. The most common motivation is freeing the field's name so you can define your own method on top of the raw input:

```ruby
expects :channel, as: :raw_channel              # caller still passes `channel:`
def channel = @channel ||= Channel.find(raw_channel)
```

The wire key stays canonical everywhere caller-facing — validation messages, required-inputs, logging, and sensitive-field filtering all still key off `channel`. Only the in-action reader (and its `?` predicate) is renamed.

`as:` applies to a single field. For subfields it's especially handy to disambiguate or namespace unwrapped values; `prefix:` is sugar that renames several at once (literal concatenation, so you supply the separator):

```ruby
expects :event_params, type: Hash
expects :id, on: :event_params, as: :event_id           # reader: event_id (extracts `id`)
expects :id, :type, on: :event_params, prefix: :event_  # readers: event_id, event_type
```

`as:`/`prefix:` cannot be combined, can't be used with `readers: false`, and can't rename a dotted `on:` path (which generates no reader) — each raises at declaration time. A renamed reader must clear the same reserved-name bar as a field and can't collide with another reader. Renaming composes with `model:` — the model is resolved (including the `<field>_id` lookup) against the wire key and exposed under the aliased reader.

When you declare subfields `on:` a renamed parent, reference it by its **reader name** (the alias), not the wire key — `on:` is resolved by calling the parent's reader:

```ruby
expects :channel, type: Hash, as: :raw_channel
expects :id, on: :raw_channel    # ✅ reader name;  on: :channel would raise (no `channel` reader)
```

#### `preprocess`
`expects` also supports a `preprocess` option that, if set to a callable, will be executed _before_ applying any defaults or validations. Use it for a custom, field-specific transform. For the common case of turning a wire string into a Ruby type (`Date`/`Symbol`/…), prefer `coerce:` (below), which is the shared, standard inverse of the output serializer. If the preprocess callable raises an exception, that'll be swallowed and the action failed.

#### `coerce`
`expects` supports a `coerce:` option that parses an inbound wire string into its declared Ruby type _before_ your `preprocess`, defaults, and validation run — the inbound inverse of how a `Date`/`Symbol` result serializes on the way out. This closes the round-trip gap: a JSON client (or a Rails form) sending `"2026-07-08"` or `"active"` is accepted for a `Date`/`Symbol` field, rather than rejected for not already being the Ruby object.

```ruby
expects :on, coerce: Date                          # "2026-07-08"  → Date
expects :mode, coerce: Symbol, inclusion: { in: %i[a b] }  # "a" → :a, then validated
expects :count, coerce: Integer                    # "123" → 123 (base 10)
expects :on, type: { klass: Date, coerce: true }   # explicit form (use with sibling type options like message:)
expects :on, coerce: [Date, String]                # union: parse a date if possible, else keep the string
```

The supported types are `Date`, `DateTime`, `Time`, `Symbol`, `Integer`, and `Float` — those with a strict, unambiguous string parse. Coercion is **coerce-or-leave**: only strings are transformed (a value already of the right type, or a JSON-native number, is untouched; a blank string is left as-is so presence validation still applies), and an unparseable string passes through to a normal validation error (reported as "could not be coerced to a Date", distinct from a wrong-type "is not a Date"). `coerce:` is opt-in per field, so a direct Ruby caller's strictness is unchanged, and it is valid on top-level `expects` fields only.

Date/time coercion accepts any **ISO-8601-shaped** wire string — a `YYYY-MM-DD` date optionally followed by a time (`T` or space separator, optional seconds/fraction, optional `Z`/`±HH:MM` offset). That covers JSON/RFC3339 timestamps, a Rails `date_field` (`2026-07-08`), a `datetime-local` (`2026-07-08T14:30`, no offset — read in the local zone), and Rails' `Time#to_s` (`2026-07-08 14:30:00 +0000`). Ambiguous or partial input that Ruby's `Date.parse`/`Time.parse` would otherwise guess against today's date (`"12"`, `"01/02/2026"`, a bare `14:30` time) is left uncoerced and fails validation rather than becoming a silently-wrong value.

##### Coercing a whole action: `coerce_input_types`

Per-field `coerce:` is the right tool for a single wire-shaped field. For an action that is _entirely_ transport-facing — a controller handing it a params hash of strings, an adapter decoding JSON — annotating every field is noise. The `coerce_input_types` config setting declares "treat all inbound values here as wire data": when on, every field with a coercible declared type behaves as if it set `coerce: true`.

```ruby
# Whole app (a consumer's informed choice — e.g. a pure-API service):
Axn.config.coerce_input_types = true

# One action (or a base class its controller-facing actions inherit):
class CreateThing
  include Axn
  configure { |c| c.coerce_input_types = true }
  expects :starts_on, type: Date   # "2026-07-08" is now coerced, no per-field coerce:
end
```

The default is **off** (`false`), and deliberately so: `type: Date` is a contract assertion, and a string where a `Date` is declared is usually a bug for an in-process Ruby caller — coercing it globally by default would mask that. You opt in where you know the input crossed a wire.

A field's own `coerce:` always wins over the flag, so a mixed action can opt one field back out with the explicit form:

```ruby
class ImportRow
  include Axn
  configure { |c| c.coerce_input_types = true }
  expects :on, type: Date                          # coerced
  expects :raw, type: { klass: Date, coerce: false }  # left strict despite the flag
end
```

Scope matches `coerce:` itself — **top-level `expects` fields only** today (non-coercible types like `String`/`Hash` are untouched; subfields are not reached). When subfield coercion is added in a future release, `coerce_input_types` will extend to subfields automatically.

## `.success` and `.error`

The `success` and `error` declarations allow you to customize the `error` and `success` messages on the returned result.

Both methods accept a string (returned directly), a symbol (resolved as a local instance method on the action), or a block (evaluated in the action's context, so can access instance methods and variables).

When an exception is available (e.g., during `error`), handlers can receive it in either of two equivalent ways:
- Keyword form: accept `exception:` and it will be passed as a keyword
- Positional form: if the handler accepts a single positional argument, it will be passed positionally

This applies to both blocks and symbol-backed instance methods. Choose the style that best fits your codebase (clarity vs concision).

In callables and symbol-backed methods, you can access:
- **Input data**: Use field names directly (e.g., `name`)
- **Output data**: Use `result.field` pattern (e.g., `result.greeting`)
- **Instance methods and variables**: Direct access

```ruby
success { "Hello #{name}, your greeting: #{result.greeting}" }
error { |e| "Bad news: #{e.message}" }
error { |exception:| "Bad news: #{exception.message}" }

# Using symbol method names
success :build_success_message
error :build_error_message

def build_success_message
  "Hello #{name}, your greeting: #{result.greeting}"
end

def build_error_message(e)
  "Bad news: #{e.message}"
end

def build_error_message(exception:)
  "Bad news: #{exception.message}"
end
```

## Message Matching Order {#message-matching-order}

Messages follow the [base/reason model](/usage/writing#prefixing-failure-reasons): an **unconditional** `error`/`success` (literal or block) is the **base headline**, while a **conditional** (`if:`/`unless:`) or explicitly `standalone: false` entry is a **reason**. Resolution shows the most-recently-declared matching *reason* (attached under the base), or — when none matches — the base headline, or finally the generic default.

### How It Works

1. Entries are stored **last-defined-first** and evaluated in that order.
2. The displayed message is the first matching **reason** (a conditional or `standalone: false` entry), attached under the base.
3. If no reason matches, the **base headline** is shown — it's found by shape, so **its declaration position doesn't matter**.
4. Among multiple reasons that could match (or multiple unconditional headlines), the **most-recently declared wins** — so declare the most-specific reasons last.

### The base's position doesn't matter

Because the base is identified by shape, matching reasons are attached under it no matter where it's declared — there is no "shadowing" to avoid (declaring it last is fine):

```ruby
class MyAction
  include Axn

  error "Invalid input provided", if: ArgumentError
  error "Record not found", if: ActiveRecord::RecordNotFound
  error "Something went wrong"   # the base — position-independent
end

# ArgumentError raised => "Something went wrong: Invalid input provided"
# unmatched exception   => "Something went wrong"  (base alone)
```

### With Inheritance

Child class entries are evaluated before parent class entries, so a child's headline (or matching reason) wins over the parent's:

```ruby
class ParentAction
  include Axn
  error "Parent error"
end

class ChildAction < ParentAction
  error "Child error"   # wins — child is evaluated first
end
```

## Conditional messages

While `.error` and `.success` set the default messages, you can register conditional messages using an optional `if:` or `unless:` matcher. The matcher can be:

- an exception class (e.g., `ArgumentError`)
- a class name string (e.g., `"Axn::InboundValidationError"`)
- a symbol referencing a local instance method predicate (arity 0 or 1, or keyword `exception:`), e.g. `:bad_input?`
- a callable (arity 0 or 1, or keyword `exception:`)

Symbols are resolved as methods on the action instance. If the method accepts `exception:` it will be passed as a keyword; otherwise, if it accepts one positional argument, the raised exception is passed positionally; otherwise it is called with no arguments. If the action does not respond to the symbol, we fall back to constant lookup (e.g., `if: :ArgumentError` behaves like `if: ArgumentError`). Symbols are also supported for the message itself (e.g., `success :method_name`), resolved via the same rules.

```ruby
error "bad"

# Custom message with exception class matcher
error "Invalid params provided", if: ActiveRecord::InvalidRecord

# Custom message with callable matcher and message
error(if: ArgumentError) { |e| "Argument error: #{e.message}" }
error(if: -> { name == "bad" }) { "Bad input #{name}, result: #{result.status}" }

# Base error attaches to a conditional reason by default
error "Foo"                                    # base — never itself shown as a reason
error("bar", if: ArgumentError)                # ArgumentError => "Foo: bar"
error(if: TypeError, &:message)                # TypeError     => "Foo: <exception.message>"
# (reasons are checked last-declared-first; if two conditional reasons both match the same
#  exception, the later-declared one wins — keep their matchers disjoint to avoid surprises)

# Custom message with symbol predicate (arity 0)
error "Transient error, please retry", if: :transient_error?

def transient_error?
  # local decision based on inputs/outputs
  name == "temporary"
end

# Symbol predicate (arity 1), receives the exception
error(if: :argument_error?) { |e| "Bad argument: #{e.message}" }

def argument_error?(e)
  e.is_a?(ArgumentError)
end

# Symbol predicate (keyword), receives the exception via keyword
error(if: :argument_error_kw?) { |exception:| "Bad argument: #{exception.message}" }

def argument_error_kw?(exception:)
  exception.is_a?(ArgumentError)
end

# Lambda predicate with keyword
error "AE", if: ->(exception:) { exception.is_a?(ArgumentError) }

# Using unless: for inverse logic
error "Custom error", unless: :should_skip?

def should_skip?
  # local decision based on inputs/outputs
  name == "temporary"
end

::: warning
You cannot use both `if:` and `unless:` for the same message - this will raise an `ArgumentError`.
:::

## Composing error messages across actions

Most of the time you don't need to do anything special: declare a base `error` on the parent and it attaches to the parent's own failures *and* any child failure surfaced via `call!`. A child that fails via `fail!` re-raises the same `Axn::Failure` (no wrapping), so the base is prepended automatically — see [Prefixing failure reasons](/usage/writing#prefixing-failure-reasons).

```ruby
class OuterAction
  include Axn
  error "Couldn't onboard"

  def call
    InnerAction.call!(...) # inner's fail!("email taken") surfaces as "Couldn't onboard: email taken"
  end
end
```

Reach for an explicit `call` + `fail!` only when the base headline isn't enough — specifically:

- **Per-call-site context**, when a single class-level headline can't express what you need (e.g. distinguishing two invocations of the same child). Don't also repeat the headline in the `fail!` string — a declared base already attaches to it (`"<base>: validating: …"`).

  ```ruby
  def call
    a = StepA.call(...); fail!("validating: #{a.error}") unless a.ok?
    b = StepB.call(...); fail!("charging: #{b.error}") unless b.ok?
  end
  ```

- **Absorbing an unhandled child exception** into a parent *failure* rather than letting it stay an exception. A child that fails via a raw exception (not `fail!`) re-raises *that exception* through `call!`, so the parent settles as an `exception` outcome whose `result.error` is just the parent's headline (the child's message isn't woven in). Running the child with non-bang `call` and `fail!`ing on `!result.ok?` instead converts it to a `failure` outcome whose message carries the child's error. Either way the exception is [reported once](/usage/writing#reporting-a-nested-bug-once) — so this choice is about the **outcome and message**.

::: tip Suppressing reports for expected failures
If an inner action raises an exception that is an expected business outcome (not a bug), declare `fails_on ExceptionClass` on the **inner** action to reclassify it into the failure bucket — it fires `on_failure`, skips `Axn.config.on_exception`, and preserves the original exception on `result.exception`. See [Suppressing reports for expected failures](/usage/writing#suppressing-reports-for-expected-failures-in-composed-actions).
:::

## `.async`

Configures the async execution behavior for the action. This determines how the action will be executed when `call_async` is called.

```ruby
class MyAction
  include Axn

  # Configure Sidekiq
  async :sidekiq do
    sidekiq_options queue: "high_priority", retry: 5, priority: 10
  end

  # Or use keyword arguments (shorthand)
  async :sidekiq, queue: "high_priority", retry: 5

  # Configure ActiveJob
  async :active_job do
    queue_as "data_processing"
    self.priority = 10
    self.wait = 5.minutes
  end

  # Disable async execution
  async false

  expects :input

  def call
    # Action logic here
  end
end
```

### Available Adapters

**`:sidekiq`** - Integrates with Sidekiq background job processing
- Supports all Sidekiq configuration options via `sidekiq_options`
- Supports keyword argument shorthand for common options (`queue`, `retry`, `priority`)

**`:active_job`** - Integrates with Rails' ActiveJob framework
- Supports all ActiveJob configuration options
- Works with any ActiveJob backend (Sidekiq, Delayed Job, etc.)

**`false`** - Disables async execution
- `call_async` will raise a `NotImplementedError`

### Inheritance

Async configuration is inherited from parent classes. Child classes can override the parent's configuration:

```ruby
class ParentAction
  include Axn

  async :sidekiq do
    sidekiq_options queue: "parent_queue"
  end
end

class ChildAction < ParentAction
  # Inherits parent's Sidekiq configuration
  # Can override with its own configuration
  async :active_job do
    queue_as "child_queue"
  end
end
```

### Default Configuration

If no async configuration is specified, the action will use the default configuration set via `Axn.config.set_default_async`. If no default is set, async execution is disabled.

## Callbacks

In addition to the [global exception handler](/reference/configuration#on-exception), a number of custom callback are available for you as well, if you want to take specific actions when a given Axn succeeds or fails.

::: tip Callback Ordering
* Callbacks are executed in **last-defined-first** order, similar to messages
* Child class callbacks execute before parent class callbacks
* Multiple matching callbacks of the same type will *all* execute
:::


::: tip Callbacks vs Hooks
  * *Hooks* (`before`/`after`) are executed _as part of the `call`_ -- exceptions or `fail!`s here _will_ change a successful action call to a failure (i.e. `result.ok?` will be false)
  * *Callbacks* (defined below) are executed _after_ the `call` -- exceptions or `fail!`s here will _not_ change `result.ok?`
:::


**Note:** Symbol method handlers for all callback types follow the same argument pattern as [message handlers](#conditional-messages):
- If the method accepts `exception:` as a keyword, the exception is passed as a keyword
- If the method accepts one positional argument, the exception is passed positionally
- Otherwise, the method is called with no arguments

::: warning
You cannot use both `if:` and `unless:` for the same callback - this will raise an `ArgumentError`.
:::

### `on_success`

This is triggered after the Axn completes successfully, once the enclosing database transaction has committed (immediately if none is open); it is skipped if that transaction rolls back. Nested `on_success` callbacks fire child-first (inner before outer). Difference from `after`: if the given block raises an error, this WILL be reported to the global exception handler, but will NOT change `ok?` to false.

### `on_error`

Triggered on ANY error (explicit `fail!` or uncaught exception). Optional filter argument works the same as `on_exception` (documented below).

`on_error` is a superset of `on_failure` and `on_exception`, so it co-fires with whichever specific bucket applies: a `fail!` triggers both `on_error` and `on_failure`, and an uncaught exception triggers both `on_error` and `on_exception`. If you register `on_error` alongside the specific callback, expect both to run — they are not mutually exclusive.

### `on_failure`

Triggered ONLY on explicit `fail!` (i.e. _not_ by an uncaught exception). Optional filter argument works the same as `on_exception` (documented below).

### `on_exception`

Much like the [globally-configured on_exception hook](/reference/configuration#on-exception), you can also specify exception handlers for a _specific_ Axn class:

```ruby
class Foo
  include Axn

  on_exception do |exception| # [!code focus:3]
    # e.g. trigger a slack error
  end
end
```

Note that by default the `on_exception` block will be applied to _any_ `StandardError` that is raised, but you can specify a matcher using the same logic as for conditional messages (`if:` or `unless:`):

```ruby
class Foo
  include Axn

  on_exception(if: NoMethodError) do |exception| # [!code focus]
    # e.g. trigger a slack error
  end

on_exception(unless: :transient_error?) do |exception| # [!code focus]
    # e.g. trigger a slack error for non-transient errors
  end

def transient_error?
  # local decision based on inputs/outputs
  name == "temporary"
end

  on_exception(if: ->(e) { e.is_a?(ZeroDivisionError) }) do # [!code focus]
    # e.g. trigger a slack error
  end
end
```


If multiple `on_exception` handlers are provided, ALL that match the raised exception will be triggered in the order provided.

The _global_ handler will be triggered _after_ all class-specific handlers.

## `.fails_on`

`fails_on` reclassifies the listed exception classes from the **exception** outcome into the **failure** outcome: a matching raised exception settles as a failed result (firing `on_failure`, **not** `on_exception`, and skipping the global `on_exception` report) while the original exception is preserved on `result.exception` so the normal `error` message resolution still applies. It does not wrap the exception in `Axn::Failure`.

```ruby
class SubmitOrder
  include Axn

  fails_on ActiveRecord::RecordInvalid                       # default message
  # fails_on ActiveRecord::RecordInvalid, "Unable to submit" # positional string
  # fails_on(ActiveRecord::RecordInvalid) { |e| e.message }  # block (receives the exception)
  # fails_on [RecordInvalid, RecordNotUnique], "Couldn't save"

  def call = order.save!
end
```

Signature: `fails_on(exceptions, message = nil, &block)` — `exceptions` is an Exception class or array of classes; the optional message/block is wired through the [`error`](#message-matching-order) DSL (so it composes with base/reason attachment and ordering). See [Reclassifying exceptions as failures](/usage/writing#reclassifying-exceptions-as-failures) for the full explanation, and the [Model strategy](/strategies/model) for the common ActiveRecord case.

## Contract reflection (`.input_schema` / `.output_schema`)

`.input_schema` and `.output_schema` return [JSON Schema](https://json-schema.org/) Hashes derived from your `expects`/`exposes` declarations — the lingua franca that OpenAPI, MCP `inputSchema`, and LLM function-calling `parameters` all speak. Paired with `Axn::Reflection::Values.serialize_exposed(result, configs)` (which renders a result to a JSON-safe Hash), this is the groundwork for exposing any Axn as a callable tool. Both methods are read-only and **off the execution path** — reflecting an Axn never instantiates it, runs its validators, or executes any of your code. (One deliberate exception: `input_schema` logs a single diagnostic warning per class when it omits a deep subfield that has no JSON-object representation — see below — writing only to the configured logger.)

```ruby
class FindWidget
  include Axn
  expects :id, type: :uuid
  expects :verbose, type: :boolean, default: false
  exposes :widget, type: Hash
end

FindWidget.input_schema
#=> { type: "object",
#     properties: { id: { type: "string", format: "uuid" },
#                   verbose: { type: "boolean", default: false } },
#     required: ["id"] }   # `verbose` is optional — it has a default
```

A field is marked `required` unless a **declared signal** says it may be omitted: a usable `default:` (present, and not blank — a `default: {}`/`""` can't satisfy the field's presence, so it stays required), or a nil/blank-tolerant declaration (`optional:` / `allow_nil:` / `allow_blank:` / `presence: false`). Every `exposes` field is `required` in `output_schema` (the serializer always emits every key; nullability is carried by the property's `type`, e.g. `["string", "null"]`).

::: warning Requiredness is advisory, not a runtime guarantee
To keep reflection cheap and free of running your code, the schema is built from your **declarations**, not by test-running your validators against each default. In these narrow cases the reflected `required` can therefore disagree with what `Axn.call` actually accepts:

- a **non-blank but invalid default** (e.g. `expects :name, type: String, default: 123`) is reflected as optional, but omitting it still fails validation at runtime — a self-contradictory contract;
- a **`model:` subfield nested under a parent, paired with a sibling defaulted `<field>_id` subfield**: at runtime the parent is synthesized and the id default supplies the lookup token, so the parent is omittable — but the schema reflects it as `required` (the safe, stricter direction). Shallow `model:` fields and their explicit shallow `<field>_id` siblings *are* reconciled precisely.

These surface as ordinary, recoverable validation errors (a tool client simply gets a failed result and can retry). Give the default a valid value, drop the parent's `allow_nil:`, or send the parent explicitly, and the schema and runtime agree.
:::

Subfields nest to any depth: a dotted `on:` path (`on: "address.billing"`), a subfield of a subfield, and a dotted field name (`expects "bar.baz", on: :foo`) all appear as recursively nested object `properties`, keyed by wire key (aliases resolve to the key a client actually sends). A required subfield at any depth forces its whole ancestor chain into `required` (and strips those ancestors' nullability): a `nil`/omitted ancestor yields every descendant absent, so runtime could never satisfy the leaf. Intermediate keys introduced by a dotted segment reflect as plain object properties that are required (and non-nullable) exactly when something beneath them is. The structural exclusions: a deep subfield whose chain passes through a `model:` parent (the client sends `<field>_id`, not the object) or a non-object parent (`type: Array`, a mixed union) has no JSON-object representation, and a dotted-NAME `model:` config (`expects "org.company", on: :payload, model:`) has no JSON-consumable id (a dotted subfield name generates no reader, so the runtime never runs the id→record lookup and the advertised `<field>_id` can't feed it — a dotted `on:` with a non-dotted name like `expects :company, on: "payload.org", model:` still works and is kept). All are omitted from the schema — calling `input_schema` on such a class logs a one-time warning naming the omitted field(s), so the gap is visible rather than silent when you build tooling on the schema.

::: tip Ruby-object input types are coercible
The schema advertises each `type:` as its JSON wire form — so `expects :on, type: Date` shows `{ type: "string", format: "date" }` and `expects :mode, type: Symbol` shows `{ type: "string" }`. Add `coerce:` (see [`coerce`](#coerce) above) so a JSON client sending the string `"2026-07-08"` or `"active"` is parsed into the declared `Date`/`Symbol` — the inbound inverse of how the value serializes on output. Without `coerce:`, core still validates strictly against the Ruby type (a direct Ruby caller must pass a real `Date`).
:::

