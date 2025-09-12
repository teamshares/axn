# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Axn::Enqueueable inheritance" do
  before do
    # Mock Sidekiq and ActiveJob for testing
    stub_const("Sidekiq", Module.new)
    stub_const("Sidekiq::Job", Module.new)
    stub_const("Sidekiq::Client", Class.new)
    stub_const("Sidekiq::Testing", Module.new)
    stub_const("ActiveJob", Module.new)
    stub_const("ActiveJob::Base", Class.new)

    # Mock Sidekiq::Job methods
    Sidekiq::Job.module_eval do
      def self.perform_async(*args)
        # Mock implementation
      end

      def perform_async(*args)
        # Mock implementation
      end
    end

    # Mock Sidekiq::Client methods
    Sidekiq::Client.define_method(:json_unsafe?) do |arg|
      arg.is_a?(Class)
    end

    # Mock Sidekiq::Testing methods
    Sidekiq::Testing.define_singleton_method(:inline!) do |&block|
      block.call
    end

    # Mock ActiveJob::Base methods
    ActiveJob::Base.extend(Module.new do
      def perform_later(*args)
        # Mock implementation
      end

      def set(options = {})
        # Mock implementation
      end

      def queue_as(queue_name)
        # Mock implementation
      end

      def retry_on(exception, **options)
        # Mock implementation
      end

      def discard_on(exception)
        # Mock implementation
      end

      def priority=(priority)
        # Mock implementation
      end
    end)
  end

  context "when parent class has async :sidekiq" do
    let(:parent_class) do
      # Ensure Sidekiq::Job mock is available
      Sidekiq::Job.module_eval do
        def self.perform_async(*args)
          # Mock implementation
        end

        def perform_async(*args)
          # Mock implementation
        end
      end

      Class.new do
        include Axn

        async :sidekiq do
          sidekiq_options queue: "parent_queue", retry: 3
        end

        expects :name

        def call
          "Hello, #{name}!"
        end
      end
    end

    let(:child_class) do
      Class.new(parent_class) do
        # No async configuration - should inherit parent's
      end
    end

    it "inherits parent's async adapter" do
      expect(child_class._async_adapter).to eq(:sidekiq)
    end

    it "inherits parent's sidekiq configuration" do
      expect(child_class.sidekiq_options_hash["queue"]).to eq("parent_queue")
      expect(child_class.sidekiq_options_hash["retry"]).to eq(3)
    end

    it "can call_async without error" do
      expect { child_class.call_async(name: "World") }.not_to raise_error
    end
  end

  context "when parent class has async :active_job" do
    let(:parent_class) do
      Class.new do
        include Axn

        async :active_job do
          queue_as "parent_queue"
          self.priority = 5
        end

        expects :name

        def call
          "Hello, #{name}!"
        end
      end
    end

    let(:child_class) do
      Class.new(parent_class) do
        # No async configuration - should inherit parent's
      end
    end

    it "inherits parent's async adapter" do
      expect(child_class._async_adapter).to eq(:active_job)
    end

    it "can call_async without error" do
      expect { child_class.call_async(name: "World") }.not_to raise_error
    end
  end

  context "when parent class has async false" do
    let(:parent_class) do
      Class.new do
        include Axn

        async false

        expects :name

        def call
          "Hello, #{name}!"
        end
      end
    end

    let(:child_class) do
      Class.new(parent_class) do
        # No async configuration - should inherit parent's
      end
    end

    it "inherits parent's disabled async" do
      expect(child_class._async_adapter).to eq(false)
    end

    it "raises NotImplementedError when calling call_async" do
      expect { child_class.call_async(name: "World") }.to raise_error(NotImplementedError)
    end
  end

  context "when child class overrides parent's async configuration" do
    let(:parent_class) do
      Class.new do
        include Axn

        async :sidekiq do
          sidekiq_options queue: "parent_queue"
        end
      end
    end

    let(:child_class) do
      Class.new(parent_class) do
        async :active_job do
          queue_as "child_queue"
        end
      end
    end

    it "uses child's async configuration" do
      expect(child_class._async_adapter).to eq(:active_job)
    end

    it "inherits parent's sidekiq methods but uses child's activejob configuration" do
      # The child class inherits parent's sidekiq methods (Ruby inheritance)
      expect(child_class).to respond_to(:sidekiq_options_hash)

      # But it uses the child's activejob configuration
      expect(child_class._async_adapter).to eq(:active_job)
      expect(child_class._activejob_configs).to include([:queue_as, "child_queue"])
    end
  end
end
