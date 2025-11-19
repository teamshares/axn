# frozen_string_literal: true

require "fileutils"
require "json"

module Benchmark
  module Storage
    REPORTS_DIR = "tmp/benchmark_reports"
    LAST_RELEASE_FILE = File.join(REPORTS_DIR, ".last_release")

    class << self
      def ensure_reports_directory
        FileUtils.mkdir_p(REPORTS_DIR)
      end

      def save_benchmark(data, version)
        ensure_reports_directory
        filename = benchmark_filename(version)
        File.write(filename, JSON.pretty_generate(data))
        filename
      end

      def load_benchmark(version)
        filename = benchmark_filename(version)
        return nil unless File.exist?(filename)

        JSON.parse(File.read(filename), symbolize_names: true)
      end

      def get_last_release_version
        return nil unless File.exist?(LAST_RELEASE_FILE)

        File.read(LAST_RELEASE_FILE).strip
      end

      def set_last_release_version(version)
        ensure_reports_directory
        File.write(LAST_RELEASE_FILE, version)
      end

      def benchmark_filename(version)
        version_with_prefix = version.start_with?("v") ? version : "v#{version}"
        File.join(REPORTS_DIR, "#{version_with_prefix}.json")
      end
    end
  end
end

