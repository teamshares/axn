# frozen_string_literal: true

module Actions
  module Async
    module Sidekiq
      class OnlyExhausted
        include Concerns::OnlyExhaustedBehavior

        async :sidekiq do
          sidekiq_options retry: 2
        end
      end
    end
  end
end
