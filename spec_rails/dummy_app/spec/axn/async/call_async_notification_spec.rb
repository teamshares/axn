# frozen_string_literal: true

# Migrated from the Sidekiq-coupled contexts of the non-rails
# spec/axn/async/call_async_notification_spec.rb. Those stubbed Sidekiq and treated the
# action as the job (the old model). Here we exercise the axn.call_async notification
# against the real Sidekiq generic-worker adapter.
RSpec.describe "Action axn.call_async notification (Sidekiq)", :sidekiq do
  let(:notifications) { [] }

  before do
    Sidekiq::Testing.fake!
    Sidekiq::Job.clear_all
    ActiveSupport::Notifications.subscribe("axn.call_async") do |name, start, finish, id, payload|
      notifications << { name:, start:, finish:, id:, payload: }
    end
  end

  after do
    ActiveSupport::Notifications.unsubscribe("axn.call_async")
    Sidekiq::Job.clear_all
  end

  describe "axn.call_async notification emission with Sidekiq adapter" do
    let(:action_class) do
      stub_const("CallAsyncNotificationSidekiq", Class.new do
        include Axn
        async :sidekiq
        def call = nil
      end)
    end

    it "emits axn.call_async notification with correct payload" do
      action_class.call_async(name: "World", age: 25)
      expect(notifications.length).to eq(1)
      expect(notifications.first[:name]).to eq("axn.call_async")
      expect(notifications.first[:payload][:resource]).to eq("CallAsyncNotificationSidekiq")
      expect(notifications.first[:payload][:action_class]).to eq(action_class)
      expect(notifications.first[:payload][:kwargs]).to eq({ name: "World", age: 25 })
      expect(notifications.first[:payload][:adapter]).to eq("sidekiq")
    end

    it "provides timing information in notification" do
      action_class.call_async(name: "World")
      expect(notifications.first[:start]).to be_a(Time)
      expect(notifications.first[:finish]).to be_a(Time)
      expect(notifications.first[:finish]).to be >= notifications.first[:start]
    end

    it "includes _async options in kwargs" do
      action_class.call_async(name: "World", _async: { wait: 3600 })
      expect(notifications.first[:payload][:kwargs]).to include(_async: { wait: 3600 })
    end
  end

  describe "resource naming in notification payload" do
    it "includes the correct class name for a named action" do
      named = stub_const("CallAsyncNotificationNamed", Class.new do
        include Axn
        async :sidekiq
        def call = nil
      end)

      named.call_async(name: "World")
      expect(notifications.first[:payload][:resource]).to eq("CallAsyncNotificationNamed")
    end

    it "includes AnonymousClass as the resource name for an anonymous action" do
      # Anonymous actions cannot enqueue to the generic Worker (needs a constant name),
      # but the notification still fires first and reports AnonymousClass. The subsequent
      # enqueue raises, which we ignore here — we only assert the emitted payload.
      anon = Class.new do
        include Axn
        async :sidekiq
        def call = nil
      end

      begin
        anon.call_async(name: "World")
      rescue ArgumentError
        # expected: cannot enqueue an anonymous Axn action to Sidekiq
      end

      expect(notifications.first[:payload][:resource]).to eq("AnonymousClass")
    end
  end
end
