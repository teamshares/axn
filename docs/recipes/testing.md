# Testing

::: danger ALPHA
* TODO: document testing patterns
:::

Configuring rspec to treat files in spec/actions as service specs:

```ruby
RSpec.configure do |config|
  config.define_derived_metadata(file_path: "spec/actions") do |metadata|
    metadata[:type] = :service
  end
end
```
