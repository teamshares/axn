# frozen_string_literal: true

require_relative "../../../support/shared_examples/async_adapter_interface"
require_relative "../../../support/shared_examples/async_adapter_behavior"

RSpec.describe "Axn::Async with ActiveJob adapter" do
  # Mock ActiveJob::Base with after_discard to simulate Rails 7.1+
  let(:active_job_base_with_after_discard) do
    Class.new do
      def self.after_discard(&)
        # Mock implementation
      end
    end
  end

  let(:action_class) do
    stub_const("ActiveJob", Module.new)
    stub_const("ActiveJob::Base", active_job_base_with_after_discard)

    build_axn do
      async :active_job
      expects :name, :age
    end
  end

  # Shared example configuration for ActiveJob adapter
  let(:adapter_name) { :active_job }

  let(:setup_framework_mocks) do
    aj_base = active_job_base_with_after_discard
    lambda do
      stub_const("ActiveJob", Module.new)
      stub_const("ActiveJob::Base", aj_base)
    end
  end

  let(:build_action) do
    lambda do |config_block|
      action = build_axn do
        async :active_job
      end
      action.class_eval(&config_block) if config_block
      action
    end
  end

  let(:get_worker) do
    ->(action_class) { action_class.send(:active_job_proxy_class).new }
  end

  let(:perform_job) do
    ->(worker, args) { worker.perform(args) }
  end

  it_behaves_like "an async adapter interface", :active_job, Axn::Async::Adapters::ActiveJob
  it_behaves_like "async adapter exception handling"
  it_behaves_like "async adapter per-class exception reporting"

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

  describe "kwargs configuration" do
    it "raises error when kwargs are provided" do
      stub_const("ActiveJob", Module.new)
      stub_const("ActiveJob::Base", active_job_base_with_after_discard)

      expect do
        build_axn do
          async :active_job, queue: :high_priority
          expects :name
        end
      end.to raise_error(ArgumentError, /ActiveJob adapter requires a configuration block/)
    end
  end

  describe "Rails version validation" do
    context "when after_discard is not available (Rails < 7.1)" do
      let(:old_active_job_base) { Class.new } # No after_discard method

      it "raises error for :first_and_exhausted mode" do
        stub_const("ActiveJob", Module.new)
        stub_const("ActiveJob::Base", old_active_job_base)
        allow(Axn.config).to receive(:async_exception_reporting).and_return(:first_and_exhausted)

        expect do
          build_axn do
            async :active_job
            expects :name
          end
        end.to raise_error(ArgumentError, /requires Rails 7.1\+/)
      end

      it "raises error for :only_exhausted mode" do
        stub_const("ActiveJob", Module.new)
        stub_const("ActiveJob::Base", old_active_job_base)
        allow(Axn.config).to receive(:async_exception_reporting).and_return(:only_exhausted)

        expect do
          build_axn do
            async :active_job
            expects :name
          end
        end.to raise_error(ArgumentError, /requires Rails 7.1\+/)
      end

      it "allows :every_attempt mode" do
        stub_const("ActiveJob", Module.new)
        stub_const("ActiveJob::Base", old_active_job_base)
        allow(Axn.config).to receive(:async_exception_reporting).and_return(:every_attempt)

        expect do
          build_axn do
            async :active_job
            expects :name
          end
        end.not_to raise_error
      end
    end

    context "when after_discard is available (Rails 7.1+)" do
      let(:new_active_job_base) do
        Class.new do
          def self.after_discard(&)
            # Mock implementation
          end
        end
      end

      it "allows :first_and_exhausted mode" do
        stub_const("ActiveJob", Module.new)
        stub_const("ActiveJob::Base", new_active_job_base)
        allow(Axn.config).to receive(:async_exception_reporting).and_return(:first_and_exhausted)

        expect do
          build_axn do
            async :active_job
            expects :name
          end
        end.not_to raise_error
      end

      it "allows :only_exhausted mode" do
        stub_const("ActiveJob", Module.new)
        stub_const("ActiveJob::Base", new_active_job_base)
        allow(Axn.config).to receive(:async_exception_reporting).and_return(:only_exhausted)

        expect do
          build_axn do
            async :active_job
            expects :name
          end
        end.not_to raise_error
      end
    end
  end
end
