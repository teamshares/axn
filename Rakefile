# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

# RuboCop specs (separate from main specs to avoid loading RuboCop unnecessarily)
RSpec::Core::RakeTask.new(:spec_rubocop) do |task|
  task.pattern = "spec_rubocop/**/*_spec.rb"
end

# Rails specs (separate from main specs to avoid loading Rails unnecessarily)
task :spec_rails do
  Dir.chdir("spec_rails") do
    sh "bundle exec rspec ."
  end
end

require "rubocop/rake_task"

# RuboCop with Axn custom cops (targeting examples/rubocop directory)
task :rubocop_axn do
  sh "bundle exec rubocop --require axn/rubocop examples/rubocop/ || true"
end

# Default RuboCop task (runs on all files)
RuboCop::RakeTask.new

task default: %i[spec rubocop]
task all_specs: %i[spec spec_rubocop spec_rails]
