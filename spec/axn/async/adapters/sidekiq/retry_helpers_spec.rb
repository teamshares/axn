# frozen_string_literal: true

require "axn/async/adapters/sidekiq/retry_helpers"

RSpec.describe Axn::Async::Adapters::Sidekiq::RetryHelpers do
  describe ".extract_attempt_number" do
    it "returns 1 for first execution (nil retry_count)" do
      job = { "retry_count" => nil }
      expect(described_class.extract_attempt_number(job)).to eq(1)
    end

    it "returns 1 when retry_count key is missing" do
      job = {}
      expect(described_class.extract_attempt_number(job)).to eq(1)
    end

    it "returns 2 for first retry (retry_count = 0)" do
      job = { "retry_count" => 0 }
      expect(described_class.extract_attempt_number(job)).to eq(2)
    end

    it "returns 3 for second retry (retry_count = 1)" do
      job = { "retry_count" => 1 }
      expect(described_class.extract_attempt_number(job)).to eq(3)
    end

    it "returns correct attempt for higher retry counts" do
      job = { "retry_count" => 24 }
      expect(described_class.extract_attempt_number(job)).to eq(26)
    end
  end

  describe ".extract_max_retries" do
    it "returns 0 when retry is false" do
      job = { "retry" => false }
      expect(described_class.extract_max_retries(job)).to eq(0)
    end

    it "returns the integer value when retry is an integer" do
      job = { "retry" => 5 }
      expect(described_class.extract_max_retries(job)).to eq(5)
    end

    it "returns Sidekiq default when retry is true" do
      job = { "retry" => true }
      expect(described_class.extract_max_retries(job)).to eq(25)
    end

    it "returns Sidekiq default when retry is nil" do
      job = { "retry" => nil }
      expect(described_class.extract_max_retries(job)).to eq(25)
    end

    it "uses async_max_retries config when set and retry is true" do
      allow(Axn.config).to receive(:async_max_retries).and_return(10)
      job = { "retry" => true }
      expect(described_class.extract_max_retries(job)).to eq(10)
    end

    it "prefers explicit integer over config" do
      allow(Axn.config).to receive(:async_max_retries).and_return(10)
      job = { "retry" => 3 }
      expect(described_class.extract_max_retries(job)).to eq(3)
    end
  end

  describe ".build_retry_context" do
    it "builds a RetryContext with correct values" do
      job = {
        "retry_count" => 2,
        "retry" => 5,
        "jid" => "abc123",
      }

      context = described_class.build_retry_context(job)

      expect(context).to be_a(Axn::Async::RetryContext)
      expect(context.adapter).to eq(:sidekiq)
      expect(context.attempt).to eq(4) # retry_count 2 → attempt 4
      expect(context.max_retries).to eq(5)
      expect(context.job_id).to eq("abc123")
    end

    it "handles first execution (nil retry_count)" do
      job = {
        "retry" => true,
        "jid" => "def456",
      }

      context = described_class.build_retry_context(job)

      expect(context.attempt).to eq(1)
      expect(context.first_attempt?).to be true
    end

    it "correctly calculates retries_exhausted?" do
      job = {
        "retry_count" => 4, # attempt 6
        "retry" => 5,       # max 5 retries
        "jid" => "ghi789",
      }

      context = described_class.build_retry_context(job)

      expect(context.attempt).to eq(6)
      expect(context.max_retries).to eq(5)
      expect(context.retries_exhausted?).to be true
    end
  end
end
