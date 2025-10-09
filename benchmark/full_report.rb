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
  class FullReport
    def self.run(markdown: false)
      puts Colors.bold(Colors.info("🚀 Running Comprehensive Axn Performance Analysis"))
      puts Colors.dim("=" * 80)
      puts

      all_results = {}

      # 1. Axn Baseline Analysis
      puts Colors.bold(Colors.highlight("1️⃣ AXN BASELINE ANALYSIS"))
      puts Colors.dim("-" * 50)

      baseline_results = {}
      AxnScenarios.all_scenarios.each do |scenario_name|
        print Colors.info("Running #{scenario_name}...")
        benchmark_scenario(scenario_name)
        baseline_results[scenario_name] = { status: "completed" }
        puts Colors.success(" ✓ completed")
      end

      all_results["Baseline Performance"] = baseline_results

      # 2. Memory Analysis
      puts "\n#{Colors.bold(Colors.highlight("2️⃣ MEMORY USAGE ANALYSIS"))}"
      puts Colors.dim("-" * 40)

      memory_results = {}
      AxnScenarios.all_scenarios.each do |scenario_name|
        print Colors.info("Analyzing memory for #{scenario_name}...")
        memory_result = benchmark_memory(scenario_name)
        memory_results[scenario_name] = memory_result
        allocated = Colors.highlight(format_bytes(memory_result.total_allocated_memsize))
        retained = Colors.highlight(format_bytes(memory_result.total_retained_memsize))
        puts Colors.success(" ✓ #{allocated} allocated, #{retained} retained")
      end

      all_results["Memory Analysis"] = memory_results

      # 3. Feature Impact Analysis
      puts "\n#{Colors.bold(Colors.highlight("3️⃣ FEATURE IMPACT ANALYSIS"))}"
      puts Colors.dim("-" * 40)

      feature_impact = analyze_feature_impact(memory_results)
      all_results["Feature Impact"] = feature_impact

      # Generate markdown report if requested
      if markdown
        # TODO: Implement markdown report generation
        puts Colors.warning("Markdown report generation not yet implemented")
      end

      puts "\n#{Colors.dim("=" * 80)}"
      puts Colors.success("🏁 Comprehensive analysis complete!")
      puts Colors.dim("=" * 80)

      all_results
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
      impact = {}

      # Compare bare vs minimal
      bare_memory = memory_results[:bare]
      minimal_memory = memory_results[:minimal]
      if bare_memory && minimal_memory
        overhead = minimal_memory.total_allocated_memsize - bare_memory.total_allocated_memsize
        impact[:input_output_overhead] = {
          scenario: "bare → minimal",
          overhead:,
          percentage: calculate_percentage(overhead, bare_memory.total_allocated_memsize),
        }
        percentage = calculate_percentage(overhead, bare_memory.total_allocated_memsize)
        puts Colors.info("Input/Output overhead: ") +
             Colors.highlight("#{format_bytes(overhead)} (#{percentage}%)")
      end

      # Compare basic vs type validation
      basic_memory = memory_results[:basic]
      type_validation_memory = memory_results[:type_validation]
      if basic_memory && type_validation_memory
        overhead = type_validation_memory.total_allocated_memsize - basic_memory.total_allocated_memsize
        impact[:type_validation_overhead] = {
          scenario: "basic → type_validation",
          overhead:,
          percentage: calculate_percentage(overhead, basic_memory.total_allocated_memsize),
        }
        percentage = calculate_percentage(overhead, basic_memory.total_allocated_memsize)
        puts Colors.info("Type validation overhead: ") +
             Colors.highlight("#{format_bytes(overhead)} (#{percentage}%)")
      end

      # Compare basic vs hooks
      hooks_memory = memory_results[:hooks]
      if basic_memory && hooks_memory
        overhead = hooks_memory.total_allocated_memsize - basic_memory.total_allocated_memsize
        impact[:hooks_overhead] = {
          scenario: "basic → hooks",
          overhead:,
          percentage: calculate_percentage(overhead, basic_memory.total_allocated_memsize),
        }
        puts Colors.info("Hooks overhead: ") + Colors.highlight("#{format_bytes(overhead)} (#{calculate_percentage(overhead,
                                                                                                                   basic_memory.total_allocated_memsize)}%)")
      end

      # Compare basic vs error handling
      error_handling_memory = memory_results[:error_handling]
      if basic_memory && error_handling_memory
        overhead = error_handling_memory.total_allocated_memsize - basic_memory.total_allocated_memsize
        impact[:error_handling_overhead] = {
          scenario: "basic → error_handling",
          overhead:,
          percentage: calculate_percentage(overhead, basic_memory.total_allocated_memsize),
        }
        percentage = calculate_percentage(overhead, basic_memory.total_allocated_memsize)
        puts Colors.info("Error handling overhead: ") +
             Colors.highlight("#{format_bytes(overhead)} (#{percentage}%)")
      end

      # Compare basic vs composition
      composition_memory = memory_results[:composition]
      if basic_memory && composition_memory
        overhead = composition_memory.total_allocated_memsize - basic_memory.total_allocated_memsize
        impact[:composition_overhead] = {
          scenario: "basic → composition",
          overhead:,
          percentage: calculate_percentage(overhead, basic_memory.total_allocated_memsize),
        }
        percentage = calculate_percentage(overhead, basic_memory.total_allocated_memsize)
        puts Colors.info("Composition overhead: ") +
             Colors.highlight("#{format_bytes(overhead)} (#{percentage}%)")
      end

      impact
    end

    def self.format_bytes(bytes)
      return "#{bytes} bytes" if bytes < 1024
      return "#{(bytes / 1024.0).round(1)} KB" if bytes < 1024 * 1024

      "#{(bytes / (1024.0 * 1024)).round(1)} MB"
    end

    def self.calculate_percentage(overhead, baseline)
      return 0 if baseline.zero?

      (overhead.to_f / baseline * 100).round(1)
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
  end
end

# Run if called directly
if __FILE__ == $PROGRAM_NAME
  markdown = ARGV.include?("--markdown")
  Benchmark::FullReport.run(markdown:)
end
