# Testing

::: danger ALPHA
* TODO: document testing patterns
:::

## Mocking Axn calls

Say you're writing unit specs for PrimaryAction that calls Subaction, and you want to mock out the Subaction call.

To generate a successful Axn::Result:

* Base case: `Axn::Result.ok`
* [Optional] Custom message: `Axn::Result.ok("It went awesome")`
* [Optional] Custom exposures: `Axn::Result.ok("It went awesome", some_var: 123)`

To generate a failed Axn::Result:

* Base case: `Axn::Result.error`
* [Optional] Custom message: `Axn::Result.error("It went poorly")`
* [Optional] Custom exposures: `Axn::Result.error("It went poorly", some_var: 123)`
* [Optional] Custom exception: `Axn::Result.error(some_var: 123) { raise FooBarException.new("bad thing") }`

Either way, using those to mock an actual call would look something like this in your rspec:

```ruby
let(:subaction_response) { Axn::Result.ok("custom message", foo: 1) }

before do
  expect(Subaction).to receive(:call).and_return(subaction_response)
end
```

### `call!`

The semantics of call-bang are a little different -- if Subaction is called via `call!`, you'll need slightly different code to handle success vs failure:

### Success

```ruby
let(:subaction_response) { Axn::Result.ok("custom message", foo: 1) }

before do
  expect(Subaction).to receive(:call!).and_return(subaction_response)
end
```

### Failure

Because `call!` will _raise_, we need to use `and_raise` rather than `and_return`:

```ruby
let(:subaction_exception) { SomeValidErrorClass.new("whatever you expect subclass to raise") }

before do
  expect(Subaction).to receive(:call!).and_raise(subaction_exception)
end
```

NOTE: to mock subaction failing via explicit `fail!` call, you'd use an `Axn::Failure` exception class.

## Mocking Axn arguments

Be aware that in order to improve testing ergonomics, the `type` validation will return `true` for _any_ `RSpec::Mocks::` subclass _as long as `Axn.config.env.test?` is `true`_.

This makes it much easier to test Axns, as you can pass in mocks without immediately failing the inbound validation.

```ruby
subject(:result) { action.call!(sym:) }

let(:action) { build_axn { expects :sym, type: Symbol } }

context "with a symbol" do
  let(:sym) { :hello }
  it { is_expected.to be_ok }
end

context "with an RSpec double" do
  let(:sym) { double(to_s: "hello") }  # [!code focus:2]
  it { is_expected.to be_ok }
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
