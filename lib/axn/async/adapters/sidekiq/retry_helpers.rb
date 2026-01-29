# frozen_string_literal: true

module Axn
  module Async
    class Adapters
      module Sidekiq
        # Shared helpers for extracting retry information from Sidekiq jobs
        module RetryHelpers
          # Sidekiq's built-in default when retry: true or retry not specified
          SIDEKIQ_DEFAULT_RETRIES = 25

          module_function

          # Extracts the maximum number of retries from a Sidekiq job hash.
          # Sidekiq's retry option can be:
          # - true or nil: use Sidekiq default (25), unless config override is set
          # - false: no retries (0)
          # - an integer: explicit retry count
          #
          # If Axn.config.async_max_retries is explicitly set, it overrides
          # the Sidekiq default (but not explicit per-job integer values).
          def extract_max_retries(job)
            retry_option = job["retry"]
            case retry_option
            when false then 0
            when Integer then retry_option
            else
              # true, nil, or unknown value - use config override if set, else Sidekiq default
              Axn.config.async_max_retries || SIDEKIQ_DEFAULT_RETRIES
            end
          end

          # Calculates the attempt number from Sidekiq's retry_count field.
          # Sidekiq's retry_count semantics:
          # - nil: first execution (attempt 1)
          # - 0: first retry after first failure (attempt 2)
          # - 1: second retry (attempt 3)
          # - etc.
          def extract_attempt_number(job)
            retry_count = job["retry_count"]
            retry_count.nil? ? 1 : retry_count + 2
          end

          # Builds an Axn::Async::RetryContext from a Sidekiq job hash.
          # Used by both middleware and death handler to ensure consistent context.
          def build_retry_context(job)
            RetryContext.new(
              adapter: :sidekiq,
              attempt: extract_attempt_number(job),
              max_retries: extract_max_retries(job),
              job_id: job["jid"],
            )
          end
        end
      end
    end
  end
end
