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

  # DuplicateFieldError nests under ContractViolation with its siblings and has no include of
  # its own, so this exercises the tag it inherits rather than one it declares.
  it "catches DuplicateFieldError through its ContractViolation superclass" do
    expect { raise Axn::ContractViolation::DuplicateFieldError, "dup" }.to raise_error(Axn::Error)
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

  # A public class must not inherit out of Axn::Internal: it puts an internal constant in a
  # documented class's ancestry, and makes that constant the only way to express "any registry
  # lookup miss". rescue Axn::Error is that expression now.
  describe "registry errors" do
    subject(:registry_errors) do
      [Axn::StrategyNotFound, Axn::DuplicateStrategyError,
       Axn::Async::AdapterNotFound, Axn::Async::DuplicateAdapterError,
       Axn::Mountable::MountingTypeNotFound, Axn::Mountable::DuplicateMountingTypeError]
    end

    it "have no Axn::Internal constant in their ancestry" do
      leaked = registry_errors.reject do |klass|
        klass.ancestors.grep(Class).none? { |a| a.name.to_s.start_with?("Axn::Internal") }
      end
      expect(leaked).to be_empty
    end

    it "are all catchable as Axn::Error" do
      expect(registry_errors.reject { |k| k.include?(Axn::Error) }).to be_empty
    end

    it "still descend from StandardError" do
      expect(registry_errors.reject { |k| k <= StandardError }).to be_empty
    end
  end
end
