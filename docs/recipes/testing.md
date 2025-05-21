# Testing

::: danger ALPHA
* TODO: document testing patterns
:::

## Mocking Axn calls

Say you're writing unit specs for PrimaryAction that calls Subaction, and you want to mock out the Subaction call.

To generate a successful Action::Result:

* Base case: `Action::Result.ok`
* [Optional] Custom message: `Action::Result.ok("It went awesome")`
* [Optional] Custom exposures: `Action::Result.ok("It went awesome", some_var: 123)`

To generate a failed Action::Result:

* Base case: `Action::Result.error`
* [Optional] Custom message: `Action::Result.error("It went poorly")`
* [Optional] Custom exposures: `Action::Result.error("It went poorly", some_var: 123)`
* [Optional] Custom exception: `Action::Result.error(some_var: 123) { raise FooBarException.new("bad thing") }`

Either way, using those to mock an actual call would look something like this in your rspec:

```ruby
let(:subaction_response) { Action::Result.ok("custom message", foo: 1) }

before do
  expect(Subaction).to receive(:call).and_return(subaction_response)
end
```

## RSpec configuration

Configuring rspec to treat files in spec/actions as service specs (very optional):

```ruby
RSpec.configure do |config|
  config.define_derived_metadata(file_path: "spec/actions") do |metadata|
    metadata[:type] = :service
  end
end
```
