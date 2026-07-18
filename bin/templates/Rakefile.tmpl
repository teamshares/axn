# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"
require "rubocop/rake_task"

RSpec::Core::RakeTask.new(:spec)

RuboCop::RakeTask.new

task default: %i[spec rubocop]

# Gate release on a green default task (spec + rubocop). bundler/gem_tasks' `release` depends on
# `build`, so enhancing `build` runs the default before anything is pushed.
Rake::Task["build"].enhance([:default])
