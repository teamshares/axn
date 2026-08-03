# frozen_string_literal: true

RSpec.describe "a validate: lambda that raises an exception axn cannot describe" do
  # `validate_validator` reports the lambda's exception through `best_effort { raise e }`. When the report
  # itself raised, the escape landed in the executor one layer out and REPLACED the settled outcome: the
  # caller's `Axn::InboundValidationError` was destroyed, no per-field message was ever added, and
  # `result.exception` named a stack with nothing to do with the failure. Reachable with three lines of
  # ordinary DSL, and in every environment for the hostile-`#message` shape.
  def action_validating_with(&raiser)
    build_axn do
      expects :n, validate: ->(_value) { raiser.call }
    end
  end

  let(:hostile_message) do
    Class.new(StandardError) do
      def message = raise(NotImplementedError, "message explodes")
    end
  end

  it "settles on the validation error for an ordinary raise (control)" do
    result = action_validating_with { raise ArgumentError, "ordinary" }.call(n: 1)

    expect(result).not_to be_ok
    expect(result.exception).to be_a(Axn::InboundValidationError)
  end

  it "settles on the validation error when the lambda's exception has a raising #message" do
    result = action_validating_with { raise hostile_message }.call(n: 1)

    expect(result).not_to be_ok
    expect(result.exception).to be_a(Axn::InboundValidationError)
  end

  it "settles on the validation error when the lambda's exception holds unrenderable message bytes" do
    result = action_validating_with { raise ArgumentError, "bad\xFF".dup.force_encoding("ASCII-8BIT") }.call(n: 1)

    expect(result).not_to be_ok
    expect(result.exception).to be_a(Axn::InboundValidationError)
  end
end
