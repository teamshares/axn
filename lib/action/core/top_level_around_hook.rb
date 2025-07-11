# frozen_string_literal: true

module Action
  module TopLevelAroundHook
    def self.included(base)
      base.class_eval do
        around :__top_level_around_hook

        extend AutologgingClassMethods
        include AutologgingInstanceMethods
        include InstanceMethods
      end
    end

    module AutologgingClassMethods
      def default_autolog_level = Action.config.default_autolog_level
    end

    module AutologgingInstanceMethods
      private

      def _log_before
        public_send(
          self.class.default_autolog_level,
          [
            "About to execute",
            _log_context(:inbound),
          ].compact.join(" with: "),
        )
      end

      def _log_after(outcome:, timing_start:)
        elapsed_mils = ((Time.now - timing_start) * 1000).round(3)

        public_send(
          self.class.default_autolog_level,
          [
            "Execution completed (with outcome: #{outcome}) in #{elapsed_mils} milliseconds",
            _log_context(:outbound),
          ].compact.join(". Set: "),
        )
      end

      def _log_context(direction)
        data = context_for_logging(direction)
        return unless data.present?

        max_length = 150
        suffix = "…<truncated>…"

        _log_object(data).tap do |str|
          return str[0, max_length - suffix.length] + suffix if str.length > max_length
        end
      end

      def _log_object(data)
        case data
        when Hash
          data.transform_values { |v| _log_object(v) }
        when Array
          data.map { |v| _log_object(v) }
        else
          return "<#{data.class.name}##{data.id.presence || "unpersisted"}>" if defined?(ActiveRecord::Base) && data.is_a?(ActiveRecord::Base)

          data
        end.inspect
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
