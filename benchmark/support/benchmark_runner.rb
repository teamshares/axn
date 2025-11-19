# frozen_string_literal: true

require "bundler/setup"
require "benchmark/ips"
require "memory_profiler"
require "json"
require "time"

# Disable Axn logging for benchmarks
require_relative "../../lib/axn"
Axn.configure do |c|
  c.logger = Logger.new(File::NULL)
end

require_relative "axn_scenarios"
require_relative "colors"

module Benchmark
  module BenchmarkRunner
    class << self
      def run_all_scenarios(verbose: true)
        ips_results = []
        memory_results = {}

        AxnScenarios.all_scenarios.each do |scenario_name|
          if verbose
            print Colors.info("Running #{scenario_name}...")
          end

          ips_result = benchmark_scenario(scenario_name, quiet: !verbose)
          stddev_percentage = ips_result.ips.positive? ? (ips_result.ips_sd / ips_result.ips * 100).round(2) : 0.0
          time_seconds = ips_result.ips.positive? ? (ips_result.iterations.to_f / ips_result.ips).round(3) : 0.0

          ips_results << {
            name: scenario_name.to_s,
            ips: ips_result.ips,
            stddev: stddev_percentage,
            iterations: ips_result.iterations,
            time: time_seconds,
          }

          if verbose
            puts Colors.success(" ✓ completed")
          end
        end

        if verbose
          puts "\n#{Colors.bold(Colors.highlight("💾 Memory Usage Analysis"))}"
          puts Colors.dim("-" * 40)
        end

        AxnScenarios.all_scenarios.each do |scenario_name|
          if verbose
            print Colors.info("Analyzing memory for #{scenario_name}...")
          end

          memory_result = benchmark_memory(scenario_name)
          memory_results[scenario_name.to_s] = {
            allocated: memory_result.total_allocated_memsize,
            retained: memory_result.total_retained_memsize,
            objects: memory_result.total_allocated,
            retained_objects: memory_result.total_retained,
          }

          if verbose
            allocated = Colors.highlight(format_bytes(memory_result.total_allocated_memsize))
            retained = Colors.highlight(format_bytes(memory_result.total_retained_memsize))
            puts Colors.success(" ✓ #{allocated} allocated, #{retained} retained")
          end
        end

        {
          version: Axn::VERSION,
          timestamp: Time.now.iso8601,
          git_commit: git_commit_info,
          ruby_version: RUBY_VERSION,
          platform: RUBY_PLATFORM,
          ips_results:,
          memory_results:,
        }
      end

      def benchmark_scenario(scenario_name, quiet: false)
        require "benchmark/ips"

        report = Benchmark.ips(quiet:) do |x|
          x.config(time: 3, warmup: 1)
          x.report(scenario_name.to_s) do
            AxnScenarios.run_scenario(scenario_name, **sample_data_for_scenario(scenario_name))
          end
        end

        # Extract the entry for this specific scenario
        report.entries.find { |e| e.label == scenario_name.to_s } || report.entries.first
      end

      def benchmark_memory(scenario_name)
        require "memory_profiler"

        MemoryProfiler.report do
          100.times do
            AxnScenarios.run_scenario(scenario_name, **sample_data_for_scenario(scenario_name))
          end
        end
      end

      def sample_data_for_scenario(scenario_name)
        case scenario_name
        when :bare
          {}
        when :minimal
          { name: "John Doe" }
        when :basic
          { name: "John Doe", email: "john@example.com" }
        when :type_validation
          { name: "John Doe", email: "john@example.com", age: 30, admin: true, tags: %w[user premium] }
        when :nested_validation
          { user: { name: "John Doe", email: "john@example.com", profile: { bio: "Software developer", avatar_url: "https://example.com/avatar.jpg" } } }
        when :hooks, :composition
          { name: "John Doe", email: "john@example.com" }
        when :error_handling, :complex
          { name: "John Doe", email: "john@example.com", should_fail: false, error_type: nil }
        when :conditional_error
          { user_id: 123, action_type: "update" }
        when :database
          { name: "John Doe", email: "john@example.com", simulate_delay: false }
        when :service_orchestration
          { user_id: 123, order_data: { amount: 99.99, items: %w[item1 item2] } }
        when :data_transformation
          { raw_data: [{ id: 1, name: "item1", value: 10 }, { id: 2, name: "item2", value: 20 }], transform_options: { multiplier: 1.5 } }
        when :nested
          { name: "John Doe", email: "john@example.com", nested_should_fail: false }
        else
          {}
        end
      end

      def format_bytes(bytes)
        return "#{bytes} bytes" if bytes < 1024
        return "#{(bytes / 1024.0).round(1)} KB" if bytes < 1024 * 1024

        "#{(bytes / (1024.0 * 1024)).round(1)} MB"
      end

      def git_commit_info
        `git rev-parse --short HEAD 2>/dev/null`.strip
      rescue StandardError
        "unknown"
      end
    end
  end
end

