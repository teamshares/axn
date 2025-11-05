# frozen_string_literal: true

RSpec.shared_examples "can build Axns from callables" do
  subject(:axn) { builder.call }

  context "basic building" do
    let(:callable) do
      ->(arg:, expected:) { log "got expected=#{expected}, arg=#{arg}" }
    end

    it "builds an Axn from a callable" do
      expect(Axn::Factory).to receive(:build).and_call_original
      expect(callable).to be_a(Proc)
      expect(axn < Axn).to eq(true)
      expect(axn.call(expected: true, arg: 123)).to be_ok
      expect(axn.call).not_to be_ok
    end
  end

  context "setting expose_return_as" do
    let(:kwargs) { { expose_return_as: :value } }

    let(:callable) do
      -> { 123 }
    end

    it "works correctly" do
      expect(axn.call).to be_ok
      expect(axn.call.value).to eq(123)
    end
  end

  context "setting messages, expects, exposes" do
    let(:kwargs) do
      {
        success: "success",
        error: "error",
        exposes: [:num],
        expects: :arg,
      }
    end

    let(:callable) do
      -> { expose :num, arg * 10 }
    end

    it "works correctly" do
      expect(axn.call).not_to be_ok
      expect(axn.call.error).to eq("error")

      expect(axn.call(arg: 1)).to be_ok
      expect(axn.call(arg: 1).success).to eq("success")
      expect(axn.call(arg: 1).num).to eq(10)
    end

    context "with a semi-complex expects" do
      let(:kwargs) do
        {
          expects: { arg: { type: Numeric, numericality: { greater_than: 1 } } },
          exposes: [:num],
        }
      end

      it "works correctly" do
        expect(axn.call(bar: 1, arg: 1)).not_to be_ok
        expect(axn.call(bar: 1, arg: 2)).to be_ok
      end
    end

    context "with a complex expects" do
      let(:kwargs) do
        {
          expects: [:bar, { arg: { type: Numeric, numericality: { greater_than: 1 } } }],
          exposes: [:num],
        }
      end

      it "works correctly" do
        expect(axn.call(bar: 1, arg: 1)).not_to be_ok
        expect(axn.call(bar: 1, arg: 2)).to be_ok
      end
    end
  end

  context "setting before, after, around hooks" do
    let(:before) { -> { puts "before" } }
    let(:after) { -> { puts "after" } }
    let(:around) do
      lambda { |block|
        puts "<<"
        block.call
        puts ">>"
      }
    end

    let(:callable) do
      -> { puts "call" }
    end

    let(:kwargs) do
      { before:, after:, around: }
    end

    context "when ok?" do
      let(:expected) do
        %w[<< before call after >>].join("\n") + "\n" # rubocop:disable Style/StringConcatenation
      end

      it "executes hooks in order" do
        expect do
          expect(axn.call).to be_ok
        end.to output(expected).to_stdout
      end
    end

    context "when not ok?" do
      let(:expected) do
        %w[<< before call].join("\n") + "\n" # rubocop:disable Style/StringConcatenation
      end

      let(:callable) do
        lambda {
          puts "call"
          raise "bad"
        }
      end

      it "executes hooks in order" do
        expect do
          expect(axn.call).not_to be_ok
        end.to output(expected).to_stdout
      end
    end
  end

  context "setting conditional error" do
    let(:callable) do
      -> { raise "error" }
    end

    let(:kwargs) { { error: Axn::Core::Flow::Handlers::Descriptors::MessageDescriptor.build(handler: "overridden msg", if: -> { true }) } }

    it "works correctly" do
      expect(axn.call.error).to eq("overridden msg")
    end
  end

  context "setting handlers with descriptors" do
    let(:callable) do
      -> { raise "error" }
    end

    context "with success descriptor" do
      let(:kwargs) do
        {
          success: Axn::Core::Flow::Handlers::Descriptors::MessageDescriptor.build(handler: "Success!", prefix: "user"),
          error: "Default error",
        }
      end

      it "works correctly" do
        expect(axn.call.error).to eq("Default error")
      end
    end

    context "with array of handlers" do
      let(:callable) { -> { puts "call" } }
      let(:kwargs) do
        {
          success: [
            "Simple success",
            Axn::Core::Flow::Handlers::Descriptors::MessageDescriptor.build(handler: "Conditional success", if: -> { false }),
          ],
        }
      end

      it "works correctly" do
        expect do
          result = axn.call
          expect(result).to be_ok
          expect(result.success).to eq("Simple success")
        end.to output("call\n").to_stdout
      end
    end

    context "with callback descriptors" do
      let(:kwargs) do
        {
          on_success: Axn::Core::Flow::Handlers::Descriptors::CallbackDescriptor.build(handler: -> { puts "conditional success" }, if: -> { false }),
          on_error: -> { puts "error callback" },
        }
      end

      it "works correctly" do
        expect do
          expect(axn.call).not_to be_ok
        end.to output("error callback\n").to_stdout
      end
    end

    context "with array of callbacks" do
      let(:kwargs) do
        {
          on_success: [
            -> { puts "simple success" },
            Axn::Core::Flow::Handlers::Descriptors::CallbackDescriptor.build(handler: -> { puts "conditional success" }, if: -> { false }),
          ],
        }
      end

      let(:callable) { -> { puts "call" } }

      it "works correctly" do
        expect do
          expect(axn.call).to be_ok
        end.to output("call\nsimple success\n").to_stdout
      end
    end
  end

  context "error handling" do
    let(:callable) { -> { puts "call" } }

    it "raises error when passing hash directly" do
      expect do
        Axn::Factory.build(success: { message: "test", prefix: "user" }, &callable)
      end.to raise_error(Axn::UnsupportedArgument, /Cannot pass hash directly to success/)
    end
  end

  context "setting callbacks" do
    let(:on_success) { -> { puts "on_success" } }
    let(:on_failure) { ->(_exception) { puts "on_failure" } }
    let(:on_error) { ->(_exception) { puts "on_error" } }
    let(:on_exception) { ->(_exception) { puts "on_exception" } }

    let(:kwargs) do
      { on_success:, on_failure:, on_error:, on_exception: }
    end

    context "when success" do
      let(:callable) { -> { puts "call" } }

      it "executes on_success callback" do
        expect do
          expect(axn.call).to be_ok
        end.to output("call\non_success\n").to_stdout
      end
    end

    context "when failure via fail!" do
      let(:callable) { -> { fail! "test failure" } }

      it "executes on_failure and on_error callbacks" do
        expect do
          expect(axn.call).not_to be_ok
        end.to output("on_error\non_failure\n").to_stdout
      end
    end

    context "when exception raised" do
      let(:callable) { -> { raise "test exception" } }

      it "executes on_exception and on_error callbacks" do
        expect do
          expect(axn.call).not_to be_ok
        end.to output("on_error\non_exception\n").to_stdout
      end
    end
  end

  context "setting use strategies" do
    let(:callable) { -> { puts "call" } }

    before do
      # Create a test strategy
      test_strategy = Module.new do
        def self.included(base)
          base.class_eval do
            def test_method
              "strategy loaded"
            end
          end
        end
      end

      # Register it with the strategy system
      Axn::Strategies.register(:test_strategy, test_strategy)
    end

    after do
      # Clean up the strategy registry
      Axn::Strategies.clear!
    end

    context "with simple strategy name" do
      let(:kwargs) { { use: :test_strategy } }

      it "includes the strategy" do
        expect(axn.call).to be_ok
        # Verify the strategy was used
        expect(axn.send(:new)).to respond_to(:test_method)
        expect(axn.send(:new).test_method).to eq("strategy loaded")
      end
    end

    context "with multiple strategies" do
      let(:kwargs) { { use: [:test_strategy] } }

      it "includes all strategies" do
        expect(axn.call).to be_ok
        expect(axn.send(:new)).to respond_to(:test_method)
      end
    end

    context "with strategy array without config" do
      let(:kwargs) { { use: [:test_strategy] } }

      it "includes the strategy without configuration" do
        expect(axn.call).to be_ok
        expect(axn.send(:new)).to respond_to(:test_method)
      end
    end
  end

  context "setting async configuration" do
    let(:callable) { -> { puts "call" } }

    context "with async false" do
      let(:kwargs) { { async: false } }

      it "configures async as disabled" do
        expect(axn.call).to be_ok
        expect(axn.ancestors).to include(Axn::Async::Adapters::Disabled)
        expect(axn).to respond_to(:call_async)
      end

      it "raises NotImplementedError when calling call_async" do
        expect do
          axn.call_async(foo: "bar")
        end.to raise_error(NotImplementedError, /Async execution is explicitly disabled/)
      end
    end

    context "with async adapter name" do
      let(:kwargs) { { async: :sidekiq } }

      before do
        # Mock Sidekiq adapter
        sidekiq_adapter = Module.new do
          def self.included(base)
            base.class_eval do
              def self.perform_async(*args)
                # Mock implementation
              end
            end
          end
        end

        stub_const("Axn::Async::Adapters::Sidekiq", sidekiq_adapter)
        allow(Axn::Async::Adapters).to receive(:find).with(:sidekiq).and_return(sidekiq_adapter)
      end

      it "configures async with the specified adapter" do
        expect(axn.call).to be_ok
        expect(axn.ancestors).to include(Axn::Async::Adapters::Sidekiq)
        expect(axn).to respond_to(:call_async)
      end
    end

    context "with async adapter and configuration" do
      let(:kwargs) { { async: [:sidekiq, { queue: "high_priority", retry: 5 }] } }

      before do
        # Mock Sidekiq adapter
        sidekiq_adapter = Module.new do
          def self.included(base)
            base.class_eval do
              def self.perform_async(*args)
                # Mock implementation
              end
            end
          end
        end

        stub_const("Axn::Async::Adapters::Sidekiq", sidekiq_adapter)
        allow(Axn::Async::Adapters).to receive(:find).with(:sidekiq).and_return(sidekiq_adapter)
      end

      it "configures async with adapter and options" do
        expect(axn.call).to be_ok
        expect(axn.ancestors).to include(Axn::Async::Adapters::Sidekiq)
        expect(axn).to respond_to(:call_async)
        # Verify the configuration was applied
        expect(axn._async_adapter).to eq(:sidekiq)
        expect(axn._async_config).to eq({ queue: "high_priority", retry: 5 })
      end
    end

    context "with async nil (default)" do
      let(:kwargs) { {} }

      it "does not configure async" do
        expect(axn.call).to be_ok
        expect(axn._async_adapter).to be_nil
        expect(axn._async_config).to be_nil
        expect(axn._async_config_block).to be_nil
      end
    end

    context "with async callable configuration" do
      let(:callable) { -> { puts "call" } }

      before do
        # Mock Sidekiq adapter
        sidekiq_adapter = Module.new do
          def self.included(base)
            base.class_eval do
              def self.perform_async(*args)
                # Mock implementation
              end
            end
          end
        end

        stub_const("Axn::Async::Adapters::Sidekiq", sidekiq_adapter)
        allow(Axn::Async::Adapters).to receive(:find).with(:sidekiq).and_return(sidekiq_adapter)
      end

      context "with adapter and callable" do
        let(:kwargs) { { async: [:sidekiq, -> { sidekiq_options queue: "high_priority" }] } }

        it "configures async with callable" do
          expect(axn.call).to be_ok
          expect(axn.ancestors).to include(Axn::Async::Adapters::Sidekiq)
          expect(axn).to respond_to(:call_async)
          expect(axn._async_adapter).to eq(:sidekiq)
          expect(axn._async_config_block).to be_a(Proc)
        end
      end

      context "with adapter, hash, and callable" do
        let(:kwargs) { { async: [:sidekiq, { queue: "high" }, -> { retry_on StandardError }] } }

        it "configures async with hash and callable" do
          expect(axn.call).to be_ok
          expect(axn.ancestors).to include(Axn::Async::Adapters::Sidekiq)
          expect(axn).to respond_to(:call_async)
          expect(axn._async_adapter).to eq(:sidekiq)
          expect(axn._async_config).to eq({ queue: "high" })
          expect(axn._async_config_block).to be_a(Proc)
        end
      end
    end

    context "with invalid async configuration" do
      let(:callable) { -> { puts "call" } }

      it "raises ArgumentError for invalid patterns" do
        expect do
          Axn::Factory.build(callable, async: [:sidekiq, "invalid"])
        end.to raise_error(ArgumentError, /Invalid async configuration/)

        expect do
          Axn::Factory.build(callable, async: [:sidekiq, { queue: "high" }, "invalid"])
        end.to raise_error(ArgumentError, /Invalid async configuration/)

        expect do
          Axn::Factory.build(callable, async: [])
        end.to raise_error(ArgumentError, /Invalid async configuration/)

        expect do
          Axn::Factory.build(callable, async: [:sidekiq, { queue: "high" }, -> { config }, "extra"])
        end.to raise_error(ArgumentError, /Invalid async configuration/)
      end
    end

    context "with Array() conversion" do
      let(:callable) { -> { puts "call" } }

      before do
        # Mock Sidekiq adapter
        sidekiq_adapter = Module.new do
          def self.included(base)
            base.class_eval do
              def self.perform_async(*args)
                # Mock implementation
              end
            end
          end
        end

        stub_const("Axn::Async::Adapters::Sidekiq", sidekiq_adapter)
        allow(Axn::Async::Adapters).to receive(:find).with(:sidekiq).and_return(sidekiq_adapter)
      end

      it "converts single values to arrays" do
        # These should all work the same way
        %i[sidekiq sidekiq].each do |async_config|
          axn = Axn::Factory.build(callable, async: async_config)
          expect(axn.call).to be_ok
          expect(axn._async_adapter).to eq(:sidekiq)
        end
      end

      it "handles nil adapter (skips async configuration)" do
        axn = Axn::Factory.build(callable, async: nil)
        expect(axn.call).to be_ok
        expect(axn._async_adapter).to be_nil
        expect(axn._async_config).to be_nil
        expect(axn._async_config_block).to be_nil
      end

      it "handles nil adapter in array (skips async configuration)" do
        axn = Axn::Factory.build(callable, async: [nil])
        expect(axn.call).to be_ok
        expect(axn._async_adapter).to be_nil
        expect(axn._async_config).to be_nil
        expect(axn._async_config_block).to be_nil
      end
    end
  end

  context "with optional: true parameters" do
    let(:kwargs) do
      {
        expects: { name: { type: String }, email: { type: String, optional: true } },
        exposes: { greeting: { type: String } },
      }
    end

    let(:callable) do
      ->(name:, email:) { expose greeting: "Hello #{name}" } # rubocop:disable Lint/UnusedBlockArgument
    end

    it "allows missing optional fields" do
      result = axn.call(name: "John")
      expect(result).to be_ok
      expect(result.greeting).to eq("Hello John")
    end

    it "allows present optional fields" do
      result = axn.call(name: "Jane", email: "jane@example.com")
      expect(result).to be_ok
      expect(result.greeting).to eq("Hello Jane")
    end

    it "fails when required fields are missing" do
      result = axn.call(email: "test@example.com")
      expect(result).not_to be_ok
      expect(result.error).to eq("Something went wrong")
    end
  end
end

RSpec.describe Axn::Factory do
  context "with proc/lambda as positional argument" do
    let(:callable) do
      ->(arg:, expected:) { log "got expected=#{expected}, arg=#{arg}" }
    end

    it "builds an Axn from a proc" do
      axn = Axn::Factory.build(callable, expects: %i[arg expected])
      expect(axn < Axn).to eq(true)
      expect(axn.call(expected: true, arg: 123)).to be_ok
      expect(axn.call).not_to be_ok
    end

    it "builds an Axn from a lambda" do
      lambda_callable = ->(arg:, expected:) { log "got expected=#{expected}, arg=#{arg}" }
      axn = Axn::Factory.build(lambda_callable, expects: %i[arg expected])
      expect(axn < Axn).to eq(true)
      expect(axn.call(expected: true, arg: 123)).to be_ok
    end

    it "works with expose_return_as" do
      axn = Axn::Factory.build(-> { 123 }, expose_return_as: :value)
      expect(axn.call).to be_ok
      expect(axn.call.value).to eq(123)
    end

    it "works with expects and exposes" do
      axn = Axn::Factory.build(
        -> { expose :num, arg * 10 },
        expects: :arg,
        exposes: [:num],
        success: "success",
        error: "error",
      )

      expect(axn.call).not_to be_ok
      expect(axn.call.error).to eq("error")

      expect(axn.call(arg: 1)).to be_ok
      expect(axn.call(arg: 1).success).to eq("success")
      expect(axn.call(arg: 1).num).to eq(10)
    end

    it "raises error when neither callable nor block provided" do
      expect do
        Axn::Factory.build
      end.to raise_error(ArgumentError, /Must provide either a callable or a block/)
    end

    it "raises error when both callable and block provided" do
      callable = -> { "from callable" }
      block = -> { "from block" }

      expect do
        Axn::Factory.build(callable, expose_return_as: :value, &block)
      end.to raise_error(ArgumentError, /Cannot receive both a callable and a block/)
    end

    it "works with async configuration" do
      callable = -> { puts "call" }

      # Mock Sidekiq adapter
      sidekiq_adapter = Module.new do
        def self.included(base)
          base.class_eval do
            def self.perform_async(*args)
              # Mock implementation
            end
          end
        end
      end

      stub_const("Axn::Async::Adapters::Sidekiq", sidekiq_adapter)
      allow(Axn::Async::Adapters).to receive(:find).with(:sidekiq).and_return(sidekiq_adapter)

      axn = Axn::Factory.build(callable, async: :sidekiq)
      expect(axn.call).to be_ok
      expect(axn.ancestors).to include(Axn::Async::Adapters::Sidekiq)
      expect(axn).to respond_to(:call_async)
    end
  end

  let(:builder) { -> { Axn::Factory.build(**kwargs, &callable) } }
  let(:kwargs) { {} }

  it_behaves_like "can build Axns from callables"
end
