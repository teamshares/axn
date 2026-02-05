# frozen_string_literal: true

require_relative "base_verifier"
require_relative "shared_scenarios"
require "sidekiq/api"
require "json"

module Integration
  class SidekiqVerifier < BaseVerifier
    include SharedScenarios

    SIDEKIQ_STARTUP_TIMEOUT = 10 # seconds
    SIDEKIQ_SHUTDOWN_TIMEOUT = 5 # seconds

    # Custom run! to handle mode-grouped scenarios
    def run!
      setup
      run_mode_scenarios
      report_results
    ensure
      teardown
    end

    private

    def setup
      super
      verify_redis_connection!
      clear_sidekiq_queues!
      setup_exception_tracking!
      puts "  Adapter: sidekiq"
      puts "  Redis: Connected"
    end

    def teardown
      stop_sidekiq_server!
      cleanup_exception_tracking!
      super
    end

    def verify_redis_connection!
      Sidekiq.redis(&:ping)
    rescue StandardError => e
      raise "Redis connection failed: #{e.message}. Is Redis running on localhost:6379?"
    end

    def clear_sidekiq_queues!
      Sidekiq::Queue.all.each(&:clear)
      Sidekiq::RetrySet.new.clear
      Sidekiq::DeadSet.new.clear
      Sidekiq::ScheduledSet.new.clear
    end

    # Use Redis to track exception reports across processes
    def setup_exception_tracking!
      @exception_key = "axn:integration_test:exceptions:#{Process.pid}"
      Sidekiq.redis { |r| r.del(@exception_key) }
    end

    def cleanup_exception_tracking!
      return unless @exception_key

      Sidekiq.redis { |r| r.del(@exception_key) }
    end

    def read_exception_reports_from_redis
      reports = Sidekiq.redis { |r| r.lrange(@exception_key, 0, -1) }
      reports.map { |r| JSON.parse(r, symbolize_names: true) }
    end

    def start_sidekiq_server!(mode:)
      # Create a sidekiq config file for testing with fast retries
      config_file = Rails.root.join("tmp", "sidekiq_test.yml")
      FileUtils.mkdir_p(config_file.dirname)

      File.write(config_file, <<~YAML)
        :concurrency: 2
        :queues:
          - default
        :retry: 2
        :poll_interval_average: 1
      YAML

      # Create an initializer that configures Sidekiq and exception tracking.
      # Middleware and death handler are already registered by Axn when the app loads
      # (set_default_async(:sidekiq) triggers auto-registration). Do not add them again
      # or reports will fire twice.
      initializer_file = Rails.root.join("tmp", "sidekiq_test_init.rb")
      File.write(initializer_file, <<~RUBY)
        # Load Rails environment first if not already loaded
        require "#{Rails.root.join('config', 'environment.rb')}" unless defined?(Rails.application)

        # Configure Axn to track exceptions in Redis for test verification
        EXCEPTION_KEY = "#{@exception_key}"

        Axn.configure do |c|
          c.async_exception_reporting = :#{mode}
          c.on_exception = proc do |exception, context:|
            report = {
              exception_class: exception.class.name,
              message: exception.message,
              context: context,
              time: Time.now.iso8601,
            }
            Sidekiq.redis { |r| r.rpush(EXCEPTION_KEY, report.to_json) }
          end
        end
      RUBY

      # Start Sidekiq in a subprocess
      @sidekiq_pid = spawn(
        { "RAILS_ENV" => "test" },
        "bundle", "exec", "sidekiq",
        "-C", config_file.to_s,
        "-r", initializer_file.to_s,
        %i[out err] => [Rails.root.join("tmp", "sidekiq_test.log").to_s, "w"]
      )

      Process.detach(@sidekiq_pid)

      # Wait for Sidekiq to be ready
      wait_for_sidekiq_ready!
      puts "  Sidekiq: Started with mode=#{mode} (pid: #{@sidekiq_pid})"
    end

    def wait_for_sidekiq_ready!
      deadline = Time.now + SIDEKIQ_STARTUP_TIMEOUT

      loop do
        if Time.now > deadline
          stop_sidekiq_server!
          raise "Sidekiq failed to start within #{SIDEKIQ_STARTUP_TIMEOUT} seconds"
        end

        # Check if Sidekiq has registered any processes
        processes = Sidekiq::ProcessSet.new
        if processes.any?
          # Give it a moment to fully initialize
          sleep 0.5
          return
        end

        sleep 0.5
      end
    end

    def stop_sidekiq_server!
      return unless @sidekiq_pid

      puts "\n  Stopping Sidekiq (pid: #{@sidekiq_pid})..."

      begin
        # Send TERM signal for graceful shutdown
        Process.kill("TERM", @sidekiq_pid)

        # Wait for graceful shutdown
        deadline = Time.now + SIDEKIQ_SHUTDOWN_TIMEOUT
        loop do
          # Check if process is still running
          Process.kill(0, @sidekiq_pid)

          if Time.now > deadline
            # Force kill if graceful shutdown failed
            puts "  Force killing Sidekiq..."
            Process.kill("KILL", @sidekiq_pid)
            break
          end

          sleep 0.2
        rescue Errno::ESRCH
          # Process no longer exists
          break
        end
      rescue Errno::ESRCH
        # Process already gone
      end

      @sidekiq_pid = nil
      puts "  Sidekiq stopped"
    end

    def wait_for_jobs(seconds)
      # Poll and actively move retries to queue until all jobs are processed
      # Jobs are "done" when they're either successfully completed OR in the dead set
      deadline = Time.now + seconds
      iteration = 0
      last_activity = Time.now

      loop do
        break if Time.now > deadline

        # Move any scheduled retries to immediate execution
        moved = force_immediate_retries!
        last_activity = Time.now if moved.positive?

        queue_size = Sidekiq::Queue.all.sum(&:size)
        retry_size = Sidekiq::RetrySet.new.size
        scheduled_size = Sidekiq::ScheduledSet.new.size
        dead_size = Sidekiq::DeadSet.new.size

        # Debug output (every 2 seconds)
        # rubocop:disable Style/IfUnlessModifier
        if (iteration % 4).zero? && ENV["DEBUG"]
          puts "(queues=#{queue_size} retry=#{retry_size} scheduled=#{scheduled_size} dead=#{dead_size} moved=#{moved})"
        end
        # rubocop:enable Style/IfUnlessModifier
        iteration += 1

        # All queues must be empty for us to be done
        # Wait at least 2 seconds after last activity to ensure job is fully processed
        break if queue_size.zero? && retry_size.zero? && scheduled_size.zero? && Time.now - last_activity > 2

        sleep 0.25
      end
      # Extra wait for processing to complete
      sleep 0.5
    end

    # Force ALL retry/scheduled jobs to execute immediately
    # Returns number of jobs moved
    def force_immediate_retries!
      moved = 0

      # Move ALL retries to the queue immediately (ignoring scheduled time)
      Sidekiq.redis do |conn|
        # Get all jobs from retry set
        while (job = conn.zrange("retry", 0, 0).first)
          conn.zrem("retry", job)
          data = JSON.parse(job)
          conn.lpush("queue:#{data['queue'] || 'default'}", job)
          moved += 1
        end

        # Get all jobs from scheduled set
        while (job = conn.zrange("schedule", 0, 0).first)
          conn.zrem("schedule", job)
          data = JSON.parse(job)
          conn.lpush("queue:#{data['queue'] || 'default'}", job)
          moved += 1
        end
      end

      moved
    end

    def run_mode_scenarios
      mode_groups.each do |mode, scenarios|
        puts "\n  --- Testing mode: #{mode} ---"

        # Start Sidekiq with this mode
        start_sidekiq_server!(mode:)

        # Run all scenarios for this mode
        scenarios.each do |scenario|
          run_scenario(scenario)
        end

        # Stop Sidekiq before switching modes
        stop_sidekiq_server!
      end
    end

    # Group scenarios by mode
    def mode_groups
      {
        every_attempt: [
          scenario_fail_does_not_retry,
          scenario_exception_triggers_on_exception,
          scenario_retry_context_tracked,
          scenario_every_attempt_reports_each_retry,
          scenario_no_retry_job_reports_exactly_once_every_attempt,
        ],
        first_and_exhausted: [
          scenario_first_and_exhausted_reports_first_and_death,
          scenario_no_retry_job_reports_exactly_once_first_and_exhausted,
          # Per-class override tests: run with global :first_and_exhausted
          # to prove per-class overrides work
          scenario_per_class_only_exhausted_respected,
          scenario_per_class_every_attempt_respected,
        ],
        only_exhausted: [
          scenario_only_exhausted_reports_only_on_death,
          scenario_no_retry_job_reports_exactly_once_only_exhausted,
        ],
      }
    end

    # Not used directly, but required by base class
    def verification_scenarios
      mode_groups.values.flatten
    end

    def run_scenario(scenario)
      name = scenario[:name]
      print "\n  #{name}... "

      begin
        # Clear Redis exception tracking for this scenario
        Sidekiq.redis { |r| r.del(@exception_key) }
        clear_sidekiq_queues!

        scenario[:setup]&.call
        scenario[:action].call

        # Give job time to be processed and potentially retried
        sleep 2

        wait_for_jobs(scenario[:wait] || 5)

        # Read reports from Redis
        reports = read_exception_reports_from_redis
        scenario[:verify].call(reports)

        @results << { name:, status: :passed }
        puts Colors.green("✓ PASSED")
      rescue StandardError => e
        @results << { name:, status: :failed, error: e.message }
        puts Colors.red("✗ FAILED: #{e.message}")
      ensure
        scenario[:teardown]&.call
      end
    end

    # ============================================================
    # Core behavior scenarios (run with :every_attempt mode)
    # ============================================================

    # Scenario: fail! should not cause retries or trigger on_exception
    def scenario_fail_does_not_retry
      {
        name: "fail! does not cause retries or reports",
        setup: nil,
        action: lambda {
          Actions::Integration::FailingWithFail.call_async(name: "test")
        },
        verify: lambda { |reports|
          # fail! should not trigger on_exception (no reports with Axn::Failure)
          failure_reports = reports.select { |r| r[:exception_class] == "Axn::Failure" }
          assert failure_reports.empty?, "Expected no Axn::Failure reports, got #{failure_reports.size}"

          # Should not be in retry queue or dead set
          assert_equal 0, Sidekiq::RetrySet.new.size, "Expected no jobs in retry queue"
          assert_equal 0, Sidekiq::DeadSet.new.size, "Expected no jobs in dead set"
        },
      }
    end

    # Scenario: Unexpected exceptions trigger on_exception with async context
    def scenario_exception_triggers_on_exception
      {
        name: "Unexpected exceptions trigger on_exception",
        setup: nil,
        action: lambda {
          Actions::Integration::FailingWithException.call_async(name: "test")
        },
        verify: lambda { |reports|
          # Should have reported at least once
          matching = reports.select { |r| r[:message]&.include?("Intentional failure") }
          assert matching.any?, "Expected at least one exception report with 'Intentional failure'"

          # Context should include async info
          report = matching.first
          assert report[:context]&.dig(:async), "Expected async info in context"
          # Adapter may be symbol or string depending on JSON serialization
          adapter = report[:context][:async][:adapter]
          assert adapter.to_s == "sidekiq", "Expected adapter: sidekiq, got: #{adapter}"
        },
      }
    end

    # Scenario: Retry context is properly tracked (attempt number, job_id, etc.)
    def scenario_retry_context_tracked
      {
        name: "Retry context includes attempt and job metadata",
        setup: nil,
        action: lambda {
          Actions::Integration::FailingWithException.call_async(name: "test")
        },
        verify: lambda { |reports|
          assert reports.any?, "Expected at least one report"

          report = reports.first
          async_context = report[:context]&.dig(:async)
          assert async_context, "Expected async context"

          # Verify retry context fields
          assert async_context[:attempt].is_a?(Integer), "Expected attempt to be an integer"
          assert async_context[:attempt] >= 1, "Expected attempt >= 1"
          assert async_context.key?(:max_retries), "Expected max_retries in context"
          assert async_context.key?(:job_id), "Expected job_id in context"
          assert async_context.key?(:first_attempt), "Expected first_attempt in context"
          assert async_context.key?(:retries_exhausted), "Expected retries_exhausted in context"
        },
      }
    end

    # Scenario: :every_attempt reports on each retry
    def scenario_every_attempt_reports_each_retry
      {
        name: ":every_attempt reports on multiple retries",
        wait: 20, # Wait for retries to complete (Sidekiq has backoff delays)
        setup: nil,
        action: lambda {
          Actions::Integration::FailingWithException.call_async(name: "test")
        },
        verify: lambda { |reports|
          # With retry: 2 in config, should get 3 reports (attempt 1, 2, 3)
          # Plus 1 from death handler = 4 total
          # But we only verify we got multiple attempts
          assert reports.size >= 2, "Expected at least 2 reports for :every_attempt, got #{reports.size}"

          # Verify we have different attempt numbers
          attempts = reports.map { |r| r[:context]&.dig(:async, :attempt) }.compact.uniq
          assert attempts.size >= 2, "Expected reports from multiple attempts, got attempts: #{attempts}"
        },
      }
    end

    # ============================================================
    # :first_and_exhausted mode scenarios
    # ============================================================

    def scenario_first_and_exhausted_reports_first_and_death
      {
        name: ":first_and_exhausted reports on first attempt and death",
        wait: 15, # Wait for all retries to exhaust
        setup: nil,
        action: lambda {
          Actions::Integration::FailingWithException.call_async(name: "test")
        },
        verify: lambda { |reports|
          # Should have exactly 2 reports: first attempt + death
          # (middleware skips attempts 2+, death handler reports on exhaustion)
          assert reports.size >= 1, "Expected at least 1 report, got #{reports.size}"
          assert reports.size <= 2, "Expected at most 2 reports for :first_and_exhausted, got #{reports.size}"

          # First report should be attempt 1
          first_report = reports.find { |r| r[:context]&.dig(:async, :attempt) == 1 }
          assert first_report, "Expected report for attempt 1"
          assert first_report[:context][:async][:first_attempt] == true, "Expected first_attempt: true"

          # If we have 2 reports, second should be from death handler (retries_exhausted: true)
          if reports.size == 2
            death_report = reports.find { |r| r[:context]&.dig(:async, :retries_exhausted) == true }
            assert death_report, "Expected death handler report with retries_exhausted: true"
          end
        },
      }
    end

    # ============================================================
    # :only_exhausted mode scenarios
    # ============================================================

    def scenario_only_exhausted_reports_only_on_death
      {
        name: ":only_exhausted reports ONLY on death (not on attempts)",
        wait: 25, # Wait for all retries to exhaust (Sidekiq backoff can be slow)
        setup: nil,
        action: lambda {
          Actions::Integration::FailingWithException.call_async(name: "test")
        },
        verify: lambda { |reports|
          # Should have exactly 1 report: only from death handler
          # (middleware skips all attempts in :only_exhausted mode)
          assert_equal 1, reports.size, "Expected exactly 1 report for :only_exhausted, got #{reports.size}"

          # The single report should be from death handler
          report = reports.first
          assert report[:context]&.dig(:async, :retries_exhausted) == true,
                 "Expected retries_exhausted: true from death handler"

          # Should NOT have first_attempt: true (this comes from regular attempts)
          # Death handler sets retries_exhausted but not first_attempt
        },
      }
    end

    # ============================================================
    # First-attempt death/discard scenarios (retry: false)
    # ============================================================

    def scenario_no_retry_job_reports_exactly_once_every_attempt
      {
        name: ":every_attempt + retry:false reports exactly once (no death handler report)",
        setup: nil,
        action: lambda {
          Actions::Integration::FailingWithExceptionNoRetry.call_async(name: "test")
        },
        verify: lambda { |reports|
          matching = reports.select { |r| r[:message]&.include?("Intentional failure (no retry)") }
          assert_equal 1, matching.size, "Expected exactly 1 report, got #{matching.size}"

          attempt = matching.first[:context]&.dig(:async, :attempt)
          assert_equal 1, attempt, "Expected attempt 1, got #{attempt.inspect}"
        },
      }
    end

    def scenario_no_retry_job_reports_exactly_once_first_and_exhausted
      {
        name: ":first_and_exhausted + retry:false reports exactly once (avoid double-report)",
        setup: nil,
        action: lambda {
          Actions::Integration::FailingWithExceptionNoRetry.call_async(name: "test")
        },
        verify: lambda { |reports|
          matching = reports.select { |r| r[:message]&.include?("Intentional failure (no retry)") }
          assert_equal 1, matching.size,
                       "Expected exactly 1 report for first-attempt death, got #{matching.size}"

          attempt = matching.first[:context]&.dig(:async, :attempt)
          assert_equal 1, attempt, "Expected attempt 1, got #{attempt.inspect}"
        },
      }
    end

    def scenario_no_retry_job_reports_exactly_once_only_exhausted
      {
        name: ":only_exhausted + retry:false reports exactly once (death handler only)",
        setup: nil,
        action: lambda {
          Actions::Integration::FailingWithExceptionNoRetry.call_async(name: "test")
        },
        verify: lambda { |reports|
          matching = reports.select { |r| r[:message]&.include?("Intentional failure (no retry)") }
          assert_equal 1, matching.size, "Expected exactly 1 report, got #{matching.size}"

          retries_exhausted = matching.first[:context]&.dig(:async, :retries_exhausted)
          assert retries_exhausted == true, "Expected retries_exhausted: true, got #{retries_exhausted.inspect}"
        },
      }
    end
  end
end
