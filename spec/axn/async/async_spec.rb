# frozen_string_literal: true

RSpec.describe Axn::Async do
  let(:action) { build_axn }

  context "with default configuration" do
    it "includes Disabled module by default" do
      # Trigger default configuration by calling call_async
      expect { action.call_async(foo: "bar") }.to raise_error(NotImplementedError)
      expect(action.ancestors).to include(Axn::Async::Disabled)
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
      sidekiq_job = Module.new do
        def self.included(base)
          base.extend(ClassMethods)
        end

        module ClassMethods
          def perform_async(*args)
            # Mock implementation
          end
        end
      end

      sidekiq_client = Class.new do
        def send(method, *args)
          false # Mock json_unsafe? to return false
        end
      end

      stub_const("Sidekiq", Module.new)
      stub_const("Sidekiq::Job", sidekiq_job)
      stub_const("Sidekiq::Client", sidekiq_client)

      build_axn do
        async :sidekiq
      end
    end

    it "includes ViaSidekiq" do
      expect(action.ancestors).to include(Axn::Async::ViaSidekiq)
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

    it "includes ViaActiveJob" do
      expect(action.ancestors).to include(Axn::Async::ViaActiveJob)
    end

    it "provides call_async method" do
      expect(action).to respond_to(:call_async)
    end

    it "call_async works without raising" do
      expect { action.call_async(foo: "bar") }.not_to raise_error
    end
  end
end
