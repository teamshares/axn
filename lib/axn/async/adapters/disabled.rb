# frozen_string_literal: true

module Axn
  module Async
    class Adapters
      module Disabled
        def self.included(base)
          base.class_eval do
            # Validate that kwargs are not provided for Disabled adapter
            raise ArgumentError, "Disabled adapter does not accept configuration options." if _async_config&.any?
            raise ArgumentError, "Disabled adapter does not accept configuration block." if _async_config_block

            # Exception to the adapter pattern: Disabled adapter overrides call_async directly
            # to raise immediately without emitting notifications or logging.
            # Other adapters must NOT override call_async and should only implement _enqueue_async_job.
            def self.call_async(**kwargs)
              # Remove _async parameter to avoid confusion in error message
              kwargs.delete(:_async)

              # Don't emit notification or log - just raise immediately
              raise NotImplementedError,
                    "Async execution is explicitly disabled for #{name}. " \
                    "Use `async :sidekiq` or `async :active_job` to enable background processing."
            end

            def self._enqueue_async_job(kwargs)
              # This should never be called since call_async raises, but define it for completeness
              raise NotImplementedError,
                    "Async execution is explicitly disabled for #{name}. " \
                    "Use `async :sidekiq` or `async :active_job` to enable background processing."
            end
          end
        end
      end
    end
  end
end
