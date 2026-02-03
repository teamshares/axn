# frozen_string_literal: true

module Actions
  module Integration
    # Action that raises an unexpected exception with NO retries (retry: false).
    # This is used to verify "discard/death on first attempt" behavior across modes:
    # - :every_attempt => 1 report (attempt 1)
    # - :first_and_exhausted => 1 report (attempt 1; death handler must NOT double-report)
    # - :only_exhausted => 1 report (death handler only)
    #
    # Uses the global default async adapter (set via AXN_DEFAULT_ASYNC_ADAPTER env var).
    class FailingWithExceptionNoRetry
      include Axn

      if ENV["AXN_DEFAULT_ASYNC_ADAPTER"] == "sidekiq"
        async :sidekiq do
          sidekiq_options retry: false
        end
      else
        async
      end

      expects :name

      def call
        info "About to raise exception with name: #{name} (no retry)"
        raise StandardError, "Intentional failure (no retry)"
      end
    end
  end
end
