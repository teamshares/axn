# frozen_string_literal: true

require_relative "retry_helpers"

module Axn
  module Async
    class Adapters
      module Sidekiq
        # Sidekiq server middleware that sets up retry context for Axn actions.
        # This middleware extracts retry information from the job hash and makes
        # it available via Axn::Async::CurrentRetryContext during job execution.
        #
        # To enable, add to your Sidekiq server configuration:
        #
        #   Sidekiq.configure_server do |config|
        #     config.server_middleware do |chain|
        #       chain.add Axn::Async::Adapters::Sidekiq::Middleware
        #     end
        #   end
        #
        class Middleware
          def call(worker, job, _queue, &)
            # Only set up context for Axn workers
            return yield unless worker.class.included_modules.include?(Axn::Core)

            context = RetryContext.new(
              adapter: :sidekiq,
              attempt: (job["retry_count"] || 0) + 1,
              max_retries: RetryHelpers.extract_max_retries(job),
              job_id: job["jid"],
            )

            CurrentRetryContext.with(context, &)
          end
        end
      end
    end
  end
end
