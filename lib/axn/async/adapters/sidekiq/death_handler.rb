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
              # Resolve the underlying Axn action. With the generic Worker the action class
              # name + kwargs live in job["args"]; legacy direct-Sidekiq::Job actions put the
              # action in job["class"] with kwargs as the first arg.
              action_class_name, action_args =
                if job["class"].to_s == Worker.name
                  [job["args"]&.first, job["args"]&.dig(1)]
                else
                  [job["class"], job["args"]&.first]
                end

              klass = action_class_name.to_s.safe_constantize
              return unless klass&.included_modules&.include?(Axn::Core)

              # Use per-class override if set, otherwise fall back to global config
              config_mode = klass.try(:_async_exception_reporting) || Axn.config.async_exception_reporting
              return if config_mode == :every_attempt # Already reported on each attempt

              retry_context = RetryHelpers.build_retry_context(job, from_death_handler: true)

              # For :first_and_exhausted, we need to report now (exhausted)
              # For :only_exhausted, we need to report now (only time)
              return unless retry_context.should_trigger_on_exception?(config_mode, from_exhaustion_handler: true)

              job_args = (action_args || {}).symbolize_keys

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
