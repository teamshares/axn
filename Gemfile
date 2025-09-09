# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in axn.gemspec
gemspec

# These are only needed for development of Axn itself
gem "pry-byebug", "3.11.0"
gem "rails", "> 7.0" # For Rails Engine testing
gem "rspec", "~> 3.2"
gem "sidekiq", "~> 7" # Background job processor -- when update, ensure `process_context_to_sidekiq_args` is still compatible
gem "sqlite3", "~> 2.0" # For Rails Engine testing database

gem "rake", "~> 13.0"
gem "rubocop", "~> 1.21"
