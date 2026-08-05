# frozen_string_literal: true

# A test double stands in for a value of any declared type, so `TypeValidator.mock_value?` waives type
# validation for one. That waiver is decided by NAMING the value's class — which makes it the one place a
# caller's value could decide whether its own contract check runs at all, if the name were asked of it.
RSpec.describe "waiving type validation for a test double" do
  let(:action) do
    build_axn do
      expects :at, type: Time
      def call = nil
    end
  end

  it "still waives the check for a real double" do
    expect(action.call(at: instance_double(Time)).outcome).to be_success
  end

  it "still enforces the declared type for an ordinary wrong value" do
    expect(action.call(at: "not a time").outcome).to be_exception
  end

  # `value.class` is the value's own reader. A value naming itself into the waiver skips the contract check
  # it was declared under — so the name comes from bound `Object#class` + `Module#to_s` instead.
  it "does not let a value name itself into the waiver" do
    impostor = Class.new do
      def self.name = "RSpec::Mocks::Double"
      def class = Class.new { def self.name = "RSpec::Mocks::Double" }
    end.new

    expect(action.call(at: impostor).outcome).to be_exception
  end

  # The other direction, and the one with teeth: a value whose `class` RAISES would replace the validation
  # verdict with its own exception. Outside StandardError and SWALLOWABLE_BEYOND_STANDARD_ERROR, so it would
  # escape `.call` rather than settle.
  it "does not let a value's own class reader replace the verdict" do
    unswallowable = Class.new(Exception) # rubocop:disable Lint/InheritException
    hostile = Class.new do
      define_method(:class) { raise(unswallowable, "class must not decide the waiver") }
    end.new

    result = nil
    expect { result = action.call(at: hostile) }.not_to raise_error
    expect(result.outcome).to be_exception
  end

  # An anonymous class has no `name` — the case the previous `&.` existed for. `Module#to_s` answers
  # `#<Class:0x…>`, which takes the same branch nil did, so the guard is unchanged and the `&.` is gone.
  it "handles a value whose class is anonymous" do
    expect(action.call(at: Class.new.new).outcome).to be_exception
  end
end
