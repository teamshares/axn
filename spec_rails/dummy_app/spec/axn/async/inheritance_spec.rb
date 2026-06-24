# frozen_string_literal: true

RSpec.describe "Axn::Async inheritance" do
  # Shared examples for basic inheritance behavior
  shared_examples "inherits async configuration" do |adapter_type|
    it "inherits parent's async adapter" do
      expect(child_class._async_adapter).to eq(adapter_type)
    end

    it "can call_async without error" do
      expect { child_class.call_async(name: "World") }.not_to raise_error
    end
  end

  shared_examples "inherits sidekiq configuration" do |queue, retry_count|
    it "inherits parent's sidekiq configuration" do
      # Sidekiq options now live on the per-action Worker subclass. A child that inherits
      # async config without redeclaring resolves (via inherited const lookup) to the
      # parent's AxnSidekiqWorker subclass.
      options = child_class.const_get(:AxnSidekiqWorker).get_sidekiq_options
      expect(options["queue"]).to eq(queue)
      expect(options["retry"]).to eq(retry_count)
    end
  end

  shared_examples "inherits active_job configuration" do |queue, priority|
    it "inherits parent's active_job configuration" do
      child_class.call_async(name: "Test")
      proxy_class = child_class.const_get("ActiveJobProxy")
      expect(proxy_class.queue_name).to eq(queue)
      expect(proxy_class.priority).to eq(priority)
    end
  end

  shared_examples "child proxy calls child method" do |adapter_type|
    it "child proxy calls child's call method, not parent's" do
      # Mock the call method to verify it's called on the child class
      # Note: adapters now call `call` (not `call!`) to handle failures correctly
      mock_result = instance_double(Axn::Result, outcome: instance_double("Outcome", exception?: false))
      expect(child_class).to receive(:call).with(name: "World").and_return(mock_result)

      if adapter_type == :sidekiq
        # The generic Worker dispatches by class name: perform(action_name, kwargs).
        # child_class is named via stub_const in the calling context.
        result = child_class.const_get(:AxnSidekiqWorker).new.perform(child_class.name, { "name" => "World" })
      else
        # For ActiveJob, trigger proxy creation and execute perform
        child_class.call_async(name: "World")
        proxy_class = child_class.const_get("ActiveJobProxy")
        proxy_instance = proxy_class.new
        result = proxy_instance.perform({ name: "World" })
      end

      expect(result).to eq(mock_result)
    end
  end

  shared_examples "parent proxy calls parent method" do |adapter_type|
    it "parent proxy calls parent's call method" do
      # Mock the call method to verify it's called on the parent class
      # Note: adapters now call `call` (not `call!`) to handle failures correctly
      mock_result = instance_double(Axn::Result, outcome: instance_double("Outcome", exception?: false))
      expect(parent_class).to receive(:call).with(name: "World").and_return(mock_result)

      if adapter_type == :sidekiq
        # The generic Worker dispatches by class name: perform(action_name, kwargs).
        # parent_class is named via stub_const in the calling context.
        result = parent_class.const_get(:AxnSidekiqWorker).new.perform(parent_class.name, { "name" => "World" })
      else
        # For ActiveJob, trigger proxy creation and execute perform
        parent_class.call_async(name: "World")
        proxy_class = parent_class.const_get("ActiveJobProxy")
        proxy_instance = proxy_class.new
        result = proxy_instance.perform({ name: "World" })
      end

      expect(result).to eq(mock_result)
    end
  end
  context "when parent class has async :sidekiq" do
    let(:parent_class) do
      klass = build_axn do
        async :sidekiq do
          sidekiq_options queue: "parent_queue", retry: 3
        end

        expects :name

        def call
          "Hello, #{name}!"
        end
      end
      # Named so the generic Sidekiq Worker can constantize it when enqueuing/dispatching.
      stub_const("SidekiqInheritanceParent", klass)
    end

    let(:child_class) do
      klass = Class.new(parent_class) do
        # No async configuration - should inherit parent's
      end
      stub_const("SidekiqInheritanceChild", klass)
    end

    include_examples "inherits async configuration", :sidekiq
    include_examples "inherits sidekiq configuration", "parent_queue", 3
  end

  context "when parent class has async :active_job" do
    let(:parent_class) do
      build_axn do
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

    include_examples "inherits async configuration", :active_job
    include_examples "inherits active_job configuration", "parent_queue", 5
  end

  context "when parent class has async false" do
    let(:parent_class) do
      build_axn do
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
      build_axn do
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
      # The child class inherits the parent's Sidekiq Worker subclass (Ruby const inheritance)
      expect(child_class.const_get(:AxnSidekiqWorker)).to be < Axn::Async::Adapters::Sidekiq::Worker

      # But it uses the child's activejob configuration
      expect(child_class._async_adapter).to eq(:active_job)

      # Trigger creation of the ActiveJob proxy class
      child_class.call_async(name: "Test")

      # Check that the proxy class was created
      proxy_class = child_class.const_get("ActiveJobProxy")
      expect(proxy_class).to be_present
    end
  end

  context "ActiveJob proxy inheritance behavior" do
    let(:parent_class) do
      build_axn do
        async :active_job do
          queue_as "parent_queue"
          self.priority = 5
        end

        expects :name

        def call
          "Parent: Hello, #{name}!"
        end
      end
    end

    let(:child_class) do
      Class.new(parent_class) do
        # Override the call method
        def call
          "Child: Hello, #{name}!"
        end
      end
    end

    it "creates separate proxy classes for parent and child" do
      # Trigger proxy creation for both classes
      parent_class.call_async(name: "Test")
      child_class.call_async(name: "Test")

      parent_proxy = parent_class.const_get("ActiveJobProxy")
      child_proxy = child_class.const_get("ActiveJobProxy")

      expect(parent_proxy).not_to eq(child_proxy)
      expect(parent_proxy.name).to include("ActiveJobProxy")
      expect(child_proxy.name).to include("ActiveJobProxy")
    end

    include_examples "child proxy calls child method", :active_job
    include_examples "parent proxy calls parent method", :active_job
    include_examples "inherits active_job configuration", "parent_queue", 5

    it "child can override parent's ActiveJob configuration" do
      child_with_override = Class.new(parent_class) do
        async :active_job do
          queue_as "child_queue"
          self.priority = 10
        end

        def call
          "Child Override: Hello, #{name}!"
        end
      end

      # Trigger proxy creation
      child_with_override.call_async(name: "Test")

      proxy_class = child_with_override.const_get("ActiveJobProxy")

      # Check that the proxy class has the child's ActiveJob configuration
      expect(proxy_class.queue_name).to eq("child_queue")
      expect(proxy_class.priority).to eq(10)
    end

    it "multiple children have separate proxy classes" do
      child1 = Class.new(parent_class) do
        def call
          "Child1: Hello, #{name}!"
        end
      end

      child2 = Class.new(parent_class) do
        def call
          "Child2: Hello, #{name}!"
        end
      end

      # Trigger proxy creation for all classes
      parent_class.call_async(name: "Test")
      child1.call_async(name: "Test")
      child2.call_async(name: "Test")

      parent_proxy = parent_class.const_get("ActiveJobProxy")
      child1_proxy = child1.const_get("ActiveJobProxy")
      child2_proxy = child2.const_get("ActiveJobProxy")

      # All proxy classes should be different
      expect(parent_proxy).not_to eq(child1_proxy)
      expect(parent_proxy).not_to eq(child2_proxy)
      expect(child1_proxy).not_to eq(child2_proxy)

      # Each should have a unique name
      expect(parent_proxy.name).to include("ActiveJobProxy")
      expect(child1_proxy.name).to include("ActiveJobProxy")
      expect(child2_proxy.name).to include("ActiveJobProxy")
    end
  end

  context "Sidekiq inheritance behavior" do
    let(:parent_class) do
      klass = build_axn do
        async :sidekiq do
          sidekiq_options queue: "parent_queue", retry: 3
        end

        expects :name

        def call
          "Parent: Hello, #{name}!"
        end
      end
      # Named so the generic Sidekiq Worker can constantize it when dispatching.
      stub_const("SidekiqBehaviorParent", klass)
    end

    let(:child_class) do
      klass = Class.new(parent_class) do
        # Override the call method
        def call
          "Child: Hello, #{name}!"
        end
      end
      stub_const("SidekiqBehaviorChild", klass)
    end

    include_examples "inherits sidekiq configuration", "parent_queue", 3
    include_examples "child proxy calls child method", :sidekiq
    include_examples "parent proxy calls parent method", :sidekiq

    it "child can have its own sidekiq configuration" do
      # Create a child that doesn't inherit any parent's sidekiq configuration
      child_with_own_config = Class.new do
        include Axn

        async :sidekiq do
          sidekiq_options queue: "child_queue", retry: 5
        end

        expects :name

        def call
          "Child Own Config: Hello, #{name}!"
        end
      end

      # Per-action sidekiq options now live on the generated Worker subclass.
      options = child_with_own_config.const_get(:AxnSidekiqWorker).get_sidekiq_options
      expect(options["queue"]).to eq("child_queue")
      expect(options["retry"]).to eq(5)
    end
  end

  context "default async configuration inheritance" do
    before do
      # Set up a default async configuration
      Axn.config.set_default_async(:active_job) do
        queue_as "default_queue"
        self.priority = 1
      end
    end

    after do
      # Reset to default
      Axn.config.set_default_async(false)
    end

    let(:parent_class) do
      build_axn do
        expects :name

        def call
          "Parent: Hello, #{name}!"
        end
      end
    end

    let(:child_class) do
      Class.new(parent_class) do
        # Override the call method
        def call
          "Child: Hello, #{name}!"
        end
      end
    end

    it "inherits default async configuration when no explicit async is set" do
      # Trigger default configuration by calling call_async
      parent_class.call_async(name: "Test")
      child_class.call_async(name: "Test")

      expect(parent_class._async_adapter).to eq(:active_job)
      expect(child_class._async_adapter).to eq(:active_job)

      # Both should have ActiveJob proxy classes
      parent_proxy = parent_class.const_get("ActiveJobProxy")
      child_proxy = child_class.const_get("ActiveJobProxy")

      expect(parent_proxy).not_to eq(child_proxy)
      expect(parent_proxy.queue_name).to eq("default_queue")
      expect(child_proxy.queue_name).to eq("default_queue")
    end

    include_examples "child proxy calls child method", :active_job

    it "can override default async configuration" do
      child_with_override = Class.new(parent_class) do
        async :sidekiq do
          sidekiq_options queue: "override_queue"
        end

        def call
          "Override: Hello, #{name}!"
        end
      end
      # Named so the generic Sidekiq Worker can constantize it when enqueuing.
      stub_const("SidekiqDefaultOverrideChild", child_with_override)

      # Trigger configuration
      child_with_override.call_async(name: "Test")

      expect(child_with_override._async_adapter).to eq(:sidekiq)
      expect(child_with_override.const_get(:AxnSidekiqWorker).get_sidekiq_options["queue"]).to eq("override_queue")
    end
  end
end
