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
          level = self.class.log_calls_level
          return unless level

          self.class.public_send(
            level,
            [
              "About to execute",
              _log_context(:inbound),
            ].compact.join(" with: "),
            before: Axn.config.env.production? ? nil : "\n------\n",
          )
        rescue StandardError => e
          Axn::Internal::Logging.piping_error("logging before hook", action: self, exception: e)
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
          return unless level

          self.class.public_send(
            level,
            [
              "Execution completed (with outcome: #{result.outcome}) in #{result.elapsed_time} milliseconds",
              _log_context(:outbound),
            ].compact.join(". Set: "),
            after: Axn.config.env.production? ? nil : "\n------\n",
          )
        rescue StandardError => e
          Axn::Internal::Logging.piping_error("logging after hook", action: self, exception: e)
        end

        def _log_context(direction)
          data = context_for_logging(direction)
          Axn::Util::Logging.format_context(data)
        end
      end
    end
  end
end
