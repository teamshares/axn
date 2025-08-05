# frozen_string_literal: true

module Action
  module Core
    module AutomaticLogging
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
            before: Action.config.env.production? ? nil : "\n------\n",
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
            after: Action.config.env.production? ? nil : "\n------\n",
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
            # NOTE: slightly more manual in order to avoid quotes around ActiveRecord objects' <Class#id> formatting
            "{#{data.map { |k, v| "#{k}: #{_log_object(v)}" }.join(", ")}}"
          when Array
            data.map { |v| _log_object(v) }
          else
            return data.to_unsafe_h if defined?(ActionController::Parameters) && data.is_a?(ActionController::Parameters)
            return "<#{data.class.name}##{data.to_param.presence || "unpersisted"}>" if defined?(ActiveRecord::Base) && data.is_a?(ActiveRecord::Base)

            data.inspect
          end
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
end
