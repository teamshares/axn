# frozen_string_literal: true

module Actions
  module Async
    module ActiveJob
      class EveryAttempt
        include Axn

        async :active_job do
          retry_on StandardError, attempts: 2
        end

        include Concerns::EveryAttemptBehavior
      end
    end
  end
end
