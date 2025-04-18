# frozen_string_literal: true

module Action
  module TopLevelAroundHook
    def self.included(base)
      base.class_eval do
        around :__top_level_around_hook

        include InstanceMethods
      end
    end

    module InstanceMethods
      def __top_level_around_hook(hooked)
        timing_start = Time.now
        _log_before

        _configurable_around_wrapper do
          (@outcome, @exception) = _call_and_return_outcome(hooked)
        end

        _log_after(timing_start:, outcome: @outcome)

        raise @exception if @exception
      end

      private

      def _configurable_around_wrapper(&)
        return yield unless Action.config.top_level_around_hook

        Action.config.top_level_around_hook.call(self.class.name || "AnonymousClass", &)
      end

      def _log_before
        debug [
          "About to execute",
          context_for_logging(:inbound).presence&.inspect,
        ].compact.join(" with: ")
      end

      def _log_after(outcome:, timing_start:)
        elapsed_mils = ((Time.now - timing_start) * 1000).round(3)

        debug [
          "Execution completed (with outcome: #{outcome}) in #{elapsed_mils} milliseconds",
          context_for_logging(:outbound).presence&.inspect,
        ].compact.join(". Set: ")
      end

      def _call_and_return_outcome(hooked)
        hooked.call

        "success"
      rescue StandardError => e
        [
          e.is_a?(Action::Failure) ? "failure" : "exception",
          e,
        ]
      end
    end
  end
end
