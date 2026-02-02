# frozen_string_literal: true

module Actions
  module Integration
    # Action that raises an exception with per-class :every_attempt override.
    # Uses the global default async adapter (set via AXN_DEFAULT_ASYNC_ADAPTER env var).
    class FailingWithExceptionEveryAttempt
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

      # Per-class override: report on every attempt
      async_exception_reporting :every_attempt

      expects :name

      def call
        info "About to fail with name: #{name} (every_attempt override)"
        raise StandardError, "Intentional failure for every_attempt testing"
      end
    end
  end
end
