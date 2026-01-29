# frozen_string_literal: true

RSpec.describe Axn::Async::RetryContext do
  describe "#initialize" do
    it "stores the provided attributes" do
      context = described_class.new(
        adapter: :sidekiq,
        attempt: 3,
        max_retries: 25,
        job_id: "abc123",
      )

      expect(context.adapter).to eq(:sidekiq)
      expect(context.attempt).to eq(3)
      expect(context.max_retries).to eq(25)
      expect(context.job_id).to eq("abc123")
    end
  end

  describe "#first_attempt?" do
    it "returns true when attempt is 1" do
      context = described_class.new(adapter: :sidekiq, attempt: 1, max_retries: 25)
      expect(context.first_attempt?).to be true
    end

    it "returns false when attempt is greater than 1" do
      context = described_class.new(adapter: :sidekiq, attempt: 2, max_retries: 25)
      expect(context.first_attempt?).to be false
    end
  end

  describe "#retries_exhausted?" do
    it "returns true when attempt exceeds max_retries" do
      context = described_class.new(adapter: :sidekiq, attempt: 26, max_retries: 25)
      expect(context.retries_exhausted?).to be true
    end

    it "returns false when attempt equals max_retries" do
      context = described_class.new(adapter: :sidekiq, attempt: 25, max_retries: 25)
      expect(context.retries_exhausted?).to be false
    end

    it "returns false when attempt is less than max_retries" do
      context = described_class.new(adapter: :sidekiq, attempt: 5, max_retries: 25)
      expect(context.retries_exhausted?).to be false
    end
  end

  describe "#should_trigger_on_exception?" do
    describe "with :every_attempt mode" do
      it "always returns true" do
        context = described_class.new(adapter: :sidekiq, attempt: 5, max_retries: 25)
        expect(context.should_trigger_on_exception?(:every_attempt)).to be true
      end
    end

    describe "with :first_and_exhausted mode" do
      it "returns true on first attempt" do
        context = described_class.new(adapter: :sidekiq, attempt: 1, max_retries: 25)
        expect(context.should_trigger_on_exception?(:first_and_exhausted)).to be true
      end

      it "returns false on intermediate attempts" do
        context = described_class.new(adapter: :sidekiq, attempt: 5, max_retries: 25)
        expect(context.should_trigger_on_exception?(:first_and_exhausted)).to be false
      end

      it "returns true when retries are exhausted" do
        context = described_class.new(adapter: :sidekiq, attempt: 26, max_retries: 25)
        expect(context.should_trigger_on_exception?(:first_and_exhausted)).to be true
      end
    end

    describe "with :only_exhausted mode" do
      it "returns false on first attempt" do
        context = described_class.new(adapter: :sidekiq, attempt: 1, max_retries: 25)
        expect(context.should_trigger_on_exception?(:only_exhausted)).to be false
      end

      it "returns false on intermediate attempts" do
        context = described_class.new(adapter: :sidekiq, attempt: 5, max_retries: 25)
        expect(context.should_trigger_on_exception?(:only_exhausted)).to be false
      end

      it "returns true when retries are exhausted" do
        context = described_class.new(adapter: :sidekiq, attempt: 26, max_retries: 25)
        expect(context.should_trigger_on_exception?(:only_exhausted)).to be true
      end
    end

    describe "with default (uses config)" do
      it "uses Axn.config.async_exception_reporting" do
        allow(Axn.config).to receive(:async_exception_reporting).and_return(:every_attempt)
        context = described_class.new(adapter: :sidekiq, attempt: 5, max_retries: 25)
        expect(context.should_trigger_on_exception?).to be true
      end
    end
  end

  describe "#to_h" do
    it "returns a hash representation" do
      context = described_class.new(
        adapter: :sidekiq,
        attempt: 3,
        max_retries: 25,
        job_id: "abc123",
      )

      expect(context.to_h).to eq({
                                   adapter: :sidekiq,
                                   attempt: 3,
                                   max_retries: 25,
                                   job_id: "abc123",
                                   first_attempt: false,
                                   retries_exhausted: false,
                                 })
    end

    it "omits nil job_id" do
      context = described_class.new(adapter: :sidekiq, attempt: 1, max_retries: 25)
      expect(context.to_h).not_to have_key(:job_id)
    end
  end
end

RSpec.describe Axn::Async::CurrentRetryContext do
  after do
    described_class.clear
  end

  describe ".current" do
    it "returns nil by default" do
      expect(described_class.current).to be_nil
    end
  end

  describe ".current=" do
    it "sets the current context" do
      context = Axn::Async::RetryContext.new(adapter: :sidekiq, attempt: 1, max_retries: 25)
      described_class.current = context
      expect(described_class.current).to eq(context)
    end
  end

  describe ".with" do
    it "sets context for the duration of the block" do
      context = Axn::Async::RetryContext.new(adapter: :sidekiq, attempt: 1, max_retries: 25)

      described_class.with(context) do
        expect(described_class.current).to eq(context)
      end
    end

    it "restores previous context after block" do
      original = Axn::Async::RetryContext.new(adapter: :active_job, attempt: 1, max_retries: 5)
      nested = Axn::Async::RetryContext.new(adapter: :sidekiq, attempt: 2, max_retries: 25)

      described_class.current = original

      described_class.with(nested) do
        expect(described_class.current).to eq(nested)
      end

      expect(described_class.current).to eq(original)
    end

    it "restores context even if block raises" do
      original = Axn::Async::RetryContext.new(adapter: :active_job, attempt: 1, max_retries: 5)
      nested = Axn::Async::RetryContext.new(adapter: :sidekiq, attempt: 2, max_retries: 25)

      described_class.current = original

      expect do
        described_class.with(nested) do
          raise "test error"
        end
      end.to raise_error("test error")

      expect(described_class.current).to eq(original)
    end
  end

  describe ".clear" do
    it "sets current to nil" do
      context = Axn::Async::RetryContext.new(adapter: :sidekiq, attempt: 1, max_retries: 25)
      described_class.current = context
      described_class.clear
      expect(described_class.current).to be_nil
    end
  end
end
