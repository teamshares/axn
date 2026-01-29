# frozen_string_literal: true

require_relative "../../../support/shared_examples/async_adapter_interface"

RSpec.describe "Axn::Async with ActiveJob adapter" do
  let(:action_class) do
    active_job_base = Class.new
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
      expect_any_instance_of(Class).to receive(:perform_later).with({ name: "World", age: 25 })
      action_class.call_async(name: "World", age: 25)
    end

    context "with delayed execution" do
      it "calls set(wait:) and perform_later when _async contains wait option" do
        proxy_instance = double("proxy")
        allow(action_class).to receive(:active_job_proxy_class).and_return(proxy_instance)
        allow(proxy_instance).to receive(:set).with(wait: 3600).and_return(proxy_instance)

        expect(proxy_instance).to receive(:perform_later).with({ name: "World", age: 25 })
        action_class.call_async(name: "World", age: 25, _async: { wait: 3600 })
      end

      it "calls set(wait_until:) and perform_later when _async contains wait_until option" do
        future_time = Time.now + 3600
        proxy_instance = double("proxy")
        allow(action_class).to receive(:active_job_proxy_class).and_return(proxy_instance)
        allow(proxy_instance).to receive(:set).with(wait_until: future_time).and_return(proxy_instance)

        expect(proxy_instance).to receive(:perform_later).with({ name: "World", age: 25 })
        action_class.call_async(name: "World", age: 25, _async: { wait_until: future_time })
      end

      it "calls perform_later when _async is not a hash" do
        expect_any_instance_of(Class).to receive(:perform_later).with({ name: "World", age: 25, _async: "user_value" })
        action_class.call_async(name: "World", age: 25, _async: "user_value")
      end

      it "calls perform_later when _async is an empty hash" do
        expect_any_instance_of(Class).to receive(:perform_later).with({ name: "World", age: 25 })
        action_class.call_async(name: "World", age: 25, _async: {})
      end
    end
  end

  describe "ActiveJob-specific behavior" do
    it "does not include any ActiveJob modules directly" do
      expect(action_class.ancestors).not_to include(ActiveJob::Base)
    end

    it "does not provide perform method on action instances" do
      action = action_class.send(:new, name: "Test", age: 30)
      expect(action).not_to respond_to(:perform)
    end

    it "calls perform_later on the proxy class with context" do
      expect_any_instance_of(Class).to receive(:perform_later).with({ name: "World", age: 25 })
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

  describe "proxy #perform exception handling" do
    let(:successful_action) do
      active_job_base = Class.new
      stub_const("ActiveJob", Module.new)
      stub_const("ActiveJob::Base", active_job_base)

      build_axn do
        async :active_job
        expects :value
        exposes :result_value

        def call
          expose result_value: value * 2
        end
      end
    end

    let(:failing_action) do
      active_job_base = Class.new
      stub_const("ActiveJob", Module.new)
      stub_const("ActiveJob::Base", active_job_base)

      build_axn do
        async :active_job
        expects :should_fail

        def call
          fail! "Business logic failure" if should_fail
        end
      end
    end

    let(:exception_action) do
      active_job_base = Class.new
      stub_const("ActiveJob", Module.new)
      stub_const("ActiveJob::Base", active_job_base)

      build_axn do
        async :active_job

        def call
          raise "Unexpected error"
        end
      end
    end

    it "returns result on success" do
      proxy = successful_action.send(:active_job_proxy_class).new
      result = proxy.perform({ value: 5 })

      expect(result).to be_ok
      expect(result.result_value).to eq(10)
    end

    it "does not raise on Axn::Failure (business logic failure)" do
      proxy = failing_action.send(:active_job_proxy_class).new

      # Should NOT raise - Axn::Failure is a business decision, not a transient error
      expect { proxy.perform({ should_fail: true }) }.not_to raise_error

      # But the result should indicate failure
      result = proxy.perform({ should_fail: true })
      expect(result.outcome).to be_failure
      expect(result.exception).to be_a(Axn::Failure)
    end

    it "re-raises unexpected exceptions for ActiveJob retry" do
      proxy = exception_action.send(:active_job_proxy_class).new

      # Should raise - unexpected errors should trigger ActiveJob retries
      expect { proxy.perform({}) }.to raise_error(RuntimeError, "Unexpected error")
    end
  end
end
