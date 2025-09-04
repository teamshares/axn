# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"
ENV["RACK_ENV"] ||= "test"

# Change to the dummy app directory to ensure proper loading
dummy_app_path = File.expand_path("dummy_app", __dir__)
original_dir = Dir.pwd

begin
  Dir.chdir(dummy_app_path)
  # Load the dummy Rails application
  require File.join(dummy_app_path, "config/environment")
ensure
  Dir.chdir(original_dir)
end

# Load axn testing helpers
require "axn/testing/spec_helpers"

$LOAD_PATH.unshift(File.expand_path(__dir__))

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.before(:suite) do
    Axn.configure do |c|
      # Hide default logging
      c.logger = Logger.new(File::NULL) unless ENV["DEBUG"]
    end
  end

  # Ensure Rails is properly loaded for each test
  config.before(:each) do
    # Reload the Rails application to ensure clean state
    Rails.application.reload_routes!
  end
end

def expect_piping_error_called(message_substring:, error_class:, error_message:, action: nil)
  matcher = {
    exception: an_object_satisfying { |e| e.is_a?(error_class) && e.message == error_message },
  }
  matcher[:action] = action unless action.nil?
  expect(Axn::Internal::Logging).to have_received(:piping_error).with(
    a_string_including(message_substring),
    hash_including(matcher),
  )
end
