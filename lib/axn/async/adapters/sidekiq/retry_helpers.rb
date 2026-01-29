# frozen_string_literal: true

module Axn
  module Async
    class Adapters
      module Sidekiq
        # Shared helpers for extracting retry information from Sidekiq jobs
        module RetryHelpers
          SIDEKIQ_DEFAULT_RETRIES = 25

          module_function

          # Extracts the maximum number of retries from a Sidekiq job hash.
          # Sidekiq's retry option can be:
          # - true or nil: use default (25)
          # - false: no retries (0)
          # - an integer: explicit retry count
          def extract_max_retries(job)
            retry_option = job["retry"]
            case retry_option
            when false then 0
            when Integer then retry_option
            else SIDEKIQ_DEFAULT_RETRIES
            end
          end
        end
      end
    end
  end
end
