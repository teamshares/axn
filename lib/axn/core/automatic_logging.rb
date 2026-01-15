# frozen_string_literal: true

module Axn
  module Core
    module AutomaticLogging
      def self.included(base)
        base.class_eval do
          extend ClassMethods
          include InstanceMethods

          # Single class_attribute - nil means disabled, any level means enabled
          class_attribute :log_calls_level, default: Axn.config.log_level
          class_attribute :log_errors_level, default: nil
        end
      end

      module ClassMethods
        def log_calls(level)
          self.log_calls_level = level.presence
        end

        def log_errors(level)
          self.log_errors_level = level.presence
        end
      end

      module InstanceMethods
        private

        def _with_logging
          _log_before if self.class.log_calls_level
          yield
        ensure
          _log_after if self.class.log_calls_level || self.class.log_errors_level
        end

        def _log_before
          Axn::Util::Logging.log_at_level(
            self.class,
            level: self.class.log_calls_level,
            message_parts: ["About to execute"],
            join_string: " with: ",
            before: _top_level_separator,
            error_context: "logging before hook",
            context_direction: :inbound,
            context_instance: self,
          )
        end

        def _log_after
          # Check log_calls_level first (logs all outcomes)
          if self.class.log_calls_level
            _log_after_at_level(self.class.log_calls_level)
            return
          end

          # Check log_errors_level (only logs when result.ok? is false)
          return unless self.class.log_errors_level && !result.ok?

          _log_after_at_level(self.class.log_errors_level)
        end

        def _log_after_at_level(level)
          Axn::Util::Logging.log_at_level(
            self.class,
            level:,
            message_parts: [
              "Execution completed (with outcome: #{result.outcome}) in #{result.elapsed_time} milliseconds",
            ],
            join_string: ". Set: ",
            after: _top_level_separator,
            error_context: "logging after hook",
            context_direction: :outbound,
            context_instance: self,
          )
        end

        def _top_level_separator
          return if Axn.config.env.production?
          return if Axn::Util::BackgroundJob.running_in_background?
          return if Axn::Util::BackgroundJob.running_in_console?
          return if NestingTracking._current_axn_stack.size > 1

          "\n------\n"
        end
      end
    end
  end
end
