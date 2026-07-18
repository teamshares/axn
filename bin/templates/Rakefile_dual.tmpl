# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"
require "rubocop/rake_task"

RSpec::Core::RakeTask.new(:spec)

# Rails specs run in the embedded dummy app under spec_rails/dummy_app, which carries its own
# bundle (so the default suite stays Rails-free). Kept out of the default task for that reason.
task :spec_rails do
  Dir.chdir("spec_rails/dummy_app") do
    sh "BUNDLE_GEMFILE=Gemfile bundle exec rspec spec/"
  end
end

RuboCop::RakeTask.new

# Default: the fast, Rails-free suite + lint.
task default: %i[spec rubocop]

# Full suite (library + Rails) + lint — run pre-release and in CI.
desc "Run the full suite: library specs, Rails specs, and rubocop"
task verify: %i[spec spec_rails rubocop]

# Gate release on the full verify (bundler/gem_tasks' release depends on build).
Rake::Task["build"].enhance([:verify])
