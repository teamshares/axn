# frozen_string_literal: true

require "tmpdir"
require "stringio"
require "fileutils"
require_relative "../../bin/support/gem_generator"

# The generator is a dev-only tool (bin/, absent from the packaged gem). It shells out to
# `bundle gem NAME` (offline, ~1s) and lays the canonical axn delta on top, so a fresh
# downstream gem starts conformant instead of being reverse-engineered from an existing one.
RSpec.describe GemGenerator do
  def read(relative) = File.read(File.join(@gem_dir, relative))
  def exist?(relative) = File.exist?(File.join(@gem_dir, relative))

  # The canonical bin/refresh is core's own — the generated copy must stay byte-identical to it.
  def canonical_refresh = File.read(File.expand_path("../../bin/refresh", __dir__))

  context "with a single-word gem name" do
    before(:context) do
      @parent = Dir.mktmpdir("axn-new-gem")
      @gem_dir = described_class.new("foo_bar", dest_parent: @parent, install: false,
                                                output: StringIO.new, input: StringIO.new).run
    end

    after(:context) { FileUtils.remove_entry(@parent) if @parent && File.directory?(@parent) }

    it "creates the gem directory under the destination parent" do
      expect(@gem_dir).to eq(File.join(@parent, "foo_bar"))
      expect(File.directory?(@gem_dir)).to be(true)
    end

    it "emits the canonical bin/refresh, byte-identical to core's" do
      expect(read("bin/refresh")).to eq(canonical_refresh)
    end

    it "deletes bundle gem cruft the base layer doesn't want" do
      expect(exist?("bin/console")).to be(false)
      expect(exist?("bin/setup")).to be(false)
      expect(exist?("sig")).to be(false)
    end

    it "standardizes CI on ci.yml (not main.yml)" do
      expect(exist?(".github/workflows/ci.yml")).to be(true)
      expect(exist?(".github/workflows/main.yml")).to be(false)
      ci = read(".github/workflows/ci.yml")
      expect(ci).to include("actions/checkout@v6")
      expect(ci).to include("bundle exec rake")
      %w[3.2 3.3 3.4].each { |v| expect(ci).to include("'#{v}'") }
    end

    it "always emits CODEOWNERS and renovate.json5" do
      expect(read(".github/CODEOWNERS")).to eq("* @teamshares/oss\n")
      expect(read(".github/renovate.json5")).to include("github>teamshares/renovate-config:lib.json5")
    end

    it "wires the shared rubocop config via inherit_gem" do
      rubocop = read(".rubocop.yml")
      expect(rubocop).to include("inherit_gem:")
      expect(rubocop).to include('axn: ".rubocop.yml"')
      # No hyphenated entry, so no Naming/FileName exclude.
      expect(rubocop).not_to include("Naming/FileName")
    end

    it "emits the canonical .gitignore set" do
      gitignore = read(".gitignore")
      expect(gitignore).to include("Gemfile.lock")
      expect(gitignore).to include("node_modules/")
      expect(gitignore).to include(".rspec_status")
    end

    it "emits a canonical gemspec with no TODO placeholders" do
      gemspec = read("foo_bar.gemspec")
      expect(gemspec).not_to include("TODO")
      expect(gemspec).to include('spec.add_dependency "axn"')
      expect(gemspec).to include('"< 0.2.0"')
      expect(gemspec).to include('spec.bindir = "exe"')
      expect(gemspec).to include('require_relative "lib/foo_bar/version"')
      expect(gemspec).to include("FooBar::VERSION")
      expect(gemspec).to include("rubygems_mfa_required")
      # The full canonical reject list (axn-ruby_llm's short/old variant is the drift we kill).
      expect(gemspec).to include("node_modules/")
    end

    it "pins axn to the teamshares main branch in the Gemfile" do
      expect(read("Gemfile")).to include('gem "axn", github: "teamshares/axn", branch: "main"')
    end

    it "wires the axn base layer into the entry file" do
      entry = read("lib/foo_bar.rb")
      expect(entry).to include('require "axn"')
      expect(entry).to include("extend Axn::Configurable")
      expect(entry).to include("config_namespace :foo_bar")
      expect(entry).to include("def self.deprecator")
      expect(entry).to include('ActiveSupport::Deprecation.new("1.0", "foo_bar")')
    end

    it "emits the canonical spec_helper" do
      helper = read("spec/spec_helper.rb")
      expect(helper).to include('require "axn/testing/spec_helpers"')
      expect(helper).to include("disable_monkey_patching!")
    end

    it "removes bundle gem's deliberately-failing example so the scaffold is green" do
      spec = read("spec/foo_bar_spec.rb")
      expect(spec).not_to include("expect(false)")
      expect(spec).to include("has a version number")
    end

    it "symlinks CLAUDE.md to AGENTS.md" do
      claude = File.join(@gem_dir, "CLAUDE.md")
      expect(File.symlink?(claude)).to be(true)
      expect(File.readlink(claude)).to eq("AGENTS.md")
      expect(exist?("AGENTS.md")).to be(true)
    end

    it "seeds an Unreleased CHANGELOG section" do
      expect(read("CHANGELOG.md")).to include("## [Unreleased]")
    end
  end

  context "with a hyphenated (axn-*) gem name" do
    before(:context) do
      @parent = Dir.mktmpdir("axn-new-gem")
      @gem_dir = described_class.new("axn-foo", dest_parent: @parent, install: false,
                                                output: StringIO.new, input: StringIO.new).run
    end

    after(:context) { FileUtils.remove_entry(@parent) if @parent && File.directory?(@parent) }

    it "creates the hyphenated shim entry requiring the nested real entry" do
      shim = read("lib/axn-foo.rb")
      expect(shim).to include('require_relative "axn/foo"')
    end

    it "wires the axn base layer into the nested real entry with the axn- stripped namespace" do
      entry = read("lib/axn/foo.rb")
      expect(entry).to include('require "axn"')
      expect(entry).to include("extend Axn::Configurable")
      expect(entry).to include("config_namespace :foo")
      expect(entry).to include("def self.deprecator")
    end

    it "adds the Naming/FileName exclude for the hyphenated entry" do
      rubocop = read(".rubocop.yml")
      expect(rubocop).to include("Naming/FileName")
      expect(rubocop).to include('"lib/axn-foo.rb"')
    end

    it "references the nested version constant in the gemspec" do
      gemspec = read("axn-foo.gemspec")
      expect(gemspec).to include("Axn::Foo::VERSION")
      expect(gemspec).to include('require_relative "lib/axn/foo/version"')
    end
  end

  # The summary is the one field genuinely worth capturing at creation time (RubyGems requires it);
  # it flows into both the gemspec (summary + description) and the README description line.
  describe "summary resolution" do
    def generate(name, **opts)
      parent = Dir.mktmpdir("axn-new-gem")
      @cleanup << parent
      # Force a non-interactive input so the tty prompt never fires (and never hangs) under specs.
      described_class.new(name, dest_parent: parent, install: false, output: StringIO.new,
                                input: StringIO.new, **opts).run
    end

    before { @cleanup = [] }
    after { @cleanup.each { |dir| FileUtils.remove_entry(dir) if File.directory?(dir) } }

    it "falls back to a gem-name-aware summary when none is provided and input is non-interactive" do
      gem_dir = generate("foo_bar")
      gemspec = File.read(File.join(gem_dir, "foo_bar.gemspec"))
      readme = File.read(File.join(gem_dir, "README.md"))

      expect(gemspec).to include('spec.summary = "foo_bar: an axn-consuming gem."')
      expect(gemspec).to include('spec.description = "foo_bar: an axn-consuming gem."')
      expect(readme).to include("foo_bar: an axn-consuming gem.")
      # The old fully-generic README line must be gone.
      expect(readme).not_to include("An [axn](https://github.com/teamshares/axn)-consuming gem.")
    end

    it "uses an explicitly provided summary for the gemspec and README" do
      gem_dir = generate("foo_bar", summary: "Sends widgets to the frobnicator.")
      gemspec = File.read(File.join(gem_dir, "foo_bar.gemspec"))

      expect(gemspec).to include('spec.summary = "Sends widgets to the frobnicator."')
      expect(gemspec).to include('spec.description = "Sends widgets to the frobnicator."')
      expect(File.read(File.join(gem_dir, "README.md"))).to include("Sends widgets to the frobnicator.")
    end

    it "safely escapes a summary containing quotes into the gemspec" do
      gem_dir = generate("foo_bar", summary: 'The "best" gem.')
      gemspec = File.read(File.join(gem_dir, "foo_bar.gemspec"))

      expect(gemspec).to include('spec.summary = "The \"best\" gem."')
    end
  end
end
