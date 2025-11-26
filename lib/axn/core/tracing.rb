# frozen_string_literal: true

require "securerandom"

module Axn
  module Core
    module Tracing
      class << self
        # Cache the tracer instance to avoid repeated lookups
        # The tracer provider may cache internally, but we avoid the method call overhead
        # We check defined?(OpenTelemetry) each time to handle cases where it's loaded lazily
        def tracer
          return nil unless defined?(OpenTelemetry)

          # Re-fetch if the tracer provider has changed (e.g., in tests with mocks)
          current_provider = OpenTelemetry.tracer_provider
          return @tracer if defined?(@tracer) && defined?(@tracer_provider) && @tracer_provider == current_provider

          @tracer_provider = current_provider
          @tracer = current_provider.tracer("axn", Axn::VERSION)
        end
      end

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
          Tracing.tracer.in_span("axn.call", attributes: { "axn.resource" => resource }) do |span|
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
          emit_metrics_proc = Axn.config.emit_metrics
          if emit_metrics_proc
            # Only pass the keyword arguments that the proc explicitly expects
            result = self.result
            kwargs = {}
            params = emit_metrics_proc.parameters
            accepts_keyrest = params.any? { |type, _name| type == :keyrest }
            if accepts_keyrest
              # If proc accepts **kwargs, pass everything
              kwargs[:resource] = resource
              kwargs[:result] = result
            else
              # Only pass explicitly expected keyword arguments
              expected_keywords = params.select { |type, _name| %i[key keyreq].include?(type) }.map { |_type, name| name }
              kwargs[:resource] = resource if expected_keywords.include?(:resource)
              kwargs[:result] = result if expected_keywords.include?(:result)
            end
            emit_metrics_proc.call(**kwargs)
          end
        rescue StandardError => e
          # Don't raise in ensure block to avoid interfering with existing exceptions
          Axn::Internal::Logging.piping_error("calling emit_metrics while tracing axn.call", action: self, exception: e)
        end
      end
    end
  end
end
