# frozen_string_literal: true

module Actions
  module Async
    module Concerns
      # Shared behavior for actions with per-class :every_attempt exception reporting.
      # Include this in adapter-specific action classes to test the override.
      #
      # Usage:
      #   class MyAction
      #     include Concerns::EveryAttemptBehavior
      #     async :sidekiq  # or :active_job
      #   end
      module EveryAttemptBehavior
        extend ActiveSupport::Concern

        included do
          include Axn

          async_exception_reporting :every_attempt

          expects :name

          define_method(:call) do
            info "Action executed with every_attempt: #{name}"
            raise StandardError, "Intentional failure for retry testing"
          end
        end
      end
    end
  end
end
