# frozen_string_literal: true

require "fileutils"

# Conformance auditor for existing axn-consuming gems (PRO-2949 follow-up). `bin/new-gem` scaffolds
# NEW gems conformant; this reports how far an EXISTING gem has drifted from the shared conventions,
# so gems built before the generator can be brought in line. Report-only (never mutates); #run
# returns false if any check fails, and the CLI exits non-zero, so it can gate CI.
#
# It audits only the genuinely-shared surface — byte-identical files reused from core (bin/refresh,
# lefthook.yml) plus structural markers (CI calls the reusable workflow, allowlist gemspec, lefthook
# wired, no leftover hand-rolled hook). It deliberately does NOT diff the whole scaffold: gemspec
# deps, README, and lib/ are meant to be gem-specific, so diffing them would be all false positives.
class GemConformance
  CORE_ROOT = File.expand_path("../..", __dir__)

  Result = Data.define(:label, :ok, :fix)

  def initialize(gem_dir, output: $stdout)
    @gem_dir = File.expand_path(gem_dir)
    @out = output
  end

  # Returns true iff every check passes.
  def run
    raise Error, "not a directory: #{@gem_dir}" unless File.directory?(@gem_dir)

    results = checks
    report(results)
    results.all?(&:ok)
  end

  class Error < StandardError; end

  private

  def checks
    [
      byte_identical("bin/refresh"),
      byte_identical("lefthook.yml"),
      file_includes("bin/setup", "lefthook install",
                    fix: "bin/setup should run `bundle exec lefthook install`"),
      path_absent(".githooks",
                  fix: "migrate the hand-rolled hook to lefthook: delete .githooks/ (bin/setup runs `lefthook install`)"),
      file_includes("Gemfile", 'gem "lefthook"',
                    fix: %(add `gem "lefthook"` to the Gemfile's dev dependencies)),
      file_includes(".rubocop.yml", "inherit_gem",
                    label: ".rubocop.yml inherits axn's config",
                    fix: %(use `inherit_gem: { axn: ".rubocop.yml" }` instead of a bespoke config)),
      ci_calls_reusable_workflow,
      path_absent(".github/workflows/main.yml",
                  fix: "delete the stray main.yml; CI is ci.yml calling the reusable workflow"),
      gemspec_uses_allowlist,
      path_present("internal-docs",
                   fix: "add internal-docs/ for working docs (superpowers plans/specs), excluded from the package"),
      file_includes(".github/renovate.json5", "teamshares/renovate-config",
                    label: "renovate extends the central preset",
                    fix: %(extend `["github>teamshares/renovate-config:lib.json5"]`)),
    ]
  end

  # --- check builders ----------------------------------------------------------------------------

  # Must exist and be byte-identical to core's copy (bin/refresh, lefthook.yml).
  def byte_identical(rel)
    label = "#{rel} matches core"
    canonical = File.join(CORE_ROOT, rel)
    target = File.join(@gem_dir, rel)
    return Result.new(label, false, "missing — copy it from core (#{rel})") unless File.exist?(target)

    ok = File.read(target) == File.read(canonical)
    Result.new(label, ok, ok ? nil : "drifts from core — re-copy #{rel} from the axn repo")
  end

  def file_includes(rel, substring, fix:, label: nil)
    label ||= "#{rel} contains #{substring.inspect}"
    target = File.join(@gem_dir, rel)
    return Result.new(label, false, "#{rel} is missing — #{fix}") unless File.exist?(target)

    Result.new(label, File.read(target).include?(substring), fix)
  end

  def path_absent(rel, fix:)
    Result.new("no #{rel}", !File.exist?(File.join(@gem_dir, rel)), fix)
  end

  def path_present(rel, fix:)
    Result.new("#{rel} present", File.exist?(File.join(@gem_dir, rel)), fix)
  end

  def ci_calls_reusable_workflow
    fix = "ci.yml should `uses: teamshares/axn/.github/workflows/gem-ci.yml@main`"
    file_includes(".github/workflows/ci.yml", "teamshares/axn/.github/workflows/gem-ci.yml",
                  label: "CI calls the reusable workflow", fix:)
  end

  def gemspec_uses_allowlist
    label = "gemspec uses an allowlist (not a denylist)"
    fix = "enumerate shipped paths via `git ls-files -z -- lib …` instead of `git ls-files | reject(...)`"
    gemspec = Dir[File.join(@gem_dir, "*.gemspec")].first
    return Result.new(label, false, "no .gemspec found") unless gemspec

    content = File.read(gemspec)
    ok = content.include?("git ls-files -z --") && !content.include?(".reject")
    Result.new(label, ok, fix)
  end

  # --- reporting ---------------------------------------------------------------------------------

  def report(results)
    @out.puts "Conformance audit: #{@gem_dir}"
    @out.puts
    results.each do |r|
      @out.puts "  #{r.ok ? '✓' : '✗'} #{r.label}"
      @out.puts "      ↳ #{r.fix}" if !r.ok && r.fix
    end
    @out.puts
    passed = results.count(&:ok)
    summary = "#{passed}/#{results.size} checks passed"
    summary += passed == results.size ? " — conformant" : " — see fixes above"
    @out.puts summary
  end
end
