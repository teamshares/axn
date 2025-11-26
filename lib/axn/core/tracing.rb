# frozen_string_literal: true

require "securerandom"

module Axn
  module Core
    module Tracing
      private

      def _with_tracing(&)
        resource = self.class.name || "AnonymousClass"
        payload = { resource:, action: self }

        update_payload = proc do
          result = self.result
          outcome = result.outcome.to_s
          payload[:outcome] = outcome
          payload[:result] = result
          payload[:elapsed_time] = result.elapsed_time
          payload[:exception] = result.exception if result.exception
        rescue StandardError => e
          # Don't raise in ensure block to avoid interfering with existing exceptions
          Axn::Internal::Logging.piping_error("updating notification payload while tracing axn.call", action: self, exception: e)
        end

        instrument_block = proc do
          ActiveSupport::Notifications.instrument("axn.call", payload, &)
        ensure
          # Update payload BEFORE instrument completes so subscribers see the changes
          update_payload.call
        end

        # NOTE: despite using block form, ActiveSupport explicitly only emits to subscribers when it's finished,
        # which means it's not suitable for wrapping execution with a span and tracking child spans.
        # We use OpenTelemetry for that, if available.
        if defined?(OpenTelemetry)
          tracer = OpenTelemetry.tracer_provider.tracer("axn", Axn::VERSION)
          tracer.in_span("axn.call", attributes: { "axn.resource" => resource }) do |span|
            instrument_block.call
          ensure
            # Update span with outcome and error status after execution
            # This ensure runs before the span finishes, so we can still update it
            begin
              result = self.result
              outcome = result.outcome.to_s
              span.set_attribute("axn.outcome", outcome)

              if %w[failure exception].include?(outcome) && result.exception
                span.record_exception(result.exception)
                error_message = result.exception.message || result.exception.class.name
                span.status = OpenTelemetry::Trace::Status.error(error_message)
              end
            rescue StandardError => e
              # Don't raise in ensure block to avoid interfering with existing exceptions
              Axn::Internal::Logging.piping_error("updating OTel span while tracing axn.call", action: self, exception: e)
            end
          end
        else
          instrument_block.call
        end
      ensure
        begin
          result = self.result
          Axn.config.emit_metrics&.call(resource, result)
        rescue StandardError => e
          # Don't raise in ensure block to avoid interfering with existing exceptions
          Axn::Internal::Logging.piping_error("calling emit_metrics while tracing axn.call", action: self, exception: e)
        end
      end
    end
  end
end
