# frozen_string_literal: true

# These tests require Sidekiq/ActiveJob to be loaded, so they live in spec_rails
# rather than the main spec/ directory.

RSpec.describe Axn::Configuration do
  subject(:config) { Axn.config }

  # Every example here writes the process-global default and enqueue-all async settings, which later files read
  # (a leftover enqueue-all adapter is re-applied to the orchestrator by the next `set_default_async`). Put both
  # back to their unset state. Runs before rspec-mocks teardown, so the stubs below still intercept the re-apply.
  after do
    config.set_enqueue_all_async(nil)
    config.set_default_async(false)
  end

  describe "async configuration with real adapters" do
    # These tests stub _apply_async_to_enqueue_all_orchestrator to avoid
    # permanently mutating the EnqueueAllOrchestrator class (which would
    # pollute other tests that depend on its async configuration).
    before do
      allow(config).to receive(:_apply_async_to_enqueue_all_orchestrator)
    end

    it "can set adapter, config, and block together" do
      block = proc { puts "test" }
      config.set_default_async(:sidekiq, queue: "high", retry: 5, &block)

      expect(config._default_async_adapter).to eq(:sidekiq)
      expect(config._default_async_config).to eq({ queue: "high", retry: 5 })
      expect(config._default_async_config_block).to eq(block)
    end

    it "can set just the adapter" do
      config.set_default_async(:active_job)

      expect(config._default_async_adapter).to eq(:active_job)
      expect(config._default_async_config).to eq({})
      expect(config._default_async_config_block).to be_nil
    end

    it "allows setting config and block when adapter is false but already set" do
      config.set_default_async(:sidekiq)
      expect do
        config.set_default_async(false, queue: "test")
      end.not_to raise_error
      expect(config._default_async_config).to eq({ queue: "test" })
    end

    it "overwrites previous values when called multiple times" do
      # First call
      block1 = proc { puts "first block" }
      config.set_default_async(:sidekiq, queue: "first", retry: 1, &block1)

      expect(config._default_async_adapter).to eq(:sidekiq)
      expect(config._default_async_config).to eq({ queue: "first", retry: 1 })
      expect(config._default_async_config_block).to eq(block1)

      # Second call - should overwrite everything
      block2 = proc { puts "second block" }
      config.set_default_async(:active_job, queue: "second", retry: 2, &block2)

      expect(config._default_async_adapter).to eq(:active_job)
      expect(config._default_async_config).to eq({ queue: "second", retry: 2 })
      expect(config._default_async_config_block).to eq(block2)

      # Third call - should overwrite again
      config.set_default_async(false, queue: "third", retry: 3)

      expect(config._default_async_adapter).to be false
      expect(config._default_async_config).to eq({ queue: "third", retry: 3 })
      expect(config._default_async_config_block).to be_nil
    end

    it "calls _apply_async_to_enqueue_all_orchestrator when setting async" do
      config.set_default_async(:sidekiq)
      expect(config).to have_received(:_apply_async_to_enqueue_all_orchestrator).once
    end

    it "registers Sidekiq exception reporting when set_default_async(:sidekiq) without ever setting async_exception_reporting" do
      skip "Sidekiq not loaded" unless defined?(Sidekiq)

      Axn::Async::Adapters::Sidekiq::AutoConfigure.reset!
      # Ensure we use the default (never call async_exception_reporting=)
      config.instance_variable_set(:@async_exception_reporting, nil)

      config.set_default_async(:sidekiq, queue: "default")

      expect(Axn::Async::Adapters::Sidekiq::AutoConfigure.registered?).to be true
    ensure
      Axn::Async::Adapters::Sidekiq::AutoConfigure.reset! if defined?(Axn::Async::Adapters::Sidekiq::AutoConfigure)
    end
  end

  describe "eager EnqueueAllOrchestrator configuration" do
    # This test really applies the config, and `async` includes the adapter module into its target for good, so
    # the target is a throwaway subclass standing in for the orchestrator constant rather than the shared class.
    it "applies sidekiq config to EnqueueAllOrchestrator" do
      skip "Sidekiq not loaded" unless defined?(Sidekiq)

      stub_const("Axn::Async::EnqueueAllOrchestrator", Class.new(Axn::Async::EnqueueAllOrchestrator))

      config.set_enqueue_all_async(:sidekiq)

      expect(Axn::Async::EnqueueAllOrchestrator._async_adapter).to eq(:sidekiq)
      # The orchestrator is no longer a Sidekiq::Job itself; its per-action generic Worker
      # subclass is the Sidekiq::Job that runs it.
      worker = Axn::Async::EnqueueAllOrchestrator.const_get(:AxnSidekiqWorker)
      expect(worker.ancestors).to include(Sidekiq::Job)
      expect(worker).to be < Axn::Async::Adapters::Sidekiq::Worker
    end
  end
end
