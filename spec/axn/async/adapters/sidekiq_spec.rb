# frozen_string_literal: true

require_relative "../../../support/shared_examples/async_adapter_interface"

RSpec.describe "Axn::Async with Sidekiq adapter" do
  let(:sidekiq_job) do
    Module.new do
      def self.included(base)
        base.class_eval do
          def self.perform_async(*args)
            # Mock implementation
          end

          def self.perform_in(interval, *args)
            # Mock implementation for delayed execution
          end

          def self.perform_at(timestamp, *args)
            # Mock implementation for scheduled execution
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
  end

  let(:action_class) do
    stub_const("Sidekiq", Module.new)
    stub_const("Sidekiq::Job", sidekiq_job)

    build_axn do
      async :sidekiq
      expects :name, :age
    end
  end

  it_behaves_like "an async adapter interface", :sidekiq, Axn::Async::Adapters::Sidekiq

  describe ".call_async" do
    it "calls perform_async with processed context" do
      expect(action_class).to receive(:perform_async).with(hash_including("name" => "World", "age" => 25))
      action_class.call_async(name: "World", age: 25)
    end

    context "with delayed execution" do
      it "calls perform_in when _async contains wait option" do
        expect(action_class).to receive(:perform_in).with(3600, hash_including("name" => "World", "age" => 25))
        action_class.call_async(name: "World", age: 25, _async: { wait: 3600 })
      end

      it "calls perform_at when _async contains wait_until option" do
        future_time = Time.now + 3600
        expect(action_class).to receive(:perform_at).with(future_time, hash_including("name" => "World", "age" => 25))
        action_class.call_async(name: "World", age: 25, _async: { wait_until: future_time })
      end

      it "calls perform_async when _async is not a hash" do
        expect(action_class).to receive(:perform_async).with(hash_including("name" => "World", "age" => 25, "_async" => "user_value"))
        action_class.call_async(name: "World", age: 25, _async: "user_value")
      end

      it "calls perform_async when _async is an empty hash" do
        expect(action_class).to receive(:perform_async).with(hash_including("name" => "World", "age" => 25))
        action_class.call_async(name: "World", age: 25, _async: {})
      end
    end
  end

  describe "Sidekiq-specific behavior" do
    it "includes Sidekiq::Job" do
      expect(action_class.ancestors).to include(Sidekiq::Job)
    end

    it "provides perform method on instances" do
      action = action_class.send(:new, name: "Test", age: 30)
      expect(action).to respond_to(:perform)
    end

    it "calls perform_async with processed context" do
      expect(action_class).to receive(:perform_async).with(hash_including("name" => "World", "age" => 25))
      action_class.call_async(name: "World", age: 25)
    end
  end

  describe "#perform exception handling" do
    let(:successful_action) do
      stub_const("Sidekiq", Module.new)
      stub_const("Sidekiq::Job", sidekiq_job)

      build_axn do
        async :sidekiq
        expects :value
        exposes :result_value

        def call
          expose result_value: value * 2
        end
      end
    end

    let(:failing_action) do
      stub_const("Sidekiq", Module.new)
      stub_const("Sidekiq::Job", sidekiq_job)

      build_axn do
        async :sidekiq
        expects :should_fail

        def call
          fail! "Business logic failure" if should_fail
        end
      end
    end

    let(:exception_action) do
      stub_const("Sidekiq", Module.new)
      stub_const("Sidekiq::Job", sidekiq_job)

      build_axn do
        async :sidekiq

        def call
          raise "Unexpected error"
        end
      end
    end

    it "returns result on success" do
      worker = successful_action.send(:new)
      result = worker.perform({ "value" => 5 })

      expect(result).to be_ok
      expect(result.result_value).to eq(10)
    end

    it "does not raise on Axn::Failure (business logic failure)" do
      worker = failing_action.send(:new)

      # Should NOT raise - Axn::Failure is a business decision, not a transient error
      expect { worker.perform({ "should_fail" => true }) }.not_to raise_error

      # But the result should indicate failure
      result = worker.perform({ "should_fail" => true })
      expect(result.outcome).to be_failure
      expect(result.exception).to be_a(Axn::Failure)
    end

    it "re-raises unexpected exceptions for Sidekiq retry" do
      worker = exception_action.send(:new)

      # Should raise - unexpected errors should trigger Sidekiq retries
      expect { worker.perform({}) }.to raise_error(RuntimeError, "Unexpected error")
    end
  end

  describe "kwargs configuration" do
    let(:action_class_with_kwargs) do
      stub_const("Sidekiq", Module.new)
      stub_const("Sidekiq::Job", sidekiq_job)

      build_axn do
        async :sidekiq, queue: "high_priority", retry: 5
        expects :name, :age
      end
    end

    it "applies sidekiq_options from kwargs" do
      expect(action_class_with_kwargs.sidekiq_options_hash).to include(queue: "high_priority", retry: 5)
    end

    it "works with call_async" do
      expect(action_class_with_kwargs).to receive(:perform_async).with(hash_including("name" => "World", "age" => 25))
      action_class_with_kwargs.call_async(name: "World", age: 25)
    end
  end
end
