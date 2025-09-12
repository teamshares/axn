# frozen_string_literal: true

require "spec_helper"

RSpec.describe Axn::Async::Adapters do
  describe ".built_in" do
    it "loads all adapter files from the adapters directory" do
      expect(described_class.built_in.keys).to include(:sidekiq, :active_job, :disabled)
      expect(described_class.built_in[:sidekiq]).to be(Axn::Async::Adapters::Sidekiq)
      expect(described_class.built_in[:active_job]).to be(Axn::Async::Adapters::ActiveJob)
      expect(described_class.built_in[:disabled]).to be(Axn::Async::Adapters::Disabled)
    end

    it "returns a hash with module values" do
      adapters = described_class.built_in
      expect(adapters).to be_a(Hash)
      expect(adapters.values).to all(be_a(Module))
    end

    it "memoizes the result" do
      first_call = described_class.built_in
      second_call = described_class.built_in
      expect(first_call.object_id).to eq(second_call.object_id)
    end
  end

  describe ".register" do
    let(:custom_adapter) do
      Module.new do
        extend ActiveSupport::Concern
        included do
          puts "Custom adapter included!"
        end
      end
    end

    it "adds an adapter to the list" do
      described_class.clear!
      initial_count = described_class.all.length

      described_class.register(:custom, custom_adapter)

      expect(described_class.all.length).to eq(initial_count + 1)
      expect(described_class.all[:custom]).to eq(custom_adapter)
    end

    it "raises an error when registering a duplicate adapter by name" do
      described_class.clear!
      described_class.register(:custom, custom_adapter)

      expect do
        described_class.register(:custom, custom_adapter)
      end.to raise_error(Axn::Async::DuplicateAdapterError, "Adapter custom already registered")
    end

    it "initializes adapters if not already done" do
      described_class.clear!
      expect(described_class).to receive(:all).and_call_original
      described_class.register(:custom, custom_adapter)
    end
  end

  describe ".find" do
    it "finds an existing adapter" do
      expect(described_class.find(:sidekiq)).to be(Axn::Async::Adapters::Sidekiq)
    end

    it "raises AdapterNotFound for non-existent adapter" do
      expect do
        described_class.find(:nonexistent)
      end.to raise_error(Axn::Async::AdapterNotFound, "Adapter 'nonexistent' not found")
    end

    it "raises AdapterNotFound for nil name" do
      expect do
        described_class.find(nil)
      end.to raise_error(Axn::Async::AdapterNotFound, "Adapter name cannot be nil")
    end

    it "raises AdapterNotFound for empty name" do
      expect do
        described_class.find("")
      end.to raise_error(Axn::Async::AdapterNotFound, "Adapter name cannot be empty")
    end
  end

  describe ".clear!" do
    it "resets to built-in adapters only" do
      custom_adapter = Module.new
      described_class.register(:test_adapter, custom_adapter)
      expect(described_class.all.keys).to include(:test_adapter)

      described_class.clear!
      expect(described_class.all.keys).not_to include(:test_adapter)
      expect(described_class.all.keys).to include(:sidekiq, :active_job, :disabled)
    end
  end

  describe ".all" do
    it "returns all registered adapters" do
      adapters = described_class.all
      expect(adapters).to be_a(Hash)
      expect(adapters.keys).to include(:sidekiq, :active_job, :disabled)
    end
  end
end
