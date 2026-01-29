# frozen_string_literal: true

module Axn
  module Async
    # Holds retry context information for async job execution.
    # This context is used to determine when on_exception should be triggered
    # and to provide retry information to exception handlers.
    class RetryContext
      attr_reader :adapter, :attempt, :max_retries, :job_id

      def initialize(adapter:, attempt:, max_retries:, job_id: nil)
        @adapter = adapter
        @attempt = attempt
        @max_retries = max_retries
        @job_id = job_id
      end

      def first_attempt?
        attempt == 1
      end

      def retries_exhausted?
        attempt > max_retries
      end

      # Determines if on_exception should be triggered based on config and retry state
      def should_trigger_on_exception?(config_mode = Axn.config.async_exception_reporting)
        case config_mode
        when :every_attempt then true
        when :first_and_exhausted then first_attempt? || retries_exhausted?
        when :only_exhausted then retries_exhausted?
        else true # Unknown modes default to triggering
        end
      end

      def to_h
        {
          adapter:,
          attempt:,
          max_retries:,
          job_id:,
          first_attempt: first_attempt?,
          retries_exhausted: retries_exhausted?,
        }.compact
      end
    end

    # Thread-local storage for the current async retry context
    module CurrentRetryContext
      class << self
        def current
          ActiveSupport::IsolatedExecutionState[:_axn_async_retry_context]
        end

        def current=(context)
          ActiveSupport::IsolatedExecutionState[:_axn_async_retry_context] = context
        end

        def with(context)
          previous = current
          self.current = context
          yield
        ensure
          self.current = previous
        end

        def clear
          self.current = nil
        end
      end
    end
  end
end
