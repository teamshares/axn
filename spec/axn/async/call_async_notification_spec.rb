# frozen_string_literal: true

RSpec.describe "Action axn.call_async notification" do
  let(:notifications) { [] }

  before do
    ActiveSupport::Notifications.subscribe("axn.call_async") do |name, start, finish, id, payload|
      notifications << { name:, start:, finish:, id:, payload: }
    end
  end

  after do
    ActiveSupport::Notifications.unsubscribe("axn.call_async")
  end

  # NOTE: The Sidekiq adapter notification cases and the named/anonymous resource-naming
  # cases were migrated to the Rails dummy app
  # (spec_rails/dummy_app/spec/axn/async/call_async_notification_spec.rb), where the real
  # generic-worker Sidekiq adapter exists. The cases below are adapter-agnostic / ActiveJob
  # specific and run in this non-rails suite unchanged.
  describe "axn.call_async notification emission" do
    context "with ActiveJob adapter" do
      let(:action_class) do
        active_job_base = Class.new do
          def self.perform_later(*args)
            # Mock implementation
          end
        end

        # Add after_discard for Rails 7.1+ compatibility
        active_job_base.define_singleton_method(:after_discard) { |&block| }

        stub_const("ActiveJob", Module.new)
        stub_const("ActiveJob::Base", active_job_base)

        build_axn do
          async :active_job
        end
      end

      it "emits axn.call_async notification with correct payload" do
        action_class.call_async(name: "World", age: 25)
        expect(notifications.length).to eq(1)
        expect(notifications.first[:name]).to eq("axn.call_async")
        expect(notifications.first[:payload][:resource]).to eq("AnonymousClass")
        expect(notifications.first[:payload][:action_class]).to eq(action_class)
        expect(notifications.first[:payload][:kwargs]).to eq({ name: "World", age: 25 })
        expect(notifications.first[:payload][:adapter]).to eq("active_job")
      end
    end

    context "with Disabled adapter" do
      let(:action_class) do
        build_axn do
          async false
        end
      end

      it "does not emit axn.call_async notification when disabled" do
        expect { action_class.call_async(name: "World") }.to raise_error(NotImplementedError)
        expect(notifications.length).to eq(0)
      end
    end

    context "with no adapter configured" do
      let(:action_class) { build_axn }

      it "does not emit axn.call_async notification when default is disabled" do
        expect { action_class.call_async(name: "World") }.to raise_error(NotImplementedError)
        # Default adapter is disabled, so no notification should be emitted
        expect(notifications.length).to eq(0)
      end
    end
  end
end
