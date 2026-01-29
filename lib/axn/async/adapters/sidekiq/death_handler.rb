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

              retry_context = RetryContext.new(
                adapter: :sidekiq,
                attempt: (job["retry_count"] || 0) + 1,
                max_retries: RetryHelpers.extract_max_retries(job),
                job_id: job["jid"],
              )

              # For :first_and_exhausted, we need to report now (exhausted)
              # For :only_exhausted, we need to report now (only time)
              return unless retry_context.should_trigger_on_exception?(config_mode)

              # Build context using the action class's context_for_logging to properly
              # filter sensitive values. Job args contain the serialized action input context.
              job_args = (job["args"]&.first || {}).symbolize_keys
              filtered_context = klass.context_for_logging(data: job_args, direction: :inbound)

              # Merge async retry information and job metadata
              action_context = filtered_context.merge(
                async: retry_context.to_h,
                _job_metadata: {
                  job_class: job["class"],
                  jid: job["jid"],
                  queue: job["queue"],
                  created_at: job["created_at"],
                  failed_at: job["failed_at"],
                  error_class: job["error_class"],
                  error_message: job["error_message"],
                }.compact,
              )

              # Create a proxy action for logging that provides the expected interface
              proxy_action = DeadJobAction.new(job, klass, exception)

              # Call the global on_exception handler
              Axn.config.on_exception(exception, action: proxy_action, context: action_context)
            rescue StandardError => e
              # Don't let death handler errors prevent job death processing
              Axn::Internal::Logging.piping_error("in Sidekiq death handler", exception: e)
            end
          end

          # Proxy action for dead job reporting that mimics an Axn action instance.
          # Provides the interface expected by on_exception handlers.
          class DeadJobAction
            def initialize(job, action_class, exception)
              @job = job
              @action_class = action_class
              @exception = exception
            end

            def log(message)
              Axn.config.logger.warn("[Axn::DeadJob] #{message}")
            end

            def result
              @result ||= DeadJobResult.new(@exception)
            end

            def class
              @action_class
            end
          end

          class DeadJobResult
            def initialize(exception)
              @exception = exception
            end

            def error
              @exception&.message || "Job exhausted all retries"
            end

            attr_reader :exception
          end
        end
      end
    end
  end
end
