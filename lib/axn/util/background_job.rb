# frozen_string_literal: true

module Axn
  module Util
    module BackgroundJob
      extend self

      # Determines if code is currently running within a background job context.
      # Checks all registered async adapters to see if any report running in background.
      #
      # @return [Boolean] true if running in a background job, false otherwise
      #
      # @example
      #   if Axn::Util::BackgroundJob.running_in_background?
      #     # Code is running in Sidekiq or ActiveJob
      #   end
      def running_in_background?
        Axn::Async::Adapters.all.values.any? do |adapter|
          adapter.respond_to?(:_running_in_background?) && adapter._running_in_background?
        end
      rescue StandardError
        false
      end
    end
  end
end

