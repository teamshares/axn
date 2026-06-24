# frozen_string_literal: true

# Migrated from the Sidekiq-coupled "async invocation logging" cases of the non-rails
# spec/axn/core/automatic_logging_spec.rb. Those stubbed Sidekiq (the old "action IS the
# Sidekiq::Job" model). Here we assert the enqueue-time async invocation logging against
# the real generic-worker Sidekiq adapter (fake mode: enqueue + log, no execution).
RSpec.describe "Axn::Core::AutomaticLogging async invocation logging (Sidekiq)", :sidekiq do
  let(:log_messages) { [] }
  let(:logger) { instance_double(Logger) }

  before do
    Sidekiq::Testing.fake!
    Sidekiq::Job.clear_all

    allow(Axn.config).to receive(:logger).and_return(logger)
    allow(logger).to receive(:info) { |message| log_messages << { level: :info, message: } }
    allow(logger).to receive(:warn) { |message| log_messages << { level: :warn, message: } }
  end

  after { Sidekiq::Job.clear_all }

  context "when call_async is invoked" do
    let(:action_class) do
      stub_const("AsyncLoggingAction", Class.new do
        include Axn
        async :sidekiq
        expects :name
        def call = "Hello, #{name}!"
      end)
    end

    it "logs once when call_async is invoked" do
      action_class.call_async(name: "World")

      expect(log_messages.length).to eq(1)

      async_log = log_messages.find { |log| log[:message].include?("Enqueueing async execution via sidekiq") }
      expect(async_log).to be_present
      expect(async_log[:message]).to include('name: "World"')
      expect(async_log[:level]).to eq(:info)
    end

    it "uses the configured auto_log level" do
      action_class.auto_log :warn

      action_class.call_async(name: "World")

      expect(log_messages.length).to eq(1)
      expect(log_messages.first[:level]).to eq(:warn)
    end

    it "does not log when auto_log is disabled" do
      action_class.auto_log false

      action_class.call_async(name: "World")

      expect(log_messages).to be_empty
    end

    it "does not log the enqueue when only error outcomes are configured" do
      action_class.auto_log exception: :error

      action_class.call_async(name: "World")

      expect(log_messages).to be_empty
    end

    it "filters sensitive fields from context" do
      action_class = stub_const("AsyncLoggingSensitiveAction", Class.new do
        include Axn
        async :sidekiq
        expects :name, sensitive: true
        expects :age
        def call = nil
      end)

      action_class.call_async(name: "Secret", age: 25)

      expect(log_messages.length).to eq(1)
      expect(log_messages.first[:message]).not_to include("Secret")
      expect(log_messages.first[:message]).to include("age: 25")
    end
  end
end
