# frozen_string_literal: true

begin
  require "faraday"
rescue LoadError
  # Faraday not available
end

RSpec.describe Axn::Extras::Strategies::Client do
  let(:test_action) { build_axn }

  before do
    skip "Faraday is not available" unless defined?(Faraday)
    Axn::Strategies.clear!
    Axn::Strategies.register(:client, described_class)
  end

  describe ".configure" do
    context "with default configuration" do
      it "creates a client method with default name" do
        test_action.use(:client, url: "https://api.example.com")
        instance = test_action.allocate
        instance.send(:initialize)

        expect(instance).to respond_to(:client)
        expect(instance.client).to be_a(Faraday::Connection)
        expect(instance.client.url_prefix.to_s).to eq("https://api.example.com/")
      end

      it "sets default headers" do
        test_action.use(:client, url: "https://api.example.com")
        instance = test_action.allocate
        instance.send(:initialize)

        expect(instance.client.headers["Content-Type"]).to eq("application/json")
        expect(instance.client.headers["User-Agent"]).to match(%r{client / Axn Client Strategy / v})
      end
    end

    context "with custom name" do
      it "creates a client method with custom name" do
        test_action.use(:client, name: :api_client, url: "https://api.example.com")
        instance = test_action.allocate
        instance.send(:initialize)

        expect(instance).to respond_to(:api_client)
        expect(instance).not_to respond_to(:client)
        expect(instance.api_client).to be_a(Faraday::Connection)
      end

      it "uses custom name in user agent" do
        test_action.use(:client, name: :api_client, url: "https://api.example.com")
        instance = test_action.allocate
        instance.send(:initialize)

        expect(instance.api_client.headers["User-Agent"]).to match(%r{api_client / Axn Client Strategy / v})
      end
    end

    context "with custom user_agent" do
      it "uses provided user agent" do
        test_action.use(:client, url: "https://api.example.com", user_agent: "MyApp/1.0")
        instance = test_action.allocate
        instance.send(:initialize)

        expect(instance.client.headers["User-Agent"]).to eq("MyApp/1.0")
      end
    end

    context "with prepend_config" do
      it "calls prepend_config before default middleware" do
        prepend_called = false
        prepend_config = proc do |conn|
          prepend_called = true
          conn.headers["X-Custom"] = "value"
        end

        test_action.use(:client, url: "https://api.example.com", prepend_config:)
        instance = test_action.allocate
        instance.send(:initialize)

        # Call the client method to trigger its creation
        client = instance.client

        expect(prepend_called).to be true
        expect(client.headers["X-Custom"]).to eq("value")
      end
    end

    context "with debug option" do
      it "enables logger middleware when debug is true" do
        test_action.use(:client, url: "https://api.example.com", debug: true)
        instance = test_action.allocate
        instance.send(:initialize)

        # Check that logger middleware is in the stack
        # Faraday stores middleware in reverse order
        client = instance.client
        middleware_klasses = client.builder.handlers.map do |h|
          h.klass
        rescue StandardError
          h.class
        end
        expect(middleware_klasses).to include(Faraday::Response::Logger)
      end

      it "does not enable logger middleware when debug is false" do
        test_action.use(:client, url: "https://api.example.com", debug: false)
        instance = test_action.allocate
        instance.send(:initialize)

        middleware_classes = instance.client.builder.handlers.map(&:class)
        expect(middleware_classes).not_to include(Faraday::Response::Logger)
      end
    end

    context "with configuration block" do
      it "calls the block with the connection" do
        block_called = false
        test_action.use(:client, url: "https://api.example.com") do |conn|
          block_called = true
          conn.headers["X-From-Block"] = "block-value"
        end
        instance = test_action.allocate
        instance.send(:initialize)

        # Call the client method to trigger its creation
        client = instance.client

        expect(block_called).to be true
        expect(client.headers["X-From-Block"]).to eq("block-value")
      end
    end

    context "with callable options" do
      it "hydrates callable options" do
        dynamic_url = proc { "https://dynamic.example.com" }
        test_action.use(:client, url: dynamic_url)
        instance = test_action.allocate
        instance.send(:initialize)

        expect(instance.client.url_prefix.to_s).to eq("https://dynamic.example.com/")
      end
    end

    context "with Faraday connection options" do
      it "passes options to Faraday.new" do
        test_action.use(:client, url: "https://api.example.com", request: { timeout: 5 })
        instance = test_action.allocate
        instance.send(:initialize)

        expect(instance.client.options.timeout).to eq(5)
      end
    end

    context "memoization" do
      it "memoizes the client instance" do
        test_action.use(:client, url: "https://api.example.com")
        instance = test_action.allocate
        instance.send(:initialize)

        first_call = instance.client
        second_call = instance.client

        expect(first_call).to be(second_call)
      end
    end

    context "error handling" do
      it "raises error if client name is already taken" do
        action_with_method = build_axn do
          def existing_method; end
        end

        # Verify the method exists before trying to use it as a client name
        expect(action_with_method.method_defined?(:existing_method)).to be true

        expect do
          action_with_method.use(:client, name: :existing_method, url: "https://api.example.com")
        end.to raise_error(ArgumentError, "client strategy: desired client name 'existing_method' is already taken")
      end
    end
  end

  describe "strategy registration" do
    it "registers the strategy when faraday is available" do
      expect(Axn::Strategies.all[:client]).to be(described_class)
    end

    it "can be used via use method" do
      test_action.use(:client, url: "https://api.example.com")
      instance = test_action.allocate
      instance.send(:initialize)

      expect(instance).to respond_to(:client)
    end
  end
end
