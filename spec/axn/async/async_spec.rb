# frozen_string_literal: true

RSpec.describe Axn::Async do
  let(:action) { build_axn }

  context "with default configuration" do
    it "includes Disabled module by default" do
      # Trigger default configuration by calling call_async
      expect { action.call_async(foo: "bar") }.to raise_error(NotImplementedError)
      expect(action.ancestors).to include(Axn::Async::Adapters::Disabled)
    end

    it "provides call_async method" do
      expect(action).to respond_to(:call_async)
    end

    it "call_async raises NotImplementedError by default" do
      expect { action.call_async(foo: "bar") }.to raise_error(NotImplementedError)
    end
  end

  # NOTE: The :sidekiq adapter contexts (adapter inclusion, sidekiq_options from kwargs,
  # and call_async behavior) were removed here because they depended on mocking Sidekiq
  # (the old "action IS the Sidekiq::Job" model). That behavior is covered against real
  # Sidekiq + the generic Worker in the Rails dummy app:
  #   spec_rails/dummy_app/spec/axn/async/async_interface_spec.rb (adapter inclusion + options)
  #   spec_rails/dummy_app/spec/axn/async/adapters/sidekiq_spec.rb (options + call_async)
  context "when explicitly configured with :active_job" do
    let(:action) do
      active_job_base = Class.new do
        def self.perform_later(*args)
          # Mock implementation
        end

        def self.after_discard(&)
          # Mock Rails 7.1+ after_discard
        end
      end

      stub_const("ActiveJob", Module.new)
      stub_const("ActiveJob::Base", active_job_base)

      build_axn do
        async :active_job
      end
    end

    it "includes Adapters::ActiveJob" do
      expect(action.ancestors).to include(Axn::Async::Adapters::ActiveJob)
    end

    it "provides call_async method" do
      expect(action).to respond_to(:call_async)
    end

    it "call_async works without raising" do
      expect { action.call_async(foo: "bar") }.not_to raise_error
    end
  end

  context "when configured with :active_job and kwargs" do
    it "raises ArgumentError" do
      stub_const("ActiveJob", Module.new)
      stub_const("ActiveJob::Base", Class.new)

      expect do
        build_axn do
          async :active_job, queue: "high_priority"
        end
      end.to raise_error(ArgumentError, /ActiveJob adapter requires a configuration block/)
    end
  end

  context "when configured with :disabled and kwargs" do
    it "raises ArgumentError" do
      expect do
        build_axn do
          async :disabled, queue: "high_priority"
        end
      end.to raise_error(ArgumentError, "Disabled adapter does not accept configuration options.")
    end
  end
end
