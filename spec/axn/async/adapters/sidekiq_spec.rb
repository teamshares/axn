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

    it "handles empty context" do
      expect(action_class).to receive(:perform_async).with({})
      action_class.call_async({})
    end

    it "handles nil context gracefully" do
      expect(action_class).to receive(:perform_async).with({})
      action_class.call_async(nil)
    end
  end

  describe "Sidekiq-specific behavior" do
    it "includes Sidekiq::Job" do
      expect(action_class.ancestors).to include(Sidekiq::Job)
    end

    it "provides perform method on instances" do
      action = action_class.new(name: "Test", age: 30)
      expect(action).to respond_to(:perform)
    end

    it "calls perform_async with processed context" do
      expect(action_class).to receive(:perform_async).with(hash_including("name" => "World", "age" => 25))
      action_class.call_async(name: "World", age: 25)
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
