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

      # Format a millisecond value as a human-readable duration string
      def self.human_duration(ms)
        case ms
        when 0...1_000
          "#{ms.round(3)} milliseconds"
        when 1_000...60_000
          "#{(ms / 1_000.0).round(3)} seconds"
        when 60_000...3_600_000
          "#{(ms / 60_000.0).round(2)} minutes"
        else
          "#{(ms / 3_600_000.0).round(2)} hours"
        end
      end
    end
  end
end
