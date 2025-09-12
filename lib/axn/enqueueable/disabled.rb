# frozen_string_literal: true

module Axn
  module Enqueueable
    module Disabled
      def self.included(base)
        base.class_eval do
          def self.call_async(context = {})
            raise NotImplementedError,
                  "Async execution is explicitly disabled for #{name}. " \
                  "Use `async :sidekiq` or `async :active_job` to enable background processing."
          end
        end
      end
    end
  end
end
