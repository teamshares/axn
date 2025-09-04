# frozen_string_literal: true

RSpec.describe Axn do
  describe ".axn" do
    let(:client) do
      build_action do
        auto_log :debug
      end
    end

    context "with existing action class" do
      let(:subaction) do
        build_action { log "in subaction" }
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
        expect(Axn.config.logger).to receive(:debug).with(/About to execute with: {expected: true, arg: 123}/).ordered
        expect(Axn.config.logger).to receive(:info).with(/got expected=true, arg=123/).ordered
        expect(Axn.config.logger).to receive(:debug).with(/Execution completed \(with outcome: success\)/).ordered
        expect(client.foo(expected: true, arg: 123)).to be_ok
      end

      context "with kwargs with defaults" do
        let(:subaction) do
          ->(expected:, arg: "abc") {}
        end

        it "fails to attach" do
          expect(client).not_to respond_to(:foo)
          expect { client.axn(:foo, &subaction) }.to raise_error(ArgumentError, /block expects keyword arguments with defaults/)
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
        client.axn(:foo, exposes: :resp, &subaction)
      end

      let(:client) do
        build_action do
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
  end
end
