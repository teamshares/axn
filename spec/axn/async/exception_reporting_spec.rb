# frozen_string_literal: true

require "axn/async/exception_reporting"

RSpec.describe Axn::Async::ExceptionReporting do
  let(:action_class) do
    build_axn do
      expects :name
    end
  end

  let(:exception) { StandardError.new("job failed") }
  let(:retry_context) do
    Axn::Async::RetryContext.new(
      adapter: :sidekiq,
      attempt: 26,
      max_retries: 25,
      job_id: "jid-123",
    )
  end
  let(:job_args) { { name: "test" } }

  describe ".trigger_on_exception" do
    it "calls Axn.config.on_exception with exception, proxy action, and context including async" do
      received = nil
      allow(Axn.config).to receive(:on_exception) do |e, action:, context:|
        received = { exception: e, action:, context: }
      end

      described_class.trigger_on_exception(
        exception:,
        action_class:,
        retry_context:,
        job_args:,
        extra_context: {},
        log_prefix: "test",
      )

      expect(received[:exception]).to eq(exception)
      expect(received[:action].class).to eq(action_class)
      expect(received[:action].result.error).to eq("job failed")
      expect(received[:context][:async]).to eq(
        adapter: :sidekiq,
        attempt: 26,
        max_retries: 25,
        job_id: "jid-123",
        first_attempt: false,
        retries_exhausted: true,
      )
    end

    it "merges extra_context async data into context[:async]" do
      received = nil
      allow(Axn.config).to receive(:on_exception) { |_e, context:, **| received = context }

      described_class.trigger_on_exception(
        exception:,
        action_class:,
        retry_context:,
        job_args: {},
        extra_context: { async: { discarded: true } },
      )

      expect(received[:async][:discarded]).to be true
      expect(received[:async][:adapter]).to eq(:sidekiq)
    end

    it "does not mutate extra_context" do
      allow(Axn.config).to receive(:on_exception)

      extra_context = { async: { discarded: true }, _job_metadata: { jid: "x" } }
      described_class.trigger_on_exception(
        exception:,
        action_class:,
        retry_context:,
        job_args: {},
        extra_context:,
      )

      expect(extra_context).to eq({ async: { discarded: true }, _job_metadata: { jid: "x" } })
    end

    it "includes other extra_context keys in context (excluding :async)" do
      received = nil
      allow(Axn.config).to receive(:on_exception) { |_e, context:, **| received = context }

      described_class.trigger_on_exception(
        exception:,
        action_class:,
        retry_context:,
        job_args: {},
        extra_context: { _job_metadata: { jid: "jid-456" } },
      )

      expect(received[:_job_metadata]).to eq({ jid: "jid-456" })
    end

    context "when the exception class matches a fails_on declaration (discard/death-handler path)" do
      # This helper is the discard path: it only fires after retries are exhausted or a job is
      # discarded. A `fails_on` exception settles as `outcome.failure?` and is never re-raised by
      # the adapter, so it never reaches here — anything that does is a genuine exhausted exception
      # or one that bypassed the executor (deserialization / proxy errors). It must report
      # regardless of `fails_on`, or a broad `fails_on StandardError` would drop the only report
      # for a real infra error.
      let(:action_class) do
        build_axn do
          expects :name
          fails_on StandardError
        end
      end

      it "still reports rather than letting fails_on suppress the only global report" do
        allow(Axn.config).to receive(:on_exception)

        described_class.trigger_on_exception(
          exception: StandardError.new("bypassed-executor infra error"),
          action_class:,
          retry_context:,
          job_args:,
          extra_context: {},
          log_prefix: "test",
        )

        expect(Axn.config).to have_received(:on_exception)
      end
    end
  end
end
