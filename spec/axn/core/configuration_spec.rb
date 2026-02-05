# frozen_string_literal: true

RSpec.describe Axn::RailsConfiguration do
  subject(:config) { described_class.new }

  describe "#app_actions_autoload_namespace" do
    it "defaults to nil" do
      expect(config.app_actions_autoload_namespace).to be_nil
    end

    it "can be set to a symbol" do
      config.app_actions_autoload_namespace = :Actions
      expect(config.app_actions_autoload_namespace).to eq(:Actions)
    end

    it "can be set to nil explicitly" do
      config.app_actions_autoload_namespace = nil
      expect(config.app_actions_autoload_namespace).to be_nil
    end
  end
end

RSpec.describe Axn::Configuration do
  subject(:config) { described_class.new }

  describe "defaults (in test mode)" do
    it { expect(config.additional_includes).to eq([]) }
    it { expect(config.logger).to be_a(Logger) }
    it { expect(config.env.test?).to eq(true) }
  end

  describe "async configuration" do
    # Tests that use real adapters (:sidekiq, :active_job) are in spec_rails/
    # since they require those gems to be loaded.

    it "defaults to disabled" do
      expect(config._default_async_adapter).to be false
      expect(config._default_async_config).to eq({})
      expect(config._default_async_config_block).to be_nil
    end

    it "can set just the config" do
      config.set_default_async(false, queue: "low", retry: 3)

      expect(config._default_async_adapter).to be false
      expect(config._default_async_config).to eq({ queue: "low", retry: 3 })
      expect(config._default_async_config_block).to be_nil
    end

    it "can set just the block" do
      block = proc { puts "test block" }
      config.set_default_async(&block)

      expect(config._default_async_adapter).to be false
      expect(config._default_async_config).to eq({})
      expect(config._default_async_config_block).to eq(block)
    end

    it "raises ArgumentError when trying to set adapter to nil" do
      expect do
        config.set_default_async(nil)
      end.to raise_error(ArgumentError, "Cannot set default async adapter to nil as it would cause infinite recursion")
    end

    it "triggers async exception reporting registration for Sidekiq when set_default_async(:sidekiq)" do
      allow(config).to receive(:_ensure_async_exception_reporting_registered_for_adapter)
      allow(config).to receive(:_apply_async_to_enqueue_all_orchestrator)

      config.set_default_async(:sidekiq, queue: "default")

      expect(config).to have_received(:_ensure_async_exception_reporting_registered_for_adapter).with(:sidekiq)
    end

    it "calls ensure with false when adapter is false (no registration for disabled async)" do
      allow(config).to receive(:_ensure_async_exception_reporting_registered_for_adapter)
      allow(config).to receive(:_apply_async_to_enqueue_all_orchestrator)

      config.set_default_async(false, queue: "low")

      expect(config).to have_received(:_ensure_async_exception_reporting_registered_for_adapter).with(false)
    end
  end

  describe "set_enqueue_all_async and async exception reporting" do
    it "triggers async exception reporting registration for Sidekiq when set_enqueue_all_async(:sidekiq)" do
      allow(config).to receive(:_ensure_async_exception_reporting_registered_for_adapter)
      allow(config).to receive(:_apply_async_to_enqueue_all_orchestrator)

      config.set_enqueue_all_async(:sidekiq, queue: "batch")

      expect(config).to have_received(:_ensure_async_exception_reporting_registered_for_adapter).with(:sidekiq)
    end
  end

  describe "#rails" do
    it "returns a RailsConfiguration instance" do
      expect(config.rails).to be_a(Axn::RailsConfiguration)
    end

    it "returns the same instance on subsequent calls" do
      expect(config.rails).to be(config.rails)
    end
  end

  describe "#env" do
    it "can be set to production" do
      expect(config.env.test?).to eq(true)
      config.env = "production"
      expect(config.env.production?).to eq(true)
    end
  end

  describe "#async_exception_reporting" do
    it "defaults to :first_and_exhausted" do
      expect(config.async_exception_reporting).to eq(:first_and_exhausted)
    end

    it "can be set to :every_attempt" do
      config.async_exception_reporting = :every_attempt
      expect(config.async_exception_reporting).to eq(:every_attempt)
    end

    it "can be set to :only_exhausted" do
      config.async_exception_reporting = :only_exhausted
      expect(config.async_exception_reporting).to eq(:only_exhausted)
    end

    it "raises ArgumentError for invalid values" do
      expect do
        config.async_exception_reporting = :invalid
      end.to raise_error(ArgumentError, /must be one of:/)
    end
  end

  describe "#async_max_retries" do
    it "defaults to nil (uses adapter defaults)" do
      expect(config.async_max_retries).to be_nil
    end

    it "can be set to override adapter defaults" do
      config.async_max_retries = 10
      expect(config.async_max_retries).to eq(10)
    end
  end

  describe "#on_exception" do
    let(:exception) { StandardError.new("fail!") }
    let(:action) { double("Action", log: nil) }
    let(:context) { { foo: :bar } }
    subject(:config) { described_class.new }

    it "calls proc with only e if no kwargs expected" do
      called = nil
      config.on_exception = proc { |e| called = [e] }
      config.on_exception(exception, action:, context:)
      expect(called).to eq([exception])
    end

    it "calls proc with e and action if action: is expected" do
      called = nil
      config.on_exception = proc { |e, action:| called = [e, action] }
      config.on_exception(exception, action:, context:)
      expect(called).to eq([exception, action])
    end

    it "calls proc with e and context if context: is expected" do
      called = nil
      config.on_exception = proc { |e, context:| called = [e, context] }
      config.on_exception(exception, action:, context:)
      expect(called).to eq([exception, context])
    end

    it "calls proc with e, action, and context if both are expected" do
      called = nil
      config.on_exception = proc { |e, action:, context:| called = [e, action, context] }
      config.on_exception(exception, action:, context:)
      expect(called).to eq([exception, action, context])
    end

    it "does not pass unknown kwargs" do
      called = nil
      config.on_exception = proc { |e, foo: nil| called = [e, foo] }
      config.on_exception(exception, action:, context:)
      expect(called).to eq([exception, nil])
    end
  end
end
