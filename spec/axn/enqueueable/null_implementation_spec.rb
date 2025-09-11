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
    # Temporarily hide ActiveJob and Sidekiq if they exist
    @original_activejob = Object.send(:remove_const, :ActiveJob) if defined?(ActiveJob)
    @original_sidekiq = Object.send(:remove_const, :Sidekiq) if defined?(Sidekiq)
  end

  after do
    # Restore ActiveJob and Sidekiq if they were originally defined
    Object.const_set(:ActiveJob, @original_activejob) if @original_activejob
    Object.const_set(:Sidekiq, @original_sidekiq) if @original_sidekiq
  end

  describe ".perform_later" do
    it "raises NotImplementedError with helpful message" do
      expect do
        action.perform_later(foo: "bar")
      end.to raise_error(NotImplementedError,
                         "Enqueueable functionality requires a background job library. " \
                         "Please add active_job or sidekiq to your Gemfile.")
    end
  end

  describe ".perform_now" do
    it "raises NotImplementedError with helpful message" do
      expect do
        action.perform_now(foo: "bar")
      end.to raise_error(NotImplementedError,
                         "Enqueueable functionality requires a background job library. " \
                         "Please add active_job or sidekiq to your Gemfile.")
    end
  end
end
