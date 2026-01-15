# frozen_string_literal: true

module Axn
  module Util
    module BackgroundJob
      module_function

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

      # Determines if code is currently running in an interactive console (IRB, Pry, Rails console).
      # Used to skip visual separators in console output since the prompt already provides separation.
      #
      # @return [Boolean] true if running in a console, false otherwise
      def running_in_console?
        defined?(Rails::Console) || defined?(IRB) || defined?(Pry)
      end
    end
  end
end
