#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "time"

class BenchmarkReportComparator
  def self.compare_latest_with_baseline
    reports_dir = "tmp/benchmark_reports"
    return puts "No reports directory found" unless Dir.exist?(reports_dir)

    reports = Dir.glob(File.join(reports_dir, "benchmark_*.md"))
                 .sort_by { |f| File.mtime(f) }

    return puts "No benchmark reports found" if reports.empty?

    if reports.length < 2
      puts "Only one report found. Need at least 2 reports to compare."
      puts "Latest report: #{File.basename(reports.last)}"
      return
    end

    baseline = reports[-2]  # Second to last
    latest = reports.last   # Most recent

    puts "📊 Performance Comparison Report"
    puts "=" * 50
    puts "Baseline: #{File.basename(baseline)} (#{File.mtime(baseline).strftime("%Y-%m-%d %H:%M")})"
    puts "Latest:   #{File.basename(latest)} (#{File.mtime(latest).strftime("%Y-%m-%d %H:%M")})"
    puts

    compare_reports(baseline, latest)
  end

  def self.compare_reports(baseline_file, latest_file)
    baseline_data = parse_report(baseline_file)
    latest_data = parse_report(latest_file)

    puts "🚀 Speed Changes:"
    puts "-" * 30

    baseline_data[:speed].each do |action, baseline_ips|
      latest_ips = latest_data[:speed][action]
      next unless latest_ips

      change_percent = ((latest_ips - baseline_ips) / baseline_ips * 100).round(1)
      change_icon = change_percent > 0 ? "📈" : "📉"
      change_color = change_percent > 0 ? "faster" : "slower"

      puts "#{change_icon} #{action}: #{baseline_ips.round(0)} → #{latest_ips.round(0)} i/s (#{change_percent.abs}% #{change_color})"
    end

    puts "\n💾 Memory Changes:"
    puts "-" * 30

    baseline_data[:memory].each do |action, baseline_mem|
      latest_mem = latest_data[:memory][action]
      next unless latest_mem

      change_percent = ((latest_mem - baseline_mem) / baseline_mem * 100).round(1)
      change_icon = change_percent > 0 ? "📈" : "📉"
      change_color = change_percent > 0 ? "more" : "less"

      puts "#{change_icon} #{action}: #{format_bytes(baseline_mem)} → #{format_bytes(latest_mem)} (#{change_percent.abs}% #{change_color})"
    end

    puts "\n💡 Summary:"
    puts "-" * 20
    puts "• Positive changes (📈) indicate performance improvements"
    puts "• Negative changes (📉) indicate performance regressions"
    puts "• Look for significant changes (>10%) that might need investigation"
  end

  private

  def self.parse_report(file_path)
    content = File.read(file_path)

    # This is a simplified parser - you might want to make it more robust
    speed_data = {}
    memory_data = {}

    # Parse speed data from terminal output (this would need to be stored in the markdown)
    # For now, this is a placeholder - you'd need to enhance the reporter to store this data

    { speed: speed_data, memory: memory_data }
  end

  def self.format_bytes(bytes)
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
end

# Run if called directly
BenchmarkReportComparator.compare_latest_with_baseline if __FILE__ == $0
