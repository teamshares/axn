# frozen_string_literal: true

# Shared examples for Rails async adapter behavioral contracts.
# These examples test adapter behavior with real Sidekiq/ActiveJob frameworks.
#
# Each adapter spec must provide:
#   let(:test_action)         # An action class configured with the adapter
#   let(:failing_action)      # An action class that raises an exception
#   let(:expected_log_message) # Regex matching the expected log message
#   let(:enqueue_job)         # Lambda to enqueue a job: ->(action, args) { action.call_async(**args) }
#   let(:perform_enqueued)    # Lambda to perform enqueued jobs (adapter-specific)
#
# Example usage:
#   it_behaves_like "async adapter rails execution"
#   it_behaves_like "async adapter rails delayed execution"

# Tests basic job execution behavior with real frameworks
RSpec.shared_examples "async adapter rails execution" do
  describe "job execution" do
    before do
      allow(Axn.config.logger).to receive(:info).and_call_original
    end

    it "executes jobs without error" do
      enqueue_job.call(test_action, { name: "World", age: 25 })
      expect { perform_enqueued.call }.not_to raise_error
    end

    it "logs action execution details" do
      enqueue_job.call(test_action, { name: "World", age: 25 })
      perform_enqueued.call
      expect(Axn.config.logger).to have_received(:info).with(expected_log_message)
    end

    it "re-raises unexpected exceptions" do
      enqueue_job.call(failing_action, { name: "Test" })
      expect { perform_enqueued.call }.to raise_error(StandardError, "Intentional failure")
    end
  end
end

# Tests _async delayed execution options with real durations
RSpec.shared_examples "async adapter rails delayed execution" do
  describe "_async config with symbol keys and durations" do
    context "with symbol keys" do
      it "accepts _async config with symbol keys for wait" do
        expect { enqueue_job.call(test_action, { name: "World", age: 25, _async: { wait: 3600 } }) }.not_to raise_error
      end

      it "accepts _async config with symbol keys for wait_until" do
        future_time = 1.hour.from_now
        expect { enqueue_job.call(test_action, { name: "World", age: 25, _async: { wait_until: future_time } }) }.not_to raise_error
      end
    end

    context "with ActiveSupport::Duration values" do
      it "accepts duration for wait option" do
        expect { enqueue_job.call(test_action, { name: "World", age: 25, _async: { wait: 5.minutes } }) }.not_to raise_error
      end

      it "accepts duration for wait option with symbol key" do
        expect { enqueue_job.call(test_action, { name: "World", age: 25, _async: { wait: 1.hour } }) }.not_to raise_error
      end
    end

    context "with both symbol keys and durations" do
      it "handles symbol keys with duration values" do
        expect { enqueue_job.call(test_action, { name: "World", age: 25, _async: { wait: 30.minutes } }) }.not_to raise_error
      end
    end
  end
end

# Tests per-class async_exception_reporting override behavior
RSpec.shared_examples "async adapter rails per-class exception reporting" do
  # This shared example tests that per-class async_exception_reporting overrides work correctly.
  # It requires:
  #   let(:action_with_only_exhausted) # An action with async_exception_reporting :only_exhausted
  #   let(:action_with_every_attempt)  # An action with async_exception_reporting :every_attempt
  #
  # Note: Full retry/exhaustion testing requires the integration verifiers,
  # as test mode adapters don't simulate real retry behavior.

  describe "per-class async_exception_reporting DSL" do
    it "action with :only_exhausted has the correct setting" do
      expect(action_with_only_exhausted._async_exception_reporting).to eq(:only_exhausted)
    end

    it "action with :every_attempt has the correct setting" do
      expect(action_with_every_attempt._async_exception_reporting).to eq(:every_attempt)
    end

    it "action without override has nil setting (uses global config)" do
      expect(test_action._async_exception_reporting).to be_nil
    end
  end
end
