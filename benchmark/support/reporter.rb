# frozen_string_literal: true

require "fileutils"
require "time"

module Benchmark
  module Reporter
    class << self
      def format_ips_result(result)
        name = result.name
        ips = result.ips
        stddev = result.stddev_percentage
        iterations = result.iterations
        time = result.measurement.secs

        format("%-20s %10.1f i/s (±%.1f%%) i=%d in %.3fs", name, ips, stddev, iterations, time)
      end

      def format_memory_result(name, report)
        total_allocated = report.total_allocated_memsize
        total_retained = report.total_retained_memsize
        total_objects = report.total_allocated
        retained_objects = report.total_retained

        format("%-20s %10s allocated, %10s retained (%d objects, %d retained)",
               name,
               format_bytes(total_allocated),
               format_bytes(total_retained),
               total_objects,
               retained_objects)
      end

      def format_bytes(bytes)
        return "0 B" if bytes.zero?

        units = %w[B KB MB GB TB]
        size = bytes.to_f
        unit_index = 0

        while size >= 1024 && unit_index < units.length - 1
          size /= 1024
          unit_index += 1
        end

        format("%.1f %s", size, units[unit_index])
      end

      def generate_markdown_report(results, output_dir = "tmp/benchmark_reports")
        FileUtils.mkdir_p(output_dir)

        timestamp = Time.now.strftime("%Y-%m-%d_%H-%M-%S")
        filename = File.join(output_dir, "benchmark_#{timestamp}.md")

        File.open(filename, "w") do |file|
          file.puts "# Performance Benchmark Report"
          file.puts
          file.puts "**Generated:** #{Time.now.strftime("%Y-%m-%d %H:%M:%S")}"
          file.puts "**Ruby Version:** #{RUBY_VERSION}"
          file.puts "**Platform:** #{RUBY_PLATFORM}"
          file.puts "**Git Commit:** #{git_commit_info}"
          file.puts

          results.each do |section_name, section_results|
            file.puts "## #{section_name}"
            file.puts

            if section_results[:ips_results]
              file.puts "### Speed (Iterations per Second)"
              file.puts
              file.puts "| Action | IPS | Std Dev | Iterations | Time |"
              file.puts "|--------|-----|---------|------------|------|"

              section_results[:ips_results].each do |result|
                file.puts "| #{result.name} | #{format("%.1f",
                                                       result.ips)} | #{format("%.1f%%",
                                                                               result.stddev_percentage)} | #{result.iterations} | #{format("%.3fs",
                                                                                                                                            result.measurement.secs)} |"
              end
              file.puts
            end

            if section_results[:memory_results]
              file.puts "### Memory Usage"
              file.puts
              file.puts "| Action | Allocated | Retained | Objects | Retained Objects |"
              file.puts "|--------|-----------|----------|---------|------------------|"

              section_results[:memory_results].each do |name, report|
                file.puts "| #{name} | #{format_bytes(report.total_allocated_memsize)} | #{format_bytes(report.total_retained_memsize)} | #{report.total_allocated} | #{report.total_retained} |"
              end
              file.puts
            end

            next unless section_results[:comparison]

            file.puts "### Performance Comparison"
            file.puts
            file.puts section_results[:comparison]
            file.puts
          end
        end

        puts "📊 Markdown report generated: #{filename}"
        filename
      end

      def git_commit_info
        `git rev-parse --short HEAD 2>/dev/null`.strip
      rescue StandardError
        "unknown"
      end

      def print_terminal_results(results)
        puts "\n" + ("=" * 80)
        puts "PERFORMANCE BENCHMARK RESULTS"
        puts "=" * 80

        results.each do |section_name, section_results|
          puts "\n#{section_name.upcase}"
          puts "-" * section_name.length

          if section_results[:ips_results]
            puts "\nSpeed (Iterations per Second):"
            section_results[:ips_results].each do |result|
              puts "  #{format_ips_result(result)}"
            end
          end

          if section_results[:memory_results]
            puts "\nMemory Usage:"
            section_results[:memory_results].each do |name, report|
              puts "  #{format_memory_result(name, report)}"
            end
          end

          puts "\n#{section_results[:comparison]}" if section_results[:comparison]
        end

        puts "\n" + ("=" * 80)
      end

      def calculate_comparison_ratio(axn_result, interactor_result)
        return "N/A" if axn_result.nil? || interactor_result.nil?

        ratio = axn_result.ips / interactor_result.ips
        if ratio > 1
          format("Axn is %.1fx faster than Interactor", ratio)
        else
          format("Axn is %.1fx slower than Interactor", 1.0 / ratio)
        end
      end
    end
  end
end
