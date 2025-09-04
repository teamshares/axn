### Adding memoization

For a practical example of [the `additional_includes` configuration](/reference/configuration#additional-includes) in practice, consider adding new functionality to all Actions.

For instance, at Teamshares we automatically add memoization support (via [memo_wise](https://github.com/panorama-ed/memo_wise)) to all Actions.  But we didn't want to add another dependency to the core library, so we've implemented this by:


```ruby
  Axn.configure do |c|
    c.additional_includes = [TS::Memoization]
  end
```

```ruby
module TS::Memoization
  extend ActiveSupport::Concern

  included do
    prepend MemoWise
  end

  class_methods do
    def memo(...) = memo_wise(...)
  end
end
```

And with those pieces in place `memo` is available in all Actions:

```ruby
class ContrivedExample
  include Action

  exposes :nums

  def call
    expose nums: Array.new(10) { random_number }
  end

  private

  memo def random_number = rand(1..100) # [!code focus]
end
```

Because of the `memo` usage, `ContrivedExample.call.nums` will be a ten-element array of _the same number_, rather than re-calling `rand` for each element.
