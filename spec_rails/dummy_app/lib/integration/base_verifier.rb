# frozen_string_literal: true

module Integration
  # Simple ANSI color helpers
  module Colors
    module_function

    def green(text) = "\e[32m#{text}\e[0m"
    def red(text) = "\e[31m#{text}\e[0m"
    def bold(text) = "\e[1m#{text}\e[0m"
    def dim(text) = "\e[2m#{text}\e[0m"
  end

  # Base class for async integration verifiers.
  # Provides common utilities for running and verifying async jobs.
  class BaseVerifier
    class VerificationFailed < StandardError; end

    class << self
      def run!
        new.run!
      end
    end

    def run!
      setup
      run_verifications
      teardown
      report_results
    end

    private

    def setup
      @results = []
      @exception_reports = []
      # Access the instance variable directly (the custom callback), not the method
      @original_on_exception = Axn.config.instance_variable_get(:@on_exception)

      # Capture exception reports
      Axn.configure do |c|
        c.on_exception = proc do |exception, context:|
          @exception_reports << {
            exception:,
            context:,
            time: Time.now,
          }
          # Also call original if it was a custom proc
          @original_on_exception.call(exception, context:) if @original_on_exception.is_a?(Proc)
        end
      end

      puts "\n#{'=' * 60}"
      puts "#{self.class.name} - Starting"
      puts "=" * 60
    end

    def teardown
      # Restore original handler (may be nil)
      Axn.config.instance_variable_set(:@on_exception, @original_on_exception)
    end

    def run_verifications
      verification_scenarios.each do |scenario|
        run_scenario(scenario)
      end
    end

    def run_scenario(scenario)
      name = scenario[:name]
      print "\n  #{name}... "

      begin
        @exception_reports.clear
        scenario[:setup]&.call
        scenario[:action].call
        wait_for_jobs(scenario[:wait] || 5)
        scenario[:verify].call(@exception_reports)
        @results << { name:, status: :passed }
        puts Colors.green("✓ PASSED")
      rescue StandardError => e
        @results << { name:, status: :failed, error: e.message }
        puts Colors.red("✗ FAILED: #{e.message}")
      ensure
        scenario[:teardown]&.call
      end
    end

    def wait_for_jobs(seconds)
      # Subclasses should override for their specific backend
      sleep(seconds)
    end

    def report_results
      passed = @results.count { |r| r[:status] == :passed }
      failed = @results.count { |r| r[:status] == :failed }

      puts "\n#{'=' * 60}"
      puts "Results: #{Colors.green("#{passed} passed")}, #{failed.positive? ? Colors.red("#{failed} failed") : "#{failed} failed"}"
      puts "=" * 60

      if failed.positive?
        puts Colors.red("\nFailed scenarios:")
        @results.select { |r| r[:status] == :failed }.each do |r|
          puts Colors.red("  - #{r[:name]}: #{r[:error]}")
        end
        raise VerificationFailed, "#{failed} verification(s) failed"
      end

      puts Colors.green("\nAll verifications passed!")
    end

    def verification_scenarios
      raise NotImplementedError, "Subclasses must implement #verification_scenarios"
    end

    def assert(condition, message)
      raise message unless condition
    end

    def assert_equal(expected, actual, message = nil)
      return if expected == actual

      msg = message || "Expected #{expected.inspect}, got #{actual.inspect}"
      raise msg
    end

    def assert_exception_reported(reports, count: nil, exception_class: nil, message_match: nil)
      matching = reports.dup

      matching = matching.select { |r| r[:exception].is_a?(exception_class) } if exception_class

      matching = matching.select { |r| r[:exception].message.match?(message_match) } if message_match

      if count
        assert_equal count, matching.size, "Expected #{count} exception(s), got #{matching.size}"
      else
        assert matching.any?, "Expected at least one matching exception report"
      end

      matching
    end

    def assert_no_exception_reported(reports, exception_class: nil)
      matching = reports.dup

      matching = matching.select { |r| r[:exception].is_a?(exception_class) } if exception_class

      assert matching.empty?, "Expected no exceptions, got #{matching.size}: #{matching.map { |r| r[:exception].message }}"
    end

    def assert_context_includes(report, key, expected_value = nil)
      context = report[:context]
      assert context.key?(key), "Expected context to include #{key.inspect}, got: #{context.keys}"

      return unless expected_value

      actual = context[key]
      assert_equal expected_value, actual, "Expected context[#{key}] to be #{expected_value.inspect}, got #{actual.inspect}"
    end
  end
end
