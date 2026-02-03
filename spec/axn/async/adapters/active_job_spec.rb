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

  describe "discard handler reporting modes" do
    # This spec calls the after_discard handler directly. It verifies we don’t
    # double-report when the perform path already reported (e.g. :every_attempt,
    # or :first_and_exhausted on first attempt).
    let(:active_job_base_with_hooks) do
      Class.new do
        # Use class method that stores callbacks, ensuring inherited classes get their own array
        def self.after_discard(&block)
          @after_discard_callbacks ||= []
          @after_discard_callbacks << block
        end

        def self.after_discard_callbacks
          @after_discard_callbacks ||= []
        end
      end
    end

    let(:action_for_discard_test) do
      stub_const("ActiveJob", Module.new)
      stub_const("ActiveJob::Base", active_job_base_with_hooks)

      build_axn do
        async :active_job
        expects :name

        def call
          raise StandardError, "boom"
        end
      end
    end

    it "does not trigger on_exception from discard handler when mode is :every_attempt" do
      allow(Axn.config).to receive(:async_exception_reporting).and_return(:every_attempt)

      # Track on_exception calls
      exception_reports = []
      allow(Axn.config).to receive(:on_exception) do |exception, **kwargs|
        exception_reports << { exception:, **kwargs }
      end

      proxy_class = action_for_discard_test.send(:active_job_proxy_class)
      proxy_instance = proxy_class.new

      # Stub methods the discard handler uses
      allow(proxy_instance).to receive(:_axn_current_attempt).and_return(1)
      allow(proxy_instance).to receive(:_axn_max_retries).and_return(5)
      allow(proxy_instance).to receive(:_axn_job_id).and_return("job-123")

      exception = StandardError.new("boom")
      mock_job = double("job", arguments: [{ name: "test" }])

      # Invoke the discard handler directly (simulating after_discard callback)
      proxy_instance.send(:_axn_handle_discard, mock_job, exception, action_for_discard_test)

      # Should NOT have called on_exception because mode is :every_attempt
      expect(exception_reports).to be_empty
    end

    it "triggers on_exception from discard handler when mode is :only_exhausted" do
      allow(Axn.config).to receive(:async_exception_reporting).and_return(:only_exhausted)

      exception_reports = []
      allow(Axn.config).to receive(:on_exception) do |exception, **kwargs|
        exception_reports << { exception:, **kwargs }
      end

      proxy_class = action_for_discard_test.send(:active_job_proxy_class)
      proxy_instance = proxy_class.new

      allow(proxy_instance).to receive(:_axn_current_attempt).and_return(5)
      allow(proxy_instance).to receive(:_axn_max_retries).and_return(5)
      allow(proxy_instance).to receive(:_axn_job_id).and_return("job-123")

      exception = StandardError.new("boom")
      mock_job = double("job", arguments: [{ name: "test" }])

      proxy_instance.send(:_axn_handle_discard, mock_job, exception, action_for_discard_test)

      # Should have called on_exception because mode is :only_exhausted and this is exhaustion handler
      expect(exception_reports.size).to eq(1)
      expect(exception_reports.first[:context][:async][:discarded]).to be true
    end

    it "does not trigger on_exception from discard handler when mode is :first_and_exhausted and first attempt" do
      allow(Axn.config).to receive(:async_exception_reporting).and_return(:first_and_exhausted)

      exception_reports = []
      allow(Axn.config).to receive(:on_exception) do |exception, **kwargs|
        exception_reports << { exception:, **kwargs }
      end

      proxy_class = action_for_discard_test.send(:active_job_proxy_class)
      proxy_instance = proxy_class.new

      allow(proxy_instance).to receive(:_axn_current_attempt).and_return(1)
      allow(proxy_instance).to receive(:_axn_max_retries).and_return(5)
      allow(proxy_instance).to receive(:_axn_job_id).and_return("job-123")

      exception = StandardError.new("boom")
      mock_job = double("job", arguments: [{ name: "test" }])

      proxy_instance.send(:_axn_handle_discard, mock_job, exception, action_for_discard_test)

      # For :first_and_exhausted, attempt 1 is reported by perform path, not discard handler.
      expect(exception_reports).to be_empty
    end

    it "triggers on_exception from discard handler when mode is :first_and_exhausted and later attempt" do
      allow(Axn.config).to receive(:async_exception_reporting).and_return(:first_and_exhausted)

      exception_reports = []
      allow(Axn.config).to receive(:on_exception) do |exception, **kwargs|
        exception_reports << { exception:, **kwargs }
      end

      proxy_class = action_for_discard_test.send(:active_job_proxy_class)
      proxy_instance = proxy_class.new

      allow(proxy_instance).to receive(:_axn_current_attempt).and_return(2)
      allow(proxy_instance).to receive(:_axn_max_retries).and_return(5)
      allow(proxy_instance).to receive(:_axn_job_id).and_return("job-123")

      exception = StandardError.new("boom")
      mock_job = double("job", arguments: [{ name: "test" }])

      proxy_instance.send(:_axn_handle_discard, mock_job, exception, action_for_discard_test)

      expect(exception_reports.size).to eq(1)
      expect(exception_reports.first[:context][:async][:discarded]).to be true
    end
  end
end
