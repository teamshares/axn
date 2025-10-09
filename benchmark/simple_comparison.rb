# frozen_string_literal: true

require "bundler/setup"
require "benchmark/ips"
require "memory_profiler"

# Disable Axn logging for benchmarks
require_relative "../lib/axn"
Axn.configure do |c|
  c.logger = Logger.new(File::NULL)
end

require_relative "support/axn_scenarios"
require_relative "support/reporter"
require_relative "support/colors"

module Benchmark
  class AxnBaseline
    def self.run(markdown: false)
      puts Colors.bold(Colors.info("🚀 Running Axn Performance Baseline"))
      puts Colors.dim("=" * 50)

      # Reporter is a module with class methods

      # Run all basic scenarios
      puts "\n" + Colors.bold(Colors.highlight("📊 Basic Scenarios Performance"))
      puts Colors.dim("-" * 30)

      basic_results = {}
      AxnScenarios.basic_scenarios.each do |scenario_name|
        print Colors.info("Running #{scenario_name}...")
        benchmark_scenario(scenario_name)
        basic_results[scenario_name] = { status: "completed" }
        puts Colors.success(" ✓ completed")
      end

      # Run validation scenarios
      puts "\n" + Colors.bold(Colors.highlight("📊 Validation Scenarios Performance"))
      puts Colors.dim("-" * 30)

      AxnScenarios.validation_scenarios.each do |scenario_name|
        print Colors.info("Running #{scenario_name}...")
        benchmark_scenario(scenario_name)
        puts Colors.success(" ✓ completed")
      end

      # Run feature scenarios
      puts "\n" + Colors.bold(Colors.highlight("📊 Feature Scenarios Performance"))
      puts Colors.dim("-" * 30)

      AxnScenarios.feature_scenarios.each do |scenario_name|
        print Colors.info("Running #{scenario_name}...")
        benchmark_scenario(scenario_name)
        puts Colors.success(" ✓ completed")
      end

      # Run business scenarios
      puts "\n" + Colors.bold(Colors.highlight("📊 Business Scenarios Performance"))
      puts Colors.dim("-" * 30)

      AxnScenarios.business_scenarios.each do |scenario_name|
        print Colors.info("Running #{scenario_name}...")
        benchmark_scenario(scenario_name)
        puts Colors.success(" ✓ completed")
      end

      # Run complex scenarios
      puts "\n" + Colors.bold(Colors.highlight("📊 Complex Scenarios Performance"))
      puts Colors.dim("-" * 30)

      AxnScenarios.complex_scenarios.each do |scenario_name|
        print Colors.info("Running #{scenario_name}...")
        benchmark_scenario(scenario_name)
        puts Colors.success(" ✓ completed")
      end

      # Memory analysis for key scenarios
      puts "\n" + Colors.bold(Colors.highlight("💾 Memory Usage Analysis"))
      puts Colors.dim("-" * 30)

      memory_results = {}
      key_scenarios = %i[bare basic type_validation hooks error_handling complex]

      key_scenarios.each do |scenario_name|
        print Colors.info("Analyzing memory for #{scenario_name}...")
        memory_result = benchmark_memory(scenario_name)
        memory_results[scenario_name] = memory_result
        allocated = Colors.highlight(format_bytes(memory_result.total_allocated_memsize))
        retained = Colors.highlight(format_bytes(memory_result.total_retained_memsize))
        puts Colors.success(" ✓ #{allocated} allocated, #{retained} retained")
      end

      # Generate report if requested
      if markdown
        # TODO: Implement markdown report generation
        puts Colors.warning("Markdown report generation not yet implemented")
      end

      puts "\n" + Colors.success("✅ Axn baseline complete!")
    end

    private

    def self.benchmark_scenario(scenario_name)
      require "benchmark/ips"

      Benchmark.ips do |x|
        x.config(time: 3, warmup: 1)
        x.report(scenario_name.to_s) do
          AxnScenarios.run_scenario(scenario_name, **sample_data_for_scenario(scenario_name))
        end
      end
    end

    def self.benchmark_memory(scenario_name)
      require "memory_profiler"

      MemoryProfiler.report do
        100.times do
          AxnScenarios.run_scenario(scenario_name, **sample_data_for_scenario(scenario_name))
        end
      end
    end

    def self.sample_data_for_scenario(scenario_name)
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
      when :hooks
        { name: "John Doe", email: "john@example.com" }
      when :error_handling
        { name: "John Doe", email: "john@example.com", should_fail: false, error_type: nil }
      when :conditional_error
        { user_id: 123, action_type: "update" }
      when :composition
        { name: "John Doe", email: "john@example.com" }
      when :database
        { name: "John Doe", email: "john@example.com", simulate_delay: false }
      when :service_orchestration
        { user_id: 123, order_data: { amount: 99.99, items: %w[item1 item2] } }
      when :data_transformation
        { raw_data: [{ id: 1, name: "item1", value: 10 }, { id: 2, name: "item2", value: 20 }], transform_options: { multiplier: 1.5 } }
      when :complex
        { name: "John Doe", email: "john@example.com", should_fail: false, error_type: nil }
      when :nested
        { name: "John Doe", email: "john@example.com", nested_should_fail: false }
      else
        {}
      end
    end

    def self.format_bytes(bytes)
      return "#{bytes} bytes" if bytes < 1024
      return "#{(bytes / 1024.0).round(1)} KB" if bytes < 1024 * 1024

      "#{(bytes / (1024.0 * 1024)).round(1)} MB"
    end
  end
end

# Run if called directly
if __FILE__ == $0
  markdown = ARGV.include?("--markdown")
  Benchmark::AxnBaseline.run(markdown:)
end
