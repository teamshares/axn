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

    context "declared tag/dimension facets (PRO-2853)" do
      it "attaches input-derived facets to context[:tags]/[:dimensions], resolved from job_args" do
        action_class = build_axn do
          expects :company_id, type: Integer
          tag :company_id, -> { company_id }
          tag :region, "us5"
          dimension(:tier) { company_id > 10 ? "big" : "small" }
        end
        received = nil
        allow(Axn.config).to receive(:on_exception) { |_e, context:, **| received = context }

        described_class.trigger_on_exception(
          exception:, action_class:, retry_context:, job_args: { company_id: 42 }, extra_context: {},
        )

        expect(received[:tags]).to eq(company_id: 42, region: "us5")
        expect(received[:dimensions]).to eq(tier: "big")
      end

      it "omits the facet keys entirely when the action declares none" do
        received = nil
        allow(Axn.config).to receive(:on_exception) { |_e, context:, **| received = context }

        described_class.trigger_on_exception(
          exception:, action_class:, retry_context:, job_args:, extra_context: {},
        )

        expect(received).not_to have_key(:tags)
        expect(received).not_to have_key(:dimensions)
      end

      it "applies inbound defaults and preprocessing before resolving (matches what the worker saw)" do
        action_class = build_axn do
          expects :region, default: "us5"
          expects :name, preprocess: ->(v) { v.to_s.upcase }
          tag(:region) { region }
          tag(:name) { name }
        end
        received = nil
        allow(Axn.config).to receive(:on_exception) { |_e, context:, **| received = context }

        # region omitted from the job args → the default must still surface; name must be preprocessed.
        described_class.trigger_on_exception(
          exception:, action_class:, retry_context:, job_args: { name: "bob" }, extra_context: {},
        )

        expect(received[:tags]).to eq(region: "us5", name: "BOB")
      end

      it "skips an output-derived facet best-effort (no run happened) yet still reports" do
        action_class = build_axn do
          expects :company_id, type: Integer
          exposes :saved_id
          tag :company_id, -> { company_id }
          tag :saved_id, -> { saved_id } # output — unresolvable on the discard path
        end
        received = nil
        allow(Axn.config).to receive(:on_exception) { |_e, context:, **| received = context }

        described_class.trigger_on_exception(
          exception:, action_class:, retry_context:, job_args: { company_id: 7 }, extra_context: {},
        )

        expect(received[:tags]).to eq(company_id: 7)
      end

      it "deserializes job_args before rebuilding the instance (so GlobalID/model inputs restore)" do
        action_class = build_axn do
          expects :company
          tag(:company_id) { company.id }
        end
        # Sidekiq death-handler args are the serialized payload; the real value is restored by
        # AsyncSerialization.deserialize (keys re-stringified first for the fallback GID decoder).
        allow(Axn::Internal::AsyncSerialization).to receive(:deserialize)
          .with({ "company_as_global_id" => "gid://app/Company/42" })
          .and_return(company: double("Company", id: 42))
        received = nil
        allow(Axn.config).to receive(:on_exception) { |_e, context:, **| received = context }

        described_class.trigger_on_exception(
          exception:, action_class:, retry_context:,
          job_args: { company_as_global_id: "gid://app/Company/42" }, extra_context: {}
        )

        expect(received[:tags]).to eq(company_id: 42)
      end

      it "falls back to the raw args if deserialization raises (already-live ActiveJob discard args)" do
        action_class = build_axn do
          expects :company_id, type: Integer
          tag :company_id, -> { company_id }
        end
        allow(Axn::Internal::AsyncSerialization).to receive(:deserialize).and_raise("can only deserialize primitive arguments")
        received = nil
        allow(Axn.config).to receive(:on_exception) { |_e, context:, **| received = context }

        described_class.trigger_on_exception(
          exception:, action_class:, retry_context:, job_args: { company_id: 5 }, extra_context: {},
        )

        expect(received[:tags]).to eq(company_id: 5)
      end

      it "dups facet values so a reporter mutating one in place can't corrupt the shared literal" do
        action_class = build_axn do
          tag :region, +"us5" # mutable literal
        end
        allow(Axn.config).to receive(:on_exception) { |_e, context:, **| context[:tags][:region].upcase! }

        described_class.trigger_on_exception(
          exception:, action_class:, retry_context:, job_args: {}, extra_context: {},
        )

        # the class-level literal the resolver returns is untouched, so the next report is pristine
        expect(action_class._tags[:region]).to eq("us5")
      end

      it "still reports (without facet keys) if the action can't be reconstructed" do
        action_class = build_axn do
          expects :company_id
          tag :company_id, -> { company_id }
        end
        allow(action_class).to receive(:new).and_raise("cannot build")
        received = nil
        allow(Axn.config).to receive(:on_exception) { |_e, context:, **| received = context }

        described_class.trigger_on_exception(
          exception:, action_class:, retry_context:, job_args: { company_id: 1 }, extra_context: {},
        )

        expect(Axn.config).to have_received(:on_exception)
        expect(received).not_to have_key(:tags)
      end
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
