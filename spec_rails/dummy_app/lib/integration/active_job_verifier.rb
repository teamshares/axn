# frozen_string_literal: true

require_relative "base_verifier"
require_relative "shared_scenarios"

module Integration
  class ActiveJobVerifier < BaseVerifier
    include SharedScenarios

    private

    def setup
      super
      configure_active_job!
      puts "  Adapter: active_job"
      puts "  ActiveJob backend: #{ActiveJob::Base.queue_adapter.class.name}"
    end

    def configure_active_job!
      # Use async adapter for real-ish testing without external dependencies
      # For true integration, could use Sidekiq adapter
      ActiveJob::Base.queue_adapter = :async
    end

    def wait_for_jobs(seconds)
      # Async adapter processes immediately but in threads
      sleep(seconds)
    end

    def verification_scenarios
      [
        scenario_fail_does_not_retry,
        scenario_every_attempt_mode,
        scenario_first_and_exhausted_mode,
        scenario_only_exhausted_mode,
        scenario_discard_on_triggers_on_exception,
        # Per-class override scenarios
        scenario_per_class_only_exhausted_in_active_job,
        scenario_per_class_every_attempt_in_active_job,
      ]
    end

    # Scenario: fail! should not cause retries or error reports
    def scenario_fail_does_not_retry
      {
        name: "fail! does not trigger on_exception",
        setup: lambda {
          Axn.configure { |c| c.async_exception_reporting = :every_attempt }
        },
        action: lambda {
          Actions::Integration::FailingWithFail.call_async(name: "test")
        },
        verify: lambda { |reports|
          # fail! should not trigger on_exception
          assert_no_exception_reported(reports, exception_class: Axn::Failure)
        },
      }
    end

    # Scenario: :every_attempt mode reports on every attempt
    def scenario_every_attempt_mode
      {
        name: ":every_attempt mode reports exception",
        setup: lambda {
          Axn.configure { |c| c.async_exception_reporting = :every_attempt }
        },
        action: lambda {
          Actions::Integration::FailingWithException.call_async(name: "test")
        },
        verify: lambda { |reports|
          # Should have reported
          assert_exception_reported(reports, message_match: /Intentional failure/)

          # Context should include async info with attempt
          report = reports.first
          assert_context_includes(report, :async)
          assert report[:context][:async][:attempt] == 1, "Expected attempt 1, got #{report[:context][:async][:attempt]}"
        },
      }
    end

    # Scenario: :first_and_exhausted reports on first attempt AND on discard
    def scenario_first_and_exhausted_mode
      {
        name: ":first_and_exhausted mode reports on first attempt",
        setup: lambda {
          Axn.configure { |c| c.async_exception_reporting = :first_and_exhausted }
        },
        action: lambda {
          Actions::Integration::FailingWithException.call_async(name: "test")
        },
        verify: lambda { |reports|
          # Should have reported on first attempt
          first_attempt = reports.find { |r| r[:context].dig(:async, :attempt) == 1 }
          assert first_attempt, "Expected report for first attempt"

          # Verify it's marked as first attempt
          assert first_attempt[:context][:async][:first_attempt], "Expected first_attempt: true"
        },
      }
    end

    # Scenario: :only_exhausted does NOT report on first attempt
    def scenario_only_exhausted_mode
      {
        name: ":only_exhausted mode does NOT report on first attempt",
        setup: lambda {
          Axn.configure { |c| c.async_exception_reporting = :only_exhausted }
        },
        action: lambda {
          Actions::Integration::FailingWithException.call_async(name: "test")
        },
        verify: lambda { |reports|
          # With :only_exhausted, the first attempt should NOT trigger on_exception
          # (only exhausted/discarded jobs should report)
          # Since async adapter doesn't retry, the job just fails without reporting
          first_attempt_reports = reports.select { |r| r[:context].dig(:async, :attempt) == 1 }

          # Should have no reports for attempt 1 (only exhausted should report)
          # BUT with async adapter there's no retry mechanism, so we just verify
          # the mode is respected by checking no reports OR only discarded reports
          non_discarded = first_attempt_reports.reject { |r| r[:context].dig(:async, :discarded) }
          assert non_discarded.empty?, "Expected no non-discarded reports for :only_exhausted mode, got #{non_discarded.size}"
        },
      }
    end

    # Scenario: discard_on triggers on_exception via after_discard (Rails 7.1+)
    def scenario_discard_on_triggers_on_exception
      {
        name: "discard_on triggers on_exception (Rails 7.1+)",
        setup: lambda {
          Axn.configure { |c| c.async_exception_reporting = :first_and_exhausted }
        },
        action: lambda {
          Actions::Integration::Discardable.call_async(name: "test")
        },
        verify: lambda { |reports|
          if ActiveJob::Base.respond_to?(:after_discard)
            # Rails 7.1+ - should have reported via after_discard
            assert_exception_reported(reports, exception_class: Actions::Integration::DiscardableError)

            # At least one should be marked as discarded
            discarded_report = reports.find { |r| r[:context].dig(:async, :discarded) }
            assert discarded_report, "Expected at least one report with discarded: true"
          else
            # Rails < 7.1 - no after_discard, may not report depending on config
            puts "(skipped - Rails < 7.1)"
          end
        },
      }
    end

    # ============================================================
    # Per-Class Override Scenarios (ActiveJob-specific)
    # ============================================================

    # Scenario: Per-class :only_exhausted override is respected
    # Note: ActiveJob's async adapter doesn't retry, so we test that the
    # per-class setting is applied correctly. Full retry testing requires
    # Sidekiq integration tests.
    def scenario_per_class_only_exhausted_in_active_job
      {
        name: "Per-class :only_exhausted setting is applied",
        setup: lambda {
          # Set global to :every_attempt, so we can verify per-class override works
          Axn.configure { |c| c.async_exception_reporting = :every_attempt }
        },
        action: lambda {
          Actions::Integration::FailingWithExceptionOnlyExhausted.call_async(name: "test")
        },
        verify: lambda { |reports|
          # With per-class :only_exhausted, the first attempt should NOT trigger on_exception
          # (even though global is :every_attempt)
          first_attempt_reports = reports.select do |r|
            r[:context].dig(:async, :attempt) == 1 &&
              !r[:context].dig(:async, :discarded)
          end

          # Should have no non-discarded reports for attempt 1
          assert first_attempt_reports.empty?,
                 "Expected no first-attempt reports for per-class :only_exhausted, got #{first_attempt_reports.size}"
        },
      }
    end

    # Scenario: Per-class :every_attempt override is respected
    def scenario_per_class_every_attempt_in_active_job
      {
        name: "Per-class :every_attempt setting is applied",
        setup: lambda {
          # Set global to :only_exhausted, so we can verify per-class override works
          Axn.configure { |c| c.async_exception_reporting = :only_exhausted }
        },
        action: lambda {
          Actions::Integration::FailingWithExceptionEveryAttempt.call_async(name: "test")
        },
        verify: lambda { |reports|
          # With per-class :every_attempt, the first attempt SHOULD trigger on_exception
          # (even though global is :only_exhausted)
          first_attempt_reports = reports.select do |r|
            r[:context].dig(:async, :attempt) == 1
          end

          # Should have at least one report for attempt 1
          assert first_attempt_reports.any?,
                 "Expected first-attempt report for per-class :every_attempt, got none"
        },
      }
    end
  end
end
