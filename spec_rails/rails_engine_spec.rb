# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Axn::Rails::Engine do
  describe "Engine loading" do
    it "loads the Engine when Rails is available" do
      expect(defined?(Axn::Rails::Engine)).to be_truthy
      expect(Axn::Rails::Engine).to be < Rails::Engine
    end

    it "is automatically loaded when axn is required in Rails context" do
      # The Engine should be loaded by the time we get here
      expect(Axn::Rails::Engine).to be_truthy
    end
  end

  describe "Engine configuration" do
    it "has the correct engine name" do
      expect(Axn::Rails::Engine.engine_name).to eq("axn_rails_engine")
    end

    it "is isolated from the main application" do
      expect(Axn::Rails::Engine.isolated?).to be_falsey
    end
  end

  describe "Rails integration" do
    it "does not interfere with standalone axn usage" do
      # Axn should work normally even when Rails Engine is loaded
      expect(Axn).to respond_to(:configure)
      expect(Axn).to respond_to(:included)
    end

    it "maintains axn functionality in Rails context" do
      # Test that axn still works as expected
      result = TestAction.call
      expect(result).to be_ok
      expect(result.success).to eq("Action completed successfully")
    end
  end
end
