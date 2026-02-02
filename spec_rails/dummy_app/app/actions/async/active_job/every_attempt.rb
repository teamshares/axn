# frozen_string_literal: true

module Actions
  module Async
    module ActiveJob
      class EveryAttempt
        include Concerns::EveryAttemptBehavior

        async :active_job do
          retry_on StandardError, attempts: 2
        end
      end
    end
  end
end
