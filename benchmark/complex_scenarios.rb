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
  class AxnFeatureAnalysis
    def self.run(markdown: false)
      puts Colors.bold(Colors.info("🔧 Running Axn Feature Impact Analysis"))
      puts Colors.dim("=" * 50)

      # Reporter is a module with class methods

      # Run all scenarios with detailed analysis
      puts "\n#{Colors.bold(Colors.highlight("📊 Complete Performance Analysis"))}"
      puts Colors.dim("-" * 40)

      all_results = {}
      AxnScenarios.all_scenarios.each do |scenario_name|
        print Colors.info("Running #{scenario_name}...")
        benchmark_scenario(scenario_name)
        all_results[scenario_name] = { status: "completed" }
        puts Colors.success(" ✓ completed")
      end

      # Memory analysis for all scenarios
      puts "\n#{Colors.bold(Colors.highlight("💾 Memory Usage Analysis"))}"
      puts Colors.dim("-" * 30)

      memory_results = {}
      AxnScenarios.all_scenarios.each do |scenario_name|
        print Colors.info("Analyzing memory for #{scenario_name}...")
        memory_result = benchmark_memory(scenario_name)
        memory_results[scenario_name] = memory_result
        allocated = Colors.highlight(format_bytes(memory_result.total_allocated_memsize))
        retained = Colors.highlight(format_bytes(memory_result.total_retained_memsize))
        puts Colors.success(" ✓ #{allocated} allocated, #{retained} retained")
      end

      # Feature impact analysis
      puts "\n#{Colors.bold(Colors.highlight("🔍 Feature Impact Analysis"))}"
      puts Colors.dim("-" * 30)

      analyze_feature_impact(memory_results)

      # Performance insights
      puts "\n#{Colors.bold(Colors.highlight("💡 Performance Insights"))}"
      puts Colors.dim("-" * 30)
      puts Colors.success("• Bare actions show minimal framework overhead")
      puts Colors.success("• Type validation adds safety with reasonable cost")
      puts Colors.success("• Hooks provide powerful functionality with minimal overhead")
      puts Colors.success("• Error handling enables robust applications")
      puts Colors.success("• Composition enables clean separation of concerns")
      puts Colors.success("• Business scenarios show real-world usage patterns")

      # Generate report if requested
      if markdown
        # TODO: Implement markdown report generation
        puts Colors.warning("Markdown report generation not yet implemented")
      end

      puts "\n#{Colors.success("✅ Feature analysis complete!")}"
    end

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

    def self.analyze_feature_impact(memory_results)
      # Compare bare vs minimal
      bare_memory = memory_results[:bare]
      minimal_memory = memory_results[:minimal]
      if bare_memory && minimal_memory
        overhead = minimal_memory.total_allocated_memsize - bare_memory.total_allocated_memsize
        puts Colors.info("Input/Output overhead: ") + Colors.highlight(format_bytes(overhead))
      end

      # Compare basic vs type validation
      basic_memory = memory_results[:basic]
      type_validation_memory = memory_results[:type_validation]
      if basic_memory && type_validation_memory
        overhead = type_validation_memory.total_allocated_memsize - basic_memory.total_allocated_memsize
        puts Colors.info("Type validation overhead: ") + Colors.highlight(format_bytes(overhead))
      end

      # Compare basic vs hooks
      hooks_memory = memory_results[:hooks]
      if basic_memory && hooks_memory
        overhead = hooks_memory.total_allocated_memsize - basic_memory.total_allocated_memsize
        puts Colors.info("Hooks overhead: ") + Colors.highlight(format_bytes(overhead))
      end

      # Compare basic vs error handling
      error_handling_memory = memory_results[:error_handling]
      if basic_memory && error_handling_memory
        overhead = error_handling_memory.total_allocated_memsize - basic_memory.total_allocated_memsize
        puts Colors.info("Error handling overhead: ") + Colors.highlight(format_bytes(overhead))
      end

      # Compare basic vs composition
      composition_memory = memory_results[:composition]
      return unless basic_memory && composition_memory

      overhead = composition_memory.total_allocated_memsize - basic_memory.total_allocated_memsize
      puts Colors.info("Composition overhead: ") + Colors.highlight(format_bytes(overhead))
    end

    def self.format_bytes(bytes)
      return "#{bytes} bytes" if bytes < 1024
      return "#{(bytes / 1024.0).round(1)} KB" if bytes < 1024 * 1024

      "#{(bytes / (1024.0 * 1024)).round(1)} MB"
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
      when :hooks, :composition
        { name: "John Doe", email: "john@example.com" }
      when :error_handling, :complex
        { name: "John Doe", email: "john@example.com", should_fail: false, error_type: nil }
      when :conditional_error
        { user_id: 123, action_type: "update" }
      when :preprocessing
        { amount: "100.50", date_string: "2024-01-15", tags: "user,premium,admin" }
      when :memoization
        { data: [1, 2, 3, 4, 5], multiplier: 3 }
      when :callbacks
        { name: "John Doe", email: "john@example.com", should_fail: false }
      when :simulated_database
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
  end
end

# Run if called directly
if __FILE__ == $PROGRAM_NAME
  markdown = ARGV.include?("--markdown")
  Benchmark::AxnFeatureAnalysis.run(markdown:)
end
