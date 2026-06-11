# frozen_string_literal: true

require_relative "colors"

module Benchmark
  module Comparison
    # Allocation regression threshold: object-count or byte increase >= this % = regression.
    # Allocations are deterministic (same code + same input = identical counts every run),
    # making this the only metric for which cross-session comparison is reliably valid.
    ALLOC_REGRESSION_PCT = 3.0

    # Improvement threshold: allocation drop >= this % = meaningful improvement.
    ALLOC_IMPROVEMENT_PCT = 3.0

    # Minimum IPS move to report at all (advisory only, never gates the release).
    # Deltas smaller than this — or smaller than the combined stddev noise band —
    # are classified as :noise and collapsed in the output.
    IPS_MIN_MOVE_PCT = 5.0

    class << self
      def compare(baseline_data, current_data)
        comparison = {
          baseline_version: baseline_data[:version],
          current_version: current_data[:version],
          baseline_ruby: baseline_data[:ruby_version],
          current_ruby: current_data[:ruby_version],
          baseline_platform: baseline_data[:platform],
          current_platform: current_data[:platform],
          env_match: env_match?(baseline_data, current_data),
          ips_changes: {},
          memory_changes: {},
        }

        # --- IPS (advisory) ---
        baseline_ips = baseline_data[:ips_results].each_with_object({}) do |result, hash|
          hash[result[:name]] = result
        end

        current_data[:ips_results].each do |current_result|
          baseline_result = baseline_ips[current_result[:name]]
          next unless baseline_result

          baseline_ips_value = baseline_result[:ips].to_f
          current_ips_value  = current_result[:ips].to_f
          change_percent     = calculate_percentage_change(baseline_ips_value, current_ips_value)

          # Combined stddev noise band: sqrt(b_sd² + c_sd²), floor at IPS_MIN_MOVE_PCT.
          b_sd    = baseline_result[:stddev].to_f
          c_sd    = current_result[:stddev].to_f
          noise   = Math.sqrt(b_sd**2 + c_sd**2)
          band    = [noise, IPS_MIN_MOVE_PCT].max
          status  = classify_ips(change_percent, band)

          comparison[:ips_changes][current_result[:name]] = {
            baseline: baseline_ips_value,
            current: current_ips_value,
            change_percent:,
            noise_band: band.round(1),
            faster: change_percent.positive?,
            status:,
          }
        end

        # --- Memory (the gate) ---
        # Normalize to string keys: JSON loaded with symbolize_names: true produces symbol
        # keys for nested hashes, but BenchmarkRunner builds memory_results with string keys.
        baseline_memory = baseline_data[:memory_results].transform_keys(&:to_s)
        current_data[:memory_results].each do |scenario_name, current_mem|
          baseline_mem = baseline_memory[scenario_name.to_s]
          next unless baseline_mem

          baseline_objects  = baseline_mem[:objects].to_f
          current_objects   = current_mem[:objects].to_f
          baseline_bytes    = baseline_mem[:allocated].to_f
          current_bytes     = current_mem[:allocated].to_f

          objects_pct = calculate_percentage_change(baseline_objects, current_objects)
          bytes_pct   = calculate_percentage_change(baseline_bytes, current_bytes)

          # Regression if EITHER metric crosses the threshold (objects is primary).
          status = classify_allocation(objects_pct, bytes_pct)

          comparison[:memory_changes][scenario_name] = {
            baseline_allocated: baseline_mem[:allocated],
            current_allocated:  current_mem[:allocated],
            baseline_retained:  baseline_mem[:retained],
            current_retained:   current_mem[:retained],
            baseline_objects:   baseline_mem[:objects],
            current_objects:    current_mem[:objects],
            objects_pct:,
            bytes_pct:,
            change_percent: bytes_pct,   # kept for backward compat with existing callers
            more_efficient: bytes_pct.negative?,
            status:,
          }
        end

        comparison
      end

      # Verdict-oriented report used by benchmark:check and benchmark:compare.
      # Returns a string; exits non-zero only when called via the gate (caller decides).
      def format_check_report(comparison_data)
        output = []
        env_match   = comparison_data[:env_match]
        b_ver       = comparison_data[:baseline_version]
        c_ver       = comparison_data[:current_version]
        b_ruby      = comparison_data[:baseline_ruby]
        c_ruby      = comparison_data[:current_ruby]
        b_platform  = comparison_data[:baseline_platform]
        c_platform  = comparison_data[:current_platform]

        # Header
        output << ""
        output << Colors.bold(Colors.info("📊 Benchmark regression check"))
        output << Colors.dim("=" * 72)
        output << "  #{Colors.info("Baseline:")} #{b_ver}  (Ruby #{b_ruby} / #{b_platform})"
        output << "  #{Colors.info("Current: ")} #{c_ver}  (Ruby #{RUBY_VERSION} / #{RUBY_PLATFORM})"

        unless env_match
          output << ""
          output << Colors.warning("  ⚠️  Ruby version or platform differs from baseline.")
          output << Colors.warning("     Allocation counts may vary for reasons unrelated to this code.")
          output << Colors.warning("     Allocation gate is ADVISORY ONLY for this comparison.")
        end
        output << ""

        # ── Allocation section (the gate) ──────────────────────────────────────
        output << Colors.bold("  🔬 Allocations (#{env_match ? "gate" : "advisory — env mismatch"})")
        output << Colors.dim("  " + "-" * 68)

        regressions  = comparison_data[:memory_changes].select { |_, c| c[:status] == :regression }
        improvements = comparison_data[:memory_changes].select { |_, c| c[:status] == :improvement }
        unchanged    = comparison_data[:memory_changes].select { |_, c| c[:status] == :unchanged }

        if regressions.any?
          # Sort worst-first by objects increase %
          sorted_regressions = regressions.sort_by { |_, c| -c[:objects_pct] }
          sorted_regressions.each do |name, c|
            obj_delta   = delta_str(c[:objects_pct], "obj")
            bytes_delta = delta_str(c[:bytes_pct],   "bytes")
            output << Colors.error("  🔴 #{Colors.bold(name)}")
            output << Colors.error("       objects: #{c[:baseline_objects]} → #{c[:current_objects]} (#{obj_delta})")
            output << Colors.error("       bytes:   #{format_bytes(c[:baseline_allocated])} → #{format_bytes(c[:current_allocated])} (#{bytes_delta})")
          end
        end

        if improvements.any?
          improvements.each do |name, c|
            obj_delta   = delta_str(c[:objects_pct], "obj")
            bytes_delta = delta_str(c[:bytes_pct],   "bytes")
            output << Colors.success("  📉 #{Colors.bold(name)}")
            output << Colors.success("       objects: #{c[:baseline_objects]} → #{c[:current_objects]} (#{obj_delta})")
            output << Colors.success("       bytes:   #{format_bytes(c[:baseline_allocated])} → #{format_bytes(c[:current_allocated])} (#{bytes_delta})")
          end
        end

        clean_count = unchanged.size + (regressions.any? ? 0 : 0)
        clean_count = unchanged.size + improvements.size
        # Summarise clean scenarios as one line
        if unchanged.size.positive? || (regressions.empty? && improvements.empty?)
          output << Colors.success("  ✅ no allocation regression in #{unchanged.size} scenario(s)")
        end
        output << ""

        # ── IPS section (advisory) ─────────────────────────────────────────────
        notable_ips = comparison_data[:ips_changes].reject { |_, c| c[:status] == :noise }
        output << Colors.bold("  ⏱  Timing — advisory (never gates the release)")
        output << Colors.dim("  " + "-" * 68)

        if notable_ips.any?
          notable_ips.sort_by { |_, c| c[:change_percent] }.each do |name, c|
            direction = c[:faster] ? "faster" : "slower"
            icon      = c[:faster] ? "📈" : "📉"
            color     = c[:faster] ? :success : :warning
            pct_str   = "#{c[:change_percent].abs.round(1)}% #{direction} (exceeds ±#{c[:noise_band]}% noise)"
            output << Colors.public_send(color, "  #{icon} #{Colors.bold(name)}: #{pct_str}")
            output << Colors.public_send(color, "       #{c[:baseline].round(1)} → #{c[:current].round(1)} i/s")
          end
        else
          output << Colors.dim("  ≈  all #{comparison_data[:ips_changes].size} scenarios within noise band")
        end

        noise_count = comparison_data[:ips_changes].size - notable_ips.size
        if notable_ips.any? && noise_count.positive?
          output << Colors.dim("  ≈  #{noise_count} other scenario(s) within noise band — not shown")
        end
        output << ""

        # ── Verdict ────────────────────────────────────────────────────────────
        output << Colors.dim("  " + "=" * 68)
        if regressions.empty? || !env_match
          verdict_detail = if !env_match && regressions.any?
            " (#{regressions.size} potential regression(s) — advisory only, env mismatch)"
          end
          output << Colors.bold(Colors.success("  VERDICT: ✅  no blocking allocation regressions#{verdict_detail}"))
        else
          output << Colors.bold(Colors.error("  VERDICT: 🔴  #{regressions.size} allocation regression(s) detected"))
          output << Colors.error("           Increase blocked — address before releasing.")
        end
        output << ""

        output.join("\n")
      end

      # Legacy formatter — kept for backward compatibility, still used by benchmark:compare
      # before it was upgraded to use format_check_report.
      def format_comparison(comparison_data)
        format_check_report(comparison_data)
      end

      def regression?(comparison_data)
        return false unless comparison_data[:env_match]

        comparison_data[:memory_changes].any? { |_, c| c[:status] == :regression }
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

      private

      def env_match?(baseline_data, current_data)
        baseline_data[:ruby_version] == current_data[:ruby_version] &&
          baseline_data[:platform] == current_data[:platform]
      end

      def classify_allocation(objects_pct, bytes_pct)
        if objects_pct >= ALLOC_REGRESSION_PCT || bytes_pct >= ALLOC_REGRESSION_PCT
          :regression
        elsif objects_pct <= -ALLOC_IMPROVEMENT_PCT || bytes_pct <= -ALLOC_IMPROVEMENT_PCT
          :improvement
        else
          :unchanged
        end
      end

      def classify_ips(change_percent, noise_band)
        if change_percent.abs <= noise_band
          :noise
        elsif change_percent.positive?
          :faster
        else
          :slower
        end
      end

      def delta_str(pct, unit)
        sign  = pct >= 0 ? "+" : ""
        "#{sign}#{pct.round(1)}% #{unit}"
      end
    end
  end
end
