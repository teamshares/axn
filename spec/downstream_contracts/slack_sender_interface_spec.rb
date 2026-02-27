# frozen_string_literal: true

# =============================================================================
# SlackSender Interface Contract Spec
# =============================================================================
#
# This spec documents and tests the axn interface used by the slack_sender gem.
# Changes that break these specs require corresponding updates to slack_sender.
#
# slack_sender relies on:
# - Strategy registration (Axn::Strategies.register / find)
# - Strategy usage via `use :name, **config`
# - Action DSL: expects, exposes, error(if:), preprocess lambdas
# - Async API: call_async, async adapter configuration
# - Sync API: call!, Result with exposed values
# - Exception types: ContractViolation::PreprocessingError
# - Configuration: Axn.configure with on_exception
# =============================================================================

require "spec_helper"

RSpec.describe "SlackSender interface contract" do
  # Custom error class to simulate SlackSender::InvalidArgumentsError
  # rubocop:disable Lint/ConstantDefinitionInBlock
  class TestInvalidArgumentsError < ArgumentError; end
  # rubocop:enable Lint/ConstantDefinitionInBlock

  describe "Strategy registration and usage" do
    let(:test_strategy) do
      Module.new do
        def self.configure(**defaults)
          Module.new do
            extend ActiveSupport::Concern

            included do
              define_method(:__test_defaults) { defaults }
              private :__test_defaults
            end

            def notify(text = nil, **kwargs)
              kwargs[:text] = text if text
              __test_defaults.merge(kwargs)
            end
          end
        end
      end
    end

    after do
      Axn::Strategies.clear!
    end

    it "registers a strategy with Axn::Strategies.register" do
      Axn::Strategies.register(:test_notify, test_strategy)
      expect(Axn::Strategies.find(:test_notify)).to eq(test_strategy)
    end

    it "raises StrategyNotFound for unknown strategies" do
      expect { Axn::Strategies.find(:nonexistent) }.to raise_error(Axn::StrategyNotFound)
    end

    it "allows actions to use registered strategies via `use :name, **config`" do
      Axn::Strategies.register(:test_notify, test_strategy)

      action_class = Class.new do
        include Axn
        use :test_notify, channel: :general, profile: :default

        def call
          result = notify("Hello!")
          expose output: result
        end
      end
      action_class.exposes :output, type: Hash, optional: true

      result = action_class.call
      expect(result.output).to eq({ channel: :general, profile: :default, text: "Hello!" })
    end

    it "strategy configure receives config and returns a module" do
      Axn::Strategies.register(:test_notify, test_strategy)

      configured_module = test_strategy.configure(channel: :alerts)
      expect(configured_module).to be_a(Module)
    end
  end

  describe "Action contract with expects/exposes" do
    let(:action_class) do
      Class.new do
        include Axn

        expects :profile, type: String, preprocess: lambda(&:upcase)
        expects :channel, type: String
        expects :text, type: String, optional: true
        expects :icon_emoji, type: String, optional: true, preprocess: lambda { |raw|
          ":#{raw}:".squeeze(":") if raw.present?
        }
        expects :blocks, type: Array, optional: true
        expects :validate_known_channel, type: :boolean, default: false

        exposes :thread_ts, type: String, optional: true

        def call
          expose thread_ts: "#{profile}.#{channel}.123456"
        end
      end
    end

    it "preprocesses expected fields via lambda" do
      result = action_class.call(profile: "test", channel: "general")
      expect(result.thread_ts).to eq("TEST.general.123456")
    end

    it "applies default values for optional fields" do
      result = action_class.call(profile: "test", channel: "general")
      expect(result).to be_ok
    end

    it "exposes values via expose and makes them accessible on Result" do
      result = action_class.call(profile: "test", channel: "general")
      expect(result.thread_ts).to eq("TEST.general.123456")
    end

    it "provides reader methods for expected fields within action" do
      values_captured = {}
      test_action = Class.new do
        include Axn
        expects :name, type: String
        expects :count, type: Integer, default: 0

        define_method(:call) do
          values_captured[:name] = name
          values_captured[:count] = count
        end
      end

      test_action.call(name: "test")
      expect(values_captured).to eq({ name: "test", count: 0 })
    end
  end

  describe "error(if:) for custom error messages" do
    let(:action_with_error_handling) do
      Class.new do
        include Axn

        error(if: TestInvalidArgumentsError, &:message)
        error(if: lambda { |exception:|
          exception.is_a?(Axn::ContractViolation::PreprocessingError) && exception.cause.is_a?(TestInvalidArgumentsError)
        }) { |e| e.cause.message }

        expects :input, type: String, preprocess: lambda { |val|
          raise TestInvalidArgumentsError, "Invalid input: #{val}" if val == "bad"

          val
        }

        def call; end
      end
    end

    it "uses error handler message for matching exception class" do
      direct_error_action = Class.new do
        include Axn
        error(if: TestInvalidArgumentsError, &:message)

        def call
          raise TestInvalidArgumentsError, "Direct error message"
        end
      end

      result = direct_error_action.call
      expect(result).not_to be_ok
      expect(result.error).to eq("Direct error message")
    end

    it "wraps preprocess exceptions in PreprocessingError with cause" do
      result = action_with_error_handling.call(input: "bad")
      expect(result).not_to be_ok
      expect(result.exception).to be_a(Axn::ContractViolation::PreprocessingError)
      expect(result.exception.cause).to be_a(TestInvalidArgumentsError)
    end

    it "uses lambda-based error handler for PreprocessingError with specific cause" do
      result = action_with_error_handling.call(input: "bad")
      expect(result.error).to eq("Invalid input: bad")
    end
  end

  describe "Async API" do
    let(:async_action) do
      Class.new do
        include Axn
        async false

        expects :profile, type: String
        expects :channel, type: String
        exposes :thread_ts, type: String, optional: true

        def call
          expose thread_ts: "12345.67890"
        end
      end
    end

    it "responds to call_async class method" do
      expect(async_action).to respond_to(:call_async)
    end

    it "responds to call! class method for sync execution" do
      expect(async_action).to respond_to(:call!)
    end

    it "call! returns Result with exposed values" do
      result = async_action.call!(profile: "test", channel: "general")
      expect(result).to be_a(Axn::Result)
      expect(result).to be_ok
      expect(result.thread_ts).to eq("12345.67890")
    end

    it "call! raises exception on failure" do
      failing_action = Class.new do
        include Axn

        def call
          fail! "Something went wrong"
        end
      end

      expect { failing_action.call! }.to raise_error(Axn::Failure, "Something went wrong")
    end
  end

  describe "ContractViolation::PreprocessingError" do
    it "exists and is a ContractViolation" do
      expect(Axn::ContractViolation::PreprocessingError).to be < Axn::ContractViolation
    end

    it "preserves cause when raised in preprocess" do
      action = Class.new do
        include Axn
        expects :value, type: String, preprocess: lambda { |v|
          raise ArgumentError, "Bad value" if v == "bad"

          v
        }

        def call; end
      end

      result = action.call(value: "bad")
      expect(result.exception).to be_a(Axn::ContractViolation::PreprocessingError)
      expect(result.exception.cause).to be_a(ArgumentError)
      expect(result.exception.cause.message).to eq("Bad value")
    end
  end

  describe "Axn.configure with on_exception" do
    around do |example|
      original = Axn.config.instance_variable_get(:@on_exception)
      example.run
    ensure
      Axn.config.on_exception = original
    end

    it "allows setting on_exception proc via configure block" do
      captured = nil

      Axn.configure do |c|
        c.on_exception = proc do |e, action:, context:|
          captured = { exception: e, action:, context: }
        end
      end

      failing_action = Class.new do
        include Axn
        expects :value, type: String

        def call
          raise StandardError, "Test exception"
        end
      end

      failing_action.call(value: "test")

      expect(captured).not_to be_nil
      expect(captured[:exception]).to be_a(StandardError)
      expect(captured[:exception].message).to eq("Test exception")
      expect(captured[:context]).to be_a(Hash)
    end
  end

  describe "Async adapter configuration" do
    it "supports async :disabled (or false) to disable async" do
      action = Class.new do
        include Axn
        async false

        def call; end
      end

      expect { action.call_async }.to raise_error(NotImplementedError, /Async execution is explicitly disabled/)
    end
  end
end
