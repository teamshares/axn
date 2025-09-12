# frozen_string_literal: true

require "spec_helper"
require "axn/async/adapters"
require "axn/async/adapters/sidekiq"
require_relative "../../../support/shared_examples/async_adapter_interface"

RSpec.describe "Axn::Async with Sidekiq adapter" do
  let(:sidekiq_job) { Module.new }

  let(:action_class) do
    stub_const("Sidekiq", Module.new)
    stub_const("Sidekiq::Job", sidekiq_job)

    build_axn do
      async :sidekiq
      expects :name, :age

      def self.perform_async(*args)
        # Mock implementation
      end
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
end
