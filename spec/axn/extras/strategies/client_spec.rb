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

  def create_client_instance(action, **options, &block)
    action.use(:client, url: "https://api.example.com", **options, &block)
    instance = action.allocate
    instance.send(:initialize)
    instance
  end

  def middleware_klasses(client)
    client.builder.handlers.map do |h|
      h.klass
    rescue StandardError
      h.class
    end
  end

  describe ".configure" do
    context "with default configuration" do
      it "creates a client method with default name" do
        instance = create_client_instance(test_action)

        expect(instance).to respond_to(:client)
        expect(instance.client).to be_a(Faraday::Connection)
        expect(instance.client.url_prefix.to_s).to eq("https://api.example.com/")
      end

      it "sets default headers" do
        instance = create_client_instance(test_action)

        expect(instance.client.headers["Content-Type"]).to eq("application/json")
        expect(instance.client.headers["User-Agent"]).to match(%r{client / Axn Client Strategy / v})
      end
    end

    context "with custom name" do
      it "creates a client method with custom name" do
        instance = create_client_instance(test_action, name: :api_client)

        expect(instance).to respond_to(:api_client)
        expect(instance).not_to respond_to(:client)
        expect(instance.api_client).to be_a(Faraday::Connection)
      end

      it "uses custom name in user agent" do
        instance = create_client_instance(test_action, name: :api_client)

        expect(instance.api_client.headers["User-Agent"]).to match(%r{api_client / Axn Client Strategy / v})
      end
    end

    context "with custom user_agent" do
      it "uses provided user agent" do
        instance = create_client_instance(test_action, user_agent: "MyApp/1.0")

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

        instance = create_client_instance(test_action, prepend_config:)
        client = instance.client

        expect(prepend_called).to be true
        expect(client.headers["X-Custom"]).to eq("value")
      end
    end

    context "with debug option" do
      it "enables logger middleware when debug is true" do
        instance = create_client_instance(test_action, debug: true)

        expect(middleware_klasses(instance.client)).to include(Faraday::Response::Logger)
      end

      it "does not enable logger middleware when debug is false" do
        instance = create_client_instance(test_action, debug: false)

        expect(middleware_klasses(instance.client)).not_to include(Faraday::Response::Logger)
      end
    end

    context "with configuration block" do
      it "calls the block with the connection" do
        block_called = false
        instance = create_client_instance(test_action) do |conn|
          block_called = true
          conn.headers["X-From-Block"] = "block-value"
        end
        client = instance.client

        expect(block_called).to be true
        expect(client.headers["X-From-Block"]).to eq("block-value")
      end
    end

    context "with callable options" do
      it "hydrates callable options" do
        dynamic_url = proc { "https://dynamic.example.com" }
        instance = create_client_instance(test_action, url: dynamic_url)

        expect(instance.client.url_prefix.to_s).to eq("https://dynamic.example.com/")
      end
    end

    context "with Faraday connection options" do
      it "passes options to Faraday.new" do
        instance = create_client_instance(test_action, request: { timeout: 5 })

        expect(instance.client.options.timeout).to eq(5)
      end
    end

    context "memoization" do
      it "memoizes the client instance" do
        instance = create_client_instance(test_action)

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

    context "with error_handler" do
      it "injects ErrorHandlerMiddleware when error_handler is provided" do
        instance = create_client_instance(test_action, error_handler: { error_key: "error" })

        expect(middleware_klasses(instance.client)).to include(Axn::Extras::Strategies::Client::ErrorHandlerMiddleware)
      end

      it "does not inject ErrorHandlerMiddleware when error_handler is nil" do
        instance = create_client_instance(test_action, error_handler: nil)

        expect(middleware_klasses(instance.client)).not_to include(Axn::Extras::Strategies::Client::ErrorHandlerMiddleware)
      end

      it "does not inject ErrorHandlerMiddleware when error_handler is not provided" do
        instance = create_client_instance(test_action)

        expect(middleware_klasses(instance.client)).not_to include(Axn::Extras::Strategies::Client::ErrorHandlerMiddleware)
      end
    end

    context "additional logging context (client request/response)" do
      it "injects LoggingContextMiddleware into the connection" do
        instance = create_client_instance(test_action)

        expect(middleware_klasses(instance.client)).to include(Axn::Extras::Strategies::Client::LoggingContextMiddleware)
      end

      it "includes client_strategy__last_request (url, method, status) in exception context when a request was made" do
        original_handler = Axn.config.instance_variable_get(:@on_exception)
        Axn.config.instance_variable_set(:@on_exception, nil)
        allow(Axn.config).to receive(:on_exception)

        action = build_axn do
          use :client, url: "https://api.example.com" do |conn|
            conn.adapter :test do |stub|
              stub.get("/users") { [200, { "Content-Type" => "application/json" }, "{}"] }
            end
          end

          def call
            client.get("/users")
            raise "intentional failure after request"
          end
        end

        action.call

        expect(Axn.config).to have_received(:on_exception).with(
          an_instance_of(RuntimeError),
          hash_including(
            context: hash_including(
              inputs: hash_including(
                client_strategy__last_request: hash_including(
                  url: a_string_matching(/api\.example\.com.*users/),
                  method: "GET",
                  status: 200,
                ),
              ),
            ),
          ),
        )
      ensure
        Axn.config.instance_variable_set(:@on_exception, original_handler)
      end
    end
  end

  describe "strategy registration" do
    it "registers the strategy when faraday is available" do
      expect(Axn::Strategies.all[:client]).to be(described_class)
    end

    it "can be used via use method" do
      instance = create_client_instance(test_action)

      expect(instance).to respond_to(:client)
    end
  end
end
