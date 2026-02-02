# frozen_string_literal: true

module Actions
  module Async
    module Sidekiq
      class OnlyExhausted
        include Axn

        async :sidekiq do
          sidekiq_options retry: 2
        end

        include Concerns::OnlyExhaustedBehavior
      end
    end
  end
end
