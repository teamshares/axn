# frozen_string_literal: true

# Contract::SHAPE_INCOMPATIBLE_TYPES references Date and DateTime at load time.
# Without an explicit `require "date"`, this raises NameError in any environment
# where the stdlib date has not been loaded before axn.
RSpec.describe "axn/core/contract" do
  it "explicitly requires 'date' so Date and DateTime are defined at load time" do
    contract_source = File.read(File.expand_path("../../../lib/axn/core/contract.rb", __dir__))
    expect(contract_source).to include('require "date"')
  end
end
