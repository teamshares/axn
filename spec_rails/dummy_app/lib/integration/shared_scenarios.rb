# frozen_string_literal: true

module Integration
  # Shared verification scenarios that all async adapters must pass.
  # These scenarios test real background job processing behavior with actual
  # retries, death handlers, and exception reporting.
  #
  # Each verifier should include this module and use the scenarios in their
  # verification_scenarios method.
  module SharedScenarios
    # ============================================================
    # Core Exception Handling Scenarios
    # ============================================================

    # Scenario: fail! should not cause retries or trigger on_exception
    # This is a fundamental contract: Axn::Failure is a business decision, not an error.
    def scenario_fail_does_not_retry
      {
        name: "fail! does not cause retries or reports",
        setup: nil,
        action: -> { Actions::Integration::FailingWithFail.call_async(name: "test") },
        verify: lambda { |reports|
          # fail! should not trigger on_exception (no reports with Axn::Failure)
          failure_reports = reports.select { |r| exception_class_name(r) == "Axn::Failure" }
          assert failure_reports.empty?, "Expected no Axn::Failure reports, got #{failure_reports.size}"
        },
      }
    end

    # Scenario: Unexpected exceptions trigger on_exception with async context
    def scenario_exception_triggers_on_exception
      {
        name: "Unexpected exceptions trigger on_exception",
        setup: nil,
        action: -> { Actions::Integration::FailingWithException.call_async(name: "test") },
        verify: lambda { |reports|
          # Should have reported at least once
          matching = reports.select { |r| exception_message(r)&.include?("Intentional failure") }
          assert matching.any?, "Expected at least one exception report with 'Intentional failure'"

          # Context should include async info
          report = matching.first
          async_context = report[:context]&.dig(:async) || report.dig(:context, "async")
          assert async_context, "Expected async info in context"
        },
      }
    end

    # Scenario: Retry context is properly tracked (attempt number, job_id, etc.)
    def scenario_retry_context_tracked
      {
        name: "Retry context includes attempt and job metadata",
        setup: nil,
        action: -> { Actions::Integration::FailingWithException.call_async(name: "test") },
        verify: lambda { |reports|
          assert reports.any?, "Expected at least one report"

          report = reports.first
          async_context = report[:context]&.dig(:async) || report.dig(:context, "async")
          assert async_context, "Expected async context"

          # Verify retry context fields (may be string or symbol keys)
          attempt = async_context[:attempt] || async_context["attempt"]
          assert attempt.is_a?(Integer), "Expected attempt to be an integer"
          assert attempt >= 1, "Expected attempt >= 1"

          max_retries = async_context[:max_retries] || async_context["max_retries"]
          assert max_retries.present?, "Expected max_retries in context"
        },
      }
    end

    # ============================================================
    # Per-Class Exception Reporting Override Scenarios
    # ============================================================

    # Scenario: Per-class :only_exhausted override is respected
    # This tests that the per-class async_exception_reporting setting works correctly.
    def scenario_per_class_only_exhausted_respected
      {
        name: "Per-class :only_exhausted override is respected",
        wait: 15,
        setup: nil,
        action: -> { Actions::Integration::FailingWithExceptionOnlyExhausted.call_async(name: "test") },
        verify: lambda { |reports|
          # With :only_exhausted, should only get 1 report (from exhaustion handler)
          # No reports from intermediate attempts
          matching = reports.select { |r| exception_message(r)&.include?("Intentional failure") }

          # Should have exactly 1 report (from death/discard handler)
          assert matching.size == 1,
                 "Expected exactly 1 report for per-class :only_exhausted, got #{matching.size}"

          # The report should be from exhaustion handler
          report = matching.first
          async_context = report[:context]&.dig(:async) || report.dig(:context, "async")
          retries_exhausted = async_context&.dig(:retries_exhausted) || async_context&.dig("retries_exhausted")
          assert retries_exhausted == true, "Expected retries_exhausted: true from exhaustion handler"
        },
      }
    end

    # Scenario: Per-class :every_attempt override is respected
    def scenario_per_class_every_attempt_respected
      {
        name: "Per-class :every_attempt override is respected",
        wait: 15,
        setup: nil,
        action: -> { Actions::Integration::FailingWithExceptionEveryAttempt.call_async(name: "test") },
        verify: lambda { |reports|
          # With :every_attempt, should get multiple reports (one per attempt + exhaustion)
          matching = reports.select { |r| exception_message(r)&.include?("Intentional failure") }

          # Should have at least 2 reports (multiple attempts)
          assert matching.size >= 2,
                 "Expected at least 2 reports for per-class :every_attempt, got #{matching.size}"

          # Verify we have different attempt numbers
          attempts = matching.map do |r|
            ctx = r[:context]&.dig(:async) || r.dig(:context, "async")
            ctx&.dig(:attempt) || ctx&.dig("attempt")
          end.compact.uniq

          assert attempts.size >= 2, "Expected reports from multiple attempts, got attempts: #{attempts}"
        },
      }
    end

    # ============================================================
    # Helper Methods
    # ============================================================

    # Get all core scenarios that all adapters must pass
    def core_scenarios
      [
        scenario_fail_does_not_retry,
        scenario_exception_triggers_on_exception,
        scenario_retry_context_tracked,
      ]
    end

    # Get per-class override scenarios
    def per_class_override_scenarios
      [
        scenario_per_class_only_exhausted_respected,
        scenario_per_class_every_attempt_respected,
      ]
    end

    private

    # Helper to get exception class name from report (handles different serialization formats)
    def exception_class_name(report)
      report[:exception_class] || report["exception_class"] ||
        report[:exception]&.class&.name
    end

    # Helper to get exception message from report (handles different serialization formats)
    def exception_message(report)
      report[:message] || report["message"] ||
        report[:exception]&.message
    end
  end
end
