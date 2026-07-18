# frozen_string_literal: true

require "tmpdir"
require "stringio"
require "fileutils"
require_relative "../../bin/support/gem_generator"
require_relative "../../bin/support/gem_conformance"

# The conformance auditor reports how far an existing gem has drifted from the shared conventions.
# A freshly generated gem is the standard, so it must pass every check; each drift below is a
# mutation of that baseline that a real pre-generator gem might exhibit.
RSpec.describe GemConformance do
  # One conformant baseline for the whole file (rails: :none keeps generation fast).
  before(:context) do
    @parent = Dir.mktmpdir("axn-conform")
    @baseline = GemGenerator.new("conform_me", dest_parent: @parent, install: false,
                                               output: StringIO.new, input: StringIO.new, rails: :none).run
  end

  after(:context) { FileUtils.remove_entry(@parent) if @parent && File.directory?(@parent) }

  def audit(dir) = described_class.new(dir, output: StringIO.new).run

  # Copy the baseline, mutate it, audit the copy — so each example is independent.
  def with_drift
    Dir.mktmpdir("axn-drift") do |dir|
      FileUtils.cp_r(File.join(@baseline, "."), dir)
      yield dir
      audit(dir)
    end
  end

  it "passes every check on a freshly generated gem" do
    expect(audit(@baseline)).to be(true)
  end

  it "raises on a path that isn't a directory" do
    expect { described_class.new("/no/such/dir", output: StringIO.new).run }
      .to raise_error(described_class::Error, /not a directory/)
  end

  it "flags a missing/drifted lefthook.yml" do
    expect(with_drift { |d| File.delete(File.join(d, "lefthook.yml")) }).to be(false)
    expect(with_drift { |d| File.write(File.join(d, "lefthook.yml"), "changed\n") }).to be(false)
  end

  it "flags a byte-drifted bin/refresh" do
    expect(with_drift { |d| File.write(File.join(d, "bin", "refresh"), "#!/bin/sh\n") }).to be(false)
  end

  it "flags a leftover hand-rolled .githooks/ hook" do
    expect(with_drift do |d|
      FileUtils.mkdir_p(File.join(d, ".githooks"))
      File.write(File.join(d, ".githooks", "pre-commit"), "#!/bin/sh\n")
    end).to be(false)
  end

  it "flags a Gemfile that never adopted lefthook" do
    expect(with_drift do |d|
      gemfile = File.join(d, "Gemfile")
      File.write(gemfile, File.read(gemfile).gsub(/^gem "lefthook".*\n/, ""))
    end).to be(false)
  end

  it "flags inline CI that doesn't call the reusable workflow" do
    expect(with_drift do |d|
      File.write(File.join(d, ".github", "workflows", "ci.yml"),
                 "name: CI\non: [push]\njobs:\n  build:\n    runs-on: ubuntu-latest\n    steps:\n      - run: bundle exec rake\n")
    end).to be(false)
  end

  it "flags a leftover main.yml alongside ci.yml" do
    expect(with_drift { |d| File.write(File.join(d, ".github", "workflows", "main.yml"), "name: main\n") }).to be(false)
  end

  it "flags a denylist gemspec (not the allowlist)" do
    expect(with_drift do |d|
      gemspec = Dir[File.join(d, "*.gemspec")].first
      File.write(gemspec, File.read(gemspec).sub("git ls-files -z --", "git ls-files -z"))
    end).to be(false)
  end

  it "flags a gem with no internal-docs/" do
    expect(with_drift { |d| FileUtils.rm_rf(File.join(d, "internal-docs")) }).to be(false)
  end
end
