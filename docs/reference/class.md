# Class Methods

## `.expects` and `.exposes`

Actions have a _declarative interface_, whereby you explicitly declare both inbound and outbound arguments.  Specifically, variables you expect to receive are specified via `expects`, and variables you intend to expose are specified via `exposes`.

Both `expects` and `exposes` support the same core options:

| Option | Example (same for `exposes`) | Meaning |
| -- | -- | -- |
| `sensitive` | `expects :password, sensitive: true` | Filters the field's value when logging, reporting errors, or calling `inspect`
| `default` | `expects :foo, default: 123` | If `foo` isn't explicitly set, it'll default to this value
| `allow_blank` | `expects :foo, allow_blank: true` | Don't fail if the value is blank
| `type` | `expects :foo, type: String` | Custom type validation -- fail unless `name.is_a?(String)`
| anything else | `expects :foo, inclusion: { in: [:apple, :peach] }` | Any other arguments will be processed [as ActiveModel validations](https://guides.rubyonrails.org/active_record_validations.html) (i.e. as if passed to `validates :foo, <...>` on an ActiveRecord model)


### Validation details

::: warning
While we _support_ complex interface validations, in practice you usually just want a `type`, if anything.  Remember this is your validation about how the action is called, _not_ pretty user-facing errors (there's [a different pattern for that](/recipes/validating-user-input)).
:::

In addition to the [standard ActiveModel validations](https://guides.rubyonrails.org/active_record_validations.html), we also support three additional custom validators:
* `type: Foo` - fails unless the provided value `.is_a?(Foo)`
* `boolean: true` - wrapper to handle a boolean field (since ruby doesn't have a Boolean class, so we can't use `type:` directly)
* `validate: [callable]` - Support custom validations (fails if any string is returned OR if it raises an exception)
  * Example:
    ```ruby
    expects :foo, validate: ->(value) { "must be pretty big" unless value > 10 }
    ```



### Details specific to `.expects`

`expects` also supports a `preprocess` option that, if set to a callable, will be executed _before_ applying any validations.  This can be useful for type coercion, e.g.:

```ruby
expects :date, type: Date, preprocess: ->(d) { d.is_a?(Date) ? d : Date.parse(d) }
```

will succeed if given _either_ an actual Date object _or_ a string that Date.parse can convert into one.  If the preprocess callable raises an exception, that'll be swallowed and the action failed.

### Details specific to `.exposes`

Remember that you'll need [a corresponding `expose` call](/reference/instance#expose) for every variable you declare via `exposes`.


## `.messages`

The `messages` declaration allows you to customize the `error` and `success` messages on the returned result.

Accepts `error` and/or `success` keys.  Values can be a string (returned directly) or a callable (evaluated in the action's context, so can access instance methods).  If `error` is provided with a callable that expects a positional argument, the exception that was raised will be passed in as that value.

```ruby
messages success: "All good!", error: ->(e) { "Bad news: #{e.message}" }
```
