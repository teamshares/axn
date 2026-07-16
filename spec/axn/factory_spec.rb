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
          success: Axn::Core::Flow::Handlers::Descriptors::MessageDescriptor.build(handler: "Success!"),
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

  context "setting axn_name" do
    let(:kwargs) { { axn_name: "greet_user" } }
    let(:callable) { -> {} }

    it "sets the resolved name and the provider-facing tool_name" do
      expect(axn.resolved_axn_name).to eq("greet_user")
      expect(axn.tool_name).to eq("greet_user")
    end
  end

  context "setting description" do
    let(:kwargs) { { description: "Greets the user" } }
    let(:callable) { -> {} }

    it "sets the class-level description" do
      expect(axn._axn_description).to eq("Greets the user")
    end
  end

  context "setting semantic_hints" do
    context "with a single hint" do
      let(:kwargs) { { semantic_hints: :read_only } }
      let(:callable) { -> {} }

      it "sets the hint" do
        expect(axn.semantic_hints).to eq([:read_only])
      end
    end

    context "with an array of hints" do
      let(:kwargs) { { semantic_hints: %i[read_only idempotent] } }
      let(:callable) { -> {} }

      it "sets all hints" do
        expect(axn.semantic_hints).to contain_exactly(:read_only, :idempotent)
      end
    end

    context "with an unknown hint" do
      let(:kwargs) { { semantic_hints: :bogus } }
      let(:callable) { -> {} }

      it "raises" do
        expect { axn }.to raise_error(ArgumentError, /Unknown semantic hint/)
      end
    end
  end

  context "setting fails_on" do
    context "with a single exception class" do
      let(:err_class) { Class.new(StandardError) }
      let(:kwargs) { { fails_on: err_class } }
      let(:callable) do
        boom = err_class
        -> { raise boom, "kaboom" }
      end

      it "reclassifies the exception as a failure, preserving it on the result" do
        result = axn.call
        expect(result).not_to be_ok
        expect(result.exception).to be_a(err_class)
        expect(axn._fails_on_matchers).to include(err_class)
      end
    end

    context "with a list of bare classes" do
      let(:err_a) { Class.new(StandardError) }
      let(:err_b) { Class.new(StandardError) }
      let(:kwargs) { { fails_on: [err_a, err_b] } }
      let(:callable) { -> {} }

      it "registers a matcher for each class" do
        expect(axn._fails_on_matchers).to include(err_a, err_b)
      end
    end

    context "with a tuple carrying a message and standalone:" do
      let(:err_class) { Class.new(StandardError) }
      let(:kwargs) { { fails_on: [[err_class, "custom failure", { standalone: true }]] } }
      let(:callable) do
        boom = err_class
        -> { raise boom }
      end

      it "wires the message through the reclassified error" do
        expect(axn.call.error).to eq("custom failure")
      end
    end

    context "with a nested-classes tuple sharing one message" do
      let(:err_a) { Class.new(StandardError) }
      let(:err_b) { Class.new(StandardError) }
      let(:kwargs) { { fails_on: [[[err_a, err_b], "shared failure"]] } }
      let(:callable) do
        boom = err_b
        -> { raise boom }
      end

      it "registers a single matcher over both classes with the shared message" do
        expect(axn._fails_on_matchers).to include(err_a, err_b)
        expect(axn.call.error).to eq("shared failure")
      end
    end

    context "with an overlong spec (extra positional beyond [exceptions, message])" do
      let(:err_class) { Class.new(StandardError) }
      let(:kwargs) { { fails_on: [[err_class, "retry", :extra]] } }
      let(:callable) { -> {} }

      it "raises at declaration rather than silently dropping the extra" do
        expect { axn }.to raise_error(ArgumentError, /Invalid fails_on spec/)
      end
    end

    context "when an error: reason also matches the reclassified exception" do
      let(:err_class) { Class.new(StandardError) }
      let(:kwargs) do
        {
          fails_on: [[err_class, "from fails_on", { standalone: true }]],
          error: Axn::Core::Flow::Handlers::Descriptors::MessageDescriptor.build(
            handler: "from error kwarg", if: err_class, standalone: true,
          ),
        }
      end
      let(:callable) do
        boom = err_class
        -> { raise boom }
      end

      it "lets the fails_on message win (applied after error: handlers, mirroring a hand-written class)" do
        expect(axn.call.error).to eq("from fails_on")
      end
    end
  end

  context "setting tag / dimension" do
    context "with a single tag spec" do
      let(:kwargs) { { tag: [:region, "us5"] } }
      let(:callable) { -> {} }

      it "registers the tag" do
        expect(axn._tags[:region].resolver).to eq("us5")
        expect(axn._tags[:region].from).to eq(:inputs)
      end
    end

    context "with a tag spec carrying from:" do
      let(:kwargs) { { tag: [:charged, "yes", { from: :result }] } }
      let(:callable) { -> {} }

      it "forwards from:" do
        expect(axn._tags[:charged].from).to eq(:result)
      end
    end

    context "with a list of tag specs" do
      let(:kwargs) { { tag: [[:a, 1], [:b, 2]] } }
      let(:callable) { -> {} }

      it "registers each tag" do
        expect(axn._tags.keys).to contain_exactly(:a, :b)
      end
    end

    context "with a dimension spec" do
      let(:kwargs) { { dimension: [:plan_tier, "pro"] } }
      let(:callable) { -> {} }

      it "registers the dimension separately from tags" do
        expect(axn._dimensions[:plan_tier].resolver).to eq("pro")
        expect(axn._tags).to be_empty
      end
    end

    context "with a Hash-valued literal resolver" do
      let(:kwargs) { { tag: [:payload, { kind: "a" }] } }
      let(:callable) { -> {} }

      it "forwards the Hash as the resolver, not as keyword options" do
        expect(axn._tags[:payload].resolver).to eq({ kind: "a" })
        expect(axn._tags[:payload].from).to eq(:inputs)
      end
    end

    context "with a Hash-valued resolver plus an explicit from:" do
      let(:kwargs) { { tag: [:payload, { kind: "a" }, { from: :result }] } }
      let(:callable) { -> {} }

      it "keeps the Hash resolver positional and applies from: from the kwargs Hash" do
        expect(axn._tags[:payload].resolver).to eq({ kind: "a" })
        expect(axn._tags[:payload].from).to eq(:result)
      end
    end

    context "with a from:-shaped Hash as the resolver (2-part spec)" do
      let(:kwargs) { { tag: [:payload, { from: "api" }] } }
      let(:callable) { -> {} }

      it "treats the Hash as the positional resolver, not phase options" do
        expect(axn._tags[:payload].resolver).to eq({ from: "api" })
        expect(axn._tags[:payload].from).to eq(:inputs)
      end
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

  context "description: when a superclass already defines its own #description" do
    let(:superclass) do
      Class.new do
        def self.description(*)
          "ancestor description"
        end
      end
    end

    it "stores axn's description without invoking the shadowing ancestor setter" do
      # PRO-2875: Naming skips extending axn's `description` DSL when a non-Axn ancestor
      # defines one, so calling `axn.description(value)` here would hit the ancestor. The
      # factory must write the backing attribute directly.
      axn = Axn::Factory.build(superclass:, description: "axn description") { nil }
      expect(axn._axn_description).to eq("axn description")
      expect(axn.description).to eq("ancestor description")
    end
  end

  context "description: relative to an inherited value" do
    let(:base) do
      Class.new do
        include Axn
        description "inherited description"
      end
    end

    it "keeps the inherited description when description: is omitted" do
      axn = Axn::Factory.build(superclass: base) { nil }
      expect(axn._axn_description).to eq("inherited description")
    end

    it "clears the inherited description when passed description: nil explicitly" do
      axn = Axn::Factory.build(superclass: base, description: nil) { nil }
      expect(axn._axn_description).to be_nil
    end

    it "overrides the inherited description with a new value" do
      axn = Axn::Factory.build(superclass: base, description: "override") { nil }
      expect(axn._axn_description).to eq("override")
    end
  end

  context "semantic_hints: relative to an inherited value" do
    let(:base) do
      Class.new do
        include Axn
        semantic_hints :read_only
      end
    end

    it "keeps the inherited hints when semantic_hints: is omitted" do
      axn = Axn::Factory.build(superclass: base) { nil }
      expect(axn.semantic_hints).to eq([:read_only])
    end

    it "keeps the inherited hints when semantic_hints: is explicitly nil (an unset optional, not a clear)" do
      axn = Axn::Factory.build(superclass: base, semantic_hints: nil) { nil }
      expect(axn.semantic_hints).to eq([:read_only])
    end

    it "clears the inherited hints when passed an explicit empty list" do
      axn = Axn::Factory.build(superclass: base, semantic_hints: []) { nil }
      expect(axn.semantic_hints).to eq([])
    end

    it "overrides the inherited hints with a new list (validated against the vocab)" do
      axn = Axn::Factory.build(superclass: base, semantic_hints: [:idempotent]) { nil }
      expect(axn.semantic_hints).to contain_exactly(:idempotent)
    end
  end
end
