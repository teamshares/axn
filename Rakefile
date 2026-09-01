# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

# The commit loop. CI, `verify` and `spec_full` run every example, so this lane is a LATENCY choice
# and never a coverage one — a `:slow` spec is deferred to merge time, not skipped. That is what makes
# the tag cheap to apply, and the question it asks is about the MISTAKE, not the spec:
#
#   Could you introduce this regression WITHOUT editing the thing under test? If yes, the loop has to
#   catch it, because nothing else will tell you before CI does. If no — you would have to be working
#   in that exact area, where you would run the file directly (unfiltered, by design) — defer it.
#
# So the slow lane holds the cross-product probes (exploratory nets over ground the fast lane already
# asserts case-by-case: `degenerate_literals_spec`, `unsatisfiable_size_interval_spec`,
# `container_position_validators_spec`, `schema_spec`), `spec/bin/` (audits the gem generator, which
# ships with no gem and cannot regress `lib/`), the strategy load-order specs, and the block that
# builds objects lying about their own class. Each is reachable only by editing its own subject.
#
# `standalone_require_spec` stays in the fast lane as the one deliberate exception, because a missing
# require is the mistake you make WHILE EDITING SOMETHING ELSE — add a constant reference, and the
# require lives in another file. `spec_helper` preloads axn, so nothing else here can see it, and the
# failure surfaces first in a downstream adapter gem's load path. Parallelising its probes took it
# from ~8s to ~3.5s, so it now costs the loop ~1.6s.
#
# Cost only ever triggers the question. A spec slow from a one-time eager-load does not qualify (the
# cost migrates to whichever example runs first), and one costly example among cheap ones does not
# make its group taggable — tag the narrowest block that carries the cost.
#
# Running the two lanes as separate processes is FASTER than one process running the same examples: a
# probe declares thousands of anonymous classes, which slows every example sharing its process after
# it. A tag filter excludes EXAMPLES, not files — both lanes still load all 226 spec files (283
# top-level groups, measured), so the file-load-time strategy and tool-adapter registrations this
# suite depends on happen identically whichever lane you run.
RSpec::Core::RakeTask.new(:spec) do |t|
  t.rspec_opts = "--tag '~slow'"
end

desc "Run only the :slow specs (the cross-product probes and the gem-generator specs) — ~2.5 min"
RSpec::Core::RakeTask.new(:spec_slow) do |t|
  t.rspec_opts = "--tag slow"
end

desc "Run the whole library suite — both lanes"
task spec_full: %i[spec spec_slow]

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
task all_specs: %i[spec_full spec_rubocop spec_rails]
task specs: %i[all_specs]

# Integration verification for async adapters (requires Redis for Sidekiq)
task :verify_async do
  Dir.chdir("spec_rails/dummy_app") do
    sh "BUNDLE_GEMFILE=Gemfile bundle exec rake async:verify:all"
  end
end

desc "Run all verification checks (specs, rubocop, async integration)"
task verify: %i[spec_full spec_rubocop spec_rails rubocop verify_async] do
  puts ""
  puts "=" * 60
  puts "✅ All verification checks passed!"
  puts "=" * 60
end

# Records the current tree's numbers as the baseline every later `benchmark:check` is compared against.
# Shared because two callers need different answers to "a snapshot for this version already exists":
#
#   :abort     — `benchmark:release` invoked by hand, where an existing snapshot means you are about to
#                lose a recorded baseline by accident.
#   :overwrite — `benchmark:accept`, where replacing it deliberately is the whole point.
#   :skip      — the tail of `rake release`, which must not fail a release whose gem is already pushed
#                just because `benchmark:accept` recorded this version's snapshot beforehand.
#
# Baselines live under the gitignored tmp/, so they are per-machine: a fresh clone has none and the
# gate no-ops rather than gating on numbers it cannot compare.
RECORD_BENCHMARK_BASELINE = lambda { |on_existing:, heading:|
  require_relative "benchmark/support/benchmark_runner"
  require_relative "benchmark/support/storage"
  require_relative "benchmark/support/colors"
  require_relative "lib/axn/version"

  puts Colors.bold(Colors.info("🔬 #{heading}"))
  puts Colors.dim("=" * 80)
  puts ""

  version = Axn::VERSION
  puts Colors.info("Version: #{version}")
  puts ""

  filename = Benchmark::Storage.benchmark_filename(version)
  if File.exist?(filename)
    case on_existing
    when :skip
      puts Colors.info("ℹ️  A baseline for #{version} is already recorded (#{filename}) — keeping it.")
      puts Colors.dim("=" * 80)
      return
    when :abort
      puts Colors.error("❌ Benchmark file already exists for version #{version}")
      puts Colors.info("   File: #{filename}")
      puts Colors.info("   Use `rake benchmark:accept` to replace it deliberately, or delete the file to regenerate.")
      abort
    end
  end

  data = Benchmark::BenchmarkRunner.run_all_scenarios(verbose: true)

  saved_filename = Benchmark::Storage.save_benchmark(data, version)
  puts ""
  puts Colors.success("✅ Benchmark data saved to: #{saved_filename}")

  Benchmark::Storage.set_last_release_version(version)
  puts Colors.success("✅ Last release version updated to: #{version}")
  puts ""
  puts Colors.dim("=" * 80)
}

# Benchmark tasks
namespace :benchmark do
  desc "Run benchmarks and save results for current gem version (runs automatically after rake release)"
  task :release do
    RECORD_BENCHMARK_BASELINE.call(on_existing: :abort, heading: "Running benchmarks for release...")
  end

  desc "Accept the current numbers as the release baseline — for a REVIEWED regression (replaces this version's snapshot)"
  task :accept do
    RECORD_BENCHMARK_BASELINE.call(
      on_existing: :overwrite,
      heading: "Recording the current numbers as the #{Axn::VERSION} baseline...",
    )
    puts Colors.info("   Every later run is now compared against these numbers. `rake benchmark:check` is green until")
    puts Colors.info("   something moves off them, so make sure the regression you just accepted is written down.")
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

    # Compare and display (informational — always exits 0)
    comparison = Benchmark::Comparison.compare(baseline_data, current_data)
    puts Benchmark::Comparison.format_check_report(comparison)
  end

  desc "Allocation regression gate — exits non-zero on regression (runs automatically before rake release)"
  task :check do
    require_relative "benchmark/support/benchmark_runner"
    require_relative "benchmark/support/storage"
    require_relative "benchmark/support/comparison"
    require_relative "lib/axn/version"
    require_relative "benchmark/support/colors"

    puts Colors.bold(Colors.info("🔬 Running allocation regression gate..."))
    puts Colors.dim("=" * 72)
    puts ""

    last_release_version = Benchmark::Storage.get_last_release_version
    baseline_data        = last_release_version && Benchmark::Storage.load_benchmark(last_release_version)

    if baseline_data.nil?
      puts Colors.warning("  ⚠️  No baseline available — skipping regression gate.")
      puts Colors.dim("     (Run 'rake benchmark:release' after a release to create a baseline.)")
      puts ""
      next # exit 0 — gate is a no-op on a fresh clone
    end

    puts Colors.info("  Baseline: #{last_release_version}")
    puts Colors.info("  Running benchmarks (this takes ~20s)...")
    puts ""

    current_data = Benchmark::BenchmarkRunner.run_all_scenarios(verbose: false)
    comparison   = Benchmark::Comparison.compare(baseline_data, current_data)
    puts Benchmark::Comparison.format_check_report(comparison)

    exit 1 if Benchmark::Comparison.regression?(comparison)
  end
end

# Require verify to pass before release. This relies on the default gem release task
# (from bundler/gem_tasks) depending on "build"; verify runs before build, so before push.
Rake::Task["build"].enhance([:verify])

# Run the allocation regression gate BEFORE the gem is pushed.
# Enhancing release:guard_clean (the first prerequisite of release) ensures
# benchmark:check runs before release:source_control_push and release:rubygem_push.
# benchmark:check exits 1 on regression, aborting the release before any push.
Rake::Task["release:guard_clean"].enhance([:"benchmark:check"])

# Automatically record the released version's snapshot after rake release (bumps .last_release too).
# `on_existing: :skip` rather than the by-hand task's abort: accepting a reviewed regression with
# `rake benchmark:accept` writes this version's snapshot BEFORE the release, and aborting here would
# fail the rake invocation with the gem already pushed and the tag already up.
Rake::Task["release"].enhance do
  puts ""
  RECORD_BENCHMARK_BASELINE.call(on_existing: :skip, heading: "Running benchmarks for released version...")
end

# Downstream gem compatibility check.
PARSE_AXN_REQUIREMENT = lambda { |gemspec_path|
  content = File.read(gemspec_path)
  # Match both `add_dependency` and the (deprecated but valid) `add_runtime_dependency` form, so a
  # sibling using either is still recognized as a downstream consumer.
  match = content.match(/add(?:_runtime)?_dependency\s+["']axn["']\s*,\s*(.+)$/)
  return nil unless match

  constraints = match[1].scan(/["']([^"']+)["']/).flatten
  Gem::Requirement.new(constraints)
}

# Discover downstream gems dynamically: any gem checked out as a sibling of this repo whose gemspec
# declares an `axn` runtime dependency. A newly generated gem (see bin/new-gem) is picked up
# automatically with no list to maintain. axn's own gemspec is excluded naturally (it doesn't depend
# on itself), and the check is a graceful no-op when the sibling layout isn't present (e.g. a git
# worktree), returning {}.
DISCOVER_DOWNSTREAM_GEMS = lambda {
  Dir[File.expand_path("../*/*.gemspec", __dir__)].each_with_object({}) do |path, gems|
    next unless PARSE_AXN_REQUIREMENT.call(path)

    gems[File.basename(path, ".gemspec")] = path
  end
}

namespace :downstream do
  desc "Check whether downstream gems support the current axn version"
  task :check do
    require "rubygems"
    require_relative "lib/axn/version"

    current_version = Gem::Version.new(Axn::VERSION)
    downstream_gems = DISCOVER_DOWNSTREAM_GEMS.call
    warnings = []

    puts "Downstream gem compatibility with axn #{current_version}:"
    puts ""
    puts "  (no sibling axn-consuming gems found next to this checkout)" if downstream_gems.empty?

    downstream_gems.each do |name, gemspec_path|
      requirement = PARSE_AXN_REQUIREMENT.call(gemspec_path)

      if requirement.satisfied_by?(current_version)
        puts "  #{name}: OK  (#{requirement})"
      else
        puts "  #{name}: NEEDS UPDATE  (#{requirement} excludes #{current_version})"
        warnings << "  - #{name}: update axn constraint (currently #{requirement}) to include #{current_version}"
      end
    end

    puts ""

    if warnings.any?
      puts "WARNING: These downstream gems need axn version constraint updates before"
      puts "         they can use axn #{current_version}:"
      warnings.each { |w| puts w }
    else
      puts "All downstream gems support axn #{current_version}."
    end
  end
end

# Warn (but don't block) about downstream gems that need updating before release
Rake::Task["release"].enhance do
  Rake::Task["downstream:check"].reenable
  Rake::Task["downstream:check"].invoke
end
