# frozen_string_literal: true

RSpec.describe Axn do
  describe ".axn" do
    let(:client) do
      build_axn
    end

    context "with existing action class" do
      let(:subaction) do
        build_axn { log "in subaction" }
      end

      it "attaches subaction" do
        expect(client).not_to respond_to(:foo)
        client.axn :foo, subaction
        expect(client).to respond_to(:foo)

        expect_any_instance_of(subaction).to receive(:call).and_call_original
        expect(client.foo).to be_ok
      end
    end

    context "with existing with bare callable" do
      let(:subaction) do
        ->(expected:, arg:) { log "got expected=#{expected}, arg=#{arg}" }
      end

      it "attaches subaction" do
        expect(client).not_to respond_to(:foo)
        client.axn :foo, &subaction
        expect(client).to respond_to(:foo)

        expect(client.foo).not_to be_ok

        # The automatic logging will log before and after execution, so we need to expect multiple calls
        expect(Axn.config.logger).to receive(:info).with(/About to execute with: {expected: true, arg: 123}/).ordered
        expect(Axn.config.logger).to receive(:info).with(/got expected=true, arg=123/).ordered
        expect(Axn.config.logger).to receive(:info).with(/Execution completed \(with outcome: success\)/).ordered
        expect(client.foo(expected: true, arg: 123)).to be_ok
      end

      context "with kwargs with defaults" do
        let(:subaction) do
          ->(expected:, arg: "abc") {}
        end

        it "fails to attach" do
          expect(client).not_to respond_to(:foo)
          expect { client.axn(:foo, &subaction) }.to raise_error(ArgumentError, /callable expects keyword arguments with defaults/)
        end
      end
    end

    describe "defined from block with default return" do
      before do
        client.axn(:foo, expose_return_as: :barfoo, &subaction)
      end

      context "can handle default exposure" do
        let(:subaction) do
          ->(char:, length:) { char * length }
        end

        it "exposes automatically" do
          expect(client).to respond_to(:foo)
          result = client.foo(char: "a", length: 5)
          expect(result).to be_a(Axn::Result)
          expect(result.barfoo).to eq("aaaaa")
        end
      end

      context "can handle early return via next" do
        let(:subaction) do
          lambda do |char:, length:|
            next "it's an A" if char == "a"

            char * length
          end
        end

        it "exposes automatically" do
          result = client.foo(char: "a", length: 5)
          expect(result.barfoo).to eq("it's an A")
        end
      end
    end

    describe "defined from block with custom exposures" do
      before do
        client.axn(:foo, exposes: [:msg], &subaction)
      end

      let(:subaction) do
        lambda do |char:, length:|
          expose :msg, char * length
        end
      end

      it "handles explicit exposure" do
        result = client.foo(char: "a", length: 5)
        expect(result).to be_a(Axn::Result)
        expect(result.msg).to eq("aaaaa")
        expect { result.value }.to raise_error(NoMethodError) # Not set if there's an explicit exposure
      end
    end

    describe "handles custom expectations" do
      before do
        client.axn(:foo, expects:, &subaction)
      end

      let(:expects) { [:name] }
      let(:subaction) do
        lambda do |name:|
          log "Hello #{name}"
        end
      end

      it "handles explicit exposure" do
        expect(client.foo(name: "name")).to be_ok
        expect(client.foo(name: 123)).to be_ok
        expect(client.foo).not_to be_ok
      end

      context "with custom validations" do
        let(:expects) do
          { name: { type: String } }
        end

        it "handles explicit exposure" do
          expect(client.foo(name: "name")).to be_ok
          expect(client.foo(name: 123)).not_to be_ok
        end
      end
    end

    context "with Client class customization" do
      before do
        # Create a superclass that provides the awesome_thing method
        awesome_class = Class.new do
          def self.awesome_thing = 123
        end

        client.axn(:foo, exposes: :resp, superclass: awesome_class, &subaction)
      end

      let(:client) do
        build_axn do
          def self.awesome_thing = 123
        end
      end

      let(:subaction) do
        lambda do
          expose :resp, "Hello #{self.class.awesome_thing}"
        end
      end

      it "inherits from Client class" do
        expect(client.foo).to be_ok
        expect(client.foo.resp).to eq("Hello 123")
      end
    end

    describe "async method generation" do
      shared_examples "creates _async method" do
        it "creates _async method" do
          expect(client).to respond_to(:foo_async)
        end
      end

      shared_examples "raises NotImplementedError by default" do |args = {}|
        it "raises NotImplementedError by default (async disabled)" do
          expect { client.foo_async(**args) }.to raise_error(NotImplementedError, /Async execution is explicitly disabled/)
        end
      end

      context "with existing action class" do
        let(:subaction) { build_axn { log "in subaction" } }

        before { client.axn :foo, subaction }

        include_examples "creates _async method"

        it "calls call_async on the subaction class" do
          allow(subaction).to receive(:call_async).with(expected: true, arg: 123)
          expect(subaction).to receive(:call_async).with(expected: true, arg: 123)
          client.foo_async(expected: true, arg: 123)
        end
      end

      context "with callable blocks" do
        context "bare callable" do
          let(:subaction) { ->(expected:, arg:) { log "got expected=#{expected}, arg=#{arg}" } }
          before { client.axn :foo, &subaction }
          include_examples "creates _async method"
          include_examples "raises NotImplementedError by default", { expected: true, arg: 123 }
        end

        context "with custom exposures" do
          let(:subaction) { ->(char:, length:) { expose :msg, char * length } }
          before { client.axn(:foo, exposes: [:msg], &subaction) }
          include_examples "creates _async method"
          include_examples "raises NotImplementedError by default", { char: "a", length: 5 }
        end

        context "with custom expectations" do
          let(:subaction) { ->(name:) { log "Hello #{name}" } }
          before { client.axn(:foo, expects: [:name], &subaction) }
          include_examples "creates _async method"
          include_examples "raises NotImplementedError by default", { name: "World" }
        end
      end

      context "async method behavior" do
        let(:subaction) { build_axn { log "in subaction" } }
        before { client.axn :foo, subaction }

        it "passes all keyword arguments to call_async and handles empty arguments" do
          allow(subaction).to receive(:call_async)

          # Test with arguments
          expect(subaction).to receive(:call_async).with(
            arg1: "value1",
            arg2: "value2",
            nested: { key: "value" },
          )
          client.foo_async(arg1: "value1", arg2: "value2", nested: { key: "value" })

          # Test with no arguments
          expect(subaction).to receive(:call_async).with(no_args)
          client.foo_async
        end

        it "raises NotImplementedError when async is disabled" do
          allow(subaction).to receive(:call_async).and_raise(NotImplementedError, "Async execution is explicitly disabled")
          expect { client.foo_async(arg: "test") }.to raise_error(NotImplementedError, "Async execution is explicitly disabled")
        end
      end
    end
  end
end
