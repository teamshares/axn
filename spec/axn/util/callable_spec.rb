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
        kwargs = { resource: "Action", result:, extra: "ignored" }
        returned = described_class.call_with_desired_shape(callable, kwargs:)
        expect(returned).to eq({ resource: "Action", result: })
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
        returned = described_class.call_with_desired_shape(callable, kwargs:)
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
        kwargs = { resource: "Action", result: }
        returned = described_class.call_with_desired_shape(callable, kwargs:)
        expect(returned).to eq({ result: })
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
        returned = described_class.call_with_desired_shape(callable, kwargs:)
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
        kwargs = { resource: "Action", result:, extra: "ignored" }
        returned = described_class.call_with_desired_shape(callable, kwargs:)
        expect(returned).to eq({ resource: "Action", result: })
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
        described_class.call_with_desired_shape(callable, kwargs:)
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
        returned = described_class.call_with_desired_shape(callable, kwargs:)
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
        returned = described_class.call_with_desired_shape(callable, args:, kwargs:)
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
        returned = described_class.call_with_desired_shape(callable, args:, kwargs:)
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
        returned = described_class.call_with_desired_shape(callable, args:, kwargs:)
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
        returned = described_class.call_with_desired_shape(callable, args:)
        expect(returned).to eq({ a: 1, b: 2 })
      end
    end
  end

  describe ".only_requested_params" do
    context "when callable accepts specific keyword arguments" do
      let(:callable) { proc { |resource:, result:| } }

      it "returns filtered args and kwargs without calling" do
        kwargs = { resource: "Action", result: double("result"), extra: "ignored" }
        filtered_args, filtered_kwargs = described_class.only_requested_params(callable, kwargs:)
        expect(filtered_args).to eq([])
        expect(filtered_kwargs.keys).to eq(%i[resource result])
        expect(filtered_kwargs).not_to have_key(:extra)
      end
    end

    context "when callable accepts positional and keyword arguments" do
      let(:callable) { proc { |a, b, c:| } }

      it "returns filtered args and kwargs" do
        args = [1, 2, 3, 4]
        kwargs = { c: 5, d: 6 }
        filtered_args, filtered_kwargs = described_class.only_requested_params(callable, args:, kwargs:)
        expect(filtered_args).to eq([1, 2])
        expect(filtered_kwargs).to eq({ c: 5 })
      end
    end

    context "when callable accepts **kwargs" do
      let(:callable) { proc { |**kwargs| } }

      it "returns all provided kwargs" do
        kwargs = { resource: "Action", result: double("result"), extra: "value" }
        _, filtered_kwargs = described_class.only_requested_params(callable, kwargs:)
        expect(filtered_kwargs).to eq(kwargs)
      end
    end
  end

  describe ".only_requested_params_for_exception" do
    context "when exception is nil" do
      let(:callable) { proc { |exception:| } }

      it "returns empty args and kwargs" do
        filtered_args, filtered_kwargs = described_class.only_requested_params_for_exception(callable, nil)
        expect(filtered_args).to eq([])
        expect(filtered_kwargs).to eq({})
      end
    end

    context "when callable accepts exception as keyword argument" do
      let(:callable) { proc { |exception:| } }
      let(:exception) { RuntimeError.new("test error") }

      it "returns exception as keyword argument" do
        filtered_args, filtered_kwargs = described_class.only_requested_params_for_exception(callable, exception)
        expect(filtered_args).to eq([])
        expect(filtered_kwargs).to eq({ exception: })
      end
    end

    context "when callable accepts exception as positional argument" do
      let(:callable) { proc { |exception| } }
      let(:exception) { RuntimeError.new("test error") }

      it "returns exception as positional argument" do
        filtered_args, filtered_kwargs = described_class.only_requested_params_for_exception(callable, exception)
        expect(filtered_args).to eq([exception])
        expect(filtered_kwargs).to eq({})
      end
    end

    context "when callable accepts **kwargs" do
      let(:callable) { proc { |**kwargs| } }
      let(:exception) { RuntimeError.new("test error") }

      it "returns exception as keyword argument only (no positional args accepted)" do
        filtered_args, filtered_kwargs = described_class.only_requested_params_for_exception(callable, exception)
        expect(filtered_args).to eq([])
        expect(filtered_kwargs).to eq({ exception: })
      end
    end

    context "when callable accepts *args and **kwargs" do
      let(:callable) { proc { |*args, **kwargs| } }
      let(:exception) { RuntimeError.new("test error") }

      it "returns exception as both positional and keyword" do
        filtered_args, filtered_kwargs = described_class.only_requested_params_for_exception(callable, exception)
        expect(filtered_args).to eq([exception])
        expect(filtered_kwargs).to eq({ exception: })
      end
    end

    context "when callable accepts no exception argument" do
      let(:callable) { proc {} }
      let(:exception) { RuntimeError.new("test error") }

      it "returns empty args and kwargs" do
        filtered_args, filtered_kwargs = described_class.only_requested_params_for_exception(callable, exception)
        expect(filtered_args).to eq([])
        expect(filtered_kwargs).to eq({})
      end
    end
  end
end
