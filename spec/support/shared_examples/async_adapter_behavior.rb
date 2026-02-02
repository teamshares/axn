# frozen_string_literal: true

require_relative "async_adapter_contracts"

# Shared examples for async adapter behavioral contracts.
# These examples test that all adapters implement the same behavioral semantics.
#
# Each adapter spec must provide the following let blocks:
#
#   let(:adapter_name) { :sidekiq }  # or :active_job
#   let(:setup_framework_mocks) { -> { ... } }  # Lambda to set up framework mocks
#   let(:build_action) { ->(block) { ... } }  # Lambda that builds an action with async configured
#   let(:get_worker) { ->(action_class) { ... } }  # Lambda to get worker/proxy instance
#   let(:perform_job) { ->(worker, args) { ... } }  # Lambda to call perform with args
#
# Example usage in sidekiq_spec.rb:
#   it_behaves_like "async adapter exception handling"
#   it_behaves_like "async adapter per-class exception reporting"

# Tests exception handling behavior (Contracts: EXCEPTION_HANDLING)
RSpec.shared_examples "async adapter exception handling" do
  # Required let blocks: setup_framework_mocks, build_action, get_worker, perform_job

  let(:successful_action) do
    setup_framework_mocks.call
    build_action.call(proc do
      expects :value
      exposes :result_value

      def call
        expose result_value: value * 2
      end
    end)
  end

  let(:failing_action) do
    setup_framework_mocks.call
    build_action.call(proc do
      expects :should_fail

      def call
        fail! "Business logic failure" if should_fail
      end
    end)
  end

  let(:exception_action) do
    setup_framework_mocks.call
    build_action.call(proc do
      def call
        raise "Unexpected error"
      end
    end)
  end

  describe "exception handling" do
    it "returns result on success" do
      worker = get_worker.call(successful_action)
      result = perform_job.call(worker, { value: 5 })

      expect(result).to be_ok
      expect(result.result_value).to eq(10)
    end

    it "does not raise on Axn::Failure (business logic failure)" do
      worker = get_worker.call(failing_action)

      # Should NOT raise - Axn::Failure is a business decision, not a transient error
      expect { perform_job.call(worker, { should_fail: true }) }.not_to raise_error

      # But the result should indicate failure
      result = perform_job.call(worker, { should_fail: true })
      expect(result.outcome).to be_failure
      expect(result.exception).to be_a(Axn::Failure)
    end

    it "re-raises unexpected exceptions for retry" do
      worker = get_worker.call(exception_action)

      # Should raise - unexpected errors should trigger retries
      expect { perform_job.call(worker, {}) }.to raise_error(RuntimeError, "Unexpected error")
    end
  end
end

# Tests per-class async_exception_reporting override (Contracts: PER_CLASS_OVERRIDE)
RSpec.shared_examples "async adapter per-class exception reporting" do
  # Required let blocks: setup_framework_mocks, build_action, get_worker, perform_job

  describe "per-class async_exception_reporting override" do
    let(:retry_context) do
      Axn::Async::RetryContext.new(adapter: adapter_name, attempt: 5, max_retries: 25)
    end

    around do |example|
      # Set up the retry context for the duration of the example
      Axn::Async::CurrentRetryContext.with(retry_context) do
        example.run
      end
    end

    context "when action has per-class override :only_exhausted" do
      let(:action_with_override) do
        setup_framework_mocks.call
        build_action.call(proc do
          async_exception_reporting :only_exhausted

          def call
            raise "Test error"
          end
        end)
      end

      it "does not trigger on_exception on intermediate attempts (respects per-class override)" do
        # Global config is :every_attempt, but per-class is :only_exhausted
        allow(Axn.config).to receive(:async_exception_reporting).and_return(:every_attempt)

        on_exception_called = false
        original_on_exception = Axn.config.method(:on_exception)
        allow(Axn.config).to receive(:on_exception) do |*args, **kwargs|
          on_exception_called = true
          original_on_exception.call(*args, **kwargs)
        end

        worker = get_worker.call(action_with_override)
        # Job will raise, but on_exception should NOT be called due to per-class override
        expect { perform_job.call(worker, {}) }.to raise_error(RuntimeError)

        expect(on_exception_called).to be false
      end
    end

    context "when action has per-class override :every_attempt" do
      let(:action_with_every_attempt) do
        setup_framework_mocks.call
        build_action.call(proc do
          async_exception_reporting :every_attempt

          def call
            raise "Test error"
          end
        end)
      end

      it "triggers on_exception on every attempt (respects per-class override)" do
        # Global config is :only_exhausted, but per-class is :every_attempt
        allow(Axn.config).to receive(:async_exception_reporting).and_return(:only_exhausted)

        on_exception_called = false
        original_on_exception = Axn.config.method(:on_exception)
        allow(Axn.config).to receive(:on_exception) do |*args, **kwargs|
          on_exception_called = true
          original_on_exception.call(*args, **kwargs)
        end

        worker = get_worker.call(action_with_every_attempt)
        expect { perform_job.call(worker, {}) }.to raise_error(RuntimeError)

        expect(on_exception_called).to be true
      end
    end

    context "when action has no per-class override" do
      let(:action_without_override) do
        setup_framework_mocks.call
        build_action.call(proc do
          def call
            raise "Test error"
          end
        end)
      end

      it "falls back to global config behavior" do
        # Global config is :only_exhausted - should NOT trigger on intermediate attempt
        allow(Axn.config).to receive(:async_exception_reporting).and_return(:only_exhausted)

        on_exception_called = false
        original_on_exception = Axn.config.method(:on_exception)
        allow(Axn.config).to receive(:on_exception) do |*args, **kwargs|
          on_exception_called = true
          original_on_exception.call(*args, **kwargs)
        end

        worker = get_worker.call(action_without_override)
        expect { perform_job.call(worker, {}) }.to raise_error(RuntimeError)

        expect(on_exception_called).to be false
      end
    end
  end
end

# Tests delayed execution with _async options (Contracts: DELAYED_EXECUTION)
# Note: This is adapter-specific in how it's called, so we test the kwargs extraction
# which is common across adapters. The actual perform_in/set(wait:) calls are adapter-specific.
RSpec.shared_examples "async adapter delayed execution options" do
  # Required let blocks: action_class (with async configured)
  # Note: This shared example tests the call_async behavior, not perform

  context "with delayed execution _async options" do
    it "passes through non-hash _async values as regular kwargs" do
      # When _async is not a hash, it should be passed through to the action
      # This is tested via the enqueue expectation in each adapter's specific tests
      # since the expectation setup differs between Sidekiq and ActiveJob
    end

    it "ignores empty _async hash (immediate execution)" do
      # Empty _async hash should result in immediate execution
      # This is tested via the enqueue expectation in each adapter's specific tests
    end
  end
end
