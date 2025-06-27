# frozen_string_literal: true

require "spec_helper"

RSpec.describe Action::Strategies do
  let(:test_action) { build_action }

  describe ".built_in" do
    it "loads all strategy files from the strategies directory" do
      expect(described_class.built_in.keys).to include(:transaction)
      expect(described_class.built_in[:transaction]).to be(Action::Strategies::Transaction)
    end

    it "returns a hash with module values" do
      strategies = described_class.built_in
      expect(strategies).to be_a(Hash)
      expect(strategies.values).to all(be_a(Module))
    end

    it "memoizes the result" do
      first_call = described_class.built_in
      second_call = described_class.built_in
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
      described_class.clear!
      initial_count = described_class.all.length

      described_class.register(:custom, custom_strategy)

      expect(described_class.all.length).to eq(initial_count + 1)
      expect(described_class.all[:custom]).to eq(custom_strategy)
    end

    it "allows custom strategies to be used" do
      described_class.clear!
      described_class.register(:custom, custom_strategy)
      expect { test_action.use(:custom) }.to output("Custom strategy included!\n").to_stdout
      expect(test_action.included_modules).to include(custom_strategy)
    end

    it "raises an error when registering a duplicate strategy by name" do
      described_class.clear!
      described_class.register(:custom, custom_strategy)

      expect do
        described_class.register(:custom, custom_strategy)
      end.to raise_error(Action::DuplicateStrategyError, "Strategy custom already registered")
    end

    it "initializes strategies if not already done" do
      described_class.class_variable_set(:@@strategies, nil)

      described_class.register(:custom, custom_strategy)

      expect(described_class.all[:custom]).to eq(custom_strategy)
    end
  end

  describe ".all" do
    it "returns all registered strategies as a hash" do
      strategies = described_class.all
      expect(strategies).to be_a(Hash)
      expect(strategies.values).to include(Action::Strategies::Transaction)
    end

    it "initializes strategies if not already done" do
      described_class.class_variable_set(:@@strategies, nil)

      strategies = described_class.all

      expect(strategies.values).to include(Action::Strategies::Transaction)
    end
  end
end
