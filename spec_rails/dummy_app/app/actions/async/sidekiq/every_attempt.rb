# frozen_string_literal: true

module Actions
  module Async
    module Sidekiq
      class EveryAttempt
        include Axn

        async :sidekiq do
          sidekiq_options retry: 2
        end

        include Concerns::EveryAttemptBehavior
      end
    end
  end
end
