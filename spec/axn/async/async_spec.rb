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

  context "when explicitly configured with :sidekiq" do
    let(:action) do
      sidekiq_client = Class.new do
        def send(_method, *_args)
          false # Mock json_unsafe? to return false
        end
      end

      sidekiq_job = Module.new do
        def self.included(base)
          base.class_eval do
            def self.perform_async(*args)
              # Mock implementation
            end
          end
        end
      end

      stub_const("Sidekiq", Module.new)
      stub_const("Sidekiq::Job", sidekiq_job)
      stub_const("Sidekiq::Client", sidekiq_client)

      build_axn do
        async :sidekiq
      end
    end

    it "includes Adapters::Sidekiq" do
      expect(action.ancestors).to include(Axn::Async::Adapters::Sidekiq)
    end

    it "provides call_async method" do
      expect(action).to respond_to(:call_async)
    end

    it "call_async works without raising" do
      expect { action.call_async(foo: "bar") }.not_to raise_error
    end
  end

  context "when configured with :sidekiq and kwargs" do
    let(:action) do
      sidekiq_client = Class.new do
        def send(_method, *_args)
          false # Mock json_unsafe? to return false
        end
      end

      sidekiq_job = Module.new do
        def self.included(base)
          base.class_eval do
            def self.perform_async(*args)
              # Mock implementation
            end

            def self.sidekiq_options(**options)
              @sidekiq_options = options
            end

            def self.sidekiq_options_hash
              @sidekiq_options || {}
            end
          end
        end
      end

      stub_const("Sidekiq", Module.new)
      stub_const("Sidekiq::Job", sidekiq_job)
      stub_const("Sidekiq::Client", sidekiq_client)

      build_axn do
        async :sidekiq, queue: "high_priority", retry: 3
      end
    end

    it "includes Adapters::Sidekiq" do
      expect(action.ancestors).to include(Axn::Async::Adapters::Sidekiq)
    end

    it "applies sidekiq_options from kwargs" do
      expect(action.sidekiq_options_hash).to include(queue: "high_priority", retry: 3)
    end

    it "provides call_async method" do
      expect(action).to respond_to(:call_async)
    end

    it "call_async works without raising" do
      expect { action.call_async(foo: "bar") }.not_to raise_error
    end
  end

  context "when explicitly configured with :active_job" do
    let(:action) do
      active_job_base = Class.new do
        def self.perform_later(*args)
          # Mock implementation
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
      active_job_base = Class.new do
        def self.perform_later(*args)
          # Mock implementation
        end
      end

      stub_const("ActiveJob", Module.new)
      stub_const("ActiveJob::Base", active_job_base)

      expect do
        build_axn do
          async :active_job, queue: "high_priority"
        end
      end.to raise_error(ArgumentError,
                         "ActiveJob adapter requires a configuration block. Use `async :active_job do ... end` instead of passing keyword arguments.")
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
