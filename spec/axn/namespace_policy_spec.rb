# frozen_string_literal: true

require "axn/testing/spec_helpers"

RSpec.describe "Axn top-level namespace" do
  # Public constants + module namespaces core reserves at Axn::. A future accidental
  # clobber (or a machinery constant leaking back to top-level) fails this.
  # rubocop:disable Lint/ConstantDefinitionInBlock
  RESERVED = %i[
    Result Failure Factory FormObject Configuration RailsConfiguration
    Strategies StrategyNotFound DuplicateStrategyError
    ContractViolation ValidationError
    InboundValidationError OutboundValidationError UnsupportedArgument
    Core Internal Async Extensions Tools Validation
    Configurable Mountable Extras FieldDeclarations Testing Util
  ].freeze
  # rubocop:enable Lint/ConstantDefinitionInBlock

  it "defines every reserved constant" do
    missing = RESERVED.reject { |c| Axn.const_defined?(c, false) }
    expect(missing).to be_empty, "missing top-level Axn constants: #{missing.inspect}"
  end

  it "no longer exposes the relocated machinery at top level" do
    %i[Executor Context ContextFacade ContextFacadeInspector InternalContext ExtensionConfig].each do |c|
      expect(Axn.const_defined?(c, false)).to be(false), "#{c} should not be a top-level Axn constant"
    end
  end

  # `Axn::Reflection` is deliberately unclaimed: the machinery that used to sit there is internal
  # (`Axn::Internal::Reflection`), and the name is held open for a reflection API we would be willing to
  # support publicly. Occupying it with internals again is what this fails on — see AGENTS.md.
  it "leaves Axn::Reflection unclaimed" do
    expect(Axn.const_defined?(:Reflection, false)).to be(false)
  end
end
