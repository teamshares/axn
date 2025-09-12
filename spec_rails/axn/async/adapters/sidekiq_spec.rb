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

  let(:action_class) do
    build_axn do
      async :sidekiq
      expects :name, :age

      def call
        "Hello, #{name}! You are #{age} years old."
      end
    end
  end

  describe ".call_async" do
    it "executes the action with the provided context" do
      result = action_class.call_async(name: "World", age: 25)
      expect(result).to be_a(Axn::Result)
      expect(result.ok?).to be true
    end

    it "handles empty context" do
      expect { action_class.call_async({}) }.to raise_error(Axn::InboundValidationError)
    end

    it "handles nil context" do
      expect { action_class.call_async(nil) }.to raise_error(Axn::InboundValidationError)
    end

    it "handles complex context" do
      result = action_class.call_async(name: "World", age: 25, active: true, tags: ["test"])
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

  describe "Sidekiq error handling" do
    it "handles job failures" do
      failing_action_class = build_axn do
        async :sidekiq
        expects :name

        def call
          raise StandardError, "Intentional failure"
        end
      end

      expect { failing_action_class.call_async(name: "Test") }.to raise_error(StandardError, "Intentional failure")
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
        action_class.call_async(name: "Test", age: 25, complex: complex_object)
      end.to raise_error(ArgumentError, /Job arguments to .* must be native JSON types, but .* is a .*/)
    end
  end
end
