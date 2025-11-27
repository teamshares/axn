# frozen_string_literal: true

RSpec.describe "Axn::Extras::Strategies::Client::ErrorHandlerMiddleware" do
  before(:all) do
    # Register the client strategy if not already registered
    Axn::Strategies.register(:client, Axn::Extras::Strategies::Client) unless Axn::Strategies.all[:client]

    # Ensure the ErrorHandlerMiddleware class is defined by triggering its lazy definition
    unless Axn::Extras::Strategies::Client.const_defined?(:ErrorHandlerMiddleware, false)
      test_action = Class.new { include Axn }
      test_action.use(:client, url: "https://api.example.com", error_handler: { error_key: "error" })
      instance = test_action.allocate
      instance.send(:initialize)
      instance.client # This triggers the class definition
    end
  end

  let(:app) { double("app") }
  let(:config) { {} }
  let(:middleware) { Axn::Extras::Strategies::Client::ErrorHandlerMiddleware.new(app, config) }
  let(:env) { double("env", method: :get, url: "https://api.example.com/test") }
  let(:response_env) { double("response_env", status: 200, body: {}.to_json, method: :get, url: "https://api.example.com/test") }

  before do
    allow(app).to receive(:call).and_return(response_env)
    allow(response_env).to receive(:on_complete).and_yield(response_env)
  end

  def setup_error_response(status:, body:)
    allow(response_env).to receive(:status).and_return(status)
    allow(response_env).to receive(:body).and_return(body.to_json)
  end

  def expect_error_with_message(error_class, message_pattern = nil, &block)
    expect { middleware.call(env) }.to raise_error(error_class, message_pattern, &block)
  end

  describe "#call" do
    context "with default condition (status != 200)" do
      let(:config) { { error_key: "error" } }

      it "does not handle error when status is 200" do
        expect(middleware).not_to receive(:handle_error)
        middleware.call(env)
      end

      it "handles error when status is not 200" do
        setup_error_response(status: 400, body: {})
        expect(middleware).to receive(:handle_error).with(response_env, {})
        middleware.call(env)
      end
    end

    context "with custom if condition" do
      let(:config) do
        {
          error_key: "error",
          if: -> { status != 200 && body["error"].present? },
        }
      end

      it "handles error when condition is true" do
        setup_error_response(status: 400, body: { "error" => "BadRequest" })
        expect(middleware).to receive(:handle_error)
        middleware.call(env)
      end

      it "does not handle error when condition is false" do
        setup_error_response(status: 400, body: {})
        expect(middleware).not_to receive(:handle_error)
        middleware.call(env)
      end
    end

    context "with error_key" do
      let(:config) { { error_key: "error" } }

      it "extracts error from response body" do
        setup_error_response(status: 400, body: { "error" => "Something went wrong" })
        expect_error_with_message(Faraday::BadRequestError, /Something went wrong/)
      end

      it "handles nested error keys" do
        config[:error_key] = "data.message"
        setup_error_response(status: 400, body: { "data" => { "message" => "Nested error" } })
        expect_error_with_message(Faraday::BadRequestError, /Nested error/)
      end
    end

    context "with detail_key and extract_detail for array" do
      let(:config) do
        {
          error_key: "error",
          detail_key: "validation.errors",
          extract_detail: ->(node) { node["message"] },
        }
      end

      it "extracts and formats details from array" do
        setup_error_response(status: 400, body: {
                               "error" => "Validation failed",
                               "validation" => {
                                 "errors" => [
                                   { "message" => "Email is invalid" },
                                   { "message" => "Name is required" },
                                 ],
                               },
                             })
        expect_error_with_message(Faraday::BadRequestError) do |error|
          expect(error.message).to include("Validation failed")
          expect(error.message).to include("Email is invalid")
          expect(error.message).to include("Name is required")
        end
      end
    end

    context "with detail_key and extract_detail for hash" do
      let(:config) do
        {
          error_key: "error",
          detail_key: "details",
          extract_detail: lambda { |key, value|
            descriptions = Array(value).map { |v| v["description"] }.compact
            "#{key.to_s.humanize}: #{descriptions.to_sentence}" if descriptions.any?
          },
        }
      end

      it "extracts and formats details from hash" do
        setup_error_response(status: 400, body: {
                               "error" => "RecordInvalid",
                               "details" => {
                                 "email" => [{ "description" => "Email is already in use" }],
                                 "name" => [{ "description" => "Name is required" }],
                               },
                             })
        expect_error_with_message(Faraday::BadRequestError) do |error|
          expect(error.message).to include("RecordInvalid")
          expect(error.message).to include("Email: Email is already in use")
          expect(error.message).to include("Name: Name is required")
        end
      end
    end

    context "with custom exception_class" do
      let(:custom_error) { Class.new(StandardError) }
      let(:config) do
        {
          error_key: "error",
          exception_class: custom_error,
        }
      end

      it "raises custom exception class" do
        setup_error_response(status: 400, body: { "error" => "Custom error" })
        expect_error_with_message(custom_error)
      end
    end

    context "with custom formatter" do
      let(:config) do
        {
          error_key: "error",
          formatter: ->(error, _details, _response_env) { "Custom: #{error}" },
        }
      end

      it "uses custom formatter" do
        setup_error_response(status: 400, body: { "error" => "Test error" })
        expect_error_with_message(Faraday::BadRequestError, /Custom: Test error/)
      end
    end

    context "with backtrace_key" do
      let(:config) do
        {
          error_key: "error",
          backtrace_key: "data.backtrace",
          exception_class: Class.new(StandardError),
        }
      end

      it "sets backtrace on exception" do
        custom_error = config[:exception_class]
        backtrace = ["file1.rb:10", "file2.rb:20"]
        setup_error_response(status: 400, body: {
                               "error" => "Test error",
                               "data" => { "backtrace" => backtrace },
                             })
        expect_error_with_message(custom_error) do |error|
          expect(error.backtrace).to eq(backtrace)
        end
      end
    end

    context "with default formatter (no extract_detail)" do
      let(:config) do
        {
          error_key: "error",
          detail_key: "details",
        }
      end

      it "raises ArgumentError when details is not a string" do
        setup_error_response(status: 400, body: {
                               "error" => "Test error",
                               "details" => [
                                 { "message" => "Detail 1" },
                                 { "description" => "Detail 2" },
                               ],
                             })
        expect_error_with_message(ArgumentError, /must provide extract_detail when detail_key is set and details is not a string/)
      end

      it "uses details directly when details is a string" do
        setup_error_response(status: 400, body: {
                               "error" => "Test error",
                               "details" => "Detail message",
                             })
        expect_error_with_message(Faraday::BadRequestError) do |error|
          expect(error.message).to include("Test error")
          expect(error.message).to include("Detail message")
        end
      end
    end

    context "message formatting" do
      let(:config) { { error_key: "error" } }

      it "includes prefix with method and URL" do
        setup_error_response(status: 400, body: { "error" => "Test error" })
        expect_error_with_message(Faraday::BadRequestError) do |error|
          expect(error.message).to match(%r{Error while GETing https://api\.example\.com/test})
          expect(error.message).to include("Test error")
        end
      end

      it "joins error and details with dash" do
        config[:detail_key] = "details"
        config[:extract_detail] = ->(node) { node["message"] }
        setup_error_response(status: 400, body: {
                               "error" => "Error message",
                               "details" => [{ "message" => "Detail message" }],
                             })
        expect_error_with_message(Faraday::BadRequestError) do |error|
          expect(error.message).to match(/Error message - Detail message/)
        end
      end
    end
  end
end
