# `Action::Result`

Every `call` invocation on an Action will return an `Action::Result` instance, which provides a consistent interface:

| Method | Description |
| -- | -- |
| `ok?` | `true` if the call succeeded, `false` if not.
| `error` | User-facing error message (string), if not `ok?` (else nil)
| `success` | User-facing success message (string), if `ok?` (else nil)
| `message` | User-facing message (string), always defined (`ok? ? success : error`)
| `exception` | If not `ok?` because an exception was swallowed, will be set to the swallowed exception (note: rarely used outside development; prefer to let the library automatically handle exception handling for you)
| `outcome` | The execution outcome as a string inquirer (`success?`, `failure?`, `exception?`)
| `elapsed_time` | Execution time in milliseconds (Float)
| any `expose`d values | guaranteed to be set if `ok?` (since they have outgoing presence validations by default; any missing would have failed the action)

NOTE: `success` and `error` (and so implicitly `message`) can be configured per-action via [the `success` and `error` declarations](/reference/class#success-and-error).

### Clarification of exposed values

In addition to the core interface, your Action's Result class will have methods defined to read the values of any attributes that were explicitly exposed.  For example, given this action and result:


```ruby
class Foo
  include Action

  exposes :bar, :baz # [!code focus]

  def call
    expose bar: 1, baz: 2
  end
end

result = Foo.call # [!code focus]
```

`result` will have both `bar` and `baz` reader methods (which will return 1 and 2, respectively).
