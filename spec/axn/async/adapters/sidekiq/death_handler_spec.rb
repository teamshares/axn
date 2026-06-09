# frozen_string_literal: true

require "axn/async/adapters/sidekiq/death_handler"
require "axn/async/adapters/sidekiq/retry_helpers"
require "axn/async/exception_reporting"

RSpec.describe Axn::Async::Adapters::Sidekiq::DeathHandler do
  # Sidekiq calls death handlers after incrementing retry_count one final time.
  # For retry: 3 (4 total executions), Sidekiq sets retry_count = 3 before the death
  # handler fires, even though the last actual execution ran with retry_count = 2.

  let(:action_class) do
    klass = build_axn do
      def call
        raise "intentional failure"
      end
    end
    stub_const("TestAxnDeathHandlerAction", klass)
    klass
  end

  let(:exception) { RuntimeError.new("intentional failure") }

  def job_for(retry_count:, retry_opt:, jid: "test-jid")
    hash = {
      "class" => "TestAxnDeathHandlerAction",
      "args" => [{}],
      "retry" => retry_opt,
      "jid" => jid,
      "queue" => "default",
    }
    hash["retry_count"] = retry_count unless retry_count.nil?
    hash
  end

  before { action_class } # ensure stub_const fires

  describe ".call" do
    context "with :first_and_exhausted mode (default)" do
      before do
        allow(Axn.config).to receive(:async_exception_reporting).and_return(:first_and_exhausted)
      end

      it "reports attempt 4 (not 5) when retry: 3 job exhausts after 4 executions" do
        # Sidekiq sets retry_count = 3 before calling the death handler for a retry: 3 job.
        # Without the fix, this would incorrectly report attempt 5.
        captured_context = nil
        allow(Axn.config).to receive(:on_exception) do |_e, context:, **|
          captured_context = context
        end

        job = job_for(retry_count: 3, retry_opt: 3)
        described_class.call(job, exception)

        expect(captured_context).not_to be_nil
        expect(captured_context[:async][:attempt]).to eq(4)
        expect(captured_context[:async][:max_retries]).to eq(3)
        expect(captured_context[:async][:retries_exhausted]).to be true
      end

      it "does not double-report when job is discarded on first attempt (retry_count = 0)" do
        # retry: 0 → Sidekiq calls process_retry, sets retry_count = 0, count = 0 >= 0 → exhausted.
        # The corrected attempt is 1 (first_attempt? = true), so should_trigger_on_exception?
        # returns !first_attempt? = false, preventing a double-report with the middleware.
        on_exception_called = false
        allow(Axn.config).to receive(:on_exception) { on_exception_called = true }

        job = job_for(retry_count: 0, retry_opt: 0)
        described_class.call(job, exception)

        expect(on_exception_called).to be false
      end
    end

    context "with :every_attempt mode" do
      before do
        allow(Axn.config).to receive(:async_exception_reporting).and_return(:every_attempt)
      end

      it "returns early without reporting (every_attempt uses the middleware per-execution path)" do
        on_exception_called = false
        allow(Axn.config).to receive(:on_exception) { on_exception_called = true }

        job = job_for(retry_count: 3, retry_opt: 3)
        described_class.call(job, exception)

        expect(on_exception_called).to be false
      end
    end

    context "with :only_exhausted mode" do
      before do
        allow(Axn.config).to receive(:async_exception_reporting).and_return(:only_exhausted)
      end

      it "reports attempt 4 (not 5) when retry: 3 job exhausts" do
        captured_context = nil
        allow(Axn.config).to receive(:on_exception) do |_e, context:, **|
          captured_context = context
        end

        job = job_for(retry_count: 3, retry_opt: 3)
        described_class.call(job, exception)

        expect(captured_context).not_to be_nil
        expect(captured_context[:async][:attempt]).to eq(4)
        expect(captured_context[:async][:retries_exhausted]).to be true
      end
    end
  end
end
