# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

# RuboCop specs (separate from main specs to avoid loading RuboCop unnecessarily)
task :spec_rubocop do
  files = Dir.glob("spec_rubocop/**/*_spec.rb")
  sh "bundle exec rspec #{files.join(' ')}"
end

# Rails specs (separate from main specs to avoid loading Rails unnecessarily)
task :spec_rails do
  Dir.chdir("spec_rails/dummy_app") do
    sh "BUNDLE_GEMFILE=Gemfile bundle exec rspec spec/"
  end
end

require "rubocop/rake_task"

# RuboCop with Axn custom cops (targeting examples/rubocop directory)
task :rubocop_examples do
  sh "bundle exec rubocop --require axn/rubocop examples/rubocop/ || true"
end

# Default RuboCop task (runs on all files)
RuboCop::RakeTask.new

task default: %i[spec rubocop]
task rails_specs: %i[spec_rails]
task rubocop_specs: %i[spec_rubocop]
task all_specs: %i[spec spec_rubocop spec_rails]
task specs: %i[all_specs]

# Benchmark tasks
namespace :benchmark do
  desc "Run benchmarks and save results for current gem version (runs automatically after rake release)"
  task :release do
    require_relative "benchmark/support/benchmark_runner"
    require_relative "benchmark/support/storage"
    require_relative "lib/axn/version"
    require_relative "benchmark/support/colors"

    puts Colors.bold(Colors.info("🔬 Running benchmarks for release..."))
    puts Colors.dim("=" * 80)
    puts ""

    version = Axn::VERSION
    puts Colors.info("Version: #{version}")
    puts ""

    # Check if benchmark already exists for this version
    filename = Benchmark::Storage.benchmark_filename(version)
    if File.exist?(filename)
      puts Colors.error("❌ Benchmark file already exists for version #{version}")
      puts Colors.info("   File: #{filename}")
      puts Colors.info("   Delete the file if you want to regenerate benchmarks for this version.")
      abort
    end

    # Run benchmarks with verbose output
    data = Benchmark::BenchmarkRunner.run_all_scenarios(verbose: true)

    # Save benchmark data (filename already determined above)
    saved_filename = Benchmark::Storage.save_benchmark(data, version)
    puts ""
    puts Colors.success("✅ Benchmark data saved to: #{saved_filename}")

    # Update last release version
    Benchmark::Storage.set_last_release_version(version)
    puts Colors.success("✅ Last release version updated to: #{version}")
    puts ""
    puts Colors.dim("=" * 80)
  end

  desc "Compare current code performance against last release"
  task :compare do
    require_relative "benchmark/support/benchmark_runner"
    require_relative "benchmark/support/storage"
    require_relative "benchmark/support/comparison"
    require_relative "lib/axn/version"
    require_relative "benchmark/support/colors"

    puts Colors.bold(Colors.info("🔬 Comparing performance against last release..."))
    puts Colors.dim("=" * 80)
    puts ""

    # Get last release version
    last_release_version = Benchmark::Storage.get_last_release_version

    if last_release_version.nil?
      puts Colors.error("❌ No last release version found.")
      puts Colors.info("   Run 'rake benchmark:release' after a gem release to create a baseline.")
      exit 1
    end

    puts Colors.info("Last release version: #{last_release_version}")
    puts ""

    # Load baseline benchmark
    baseline_data = Benchmark::Storage.load_benchmark(last_release_version)

    if baseline_data.nil?
      puts Colors.error("❌ Benchmark data not found for version: #{last_release_version}")
      puts Colors.info("   Run 'rake benchmark:release' to create a baseline.")
      exit 1
    end

    puts Colors.info("Running benchmarks on current code...")
    puts ""

    # Run current benchmarks (quiet mode for cleaner output)
    current_data = Benchmark::BenchmarkRunner.run_all_scenarios(verbose: false)

    puts ""
    puts Colors.info("Comparing results...")
    puts ""

    # Compare and display
    comparison = Benchmark::Comparison.compare(baseline_data, current_data)
    puts Benchmark::Comparison.format_comparison(comparison)
  end
end

# Automatically run benchmark:release after rake release
Rake::Task["release"].enhance do
  require_relative "benchmark/support/colors"
  puts ""
  puts Colors.bold(Colors.info("🔬 Running benchmarks for released version..."))
  Rake::Task["benchmark:release"].reenable
  Rake::Task["benchmark:release"].invoke
end
