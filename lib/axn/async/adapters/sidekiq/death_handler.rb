# frozen_string_literal: true

require_relative "retry_helpers"
require_relative "../../exception_reporting"

module Axn
  module Async
    class Adapters
      module Sidekiq
        # Sidekiq death handler that triggers on_exception when retries are exhausted.
        # This is used when async_exception_reporting is set to :first_and_exhausted or :only_exhausted.
        #
        # To enable, add to your Sidekiq server configuration:
        #
        #   Sidekiq.configure_server do |config|
        #     config.death_handlers << Axn::Async::Adapters::Sidekiq::DeathHandler
        #   end
        #
        module DeathHandler
          class << self
            def call(job, exception)
              # Only handle Axn jobs
              klass = job["class"].to_s.safe_constantize
              return unless klass&.included_modules&.include?(Axn::Core)

              # Check if we should report based on config
              config_mode = Axn.config.async_exception_reporting
              return if config_mode == :every_attempt # Already reported on each attempt

              retry_context = RetryHelpers.build_retry_context(job)

              # For :first_and_exhausted, we need to report now (exhausted)
              # For :only_exhausted, we need to report now (only time)
              return unless retry_context.should_trigger_on_exception?(config_mode, from_exhaustion_handler: true)

              job_args = (job["args"]&.first || {}).symbolize_keys

              ExceptionReporting.trigger_on_exception(
                exception:,
                action_class: klass,
                retry_context:,
                job_args:,
                extra_context: {
                  _job_metadata: {
                    job_class: job["class"],
                    jid: job["jid"],
                    queue: job["queue"],
                    created_at: job["created_at"],
                    failed_at: job["failed_at"],
                    error_class: job["error_class"],
                    error_message: job["error_message"],
                  }.compact,
                },
                log_prefix: "Sidekiq death handler",
              )
            end
          end
        end
      end
    end
  end
end
