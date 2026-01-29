# frozen_string_literal: true

require_relative "../exception_reporting"

module Axn
  module Async
    class Adapters
      module ActiveJob
        extend ActiveSupport::Concern

        # Fallback max retries when we can't determine from job or backend.
        # Matches ActiveJob's retry_on default of 5 attempts.
        FALLBACK_MAX_RETRIES = 5

        class << self
          def _running_in_background?
            defined?(::ActiveJob) && ::ActiveJob::Base.current_job.present?
          end

          # Attempts to determine max retries from the ActiveJob backend.
          # Returns nil if unable to determine (caller should use fallback).
          def backend_max_retries
            return @backend_max_retries if defined?(@backend_max_retries)

            @backend_max_retries = detect_backend_max_retries
          end

          private

          def detect_backend_max_retries
            # Try Sidekiq first (most common)
            if defined?(::Sidekiq)
              # Sidekiq 7+ uses default_configuration
              return ::Sidekiq.default_configuration[:max_retries] || 25 if ::Sidekiq.respond_to?(:default_configuration)
              # Sidekiq 6 and earlier use options hash
              return ::Sidekiq.options[:max_retries] if ::Sidekiq.respond_to?(:options) && ::Sidekiq.options[:max_retries]

              # Sidekiq is loaded but we can't get config - use its known default
              return 25
            end

            # Other backends - return nil to use fallback
            nil
          rescue StandardError
            nil
          end
        end

        included do
          raise LoadError, "ActiveJob is not available. Please add 'activejob' to your Gemfile." unless defined?(::ActiveJob::Base)

          # Validate that kwargs are not provided for ActiveJob
          if _async_config&.any?
            raise ArgumentError, "ActiveJob adapter requires a configuration block. Use `async :active_job do ... end` instead of passing keyword arguments."
          end
        end

        class_methods do
          private

          # Implements adapter-specific enqueueing logic for ActiveJob.
          # Note: Adapters must implement _enqueue_async_job and must NOT override call_async.
          def _enqueue_async_job(kwargs)
            job = active_job_proxy_class

            # Extract and normalize _async options (removes _async from kwargs)
            normalized_options = _extract_and_normalize_async_options(kwargs)

            # Process normalized async options if present
            if normalized_options
              if normalized_options["wait_until"]
                job = job.set(wait_until: normalized_options["wait_until"])
              elsif normalized_options["wait"]
                job = job.set(wait: normalized_options["wait"])
              end
            end

            job.perform_later(kwargs)
          end

          def active_job_proxy_class
            @active_job_proxy_class ||= create_active_job_proxy_class
          end

          def create_active_job_proxy_class
            # Store reference to the original action class
            action_class = self

            # Create the ActiveJob proxy class
            Class.new(::ActiveJob::Base).tap do |proxy|
              # Give the job class a meaningful name for logging and debugging
              job_name = "#{name}::ActiveJobProxy"
              const_set("ActiveJobProxy", proxy)
              proxy.define_singleton_method(:name) { job_name }

              # Apply the async configuration block if it exists
              proxy.class_eval(&_async_config_block) if _async_config_block

              # Define the perform method
              proxy.define_method(:perform) do |job_context = {}|
                # Set up retry context using ActiveJob's built-in executions counter
                # executions is 1 on first run, 2 on first retry, etc.
                # If executions is not available (stubbed ActiveJob), default to 1
                retry_context = Axn::Async::RetryContext.new(
                  adapter: :active_job,
                  attempt: _axn_current_attempt,
                  max_retries: _axn_max_retries,
                  job_id: _axn_job_id,
                )

                result = Axn::Async::CurrentRetryContext.with(retry_context) do
                  action_class.call(**job_context)
                end

                # Only re-raise unexpected exceptions so ActiveJob can retry.
                # Axn::Failure is a deliberate business decision (from fail!), not a transient error.
                # Per Sidekiq's ethos (which applies to background jobs generally):
                # "Retries are for unexpected errors."
                raise result.exception if result.outcome.exception?

                result
              end

              # Helper to get current attempt number (1-indexed)
              proxy.define_method(:_axn_current_attempt) do
                respond_to?(:executions) ? executions : 1
              end

              # Helper to determine max retries for this job
              proxy.define_method(:_axn_max_retries) do
                # Priority: job's retry_limit > config override > backend default > fallback
                self.class.try(:retry_limit) ||
                  Axn.config.async_max_retries ||
                  Axn::Async::Adapters::ActiveJob.backend_max_retries ||
                  Axn::Async::Adapters::ActiveJob::FALLBACK_MAX_RETRIES
              end

              # Helper to get job ID
              proxy.define_method(:_axn_job_id) do
                respond_to?(:job_id) ? job_id : nil
              end

              # Register after_discard callback to trigger on_exception when job is discarded.
              # This fires when:
              # - discard_on catches an exception
              # - retry_on exhausts all retries
              # - An unhandled exception causes discard
              #
              # Available in Rails 7.1+
              if proxy.respond_to?(:after_discard)
                proxy.after_discard do |job, exception|
                  _axn_handle_discard(job, exception, action_class)
                end
              end

              # Handler for discarded jobs - triggers on_exception based on config
              proxy.define_method(:_axn_handle_discard) do |job, exception, axn_class|
                # Skip if no exception (shouldn't happen, but be safe)
                return unless exception

                # Skip Axn::Failure - it's a business decision, not an error to report
                return if exception.is_a?(Axn::Failure)

                config_mode = Axn.config.async_exception_reporting

                # For :every_attempt, we already reported during perform - skip here
                return if config_mode == :every_attempt

                # Build retry context for the discard
                retry_context = Axn::Async::RetryContext.new(
                  adapter: :active_job,
                  attempt: _axn_current_attempt,
                  max_retries: _axn_max_retries,
                  job_id: _axn_job_id,
                )

                job_args = begin
                  (job.arguments.first || {}).symbolize_keys
                rescue StandardError
                  {}
                end

                Axn::Async::ExceptionReporting.trigger_on_exception(
                  exception:,
                  action_class: axn_class,
                  retry_context:,
                  job_args:,
                  extra_context: { async: { discarded: true } },
                  log_prefix: "ActiveJob after_discard handler",
                )
              end
            end
          end
        end
      end
    end
  end
end
