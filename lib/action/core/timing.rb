# frozen_string_literal: true

module Action
  module Core
    module Timing
      def self.included(base)
        base.class_eval do
          include InstanceMethods
        end
      end

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

      module InstanceMethods
        private

        def _with_timing
          timing_start = Core::Timing.now
          yield
        ensure
          elapsed_mils = Core::Timing.elapsed_ms(timing_start)
          @__context.send(:elapsed_time=, elapsed_mils)
        end
      end
    end
  end
end
