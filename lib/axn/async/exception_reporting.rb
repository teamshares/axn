# frozen_string_literal: true

module Axn
  module Async
    # Shared utilities for async exception reporting across adapters.
    # Used by both Sidekiq (death handler) and ActiveJob (after_discard) to
    # build context and trigger on_exception consistently.
    module ExceptionReporting
      class << self
        # Triggers on_exception for an async job that has been discarded/exhausted.
        #
        # @param exception [Exception] the exception that caused the discard
        # @param action_class [Class] the Axn action class
        # @param retry_context [RetryContext] the retry context
        # @param job_args [Hash] the job arguments (will be filtered)
        # @param extra_context [Hash] additional context to merge (e.g., discarded: true, _job_metadata)
        # @param log_prefix [String] prefix for error logging (e.g., "Sidekiq death handler")
        def trigger_on_exception(exception:, action_class:, retry_context:, job_args:, extra_context: {}, log_prefix: "async")
          # Filter sensitive values using the action class's internal _context_slice
          filtered_context = action_class._context_slice(data: job_args, direction: :inbound)

          # Build final context with async info (avoid mutating extra_context)
          async_extra = extra_context[:async] || {}
          context = filtered_context.merge(
            async: retry_context.to_h.merge(async_extra),
          ).merge(extra_context.except(:async))

          # Create proxy action for the on_exception interface
          proxy_action = DiscardedJobAction.new(action_class, exception)

          # Trigger on_exception
          Axn.config.on_exception(exception, action: proxy_action, context:)
        rescue StandardError => e
          Axn::Internal::PipingError.swallow("in #{log_prefix}", exception: e)
        end
      end

      # Proxy action for discarded/dead job reporting that mimics an Axn action instance.
      # Provides the interface expected by on_exception handlers.
      class DiscardedJobAction
        def initialize(action_class, exception)
          @action_class = action_class
          @exception = exception
        end

        def log(message)
          Axn.config.logger.warn("[Axn::DiscardedJob] #{message}")
        end

        def result
          @result ||= DiscardedJobResult.new(@exception)
        end

        def class
          @action_class
        end
      end

      class DiscardedJobResult
        def initialize(exception)
          @exception = exception
        end

        def error
          @exception&.message || "Job was discarded"
        end

        attr_reader :exception
      end
    end
  end
end
