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

      # Determines if on_exception should be triggered based on config and retry state.
      #
      # For :first_and_exhausted and :only_exhausted modes, exhaustion reporting is handled by:
      # - Sidekiq: Death handler (calls this with from_exhaustion_handler: true)
      # - ActiveJob: after_discard callback (calls this with from_exhaustion_handler: true)
      #   Note: ActiveJob adapter requires Rails 7.1+ for these modes (raises error on older Rails)
      #
      # @param config_mode [Symbol, nil] The exception reporting mode. If nil, falls back to global config.
      # @param from_exhaustion_handler [Boolean] if true, called from exhaustion/discard handler
      def should_trigger_on_exception?(config_mode = nil, from_exhaustion_handler: false)
        # Fall back to global config when no per-class override is set
        resolved_mode = config_mode || Axn.config.async_exception_reporting

        case resolved_mode
        when :first_and_exhausted
          # Regular flow reports on first attempt only.
          # Exhaustion handler reports only when retries were exhausted after multiple attempts,
          # NOT when job was discarded on first attempt (perform already reported).
          if from_exhaustion_handler
            !first_attempt? # avoid double-report when job discarded on first attempt
          else
            first_attempt?
          end
        when :only_exhausted
          # Only exhaustion handler should report
          from_exhaustion_handler
        else
          # :every_attempt and unknown modes default to triggering
          true
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
