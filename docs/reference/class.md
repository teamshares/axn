::: danger ALPHA
* TODO: convert this rough outline into actual documentation
:::

# Class Methods

* `expects`
* `exposes`
* `messages`

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




* Note: while we support it, in practice you probably don't want to use too many validations on your interface -- remember this is your validation not user facing (pull the note...)

* Note that `expects` also supports a `preprocess` argument....

* Note we have two custom validations: boolean: true and the implicit type: foo.  (maybe with array of types?)

* Note a third allows custom validations:
    > `expects :foo, validate: ->(value) { "must be pretty big" unless value > 10 }` (error raised if any string returned OR if it raises an exception)

## `messages`

### .call

### .rollback

### hooks
