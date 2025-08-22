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
      expect(axn < Action).to eq(true)
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

    let(:kwargs) { { error: Action::Core::Flow::Handlers::Descriptors::MessageDescriptor.build(handler: "overridden msg", if: -> { true }) } }

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
          success: Action::Core::Flow::Handlers::Descriptors::MessageDescriptor.build(handler: "Success!", prefix: "user"),
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
            Action::Core::Flow::Handlers::Descriptors::MessageDescriptor.build(handler: "Conditional success", if: -> { false }),
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
          on_success: Action::Core::Flow::Handlers::Descriptors::CallbackDescriptor.build(handler: -> { puts "conditional success" }, if: -> { false }),
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
            Action::Core::Flow::Handlers::Descriptors::CallbackDescriptor.build(handler: -> { puts "conditional success" }, if: -> { false }),
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
      end.to raise_error(Action::UnsupportedArgument, /Cannot pass hash directly to success/)
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
      Action::Strategies.register(:test_strategy, test_strategy)
    end

    after do
      # Clean up the strategy registry
      Action::Strategies.clear!
    end

    context "with simple strategy name" do
      let(:kwargs) { { use: :test_strategy } }

      it "includes the strategy" do
        expect(axn.call).to be_ok
        # Verify the strategy was used
        expect(axn.new).to respond_to(:test_method)
        expect(axn.new.test_method).to eq("strategy loaded")
      end
    end

    context "with multiple strategies" do
      let(:kwargs) { { use: [:test_strategy] } }

      it "includes all strategies" do
        expect(axn.call).to be_ok
        expect(axn.new).to respond_to(:test_method)
      end
    end

    context "with strategy array without config" do
      let(:kwargs) { { use: [:test_strategy] } }

      it "includes the strategy without configuration" do
        expect(axn.call).to be_ok
        expect(axn.new).to respond_to(:test_method)
      end
    end
  end
end

RSpec.describe Axn::Factory do
  let(:builder) { -> { Axn::Factory.build(**kwargs, &callable) } }
  let(:kwargs) { {} }

  it_behaves_like "can build Axns from callables"
end

RSpec.describe "Axn()" do
  let(:builder) { -> { Axn(callable, **kwargs) } }
  let(:kwargs) { {} }

  it_behaves_like "can build Axns from callables"

  context "when already Axn" do
    subject(:axn) { builder.call }
    let(:callable) { build_action { log "in action" } }

    it "returns the Axn" do
      expect(Axn::Factory).not_to receive(:build)

      expect(callable < Action).to eq(true)
      expect(axn < Action).to eq(true)
      expect(axn.call).to be_ok
    end
  end
end
