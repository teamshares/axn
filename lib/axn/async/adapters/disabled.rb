# frozen_string_literal: true

module Axn
  module Async
    class Adapters
      module Disabled
        def self._running_in_background?
          false
        end

        # Validation only. The raise lives in ClassMethods, which `call_async` dispatches to by the declared
        # adapter and without a notification or log line. Nothing is defined on the class itself, so a subclass
        # that re-declares `async :sidekiq` under a disabled parent really is enabled.
        def self.included(base)
          base.class_eval do
            raise ArgumentError, "Disabled adapter does not accept configuration options." if _async_config&.any?
            raise ArgumentError, "Disabled adapter does not accept configuration block." if _async_config_block
          end
        end

        module ClassMethods
          private

          def _enqueue_async_job(_kwargs)
            raise NotImplementedError,
                  "Async execution is explicitly disabled for #{name}. " \
                  "Use `async :sidekiq` or `async :active_job` to enable background processing."
          end
        end
      end
    end
  end
end
