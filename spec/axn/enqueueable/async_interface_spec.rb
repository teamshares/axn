# frozen_string_literal: true

RSpec.describe "Axn::Enqueueable async interface" do
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
      expect(action_class.ancestors).to include(Axn::Enqueueable::Disabled)
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
      expect(action_class.ancestors).to include(Axn::Enqueueable::Disabled)
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
        stub_const("Sidekiq", Module.new)
        stub_const("Sidekiq::Job", Module.new)
      end

      it "includes ViaSidekiq module" do
        expect(action_class.ancestors).to include(Axn::Enqueueable::ViaSidekiq)
      end

      it "responds to call_async" do
        expect(action_class).to respond_to(:call_async)
      end

      it "applies Sidekiq configuration" do
        expect(action_class.sidekiq_options_hash).to include("queue" => "high_priority", "retry" => 5)
      end
    end

    context "when Sidekiq is not available" do
      it "raises LoadError" do
        expect { action_class }.to raise_error(LoadError, /Sidekiq is not available/)
      end
    end
  end

  describe "async :active_job" do
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
      before do
        stub_const("ActiveJob", Module.new)
        stub_const("ActiveJob::Base", Class.new)
      end

      it "includes ViaActiveJob module" do
        expect(action_class.ancestors).to include(Axn::Enqueueable::ViaActiveJob)
      end

      it "responds to call_async" do
        expect(action_class).to respond_to(:call_async)
      end

      it "applies ActiveJob configuration" do
        expect(action_class._activejob_configs).to include([:queue_as, "high_priority"])
        retry_config = action_class._activejob_configs.find { |config| config[0] == :retry_on }
        expect(retry_config).to be_present
        expect(retry_config[1][:exception]).to eq(StandardError)
        expect(retry_config[1][:attempts]).to eq(3)
      end
    end

    context "when ActiveJob is not available" do
      it "raises LoadError" do
        expect { action_class }.to raise_error(LoadError, /ActiveJob is not available/)
      end
    end
  end

  describe "invalid adapter" do
    it "raises ArgumentError for unsupported adapter" do
      expect do
        Class.new do
          include Axn
          async :unsupported
        end
      end.to raise_error(ArgumentError, /Unsupported async adapter: unsupported/)
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

      it "includes ViaSidekiq module without configuration" do
        expect(action_class.ancestors).to include(Axn::Enqueueable::ViaSidekiq)
      end

      it "responds to call_async" do
        expect(action_class).to respond_to(:call_async)
      end
    end

    context "when Sidekiq is not available" do
      it "raises LoadError" do
        expect { action_class }.to raise_error(LoadError, /Sidekiq is not available/)
      end
    end
  end
end
