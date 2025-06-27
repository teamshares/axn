# frozen_string_literal: true

require "spec_helper"

RSpec.describe Action::UseStrategy do
  let(:test_action) { build_action }
  let(:custom_strategy) do
    Module.new do
      extend ActiveSupport::Concern
      included do
        puts "Custom strategy included!"
      end
    end
  end

  before do
    Action::Strategies.clear!
    Action::Strategies.register(:custom, custom_strategy)
  end

  describe ".use" do
    it "includes the strategy by name" do
      expect do
        test_action.use(:custom)
      end.to output("Custom strategy included!\n").to_stdout

      expect(test_action.included_modules).to include(custom_strategy)
    end

    it "raises an error for unknown strategy names" do
      expect do
        test_action.use(:unknown_strategy)
      end.to raise_error("Strategy unknown_strategy not found")
    end

    it "finds strategies by symbol name" do
      expect do
        test_action.use(:custom)
      end.to output("Custom strategy included!\n").to_stdout
    end

    it "finds strategies by string name" do
      expect do
        test_action.use("custom")
      end.to output("Custom strategy included!\n").to_stdout
    end
  end
end
