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

      it "includes Adapters::Sidekiq module without configuration" do
        expect(action_class.ancestors).to include(Axn::Async::Adapters::Sidekiq)
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
