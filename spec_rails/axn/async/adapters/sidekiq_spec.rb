# frozen_string_literal: true

require "spec_helper"
require "sidekiq/testing"

RSpec.describe "Axn::Async with Sidekiq adapter", :sidekiq do
  before do
    Sidekiq::Testing.inline!
    Sidekiq.strict_args!(false) # Allow symbols and other non-JSON types for testing
  end

  after do
    Sidekiq::Testing.fake!
    Sidekiq.strict_args!(true) # Restore strict args
  end

  describe ".call_async" do
    it "executes the action with the provided context" do
      result = Actions::TestActionSidekiq.call_async(name: "World", age: 25)
      expect(result).to be_a(Axn::Result)
      expect(result.ok?).to be true
    end

    it "handles empty context" do
      expect { Actions::TestActionSidekiq.call_async({}) }.to raise_error(Axn::InboundValidationError)
    end

    it "handles nil context" do
      expect { Actions::TestActionSidekiq.call_async(nil) }.to raise_error(Axn::InboundValidationError)
    end

    it "handles complex context" do
      result = Actions::TestActionSidekiq.call_async(name: "World", age: 25, active: true, tags: ["test"])
      expect(result).to be_a(Axn::Result)
      expect(result.ok?).to be true
    end
  end

  describe "GlobalID integration" do
    let(:user) { double("User", to_global_id: double("GlobalID", to_s: "gid://test/User/123")) }
    let(:action_with_user) do
      build_axn do
        async :sidekiq
        expects :name, :user

        def call
          "Hello, #{name}! User: #{user.class}"
        end
      end
    end

    it "converts GlobalID objects to strings in call_async" do
      result = action_with_user.call_async(name: "World", user:)
      expect(result).to be_a(Axn::Result)
      expect(result.ok?).to be true
    end

    it "converts GlobalID objects to strings and back during execution" do
      # Expect perform to be called with the GlobalID string (proving conversion happened)
      expect_any_instance_of(action_with_user).to receive(:perform).with(
        hash_including("name" => "World", "user_as_global_id" => "gid://test/User/123"),
      ).and_call_original

      # Call call_async with the actual user object - the adapter should handle conversion
      result = action_with_user.call_async(name: "World", user:)
      expect(result).to be_a(Axn::Result)
      expect(result.ok?).to be true
    end
  end

  describe "Sidekiq options configuration" do
    it "applies sidekiq_options from async config" do
      # Verify the sidekiq_options were applied
      expect(Actions::TestActionSidekiqWithOptions.sidekiq_options).to include(
        "queue" => "high_priority",
        "retry" => 3,
      )

      # Test that the job executes with the options
      result = Actions::TestActionSidekiqWithOptions.call_async(name: "Test", age: 25)
      expect(result).to be_a(Axn::Result)
      expect(result.ok?).to be true
    end

    it "works without sidekiq_options" do
      # Verify that default sidekiq_options are present
      expect(Actions::TestActionSidekiq.sidekiq_options).to be_a(Hash)
    end
  end

  describe "Sidekiq error handling" do
    it "handles job failures" do
      expect { Actions::FailingActionSidekiq.call_async(name: "Test") }.to raise_error(StandardError, "Intentional failure")
    end

    it "catches unserializable objects immediately during call_async" do
      unserializable_object = Object.new
      # Make it unserializable by adding a method that can't be serialized
      def unserializable_object.inspect
        "UnserializableObject"
      end

      expect do
        Actions::TestActionSidekiq.call_async(name: "Test", age: 25, unserializable: unserializable_object)
      end.to raise_error(ArgumentError, /Job arguments to .* must be native JSON types, but .* is a Object/)
    end

    it "catches complex unserializable objects immediately" do
      # Create a complex object with methods that can't be serialized
      complex_object = Class.new do
        def initialize
          @instance_var = "test"
        end

        def inspect
          "ComplexObject"
        end
      end.new

      expect do
        Actions::TestActionSidekiq.call_async(name: "Test", age: 25, complex: complex_object)
      end.to raise_error(ArgumentError, /Job arguments to .* must be native JSON types, but .* is a .*/)
    end
  end
end
