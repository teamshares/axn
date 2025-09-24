# `Axn::Result`

Every `call` invocation on an Axn will return an `Axn::Result` instance, which provides a consistent interface:

| Method | Description |
| -- | -- |
| `ok?` | `true` if the call succeeded, `false` if not.
| `error` | User-facing error message (string), if not `ok?` (else nil)
| `success` | User-facing success message (string), if `ok?` (else nil)
| `message` | User-facing message (string), always defined (`ok? ? success : error`)
| `exception` | If not `ok?` because an exception was swallowed, will be set to the swallowed exception (note: rarely used outside development; prefer to let the library automatically handle exception handling for you)
| `outcome` | The execution outcome as a string inquirer (`success?`, `failure?`, `exception?`)
| `elapsed_time` | Execution time in milliseconds (Float)
| `finalized?` | `true` if the result has completed execution (either successfully or with an exception), `false` if still in progress
| any `expose`d values | guaranteed to be set if `ok?` (since they have outgoing presence validations by default; any missing would have failed the action)

NOTE: `success` and `error` (and so implicitly `message`) can be configured per-action via [the `success` and `error` declarations](/reference/class#success-and-error).

### Clarification of exposed values

In addition to the core interface, your Action's Result class will have methods defined to read the values of any attributes that were explicitly exposed.  For example, given this action and result:


```ruby
class Foo
  include Axn

  exposes :bar, :baz # [!code focus]

  def call
    expose bar: 1, baz: 2
  end
end

result = Foo.call # [!code focus]
```

`result` will have both `bar` and `baz` reader methods (which will return 1 and 2, respectively).

## Pattern Matching Support

`Axn::Result` supports Ruby 3's pattern matching feature, allowing you to destructure results in a more expressive way:

```ruby
case SomeAction.call
in ok: true, success: String => message, user:, order:
  process_success(user, order, message)
in ok: false, error: String => message
  handle_error(message)
end
```

### Available Pattern Matching Keys

When pattern matching, the following keys are available:

- `ok` - Boolean success state (`true` for success, `false` for failure)
- `success` - Success message string (only present when `ok` is `true`)
- `error` - Error message string (only present when `ok` is `false`)
- `message` - Always present message string (success or error)
- `outcome` - Symbol indicating the execution outcome (`:success`, `:failure`, or `:exception`)
- `finalized` - Boolean indicating if execution completed
- Any exposed values from the action

### Pattern Matching Examples

**Basic Success/Failure Matching:**
```ruby
case result
in ok: true, user: User => user
  puts "User created: #{user.name}"
in ok: false, error: String => message
  puts "Error: #{message}"
end
```

**Outcome-Based Matching:**
```ruby
case result
in ok: true, outcome: :success, data: { id: Integer => id }
  puts "Success with ID: #{id}"
in ok: false, outcome: :failure, error: String => message
  puts "Business logic failure: #{message}"
in ok: false, outcome: :exception, error: String => message
  puts "System error: #{message}"
end
```

**Complex Nested Data Matching:**
```ruby
case result
in ok: true, order: { id: Integer => order_id, items: [{ name: String => item_name }] }
  puts "Order #{order_id} created with #{item_name}"
in ok: false, error: String => message, field: String => field
  puts "Validation failed on #{field}: #{message}"
end
```

**Type Guards and Variable Binding:**
```ruby
case result
in ok: true, success: String => message, user: { email: String => email }
  send_notification(email, message)
in ok: false, error: String => message, code: String => code
  log_error(code: code, message: message)
end
```
