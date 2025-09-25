# frozen_string_literal: true

RSpec.describe "Axn::Async with Sidekiq adapter", :sidekiq do
  before do
    Sidekiq::Testing.inline!
    Sidekiq.strict_args!(false) # Allow symbols and other non-JSON types for testing
    allow(Axn.config.logger).to receive(:info).and_call_original
  end

  after do
    Sidekiq::Testing.fake!
    Sidekiq.strict_args!(true) # Restore strict args
  end

  describe ".call_async" do
    it "executes the action with the provided context" do
      job_id = Actions::TestActionSidekiq.call_async(name: "World", age: 25)
      expect(job_id).to be_a(String)
      expect(job_id).to match(/\A[0-9a-f]{24}\z/) # Sidekiq job ID format
    end

    it "handles complex context" do
      job_id = Actions::TestActionSidekiq.call_async(name: "World", age: 25, active: true, tags: ["test"])
      expect(job_id).to be_a(String)
      expect(job_id).to match(/\A[0-9a-f]{24}\z/) # Sidekiq job ID format
    end
  end

  describe "GlobalID integration" do
    let(:user) { double("User", to_global_id: double("GlobalID", to_s: "gid://test/User/123")) }

    before do
      # Mock GlobalID::Locator to return our mock user
      allow(GlobalID::Locator).to receive(:locate).with("gid://test/User/123").and_return(user)
    end

    it "converts GlobalID objects to strings in call_async" do
      job_id = Actions::TestActionSidekiqGlobalId.call_async(name: "World", user:)
      expect(job_id).to be_a(String)
      expect(job_id).to match(/\A[0-9a-f]{24}\z/) # Sidekiq job ID format
    end

    it "converts GlobalID objects to strings and back during execution" do
      # Expect perform to be called with the GlobalID string (proving conversion happened)
      expect_any_instance_of(Actions::TestActionSidekiqGlobalId).to receive(:perform).with(
        hash_including("name" => "World", "user_as_global_id" => "gid://test/User/123"),
      ).and_call_original

      # Call call_async with the actual user object - the adapter should handle conversion
      job_id = Actions::TestActionSidekiqGlobalId.call_async(name: "World", user:)
      expect(job_id).to be_a(String)
      expect(job_id).to match(/\A[0-9a-f]{24}\z/) # Sidekiq job ID format
    end
  end

  describe "Sidekiq options configuration" do
    it "applies sidekiq_options from async config" do
      # Verify the sidekiq_options were applied
      expect(Actions::TestActionSidekiqWithOptions.sidekiq_options).to include(
        "queue" => "high_priority",
        "retry" => 3,
      )

      # Test that the job can be enqueued with the options
      job_id = Actions::TestActionSidekiqWithOptions.call_async(name: "Test", age: 25)
      expect(job_id).to be_a(String)
      expect(job_id).to match(/\A[0-9a-f]{24}\z/) # Sidekiq job ID format
    end

    it "works without sidekiq_options" do
      # Verify that default sidekiq_options are present
      expect(Actions::TestActionSidekiq.sidekiq_options).to be_a(Hash)
    end
  end

  describe "Sidekiq job execution" do
    it "executes the action successfully" do
      expect do
        Actions::TestActionSidekiq.call_async(name: "World", age: 25)
      end.not_to raise_error
    end

    it "executes action with no arguments successfully" do
      expect do
        Actions::TestActionSidekiqNoArgs.call_async
      end.not_to raise_error
    end

    it "handles complex context during execution" do
      expect do
        Actions::TestActionSidekiq.call_async(name: "Rails", age: 30, active: true, tags: ["test"])
      end.not_to raise_error
    end

    it "verifies that jobs can be executed multiple times" do
      expect do
        Actions::TestActionSidekiq.call_async(name: "World", age: 25)
        Actions::TestActionSidekiq.call_async(name: "Rails", age: 30)
      end.not_to raise_error
    end

    it "executes action successfully" do
      expect do
        Actions::TestActionSidekiq.call_async(name: "World", age: 25)
      end.not_to raise_error
    end

    it "logs action execution details" do
      Actions::TestActionSidekiq.call_async(name: "World", age: 25)

      # Verify that info was called with the expected message
      expect(Axn.config.logger).to have_received(:info).with(/Action executed: Hello, World! You are 25 years old\./)
    end

    it "logs before failing" do
      expect { Actions::FailingActionSidekiq.call_async(name: "Test") }.to raise_error(StandardError, "Intentional failure")

      # Verify that info was called before the error
      expect(Axn.config.logger).to have_received(:info).with(/About to fail with name: Test/)
    end
  end

  describe "Sidekiq error handling" do
    it "handles job failures" do
      expect { Actions::FailingActionSidekiq.call_async(name: "Test") }.to raise_error(StandardError, "Intentional failure")
    end

    it "executes failing action and raises error" do
      expect { Actions::FailingActionSidekiq.call_async(name: "Test") }.to raise_error(StandardError, "Intentional failure")
    end

    it "catches unserializable objects immediately during call_async" do
      # Create a truly unserializable object
      unserializable_object = Object.new
      def unserializable_object.to_s
        raise "Cannot serialize"
      end

      # Test that the object is actually unserializable
      expect { JSON.generate(unserializable_object) }.to raise_error(RuntimeError, "Cannot serialize")

      # Enable strict args for this test to catch unserializable objects
      Sidekiq.strict_args!(true)

      expect do
        Actions::TestActionSidekiq.call_async(name: "Test", age: 25, unserializable: unserializable_object)
      end.to raise_error(RuntimeError, "Cannot serialize")
    ensure
      # Restore strict args setting
      Sidekiq.strict_args!(false)
    end

    it "catches complex unserializable objects immediately" do
      # Create a truly unserializable object
      complex_object = Object.new
      def complex_object.to_s
        raise "Cannot serialize"
      end

      # Test that the object is actually unserializable
      expect { JSON.generate(complex_object) }.to raise_error(RuntimeError, "Cannot serialize")

      # Enable strict args for this test to catch unserializable objects
      Sidekiq.strict_args!(true)

      expect do
        Actions::TestActionSidekiq.call_async(name: "Test", age: 25, complex: complex_object)
      end.to raise_error(RuntimeError, "Cannot serialize")
    ensure
      # Restore strict args setting
      Sidekiq.strict_args!(false)
    end
  end
end
