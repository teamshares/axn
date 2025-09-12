# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Axn::Enqueueable inheritance" do
  before do
    # Use real Sidekiq and ActiveJob - no mocking needed
    require "sidekiq"
    require "active_job"
  end

  context "when parent class has async :sidekiq" do
    let(:parent_class) do
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

    it "inherits parent's async adapter" do
      expect(child_class._async_adapter).to eq(false)
    end

    it "raises NotImplementedError when calling call_async" do
      expect { child_class.call_async(name: "World") }.to raise_error(NotImplementedError, /Async execution is explicitly disabled/)
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

      # Trigger creation of the ActiveJob proxy class
      child_class.call_async(name: "Test")

      # Check that the proxy class was created
      proxy_class = child_class.const_get("ActiveJobProxy")
      expect(proxy_class).to be_present
    end
  end
end
