# frozen_string_literal: true

require "spec_helper"

RSpec.describe Action::Strategies do
  let(:test_action) do
    Class.new do
      include Action
      include Action::Strategies
      include Action::Strategies::Usable
    end
  end

  describe ".built_in" do
    it "loads all strategy files from the strategies directory" do
      expect(test_action.built_in).to include(Action::Strategies::Transaction)
    end

    it "returns only modules" do
      strategies = test_action.built_in
      expect(strategies).to all(be_a(Module))
    end

    it "memoizes the result" do
      first_call = test_action.built_in
      second_call = test_action.built_in
      expect(first_call.object_id).to eq(second_call.object_id)
    end
  end

  describe ".register" do
    let(:custom_strategy) do
      Module.new do
        extend ActiveSupport::Concern
        included do
          puts "Custom strategy included!"
        end
      end
    end

    it "adds a strategy to the list" do
      test_action.clear!
      initial_count = test_action.all.length

      test_action.register(custom_strategy)

      expect(test_action.all.length).to eq(initial_count + 1)
      expect(test_action.all).to include(custom_strategy)
    end

    it "does not add duplicate strategies" do
      test_action.clear!
      test_action.register(custom_strategy)
      initial_count = test_action.all.length

      test_action.register(custom_strategy)

      expect(test_action.all.length).to eq(initial_count)
    end

    it "initializes strategies if not already done" do
      test_action.class_variable_set(:@@strategies, nil)

      test_action.register(custom_strategy)

      expect(test_action.all).to include(custom_strategy)
    end
  end

  describe ".all" do
    it "returns all registered strategies" do
      strategies = test_action.all
      expect(strategies).to be_an(Array)
      expect(strategies).to include(Action::Strategies::Transaction)
    end

    it "initializes strategies if not already done" do
      test_action.class_variable_set(:@@strategies, nil)

      strategies = test_action.all

      expect(strategies).to include(Action::Strategies::Transaction)
    end
  end
end

RSpec.describe Action::Strategies::Usable do
  let(:test_action) do
    Class.new do
      include Action
      include Action::Strategies
      include Action::Strategies::Usable
    end
  end

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

RSpec.describe "Integration: Using Transaction strategy in an action" do
  let(:action_with_transaction) do
    Class.new do
      include Action
      include Action::Strategies
      include Action::Strategies::Usable

      use :transaction

      def call
        # Action implementation would go here
        "success"
      end
    end
  end

  it "successfully includes the Transaction strategy" do
    expect(action_with_transaction.included_modules).to include(Action::Strategies::Transaction)
  end

  it "can be instantiated and called" do
    action = action_with_transaction.new
    expect(action.call).to eq("success")
  end

  it "outputs the inclusion message when the class is defined" do
    expect do
      Class.new do
        include Action
        include Action::Strategies
        include Action::Strategies::Usable
        use :transaction
      end
    end.to output("Transaction strategy included!\n").to_stdout
  end
end
