# frozen_string_literal: true

module Actions
  module Async
    module ActiveJob
      class OnlyExhausted
        include Axn

        async :active_job do
          retry_on StandardError, attempts: 2
        end

        include Concerns::OnlyExhaustedBehavior
      end
    end
  end
end
