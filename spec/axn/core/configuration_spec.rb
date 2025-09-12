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
    it { expect(config.emit_metrics).to be_nil }
    it { expect(config.additional_includes).to eq([]) }
    it { expect(config.logger).to be_a(Logger) }
    it { expect(config.env.test?).to eq(true) }
  end

  describe "async configuration" do
    it "defaults to disabled" do
      expect(config._default_async_adapter).to be false
      expect(config._default_async_config).to eq({})
      expect(config._default_async_config_block).to be_nil
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

    it "allows setting config and block when adapter is false but already set" do
      config.set_default_async(:sidekiq)
      expect do
        config.set_default_async(false, queue: "test")
      end.not_to raise_error
      expect(config._default_async_config).to eq({ queue: "test" })
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
