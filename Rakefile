# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"
require "etc"

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
# it. A tag filter excludes EXAMPLES, not files, so a SERIAL lane still loads all 222 spec files (282
# top-level groups, measured) and the file-load-time strategy and tool-adapter registrations this suite
# depends on happen identically whichever lane you run.
#
# WORKERS LOAD ONLY THEIR OWN CHUNK. flatware splits the lane into one job of whole spec files per
# worker, so that load-everything property holds for a serial run and NOT for a parallel one — which is
# why `verify` (and so `rake release`) runs the serial suite, and why the serial tasks below are a
# supported way to run any lane, not a debugging curiosity.
#
# Two things make chunking safe enough to be the default everywhere else. First, splitting by whole
# FILE means a shared example group can never be separated from the group that includes it — the
# failure mode where `it_behaves_like` is assigned to one shard and its parent to another, running in
# neither and still reporting green, is unreachable when the file is the unit. Second, every parallel
# lane asserts that the workers' example counts sum to the single-process total, so a shard that goes
# missing is a hard failure rather than a smaller green number nobody reads.
#
# What chunking DOES change is which examples share a process, and therefore which run before which.
# The suite is order-independent (`--order random` and a reversed file order are both green, and
# spec_helper fails any example that leaks an axn nesting-stack frame), so that reordering is safe —
# but it is a property to keep, not an accident. A spec that depends on another file's side effect
# passes serially and fails only in whichever chunking happens to separate them.
SPEC_WORKERS = -> { Integer(ENV.fetch("AXN_SPEC_WORKERS", Etc.nprocessors)) }

# Runs one lane across cores, then proves nothing went missing in the split.
#
# The expectation is a `--dry-run` of the same lane in ONE process: it loads every spec file and
# enumerates without executing, which is the number the workers have to add up to. It costs ~1.8s and
# runs concurrently with the lane, so it finishes well inside the parallel run's shadow instead of
# being added to it. The actual count comes from the workers themselves (see
# `spec/support/parallel_example_counter.rb`) rather than from the runner's own summary line — a runner
# that lost a worker would report a self-consistent total either way, so a check derived from its
# arithmetic would agree with it exactly when it is wrong.
#
# Loaded here for the one constant naming the channel the workers report through, so the env var is
# spelled once rather than on both sides of the process boundary.
require_relative "spec/support/parallel_example_counter"

RUN_PARALLEL_LANE = lambda { |tag:, lane:|
  require "json"
  require "tmpdir"

  workers = SPEC_WORKERS.call

  Dir.mktmpdir("axn-spec-counts") do |dir|
    expectation = Thread.new do
      out = File.join(dir, "expected.json")
      # Its own status file: `--dry-run` records every example as passing in no time at all, which
      # would otherwise flatten the timings the next run balances on.
      env = { "AXN_RSPEC_STATUS_FILE" => File.join(dir, "dry_run_status") }
      next nil unless system(env, "bundle", "exec", "rspec", "--tag", tag, "--dry-run", "--format", "json", "--out", out)

      JSON.parse(File.read(out)).dig("summary", "example_count")
    end

    ran = system(
      {
        AxnParallelExampleCounter::COUNT_DIR_ENV => dir,
        "AXN_RSPEC_STATUS_FILE" => ".rspec_status.#{lane}",
      },
      "bundle", "exec", "flatware", "rspec", "--workers", workers.to_s, "--",
      "--tag", tag,
      "--require", "./spec/support/parallel_example_counter",
      "--format", "AxnParallelExampleCounter"
    )

    counts   = Dir[File.join(dir, "*.count")].map { |f| Integer(File.read(f)) }
    actual   = counts.sum
    expected = expectation.value

    # The reference count is the entire basis of the checks below, so failing to compute it is a hard
    # failure and never a warning: a lane nothing could verify must not be able to report success.
    # This is also the more fragile of the two runs, and fragile in a way that matters — it loads every
    # spec file into ONE process, which is exactly where an order-dependent load failure surfaces while
    # isolated worker shards stay green. Warning and carrying on would hand back a pass for the one
    # arrangement the guard exists to catch.
    abort(<<~MSG) if expected.nil?
      Could not compute the single-process example count for this lane — its dry run (above) failed.
      #{counts.size} worker(s) ran #{actual} example(s), but there is nothing to compare that against,
      so this run verified nothing. Re-run serially (`rake spec_serial` / `rake spec_slow_serial`).
    MSG

    # No worker reported at all: the runner never got as far as splitting the lane, so this is its own
    # failure rather than a sharding bug. Worth its own branch because flatware's Thor-based CLI exits
    # 0 on its own usage errors, which makes `ran` useless for catching it — without this, a runner
    # that never started reads as "sharding lost 7362 examples".
    abort(<<~MSG) if counts.empty? && expected.positive?
      The parallel spec runner produced no results at all — see its output above.
      This lane holds #{expected} example(s); none of them ran, so nothing was verified.
    MSG

    # Ahead of the pass/fail verdict deliberately: if the split lost examples, that verdict is not
    # trustworthy in either direction, so the sharding bug is the thing to report.
    abort(<<~MSG) if actual != expected
      Parallel sharding lost or duplicated examples.
        #{counts.size} worker(s) ran #{actual} example(s) (#{counts.sort.reverse.join(', ')})
        one process loads #{expected}
      Re-run this lane serially (`rake spec_serial` / `rake spec_slow_serial`) to get a trustworthy result.
    MSG

    exit(1) unless ran
  end
}

desc "The commit loop — everything not tagged :slow, across cores"
task(:spec) { RUN_PARALLEL_LANE.call(tag: "~slow", lane: "fast") }

desc "Run only the :slow specs (the cross-product probes and the gem-generator specs), across cores"
task(:spec_slow) { RUN_PARALLEL_LANE.call(tag: "slow", lane: "slow") }

desc "Run the whole library suite — both lanes"
task spec_full: %i[spec spec_slow]

# One process, every spec file loaded, defined order. `verify` runs these rather than the parallel
# lanes above, so the run that gates a release is the one where load-everything still holds.
desc "The commit loop in ONE process — the serial escape hatch when a parallel result looks wrong"
RSpec::Core::RakeTask.new(:spec_serial) do |t|
  t.rspec_opts = "--tag '~slow'"
end

desc "The :slow lane in ONE process"
RSpec::Core::RakeTask.new(:spec_slow_serial) do |t|
  t.rspec_opts = "--tag slow"
end

desc "Run the whole library suite in ONE process per lane — the load-everything, defined-order run"
task spec_full_serial: %i[spec_serial spec_slow_serial]

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

# `spec_full_serial`, not `spec_full`: this is the gate `rake release` runs (via build), and it is the
# one place the load-everything, defined-order run is worth the extra ~100s. CI runs the parallel lanes
# for the feedback, so a chunk-order regression that somehow survives both the count guard and the
# nesting-stack guard still cannot reach a released gem.
desc "Run all verification checks (specs, rubocop, async integration)"
task verify: %i[spec_full_serial spec_rubocop spec_rails rubocop verify_async] do
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
