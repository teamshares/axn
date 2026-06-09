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
        "retry_count" => 4, # attempt 6 during execution
        "retry" => 5,       # max 5 retries
        "jid" => "ghi789",
      }

      context = described_class.build_retry_context(job)

      expect(context.attempt).to eq(6)
      expect(context.max_retries).to eq(5)
      expect(context.retries_exhausted?).to be true
    end

    # Sidekiq increments retry_count before calling death handlers, so the job hash
    # seen by the death handler has retry_count = last_execution_retry_count + 1.
    # from_death_handler: true corrects for this off-by-one.
    describe "from_death_handler: true" do
      context "with retry: 3 (4 total executions, Sidekiq sets retry_count = 3 before death handler)" do
        let(:job) { { "retry_count" => 3, "retry" => 3, "jid" => "abc" } }

        it "reports attempt 4, matching the actual final execution" do
          context = described_class.build_retry_context(job, from_death_handler: true)
          expect(context.attempt).to eq(4)
        end

        it "reports retries_exhausted: true" do
          context = described_class.build_retry_context(job, from_death_handler: true)
          expect(context.retries_exhausted?).to be true
        end

        it "without from_death_handler would incorrectly report attempt 5" do
          context = described_class.build_retry_context(job)
          expect(context.attempt).to eq(5)
        end
      end

      context "with retry: 0 (1 execution, Sidekiq sets retry_count = 0 before death handler)" do
        let(:job) { { "retry_count" => 0, "retry" => 0, "jid" => "def" } }

        it "reports attempt 1, matching the single actual execution" do
          context = described_class.build_retry_context(job, from_death_handler: true)
          expect(context.attempt).to eq(1)
        end
      end

      context "with retry: false / no retries (death handler called directly, retry_count absent)" do
        let(:job) { { "retry" => false, "jid" => "ghi" } }

        # When retry: false, Sidekiq calls death handlers directly without going through
        # process_retry, so retry_count is never set. No adjustment needed.
        it "reports attempt 1 (no adjustment since retry_count is nil)" do
          context = described_class.build_retry_context(job, from_death_handler: true)
          expect(context.attempt).to eq(1)
        end
      end

      context "attempt number across full retry: 3 lifecycle" do
        # Middleware path: retry_count reflects the running job's state
        it "middleware attempt 1 has retry_count absent (nil)" do
          expect(described_class.extract_attempt_number({})).to eq(1)
        end

        it "middleware attempt 2 has retry_count = 0" do
          expect(described_class.extract_attempt_number("retry_count" => 0)).to eq(2)
        end

        it "middleware attempt 3 has retry_count = 1" do
          expect(described_class.extract_attempt_number("retry_count" => 1)).to eq(3)
        end

        it "middleware attempt 4 (final) has retry_count = 2" do
          expect(described_class.extract_attempt_number("retry_count" => 2)).to eq(4)
        end

        # Death handler path: Sidekiq increments retry_count once more before calling handlers
        it "death handler after attempt 4 sees retry_count = 3, corrected to attempt 4" do
          job = { "retry_count" => 3, "retry" => 3 }
          context = described_class.build_retry_context(job, from_death_handler: true)
          expect(context.attempt).to eq(4)
          expect(context.retries_exhausted?).to be true
        end
      end
    end
  end
end
