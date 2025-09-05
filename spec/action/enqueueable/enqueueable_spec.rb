# frozen_string_literal: true

RSpec.describe Axn::Enqueueable do
  let(:action) { build_action }

  context "when Sidekiq is not available" do
    before do
      # Temporarily hide Sidekiq if it exists
      @original_sidekiq = Object.send(:remove_const, :Sidekiq) if defined?(Sidekiq)
    end

    after do
      # Restore Sidekiq if it was originally defined
      Object.const_set(:Sidekiq, @original_sidekiq) if @original_sidekiq
    end

    it "includes NullImplementation" do
      expect(action.ancestors).to include(Axn::Enqueueable::NullImplementation)
    end

    it "raises NotImplementedError when calling enqueue" do
      expect do
        action.enqueue
      end.to raise_error(NotImplementedError,
                         "Enqueueable functionality requires a background job library. " \
                         "Please add sidekiq to your Gemfile or configure another provider.")
    end

    it "raises NotImplementedError when calling enqueue!" do
      expect do
        action.enqueue!
      end.to raise_error(NotImplementedError,
                         "Enqueueable functionality requires a background job library. " \
                         "Please add sidekiq to your Gemfile or configure another provider.")
    end
  end

  context "when Sidekiq is available" do
    before do
      # Mock Sidekiq being available with proper structure
      allow(Object).to receive(:defined?).with(:Sidekiq).and_return(true)
      stub_const("Sidekiq", Module.new)
      stub_const("Sidekiq::Job", Module.new)
    end

    it "includes ViaSidekiq" do
      expect(action.ancestors).to include(Axn::Enqueueable::ViaSidekiq)
    end
  end
end
