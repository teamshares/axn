# frozen_string_literal: true

RSpec.describe Axn::Error do
  it "is a module, not a class, so a gem can keep its own superclass" do
    expect(described_class).to be_a(Module)
    expect(described_class).not_to be_a(Class)
  end

  # The whole point: one rescue for anything axn objected to, whatever it descends from.
  it "catches a tagged exception rooted at StandardError" do
    expect { raise Axn::ContractViolation::MethodNotAllowed, "nope" }.to raise_error(Axn::Error)
  end

  it "catches a tagged exception rooted at ArgumentError" do
    expect { raise Axn::UnsupportedArgument, "some feature" }.to raise_error(Axn::Error)
  end

  it "leaves the tagged class's own ancestry intact" do
    expect(Axn::UnsupportedArgument.ancestors).to include(ArgumentError)
    expect(Axn::InboundValidationError.ancestors).to include(Axn::ContractViolation)
  end

  # Failure is a control-flow signal from call!, not a fault. Tagging it would make
  # `rescue Axn::Error` catch the INTENDED outcome while still missing an unintended
  # NoMethodError from the action body.
  it "does not catch Axn::Failure" do
    expect(Axn::Failure.include?(described_class)).to be(false)
  end

  it "does not catch internal-only exceptions" do
    expect(Axn::Internal::EarlyCompletion.include?(described_class)).to be(false)
  end
end
