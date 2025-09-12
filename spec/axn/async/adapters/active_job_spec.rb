# frozen_string_literal: true

require_relative "../../../support/shared_examples/async_adapter_interface"

RSpec.describe "Axn::Async with ActiveJob adapter" do
  let(:active_job_base) { Class.new }

  let(:action_class) do
    stub_const("ActiveJob", Module.new)
    stub_const("ActiveJob::Base", active_job_base)

    build_axn do
      async :active_job
      expects :name, :age
    end
  end

  it_behaves_like "an async adapter interface", :active_job, Axn::Async::Adapters::ActiveJob

  describe ".call_async" do
    it "calls perform_later on the proxy class with context" do
      expect_any_instance_of(Class).to receive(:perform_later).with(name: "World", age: 25)
      action_class.call_async(name: "World", age: 25)
    end

    it "handles empty context" do
      expect_any_instance_of(Class).to receive(:perform_later).with({})
      action_class.call_async({})
    end

    it "handles nil context" do
      expect_any_instance_of(Class).to receive(:perform_later).with({})
      action_class.call_async(nil)
    end
  end

  describe "ActiveJob-specific behavior" do
    it "does not include any ActiveJob modules directly" do
      expect(action_class.ancestors).not_to include(ActiveJob::Base)
    end

    it "does not provide perform method on action instances" do
      action = action_class.new(name: "Test", age: 30)
      expect(action).not_to respond_to(:perform)
    end

    it "calls perform_later on the proxy class with context" do
      expect_any_instance_of(Class).to receive(:perform_later).with(name: "World", age: 25)
      action_class.call_async(name: "World", age: 25)
    end

    describe "proxy class behavior" do
      let(:proxy_class) { action_class.send(:active_job_proxy_class) }

      it "creates a proxy class that inherits from ActiveJob::Base" do
        expect(proxy_class.superclass).to eq(ActiveJob::Base)
      end

      it "gives the proxy class a meaningful name" do
        expect(proxy_class.name).to include("ActiveJobProxy")
      end

      it "defines a perform method on the proxy class" do
        expect(proxy_class.instance_methods).to include(:perform)
      end

      it "memoizes the proxy class" do
        first_proxy = action_class.send(:active_job_proxy_class)
        second_proxy = action_class.send(:active_job_proxy_class)
        expect(first_proxy).to be(second_proxy)
      end
    end
  end
end
