# frozen_string_literal: true

require "spec_helper"

RSpec.describe Action::UseStrategy do
  let(:test_action) { build_action }

  describe ".use" do
    it "includes the strategy by name" do
      expect do
        test_action.use(:transaction)
      end.to output("Transaction strategy included!\n").to_stdout

      expect(test_action.included_modules).to include(Action::Strategies::Transaction)
    end

    it "raises an error for unknown strategy names" do
      expect do
        test_action.use(:unknown_strategy)
      end.to raise_error("Strategy unknown_strategy not found")
    end

    it "finds strategies by symbol name" do
      expect do
        test_action.use(:transaction)
      end.to output("Transaction strategy included!\n").to_stdout
    end

    it "finds strategies by string name" do
      expect do
        test_action.use("transaction")
      end.to output("Transaction strategy included!\n").to_stdout
    end
  end
end
