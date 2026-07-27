# frozen_string_literal: true

ENV["RACK_ENV"] ||= "test"

require "axn"
require "axn/testing/spec_helpers"
require "pry-byebug"

$LOAD_PATH.unshift(File.expand_path(__dir__))

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.mock_with :rspec do |mocks|
    # Catch stubs/mocks on real objects (partial doubles) whose methods don't actually
    # exist — prevents dead stubs from silently passing when an API is renamed/removed.
    mocks.verify_partial_doubles = true
  end

  config.before(:suite) do
    Axn.configure do |c|
      # Hide default logging
      c.logger = Logger.new(File::NULL) unless ENV["DEBUG"]
    end
  end

  config.before { Axn::Tools::Registry.reset_adapters! }
end

def expect_best_effort_called(message_substring:, action: nil, times: 1)
  # The transitional swallow-based call sites always forward an `action:` kwarg to
  # `best_effort` — even `nil` — via its `action:` shorthand, so the trailing kwarg is
  # present on every call regardless of whether the original call site supplied one.
  # `any_args` tolerates that trailing arg when we don't care about it, while still
  # matching cleanly once migrated call sites stop forwarding it at all.
  args = [a_string_including(message_substring)]
  args << (action.nil? ? any_args : hash_including(action:))
  expect(Axn::Extensions).to have_received(:best_effort).with(*args).exactly(times).times
end
