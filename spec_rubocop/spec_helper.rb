# frozen_string_literal: true

require "bundler/setup"
require "rubocop"
require "rubocop/rspec/support"

# Load the main spec helper for shared configuration
require_relative "../spec/spec_helper"

# Configure RuboCop testing
RSpec.configure do |config|
  config.include RuboCop::RSpec::ExpectOffense
end
