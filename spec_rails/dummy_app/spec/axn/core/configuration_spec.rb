# frozen_string_literal: true

# These tests require Sidekiq/ActiveJob to be loaded, so they live in spec_rails
# rather than the main spec/ directory.

RSpec.describe Axn::Configuration do
  subject(:config) { Axn.config }

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
  end

  describe "eager EnqueueAllOrchestrator configuration" do
    # This test actually applies the config - run it last and only with sidekiq
    # to avoid polluting other tests.
    it "applies sidekiq config to EnqueueAllOrchestrator" do
      config.set_enqueue_all_async(:sidekiq)

      expect(Axn::Async::EnqueueAllOrchestrator._async_adapter).to eq(:sidekiq)
      expect(Axn::Async::EnqueueAllOrchestrator.ancestors).to include(Sidekiq::Job)
    end
  end
end
