# frozen_string_literal: true

RSpec.describe Axn::Enqueueable::NullImplementation do
  let(:action) do
    build_axn do
      expects :foo
      def call
        # simple action
      end
    end
  end

  before do
    # Temporarily hide Sidekiq if it exists
    @original_sidekiq = Object.send(:remove_const, :Sidekiq) if defined?(Sidekiq)
  end

  after do
    # Restore Sidekiq if it was originally defined
    Object.const_set(:Sidekiq, @original_sidekiq) if @original_sidekiq
  end

  describe ".enqueue" do
    it "raises NotImplementedError with helpful message" do
      expect do
        action.enqueue(foo: "bar")
      end.to raise_error(NotImplementedError,
                         "Enqueueable functionality requires a background job library. " \
                         "Please add sidekiq to your Gemfile or configure another provider.")
    end
  end

  describe ".enqueue!" do
    it "raises NotImplementedError with helpful message" do
      expect do
        action.enqueue!(foo: "bar")
      end.to raise_error(NotImplementedError,
                         "Enqueueable functionality requires a background job library. " \
                         "Please add sidekiq to your Gemfile or configure another provider.")
    end
  end
end
