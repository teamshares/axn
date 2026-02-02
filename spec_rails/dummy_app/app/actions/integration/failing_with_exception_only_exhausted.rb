# frozen_string_literal: true

module Actions
  module Integration
    # Action that raises an exception with per-class :only_exhausted override.
    # Uses the global default async adapter (set via AXN_DEFAULT_ASYNC_ADAPTER env var).
    class FailingWithExceptionOnlyExhausted
      include Axn

      # Sidekiq-specific configuration (only applied when adapter is sidekiq)
      if ENV["AXN_DEFAULT_ASYNC_ADAPTER"] == "sidekiq"
        async :sidekiq do
          sidekiq_options retry: 2
          sidekiq_retry_in { 1 }
        end
      else
        async
      end

      # Per-class override: only report when retries are exhausted
      async_exception_reporting :only_exhausted

      expects :name

      def call
        info "About to fail with name: #{name} (only_exhausted override)"
        raise StandardError, "Intentional failure for only_exhausted testing"
      end
    end
  end
end
