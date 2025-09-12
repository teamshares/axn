# frozen_string_literal: true

RSpec.describe "Axn::Async async interface" do
  let(:action_class) do
    Class.new do
      include Axn

      expects :name

      def call
        "Hello, #{name}!"
      end
    end
  end

  describe "default behavior" do
    it "defaults to disabled async" do
      expect(Axn.config.default_async).to be false
    end

    it "includes Disabled module by default" do
      # Trigger default configuration by calling call_async
      expect { action_class.call_async(name: "World") }.to raise_error(NotImplementedError)
      expect(action_class.ancestors).to include(Axn::Async::Adapters::Disabled)
    end

    it "raises NotImplementedError when calling call_async" do
      # First call sets up the default configuration
      expect { action_class.call_async(name: "World") }.to raise_error(NotImplementedError)

      # Second call should use the Disabled module's method
      expect do
        action_class.call_async(name: "World")
      end.to raise_error(NotImplementedError, /Async execution is explicitly disabled/)
    end
  end

  describe "async false" do
    let(:action_class) do
      Class.new do
        include Axn

        async false

        expects :name

        def call
          "Hello, #{name}!"
        end
      end
    end

    it "includes Disabled module" do
      expect(action_class.ancestors).to include(Axn::Async::Adapters::Disabled)
    end

    it "raises NotImplementedError when calling call_async" do
      expect do
        action_class.call_async(name: "World")
      end.to raise_error(NotImplementedError, /Async execution is explicitly disabled/)
    end
  end

  describe "async :sidekiq" do
    let(:action_class) do
      Class.new do
        include Axn

        async :sidekiq do
          sidekiq_options queue: "high_priority", retry: 5
        end

        expects :name

        def call
          "Hello, #{name}!"
        end
      end
    end

    context "when Sidekiq is available" do
      before do
        # Use real Sidekiq - no mocking needed
        require "sidekiq"
      end

      it "includes Adapters::Sidekiq module" do
        expect(action_class.ancestors).to include(Axn::Async::Adapters::Sidekiq)
      end

      it "responds to call_async" do
        expect(action_class).to respond_to(:call_async)
      end

      it "applies Sidekiq configuration" do
        expect(action_class.sidekiq_options_hash).to include("queue" => "high_priority", "retry" => 5)
      end
    end
  end

  describe "async :active_job" do
    before do
      # Ensure ActiveJob is properly loaded
      require "active_job"
    end

    let(:action_class) do
      Class.new do
        include Axn

        async :active_job do
          queue_as "high_priority"
          retry_on StandardError, attempts: 3
        end

        expects :name

        def call
          "Hello, #{name}!"
        end
      end
    end

    context "when ActiveJob is available" do
      # No stubbing needed - use real ActiveJob

      it "includes Adapters::ActiveJob module" do
        expect(action_class.ancestors).to include(Axn::Async::Adapters::ActiveJob)
      end

      it "responds to call_async" do
        expect(action_class).to respond_to(:call_async)
      end

      it "applies ActiveJob configuration" do
        # Trigger creation of the proxy class by calling call_async
        action_class.call_async(name: "Test")

        # Check that the proxy class was created and configured
        proxy_class = action_class.const_get("ActiveJobProxy")
        expect(proxy_class).to be_present
        expect(proxy_class.name).to eq("#{action_class.name}::ActiveJobProxy")
      end
    end
  end

  describe "invalid adapter" do
    it "raises AdapterNotFound for unsupported adapter" do
      expect do
        Class.new do
          include Axn
          async :unsupported
        end
      end.to raise_error(Axn::Async::AdapterNotFound, "Adapter 'unsupported' not found")
    end
  end

  describe "async without block" do
    let(:action_class) do
      Class.new do
        include Axn

        async :sidekiq

        expects :name

        def call
          "Hello, #{name}!"
        end
      end
    end

    context "when Sidekiq is available" do
      before do
        stub_const("Sidekiq", Module.new)
        stub_const("Sidekiq::Job", Module.new)
      end

      it "includes Adapters::Sidekiq module without configuration" do
        expect(action_class.ancestors).to include(Axn::Async::Adapters::Sidekiq)
      end

      it "responds to call_async" do
        expect(action_class).to respond_to(:call_async)
      end
    end
  end
end
