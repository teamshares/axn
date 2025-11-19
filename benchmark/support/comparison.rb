# frozen_string_literal: true

require_relative "colors"

module Benchmark
  module Comparison
    class << self
      def compare(baseline_data, current_data)
        comparison = {
          baseline_version: baseline_data[:version],
          current_version: current_data[:version],
          ips_changes: {},
          memory_changes: {},
        }

        # Compare IPS results
        baseline_ips = baseline_data[:ips_results].each_with_object({}) do |result, hash|
          hash[result[:name]] = result
        end

        current_data[:ips_results].each do |current_result|
          baseline_result = baseline_ips[current_result[:name]]
          next unless baseline_result

          baseline_ips_value = baseline_result[:ips]
          current_ips_value = current_result[:ips]
          change_percent = calculate_percentage_change(baseline_ips_value, current_ips_value)

          comparison[:ips_changes][current_result[:name]] = {
            baseline: baseline_ips_value,
            current: current_ips_value,
            change_percent:,
            faster: change_percent.positive?,
          }
        end

        # Compare memory results
        baseline_memory = baseline_data[:memory_results]
        current_data[:memory_results].each do |scenario_name, current_mem|
          baseline_mem = baseline_memory[scenario_name]
          next unless baseline_mem

          baseline_allocated = baseline_mem[:allocated]
          current_allocated = current_mem[:allocated]
          change_percent = calculate_percentage_change(baseline_allocated, current_allocated)

          comparison[:memory_changes][scenario_name] = {
            baseline_allocated:,
            current_allocated:,
            baseline_retained: baseline_mem[:retained],
            current_retained: current_mem[:retained],
            change_percent:,
            more_efficient: change_percent.negative?, # Negative means less memory = better
          }
        end

        comparison
      end

      def format_comparison(comparison_data)
        output = []
        output << Colors.bold(Colors.info("📊 Performance Comparison"))
        output << Colors.dim("=" * 80)
        output << ""
        output << "#{Colors.info("Baseline:")} #{comparison_data[:baseline_version]}"
        output << "#{Colors.info("Current:")}  #{comparison_data[:current_version]}"
        output << ""

        # IPS Changes
        if comparison_data[:ips_changes].any?
          output << Colors.bold(Colors.highlight("🚀 Speed Changes (Iterations per Second)"))
          output << Colors.dim("-" * 80)

          comparison_data[:ips_changes].each do |scenario_name, change|
            baseline = change[:baseline]
            current = change[:current]
            change_percent = change[:change_percent]
            faster = change[:faster]

            icon = faster ? "📈" : "📉"
            color_method = faster ? :success : :warning
            direction = faster ? "faster" : "slower"

            change_text = "#{change_percent.abs.round(1)}% #{direction}"
            colored_change = Colors.public_send(color_method, change_text)

            output << "#{icon} #{Colors.bold(scenario_name)}:"
            output << "  #{baseline.round(1)} → #{current.round(1)} i/s (#{colored_change})"
          end
          output << ""
        end

        # Memory Changes
        if comparison_data[:memory_changes].any?
          output << Colors.bold(Colors.highlight("💾 Memory Changes"))
          output << Colors.dim("-" * 80)

          comparison_data[:memory_changes].each do |scenario_name, change|
            baseline_allocated = change[:baseline_allocated]
            current_allocated = change[:current_allocated]
            change_percent = change[:change_percent]
            more_efficient = change[:more_efficient]

            icon = more_efficient ? "📉" : "📈"
            color_method = more_efficient ? :success : :warning
            direction = more_efficient ? "less" : "more"

            change_text = "#{change_percent.abs.round(1)}% #{direction}"
            colored_change = Colors.public_send(color_method, change_text)

            output << "#{icon} #{Colors.bold(scenario_name)}:"
            output << "  Allocated: #{format_bytes(baseline_allocated)} → #{format_bytes(current_allocated)} (#{colored_change})"
          end
          output << ""
        end

        output << Colors.dim("=" * 80)
        output.join("\n")
      end

      def calculate_percentage_change(baseline, current)
        return 0.0 if baseline.zero?

        ((current - baseline) / baseline.to_f * 100).round(2)
      end

      def format_bytes(bytes)
        return "#{bytes} bytes" if bytes < 1024
        return "#{(bytes / 1024.0).round(1)} KB" if bytes < 1024 * 1024

        "#{(bytes / (1024.0 * 1024)).round(1)} MB"
      end
    end
  end
end

