# frozen_string_literal: true

require_relative "../support/shared_examples/registry_behavior"

RSpec.describe Axn::Strategies do
  let(:test_action) { build_axn }

  # Registry behavior shared examples
  it_behaves_like "a registry" do
    let(:expected_built_in_keys) { [:transaction] }
    let(:expected_find_key) { :transaction }
    let(:expected_item_type) { "Strategy" }
    let(:expected_not_found_error_class) { Axn::StrategyNotFound }
    let(:expected_duplicate_error_class) { Axn::DuplicateStrategyError }
  end

  # Strategy-specific tests
  describe ".built_in" do
    it "loads all strategy files from the strategies directory" do
      expect(described_class.built_in[:transaction]).to be(Axn::Strategies::Transaction)
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

    it "allows custom strategies to be used" do
      described_class.clear!
      described_class.register(:custom, custom_strategy)
      expect { test_action.use(:custom) }.to output("Custom strategy included!\n").to_stdout
      expect(test_action.included_modules).to include(custom_strategy)
    end
  end
end
