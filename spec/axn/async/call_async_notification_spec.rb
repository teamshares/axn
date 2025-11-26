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

  describe "axn.call_async notification emission" do
    context "with Sidekiq adapter" do
      let(:action_class) do
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

              def self.perform_in(*args)
                # Mock implementation
              end

              def self.perform_at(*args)
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

      it "emits axn.call_async notification with correct payload" do
        action_class.call_async(name: "World", age: 25)
        expect(notifications.length).to eq(1)
        expect(notifications.first[:name]).to eq("axn.call_async")
        expect(notifications.first[:payload][:resource]).to eq("AnonymousClass")
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

    context "with ActiveJob adapter" do
      let(:action_class) do
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

    context "with named action class" do
      let(:action_class) do
        sidekiq_client = Class.new do
          def send(_method, *_args)
            false
          end
        end

        sidekiq_job = Module.new do
          def self.included(base)
            base.class_eval do
              def self.perform_async(*args)
                # Mock implementation
              end

              def self.perform_in(*args)
                # Mock implementation
              end

              def self.perform_at(*args)
                # Mock implementation
              end
            end
          end
        end

        stub_const("Sidekiq", Module.new)
        stub_const("Sidekiq::Job", sidekiq_job)
        stub_const("Sidekiq::Client", sidekiq_client)

        build_axn do
          def self.name
            "TestAction"
          end

          async :sidekiq
        end
      end

      it "includes the correct class name in notification payload" do
        action_class.call_async(name: "World")
        expect(notifications.first[:payload][:resource]).to eq("TestAction")
      end
    end

    context "with anonymous class" do
      let(:action_class) do
        sidekiq_client = Class.new do
          def send(_method, *_args)
            false
          end
        end

        sidekiq_job = Module.new do
          def self.included(base)
            base.class_eval do
              def self.perform_async(*args)
                # Mock implementation
              end

              def self.perform_in(*args)
                # Mock implementation
              end

              def self.perform_at(*args)
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

      it "includes AnonymousClass as resource name" do
        action_class.call_async(name: "World")
        expect(notifications.first[:payload][:resource]).to eq("AnonymousClass")
      end
    end
  end
end
