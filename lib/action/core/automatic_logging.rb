# frozen_string_literal: true

module Action
  module Core
    module AutomaticLogging
      def self.included(base)
        base.class_eval do
          extend ClassMethods
          include InstanceMethods
        end
      end

      module ClassMethods
        def autolog_level = Action.config.default_autolog_level
      end

      module InstanceMethods
        private

        def _with_logging
          timing_start = Core::Timing.now
          _log_before
          yield
        ensure
          _log_after(timing_start:, outcome: result.outcome)
        end

        def _log_before
          public_send(
            self.class.autolog_level,
            [
              "About to execute",
              _log_context(:inbound),
            ].compact.join(" with: "),
            before: Action.config.env.production? ? nil : "\n------\n",
          )
        rescue StandardError => e
          Axn::Util.piping_error("logging before hook", action: self, exception: e)
        end

        def _log_after(outcome:, timing_start:)
          elapsed_mils = Core::Timing.elapsed_ms(timing_start)

          public_send(
            self.class.autolog_level,
            [
              "Execution completed (with outcome: #{outcome}) in #{elapsed_mils} milliseconds",
              _log_context(:outbound),
            ].compact.join(". Set: "),
            after: Action.config.env.production? ? nil : "\n------\n",
          )
        rescue StandardError => e
          Axn::Util.piping_error("logging after hook", action: self, exception: e)
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
    end
  end
end
