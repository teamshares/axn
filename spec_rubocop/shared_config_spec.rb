# frozen_string_literal: true

require_relative "spec_helper"
require "tmpdir"

# Guards the shared .rubocop.yml as consumed by downstream gems via `inherit_gem: axn`.
#
# The load-bearing piece is `inherit_mode: merge: Exclude`. Declaring an AllCops/Exclude array
# REPLACES RuboCop's built-in one (vendor, node_modules, tmp, .git), and every glob resolves relative
# to the config file that declares it — so without the merge, a consuming gem inherits globs pointing
# into the axn gem dir having lost the built-ins that pointed at itself. Its CI then lints the bundle
# ruby/setup-ruby's bundler-cache installs into an in-repo vendor/bundle, reads each vendored gem's
# own .rubocop.yml, and dies on the plugins those `require:` but the gem doesn't bundle — before
# inspecting a single file. Observed in teamshares/slack_sender (slack-ruby-client requires
# rubocop-performance/-rake/-rspec).
#
# Asserted end-to-end in a subprocess rather than through RuboCop::ConfigLoader in-process, because
# the loader memoizes its built-in config's absolute Exclude globs against the directory the process
# started in — in-process probes silently measure axn's own tree instead of the fixture's.
RSpec.describe "shared .rubocop.yml (as inherited by downstream gems)" do
  # A downstream gem's tree: inherits core's config, carries a local Exclude delta (which is what
  # triggers the array replacement), and has a vendored dependency whose own config requires a plugin
  # that is not installed here.
  def with_consuming_gem
    Dir.mktmpdir do |dir|
      vendored = File.join(dir, "vendor/bundle/ruby/3.3.0/gems/bad-dep-1.0.0")
      FileUtils.mkdir_p(File.join(vendored, "lib"))
      FileUtils.mkdir_p(File.join(dir, "lib"))

      File.write(File.join(dir, ".rubocop.yml"), <<~YAML)
        inherit_gem:
          axn: ".rubocop.yml"

        AllCops:
          Exclude:
            - "some-local-delta/**/*"
      YAML
      File.write(File.join(dir, "lib/own_code.rb"), "# frozen_string_literal: true\n")
      File.write(File.join(vendored, ".rubocop.yml"), "require:\n  - rubocop-no-such-plugin\n")
      File.write(File.join(vendored, "lib/vendored.rb"), "# frozen_string_literal: true\n")

      yield dir
    end
  end

  # Runs RuboCop with the fixture as the working directory, on the current interpreter so the
  # inherited bundler setup (and therefore `inherit_gem: axn`) still resolves.
  def rubocop_in(dir, *args)
    script = 'require "rubocop"; exit RuboCop::CLI.new.run(ARGV)'
    # "--" so ruby hands the flags to ARGV instead of parsing them itself.
    IO.popen([RbConfig.ruby, "-e", script, "--", *args, { chdir: dir, err: %i[child out] }], &:read)
  end

  it "excludes a consuming gem's in-repo vendor/bundle from linting" do
    with_consuming_gem do |dir|
      targets = rubocop_in(dir, "--list-target-files").lines.map(&:chomp)

      expect(targets).to include("lib/own_code.rb")
      expect(targets.grep(%r{vendor/bundle})).to be_empty
    end
  end

  it "does not crash on a vendored dependency's own require:" do
    with_consuming_gem do |dir|
      output = rubocop_in(dir)

      expect(output).not_to include("cannot load such file")
      expect(output).not_to include("rubocop-no-such-plugin")
    end
  end
end
