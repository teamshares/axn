# frozen_string_literal: true

RSpec.describe Action do
  describe "subactions" do
    let(:client) do
      Class.new { include Action }
    end

    context "with existing action class" do
      let(:subaction) do
        build_action { log "in subaction" }
      end

      it "attaches subaction" do
        expect(client).not_to respond_to(:foo)
        client.action :foo, subaction
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
        client.action :foo, &subaction
        expect(client).to respond_to(:foo)

        expect(client.foo).not_to be_ok

        expect(Action.config.logger).to receive(:info).with(/got expected=true, arg=123/)
        expect(client.foo(expected: true, arg: 123)).to be_ok
      end

      context "with kwargs with defaults" do
        let(:subaction) do
          ->(expected:, arg: "abc") {}
        end

        it "fails to attach" do
          expect(client).not_to respond_to(:foo)
          expect { client.action(:foo, &subaction) }.to raise_error(ArgumentError, /block expects keyword arguments with defaults/)
        end
      end
    end

    describe "defined from block" do
      before do
        client.action(:foo, &subaction)
      end

      context "can handle default exposure" do
        let(:subaction) do
          ->(char:, length:) { char * length }
        end

        it "exposes value automatically" do
          expect(client).to respond_to(:foo)
          result = client.foo(char: "a", length: 5)
          expect(result).to be_a(Action::Result)
          expect(result.value).to eq("aaaaa")
        end
      end
    end

    describe "defined from block with custom exposures" do
      before do
        client.action(:foo, exposes: [:msg], &subaction)
      end

      let(:subaction) do
        lambda do |char:, length:|
          expose :msg, char * length
        end
      end

      it "handles explicit exposure" do
        result = client.foo(char: "a", length: 5)
        expect(result).to be_a(Action::Result)
        expect(result.msg).to eq("aaaaa")
        expect { result.value }.to raise_error(NoMethodError) # Not set if there's an explicit exposure
      end
    end

    describe "handles custom expectations" do
      before do
        client.action(:foo, expects:, &subaction)
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
  end
end
