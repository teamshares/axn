# frozen_string_literal: true

require_relative "../../../support/shared_examples/async_adapter_interface"

RSpec.describe "Axn::Async with Disabled adapter" do
  let(:action_class) do
    build_axn do
      async false
      expects :name, :age
    end
  end

  it_behaves_like "an async adapter interface", :disabled, Axn::Async::Adapters::Disabled, skip_error_handling: true

  describe "error handling" do
    it "is always available (no LoadError)" do
      expect do
        build_axn do
          async false
        end
      end.not_to raise_error
    end
  end

  describe ".call_async" do
    it "raises NotImplementedError" do
      expect { action_class.call_async(name: "Test", age: 30) }.to raise_error(NotImplementedError)
    end

    it "raises NotImplementedError with empty context" do
      expect { action_class.call_async({}) }.to raise_error(NotImplementedError)
    end

    it "raises NotImplementedError with nil context" do
      expect { action_class.call_async(nil) }.to raise_error(NotImplementedError)
    end
  end

  describe "Disabled-specific behavior" do
    it "does not include any external job modules" do
      expect(action_class.ancestors).not_to include(Sidekiq::Job) if defined?(Sidekiq::Job)
      expect(action_class.ancestors).not_to include(ActiveJob::Base) if defined?(ActiveJob::Base)
    end

    it "does not provide perform method on instances" do
      action = action_class.new(name: "Test", age: 30)
      expect(action).not_to respond_to(:perform)
    end
  end
end
