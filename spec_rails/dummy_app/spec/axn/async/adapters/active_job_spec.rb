# frozen_string_literal: true

RSpec.describe "Axn::Async with ActiveJob adapter" do
  include ActiveJob::TestHelper

  around do |example|
    # Use test adapter for testing job enqueueing and execution
    original_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    example.run
  ensure
    ActiveJob::Base.queue_adapter = original_adapter
  end

  describe ".call_async" do
    it "executes the action with the provided context" do
      job = Actions::TestActionActiveJob.call_async(name: "World", age: 25)

      expect(job).to be_a(ActiveJob::Base)
      expect(job.arguments).to eq([{ name: "World", age: 25 }])
    end

    it "handles empty context" do
      job = Actions::TestActionActiveJob.call_async({})

      expect(job).to be_a(ActiveJob::Base)
      expect(job.arguments).to eq([{}])
    end

    it "handles nil context" do
      job = Actions::TestActionActiveJob.call_async(nil)

      expect(job).to be_a(ActiveJob::Base)
      expect(job.arguments).to eq([{}])
    end

    it "handles complex context" do
      job = Actions::TestActionActiveJob.call_async(name: "World", age: 25, active: true, tags: ["test"])

      expect(job).to be_a(ActiveJob::Base)
      expect(job.arguments).to eq([{ name: "World", age: 25, active: true, tags: ["test"] }])
    end
  end

  describe "ActiveJob options configuration" do
    it "applies ActiveJob options from async config" do
      # Test that the job is enqueued with the options
      job = Actions::TestActionActiveJobWithOptions.call_async(name: "Test", age: 25)
      expect(job).to be_a(ActiveJob::Base)
      expect(job.arguments).to eq([{ name: "Test", age: 25 }])

      # Verify the ActiveJob options were applied to the proxy class
      proxy_class = Actions::TestActionActiveJobWithOptions.const_get(:ActiveJobProxy)
      expect(proxy_class.new.queue_name).to eq("high_priority")
    end

    it "works without custom ActiveJob options" do
      # Test that the job is enqueued
      job = Actions::TestActionActiveJob.call_async(name: "Test", age: 25)
      expect(job).to be_a(ActiveJob::Base)

      # Verify that default queue is used
      proxy_class = Actions::TestActionActiveJob.const_get(:ActiveJobProxy)
      expect(proxy_class.new.queue_name).to eq("default")
    end
  end

  describe "ActiveJob job execution" do
    it "executes the action and logs the result" do
      Actions::TestActionActiveJob.call_async(name: "World", age: 25)
      
      expect do
        perform_enqueued_jobs
      end.to output(/Action executed: Hello, World! You are 25 years old\./).to_stdout
    end

    it "handles complex context during execution" do
      Actions::TestActionActiveJob.call_async(name: "Rails", age: 30, active: true, tags: ["test"])
      
      expect do
        perform_enqueued_jobs
      end.to output(/Action executed: Hello, Rails! You are 30 years old\./).to_stdout
    end

    it "verifies that jobs can be executed multiple times" do
      Actions::TestActionActiveJob.call_async(name: "World", age: 25)
      Actions::TestActionActiveJob.call_async(name: "Rails", age: 30)
      
      expect do
        perform_enqueued_jobs
      end.to output(/Action executed: Hello, World! You are 25 years old\./).to_stdout
      
      # Clear the output and run again to test the second job
      Actions::TestActionActiveJob.call_async(name: "Rails", age: 30)
      
      expect do
        perform_enqueued_jobs
      end.to output(/Action executed: Hello, Rails! You are 30 years old\./).to_stdout
    end
  end

  describe "ActiveJob error handling" do
    it "enqueues failing jobs" do
      job = Actions::FailingActionActiveJob.call_async(name: "Test")

      expect(job).to be_a(ActiveJob::Base)
      expect(job.arguments).to eq([{ name: "Test" }])
    end

    it "executes failing jobs and raises the error" do
      Actions::FailingActionActiveJob.call_async(name: "Test")
      
      expect do
        perform_enqueued_jobs
      end.to output(/About to fail with name: Test/).to_stdout.and raise_error(StandardError, "Intentional failure")
    end
  end
end
