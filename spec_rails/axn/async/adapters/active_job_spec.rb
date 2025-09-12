# frozen_string_literal: true

require_relative "../../../spec_helper"
require "active_job"
require "active_job/test_helper"

RSpec.describe "Axn::Async with ActiveJob adapter" do
  include ActiveJob::TestHelper

  before(:all) do
    # Debug autoloading
    puts "Rails loaded: #{defined?(Rails)}"
    puts "Actions namespace exists: #{Object.const_defined?('Actions')}"
    puts "Rails autoloader dirs: #{Rails.autoloaders.main.dirs.map(&:to_s)}"
    puts "Axn config namespace: #{Axn.config.rails.app_actions_autoload_namespace}"
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
      expect(job.arguments).to eq([nil])
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

  describe "ActiveJob error handling" do
    it "enqueues failing jobs" do
      job = Actions::FailingActionActiveJob.call_async(name: "Test")

      expect(job).to be_a(ActiveJob::Base)
      expect(job.arguments).to eq([{ name: "Test" }])
    end
  end
end
