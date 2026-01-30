# frozen_string_literal: true

# Integration test tasks for verifying async behavior with real backends.
#
# These tasks complement the RSpec suite by testing actual job processing
# behavior (not inline/fake mode). Useful for validating:
# - Exception reporting behavior across retries
# - Retry context propagation
# - Death handler / after_discard triggering
# - discard_on behavior
#
# Prerequisites:
# - Redis running on localhost:6379 (for Sidekiq)
# - Run from spec_rails/dummy_app directory
#
# Usage:
#   bundle exec rake async:verify:sidekiq
#   bundle exec rake async:verify:active_job
#   bundle exec rake async:verify:all

namespace :async do
  namespace :verify do
    desc "Verify Sidekiq async behavior with real job processing"
    task :sidekiq do
      # If env var not set, re-exec with it set (ensures adapter is configured before Rails loads)
      if ENV["AXN_DEFAULT_ASYNC_ADAPTER"] == "sidekiq"
        # Now load Rails and run the verifier
        Rake::Task[:environment].invoke
        require_relative "../integration/sidekiq_verifier"
        Integration::SidekiqVerifier.run!
      else
        puts "Running Sidekiq verifier..."
        exit(1) unless system({ "AXN_DEFAULT_ASYNC_ADAPTER" => "sidekiq" }, "bundle", "exec", "rake", "async:verify:sidekiq")
      end
    end

    desc "Verify ActiveJob async behavior with real job processing"
    task :active_job do
      # If env var not set, re-exec with it set (ensures adapter is configured before Rails loads)
      if ENV["AXN_DEFAULT_ASYNC_ADAPTER"] == "active_job"
        # Now load Rails and run the verifier
        Rake::Task[:environment].invoke
        require_relative "../integration/active_job_verifier"
        Integration::ActiveJobVerifier.run!
      else
        puts "Running ActiveJob verifier..."
        exit(1) unless system({ "AXN_DEFAULT_ASYNC_ADAPTER" => "active_job" }, "bundle", "exec", "rake", "async:verify:active_job")
      end
    end

    desc "Run all async integration verifications"
    task all: %i[sidekiq active_job]
  end
end
