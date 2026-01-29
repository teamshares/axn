# frozen_string_literal: true

require_relative "retry_helpers"

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

              context = RetryContext.new(
                adapter: :sidekiq,
                attempt: (job["retry_count"] || 0) + 1,
                max_retries: RetryHelpers.extract_max_retries(job),
                job_id: job["jid"],
              )

              # For :first_and_exhausted, we need to report now (exhausted)
              # For :only_exhausted, we need to report now (only time)
              return unless context.should_trigger_on_exception?(config_mode)

              # Create a minimal action context for the exception handler
              action_context = {
                async: context.to_h,
                job_class: job["class"],
                job_args: job["args"],
              }

              # Call the global on_exception handler
              # We create a dummy action-like object for logging
              dummy_action = DeadJobAction.new(job)
              Axn.config.on_exception(exception, action: dummy_action, context: action_context)
            rescue StandardError => e
              # Don't let death handler errors prevent job death processing
              Axn::Internal::Logging.piping_error("in Sidekiq death handler", exception: e)
            end
          end

          # Minimal action-like object for dead job reporting
          class DeadJobAction
            def initialize(job)
              @job = job
            end

            def log(message)
              Axn.config.logger.warn("[Axn::DeadJob] #{message}")
            end

            def result
              @result ||= DeadJobResult.new
            end

            def class
              DeadJobActionClass.new(@job["class"])
            end
          end

          class DeadJobResult
            def error
              "Job exhausted all retries"
            end
          end

          class DeadJobActionClass
            def initialize(name)
              @name = name
            end

            attr_reader :name
          end
        end
      end
    end
  end
end
