# frozen_string_literal: true

module Axn
  module Internal
    module Timing
      # Get the current monotonic time
      def self.now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # Calculate elapsed time in milliseconds
      def self.elapsed_ms(start_time)
        ((now - start_time) * 1000).round(3)
      end

      # Calculate elapsed time in seconds
      def self.elapsed_seconds(start_time)
        (now - start_time).round(6)
      end
    end
  end
end
