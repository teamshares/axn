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
        end
      end
    end
  end
end
