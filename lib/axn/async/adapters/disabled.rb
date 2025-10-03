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

            def self.call_async(**kwargs)
              # Remove _async parameter to avoid confusion in error message
              kwargs.delete(:_async)

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
