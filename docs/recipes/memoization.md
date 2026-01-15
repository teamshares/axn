# Memoization

Axn has built-in memoization support via the `memo` helper. This caches the result of method calls, ensuring they're only computed once per action execution.

## Basic Usage

The `memo` helper works out of the box for methods without arguments:

```ruby
class GenerateReport
  include Axn

  expects :company, model: Company
  exposes :report

  def call
    expose report: {
      total_revenue: total_revenue,
      top_products: top_products.map(&:name),
      # top_products is only queried once, even though it's called twice
      product_count: top_products.count
    }
  end

  private

  memo def top_products
    company.products.order(sales_count: :desc).limit(10)
  end

  memo def total_revenue
    company.orders.sum(:total)
  end
end
```

## How It Works

- `memo` wraps the method and caches its return value on first call
- Subsequent calls return the cached value without re-executing the method
- Memoization is scoped to the action instance, so each `call` starts fresh

## Methods With Arguments

For methods that accept arguments, Axn supports the `memo_wise` gem:

```ruby
# Gemfile
gem "memo_wise"
```

With `memo_wise` available, you can automatically memoize methods with arguments:

```ruby
class CalculatePricing
  include Axn

  expects :product
  exposes :pricing

  def call
    expose pricing: {
      retail: price_for(:retail),
      wholesale: price_for(:wholesale),
      # Each unique argument is cached separately
      bulk: price_for(:bulk)
    }
  end

  private

  memo def price_for(tier)
    # Complex pricing calculation...
    PricingEngine.calculate(product, tier:)
  end
end
```

If you try to use `memo` on a method with arguments without `memo_wise` installed, you'll get a helpful error:

```
ArgumentError: Memoization of methods with arguments requires the 'memo_wise' gem.
Please add 'memo_wise' to your Gemfile or use a method without arguments.
```

## When to Use Memoization

Memoization is particularly useful for:

- **Database queries** called multiple times within an action
- **API calls** or external service lookups
- **Complex computations** that are expensive to repeat

```ruby
class SyncUserData
  include Axn

  expects :user, model: User

  def call
    update_profile if needs_profile_update?
    update_preferences if needs_preferences_update?
    notify_if_changed
  end

  private

  # Called multiple times - only fetches once
  memo def external_data
    ExternalApi.fetch_user_data(user.external_id)
  end

  def needs_profile_update?
    external_data[:profile_version] > user.profile_version
  end

  def needs_preferences_update?
    external_data[:preferences_hash] != user.preferences_hash
  end

  def notify_if_changed
    # ...
  end
end
```

## Notes

- Memoization persists only for the duration of a single action execution
- When `memo_wise` is available, Axn automatically uses it (no configuration needed)
- See the [memo_wise documentation](https://github.com/panorama-ed/memo_wise) for advanced features like cache resetting
