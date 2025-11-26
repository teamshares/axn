# frozen_string_literal: true

RSpec.describe Axn::Util::Callable do
  describe ".call_with_desired_shape" do
    context "when callable accepts specific keyword arguments" do
      let(:callable) do
        proc do |resource:, result:|
          { resource:, result: }
        end
      end

      it "calls with only the expected keyword arguments" do
        result = double("result")
        kwargs = { resource: "Action", result: result, extra: "ignored" }
        returned = described_class.call_with_desired_shape(callable, kwargs: kwargs)
        expect(returned).to eq({ resource: "Action", result: result })
        expect(returned).not_to have_key(:extra)
      end
    end

    context "when callable only accepts resource:" do
      let(:callable) do
        proc do |resource:|
          { resource: }
        end
      end

      it "calls with only resource:" do
        kwargs = { resource: "Action", result: double("result") }
        returned = described_class.call_with_desired_shape(callable, kwargs: kwargs)
        expect(returned).to eq({ resource: "Action" })
        expect(returned).not_to have_key(:result)
      end
    end

    context "when callable only accepts result:" do
      let(:callable) do
        proc do |result:|
          { result: }
        end
      end

      it "calls with only result:" do
        result = double("result")
        kwargs = { resource: "Action", result: result }
        returned = described_class.call_with_desired_shape(callable, kwargs: kwargs)
        expect(returned).to eq({ result: result })
        expect(returned).not_to have_key(:resource)
      end
    end

    context "when callable accepts **kwargs" do
      let(:callable) do
        proc do |**kwargs|
          kwargs
        end
      end

      it "calls with all provided keyword arguments" do
        kwargs = { resource: "Action", result: double("result"), extra: "value" }
        returned = described_class.call_with_desired_shape(callable, kwargs: kwargs)
        expect(returned).to eq(kwargs)
      end
    end

    context "when callable accepts optional keyword arguments" do
      let(:callable) do
        proc do |resource:, result: nil|
          { resource:, result: }
        end
      end

      it "calls with both required and optional keyword arguments" do
        result = double("result")
        kwargs = { resource: "Action", result: result, extra: "ignored" }
        returned = described_class.call_with_desired_shape(callable, kwargs: kwargs)
        expect(returned).to eq({ resource: "Action", result: result })
        expect(returned).not_to have_key(:extra)
      end
    end

    context "when callable does not respond to parameters" do
      let(:callable) do
        double("callable").tap do |d|
          allow(d).to receive(:call).and_return({ called: true })
        end
      end

      it "calls with all provided keyword arguments" do
        kwargs = { resource: "Action", result: double("result") }
        described_class.call_with_desired_shape(callable, kwargs: kwargs)
        expect(callable).to have_received(:call).with(**kwargs)
      end
    end

    context "when callable accepts no keyword arguments" do
      let(:callable) do
        proc do
          { called: true }
        end
      end

      it "calls without keyword arguments" do
        kwargs = { resource: "Action", result: double("result") }
        returned = described_class.call_with_desired_shape(callable, kwargs: kwargs)
        expect(returned).to eq({ called: true })
      end
    end

    context "when callable accepts positional arguments" do
      let(:callable) do
        proc do |a, b, c:|
          { a:, b:, c: }
        end
      end

      it "calls with only the expected number of positional args" do
        args = [1, 2, 3, 4]
        kwargs = { c: 5, d: 6 }
        returned = described_class.call_with_desired_shape(callable, args: args, kwargs: kwargs)
        expect(returned).to eq({ a: 1, b: 2, c: 5 })
      end
    end

    context "when callable accepts required and optional positional arguments" do
      let(:callable) do
        proc do |a, b = "default", c:|
          { a:, b:, c: }
        end
      end

      it "calls with up to required + optional positional args" do
        args = [1, 2, 3, 4]
        kwargs = { c: 5 }
        returned = described_class.call_with_desired_shape(callable, args: args, kwargs: kwargs)
        expect(returned).to eq({ a: 1, b: 2, c: 5 })
      end
    end

    context "when callable accepts *args" do
      let(:callable) do
        proc do |*args, c:|
          { args:, c: }
        end
      end

      it "calls with all provided positional args" do
        args = [1, 2, 3, 4]
        kwargs = { c: 5 }
        returned = described_class.call_with_desired_shape(callable, args: args, kwargs: kwargs)
        expect(returned).to eq({ args: [1, 2, 3, 4], c: 5 })
      end
    end

    context "when callable accepts only positional arguments" do
      let(:callable) do
        proc do |a, b|
          { a:, b: }
        end
      end

      it "calls with only positional args, ignoring extra" do
        args = [1, 2, 3, 4]
        returned = described_class.call_with_desired_shape(callable, args: args)
        expect(returned).to eq({ a: 1, b: 2 })
      end
    end
  end
end

