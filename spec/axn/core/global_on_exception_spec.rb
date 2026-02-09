# frozen_string_literal: true

RSpec.describe "Global on_exception handler" do
  let(:original_handler) { Axn.config.instance_variable_get(:@on_exception) }
  before do
    # Clear any existing global handler
    Axn.config.instance_variable_set(:@on_exception, nil)
  end

  after do
    # Restore original handler
    Axn.config.instance_variable_set(:@on_exception, original_handler)
  end

  describe "basic functionality" do
    let(:action) do
      build_axn do
        expects :name, type: String
        expects :age, type: Integer, numericality: { greater_than: 0 }
        exposes :processed_name

        def call
          raise "Something went wrong!" if name == "error"

          expose :processed_name, "Hello, #{name}!"
        end
      end
    end

    context "when no global handler is set" do
      before do
        Axn.config.instance_variable_set(:@on_exception, nil)
      end

      it "logs the exception but doesn't call a custom handler" do
        expect_any_instance_of(action).to receive(:log).with(
          "#{'#' * 10} Handled exception (RuntimeError): Something went wrong! #{'#' * 10}",
        )
        expect(action.call(name: "error", age: 25)).not_to be_ok
      end
    end

    context "when global handler is set" do
      it "calls the global handler with exception, action, and context (inputs and outputs)" do
        expect(Axn.config).to receive(:on_exception).with(
          an_instance_of(RuntimeError),
          action: an_instance_of(action),
          context: hash_including(inputs: { name: "error", age: 25 }, outputs: {}),
        ).and_call_original

        result = action.call(name: "error", age: 25)
        expect(result).not_to be_ok
      end

      it "doesn't call handler when action succeeds" do
        expect(Axn.config).not_to receive(:on_exception)
        result = action.call(name: "success", age: 25)
        expect(result).to be_ok
      end
    end
  end

  describe "handler parameter variations" do
    let(:action) do
      build_axn do
        expects :trigger_error, type: :boolean, default: false

        def call
          raise "Test error" if trigger_error
        end
      end
    end

    context "handler accepts only exception" do
      it "calls handler with only exception" do
        expect(Axn.config).to receive(:on_exception).with(
          an_instance_of(RuntimeError),
          action: an_instance_of(action),
          context: hash_including(inputs: { trigger_error: true }, outputs: {}),
        ).and_call_original

        action.call(trigger_error: true)
      end
    end

    context "handler accepts exception and action" do
      it "calls handler with exception and action" do
        expect(Axn.config).to receive(:on_exception).with(
          an_instance_of(RuntimeError),
          action: an_instance_of(action),
          context: hash_including(inputs: { trigger_error: true }, outputs: {}),
        ).and_call_original

        action.call(trigger_error: true)
      end
    end

    context "handler accepts exception and context" do
      it "calls handler with exception and context" do
        expect(Axn.config).to receive(:on_exception).with(
          an_instance_of(RuntimeError),
          action: an_instance_of(action),
          context: hash_including(inputs: { trigger_error: true }, outputs: {}),
        ).and_call_original

        action.call(trigger_error: true)
      end
    end

    context "handler accepts all parameters" do
      it "calls handler with all parameters" do
        expect(Axn.config).to receive(:on_exception).with(
          an_instance_of(RuntimeError),
          action: an_instance_of(action),
          context: hash_including(inputs: { trigger_error: true }, outputs: {}),
        ).and_call_original

        action.call(trigger_error: true)
      end
    end
  end

  describe "sensitive data filtering" do
    let(:action) do
      build_axn do
        expects :username, type: String
        expects :password, type: String, sensitive: true
        expects :email, type: String, sensitive: true
        expects :age, type: Integer
        exposes :user_id

        def call
          raise "Database error" if username == "fail"

          expose :user_id, 123
        end
      end
    end

    it "filters sensitive data from context" do
      expect(Axn.config).to receive(:on_exception).with(
        an_instance_of(RuntimeError),
        action: an_instance_of(action),
        context: hash_including(
          inputs: {
            username: "fail",
            password: "[FILTERED]",
            email: "[FILTERED]",
            age: 30,
          },
          outputs: {},
        ),
      ).and_call_original

      action.call(username: "fail", password: "secret123", email: "user@example.com", age: 30)
    end
  end

  describe "error handling in global handler" do
    let(:action) do
      build_axn do
        expects :trigger_error, type: :boolean, default: false

        def call
          raise "Something went wrong" if trigger_error
        end
      end
    end

    it "logs handler errors without affecting original exception" do
      Axn.config.on_exception = proc do |e|
        raise "Handler error: #{e.message}"
      end

      expect(Axn::Internal::Logging).to receive(:piping_error).with(
        "executing on_exception hooks",
        hash_including(action: an_instance_of(action), exception: an_object_satisfying { |e|
          e.is_a?(RuntimeError) && e.message == "Handler error: Something went wrong"
        }),
      )

      result = action.call(trigger_error: true)
      expect(result).not_to be_ok
      expect(result.error).to eq("Something went wrong")
    end
  end

  describe "multiple exception types" do
    let(:action) do
      build_axn do
        expects :error_type, type: String, default: "RuntimeError"

        def call
          case error_type
          when "RuntimeError"
            raise "Runtime error"
          when "ArgumentError"
            raise ArgumentError, "Invalid argument"
          when "NoMethodError"
            raise NoMethodError, "Method not found"
          end
        end
      end
    end

    it "handles different exception types" do
      expect(Axn.config).to receive(:on_exception).with(
        an_instance_of(RuntimeError),
        action: an_instance_of(action),
        context: hash_including(inputs: { error_type: "RuntimeError" }, outputs: {}),
      ).and_call_original

      action.call(error_type: "RuntimeError")
    end
  end

  describe "production vs development logging" do
    let(:action) do
      build_axn do
        def call
          raise "Test error"
        end
      end
    end

    context "in development environment" do
      before do
        allow(Axn.config).to receive(:env).and_return(ActiveSupport::StringInquirer.new("development"))
      end

      it "logs with decorative formatting" do
        expect(Axn.config).to receive(:on_exception).and_call_original
        expect_any_instance_of(action).to receive(:log).with(
          "#{'#' * 10} Handled exception (RuntimeError): Test error #{'#' * 10}",
        )
        action.call
      end
    end

    context "in production environment" do
      before do
        allow(Axn.config).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
      end

      it "logs without decorative formatting" do
        expect(Axn.config).to receive(:on_exception).and_call_original
        expect_any_instance_of(action).to receive(:log).with(
          "Handled exception (RuntimeError): Test error",
        )
        action.call
      end
    end
  end

  describe "integration with action-specific on_exception" do
    let(:action) do
      build_axn do
        expects :trigger_error, type: :boolean, default: false

        def call
          raise "Test error" if trigger_error
        end
      end
    end

    it "calls global handler" do
      expect(Axn.config).to receive(:on_exception).with(
        an_instance_of(RuntimeError),
        action: an_instance_of(action),
        context: hash_including(inputs: { trigger_error: true }, outputs: {}),
      ).and_call_original

      expect_any_instance_of(action).to receive(:log).with(
        "#{'#' * 10} Handled exception (RuntimeError): Test error #{'#' * 10}",
      )

      result = action.call(trigger_error: true)
      expect(result).not_to be_ok
    end
  end

  describe "enhanced context features" do
    # Use a named class so retry_command can access the class name
    before do
      stub_const("TestEnhancedContextAction", build_axn do
        expects :name, type: String
        expects :value, type: Integer

        def call
          raise "Test error"
        end
      end)
    end

    let(:action) { TestEnhancedContextAction }

    shared_context "with retry command in exceptions enabled" do
      around do |example|
        original = Axn.config._include_retry_command_in_exceptions
        Axn.config._include_retry_command_in_exceptions = true
        example.run
      ensure
        Axn.config._include_retry_command_in_exceptions = original
      end
    end

    describe "automatic formatting" do
      it "always formats complex objects in context and includes outputs" do
        expect(Axn.config).to receive(:on_exception) do |_e, _action, context:|
          expect(context[:inputs]).to eq({ name: "test", value: 42 })
          expect(context[:outputs]).to eq({})
        end

        action.call(name: "test", value: 42)
      end
    end

    describe "_include_retry_command_in_exceptions (experimental)" do
      include_context "with retry command in exceptions enabled"

      it "includes retry command in context when enabled" do
        expect(Axn.config).to receive(:on_exception) do |_e, _action, context:|
          expect(context[:retry_command]).to eq('TestEnhancedContextAction.call(name: "test", value: 42)')
        end

        action.call(name: "test", value: 42)
      end
    end

    describe "automatic Current.attributes inclusion" do
      before do
        # Define a mock Current class
        stub_const("Current", Class.new do
          class << self
            attr_accessor :request_id

            def attributes
              { request_id: }
            end
          end
        end)

        Current.request_id = "test-request-123"
      end

      it "automatically includes Current.attributes when defined and present" do
        expect(Axn.config).to receive(:on_exception) do |_e, _action, context:|
          expect(context[:current_attributes]).to eq({ request_id: "test-request-123" })
        end

        action.call(name: "test", value: 42)
      end

      it "does not include Current.attributes when empty" do
        Current.request_id = nil

        expect(Axn.config).to receive(:on_exception) do |_e, _action, context:|
          expect(context[:current_attributes]).to be_nil
        end

        action.call(name: "test", value: 42)
      end
    end

    describe "combined features" do
      include_context "with retry command in exceptions enabled"

      before do
        stub_const("Current", Class.new do
          class << self
            attr_accessor :user_id

            def attributes
              { user_id: }
            end
          end
        end)

        Current.user_id = 456
      end

      it "includes all context enhancements (formatting always on, Current auto-detected, retry command if enabled)" do
        expect(Axn.config).to receive(:on_exception) do |_e, _action, context:|
          expect(context.keys).to contain_exactly(:inputs, :outputs, :retry_command, :current_attributes)
          expect(context[:inputs]).to eq({ name: "test", value: 42 })
          expect(context[:outputs]).to eq({})
          expect(context[:retry_command]).to be_a(String)
          expect(context[:current_attributes]).to eq({ user_id: 456 })
        end

        action.call(name: "test", value: 42)
      end
    end
  end
end
