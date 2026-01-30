# frozen_string_literal: true

module Actions
  module Integration
    # Action that raises an unexpected exception - should retry and report
    class FailingWithException
      include Axn

      # Sidekiq-specific configuration (only applied when adapter is sidekiq)
      if ENV["AXN_DEFAULT_ASYNC_ADAPTER"] == "sidekiq"
        async :sidekiq do
          # Limit retries for faster test completion
          sidekiq_options retry: 2

          # Make retries happen immediately (no backoff delay)
          sidekiq_retry_in { 1 } # 1 second delay
        end
      else
        # For ActiveJob or disabled adapter, just use default async
        async
      end

      expects :name

      def call
        info "About to raise exception with name: #{name}"
        raise StandardError, "Intentional failure"
      end
    end
  end
end
