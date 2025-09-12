# frozen_string_literal: true

require_relative "../../support/shared_examples/registry_behavior"

RSpec.describe Axn::Async::Adapters do
  # Registry behavior shared examples
  it_behaves_like "a registry" do
    let(:expected_built_in_keys) { %i[sidekiq active_job disabled] }
    let(:expected_find_key) { :sidekiq }
    let(:expected_item_type) { "Adapter" }
    let(:expected_not_found_error_class) { Axn::Async::AdapterNotFound }
    let(:expected_duplicate_error_class) { Axn::Async::DuplicateAdapterError }
  end

  # Adapter-specific tests
  describe ".built_in" do
    it "loads all adapter files from the adapters directory" do
      expect(described_class.built_in[:sidekiq]).to be(Axn::Async::Adapters::Sidekiq)
      expect(described_class.built_in[:active_job]).to be(Axn::Async::Adapters::ActiveJob)
      expect(described_class.built_in[:disabled]).to be(Axn::Async::Adapters::Disabled)
    end
  end
end
